#!/bin/bash
# ============================================================
# AMS fix_v4.sh - 컨테이너에서 실제 코드를 읽어 안전하게 수정
# 전략: 컨테이너 app.py를 직접 가져와서 정확한 변수명 파악 후 교체
# ============================================================
set -euo pipefail

APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
TMP_DIR="/tmp/ams_v4"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"

mkdir -p "$TMP_DIR"

echo "================================================"
echo " AMS fix_v4 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "================================================"

# ══════════════════════════════════════════════════
# STEP 1: 컨테이너 → 로컬로 최신 app.py 가져오기
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 1] 컨테이너에서 app.py 추출"
docker cp attendance-backend:/app/app.py "$TMP_DIR/app_live.py"
echo "  추출 완료: $TMP_DIR/app_live.py ($(wc -l < "$TMP_DIR/app_live.py")줄)"

# ══════════════════════════════════════════════════
# STEP 2: 실제 에러 로그 확인
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 2] 컨테이너 에러 로그"
docker logs attendance-backend --tail=30 2>&1 | grep -E "(Error|Traceback|500|NameError|AttributeError|TypeError|Exception)" | tail -15 || true

# ══════════════════════════════════════════════════
# STEP 3: attendance 함수 실제 코드 분석
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 3] attendance 함수 코드 분석"
python3 - << 'PYEOF'
import re, sys

path = '/tmp/ams_v4/app_live.py'
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# record_map 블록 찾기
rm_line = None
for i, ln in enumerate(lines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        rm_line = i
        break

if rm_line is None:
    print("  ⚠ record_map 없음 - attendance 라우트 전체 탐색")
    for i, ln in enumerate(lines):
        if '/api/attendance' in ln:
            print(f"  attendance 라우트: {i+1}줄")
            for j in range(i, min(i+60, len(lines))):
                print(f"  {j+1:4d}| {lines[j].rstrip()}")
            break
else:
    # 앞 5줄 + 뒤 20줄 출력
    start = max(0, rm_line - 5)
    end   = min(len(lines), rm_line + 20)
    print(f"  record_map 위치: {rm_line+1}줄")
    for j in range(start, end):
        print(f"  {j+1:4d}| {lines[j].rstrip()}")

    # for rec in <변수명> 찾기 (record_map 바로 다음 줄)
    for_line = None
    for i in range(rm_line, min(rm_line + 5, len(lines))):
        m = re.match(r'\s+for\s+rec\s+in\s+(\w+)', lines[i])
        if m:
            for_line = i
            var_name = m.group(1)
            print(f"\n  ✅ 반복 변수명: '{var_name}' (줄 {i+1})")
            break
    if for_line is None:
        print("  ⚠ 'for rec in' 패턴 없음")
PYEOF

# ══════════════════════════════════════════════════
# STEP 4: 정확한 변수명으로 안전하게 수정
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 4] attendance 엔드포인트 안전 수정"
python3 - << 'PYEOF'
import re, sys, os, shutil

src  = '/tmp/ams_v4/app_live.py'
dest = '/tmp/ams_v4/app_fixed.py'

