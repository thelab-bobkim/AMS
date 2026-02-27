#!/bin/bash
# ============================================================
# AMS fix_v5.sh - 단순·강건 버전
# 핵심 수정: attendance_records → all_records (1줄)
# ============================================================

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"
APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
TMP="/tmp/app_v5.py"

echo "================================================"
echo " AMS fix_v5 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "================================================"

# ── STEP 1: 컨테이너 app.py 추출 ──────────────────
echo ""
echo "[1] 컨테이너 app.py 추출"
docker cp attendance-backend:/app/app.py "$TMP"
echo "    완료 ($(wc -l < "$TMP")줄)"

# ── STEP 2: 버그 위치 출력 ────────────────────────
echo ""
echo "[2] 버그 확인"
echo "    쿼리 변수명:"
grep -n "all_records\s*=" "$TMP" || true
echo "    for rec in:"
grep -n "for rec in" "$TMP" || true

# ── STEP 3: 단 1줄 수정 ──────────────────────────
echo ""
echo "[3] 수정: attendance_records → all_records"
sed 's/for rec in attendance_records:/for rec in all_records:/g' "$TMP" > "${TMP}.fixed"
mv "${TMP}.fixed" "$TMP"
echo "    수정 후 for rec in:"
grep -n "for rec in" "$TMP" || true

# ── STEP 4: 컨테이너 내부 사전 테스트 ───────────
echo ""
echo "[4] 컨테이너 내부 사전 테스트"
docker cp "$TMP" attendance-backend:/app/app_test.py

docker exec attendance-backend python3 << 'PYEOF'
import sys, json, calendar, traceback
sys.path.insert(0, '/app')

# 구문 검사
with open('/app/app_test.py') as f:
    src = f.read()
try:
    compile(src, 'test', 'exec')
    print('    [OK] 구문 검사 통과')
except SyntaxError as e:
    print('    [FAIL] 구문 오류: ' + str(e))
    sys.exit(1)

