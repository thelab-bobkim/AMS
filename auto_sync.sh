
#!/bin/bash

YEAR=$(date +%Y)

MONTH=$(date +%-m)

LOG=/home/ubuntu/AMS/sync.log

curl -s -X POST http://localhost/api/senselink/sync -H "Content-Type: application/json" -d "{\"year\": $YEAR, \"month\": $MONTH}" >> $LOG 2>&1

echo "[$(date '+%Y-%m-%d %H:%M')] ${YEAR}년 ${MONTH}월 동기화 완료" >> $LOG

