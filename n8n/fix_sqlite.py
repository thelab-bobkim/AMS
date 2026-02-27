#!/usr/bin/env python3
"""
AMS - n8n SQLite DB 직접 수정 스크립트
n8n API 인증 없이 SQLite를 직접 수정
실행: docker exec n8n-renewal-system python3 /tmp/fix_sqlite.py
"""
import sqlite3
import json
import sys
import os
import shutil
from datetime import datetime

DB_PATH = '/home/node/.n8n/database.sqlite'
BACKUP_PATH = f'/home/node/.n8n/database.sqlite.bak.{datetime.now().strftime("%Y%m%d_%H%M%S")}'

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

NEW_CLASSIFY_CODE = """const items = $input.all();
const results = [];

for (const item of items) {
    let daysRaw = item.json.days_remaining;
    let daysNum = 0;
    
    if (typeof daysRaw === 'number') {
        daysNum = daysRaw;
    } else if (typeof daysRaw === 'string') {
        const match = String(daysRaw).match(/(\\d+)/);
        daysNum = match ? parseInt(match[1]) : 0;
    } else if (daysRaw && typeof daysRaw === 'object') {
        daysNum = parseInt(daysRaw.days || 0);
    }
    
    let alertStage = '';
    let urgencyLevel = '';
    let priority = 0;
    
    if (daysNum >= 85 && daysNum <= 90) { alertStage = 'D-90'; urgencyLevel = '정보'; priority = 1; }
    else if (daysNum >= 55 && daysNum <= 65) { alertStage = 'D-60'; urgencyLevel = '주의'; priority = 2; }
    else if (daysNum >= 40 && daysNum <= 50) { alertStage = 'D-45'; urgencyLevel = '중요'; priority = 3; }
    else if (daysNum >= 25 && daysNum <= 35) { alertStage = 'D-30'; urgencyLevel = '긴급'; priority = 4; }
    else if (daysNum >= 10 && daysNum <= 16) { alertStage = 'D-14'; urgencyLevel = '매우긴급'; priority = 5; }
    else if (daysNum >= 5 && daysNum <= 9) { alertStage = 'D-7'; urgencyLevel = '최종경고'; priority = 6; }
    else if (daysNum >= 0 && daysNum <= 4) { alertStage = 'D-0'; urgencyLevel = '위기'; priority = 7; }
    
    if (!alertStage) continue;
    
    const endDate = new Date(item.json.end_date);
    const formattedEnd = endDate.toLocaleDateString('ko-KR', {year:'numeric',month:'long',day:'numeric'});
    
    results.push({
        json: {
            ...item.json,
            days_remaining: daysNum,
            alert_stage: alertStage,
            urgency_level: urgencyLevel,
            priority: priority,
            notification_date: new Date().toISOString(),
            formatted_end_date: formattedEnd,
            formatted_amount: parseInt(item.json.monthly_amount || 0).toLocaleString('ko-KR'),
            effective_email: item.json.sales_rep_email || 'htkim@dsti.co.kr'
        }
    });
}

return results;"""

print("=" * 60)
print("AMS n8n SQLite 직접 수정 스크립트")
print("=" * 60)

if not os.path.exists(DB_PATH):
    print(f"❌ DB 파일 없음: {DB_PATH}")
    sys.exit(1)

# 백업
shutil.copy2(DB_PATH, BACKUP_PATH)
print(f"✅ DB 백업: {BACKUP_PATH}")

conn = sqlite3.connect(DB_PATH)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

# 워크플로우 목록 조회
cur.execute("SELECT id, name, active FROM workflow_entity ORDER BY id")
workflows = cur.fetchall()

print(f"\n현재 워크플로우 ({len(workflows)}개):")
for wf in workflows:
    print(f"  ID:{wf['id']} | {wf['name']} | active:{wf['active']}")

# 계약갱신 워크플로우 찾기
target_wf = None
for wf in workflows:
    name = wf['name']
    if any(k in name for k in ['계약', 'renewal', 'contract', 'AMS', '알림']):
        target_wf = wf
        print(f"\n✅ 대상 워크플로우 발견: {name} (ID: {wf['id']})")
        break

if not target_wf:
    print("\n⚠️ 계약갱신 워크플로우를 찾지 못했습니다.")
    print("   모든 워크플로우를 순차적으로 시도합니다...")
    if workflows:
        target_wf = workflows[-1]  # 마지막 워크플로우
        print(f"   마지막 워크플로우 사용: {target_wf['name']}")

