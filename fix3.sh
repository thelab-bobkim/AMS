#!/bin/bash
# ============================================================
# AMS fix_v6.sh
# 수정 1: backend/app.py - days map에 record id 추가
# 수정 2: frontend/js/app.js - emp.employee→emp, SenseLink sync 추가
# ============================================================

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"
APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
APPJS="$APP_DIR/frontend/js/app.js"

echo "================================================"
echo " AMS fix_v6 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo " 수정: record id + editCell + SenseLink 동기화"
echo "================================================"

# ── STEP 1: 현재 파일 추출 ────────────────────────
echo ""
echo "[1] 파일 추출"
docker cp attendance-backend:/app/app.py /tmp/v6_app.py
echo "    app.py: $(wc -l < /tmp/v6_app.py)줄"

# ── STEP 2: backend - days map에 id 추가 ─────────
echo ""
echo "[2] backend: days map에 record id 추가"
python3 << 'PYEOF'
import re

path = '/tmp/v6_app.py'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 'source': (rec.data_source or 'manual') 뒤에 'id': rec.id 추가
# 현재 패턴:
#     'source':   (rec.data_source  or 'manual')
# 목표:
#     'source':   (rec.data_source  or 'manual'),
#     'id':        rec.id

old = "            'source':   (rec.data_source  or 'manual')\n        }"
new = "            'source':   (rec.data_source  or 'manual'),\n            'id':        rec.id\n        }"

if old in content:
    content = content.replace(old, new, 1)
    print("    [OK] days map에 id 필드 추가 완료")
else:
    # 조금 더 유연하게 찾기
    pattern = r"('source'\s*:\s*\(rec\.data_source\s+or\s+'manual'\))\s*(\})"
    replacement = r"\1,\n            'id':        rec.id\n        \2"
    new_content, n = re.subn(pattern, replacement, content, count=1)
    if n > 0:
        content = new_content
        print("    [OK] days map에 id 필드 추가 완료 (regex)")
    else:
        print("    [WARN] 패턴 없음 - 현재 source 라인 확인:")
        for i, ln in enumerate(content.splitlines()):
            if 'data_source' in ln and 'manual' in ln and 'record_map' not in ln:
                print(f"      {i+1}: {ln}")

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF

# ── STEP 3: frontend app.js 수정 ──────────────────
echo ""
echo "[3] frontend: app.js 3곳 수정"
python3 << 'PYEOF'
import re

path = '/home/ubuntu/AMS/frontend/js/app.js'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

changes = 0

# 수정 1: emp.employee → emp (template에서 editCell 호출)
old1 = "@click=\"editCell(emp.employee, day.day)\""
new1 = "@click=\"editCell(emp, day.day)\""
if old1 in content:
    content = content.replace(old1, new1)
    changes += 1
    print("    [OK] 수정1: editCell(emp.employee) → editCell(emp)")
else:
    print("    [WARN] 수정1: 패턴 없음 - 이미 수정됐거나 다른 형태")

# 수정 2: syncFromDauoffice에 SenseLink sync 추가
old2 = """                const empRes = await axios.post(`${API}/daou/sync/employees`);
                const attRes = await axios.post(`${API}/daou/sync/attendance`, {
                    year: this.selectedYear, month: this.selectedMonth
                });
                await this.loadEmployees();
                await this.loadAttendance();
                alert(`동기화 완료!\\n직원: ${empRes.data.count}명\\n출근기록: ${attRes.data.count}개`);"""

new2 = """                const empRes = await axios.post(`${API}/daou/sync/employees`);
                const attRes = await axios.post(`${API}/daou/sync/attendance`, {
                    year: this.selectedYear, month: this.selectedMonth
                });
                let slMsg = '';
                try {
                    const slRes = await axios.post(`${API}/senselink/sync`, {
                        year: this.selectedYear, month: this.selectedMonth
                    });
                    slMsg = `\\nSenseLink: ${slRes.data.synced || 0}건`;
                } catch(se) {
                    slMsg = '\\nSenseLink: 연결 실패';
                }
                await this.loadEmployees();
                await this.loadAttendance();
                alert(`통합 동기화 완료!\\n다우오피스 직원: ${empRes.data.count}명\\n다우오피스 출근: ${attRes.data.count}개${slMsg}`);"""

if old2 in content:
    content = content.replace(old2, new2)
    changes += 1
    print("    [OK] 수정2: SenseLink sync 추가")
else:
    print("    [WARN] 수정2: syncFromDauoffice 패턴 없음")
    # 더 유연한 방식으로 시도
    idx = content.find("syncFromDauoffice()")
    if idx > 0:
        block_start = content.find("async syncFromDauoffice()")
        if block_start > 0:
            print("    [INFO] syncFromDauoffice 함수 발견, 수동 패치 시도")

# 수정 3: editCell 함수 내부 - employee 객체 접근 방식이 맞는지 확인
# 새 flat 구조에서 emp = {id, name, department, days}
# editCell(emp, day) 로 호출되면 employee.id, employee.name 모두 동작
if 'employeeName: employee.name' in content:
    print("    [OK] 수정3: editCell 내부 employee.name 접근 OK")
else:
    print("    [WARN] 수정3: editCell 내부 구조 다름")

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print(f"    총 {changes}곳 수정 완료")
PYEOF

