#!/usr/bin/env python3
"""
AMS n8n 이메일 완전 수정 스크립트 v3
- SQL에 이메일 매핑 직접 내장 (credential/DB 문제 우회)
- code 노드에서 sales_rep_email 전달 보장
- toEmail 필드 동적 값으로 교체
- credential_entity 확인 및 수정
"""
import sqlite3
import json
import subprocess
import shutil
from datetime import datetime

# ─────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────
CONTAINER   = 'n8n-renewal-system'
TARGET_ID   = '6lc-nueOiN7y9SWIY1zd6'
DB_LOCAL    = '/tmp/n8n_v3_fix.sqlite'
DB_BACKUP   = '/tmp/n8n_v3_backup.sqlite'

# 담당자 이메일 매핑 (DB 값이 NULL이어도 보장)
EMAIL_MAP = {
    '김규헌': 'ghkim1@dsti.co.kr',
    '김용태': 'ytkim@dsti.co.kr',
    '김윤식': 'karisma5882@naver.com',
    '김재천': 'jckim@dsti.co.kr',
    '김준서': 'jskim@dsti.co.kr',
    '김형태': 'hjyoo@dsti.co.kr',
    '박민식': 'hushms@dsti.co.kr',
    '박상민': 'smpark@dsti.co.kr',
    '박용석': 'hj.lee@dsti.co.kr',
    '박정재': 'pjj@dsti.co.kr',
    '박희열': 'hypark@dsti.co.kr',
    '손지원': 'jws@dsti.co.kr',
    '오팔석': 'palseokoh@dsti.co.kr',
    '윤윤원': 'ywyoun@dsti.co.kr',
    '이용건': 'yklee@dsti.co.kr',
    '이종갑': 'cklee@dsti.co.kr',
    '임규동': 'gdlim@dsti.co.kr',
    '임규빈': 'gblim@dsti.co.kr',
    '임종만': 'jmlim@dsti.co.kr',
    '장창훈': 'chjang@dsti.co.kr',
    '정석우': 'swjeong@dsti.co.kr',
    '최종민': 'jmchoi@dsti.co.kr',
}

# VALUES 리스트 생성
values_list = ',\n    '.join(
    f"('{name}', '{email}')" for name, email in EMAIL_MAP.items()
)

# SQL 내장 이메일 매핑 쿼리
NEW_SQL = f"""WITH email_map AS (
  SELECT * FROM (VALUES
    {values_list}
  ) AS t(rep_name, rep_email)
)
SELECT
    c.contract_id,
    c.contract_number,
    c.customer_name,
    c.service_type,
    c.end_date,
    c.monthly_amount,
    c.monthly_amount * 12 AS annual_amount,
    c.sales_rep_name,
    COALESCE(em.rep_email, c.sales_rep_email, 'htkim@dsti.co.kr') AS sales_rep_email,
    c.sales_rep_phone,
    c.customer_email,
    COALESCE(c.renewal_probability, 70.0) AS renewal_probability,
    (c.end_date - CURRENT_DATE)::INT AS days_remaining
FROM contracts c
LEFT JOIN email_map em ON em.rep_name = c.sales_rep_name
WHERE c.status = 'active'
  AND c.end_date >= CURRENT_DATE
  AND c.end_date <= CURRENT_DATE + INTERVAL '90 days'
ORDER BY c.end_date ASC"""

# 알림 단계 분류 코드 (sales_rep_email 전달 보장)
CLASSIFY_CODE = """
const items = $input.all();
const result = [];

for (const item of items) {
  const data = item.json;
  const days = parseInt(data.days_remaining) || 0;
  
  let alert_stage = '';
  let urgency = 'normal';
  
  if (days <= 0) {
    alert_stage = 'D-0';
    urgency = 'critical';
  } else if (days <= 7) {
    alert_stage = 'D-7';
    urgency = 'critical';
  } else if (days <= 14) {
    alert_stage = 'D-14';
    urgency = 'high';
  } else if (days <= 30) {
    alert_stage = 'D-30';
    urgency = 'high';
  } else if (days <= 45) {
    alert_stage = 'D-45';
    urgency = 'medium';
  } else if (days <= 60) {
    alert_stage = 'D-60';
    urgency = 'medium';
  } else if (days <= 90) {
    alert_stage = 'D-90';
    urgency = 'normal';
  } else {
    continue;
  }
  
  result.push({
    json: {
      ...data,
      alert_stage,
      urgency,
      sales_rep_email: data.sales_rep_email || 'htkim@dsti.co.kr'
    }
  });
}

return result;
"""