# 변수명 확인
import re
lines = src.splitlines()
rm_line = None
for i, ln in enumerate(lines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        rm_line = i
        break

if rm_line is not None:
    query_var = None
    for i in range(max(0, rm_line-20), rm_line):
        m = re.match(r'\s+(\w+)\s*=\s*AttendanceRecord\.query', lines[i])
        if m:
            query_var = m.group(1)
            print('    [OK] 쿼리 변수: ' + query_var)
            break
    for i in range(rm_line, min(rm_line+5, len(lines))):
        m = re.match(r'\s+for\s+rec\s+in\s+(\w+)', lines[i])
        if m:
            for_var = m.group(1)
            if query_var and for_var != query_var:
                print('    [FAIL] 변수 불일치: for_var=' + for_var + ' query_var=' + query_var)
                sys.exit(1)
            print('    [OK] for rec in ' + for_var + ' - 일치!')
            break

# 로직 검사
try:
    import importlib.util
    import datetime as _dt
    spec = importlib.util.spec_from_file_location('app_t', '/app/app_test.py')
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    with mod.app.app_context():
        emps = mod.Employee.query.filter_by(is_active=True).limit(3).all()
        print('    [OK] 직원: ' + str(len(emps)) + '명')
        s = _dt.date(2026, 2, 1)
        e = _dt.date(2026, 2, 28)
        recs = mod.AttendanceRecord.query.filter(
            mod.AttendanceRecord.employee_id.in_([x.id for x in emps]),
            mod.AttendanceRecord.date.between(s, e)
        ).limit(20).all()
        print('    [OK] 출석레코드: ' + str(len(recs)) + '건')
        record_map = {}
        for rec in recs:
            try:
                cin = rec.check_in_time.strftime('%H:%M') if rec.check_in_time else ''
            except Exception:
                cin = str(rec.check_in_time)[:5] if rec.check_in_time else ''
            record_map.setdefault(rec.employee_id, {})[str(rec.date.day)] = {
                'check_in': cin,
                'type':   rec.record_type  or 'normal',
                'note':   rec.note         or '',
                'source': rec.data_source  or 'manual'
            }
        result = []
        for emp in emps:
            result.append({
                'id':         emp.id,
                'name':       emp.name       or '',
                'department': emp.department or '',
                'days':       record_map.get(emp.id, {})
            })
        j = json.dumps(result, ensure_ascii=False)
        print('    [OK] JSON 직렬화 성공: ' + str(len(result)) + '건')
        if result:
            r0 = result[0]
            print('    [OK] 샘플: ' + r0['name'] + ' / ' + r0['department'])
except Exception as ex:
    print('    [FAIL] 로직 오류: ' + str(ex))
    traceback.print_exc()
    sys.exit(1)

print('    [OK] 사전 테스트 완전 통과!')
PYEOF

TEST_RET=$?
docker exec attendance-backend rm -f /app/app_test.py 2>/dev/null || true

if [ $TEST_RET -ne 0 ]; then
    echo "    [ABORT] 사전 테스트 실패 - 배포 중단"
    exit 1
fi
echo "    사전 테스트 통과 - 배포 진행"

# ── STEP 5: 호스트 파일 교체 + 컨테이너 배포 ─────
echo ""
echo "[5] 배포"
cp "$BACKEND" "${BACKEND}.bak_v5" 2>/dev/null || true
cp "$TMP" "$BACKEND"
docker cp "$BACKEND" attendance-backend:/app/app.py
docker restart attendance-backend
echo "    재시작 완료. 20초 대기..."
sleep 20

# ── STEP 6: HTTP 검증 ─────────────────────────────
echo ""
echo "[6] HTTP 검증"
HTTP_FULL=$(curl -s -w "\nHTTP_CODE:%{http_code}" "http://localhost:5000/api/attendance?year=2026&month=2")
STATUS=$(echo "$HTTP_FULL" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$HTTP_FULL" | grep -v "HTTP_CODE:")

echo "    HTTP 상태: $STATUS"

echo "$BODY" | python3 << 'PYEOF'
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print('    [FAIL] 빈 응답')
    sys.exit(0)
try:
    d = json.loads(raw)
    items = d if isinstance(d, list) else d.get('data', [])
    print('    [OK] 직원 수: ' + str(len(items)) + '명')
    if items:
        f = items[0]
        ok = all(k in f for k in ['id', 'name', 'department', 'days'])
        print('    [OK] 필드: ' + str(list(f.keys())))
        print('    [OK] 검증: ' + ('PASS' if ok else 'FAIL'))
        print('    [OK] 이름: ' + str(f.get('name', '?')) + ' / 부서: ' + str(f.get('department', '?')))
        days = f.get('days', {})
        print('    [OK] 출근 일수: ' + str(len(days)) + '일')
        if days:
            day, rec = next(iter(days.items()))
            print('    [OK] 출근 샘플: ' + str(day) + '일 -> ' + str(rec))
except Exception as ex:
    print('    [FAIL] 파싱 오류: ' + str(ex))
    print('    응답: ' + raw[:200])
PYEOF

if [ "$STATUS" != "200" ]; then
    echo "    Docker 에러 로그:"
    docker logs attendance-backend --tail=25 2>&1 | grep -E "(Error|NameError|Traceback|500)" | tail -15 || true
fi

EMP_S=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5000/api/employees")
echo "    employees API: HTTP $EMP_S"

# ── STEP 7: GitHub 푸시 ───────────────────────────
echo ""
echo "[7] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git fetch origin main 2>/dev/null || true
git add backend/app.py
git commit -m "fix(v5): attendance_records to all_records variable fix [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null || true
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
git push -u origin main 2>&1 | tail -3
PUSH_RET=$?

echo ""
echo "================================================"
if [ "$STATUS" = "200" ]; then
    echo "  [SUCCESS] attendance API 정상 작동!"
else
    echo "  [WARNING] HTTP $STATUS - 추가 확인 필요"
fi
if [ $PUSH_RET -eq 0 ]; then
    echo "  [SUCCESS] GitHub 푸시 완료"
else
    echo "  [WARNING] 로컬만 적용됨"
fi
echo "  URL: http://13.125.163.126  (Ctrl+Shift+R)"
echo "  GIT: https://github.com/thelab-bobkim/AMS"
echo "================================================"
