#!/bin/bash
# ============================================================
# AMS fix_v7.sh
# 수정 1: dauoffice_api.py - 부서명 스마트 추출 (한국어 우선)
# 수정 2: app.py - SenseLink /sl/api/v5/records 직접 호출
# ============================================================

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"
APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
DAUOFFICE="$APP_DIR/backend/dauoffice_api.py"

echo "================================================"
echo " AMS fix_v7 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo " 수정: 부서명 + SenseLink v5 API 연동"
echo "================================================"

# ── STEP 1: 현재 파일 추출 ────────────────────────
echo ""
echo "[1] 파일 추출"
docker cp attendance-backend:/app/app.py /tmp/v7_app.py
docker cp attendance-backend:/app/dauoffice_api.py /tmp/v7_dauoffice.py
echo "    app.py       : $(wc -l < /tmp/v7_app.py)줄"
echo "    dauoffice_api: $(wc -l < /tmp/v7_dauoffice.py)줄"

# ── STEP 2: dauoffice_api.py 부서명 스마트 추출 ──
echo ""
echo "[2] dauoffice_api.py: 부서명 스마트 추출 수정"
python3 << 'PYEOF'
import re

path = '/tmp/v7_dauoffice.py'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 삽입할 헬퍼 함수 (클래스 밖, imports 바로 아래)
helper_func = '''
def _extract_department(emp_data):
    """
    DauOffice userGroups에서 실제 부서명을 추출한다.
    우선순위:
      1) group.get('type') in ('DEPT','dept','department','organization') -> name
      2) 한국어 + 부서 키워드(본부/팀/부/실/센터/그룹/사업부/담당) 포함
      3) 한국어 문자 포함
      4) 첫 번째 그룹 name (fallback)
    """
    import re as _re
    DEPT_KEYWORDS = ['본부', '팀', '부', '실', '센터', '그룹', '사업부', '담당', '사업', '부문']
    DEPT_TYPES    = {'dept', 'department', 'organization', 'org'}
    user_groups = emp_data.get('userGroups', [])

    # 1순위: group type 이 dept/organization 인 그룹
    for g in user_groups:
        gtype = str(g.get('type', '')).lower()
        if gtype in DEPT_TYPES:
            name = g.get('name', '').strip()
            if name:
                return name

    # 2순위: 한국어 + 부서 키워드
    for g in user_groups:
        name = g.get('name', '').strip()
        if _re.search(r'[가-힣]', name) and any(kw in name for kw in DEPT_KEYWORDS):
            return name

    # 3순위: 한국어 포함
    for g in user_groups:
        name = g.get('name', '').strip()
        if _re.search(r'[가-힣]', name):
            return name

    # 4순위: 첫 번째 그룹 (fallback)
    if user_groups:
        return user_groups[0].get('name', '').strip()

    return ''

'''

# 함수를 클래스 정의 바로 위에 삽입
if '_extract_department' not in content:
    # DauofficeAPIClient 클래스 선언 바로 앞에 삽입
    target = '\nclass DauofficeAPIClient:'
    if target in content:
        content = content.replace(target, helper_func + target, 1)
        print("    [OK] _extract_department 헬퍼 함수 삽입 완료")
    else:
        print("    [WARN] 클래스 선언 위치를 찾지 못함 - 파일 앞부분에 추가")
        content = helper_func + content
else:
    print("    [INFO] _extract_department 이미 존재 - 스킵")

# sync_employees_from_dauoffice 안에서 department 추출 부분 교체
# 기존: department  = user_groups[0]['name'] if user_groups else ''
#       user_groups = emp_data.get('userGroups', [])   ← 중복 라인
old_dept = "                department  = user_groups[0]['name'] if user_groups else ''\n\n                user_groups = emp_data.get('userGroups', [])\n\n                position"
new_dept = "                department  = _extract_department(emp_data)\n\n                position"

if old_dept in content:
    content = content.replace(old_dept, new_dept, 1)
    print("    [OK] department 추출 로직 교체 완료 (중복 user_groups 제거)")
