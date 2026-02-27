#!/bin/bash
# ============================================================
# AMS - 현재 서버의 n8n 워크플로우 즉시 수정 스크립트
# 서버에서 실행: bash n8n/fix_workflow_now.sh
#
# 이 스크립트는 현재 실행 중인 n8n의 워크플로우를
# n8n REST API를 통해 직접 수정합니다.
# ============================================================

set -e

N8N_URL="http://localhost:5678"
N8N_USER="admin"
N8N_PASS="ChangeThisPassword123!"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  AMS 워크플로우 즉시 수정 스크립트${NC}"
echo -e "${GREEN}================================================${NC}"

# Step 1: 현재 워크플로우 목록 확인
echo -e "\n${YELLOW}[Step 1] 현재 워크플로우 목록 조회...${NC}"
WF_LIST=$(curl -s -u "$N8N_USER:$N8N_PASS" "$N8N_URL/rest/workflows")
echo "$WF_LIST" | python3 -c "
import json,sys
d = json.load(sys.stdin)
wfs = d.get('data', d) if isinstance(d, dict) else d
if isinstance(wfs, list):
    for w in wfs:
        print(f\"  ID:{w.get('id')} | {w.get('name')} | active:{w.get('active')}\")
else:
    print('응답:', str(d)[:200])
" 2>/dev/null || echo "API 응답 파싱 실패"

# Step 2: 계약갱신 워크플로우 ID 찾기
echo -e "\n${YELLOW}[Step 2] 계약갱신 워크플로우 ID 검색...${NC}"
WF_ID=$(curl -s -u "$N8N_USER:$N8N_PASS" "$N8N_URL/rest/workflows" | python3 -c "
import json,sys
d = json.load(sys.stdin)
wfs = d.get('data', d) if isinstance(d, dict) else d
if isinstance(wfs, list):
    for w in wfs:
        name = w.get('name','')
        if '계약' in name or 'renewal' in name.lower() or 'contract' in name.lower():
            print(w.get('id',''))
            break
" 2>/dev/null)

if [ -z "$WF_ID" ]; then
    echo -e "${YELLOW}⚠️  기존 워크플로우를 찾지 못했습니다. 새로 임포트합니다...${NC}"
    WF_JSON=$(cat "$(dirname $0)/workflows/renewal-notification-workflow.json")
    RESULT=$(curl -s -X POST \
        -u "$N8N_USER:$N8N_PASS" \
        -H "Content-Type: application/json" \
        -d "$WF_JSON" \
        "$N8N_URL/rest/workflows")
    WF_ID=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    echo -e "${GREEN}✅ 새 워크플로우 생성 (ID: $WF_ID)${NC}"
else
    echo -e "${GREEN}✅ 워크플로우 발견 (ID: $WF_ID)${NC}"

    # Step 3: 현재 워크플로우 조회
    echo -e "\n${YELLOW}[Step 3] 현재 워크플로우 데이터 조회...${NC}"
    CURRENT_WF=$(curl -s -u "$N8N_USER:$N8N_PASS" "$N8N_URL/rest/workflows/$WF_ID")

    # Step 4: SQL 및 이메일 노드 수정 (Python)
    echo -e "\n${YELLOW}[Step 4] SQL 및 이메일 노드 수정...${NC}"
    UPDATED_WF=$(echo "$CURRENT_WF" | python3 << 'PYEOF'
import json, sys

wf = json.load(sys.stdin)
nodes = wf.get('nodes', [])
fixed = 0

NEW_SQL = """SELECT 
    c.contract_id,
    c.contract_number,
    c.customer_name,
    c.service_type,
    c.start_date,
    c.end_date,
    c.monthly_amount,
    c.monthly_amount * 12 AS annual_amount,
    c.sales_rep_name,
    c.sales_rep_email,
    COALESCE(c.renewal_probability, 70.0) AS renewal_probability,
    (c.end_date - CURRENT_DATE) AS days_remaining
FROM contracts c
WHERE 
    c.status = 'active'
    AND c.end_date >= CURRENT_DATE
    AND c.end_date <= CURRENT_DATE + INTERVAL '90 days'
ORDER BY c.end_date ASC;"""

for node in nodes:
    ntype = node.get('type','')
    name = node.get('name','')
    params = node.get('parameters',{})

    # PostgreSQL 데이터 조회 노드 SQL 수정
    if 'postgres' in ntype.lower() and '조회' in name:
        params['query'] = NEW_SQL
        fixed += 1
        print(f"  ✅ SQL 수정: {name}", file=sys.stderr)

    # 이메일 노드 수정
    if 'email' in ntype.lower():
        # TO 필드: sales_rep_email 없으면 CC 담당자로 폴백
        params['sendTo'] = '={{ $json.sales_rep_email || "htkim@dsti.co.kr" }}'
        # CC는 htkim@dsti.co.kr 유지
        if 'options' not in params:
            params['options'] = {}
        params['options']['ccList'] = 'htkim@dsti.co.kr'
        fixed += 1
        print(f"  ✅ 이메일 TO 수정: {name}", file=sys.stderr)

print(f"  총 {fixed}개 노드 수정됨", file=sys.stderr)

# active 상태 유지
wf['active'] = True
print(json.dumps(wf, ensure_ascii=False))
PYEOF
)

    # Step 5: 수정된 워크플로우 업로드
    echo -e "\n${YELLOW}[Step 5] 수정된 워크플로우 저장...${NC}"
    UPDATE_RESULT=$(echo "$UPDATED_WF" | curl -s -X PUT \
        -u "$N8N_USER:$N8N_PASS" \
        -H "Content-Type: application/json" \
        -d @- \
        "$N8N_URL/rest/workflows/$WF_ID")

    STATUS=$(echo "$UPDATE_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('OK' if d.get('id') else 'FAIL')" 2>/dev/null)
    if [ "$STATUS" = "OK" ]; then
        echo -e "${GREEN}✅ 워크플로우 업데이트 성공!${NC}"
    else
        echo -e "${RED}❌ 업데이트 실패. n8n UI에서 수동으로 수정하세요.${NC}"
        echo "응답: $(echo $UPDATE_RESULT | head -c 300)"
    fi
fi

# Step 6: 워크플로우 활성화
echo -e "\n${YELLOW}[Step 6] 워크플로우 활성화...${NC}"
curl -s -X PATCH \
    -u "$N8N_USER:$N8N_PASS" \
    -H "Content-Type: application/json" \
    -d '{"active":true}' \
    "$N8N_URL/rest/workflows/$WF_ID" > /dev/null
echo -e "${GREEN}✅ 워크플로우 활성화 완료${NC}"

# Step 7: PostgreSQL 이메일 NULL 수정
echo -e "\n${YELLOW}[Step 7] DB 이메일 NULL 자동 매핑...${NC}"
docker exec n8n-postgres psql -U n8n -d n8n << 'SQLEOF'
UPDATE contracts c SET sales_rep_email = sm.email
FROM (VALUES
    ('김재천','jckim@dsti.co.kr'),
    ('박희열','hypark@dsti.co.kr'),
    ('김준서','jskim@dsti.co.kr'),
    ('이용건','yklee@dsti.co.kr'),
    ('박상민','smpark@dsti.co.kr'),
    ('임규빈','gblim@dsti.co.kr'),
    ('최종민','jmchoi@dsti.co.kr'),
    ('김형태','hjyoo@dsti.co.kr'),
    ('임종만','jmlim@dsti.co.kr'),
    ('오팔석','palseokoh@dsti.co.kr'),
    ('김규헌','ghkim1@dsti.co.kr'),
    ('이종갑','jglee@dsti.co.kr')
) AS sm(name, email)
WHERE c.sales_rep_name = sm.name
  AND (c.sales_rep_email IS NULL OR c.sales_rep_email = '');

UPDATE contracts SET status = TRIM(status) WHERE status != TRIM(status);

SELECT '이메일 있는 계약: ' || COUNT(*) FROM contracts WHERE sales_rep_email IS NOT NULL;
SELECT '이메일 없는 계약: ' || COUNT(*) FROM contracts WHERE sales_rep_email IS NULL;
SQLEOF

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}  ✅ 모든 수정 완료!${NC}"
echo -e "${GREEN}  n8n UI에서 워크플로우 테스트 실행 후 확인하세요${NC}"
echo -e "${GREEN}  URL: http://43.203.181.195:5678${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "수동 확인 명령:"
echo "  docker exec n8n-postgres psql -U n8n -d n8n -c \"SELECT sales_rep_name, sales_rep_email FROM contracts LIMIT 5;\""
