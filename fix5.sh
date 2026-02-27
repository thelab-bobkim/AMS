#!/bin/bash
# ============================================================
# AMS fix_v8.sh
# 수정: SenseLink relay /attendance 엔드포인트 연동
#   - user_name, sign_time_str 필드 사용
#   - type="1" 직원만, device_direction="0" 입장만
#   - 하루 중 최초 입장 시각 = 출근시각
#   - ngrok URL 환경변수 적용
# ============================================================

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"
APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
NGROK_URL="${NGROK_URL:-https://luke-subfestive-phyliss.ngrok-free.dev}"

echo "================================================"
echo " AMS fix_v8 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo " relay URL: $NGROK_URL"
echo "================================================"

# ── STEP 1: .env에 relay URL 적용 ─────────────────
echo ""
echo "[1] SENSELINK_RELAY_URL 설정"
ENV_FILE="$APP_DIR/backend/.env"
if [ -f "$ENV_FILE" ]; then
    if grep -q "SENSELINK_RELAY_URL" "$ENV_FILE"; then
        sed -i "s|SENSELINK_RELAY_URL=.*|SENSELINK_RELAY_URL=$NGROK_URL|" "$ENV_FILE"
        echo "    [OK] .env 업데이트"
    else
        echo "SENSELINK_RELAY_URL=$NGROK_URL" >> "$ENV_FILE"
        echo "    [OK] .env 추가"
    fi
else
    echo "SENSELINK_RELAY_URL=$NGROK_URL" > "$ENV_FILE"
    echo "    [OK] .env 생성"
fi
cat "$ENV_FILE" | grep SENSELINK

# ── STEP 2: app.py 추출 ───────────────────────────
echo ""
echo "[2] app.py 추출"
docker cp attendance-backend:/app/app.py /tmp/v8_app.py
echo "    $(wc -l < /tmp/v8_app.py)줄"

# ── STEP 3: senselink_sync 완전 교체 ─────────────
echo ""
echo "[3] senselink_sync 교체 (relay /attendance 방식)"
python3 << 'PYEOF'
import re