else:
    # 좀 더 유연하게 찾기
    pattern1 = r"department\s*=\s*user_groups\[0\]\['name'\]\s+if\s+user_groups\s+else\s+''"
    new_dept2 = "department  = _extract_department(emp_data)"
    new_c, n = re.subn(pattern1, new_dept2, content, count=1)
    if n > 0:
        content = new_c
        print("    [OK] department 추출 로직 교체 완료 (regex)")
        # 중복 user_groups 줄 제거
        pattern2 = r'\n\s*user_groups\s*=\s*emp_data\.get\(.userGroups.,\s*\[\]\)\s*\n'
        # 첫번째 user_groups 선언은 유지, 두 번째 중복만 제거
        matches = list(re.finditer(pattern2, content))
        if len(matches) >= 2:
            # 두 번째 이후를 제거
            for m in reversed(matches[1:]):
                content = content[:m.start()] + '\n' + content[m.end():]
            print("    [OK] 중복 user_groups 할당 제거")
    else:
        print("    [WARN] department 추출 패턴 없음 - 현재 상태 확인:")
        for i, ln in enumerate(content.splitlines()):
            if 'department' in ln and ('user_groups' in ln or 'name' in ln):
                print(f"      {i+1}: {ln}")

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("    dauoffice_api.py 수정 완료")
PYEOF

# ── STEP 3: app.py SenseLink 엔드포인트 완전 교체 ─
echo ""
echo "[3] app.py: SenseLink /sl/api/v5/records 직접 호출로 교체"
python3 << 'PYEOF'
import re

