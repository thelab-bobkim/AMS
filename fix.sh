#!/bin/bash
# ============================================================
# AMS fix_final.sh
# 원인: all_records 로 쿼리했으나 for rec in attendance_records 로 잘못 참조
# 수정: attendance_records → all_records (단 1줄 변경)
# ============================================================
set -euo pipefail

APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"

echo "================================================"
echo " AMS fix_final ($(date '+%Y-%m-%d %H:%M:%S'))"
echo " 버그: attendance_records → all_records 변수명 오류"
echo "================================================"

# ──────────────────────────────────────────────
# STEP 1: 컨테이너에서 현재 app.py 추출
# ──────────────────────────────────────────────
echo ""
echo "[STEP 1] 컨테이너에서 app.py 추출"
docker cp attendance-backend:/app/app.py /tmp/app_live.py
echo "  완료 ($(wc -l < /tmp/app_live.py)줄)"

# ──────────────────────────────────────────────
# STEP 2: 버그 확인
# ──────────────────────────────────────────────
echo ""
echo "[STEP 2] 버그 확인"
echo "  쿼리 변수명:"
grep -n "all_records\s*=" /tmp/app_live.py | head -5 || echo "  (없음)"
echo "  for rec in 변수:"
grep -n "for rec in" /tmp/app_live.py | head -5
echo "  record_map 블록:"
grep -n "record_map\|for rec in\|attendance_records\|all_records" /tmp/app_live.py | head -10

# ──────────────────────────────────────────────
# STEP 3: 단 한 줄 수정 (attendance_records → all_records)
# ──────────────────────────────────────────────
echo ""
echo "[STEP 3] 수정 적용"
cp /tmp/app_live.py /tmp/app_live.py.bak

# 정확한 줄 수정
sed -i 's/for rec in attendance_records:/for rec in all_records:/g' /tmp/app_live.py
CHANGED=$(diff /tmp/app_live.py.bak /tmp/app_live.py | grep "^[<>]" | wc -l)
echo "  변경된 줄 수: $CHANGED"

if [ "$CHANGED" -eq 0 ]; then
    echo ""
    echo "  ⚠ 'attendance_records' 없음 - 현재 for rec in 확인:"
    grep -n "for rec in" /tmp/app_live.py
    echo ""
    echo "  다른 패턴 시도..."
    # 혹시 다른 이름일 경우: for rec in (xxx): 에서 xxx가 all_records가 아닌 것
    python3 - << 'PYEOF'
import re

with open('/tmp/app_live.py', 'r') as f:
    lines = f.readlines()