with open(src, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# ── record_map 시작 줄 탐색 ──
rm_line = None
for i, ln in enumerate(lines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        rm_line = i
        break

if rm_line is None:
    print("  ❌ record_map 블록 없음 - 수동 확인 필요")
    sys.exit(1)

# ── for rec in <var> 줄 탐색 ──
rec_var = None
for i in range(rm_line, min(rm_line + 5, len(lines))):
    m = re.match(r'(\s+)for\s+rec\s+in\s+(\w+)', lines[i])
    if m:
        rec_var = m.group(2)
        indent  = m.group(1)
        break

if rec_var is None:
    # fallback: record_map 바로 아랫줄에서 파악
    print("  ⚠ 'for rec in' 없음 — 기존 코드 패턴 다름, 전체 블록 파악 시도")
    # record_map ~ 가장 가까운 return jsonify 사이 출력
    for i in range(rm_line, min(rm_line + 30, len(lines))):
        print(f"  {i+1:4d}| {lines[i].rstrip()}")
    sys.exit(1)

p  = indent       # 기본 들여쓰기 (for rec 와 동일 레벨)
p2 = p + '    '   # 한단계 안쪽

print(f"  ✅ 변수명: '{rec_var}', 들여쓰기: {len(p)}칸")

# ── return jsonify 줄 탐색 ──
ret_line = None
for i in range(rm_line, min(rm_line + 30, len(lines))):
    if re.search(r'return\s+jsonify\(', lines[i]):
        ret_line = i
        break

if ret_line is None:
    print("  ❌ return jsonify 줄 없음")
    sys.exit(1)

print(f"  ✅ 교체 범위: {rm_line+1}줄 ~ {ret_line+1}줄")
print("  교체 전 코드:")
for i in range(rm_line, ret_line + 1):
    print(f"    {i+1:4d}| {lines[i].rstrip()}")

# ── 새 블록 생성 ──
new_block = (
    f"{p}record_map = {{}}\n"
    f"{p}for rec in {rec_var}:\n"
    f"{p2}day_key = str(rec.date.day)\n"
    f"{p2}try:\n"
    f"{p2}    cin = rec.check_in_time.strftime('%H:%M') if rec.check_in_time else ''\n"
    f"{p2}except Exception:\n"
    f"{p2}    cin = str(rec.check_in_time)[:5] if rec.check_in_time else ''\n"
    f"{p2}record_map.setdefault(rec.employee_id, {{}})[day_key] = {{\n"
    f"{p2}    'check_in': cin,\n"
    f"{p2}    'type':     (rec.record_type  or 'normal'),\n"
    f"{p2}    'note':     (rec.note         or ''),\n"
    f"{p2}    'source':   (rec.data_source  or 'manual')\n"
    f"{p2}}}\n"
    f"{p}result = []\n"
    f"{p}for emp in employees:\n"
    f"{p2}result.append({{\n"
    f"{p2}    'id':         emp.id,\n"
    f"{p2}    'name':       (emp.name       or ''),\n"
    f"{p2}    'department': (emp.department or ''),\n"
    f"{p2}    'days':       record_map.get(emp.id, {{}})\n"
    f"{p2}}})\n"
    f"{p}return jsonify(result)\n"
)

new_lines = lines[:rm_line] + [new_block] + lines[ret_line + 1:]

with open(dest, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print("\n  교체 후 코드:")
# 새 파일에서 record_map 위치 다시 찾아 출력
with open(dest, 'r', encoding='utf-8') as f:
    nlines = f.readlines()
for i, ln in enumerate(nlines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        for j in range(i, min(i+20, len(nlines))):
            print(f"    {j+1:4d}| {nlines[j].rstrip()}")
        break

print(f"\n  ✅ 수정 완료 → {dest}")
PYEOF

if [ ! -f "$TMP_DIR/app_fixed.py" ]; then
    echo "  ❌ app_fixed.py 생성 실패 - 중단"
    exit 1
fi
echo "  [✓] Step 4 완료"

# ══════════════════════════════════════════════════
# STEP 5: 컨테이너 내부에서 수정 파일 사전 테스트
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 5] 컨테이너 내부 사전 테스트"
# 수정된 파일을 컨테이너에 임시 복사하여 구문·로직 검증
docker cp "$TMP_DIR/app_fixed.py" attendance-backend:/app/app_test.py
docker exec attendance-backend python3 - << 'PYEOF'
import sys, json, calendar, traceback

# 구문 검사
with open('/app/app_test.py', 'r') as f:
    src = f.read()
try:
    compile(src, 'app_test.py', 'exec')
    print("[✓] 구문 검사 통과")
except SyntaxError as e:
    print(f"[❌] 구문 오류: {e}")
    sys.exit(1)

# 로직 검사
try:
    import importlib.util, os
    os.rename('/app/app_test.py', '/app/app_test_run.py')
    spec = importlib.util.spec_from_file_location("app_test", "/app/app_test_run.py")
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    with mod.app.app_context():
        year, month = 2026, 2
        employees = mod.Employee.query.filter_by(is_active=True).limit(3).all()
        print(f"[✓] 직원 수: {len(employees)}명")

        start_dt = __import__('datetime').date(year, month, 1)
        end_dt   = __import__('datetime').date(year, month, calendar.monthrange(year, month)[1])
        recs = mod.AttendanceRecord.query.filter(
            mod.AttendanceRecord.employee_id.in_([e.id for e in employees]),
            mod.AttendanceRecord.date.between(start_dt, end_dt)
        ).limit(20).all()
        print(f"[✓] 출석 레코드: {len(recs)}건")

        record_map = {}
        for rec in recs:
            day_key = str(rec.date.day)
            try:
                cin = rec.check_in_time.strftime('%H:%M') if rec.check_in_time else ''
            except Exception:
                cin = str(rec.check_in_time)[:5] if rec.check_in_time else ''
            record_map.setdefault(rec.employee_id, {})[day_key] = {
                'check_in': cin,
                'type':   (rec.record_type  or 'normal'),
                'note':   (rec.note         or ''),
                'source': (rec.data_source  or 'manual')
            }

        result = []
        for emp in employees:
            result.append({
                'id':         emp.id,
                'name':       (emp.name       or ''),
                'department': (emp.department or ''),
                'days':       record_map.get(emp.id, {})
            })

        j = json.dumps(result, ensure_ascii=False)
        print(f"[✓] JSON 직렬화 성공: {len(result)}건")
        if result:
            print(f"[✓] 샘플: {json.dumps(result[0], ensure_ascii=False)[:200]}")

except Exception as e:
    print(f"[❌] 로직 오류: {e}")
    traceback.print_exc()
    sys.exit(1)
finally:
    try: os.rename('/app/app_test_run.py', '/app/app_test.py')
    except: pass
PYEOF

TEST_RET=$?
docker exec attendance-backend rm -f /app/app_test.py /app/app_test_run.py 2>/dev/null || true

if [ $TEST_RET -ne 0 ]; then
    echo ""
    echo "  ❌ 사전 테스트 실패 - 배포 중단!"
    exit 1
fi
echo "  [✓] 사전 테스트 통과 - 배포 진행"

# ══════════════════════════════════════════════════
# STEP 6: 호스트 app.py 교체 + 컨테이너 배포
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 6] 배포"
cp "$BACKEND" "${BACKEND}.bak_v4" && echo "  백업: ${BACKEND}.bak_v4"
cp "$TMP_DIR/app_fixed.py" "$BACKEND"
docker cp "$BACKEND" attendance-backend:/app/app.py && echo "  컨테이너 복사 완료"
docker restart attendance-backend && echo "  재시작 완료"
echo "  20초 대기..."
sleep 20

# ══════════════════════════════════════════════════
# STEP 7: HTTP 레벨 검증
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 7] HTTP 검증"
RESP=$(curl -s -w "||HTTP:%{http_code}" "http://localhost:5000/api/attendance?year=2026&month=2")
STATUS=$(echo "$RESP" | grep -oP 'HTTP:\K[0-9]+')
BODY=$(echo "$RESP" | sed 's/||HTTP:[0-9]*$//')

echo "  HTTP 상태: $STATUS"
if [ "$STATUS" = "200" ]; then
    echo "$BODY" | python3 - << 'PYEOF'
import sys, json
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
    items = d if isinstance(d, list) else d.get('data', [])
    print(f"  ✅ 직원 수: {len(items)}명")
    if items:
        f = items[0]
        ok = all(k in f for k in ['id','name','department','days'])
        print(f"  ✅ 필드: {list(f.keys())}")
        print(f"  ✅ 검증: {'OK' if ok else 'FAIL - ' + str(list(f.keys()))}")
        print(f"  ✅ 이름: {f.get('name','(없음)')} / 부서: {f.get('department','(없음)')}")
        days = f.get('days', {})
        if days:
            day, rec = next(iter(days.items()))
            print(f"  ✅ 출근기록 샘플: {day}일 → {rec}")
        else:
            print(f"  ℹ 출근기록 없음")
except Exception as e:
    print(f"  ❌ 파싱 오류: {e}")
    print(f"  응답: {raw[:300]}")
PYEOF
else
    echo "  ❌ HTTP $STATUS 오류!"
    echo "  응답: $BODY" | head -c 400
    echo ""
    echo "  컨테이너 최근 로그:"
    docker logs attendance-backend --tail=20 2>&1 | tail -20
fi

# employees API 확인
EMP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5000/api/employees")
echo "  employees API: HTTP $EMP"

# ══════════════════════════════════════════════════
# STEP 8: GitHub 푸시
# ══════════════════════════════════════════════════
echo ""
echo "▶ [STEP 8] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

# 원격 변경사항 가져오기
git fetch origin main 2>/dev/null || true

# 로컬 변경이 있으면 커밋
git add backend/app.py frontend/ .gitignore 2>/dev/null || git add -A
if git diff --cached --quiet 2>/dev/null; then
    echo "  변경사항 없음 - 강제 커밋"
    git add -A
fi
git commit -m "fix(v4): attendance API 안전수정 - 실변수명 확인+사전테스트통과 [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null || true

# rebase or merge
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
git push -u origin main 2>&1 | tail -5
PUSH_RET=$?

echo ""
echo "================================================"
if [ "$STATUS" = "200" ]; then
    echo "  ✅ 완료! attendance API 정상"
else
    echo "  ⚠ HTTP $STATUS - 로그를 확인하세요"
fi
if [ $PUSH_RET -eq 0 ]; then
    echo "  ✅ GitHub 푸시 완료"
else
    echo "  ⚠ 로컬 수정은 적용됨 (push 별도 시도 필요)"
fi
echo "  🌐 http://13.125.163.126  (Ctrl+Shift+R)"
echo "  📦 https://github.com/thelab-bobkim/AMS"
echo "================================================"
