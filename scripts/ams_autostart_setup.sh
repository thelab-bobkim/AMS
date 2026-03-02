#!/bin/bash
# ================================================================
#  근태관리 Ver-1 - 리부팅 자동 시작 설정 스크립트
#  서버: ubuntu@ip-172-26-4-210 (13.125.163.126)
#  실행: sudo bash ams_autostart_setup.sh
# ================================================================

set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
err()  { echo -e "${RED}  ❌ $1${NC}"; }
step() { echo -e "\n${YELLOW}▶ $1${NC}"; }

echo "================================================================"
echo "  근태관리 Ver-1 - 리부팅 자동 시작 설정"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"

# ── STEP 1: Docker 서비스 자동 시작 등록 ─────────────────────
step "1단계: Docker 서비스 부팅 자동 시작 등록"
systemctl enable docker 2>/dev/null && ok "docker 서비스 enable 완료" || warn "이미 등록되어 있음"
systemctl is-enabled docker | grep -q enabled && ok "docker: enabled 확인" || err "docker enable 실패"

# ── STEP 2: Docker 컨테이너 restart 정책 설정 ────────────────
step "2단계: Docker 컨테이너 restart=always 정책 설정"

# 실행 중인 AMS 관련 컨테이너 목록 확인
CONTAINERS=$(docker ps -a --format "{{.Names}}" | grep -E "attendance|mysql|nginx|ams" 2>/dev/null || true)
if [ -z "$CONTAINERS" ]; then
  warn "실행 중인 AMS 컨테이너가 없습니다 (docker-compose로 관리될 수 있음)"
else
  echo "   발견된 컨테이너:"
  for c in $CONTAINERS; do
    docker update --restart=always "$c" && ok "$c → restart=always 설정"
  done
fi

# docker-compose.yml에도 restart: always 확인
AMS_DIR=~/AMS
if [ -f "$AMS_DIR/docker-compose.yml" ]; then
  if grep -q "restart:" "$AMS_DIR/docker-compose.yml"; then
    ok "docker-compose.yml에 restart 정책 이미 존재"
  else
    # restart: always 추가
    sed -i 's/container_name:/restart: always\n    container_name:/g' "$AMS_DIR/docker-compose.yml"
    ok "docker-compose.yml에 restart: always 추가"
  fi
fi

# ── STEP 3: ngrok systemd 서비스 등록 ────────────────────────
step "3단계: ngrok 부팅 자동 시작 (systemd 서비스) 등록"

# ngrok 위치 확인
NGROK_BIN=$(which ngrok 2>/dev/null || echo "/usr/local/bin/ngrok")
NGROK_DOMAIN="luke-subfestive-phyliss.ngrok-free.app"

if [ ! -f "$NGROK_BIN" ]; then
  warn "ngrok 바이너리를 찾을 수 없습니다: $NGROK_BIN"
  warn "ngrok이 다른 경로에 있다면 /etc/systemd/system/ngrok.service의 ExecStart를 수정하세요"
fi

# ngrok authtoken 확인
NGROK_TOKEN=$(cat ~/.ngrok2/ngrok.yml 2>/dev/null | grep authtoken | awk '{print $2}' || \
              cat ~/.config/ngrok/ngrok.yml 2>/dev/null | grep authtoken | awk '{print $2}' || \
              echo "")

if [ -z "$NGROK_TOKEN" ]; then
  warn "ngrok authtoken을 찾지 못했습니다"
  warn "나중에 /etc/systemd/system/ngrok.service의 ExecStart에 --authtoken 추가 필요"
fi

# ngrok systemd 서비스 파일 생성
cat > /etc/systemd/system/ngrok.service << EOF
[Unit]
Description=ngrok - AMS SenseLink Relay Tunnel
Documentation=https://ngrok.com/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu
# ngrok free static domain: luke-subfestive-phyliss.ngrok-free.app
ExecStart=${NGROK_BIN} http --domain=luke-subfestive-phyliss.ngrok-free.app 5000
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ngrok

[Install]
WantedBy=multi-user.target
EOF

ok "ngrok.service 파일 생성: /etc/systemd/system/ngrok.service"

# ── STEP 4: AMS 전체 시작 스크립트 (docker-compose) ──────────
step "4단계: AMS 통합 시작 스크립트 생성"

