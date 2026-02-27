#!/usr/bin/env python3
"""
AMS n8n 수정 스크립트 v5 - 최종
핵심 수정: n8n-nodes-base.code 타입 체크 ('code' in type)
          jsCode 파라미터 사용 (Code 노드 전용)
          $input.all() 문법 유지
"""
import sqlite3, json, subprocess, shutil
from datetime import datetime

CONTAINER = 'n8n-renewal-system'
TARGET_ID = '6lc-nueOiN7y9SWIY1zd6'
DB_LOCAL  = '/tmp/n8n_v5_fix.sqlite'
DB_BACKUP = '/tmp/n8n_v5_backup.sqlite'

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

values_list = ',\n    '.join(f"('{n}', '{e}')" for n, e in EMAIL_MAP.items())

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

# n8n-nodes-base.code 노드용 (jsCode 파라미터, $input.all() 문법)
CLASSIFY_CODE = r"""
// 알림 단계 분류 - n8n Code 노드
const allItems = $input.all();
const result = [];

for (const item of allItems) {
  const d = item.json;
  const days = Number(d.days_remaining) || 0;

  let stage = 'D-90', urgency = 'normal';
  if      (days <= 0)  { stage = 'D-0';  urgency = 'critical'; }
  else if (days <= 7)  { stage = 'D-7';  urgency = 'critical'; }
  else if (days <= 14) { stage = 'D-14'; urgency = 'high'; }
  else if (days <= 30) { stage = 'D-30'; urgency = 'high'; }
  else if (days <= 45) { stage = 'D-45'; urgency = 'medium'; }
  else if (days <= 60) { stage = 'D-60'; urgency = 'medium'; }

  // sales_rep_email 보장
  const repEmail = d.sales_rep_email || 'htkim@dsti.co.kr';

  result.push({ json: {
    contract_id:         d.contract_id,
    contract_number:     d.contract_number,
    customer_name:       d.customer_name,
    service_type:        d.service_type,
    end_date:            d.end_date,
    monthly_amount:      d.monthly_amount,
    annual_amount:       d.annual_amount,
    sales_rep_name:      d.sales_rep_name,
    sales_rep_email:     repEmail,
    sales_rep_phone:     d.sales_rep_phone,
    customer_email:      d.customer_email,
    renewal_probability: d.renewal_probability,
    days_remaining:      days,
    alert_stage:         stage,
    urgency:             urgency
  }});
}

return result;
"""

MSG_CODE = r"""
// 메시지 생성 - n8n Code 노드
const allItems = $input.all();
const result = [];

for (const item of allItems) {
  const d = item.json;
  const days      = Number(d.days_remaining) || 0;
  const repEmail  = d.sales_rep_email  || 'htkim@dsti.co.kr';
  const repName   = d.sales_rep_name   || '담당자';
  const custName  = d.customer_name    || '';
  const svcType   = d.service_type     || '';
  const stage     = d.alert_stage      || 'D-??';
  const monthly   = Number(d.monthly_amount) || 0;
  const annual    = Number(d.annual_amount)  || monthly * 12;
  const contNo    = d.contract_number  || '-';
  const endDate   = String(d.end_date  || '').substring(0, 10);

  const icons = { critical:'🚨', high:'⚠️', medium:'📋', normal:'ℹ️' };
  const icon  = icons[d.urgency] || '📋';

  const subject = `[${icon} ${stage} 갱신알림] ${custName} - ${svcType}`;

  const body =
    `안녕하세요, ${repName} 담당자님.\n\n` +
    `아래 고객의 유지보수 계약이 ${stage} 갱신 시점에 도달했습니다.\n\n` +
    `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n` +
    `📋 계약 정보\n` +
    `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n` +
    `고객사    : ${custName}\n` +
    `서비스    : ${svcType}\n` +
    `만료일    : ${endDate}\n` +
    `잔여일    : ${days}일\n` +
    `월 금액   : ${monthly.toLocaleString('ko-KR')}원\n` +
    `연간 금액 : ${annual.toLocaleString('ko-KR')}원\n` +
    `계약번호  : ${contNo}\n` +
    `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n` +
    `빠른 갱신 조치 부탁드립니다.\n\n감사합니다.\nDSTI 유지보수팀`;

  result.push({ json: {
    contract_id:         d.contract_id,
    contract_number:     contNo,
    customer_name:       custName,
    service_type:        svcType,
    end_date:            d.end_date,
    monthly_amount:      monthly,
    annual_amount:       annual,
    sales_rep_name:      repName,
    sales_rep_email:     repEmail,
    sales_rep_phone:     d.sales_rep_phone,
    customer_email:      d.customer_email,
    renewal_probability: d.renewal_probability,
    days_remaining:      days,
    alert_stage:         stage,
    urgency:             d.urgency,
    email_subject:       subject,
    email_body:          body
  }});
}

return result;
"""

def run(cmd, show=True):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if show:
        out = (r.stdout + r.stderr).strip()
        if out:
            print(f"  {out[:200]}")
    return r

print("=" * 60)
print("AMS n8n 수정 v5 (Code 노드 jsCode 파라미터 수정)")
print("=" * 60)

# 1. DB 복사
print("\n[1/6] DB 복사...")
r = run(f"docker cp {CONTAINER}:/home/node/.n8n/database.sqlite {DB_LOCAL}")
if r.returncode != 0:
    print("❌ 실패. 컨테이너 이름 확인:"); run("docker ps --format '{{.Names}}'")
    exit(1)
