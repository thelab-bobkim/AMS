#!/bin/bash
# ============================================================
# AMS n8n 워크플로우 자동 설치 스크립트
# 서버에서 실행: bash n8n/setup.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

N8N_URL="http://localhost:5678"
N8N_USER="admin"
N8N_PASS="ChangeThisPassword123!"
WF_FILE="./n8n/workflows/renewal-notification-workflow.json"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  AMS n8n 워크플로우 설치 스크립트${NC}"
echo -e "${GREEN}============================================${NC}"

# 1. n8n 컨테이너 상태 확인
echo -e "\n${YELLOW}[1/4] n8n 컨테이너 상태 확인...${NC}"
if ! docker ps | grep -q "n8n-renewal-system"; then
    echo -e "${RED}❌ n8n-renewal-system 컨테이너가 실행 중이 아닙니다${NC}"
    echo "실행: docker compose -f n8n/docker-compose.n8n.yml up -d"
    exit 1
fi
echo -e "${GREEN}✅ n8n 컨테이너 실행 중${NC}"

# 2. n8n API 접근 확인
echo -e "\n${YELLOW}[2/4] n8n API 접근 확인...${NC}"
for i in {1..10}; do
    if curl -s -o /dev/null -w "%{http_code}" -u "$N8N_USER:$N8N_PASS" "$N8N_URL/rest/workflows" | grep -q "200"; then
        echo -e "${GREEN}✅ n8n API 접근 성공${NC}"
        break
    fi
    echo "  대기 중... ($i/10)"
    sleep 3
done

# 3. PostgreSQL 데이터 확인
echo -e "\n${YELLOW}[3/4] PostgreSQL 데이터 확인...${NC}"
CONTRACTS=$(docker exec n8n-postgres psql -U n8n -d n8n -t -c "SELECT COUNT(*) FROM contracts;" 2>/dev/null | tr -d ' ')
EMAILS=$(docker exec n8n-postgres psql -U n8n -d n8n -t -c "SELECT COUNT(*) FROM contracts WHERE sales_rep_email IS NOT NULL;" 2>/dev/null | tr -d ' ')

echo "  - 총 계약 수: $CONTRACTS"
echo "  - 이메일 있는 계약: $EMAILS"

if [ "$CONTRACTS" -lt "10" ] 2>/dev/null; then
    echo -e "${YELLOW}⚠️  계약 데이터가 적습니다. import_data.py를 실행하세요:${NC}"
    echo "  python3 n8n/scripts/import_data.py"
fi

# 4. 워크플로우 임포트 (n8n REST API)
echo -e "\n${YELLOW}[4/4] 워크플로우 임포트...${NC}"
if [ ! -f "$WF_FILE" ]; then
    echo -e "${RED}❌ 워크플로우 파일 없음: $WF_FILE${NC}"
    exit 1
fi

RESULT=$(curl -s -X POST \
    -u "$N8N_USER:$N8N_PASS" \
    -H "Content-Type: application/json" \
    -d @"$WF_FILE" \
    "$N8N_URL/rest/workflows")

WF_ID=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)

if [ -n "$WF_ID" ]; then
    echo -e "${GREEN}✅ 워크플로우 임포트 성공 (ID: $WF_ID)${NC}"
    
    # 워크플로우 활성화
    curl -s -X PATCH \
        -u "$N8N_USER:$N8N_PASS" \
        -H "Content-Type: application/json" \
        -d '{"active":true}' \
        "$N8N_URL/rest/workflows/$WF_ID" > /dev/null
    echo -e "${GREEN}✅ 워크플로우 활성화 완료${NC}"
else
    echo -e "${YELLOW}⚠️  API 임포트 실패. n8n UI에서 수동으로 임포트하세요:${NC}"
    echo "  1. http://[서버IP]:5678 접속"
    echo "  2. Workflows → Import from file"
    echo "  3. n8n/workflows/renewal-notification-workflow.json 선택"
fi

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}  설치 완료!${NC}"
echo -e "${GREEN}  n8n UI: http://[서버IP]:5678${NC}"
echo -e "${GREEN}  ID: admin / PW: ChangeThisPassword123!${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "\n중요: n8n UI에서 PostgreSQL 자격증명을 확인하세요:"
echo "  Credentials → PostgreSQL-Mainteance DB"
echo "  Host: n8n-postgres, DB: n8n, User: n8n, PW: n8n_password_2024"
