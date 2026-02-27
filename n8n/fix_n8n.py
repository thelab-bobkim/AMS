#!/usr/bin/env python3
"""
AMS - 호스트에서 실행하는 n8n SQLite 수정 스크립트
n8n 컨테이너 밖(Ubuntu 호스트)에서 실행:
  python3 /tmp/fix_n8n.py
"""
import sqlite3, json, sys, os, shutil, subprocess
from datetime import datetime

CONTAINER  = 'n8n-renewal-system'
DB_INSIDE  = '/home/node/.n8n/database.sqlite'
DB_LOCAL   = '/tmp/n8n_db_backup.sqlite'
DB_PATCHED = '/tmp/n8n_db_patched.sqlite'

NEW_SQL = (
    "SELECT \n"
    "    c.contract_id,\n"
    "    c.contract_number,\n"
    "    c.customer_name,\n"
    "    c.service_type,\n"
    "    c.start_date,\n"
    "    c.end_date,\n"
    "    c.monthly_amount,\n"
    "    c.monthly_amount * 12 AS annual_amount,\n"
    "    c.sales_rep_name,\n"
    "    c.sales_rep_email,\n"
    "    COALESCE(c.renewal_probability, 70.0) AS renewal_probability,\n"
    "    (c.end_date - CURRENT_DATE) AS days_remaining\n"
    "FROM contracts c\n"
    "WHERE \n"
    "    c.status = 'active'\n"
    "    AND c.end_date >= CURRENT_DATE\n"
    "    AND c.end_date <= CURRENT_DATE + INTERVAL '90 days'\n"
    "ORDER BY c.end_date ASC;"
)

CLASSIFY_CODE = r"""const items = $input.all();
const results = [];
for (const item of items) {
    let daysRaw = item.json.days_remaining;
    let daysNum = 0;
    if (typeof daysRaw === 'number') { daysNum = daysRaw; }
    else if (typeof daysRaw === 'string') {
        const match = String(daysRaw).match(/(\d+)/);
        daysNum = match ? parseInt(match[1]) : 0;
    } else if (daysRaw && typeof daysRaw === 'object') {
        daysNum = parseInt(daysRaw.days || 0);
    }
    let alertStage='', urgencyLevel='', priority=0;
    if (daysNum>=85&&daysNum<=90){alertStage='D-90';urgencyLevel='정보';priority=1;}
    else if(daysNum>=55&&daysNum<=65){alertStage='D-60';urgencyLevel='주의';priority=2;}
    else if(daysNum>=40&&daysNum<=50){alertStage='D-45';urgencyLevel='중요';priority=3;}
    else if(daysNum>=25&&daysNum<=35){alertStage='D-30';urgencyLevel='긴급';priority=4;}
    else if(daysNum>=10&&daysNum<=16){alertStage='D-14';urgencyLevel='매우긴급';priority=5;}
    else if(daysNum>=5&&daysNum<=9){alertStage='D-7';urgencyLevel='최종경고';priority=6;}
    else if(daysNum>=0&&daysNum<=4){alertStage='D-0';urgencyLevel='위기';priority=7;}
    if(!alertStage) continue;
    const endDate=new Date(item.json.end_date);
    const formattedEnd=endDate.toLocaleDateString('ko-KR',{year:'numeric',month:'long',day:'numeric'});
    results.push({json:{...item.json,days_remaining:daysNum,alert_stage:alertStage,
        urgency_level:urgencyLevel,priority:priority,
        notification_date:new Date().toISOString(),
        formatted_end_date:formattedEnd,
        formatted_amount:parseInt(item.json.monthly_amount||0).toLocaleString('ko-KR'),
        effective_email:item.json.sales_rep_email||'htkim@dsti.co.kr'}});
}
return results;"""

def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr

print("=" * 60)
print("AMS n8n SQLite 수정 (호스트 실행)")
print("=" * 60)

# ── Step 1: SQLite 파일 호스트로 복사 ──────────────────────
print("\n[1/5] SQLite DB를 호스트로 복사...")
code, out, err = run(f"docker cp {CONTAINER}:{DB_INSIDE} {DB_LOCAL}")
if code != 0:
    print(f"❌ 복사 실패: {err}")
    sys.exit(1)
print(f"✅ 복사 완료: {DB_LOCAL}")

# 패치 파일 생성
shutil.copy2(DB_LOCAL, DB_PATCHED)

