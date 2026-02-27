#!/bin/bash
# AMS fix6 - attendance 복구 + SenseLink relay 연동
# ngrok URL 자동 감지 포함
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"
APP_DIR="$HOME/AMS"
NGROK_URL="${NGROK_URL:-https://luke-subfestive-phyliss.ngrok-free.dev}"

echo "================================================"
echo " AMS fix6 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "================================================"

# ── STEP 1: ngrok URL 자동 감지 ──────────────────
echo ""
echo "[1] ngrok URL 확인"
DETECTED_URL=""
DETECTED_URL=$(curl -s --connect-timeout 3 http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    tunnels = d.get('tunnels', [])
    for t in tunnels:
        url = t.get('public_url','')
        if url.startswith('https://'):
            print(url)
            break
except:
    pass
" 2>/dev/null)

if [ -n "$DETECTED_URL" ]; then
    NGROK_URL="$DETECTED_URL"
    echo "    자동 감지: $NGROK_URL"
else
    echo "    감지 실패 - 기본값 사용: $NGROK_URL"
fi

# relay 연결 확인
RELAY_OK=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5   -H "ngrok-skip-browser-warning: true"   "$NGROK_URL/attendance?page=1&size=1" 2>/dev/null)
echo "    relay 응답: HTTP $RELAY_OK"

# ── STEP 2: GitHub에서 app.py 다운로드 ───────────
echo ""
echo "[2] GitHub app.py 다운로드"
curl -s -H "Authorization: token $GITHUB_TOKEN"   "https://api.github.com/repos/$GITHUB_REPO/contents/backend/app.py"   > /tmp/gh_app_response.json

python3 << 'PYEOF'
import json, base64, sys
with open('/tmp/gh_app_response.json') as f:
    d = json.load(f)
if 'content' not in d:
    print("  [FAIL] GitHub 응답 오류:", d.get('message',''))
    sys.exit(1)
content = base64.b64decode(d['content']).decode()
with open('/tmp/app_restored.py', 'w') as f:
    f.write(content)
lines = len(content.splitlines())
print(f"  다운로드 완료: {lines}줄")
PYEOF
[ $? -ne 0 ] && echo "[ABORT] 다운로드 실패" && exit 1

# ── STEP 3: 라우트 확인 ──────────────────────────
echo ""
echo "[3] 라우트 확인"
python3 << 'PYEOF'
import sys
c = open('/tmp/app_restored.py').read()
ok_all = True
for route in ['/api/attendance', '/api/employees', '/api/senselink/sync', '/api/dauoffice']:
    marker = "@app.route('" + route
    ok = marker in c
    print("  " + ("[OK]" if ok else "[FAIL]") + " " + route)
    if not ok: ok_all = False
if not ok_all:
    sys.exit(1)
PYEOF
[ $? -ne 0 ] && echo "[ABORT] 핵심 라우트 누락" && exit 1

# ── STEP 4: .env relay URL 설정 ──────────────────
echo ""
echo "[4] relay URL 설정: $NGROK_URL"
ENV_FILE="$APP_DIR/backend/.env"
if [ -f "$ENV_FILE" ]; then
    if grep -q "SENSELINK_RELAY_URL" "$ENV_FILE"; then
        sed -i "s|SENSELINK_RELAY_URL=.*|SENSELINK_RELAY_URL=$NGROK_URL|" "$ENV_FILE"
        echo "    .env 업데이트"
    else
        echo "SENSELINK_RELAY_URL=$NGROK_URL" >> "$ENV_FILE"
        echo "    .env 추가"
    fi
else
    echo "SENSELINK_RELAY_URL=$NGROK_URL" > "$ENV_FILE"
    echo "    .env 생성"
fi

# ── STEP 5: 배포 ─────────────────────────────────
echo ""
echo "[5] 배포"
cp /tmp/app_restored.py "$APP_DIR/backend/app.py"
docker cp "$APP_DIR/backend/app.py" attendance-backend:/app/app.py

# 컨테이너 env에도 relay URL 주입
docker exec attendance-backend sh -c "
  grep -q SENSELINK_RELAY_URL /app/.env 2>/dev/null     && sed -i 's|SENSELINK_RELAY_URL=.*|SENSELINK_RELAY_URL=$NGROK_URL|' /app/.env     || echo SENSELINK_RELAY_URL=$NGROK_URL >> /app/.env
" 2>/dev/null || true

docker restart attendance-backend
echo "    20초 대기..."
sleep 20

# ── STEP 6: 검증 ─────────────────────────────────
echo ""
echo "[6] 검증"
ATT_STATUS=$(curl -s -o /dev/null -w "%{http_code}"   "http://localhost:5000/api/attendance?year=2026&month=2")
EMP_STATUS=$(curl -s -o /dev/null -w "%{http_code}"   "http://localhost:5000/api/employees")
echo "    /api/attendance -> HTTP $ATT_STATUS"
echo "    /api/employees  -> HTTP $EMP_STATUS"

if [ "$ATT_STATUS" = "200" ]; then
    curl -s "http://localhost:5000/api/attendance?year=2026&month=2" | python3 << 'PYEOF'
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print("    [WARN] 빈 응답")
else:
    d = json.loads(raw)
    items = d if isinstance(d, list) else d.get('data', [])
    print("    직원수:", len(items))
    if items:
        f = items[0]
        print("    이름:", f.get('name','?'), "/ 부서:", f.get('department','?'))
        days = f.get('days',{})
        print("    출근일수:", len(days))
PYEOF
else
    echo "    [FAIL] Docker 로그:"
    docker logs attendance-backend --tail=10 2>&1 | grep -E "Error|Exception|Traceback" | head -5
fi

# SenseLink sync 테스트
echo ""
echo "    SenseLink sync 테스트:"
curl -s -X POST http://localhost:5000/api/senselink/sync   -H "Content-Type: application/json"   -d "{"year":2026,"month":2}" | python3 << 'PYEOF'
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print("    synced :", d.get('synced', 0), "건")
    print("    fetched:", d.get('fetched', 0), "건")
    errs = d.get('errors', [])
    if errs:
        print("    errors :", errs[0][:80])
    else:
        print("    errors : 없음")
except Exception as e:
    print("    파싱 실패:", e)
PYEOF

# ── STEP 7: GitHub 푸시 ───────────────────────────
echo ""
echo "[7] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git fetch origin main 2>/dev/null || true
git add backend/app.py backend/.env 2>/dev/null || git add backend/app.py
git commit -m "fix6: attendance 복구 + SenseLink /attendance relay [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null   || echo "    변경 없음 (이미 최신)"
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
git push -u origin main 2>&1 | tail -2

echo ""
echo "================================================"
echo "  ngrok URL : $NGROK_URL"
if [ "$ATT_STATUS" = "200" ]; then
    echo "  attendance: OK (HTTP 200)"
else
    echo "  attendance: 실패 (HTTP $ATT_STATUS)"
fi
echo "  브라우저  : http://13.125.163.126  (Ctrl+Shift+R)"
echo "================================================"
