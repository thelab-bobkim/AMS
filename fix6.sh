#!/bin/bash
# AMS 복구 스크립트 - attendance 복구 + SenseLink /attendance 연동
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"
APP_DIR="$HOME/AMS"
NGROK_URL="${NGROK_URL:-https://luke-subfestive-phyliss.ngrok-free.dev}"

echo "================================================"
echo " AMS 복구 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "================================================"

echo "[1] GitHub에서 복구된 app.py 다운로드"
curl -sH "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/$GITHUB_REPO/contents/backend/app.py" \
  | python3 -c "
import sys, json, base64
d = json.loads(sys.stdin.read())
with open('/tmp/app_restored.py','w') as f:
    f.write(base64.b64decode(d['content']).decode())
print('  다운로드 완료:', len(open('/tmp/app_restored.py').readlines()), '줄')
"

echo "[2] 라우트 확인"
python3 -c "
c = open('/tmp/app_restored.py').read()
routes = ['/api/attendance', '/api/employees', '/api/senselink/sync']
for r in routes:
    ok = f"@app.route('{r}'" in c
    print('  ' + ('[OK]' if ok else '[FAIL]') + ' ' + r)
"

echo "[3] .env에 relay URL 설정"
ENV_FILE="$APP_DIR/backend/.env"
if grep -q "SENSELINK_RELAY_URL" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|SENSELINK_RELAY_URL=.*|SENSELINK_RELAY_URL=$NGROK_URL|" "$ENV_FILE"
else
    echo "SENSELINK_RELAY_URL=$NGROK_URL" >> "$ENV_FILE"
fi
echo "  $(grep SENSELINK "$ENV_FILE" 2>/dev/null || echo '없음')"

echo "[4] 컨테이너에 배포"
cp /tmp/app_restored.py "$APP_DIR/backend/app.py"
docker cp "$APP_DIR/backend/app.py" attendance-backend:/app/app.py
docker restart attendance-backend
echo "  20초 대기..."
sleep 20

echo "[5] 검증"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5000/api/attendance?year=2026&month=2")
EMPLOYEES=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5000/api/employees")
echo "  /api/attendance → HTTP $STATUS"
echo "  /api/employees  → HTTP $EMPLOYEES"

if [ "$STATUS" = "200" ]; then
    BODY=$(curl -s "http://localhost:5000/api/attendance?year=2026&month=2")
    echo "$BODY" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
items = d if isinstance(d,list) else d.get('data',[])
print('  직원수:', len(items))
if items:
    f = items[0]
    print('  이름:', f.get('name','?'), '/ 부서:', f.get('department','?'))
"
fi

echo "[6] GitHub 푸시"
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git add backend/app.py backend/.env 2>/dev/null || git add backend/app.py
git commit -m "restore+fix: attendance 복구 + SenseLink /attendance [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null || true
git fetch origin main 2>/dev/null
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true
git push -u origin main 2>&1 | tail -2

echo "================================================"
echo "  완료! http://13.125.163.126 (Ctrl+Shift+R)"
echo "================================================"