cat > /usr/local/bin/ams_start.sh << 'STARTSCRIPT'
#!/bin/bash
# AMS 전체 서비스 시작 스크립트
LOG="/var/log/ams_start.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
AMS_DIR=/home/ubuntu/AMS

echo "[$TIMESTAMP] ===== AMS 서비스 시작 =====" >> "$LOG"

# 1) Docker 상태 확인
systemctl is-active docker > /dev/null 2>&1 || systemctl start docker
sleep 3

# 2) Docker 컨테이너 시작 (docker-compose 우선, 없으면 개별 시작)
if [ -f "$AMS_DIR/docker-compose.yml" ]; then
  cd "$AMS_DIR"
  docker-compose up -d >> "$LOG" 2>&1
  echo "[$TIMESTAMP] docker-compose up 완료" >> "$LOG"
else
  docker start attendance-backend 2>/dev/null && echo "[$TIMESTAMP] attendance-backend 시작" >> "$LOG" || true
  docker start $(docker ps -a --filter "name=mysql" --format "{{.Names}}") 2>/dev/null >> "$LOG" 2>&1 || true
fi

# 3) 컨테이너 준비 대기
sleep 15

# 4) 헬스체크
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/api/health 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo "[$TIMESTAMP] ✅ AMS API 정상 (HTTP 200)" >> "$LOG"
else
  echo "[$TIMESTAMP] ⚠️  AMS API 응답 없음 (HTTP $HTTP_CODE) - 재시도 중..." >> "$LOG"
  sleep 20
  docker restart attendance-backend >> "$LOG" 2>&1 || true
fi

echo "[$TIMESTAMP] ===== 시작 완료 =====" >> "$LOG"
STARTSCRIPT

chmod +x /usr/local/bin/ams_start.sh
ok "ams_start.sh 생성: /usr/local/bin/ams_start.sh"

# ── STEP 5: AMS 시작 systemd 서비스 등록 ─────────────────────
step "5단계: AMS 시작 systemd 서비스 등록"

cat > /etc/systemd/system/ams.service << 'EOF'
[Unit]
Description=AMS Attendance Management System
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=ubuntu
ExecStart=/usr/local/bin/ams_start.sh
ExecStop=/bin/bash -c 'cd /home/ubuntu/AMS && docker-compose down 2>/dev/null || docker stop attendance-backend'
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ams

[Install]
WantedBy=multi-user.target
EOF

ok "ams.service 파일 생성: /etc/systemd/system/ams.service"

# ── STEP 6: systemd 서비스 활성화 ────────────────────────────
step "6단계: 모든 서비스 enable (부팅 자동 시작 등록)"

systemctl daemon-reload
ok "daemon-reload 완료"

systemctl enable ams.service  && ok "ams.service    → enabled"
systemctl enable ngrok.service && ok "ngrok.service  → enabled"

# ── STEP 7: 현재 서비스 시작 (즉시 적용) ─────────────────────
step "7단계: 서비스 즉시 시작"

systemctl start ams.service   && ok "ams.service    → started" || warn "ams.service 시작 실패 (로그 확인)"
sleep 5
systemctl start ngrok.service && ok "ngrok.service  → started" || warn "ngrok.service 시작 실패 (토큰 확인)"

# ── 최종 상태 확인 ────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  ✅ 자동 시작 설정 완료!"
echo "================================================================"
echo ""
echo "📋 등록된 서비스 상태:"
echo "---"
systemctl is-enabled docker    2>/dev/null | xargs -I{} echo "  docker     : {}"
systemctl is-enabled ams       2>/dev/null | xargs -I{} echo "  ams        : {}"
systemctl is-enabled ngrok     2>/dev/null | xargs -I{} echo "  ngrok      : {}"
echo ""
echo "🔍 서비스 실시간 상태 확인 명령어:"
echo "  systemctl status ams"
echo "  systemctl status ngrok"
echo "  systemctl status docker"
echo ""
echo "📋 로그 확인:"
echo "  journalctl -u ngrok -f"
echo "  journalctl -u ams -f"
echo "  tail -f /var/log/ams_start.log"
echo ""
echo "🔁 리부팅 테스트:"
echo "  sudo reboot"
echo "  (재접속 후) systemctl status ams ngrok"
echo ""
echo "🌐 서비스 주소: http://13.125.163.126"