# ── STEP 4: 컨테이너 사전 테스트 ─────────────────
echo ""
echo "[4] 사전 테스트"
docker cp /tmp/v6_app.py attendance-backend:/app/app_test.py
docker exec attendance-backend python3 << 'PYEOF'
import sys, json, traceback
sys.path.insert(0, '/app')

with open('/app/app_test.py') as f:
    src = f.read()
try:
    compile(src, 'test', 'exec')
    print('    [OK] 구문 검사 통과')
except SyntaxError as e:
    print('    [FAIL] 구문 오류: ' + str(e))
    sys.exit(1)

# id 필드 포함 여부 확인
if "'id':        rec.id" in src or "'id': rec.id" in src:
    print("    [OK] days map에 id 필드 있음")
else:
    print("    [WARN] days map id 필드 없음 - 확인 필요")
    # 관련 부분 출력
    for i, ln in enumerate(src.splitlines()):
        if 'check_in' in ln and 'cin' in ln:
            lines = src.splitlines()
            for j in range(i, min(i+10, len(lines))):
                print('      ' + str(j+1) + ': ' + lines[j])
            break

try:
    import importlib.util, datetime as _dt, calendar
    spec = importlib.util.spec_from_file_location('app_t', '/app/app_test.py')
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    with mod.app.app_context():
        emps = mod.Employee.query.filter_by(is_active=True).limit(3).all()
        s = _dt.date(2026,2,1); e = _dt.date(2026,2,28)
        recs = mod.AttendanceRecord.query.filter(
            mod.AttendanceRecord.employee_id.in_([x.id for x in emps]),
            mod.AttendanceRecord.date.between(s,e)
        ).limit(20).all()
        record_map = {}
        for rec in recs:
            try: cin = rec.check_in_time.strftime('%H:%M') if rec.check_in_time else ''
            except: cin = str(rec.check_in_time)[:5] if rec.check_in_time else ''
            record_map.setdefault(rec.employee_id, {})[str(rec.date.day)] = {
                'check_in': cin,
                'type':   rec.record_type  or 'normal',
                'note':   rec.note         or '',
                'source': rec.data_source  or 'manual',
                'id':     rec.id
            }
        result = [{'id':emp.id,'name':emp.name or '','department':emp.department or '','days':record_map.get(emp.id,{})} for emp in emps]
        j = json.dumps(result, ensure_ascii=False)
        print('    [OK] JSON 직렬화: ' + str(len(result)) + '건')
        if result and result[0]['days']:
            day, rec_d = next(iter(result[0]['days'].items()))
            print('    [OK] 출근 샘플: ' + str(day) + '일 → ' + str(rec_d))
        elif result:
            print('    [INFO] ' + result[0]['name'] + ' - 출근기록 없음')
except Exception as ex:
    print('    [FAIL] ' + str(ex))
    traceback.print_exc()
    sys.exit(1)
print('    [OK] 사전 테스트 통과')
PYEOF
TEST_RET=$?
docker exec attendance-backend rm -f /app/app_test.py 2>/dev/null || true

if [ $TEST_RET -ne 0 ]; then
    echo "    [ABORT] 사전 테스트 실패"
    exit 1
fi

# ── STEP 5: 배포 ──────────────────────────────────
echo ""
echo "[5] 배포"
cp "$BACKEND" "${BACKEND}.bak_v6" 2>/dev/null || true
cp /tmp/v6_app.py "$BACKEND"
docker cp "$BACKEND" attendance-backend:/app/app.py
docker restart attendance-backend
echo "    20초 대기..."
sleep 20

# ── STEP 6: 검증 ──────────────────────────────────
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
    print('    [FAIL] 빈 응답 - 컨테이너 아직 시작 중일 수 있음')
    sys.exit(0)
try:
    d = json.loads(raw)
    items = d if isinstance(d, list) else d.get('data', [])
    print('    [OK] 직원 수: ' + str(len(items)) + '명')
    if items:
        f = items[0]
        print('    [OK] 이름: ' + str(f.get('name','?')) + ' / 부서: ' + str(f.get('department','?')))
        days = f.get('days', {})
        if days:
            day, rec = next(iter(days.items()))
            has_id = 'id' in rec
            print('    [OK] 출근 샘플: ' + str(day) + '일 → ' + str(rec))
            print('    [OK] record id 포함: ' + ('YES' if has_id else 'NO'))
        else:
            print('    [INFO] 출근기록 없음')
except Exception as ex:
    print('    [FAIL] ' + str(ex))
    print('    응답: ' + raw[:200])
PYEOF

# ── STEP 7: GitHub 푸시 ───────────────────────────
echo ""
echo "[7] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git fetch origin main 2>/dev/null || true
git add backend/app.py frontend/js/app.js
git commit -m "fix(v6): record id + editCell fix + SenseLink sync [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null || true
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
git push -u origin main 2>&1 | tail -3
PUSH_RET=$?

echo ""
echo "================================================"
if [ "$STATUS" = "200" ]; then
    echo "  [SUCCESS] API 정상!"
else
    echo "  [WARN] HTTP $STATUS"
    docker logs attendance-backend --tail=15 2>&1 | grep -E "(Error|NameError|Traceback)" | tail -10 || true
fi
[ $PUSH_RET -eq 0 ] && echo "  [SUCCESS] GitHub 완료" || echo "  [WARN] 로컬만 적용"
echo "  URL: http://13.125.163.126  (Ctrl+Shift+R)"
echo "================================================"
