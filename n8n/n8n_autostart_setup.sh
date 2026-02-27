#!/bin/bash
# ================================================================
# n8n 유지보수 알림 시스템 - 리부팅 후 자동 시작 설정 스크립트
# 실행: bash n8n_autostart_setup.sh
# ================================================================

set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
info() { echo -e "  🔹 $1"; }

echo "================================================================"
echo " n8n 유지보수 알림 시스템 - 리부팅 자동 시작 설정"
echo "================================================================"

# ── Step 1: Docker 부팅 시 자동 시작 활성화 ──────────────────
echo ""
echo "[1/4] Docker 서비스 부팅 자동 시작 설정..."
sudo systemctl enable docker
sudo systemctl enable containerd
ok "Docker 부팅 자동 시작 활성화"
info "상태: $(sudo systemctl is-enabled docker)"

# ── Step 2: 컨테이너 재시작 정책 재확인 ─────────────────────
echo ""
echo "[2/4] 컨테이너 재시작 정책 설정..."
docker update --restart=unless-stopped n8n-renewal-system 2>/dev/null && ok "n8n-renewal-system: unless-stopped" || warn "n8n-renewal-system 없음 (확인 필요)"
docker update --restart=unless-stopped n8n-postgres       2>/dev/null && ok "n8n-postgres: unless-stopped"       || warn "n8n-postgres 없음 (확인 필요)"
docker update --restart=unless-stopped n8n-redis          2>/dev/null && ok "n8n-redis: unless-stopped"          || warn "n8n-redis 없음 (확인 필요)"

# ── Step 3: systemd 서비스 등록 (컨테이너 순서 보장) ────────
echo ""
echo "[3/4] systemd 서비스 등록 (시작 순서 보장)..."

sudo tee /etc/systemd/system/n8n-maintenance.service > /dev/null << 'SYSTEMD'
[Unit]
Description=n8n Maintenance Notification System
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/n8n-start.sh
ExecStop=/usr/local/bin/n8n-stop.sh
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
SYSTEMD

# 시작 스크립트
sudo tee /usr/local/bin/n8n-start.sh > /dev/null << 'STARTSCRIPT'
#!/bin/bash
LOG="/var/log/n8n-autostart.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] n8n 서비스 시작..." >> $LOG

# 1. postgres 먼저 시작
docker start n8n-postgres 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] n8n-postgres 시작" >> $LOG

# 2. postgres 준비될 때까지 대기 (최대 30초)
for i in $(seq 1 30); do
    if docker exec n8n-postgres pg_isready -U n8n -d n8n -q 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] PostgreSQL 준비 완료 (${i}초)" >> $LOG
        break
    fi
    sleep 1
done

# 3. redis 시작
docker start n8n-redis 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] n8n-redis 시작" >> $LOG
sleep 2

# 4. n8n 시작
docker start n8n-renewal-system 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] n8n-renewal-system 시작" >> $LOG

# 5. 정상 확인
sleep 5
if docker inspect -f '{{.State.Running}}' n8n-renewal-system 2>/dev/null | grep -q true; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ n8n 서비스 정상 시작" >> $LOG
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ n8n 시작 실패 - 재시도..." >> $LOG
    sleep 10
    docker start n8n-postgres n8n-redis n8n-renewal-system 2>/dev/null || true
fi
STARTSCRIPT

# 중지 스크립트
sudo tee /usr/local/bin/n8n-stop.sh > /dev/null << 'STOPSCRIPT'
#!/bin/bash
echo "[$(date '+%Y-%m-%d %H:%M:%S')] n8n 서비스 중지..." >> /var/log/n8n-autostart.log
# 컨테이너는 중지하지 않음 (Docker가 관리)
STOPSCRIPT

sudo chmod +x /usr/local/bin/n8n-start.sh
sudo chmod +x /usr/local/bin/n8n-stop.sh

# systemd 서비스 활성화
sudo systemctl daemon-reload
sudo systemctl enable n8n-maintenance.service
ok "n8n-maintenance.service 등록 및 활성화"

# ── Step 4: 헬스체크 크론잡 (재등록) ────────────────────────
echo ""
echo "[4/4] 헬스체크 크론잡 재등록..."

# 기존 중복 제거 후 재등록
(crontab -l 2>/dev/null | grep -v "n8n-renewal-system\|n8n_health") > /tmp/cron_clean.txt || true

cat >> /tmp/cron_clean.txt << 'CRONEOF'
# n8n 헬스체크 - 5분마다 자동 복구
*/5 * * * * /usr/local/bin/n8n-health-check.sh >> /var/log/n8n-health.log 2>&1
CRONEOF

crontab /tmp/cron_clean.txt
rm -f /tmp/cron_clean.txt

# 헬스체크 스크립트
sudo tee /usr/local/bin/n8n-health-check.sh > /dev/null << 'HEALTHSCRIPT'
#!/bin/bash
# n8n 컨테이너 헬스체크 및 자동 복구
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

check_and_start() {
    local name=$1
    if ! docker inspect -f '{{.State.Running}}' $name 2>/dev/null | grep -q true; then
        echo "[$TIMESTAMP] ⚠️  $name 중단 감지 → 재시작"
        docker start $name 2>/dev/null || true
    fi
}

check_and_start n8n-postgres
sleep 3
check_and_start n8n-redis
sleep 2
check_and_start n8n-renewal-system
HEALTHSCRIPT

sudo chmod +x /usr/local/bin/n8n-health-check.sh
ok "헬스체크 크론잡 등록 (/usr/local/bin/n8n-health-check.sh)"

# ── 최종 상태 출력 ────────────────────────────────────────────
echo ""
echo "================================================================"
echo -e "${GREEN} ✅ 모든 설정 완료!${NC}"
echo "================================================================"
echo ""
echo "📋 설정 요약:"
info "Docker 부팅 자동 시작: $(sudo systemctl is-enabled docker)"
info "n8n-maintenance 서비스: $(sudo systemctl is-enabled n8n-maintenance.service)"
info "크론잡 등록: $(crontab -l | grep -c n8n-health)개"
echo ""
echo "📄 로그 파일:"
info "자동 시작 로그: /var/log/n8n-autostart.log"
info "헬스체크 로그: /var/log/n8n-health.log"
echo ""
echo "🔧 리부팅 후 확인 명령:"
echo "   sudo journalctl -u n8n-maintenance.service -n 20"
echo "   cat /var/log/n8n-autostart.log"
echo "   docker ps"
echo ""
echo "🧪 지금 테스트 (서비스 수동 실행):"
echo "   sudo systemctl start n8n-maintenance.service"
echo "   sudo systemctl status n8n-maintenance.service"