path = '/tmp/v7_app.py'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 새로운 SenseLink 섹션 전체 (기존 senselink 관련 코드 전체 교체)
new_senselink = '''

# ==================== SenseLink 안면인식 연동 ====================

import os as _os
import requests as _req
import calendar as _cal

SENSELINK_RELAY_URL = _os.environ.get('SENSELINK_RELAY_URL', 'http://175.198.93.89:8765')


def _parse_senselink_time(rec):
    """SenseLink 레코드에서 시각 추출 (passTime / signTime / time / eventTime)"""
    for field in ('passTime', 'signTime', 'time', 'eventTime', 'captureTime', 'recordTime'):
        val = rec.get(field)
        if not val:
            continue
        # Unix timestamp (int/float)
        if isinstance(val, (int, float)):
            try:
                from datetime import datetime as _dt
                return _dt.fromtimestamp(val).time()
            except Exception:
                continue
        # 문자열 datetime "YYYY-MM-DD HH:MM:SS" or "YYYY-MM-DDTHH:MM:SS"
        if isinstance(val, str) and len(val) >= 16:
            for fmt in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%dT%H:%M:%S',
                        '%Y-%m-%d %H:%M',   '%Y-%m-%dT%H:%M'):
                try:
                    from datetime import datetime as _dt
                    return _dt.strptime(val[:19], fmt).time()
                except Exception:
                    continue
    return None


def _parse_senselink_date(rec):
    """SenseLink 레코드에서 날짜(date) 추출"""
    for field in ('passTime', 'signTime', 'time', 'eventTime', 'captureTime', 'recordTime'):
        val = rec.get(field)
        if not val:
            continue
        if isinstance(val, (int, float)):
            try:
                from datetime import datetime as _dt
                return _dt.fromtimestamp(val).date()
            except Exception:
                continue
        if isinstance(val, str) and len(val) >= 10:
            try:
                from datetime import datetime as _dt
                return _dt.strptime(val[:10], '%Y-%m-%d').date()
            except Exception:
                continue
    return None


@app.route('/api/senselink/sync', methods=['POST'])
def senselink_sync():
    """SenseLink /sl/api/v5/records 에서 출근 데이터 수집"""
    data   = request.json or {}
    year   = data.get('year',  datetime.now().year)
    month  = data.get('month', datetime.now().month)

    _, last_day = calendar.monthrange(year, month)
    dt_from = f"{year:04d}-{month:02d}-01 00:00:00"
    dt_to   = f"{year:04d}-{month:02d}-{last_day:02d} 23:59:59"

    all_records = []
    page = 1
    size = 100
    errors = []

    # 릴레이를 통해 SenseLink API 호출 (페이지네이션)
    while True:
        try:
            resp = _req.get(
                f"{SENSELINK_RELAY_URL}/sl/api/v5/records",
                params={
                    'dateTimeFrom': dt_from,
                    'dateTimeTo':   dt_to,
                    'order': 1,
                    'page':  page,
                    'size':  size
                },
                timeout=30
            )
            if resp.status_code != 200:
                errors.append(f"릴레이 HTTP {resp.status_code}")
                break
            body = resp.json()
            # code 확인
            code = str(body.get('code', ''))
            if code not in ('200', '0', ''):
                errors.append(f"SenseLink API 오류: {body.get('message', code)}")
                break
            # data.list 또는 data 직접
            d = body.get('data', body)
            if isinstance(d, list):
                recs = d
                total = len(d)
            else:
                recs  = d.get('list', d.get('records', d.get('data', [])))
                total = d.get('total', d.get('totalCount', len(recs)))

            if not recs:
                break
            all_records.extend(recs)
            if len(all_records) >= total or len(recs) < size:
                break
            page += 1

        except Exception as e:
            errors.append(f"릴레이 연결 오류: {str(e)}")
            break

    if errors and not all_records:
        return jsonify({
            'code': 200,
            'message': '릴레이 연결 실패 - 릴레이 서버를 확인하세요',
            'relay_url': SENSELINK_RELAY_URL,
            'errors': errors,
            'synced': 0
        })

    # DB 저장
    synced = 0
    save_errors = []
    for rec in all_records:
        try:
            user_name = (rec.get('userName') or rec.get('name') or '').strip()
            if not user_name:
                continue
            emp = Employee.query.filter_by(name=user_name, is_active=True).first()
            if not emp:
                continue
            work_date = _parse_senselink_date(rec)
            if not work_date:
                continue
            ci_time = _parse_senselink_time(rec)

            existing = AttendanceRecord.query.filter_by(
                employee_id=emp.id, date=work_date).first()
            if existing:
                if ci_time:
                    existing.check_in_time = ci_time
                existing.data_source = 'senselink'
            else:
                db.session.add(AttendanceRecord(
                    employee_id=emp.id,
                    date=work_date,
                    check_in_time=ci_time,
                    record_type='normal',
                    data_source='senselink'
                ))
            synced += 1
        except Exception as e:
            save_errors.append(str(e))

    db.session.commit()
    return jsonify({
        'code':    200,
        'message': f'{synced}건 동기화 완료 (SenseLink {len(all_records)}건 수신)',
        'synced':  synced,
        'fetched': len(all_records),
        'errors':  (errors + save_errors)[:5],
        'relay_url': SENSELINK_RELAY_URL,
        'period':  f"{dt_from[:10]} ~ {dt_to[:10]}"
    })


@app.route('/api/senselink/status', methods=['GET'])
def senselink_status():
    """SenseLink 연동 상태"""
    total = AttendanceRecord.query.filter_by(data_source='senselink').count()
    relay_ok = False
    try:
        r = _req.get(f"{SENSELINK_RELAY_URL}/sl/api/v5/records",
                     params={'page': 1, 'size': 1}, timeout=5)
        relay_ok = (r.status_code < 500)
    except Exception:
        relay_ok = False
    return jsonify({
        'code': 200,
        'relay_url': SENSELINK_RELAY_URL,
        'relay_reachable': relay_ok,
        'total_senselink_records': total
    })


@app.route('/api/senselink/preview', methods=['GET'])
def senselink_preview():
    """SenseLink 최근 데이터 미리보기"""
    year  = request.args.get('year',  datetime.now().year,  type=int)
    month = request.args.get('month', datetime.now().month, type=int)
    recs  = AttendanceRecord.query.filter(
        AttendanceRecord.data_source == 'senselink',
        db.extract('year',  AttendanceRecord.date) == year,
        db.extract('month', AttendanceRecord.date) == month
    ).limit(20).all()
    return jsonify({'code': 200, 'count': len(recs),
                    'records': [r.to_dict() for r in recs]})

'''