path = '/tmp/v8_app.py'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 새 SenseLink 섹션
NEW_SENSELINK = '''
# ==================== SenseLink 안면인식 연동 ====================

import os as _os
import requests as _req
import calendar as _cal
from collections import defaultdict as _defaultdict

SENSELINK_RELAY_URL = _os.environ.get('SENSELINK_RELAY_URL', 'http://175.198.93.89:8765')


@app.route('/api/senselink/sync', methods=['POST'])
def senselink_sync():
    """SenseLink relay /attendance 에서 출근 데이터 수집
    
    relay 응답 필드:
      user_name      : 직원명
      sign_time_str  : "YYYY-MM-DD HH:MM:SS"
      type           : "1"=직원, "3"=기타
      device_direction: "0"=입장, "1"=퇴장
    로직: type="1" + 하루 중 최초 sign_time_str = 출근시각
    """
    data  = request.json or {}
    year  = data.get('year',  datetime.now().year)
    month = data.get('month', datetime.now().month)

    date_prefix  = f"{year:04d}-{month:02d}-"
    cutoff_start = f"{year:04d}-{month:02d}-01"
    _, last_d    = calendar.monthrange(year, month)
    cutoff_end   = f"{year:04d}-{month:02d}-{last_d:02d} 23:59:59"

    HEADERS = {
        'ngrok-skip-browser-warning': 'true',
        'User-Agent': 'AMS-Server/1.0'
    }

    all_recs = []
    page = 1
    size = 100
    errors = []
    pages_fetched = 0
    MAX_PAGES = 200  # 최대 200페이지 (2만 건) 방어

    while pages_fetched < MAX_PAGES:
        try:
            resp = _req.get(
                f"{SENSELINK_RELAY_URL}/attendance",
                params={
                    'page': page, 'size': size,
                    'year': year, 'month': month,
                    'start': cutoff_start[:10],
                    'end':   cutoff_end[:10]
                },
                headers=HEADERS,
                timeout=30
            )
            if resp.status_code != 200:
                errors.append(f"relay HTTP {resp.status_code}")
                break

            body = resp.json()
            raw  = body.get('data', body)
            recs = raw if isinstance(raw, list) else []
            total = body.get('total', 0)

            pages_fetched += 1

            if not recs:
                break

            # 해당 월 레코드만 수집
            for r in recs:
                st = r.get('sign_time_str', '')
                if st.startswith(date_prefix):
                    all_recs.append(r)

            # 마지막 레코드 시각이 목표 월보다 이전이면 중단 (내림차순 정렬 가정)
            oldest_sign = min((r.get('sign_time_str','') for r in recs), default='')
            if oldest_sign and oldest_sign < cutoff_start:
                break

            if page * size >= total:
                break
            page += 1

        except Exception as e:
            errors.append(str(e))
            break

    # ── 하루 최초 입장 기록 선택 ──────────────────
    # key: (user_name, date_str "YYYY-MM-DD")
    # type="1" 직원만, device_direction="0" 입장 우선
    best: dict = {}   # key → 최조 sign_time_str 레코드

    for rec in all_recs:
        uname = (rec.get('user_name') or '').strip()
        stime = rec.get('sign_time_str', '')
        rtype = str(rec.get('type', ''))

        if not uname or not stime or rtype != '1':
            continue
        if not stime.startswith(date_prefix):
            continue

        dkey = stime[:10]
        key  = (uname, dkey)

        direction = str(rec.get('device_direction', '0'))
        cur_best  = best.get(key)

        if cur_best is None:
            best[key] = rec
        else:
            # 입장(0) 레코드 우선 선택, 같은 direction이면 더 이른 시각
            cur_dir = str(cur_best.get('device_direction', '0'))
            if direction == '0' and cur_dir != '0':
                best[key] = rec
            elif direction == cur_dir and stime < cur_best.get('sign_time_str', ''):
                best[key] = rec

    # ── DB 저장 ───────────────────────────────────
    synced, save_errors = 0, []
    for (uname, dkey), rec in best.items():
        try:
            emp = Employee.query.filter_by(name=uname, is_active=True).first()
            if not emp:
                continue
            work_date = datetime.strptime(dkey, '%Y-%m-%d').date()
            stime     = rec.get('sign_time_str', '')
            ci_time   = None
            if len(stime) >= 19:
                ci_time = datetime.strptime(stime[:19], '%Y-%m-%d %H:%M:%S').time()

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
        'message': f'{synced}건 동기화 완료',
        'synced':  synced,
        'fetched': len(all_recs),
        'pages':   pages_fetched,
        'total_relay': body.get('total', 0) if 'body' in dir() else 0,
        'relay_url': SENSELINK_RELAY_URL,
        'period':  f"{date_prefix}01 ~ {date_prefix}{last_d:02d}",
        'errors':  (errors + save_errors)[:5]
    })


@app.route('/api/senselink/status', methods=['GET'])
def senselink_status():
    """SenseLink 연동 상태 + relay 연결 확인"""
    total = AttendanceRecord.query.filter_by(data_source='senselink').count()
    relay_ok = False
    relay_msg = ''
    try:
        r = _req.get(
            f"{SENSELINK_RELAY_URL}/attendance",
            params={'page': 1, 'size': 1},
            headers={'ngrok-skip-browser-warning': 'true'},
            timeout=5
        )
        relay_ok  = (r.status_code == 200)
        relay_msg = f"HTTP {r.status_code}"
        if relay_ok:
            d = r.json()
            relay_msg += f", total={d.get('total', '?')}"
    except Exception as e:
        relay_msg = str(e)[:80]

    return jsonify({
        'code': 200,
        'relay_url':      SENSELINK_RELAY_URL,
        'relay_reachable': relay_ok,
        'relay_status':   relay_msg,
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

# 기존 SenseLink 섹션 전체 교체
# 시작: # ={10,} SenseLink
# 끝:   # ={10,} 다우오피스 라우트 별칭
pattern = r'(# =+[^\n]*SenseLink[^\n]*\n).*?(# =+[^\n]*다우오피스 라우트 별칭)'
m = re.search(pattern, content, re.DOTALL)
if m:
    content = content[:m.start()] + NEW_SENSELINK + '\n\n' + content[m.start(2):]
    print("    [OK] SenseLink 섹션 전체 교체 완료")
else:
    # fallback: senselink_sync 함수만 교체
    fsync_pat = r'(@app\.route\(\'/api/senselink/sync\'.*?)(?=@app\.route\(\'/api/senselink/status\')'
    new_func  = NEW_SENSELINK.split("@app.route('/api/senselink/status'")[0].strip() + '\n\n\n'
    new_c, n  = re.subn(fsync_pat, new_func, content, count=1, flags=re.DOTALL)
    if n:
        content = new_c
        print("    [OK] senselink_sync 함수 교체 (fallback)")
    else:
        print("    [WARN] 패턴 못 찾음 - SenseLink 섹션 끝에 추가")
        # if_name 바로 앞에 추가
        idx = content.rfind("\nif __name__")
        if idx > 0:
            content = content[:idx] + '\n' + NEW_SENSELINK + content[idx:]

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("    app.py 저장 완료")
PYEOF

# ── STEP 4: 구문 검사 ─────────────────────────────
echo ""
echo "[4] 구문 검사"
python3 -c "
import py_compile, sys
try:
    py_compile.compile('/tmp/v8_app.py', doraise=True)
    print('    [OK] app.py 구문 OK')
except py_compile.PyCompileError as e:
    print('    [FAIL]', e)
    sys.exit(1)
"
[ $? -ne 0 ] && exit 1

# ── STEP 5: relay 연결 테스트 ─────────────────────
echo ""
echo "[5] relay 연결 테스트"
python3 << 'PYEOF'
import requests, json

RELAY = "https://luke-subfestive-phyliss.ngrok-free.dev"
HEADERS = {'ngrok-skip-browser-warning': 'true'}
try:
    r = requests.get(f"{RELAY}/attendance",
                     params={'page': 1, 'size': 5},
                     headers=HEADERS, timeout=10)
    print(f"    HTTP: {r.status_code}")
    if r.status_code == 200:
        d = r.json()
        total = d.get('total', '?')
        recs  = d.get('data', [])
        print(f"    total: {total}건")
        if recs:
            s = recs[0]
            print(f"    샘플: {s.get('user_name','?')} | {s.get('sign_time_str','?')} | type={s.get('type')} | dir={s.get('device_direction')}")
    else:
        print(f"    응답: {r.text[:200]}")
except Exception as e:
    print(f"    [FAIL] {e}")
PYEOF

# ── STEP 6: 컨테이너 내부 테스트 ─────────────────
echo ""
echo "[6] 컨테이너 내부 테스트"
docker cp /tmp/v8_app.py attendance-backend:/app/app_test.py
docker exec attendance-backend python3 << 'PYEOF'
import sys
sys.path.insert(0, '/app')
with open('/app/app_test.py') as f:
    src = f.read()
try:
    compile(src, 'test', 'exec')
    print("    [OK] 구문 OK")
except SyntaxError as e:
    print(f"    [FAIL] {e}")
    sys.exit(1)

# 핵심 요소 확인
checks = {
    'user_name 필드':      "'user_name'" in src,
    'sign_time_str 필드':  "'sign_time_str'" in src,
    'type 필터':           "rtype != '1'" in src,
    '입장 우선 로직':      "device_direction" in src,
    '하루 최초 출근':      "best" in src,
}
for k, v in checks.items():
    print(f"    {'[OK]' if v else '[FAIL]'} {k}")
PYEOF
T=$?
docker exec attendance-backend rm -f /app/app_test.py 2>/dev/null || true
[ $T -ne 0 ] && echo "    [ABORT]" && exit 1

# ── STEP 7: 배포 ──────────────────────────────────
echo ""
echo "[7] 배포"
cp /tmp/v8_app.py "$BACKEND"
docker cp "$BACKEND" attendance-backend:/app/app.py
# env 파일도 컨테이너에 반영
docker exec attendance-backend sh -c \
  "grep -q SENSELINK_RELAY_URL /app/.env 2>/dev/null \
    && sed -i 's|SENSELINK_RELAY_URL=.*|SENSELINK_RELAY_URL=$NGROK_URL|' /app/.env \
    || echo 'SENSELINK_RELAY_URL=$NGROK_URL' >> /app/.env" 2>/dev/null || true
docker restart attendance-backend
echo "    20초 대기..."
sleep 20

# ── STEP 8: HTTP 검증 ─────────────────────────────
echo ""
echo "[8] HTTP 검증"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5000/api/attendance?year=2026&month=2")
echo "    /api/attendance → HTTP $STATUS"

echo ""
echo "    SenseLink status:"
curl -s "http://localhost:5000/api/senselink/status" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print('    relay_reachable :', d.get('relay_reachable'))
print('    relay_status    :', d.get('relay_status',''))
print('    senselink 건수  :', d.get('total_senselink_records',0))
print('    relay_url       :', d.get('relay_url',''))
" 2>/dev/null

echo ""
echo "    SenseLink sync 테스트 (2026-02):"
curl -s -X POST http://localhost:5000/api/senselink/sync \
  -H "Content-Type: application/json" \
  -d '{"year":2026,"month":2}' | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print('    synced :', d.get('synced',0), '건')
print('    fetched:', d.get('fetched',0), '건')
print('    pages  :', d.get('pages',0))
print('    errors :', d.get('errors',[]))
print('    message:', d.get('message',''))
" 2>/dev/null

# ── STEP 9: GitHub 푸시 ───────────────────────────
echo ""
echo "[9] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git fetch origin main 2>/dev/null || true
git add backend/app.py backend/.env 2>/dev/null || git add backend/app.py
git commit -m "fix(v8): SenseLink relay /attendance - user_name+sign_time_str [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null || true
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
git push -u origin main 2>&1 | tail -3
PUSH_RET=$?

echo ""
echo "================================================"
echo "  [DONE] fix_v8 완료"
echo ""
echo "  변경 내용:"
echo "    - relay /attendance 엔드포인트 연동"
echo "    - user_name, sign_time_str 필드 파싱"
echo "    - type='1' 직원만 / 하루 최초 입장 = 출근시각"
echo "    - ngrok URL: $NGROK_URL"
echo ""
if [ "$STATUS" = "200" ]; then
    echo "  [OK] /api/attendance HTTP 200"
else
    echo "  [WARN] /api/attendance HTTP $STATUS"
fi
[ $PUSH_RET -eq 0 ] && echo "  [OK] GitHub 푸시 완료" || echo "  [WARN] GitHub 로컬만 적용"
echo ""
echo "  브라우저: http://13.125.163.126  (Ctrl+Shift+R)"
echo "================================================"