# record_map 블록 찾기
rm_line = None
for i, ln in enumerate(lines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        rm_line = i
        break

if rm_line is None:
    print("  ❌ record_map 없음")
    exit(1)

print(f"  record_map: {rm_line+1}줄")

# record_map 앞 5줄에서 쿼리 변수명 탐색
query_var = None
for i in range(max(0, rm_line-15), rm_line):
    m = re.match(r'\s+(\w+)\s*=\s*AttendanceRecord\.query', lines[i])
    if m:
        query_var = m.group(1)
        print(f"  쿼리 변수명: '{query_var}' ({i+1}줄)")
        break

# for rec in <xxx> 찾기
for_var = None
for i in range(rm_line, rm_line+5):
    m = re.match(r'\s+for\s+rec\s+in\s+(\w+)', lines[i])
    if m:
        for_var = m.group(1)
        print(f"  for rec in '{for_var}' ({i+1}줄)")
        break

if query_var and for_var and query_var != for_var:
    print(f"\n  ❌ 불일치! '{for_var}' → '{query_var}' 로 교체")
    new_lines = []
    for ln in lines:
        new_lines.append(ln.replace(f'for rec in {for_var}:', f'for rec in {query_var}:'))
    with open('/tmp/app_live.py', 'w') as f:
        f.writelines(new_lines)
    print("  ✅ 교체 완료")
elif query_var == for_var:
    print(f"\n  ✅ 변수명 일치 ({query_var}) - 다른 원인 확인 필요")
else:
    print("\n  ⚠ 변수 탐색 실패")
PYEOF
fi

# ──────────────────────────────────────────────
# STEP 4: 컨테이너 내부에서 Python 구문 + 로직 사전 검증
# ──────────────────────────────────────────────
echo ""
echo "[STEP 4] 컨테이너 내부 사전 검증"
docker cp /tmp/app_live.py attendance-backend:/app/app_candidate.py

docker exec attendance-backend python3 - << 'PYEOF'
import sys, json, calendar, traceback, os

# 1) 구문 검사
with open('/app/app_candidate.py', 'r') as f:
    src = f.read()
try:
    compile(src, 'app_candidate.py', 'exec')
    print("  [✓] 구문 검사 OK")
except SyntaxError as e:
    print(f"  [❌] 구문 오류: {e}")
    sys.exit(1)

# 2) 변수명 확인
import re
lines = src.splitlines()
rm_line = None
for i, ln in enumerate(lines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        rm_line = i
        break

if rm_line is not None:
    # 앞 15줄에서 쿼리 변수명 찾기
    for i in range(max(0, rm_line-15), rm_line):
        m = re.match(r'\s+(\w+)\s*=\s*AttendanceRecord\.query', lines[i])
        if m:
            query_var = m.group(1)
            print(f"  [✓] 쿼리 변수: '{query_var}'")
            break
    # for rec in 확인
    for i in range(rm_line, rm_line+5):
        m = re.match(r'\s+for\s+rec\s+in\s+(\w+)', lines[i])
        if m:
            for_var = m.group(1)
            status = "✓" if for_var == query_var else "❌"
            print(f"  [{status}] for rec in '{for_var}' {'← 일치!' if for_var == query_var else f'← 불일치! (query: {query_var})'}")
            if for_var != query_var:
                sys.exit(1)
            break

# 3) 실제 로직 검증
try:
    import importlib.util
    spec = importlib.util.spec_from_file_location("app_c", "/app/app_candidate.py")
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    with mod.app.app_context():
        import datetime as _dt
        year, month = 2026, 2
        start_date = _dt.date(year, month, 1)
        _, last_day = calendar.monthrange(year, month)
        end_date   = _dt.date(year, month, last_day)

        employees = mod.Employee.query.filter_by(is_active=True).limit(5).all()
        print(f"  [✓] 직원 수: {len(employees)}명")

        emp_ids = [e.id for e in employees]
        all_records = mod.AttendanceRecord.query.filter(
            mod.AttendanceRecord.employee_id.in_(emp_ids),
            mod.AttendanceRecord.date >= start_date,
            mod.AttendanceRecord.date <= end_date
        ).limit(20).all()
        print(f"  [✓] 출석 레코드: {len(all_records)}건")

        record_map = {}
        for rec in all_records:
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

        serialized = json.dumps(result, ensure_ascii=False)
        print(f"  [✓] JSON 직렬화 OK: {len(result)}건")
        if result:
            r0 = result[0]
            print(f"  [✓] 샘플: 이름={r0['name']}, 부서={r0['department']}, 출근일수={len(r0['days'])}")

except Exception as e:
    print(f"  [❌] 로직 오류: {e}")
    traceback.print_exc()
    sys.exit(1)

print("  [✓] 사전 검증 완전 통과!")
PYEOF

PRETEST=$?
docker exec attendance-backend rm -f /app/app_candidate.py 2>/dev/null || true

if [ $PRETEST -ne 0 ]; then
    echo ""
    echo "  ❌ 사전 검증 실패 - 배포 중단"
    exit 1
fi
echo "  [✓] 사전 검증 통과 - 배포 진행"

# ──────────────────────────────────────────────
# STEP 5: 실제 배포
# ──────────────────────────────────────────────
echo ""
echo "[STEP 5] 배포"
cp "$BACKEND" "${BACKEND}.bak_final" 2>/dev/null || true
cp /tmp/app_live.py "$BACKEND"
docker cp "$BACKEND" attendance-backend:/app/app.py
docker restart attendance-backend
echo "  재시작 완료. 20초 대기..."
sleep 20

# ──────────────────────────────────────────────
# STEP 6: HTTP 검증
# ──────────────────────────────────────────────
echo ""
echo "[STEP 6] HTTP 검증"
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
        f0 = items[0]
        keys = list(f0.keys())
        ok   = all(k in f0 for k in ['id','name','department','days'])
        print(f"  ✅ 필드: {keys}")
        print(f"  ✅ 구조 검증: {'OK' if ok else 'FAIL'}")
        print(f"  ✅ 이름: {f0.get('name','?')} / 부서: {f0.get('department','?')}")
        days = f0.get('days', {})
        print(f"  ✅ 출근 일수: {len(days)}일")
        if days:
            day, rec = next(iter(days.items()))
            print(f"  ✅ 출근 샘플: {day}일 → {rec}")
except Exception as e:
    print(f"  ❌ 파싱 오류: {e}")
    print(f"  응답 앞 300자: {raw[:300]}")
PYEOF
else
    echo "  ❌ HTTP $STATUS"
    echo "  응답: $(echo "$BODY" | head -c 300)"
    echo ""
    echo "  Docker 최근 로그:"
    docker logs attendance-backend --tail=30 2>&1 | grep -E "(Error|Traceback|NameError|500)" | tail -15
fi

# employees 확인
EMP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5000/api/employees")
echo "  employees: HTTP $EMP"

# ──────────────────────────────────────────────
# STEP 7: GitHub 푸시
# ──────────────────────────────────────────────
echo ""
echo "[STEP 7] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

git fetch origin main 2>/dev/null || true
git add backend/app.py
git diff --cached --quiet 2>/dev/null || \
    git commit -m "fix(final): attendance_records → all_records 변수명 오류 수정 [$(date '+%Y-%m-%d %H:%M')]"
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
PUSH_OUT=$(git push -u origin main 2>&1); PUSH_RET=$?
echo "  $PUSH_OUT" | tail -3

echo ""
echo "================================================"
if [ "$STATUS" = "200" ]; then
    echo "  ✅ 완료! attendance API 정상 작동"
else
    echo "  ⚠ HTTP $STATUS - 추가 확인 필요"
fi
if [ $PUSH_RET -eq 0 ]; then
    echo "  ✅ GitHub 푸시 완료"
fi
echo "  🌐 http://13.125.163.126  (Ctrl+Shift+R)"
echo "  📦 https://github.com/thelab-bobkim/AMS"
echo "================================================"