# ── Step 2: SQLite 수정 ─────────────────────────────────────
print("\n[2/5] 워크플로우 데이터 수정...")
conn = sqlite3.connect(DB_PATCHED)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

cur.execute("SELECT id, name, active FROM workflow_entity ORDER BY id")
workflows = cur.fetchall()
print(f"워크플로우 목록:")
for wf in workflows:
    print(f"  ID:{wf['id']} | {wf['name']}")

# 대상 워크플로우 선택
target = None
for wf in workflows:
    if any(k in (wf['name'] or '') for k in ['계약','갱신','알림','renewal','AMS','contract']):
        target = wf
        break
if not target and workflows:
    target = workflows[-1]

if not target:
    print("❌ 워크플로우 없음")
    conn.close(); sys.exit(1)

print(f"\n대상: {target['name']} (ID:{target['id']})")

cur.execute("SELECT nodes FROM workflow_entity WHERE id=?", (target['id'],))
row = cur.fetchone()
nodes = json.loads(row['nodes'] or '[]')
print(f"노드 수: {len(nodes)}")

fixed = 0
for node in nodes:
    ntype = node.get('type','')
    name  = node.get('name','')
    params = node.get('parameters',{})

    # PostgreSQL 조회 노드 SQL 수정
    if 'postgres' in ntype.lower() and any(k in name for k in ['조회','데이터','query','data','계약']):
        old = params.get('query','')[:60]
        params['query'] = NEW_SQL
        node['parameters'] = params
        print(f"  ✅ SQL 수정 [{name}]: {old!r}...")
        fixed += 1

    # 알림 분류 Function 노드
    if 'function' in ntype.lower() and any(k in name for k in ['분류','classify','단계','알림']):
        params['functionCode'] = CLASSIFY_CODE
        node['parameters'] = params
        print(f"  ✅ 분류 로직 수정 [{name}]")
        fixed += 1

    # 이메일 발송 노드
    if 'email' in ntype.lower() or 'emailSend' in ntype:
        old_to = params.get('sendTo', params.get('toEmail',''))
        params['sendTo'] = '={{ $json.sales_rep_email || "htkim@dsti.co.kr" }}'
        if 'options' not in params:
            params['options'] = {}
        params['options']['ccList'] = 'htkim@dsti.co.kr'
        node['parameters'] = params
        print(f"  ✅ 이메일 TO 수정 [{name}]: {old_to!r} → sales_rep_email")
        print(f"     CC: htkim@dsti.co.kr")
        fixed += 1

if fixed == 0:
    print("  ⚠️  수정된 노드 없음. 전체 노드 타입 출력:")
    for n in nodes:
        print(f"    {n.get('type')} | {n.get('name')}")

# 저장
cur.execute(
    "UPDATE workflow_entity SET nodes=?, updatedAt=? WHERE id=?",
    (json.dumps(nodes, ensure_ascii=False), datetime.now().isoformat(), target['id'])
)
conn.commit()
conn.close()
print(f"\n✅ {fixed}개 노드 수정 + SQLite 저장 완료")

# ── Step 3: 수정된 파일 컨테이너로 복사 ────────────────────
print("\n[3/5] 수정된 DB를 컨테이너에 복사...")
code, out, err = run(f"docker cp {DB_PATCHED} {CONTAINER}:{DB_INSIDE}")
if code != 0:
    print(f"❌ 복사 실패: {err}")
    sys.exit(1)
print("✅ 복사 완료")

# ── Step 4: WAL/SHM 파일 정리 ──────────────────────────────
print("\n[4/5] WAL 파일 정리...")
run(f"docker exec {CONTAINER} rm -f {DB_INSIDE}-wal {DB_INSIDE}-shm 2>/dev/null || true")
print("✅ WAL 정리 완료")

# ── Step 5: n8n 재시작 ─────────────────────────────────────
print("\n[5/5] n8n 컨테이너 재시작...")
code, out, err = run(f"docker restart {CONTAINER}")
if code == 0:
    print("✅ n8n 재시작 완료!")
else:
    print(f"⚠️  재시작 실패: {err}")
    print("   수동 실행: docker restart n8n-renewal-system")

print("\n" + "=" * 60)
print("✅ 모든 수정 완료!")
print("  → n8n UI: http://43.203.181.195:5678")
print("  → 워크플로우 테스트: Execute workflow 클릭")
print("  → 이메일 TO: 담당자 이메일 (sales_rep_email)")
print("  → 이메일 CC: htkim@dsti.co.kr")
print("=" * 60)
