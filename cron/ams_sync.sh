#!/bin/bash
# ============================================================
# AMS 자동 동기화 스크립트 (cron 실행용)
# 위치: /usr/local/bin/ams_sync.sh
# 크론: 0 0,3,6,9,12 * * * /usr/local/bin/ams_sync.sh
#       (UTC 기준 = KST 09:00, 12:00, 15:00, 18:00, 21:00)
# ============================================================
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
YEAR=$(date '+%Y')
MONTH=$(date '+%-m')
LOG="/var/log/ams_sync.log"

echo "[$TIMESTAMP] ===== AMS 동기화 시작 =====" >> "$LOG"

# 1) DauOffice 직원 동기화
RESP=$(curl -s -X POST 'http://localhost:5000/api/dauoffice/sync-employees' \
  -H 'Content-Type: application/json' --max-time 60 2>&1)
echo "[$TIMESTAMP] [직원] $RESP" >> "$LOG"

sleep 5

# 2) SenseLink 당월 동기화
RESP2=$(curl -s -X POST 'http://localhost:5000/api/senselink/sync' \
  -H 'Content-Type: application/json' \
  -d "{\"year\":${YEAR},\"month\":${MONTH}}" --max-time 120 2>&1)
echo "[$TIMESTAMP] [SenseLink] $RESP2" >> "$LOG"

echo "[$TIMESTAMP] ===== 동기화 완료 =====" >> "$LOG"
echo "" >> "$LOG"