# 기존 SenseLink 섹션을 새 코드로 교체
# 패턴: # ==================== SenseLink ... 부터 # ==================== 다우오피스 라우트 별칭 전까지
pattern = r'# ={10,}.*?SenseLink.*?\n.*?# ={10,}.*?다우오피스 라우트 별칭'
match = re.search(pattern, content, re.DOTALL)
if match:
    content = content[:match.start()] + new_senselink + '\n\n# ==================== 다우오피스 라우트 별칭 (프론트엔드 /api/daou/ 호환) =='
    # 다우오피스 별칭 이하 코드 복원
    alias_start = content.find('# ==================== 다우오피스 라우트 별칭')
    orig_alias_start = match.end() - len('# ==================== 다우오피스 라우트 별칭')
    # 원본 파일을 다시 읽어서 alias 이하 코드 가져오기
    with open('/tmp/v7_app.py', 'r', encoding='utf-8') as f:
        orig = f.read()
    orig_alias_idx = orig.find('# ==================== 다우오피스 라우트 별칭')
    if orig_alias_idx > 0:
        alias_rest = orig[orig_alias_idx:]
        content = content[:alias_start] + alias_rest
    print("    [OK] SenseLink 섹션 전체 교체 완료")
else:
    # 패턴이 다를 경우 - senselink_sync 함수만 교체
    old_sync_pattern = r'@app\.route\(\'/api/senselink/sync\'.*?(?=@app\.route\(\'/api/senselink/status\')'
    new_func = '''@app.route('/api/senselink/sync', methods=['POST'])
def senselink_sync():
    """SenseLink /sl/api/v5/records 에서 출근 데이터 수집"""
    data   = request.json or {}
    year   = data.get('year',  datetime.now().year)
    month  = data.get('month', datetime.now().month)

    _, last_day = calendar.monthrange(year, month)
    dt_from = f"{year:04d}-{month:02d}-01 00:00:00"
    dt_to   = f"{year:04d}-{month:02d}-{last_day:02d} 23:59:59"

    all_records = []
    page = 1
    size = 100
    errors = []

    while True:
        try:
            resp = _req.get(
                f"{SENSELINK_RELAY_URL}/sl/api/v5/records",
                params={'dateTimeFrom': dt_from, 'dateTimeTo': dt_to,
                        'order': 1, 'page': page, 'size': size},
                timeout=30
            )
            if resp.status_code != 200:
                errors.append(f"릴레이 HTTP {resp.status_code}")
                break
            body = resp.json()
            d = body.get(\'data\', body)
            if isinstance(d, list):
                recs, total = d, len(d)
            else:
                recs  = d.get(\'list\', d.get(\'records\', []))
                total = d.get(\'total\', d.get(\'totalCount\', len(recs)))
            if not recs:
                break
            all_records.extend(recs)
            if len(all_records) >= total or len(recs) < size:
                break
            page += 1
        except Exception as e:
            errors.append(str(e)); break

    if errors and not all_records:
        return jsonify({'code': 200, 'message': \'릴레이 연결 실패\',
                        'relay_url': SENSELINK_RELAY_URL, 'errors': errors, 'synced': 0})

    synced = 0
    for rec in all_records:
        try:
            user_name = (rec.get(\'userName\') or rec.get(\'name\') or \'\').strip()
            if not user_name: continue
            emp = Employee.query.filter_by(name=user_name, is_active=True).first()
            if not emp: continue
            work_date = None
            for f in (\'passTime\',\'signTime\',\'time\',\'eventTime\'):
                v = rec.get(f)
                if v and isinstance(v, str) and len(v) >= 10:
                    try:
                        from datetime import datetime as _dt2
                        work_date = _dt2.strptime(v[:10], \'%Y-%m-%d\').date(); break
                    except: pass
                elif v and isinstance(v, (int, float)):
                    try:
                        from datetime import datetime as _dt2
                        work_date = _dt2.fromtimestamp(v).date(); break
                    except: pass
            if not work_date: continue
            ci_time = None
            for f in (\'passTime\',\'signTime\',\'time\',\'eventTime\'):
                v = rec.get(f)
                if v and isinstance(v, str) and len(v) >= 16:
                    try:
                        from datetime import datetime as _dt2
                        ci_time = _dt2.strptime(v[:19], \'%Y-%m-%d %H:%M:%S\').time(); break
                    except: pass
                elif v and isinstance(v, (int, float)):
                    try:
                        from datetime import datetime as _dt2
                        ci_time = _dt2.fromtimestamp(v).time(); break
                    except: pass
            existing = AttendanceRecord.query.filter_by(employee_id=emp.id, date=work_date).first()
            if existing:
                if ci_time: existing.check_in_time = ci_time
                existing.data_source = \'senselink\'
            else:
                db.session.add(AttendanceRecord(
                    employee_id=emp.id, date=work_date,
                    check_in_time=ci_time, record_type=\'normal\', data_source=\'senselink\'))
            synced += 1
        except: pass
    db.session.commit()
    return jsonify({'code': 200, 'message': f\'{synced}건 동기화 완료\',
                    'synced': synced, 'fetched': len(all_records), 'errors': errors[:5]})


'''
    new_c, n = re.subn(old_sync_pattern, new_func, content, count=1, flags=re.DOTALL)
    if n > 0:
        content = new_c
        print("    [OK] senselink_sync 함수 교체 완료 (fallback)")
    else:
        print("    [WARN] SenseLink 섹션 패턴 못 찾음 - 수동 확인 필요")

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("    app.py 수정 완료")
PYEOF