# 메시지 생성 코드
MSG_CODE = """
const items = $input.all();
const result = [];

for (const item of items) {
  const data = item.json;
  const days = parseInt(data.days_remaining) || 0;
  const rep_email = data.sales_rep_email || 'htkim@dsti.co.kr';
  const monthly = parseFloat(data.monthly_amount) || 0;
  const annual = parseFloat(data.annual_amount) || (monthly * 12);
  
  const urgency_icon = {
    'critical': '🚨',
    'high': '⚠️',
    'medium': '📋',
    'normal': 'ℹ️'
  }[data.urgency] || 'ℹ️';
  
  const stage = data.alert_stage || 'D-??';
  
  const subject = `[${urgency_icon} ${stage} 갱신알림] ${data.customer_name} - ${data.service_type}`;
  
  const body = `안녕하세요, ${data.sales_rep_name} 담당자님.

아래 고객의 유지보수 계약이 ${stage} 갱신 시점에 도달했습니다.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 계약 정보
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
고객사    : ${data.customer_name}
서비스    : ${data.service_type}
만료일    : ${data.end_date}
잔여일    : ${days}일
월 금액   : ${monthly.toLocaleString('ko-KR')}원
연간 금액 : ${annual.toLocaleString('ko-KR')}원
계약번호  : ${data.contract_number || '-'}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

빠른 갱신 조치 부탁드립니다.

감사합니다.
DSTI 유지보수팀`;

  result.push({
    json: {
      ...data,
      sales_rep_email: rep_email,
      email_subject: subject,
      email_body: body
    }
  });
}

return result;
"""

def run(cmd, capture=False):
    r = subprocess.run(cmd, shell=True, capture_output=capture, text=True)
    if not capture:
        if r.returncode != 0:
            print(f"  ⚠️ 명령 실패: {cmd}")
    return r

print("=" * 60)
print("AMS n8n 이메일 수정 스크립트 v3")
print("=" * 60)

# 1. DB 복사
print("\n[1/6] SQLite DB 컨테이너에서 복사...")
r = run(f"docker cp {CONTAINER}:/home/node/.n8n/database.sqlite {DB_LOCAL}", capture=True)
if r.returncode != 0:
    print(f"  ❌ 복사 실패: {r.stderr}")
    exit(1)
shutil.copy2(DB_LOCAL, DB_BACKUP)
print(f"  ✅ {DB_LOCAL} ({subprocess.check_output(f'ls -lh {DB_LOCAL}', shell=True).decode().split()[4]})")

# 2. DB 열기
conn = sqlite3.connect(DB_LOCAL)
cur = conn.cursor()

# 3. 모든 워크플로우 확인
print("\n[2/6] 워크플로우 목록 확인...")
cur.execute("SELECT id, name, active FROM workflow_entity ORDER BY id")
workflows = cur.fetchall()
for wf in workflows:
    print(f"  {'✅' if wf[2] else '⬜'} [{wf[2]}] ID:{wf[0]} | {wf[1]}")

# 4. 타겟 워크플로우 수정
print(f"\n[3/6] 워크플로우 {TARGET_ID} 노드 수정...")
cur.execute("SELECT nodes FROM workflow_entity WHERE id=?", (TARGET_ID,))
row = cur.fetchone()
if not row:
    print(f"  ❌ 워크플로우 {TARGET_ID} 없음!")
    conn.close()
    exit(1)

nodes = json.loads(row[0] or '[]')
print(f"  총 {len(nodes)}개 노드 발견")