shutil.copy2(DB_LOCAL, DB_BACKUP)
sz = subprocess.check_output(f"ls -lh {DB_LOCAL}", shell=True).decode().split()[4]
print(f"  ✅ {DB_LOCAL} ({sz})")

conn = sqlite3.connect(DB_LOCAL)
cur  = conn.cursor()

# 2. 노드 현황 진단
print("\n[2/6] 노드 현황 진단...")
cur.execute("SELECT nodes FROM workflow_entity WHERE id=?", (TARGET_ID,))
row = cur.fetchone()
if not row:
    print(f"❌ 워크플로우 {TARGET_ID} 없음"); conn.close(); exit(1)

nodes = json.loads(row[0] or '[]')
for n in nodes:
    t  = n.get('type', '')
    nm = n.get('name', '')
    p  = n.get('parameters', {})
    code_key = 'jsCode' if 'jsCode' in p else ('functionCode' if 'functionCode' in p else 'NONE')
    to_val   = p.get('toEmail', p.get('sendTo', ''))
    if 'email' in t.lower():
        print(f"  [{t}] {nm}  →  toEmail={to_val[:50] if to_val else '없음'}")
    elif 'postgres' in t.lower():
        q_preview = p.get('query', '')[:40].replace('\n',' ')
        print(f"  [{t}] {nm}  →  query={q_preview}...")
    else:
        print(f"  [{t}] {nm}  →  code_key={code_key}")

# 3. 노드 수정 (타입별 정확히 매칭)
print(f"\n[3/6] 노드 수정...")
fixed = 0
for node in nodes:
    t  = node.get('type', '')
    nm = node.get('name', '')
    p  = node.get('parameters', {})

    # PostgreSQL 계약 조회 노드
    if 'postgres' in t.lower() and '계약' in nm:
        p['query'] = NEW_SQL
        node['parameters'] = p
        print(f"  ✅ SQL (email_map 내장): [{nm}]"); fixed += 1

    # Code 노드 - 분류 (n8n-nodes-base.code, jsCode 파라미터)
    elif t == 'n8n-nodes-base.code' and '분류' in nm:
        p['jsCode'] = CLASSIFY_CODE
        # 혹시 functionCode도 남아있으면 삭제
        p.pop('functionCode', None)
        node['parameters'] = p
        print(f"  ✅ 분류 코드 (jsCode): [{nm}]"); fixed += 1

    # Code 노드 - 메시지 (n8n-nodes-base.code, jsCode 파라미터)
    elif t == 'n8n-nodes-base.code' and ('메시지' in nm or '템플릿' in nm):
        p['jsCode'] = MSG_CODE
        p.pop('functionCode', None)
        node['parameters'] = p
        print(f"  ✅ 메시지 코드 (jsCode): [{nm}]"); fixed += 1

    # 이메일 노드
    elif 'email' in t.lower() and 'send' in t.lower():
        old = p.get('toEmail', p.get('sendTo', '없음'))
        p['toEmail'] = '={{ $json.sales_rep_email }}'
        p.pop('sendTo', None)
        p.setdefault('options', {})['ccList'] = 'htkim@dsti.co.kr'
        node['parameters'] = p
        print(f"  ✅ 이메일 TO: {old[:40]} → ={{{{ $json.sales_rep_email }}}}"); fixed += 1
        print(f"     CC: htkim@dsti.co.kr")

print(f"\n  총 {fixed}개 노드 수정됨")
if fixed < 3:
    print("  ⚠️  일부 노드가 수정되지 않았습니다. 타입 목록 재확인:")
    for n in nodes:
        print(f"     type='{n.get('type','')}', name='{n.get('name','')}'")

# 4. DB 저장
print(f"\n[4/6] DB 저장...")
now = datetime.now().isoformat()
cur.execute(
    "UPDATE workflow_entity SET nodes=?, active=1, updatedAt=? WHERE id=?",
    (json.dumps(nodes, ensure_ascii=False), now, TARGET_ID)
)
cur.execute("UPDATE workflow_entity SET active=0 WHERE id!=?", (TARGET_ID,))
conn.commit()
conn.close()
print("  ✅ 완료")

# 5. 컨테이너에 복사
print(f"\n[5/6] 컨테이너에 DB 복사...")
run(f"docker cp {DB_LOCAL} {CONTAINER}:/home/node/.n8n/database.sqlite")
run(f"docker exec {CONTAINER} rm -f /home/node/.n8n/database.sqlite-wal /home/node/.n8n/database.sqlite-shm")
print("  ✅ 완료")

# 6. 재시작
print(f"\n[6/6] n8n 재시작...")
run(f"docker restart {CONTAINER}")
print("  ✅ 완료")

print("\n" + "=" * 60)
print("✅ v5 적용 완료!")
print("=" * 60)
print("""
핵심 수정 내용:
  1. SQL    : WITH email_map CTE (22명 이메일 직접 내장)
  2. 분류   : n8n-nodes-base.code + jsCode 파라미터
  3. 메시지 : n8n-nodes-base.code + jsCode 파라미터
  4. 이메일 : toEmail = {{ $json.sales_rep_email }}, CC=htkim@dsti.co.kr

테스트:
  http://43.203.181.195:5678 → Execute workflow
  → 분류 노드 OUTPUT에서 sales_rep_email 확인
""")