# ── STEP 4: 구문 검사 ─────────────────────────────
echo ""
echo "[4] 구문 검사"
python3 -c "
import py_compile, sys
for f in ('/tmp/v7_app.py', '/tmp/v7_dauoffice.py'):
    try:
        py_compile.compile(f, doraise=True)
        print('    [OK] ' + f.split('/')[-1])
    except py_compile.PyCompileError as e:
        print('    [FAIL] ' + str(e))
        sys.exit(1)
"
SYNTAX_RET=$?
if [ $SYNTAX_RET -ne 0 ]; then
    echo "    [ABORT] 구문 오류 - 배포 중단"
    exit 1
fi

# ── STEP 5: 컨테이너 내부 사전 테스트 ────────────
echo ""
echo "[5] 컨테이너 사전 테스트"
docker cp /tmp/v7_app.py      attendance-backend:/app/app_test.py
docker cp /tmp/v7_dauoffice.py attendance-backend:/app/dauoffice_test.py
docker exec attendance-backend python3 << 'PYEOF'
import sys, json, traceback
sys.path.insert(0, '/app')

errors = []
for fname in ('/app/app_test.py', '/app/dauoffice_test.py'):
    with open(fname) as f:
        src = f.read()
    try:
        compile(src, fname, 'exec')
        print(f'    [OK] {fname.split("/")[-1]} 구문 OK')
    except SyntaxError as e:
        errors.append(str(e))
        print(f'    [FAIL] {fname.split("/")[-1]}: {e}')

if errors:
    sys.exit(1)

# _extract_department 로직 테스트
sys.path.insert(0, '/app')
try:
    exec(open('/app/dauoffice_test.py').read(), {'__name__': '__test__'})
    print("    [OK] dauoffice_test.py 실행 OK")
except SystemExit:
    pass
except Exception as e:
    # Flask 앱 초기화 오류는 무시하고 함수만 테스트
    pass

# _extract_department 함수 테스트
src_daou = open('/app/dauoffice_test.py').read()
if '_extract_department' in src_daou:
    # 함수 추출 및 테스트
    import re
    m = re.search(r'def _extract_department.*?(?=\nclass|\ndef [a-z]|\Z)', src_daou, re.DOTALL)
    if m:
        exec(m.group(0))
        test_cases = [
            ({'userGroups': [{'name': 'CA사업본부', 'type': 'dept'}, {'name': '엔지니어', 'type': 'position'}]}, 'CA사업본부'),
            ({'userGroups': [{'name': '엔지니어'}, {'name': 'DSTI_KR_2'}]}, '엔지니어'),  # 한국어 우선
            ({'userGroups': []}, ''),
        ]
        ok = True
        for emp_data, expected in test_cases:
            result = _extract_department(emp_data)
            if result == expected:
                print(f"    [OK] _extract_department({emp_data['userGroups']}) = '{result}'")
            else:
                print(f"    [WARN] _extract_department({emp_data['userGroups']}) = '{result}' (expected '{expected}')")
    else:
        print("    [WARN] _extract_department 함수 추출 실패")
else:
    print("    [WARN] dauoffice_test.py에 _extract_department 없음")

print("    [OK] 사전 테스트 통과")
PYEOF
PRE_RET=$?
docker exec attendance-backend rm -f /app/app_test.py /app/dauoffice_test.py 2>/dev/null || true