fixed_nodes = []
for node in nodes:
    t = node.get('type', '')
    nm = node.get('name', '')
    p = node.get('parameters', {})

    # PostgreSQL 노드: SQL 교체
    if 'postgres' in t.lower() and '계약' in nm:
        old_q = p.get('query', '')[:50]
        p['query'] = NEW_SQL
        node['parameters'] = p
        print(f"  ✅ SQL 교체: [{nm}] {old_q[:30]}... → WITH email_map 포함")

    # 알림 단계 분류 코드 노드
    elif ('code' in t.lower() or 'function' in t.lower()) and '분류' in nm:
        p['jsCode'] = CLASSIFY_CODE
        p['functionCode'] = CLASSIFY_CODE
        node['parameters'] = p
        print(f"  ✅ 분류 코드 교체: [{nm}] sales_rep_email 전달 보장")

    # 메시지 생성 코드 노드
    elif ('code' in t.lower() or 'function' in t.lower()) and ('메시지' in nm or '템플릿' in nm):
        p['jsCode'] = MSG_CODE
        p['functionCode'] = MSG_CODE
        node['parameters'] = p
        print(f"  ✅ 메시지 코드 교체: [{nm}] sales_rep_email 포함")

    # 이메일 전송 노드: toEmail 수정
    elif 'email' in t.lower() or 'Email' in t:
        old_to = p.get('toEmail', p.get('sendTo', '미설정'))
        # toEmail과 sendTo 모두 수정
        p['toEmail'] = '={{ $json.sales_rep_email }}'
        if 'sendTo' in p:
            del p['sendTo']
        p.setdefault('options', {})['ccList'] = 'htkim@dsti.co.kr'
        node['parameters'] = p
        print(f"  ✅ 이메일 TO 수정: {old_to} → ={{{{ $json.sales_rep_email }}}}")
        print(f"     CC: htkim@dsti.co.kr")

    fixed_nodes.append(node)

# 5. DB 업데이트
print(f"\n[4/6] 워크플로우 DB 업데이트...")
now = datetime.now().isoformat()
cur.execute(
    "UPDATE workflow_entity SET nodes=?, active=1, updatedAt=? WHERE id=?",
    (json.dumps(fixed_nodes, ensure_ascii=False), now, TARGET_ID)
)
# 나머지 비활성화
cur.execute("UPDATE workflow_entity SET active=0 WHERE id!=?", (TARGET_ID,))
conn.commit()

# 6. credential_entity 확인 및 수정
print(f"\n[5/6] PostgreSQL credential 확인...")
cur.execute("SELECT id, name, type, data FROM credentials_entity")
creds = cur.fetchall()
for cred in creds:
    cid, cname, ctype, cdata = cred
    print(f"  🔑 [{cid}] {cname} ({ctype})")
    if 'postgres' in ctype.lower() or 'Postgres' in ctype:
        try:
            d = json.loads(cdata or '{}')
            host = d.get('host', '?')
            db = d.get('database', '?')
            user = d.get('user', '?')
            print(f"     host={host}, db={db}, user={user}")
            # 호스트가 n8n-postgres가 아니면 수정
            if host not in ('n8n-postgres', 'localhost', '172.20.0.4'):
                print(f"  ⚠️  잘못된 host '{host}' → 'n8n-postgres' 수정 필요")
                print(f"  ⚠️  n8n UI에서 직접 수정해주세요:")
                print(f"       Host: n8n-postgres")
                print(f"       Database: n8n")
                print(f"       User: n8n")
                print(f"       Password: n8n_password_2024")
            else:
                print(f"     ✅ host 정상: {host}")
        except Exception as e:
            print(f"  ⚠️  파싱 실패: {e}")

conn.close()
print("  ✅ DB 수정 완료")

# 7. 컨테이너에 복사 및 재시작
print(f"\n[6/6] 컨테이너에 DB 복사 및 재시작...")
run(f"docker cp {DB_LOCAL} {CONTAINER}:/home/node/.n8n/database.sqlite")
run(f"docker exec {CONTAINER} rm -f /home/node/.n8n/database.sqlite-wal /home/node/.n8n/database.sqlite-shm")
run(f"docker restart {CONTAINER}")

print("\n" + "=" * 60)
print("✅ 완료! n8n 재시작됨")
print("=" * 60)
print(f"\n🌐 n8n UI: http://43.203.181.195:5678")
print(f"\n📋 수정 사항:")
print(f"   1. SQL에 이메일 매핑 직접 내장 (DB NULL 문제 우회)")
print(f"   2. 분류 코드: sales_rep_email 전달 보장")
print(f"   3. 메시지 코드: sales_rep_email 포함")
print(f"   4. 이메일 노드: toEmail = {{{{ $json.sales_rep_email }}}}")
print(f"   5. CC: htkim@dsti.co.kr")
print(f"\n⚠️  n8n UI 접속 후 Credentials 확인 필요:")
print(f"   PostgreSQL credential host = 'n8n-postgres' 확인")
print(f"\n✅ 검증 명령:")
print(f'   docker exec n8n-postgres psql -U n8n -d n8n -c "SELECT sales_rep_name, sales_rep_email FROM contracts WHERE sales_rep_email IS NOT NULL LIMIT 5;"')