if not target_wf:
    print("❌ 수정할 워크플로우가 없습니다")
    conn.close()
    sys.exit(1)

# 워크플로우 데이터 읽기
cur.execute("SELECT * FROM workflow_entity WHERE id = ?", (target_wf['id'],))
row = cur.fetchone()
wf_data = dict(row)

# nodes 파싱 (JSON 문자열)
nodes_raw = wf_data.get('nodes', '[]')
try:
    nodes = json.loads(nodes_raw) if isinstance(nodes_raw, str) else nodes_raw
except:
    print("❌ 노드 JSON 파싱 실패")
    conn.close()
    sys.exit(1)

print(f"\n노드 수: {len(nodes)}")

fixed_count = 0
for node in nodes:
    ntype = node.get('type', '')
    name = node.get('name', '')
    params = node.get('parameters', {})

    # ── PostgreSQL 데이터 조회 노드 SQL 수정 ──
    if 'postgres' in ntype.lower() and any(k in name for k in ['조회', '데이터', 'query', 'data']):
        old_sql = params.get('query', '')
        params['query'] = NEW_SQL
        node['parameters'] = params
        print(f"\n✅ SQL 수정: [{name}]")
        print(f"   이전 SQL (앞 80자): {old_sql[:80]}")
        print(f"   새 SQL: sales_rep_email 포함, EXTRACT 오류 수정, 범위 조회")
        fixed_count += 1

    # ── 알림 단계 분류 Function 노드 수정 ──
    if 'function' in ntype.lower() and any(k in name for k in ['분류', 'classify', '단계']):
        params['functionCode'] = NEW_CLASSIFY_CODE
        node['parameters'] = params
        print(f"\n✅ 분류 로직 수정: [{name}]")
        print(f"   days_remaining interval → 숫자 변환 + 범위 매칭 적용")
        fixed_count += 1

    # ── 이메일 발송 노드 수정 ──
    if 'email' in ntype.lower() or 'emailSend' in ntype:
        old_to = params.get('sendTo', params.get('toEmail', ''))
        # TO: sales_rep_email 없으면 htkim@dsti.co.kr 폴백
        params['sendTo'] = '={{ $json.sales_rep_email || "htkim@dsti.co.kr" }}'
        # CC 설정
        if 'options' not in params:
            params['options'] = {}
        params['options']['ccList'] = 'htkim@dsti.co.kr'
        node['parameters'] = params
        print(f"\n✅ 이메일 노드 수정: [{name}]")
        print(f"   TO: {old_to} → ={{ $json.sales_rep_email || 'htkim@dsti.co.kr' }}")
        print(f"   CC: htkim@dsti.co.kr (유지)")
        fixed_count += 1

print(f"\n총 {fixed_count}개 노드 수정됨")

if fixed_count == 0:
    print("\n⚠️ 수정된 노드가 없습니다. 노드 타입을 확인합니다:")
    for node in nodes:
        print(f"  타입: {node.get('type')} | 이름: {node.get('name')}")

# 수정된 노드 저장
new_nodes_json = json.dumps(nodes, ensure_ascii=False)
cur.execute(
    "UPDATE workflow_entity SET nodes = ?, updatedAt = ? WHERE id = ?",
    (new_nodes_json, datetime.now().isoformat(), target_wf['id'])
)
conn.commit()
print(f"\n✅ SQLite DB 업데이트 완료 (워크플로우 ID: {target_wf['id']})")

# 검증
cur.execute("SELECT nodes FROM workflow_entity WHERE id = ?", (target_wf['id'],))
verify = json.loads(cur.fetchone()[0])
email_nodes = [n for n in verify if 'email' in n.get('type','').lower()]
for en in email_nodes:
    print(f"\n검증 - 이메일 노드 [{en['name']}]:")
    print(f"  TO: {en['parameters'].get('sendTo','')}")
    print(f"  CC: {en['parameters'].get('options',{}).get('ccList','')}")

conn.close()

print("\n" + "=" * 60)
print("✅ 수정 완료!")
print("⚠️  n8n을 재시작해야 변경사항이 적용됩니다:")
print("   docker restart n8n-renewal-system")
print("=" * 60)