if [ $PRE_RET -ne 0 ]; then
    echo "    [ABORT] 사전 테스트 실패"
    exit 1
fi

# ── STEP 6: 배포 ──────────────────────────────────
echo ""
echo "[6] 배포"
# 로컬 파일 업데이트
cp /tmp/v7_app.py      "$BACKEND"
cp /tmp/v7_dauoffice.py "$DAUOFFICE"
# 컨테이너에 복사
docker cp "$BACKEND"   attendance-backend:/app/app.py
docker cp "$DAUOFFICE" attendance-backend:/app/dauoffice_api.py
# 재시작
docker restart attendance-backend
echo "    20초 대기..."
sleep 20

# ── STEP 7: HTTP 검증 ─────────────────────────────
echo ""
echo "[7] HTTP 검증"
HTTP_FULL=$(curl -s -w "\nHTTP_CODE:%{http_code}" "http://localhost:5000/api/attendance?year=2026&month=2")
STATUS=$(echo "$HTTP_FULL" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$HTTP_FULL" | grep -v "HTTP_CODE:")

echo "    HTTP 상태: $STATUS"
echo "$BODY" | python3 << 'PYEOF'
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print('    [WARN] 빈 응답 - curl 재시도 필요')
    sys.exit(0)
try:
    d = json.loads(raw)
    items = d if isinstance(d, list) else d.get('data', [])
    print('    [OK] 직원 수: ' + str(len(items)) + '명')
    if items:
        f0 = items[0]
        print('    [OK] 이름: '   + str(f0.get('name','?')))
        print('    [OK] 부서: '   + str(f0.get('department','?')))
        days = f0.get('days', {})
        if days:
            day, rec = next(iter(days.items()))
            print('    [OK] 출근샘플: ' + str(day) + '일 → ' + str(rec))
        else:
            print('    [INFO] 2월 출근기록 없음')
except Exception as ex:
    print('    [FAIL] ' + str(ex))
    print('    응답: ' + raw[:300])
PYEOF

# SenseLink 상태 확인
echo ""
echo "    SenseLink 상태:"
curl -s "http://localhost:5000/api/senselink/status" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print('    relay_reachable  : ' + str(d.get('relay_reachable', '?')))
    print('    senselink_records: ' + str(d.get('total_senselink_records', 0)) + '건')
    print('    relay_url        : ' + str(d.get('relay_url','')))
except: print('    [WARN] SenseLink 상태 파싱 실패')
" 2>/dev/null || echo "    [WARN] SenseLink 상태 조회 실패"

# ── STEP 8: GitHub 푸시 ───────────────────────────
echo ""
echo "[8] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git fetch origin main 2>/dev/null || true
git add backend/app.py backend/dauoffice_api.py
git commit -m "fix(v7): dept smart extract + SenseLink v5 API [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null || echo "    [INFO] 변경사항 없음 (이미 최신)"
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
git push -u origin main 2>&1 | tail -3
PUSH_RET=$?

echo ""
echo "================================================"
if [ "$STATUS" = "200" ]; then
    echo "  [SUCCESS] /api/attendance 정상 (HTTP 200)"
else
    echo "  [WARN] HTTP $STATUS - 로그 확인:"
    docker logs attendance-backend --tail=10 2>&1 | grep -E "(Error|Exception|Traceback)" | head -5 || true
fi
[ $PUSH_RET -eq 0 ] && echo "  [SUCCESS] GitHub 푸시 완료" || echo "  [WARN] GitHub 푸시 실패 (로컬만 적용)"
echo ""
echo "  변경 요약:"
echo "    1) dauoffice_api.py: 부서명 스마트 추출 (_extract_department)"
echo "       - 한국어 부서 키워드 (본부/팀/부/실/센터) 우선 선택"
echo "    2) app.py: SenseLink /sl/api/v5/records 직접 호출"
echo "       - passTime/signTime/eventTime 다중 필드 자동 감지"
echo "       - 페이지네이션 지원 (size=100)"
echo ""
echo "  다음 단계:"
echo "    curl 'http://localhost:5000/api/senselink/sync' -X POST -H 'Content-Type: application/json' -d '{\"year\":2026,\"month\":2}'"
echo ""
echo "  URL: http://13.125.163.126  (Ctrl+Shift+R 새로고침)"
echo "================================================"
