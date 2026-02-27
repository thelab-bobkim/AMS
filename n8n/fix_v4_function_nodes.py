#!/usr/bin/env python3
"""
AMS n8n 이메일 수정 스크립트 v4
핵심 수정: 구버전 n8n Function 노드 문법 적용 ($input.all() → items)
"""
import sqlite3, json, subprocess, shutil
from datetime import datetime

CONTAINER = 'n8n-renewal-system'
TARGET_ID = '6lc-nueOiN7y9SWIY1zd6'
DB_LOCAL  = '/tmp/n8n_v4_fix.sqlite'
DB_BACKUP = '/tmp/n8n_v4_backup.sqlite'

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

# ─────────────────────────────────────────────
# 구버전 n8n Function 노드 문법 (items 직접 사용)
# ─────────────────────────────────────────────
CLASSIFY_CODE = """// 구버전 n8n Function 노드 - items 직접 사용
var result = [];

for (var i = 0; i < items.length; i++) {
  var data = items[i].json;
  var days = parseInt(data.days_remaining) || 0;
  var alert_stage = '';
  var urgency = 'normal';

  if (days <= 0)       { alert_stage = 'D-0';  urgency = 'critical'; }
  else if (days <= 7)  { alert_stage = 'D-7';  urgency = 'critical'; }
  else if (days <= 14) { alert_stage = 'D-14'; urgency = 'high'; }
  else if (days <= 30) { alert_stage = 'D-30'; urgency = 'high'; }
  else if (days <= 45) { alert_stage = 'D-45'; urgency = 'medium'; }
  else if (days <= 60) { alert_stage = 'D-60'; urgency = 'medium'; }
  else                 { alert_stage = 'D-90'; urgency = 'normal'; }

  result.push({
    json: {
      contract_id:          data.contract_id,
      contract_number:      data.contract_number,
      customer_name:        data.customer_name,
      service_type:         data.service_type,
      end_date:             data.end_date,
      monthly_amount:       data.monthly_amount,
      annual_amount:        data.annual_amount,
      sales_rep_name:       data.sales_rep_name,
      sales_rep_email:      data.sales_rep_email || 'htkim@dsti.co.kr',
      sales_rep_phone:      data.sales_rep_phone,
      customer_email:       data.customer_email,
      renewal_probability:  data.renewal_probability,
      days_remaining:       days,
      alert_stage:          alert_stage,
      urgency:              urgency
    }
  });
}

return result;
"""

MSG_CODE = """// 구버전 n8n Function 노드 - items 직접 사용
var result = [];

for (var i = 0; i < items.length; i++) {
  var data = items[i].json;
  var days = parseInt(data.days_remaining) || 0;
  var rep_email = data.sales_rep_email || 'htkim@dsti.co.kr';
  var monthly = parseFloat(data.monthly_amount) || 0;
  var annual  = parseFloat(data.annual_amount)  || (monthly * 12);
  var stage   = data.alert_stage || 'D-??';

  var urgency_icon = '📋';
  if (data.urgency === 'critical') urgency_icon = '🚨';
  else if (data.urgency === 'high') urgency_icon = '⚠️';
  else if (data.urgency === 'medium') urgency_icon = '📋';

  var subject = '[' + urgency_icon + ' ' + stage + ' 갱신알림] ' + data.customer_name + ' - ' + data.service_type;

  var body = '안녕하세요, ' + data.sales_rep_name + ' 담당자님.\\n\\n'
    + '아래 고객의 유지보수 계약이 ' + stage + ' 갱신 시점에 도달했습니다.\\n\\n'
    + '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\\n'
    + '📋 계약 정보\\n'
    + '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\\n'
    + '고객사    : ' + data.customer_name + '\\n'
    + '서비스    : ' + data.service_type + '\\n'
    + '만료일    : ' + (data.end_date || '').toString().substring(0, 10) + '\\n'
    + '잔여일    : ' + days + '일\\n'
    + '월 금액   : ' + monthly.toLocaleString('ko-KR') + '원\\n'
    + '연간 금액 : ' + annual.toLocaleString('ko-KR') + '원\\n'
    + '계약번호  : ' + (data.contract_number || '-') + '\\n'
    + '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\\n\\n'
    + '빠른 갱신 조치 부탁드립니다.\\n\\n'
    + '감사합니다.\\nDSTI 유지보수팀';

  result.push({
    json: {
      contract_id:         data.contract_id,
      contract_number:     data.contract_number,
      customer_name:       data.customer_name,
      service_type:        data.service_type,
      end_date:            data.end_date,
      monthly_amount:      data.monthly_amount,
      annual_amount:       data.annual_amount,
      sales_rep_name:      data.sales_rep_name,
      sales_rep_email:     rep_email,
      sales_rep_phone:     data.sales_rep_phone,
      customer_email:      data.customer_email,
      renewal_probability: data.renewal_probability,
      days_remaining:      days,
      alert_stage:         stage,
      urgency:             data.urgency,
      email_subject:       subject,
      email_body:          body
    }
  });
}

return result;
"""

def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ⚠️  stderr: {r.stderr.strip()[:200]}")
    else:
        out = r.stdout.strip()
        if out:
            print(f"  {out[:100]}")
    return r

print("=" * 60)
print("AMS n8n 수정 스크립트 v4 (구버전 Function 노드 호환)")
print("=" * 60)

# 1. DB 복사
print("\n[1/5] DB 복사...")
r = run(f"docker cp {CONTAINER}:/home/node/.n8n/database.sqlite {DB_LOCAL}")
if r.returncode != 0:
    print("❌ 실패"); exit(1)
shutil.copy2(DB_LOCAL, DB_BACKUP)
size = subprocess.check_output(f"ls -lh {DB_LOCAL}", shell=True).decode().split()[4]
print(f"  ✅ {DB_LOCAL} ({size})")

# 2. 노드 수정
conn = sqlite3.connect(DB_LOCAL)
cur  = conn.cursor()
cur.execute("SELECT nodes FROM workflow_entity WHERE id=?", (TARGET_ID,))
row = cur.fetchone()
if not row:
    print(f"❌ 워크플로우 {TARGET_ID} 없음"); conn.close(); exit(1)

nodes = json.loads(row[0] or '[]')
print(f"\n[2/5] {len(nodes)}개 노드 수정...")

for node in nodes:
    t  = node.get('type', '')
    nm = node.get('name', '')
    p  = node.get('parameters', {})

    if 'postgres' in t.lower() and '계약' in nm:
        p['query'] = NEW_SQL
        node['parameters'] = p
        print(f"  ✅ SQL (email_map 내장): [{nm}]")

    elif 'function' in t.lower() and '분류' in nm:
        p['functionCode'] = CLASSIFY_CODE
        node['parameters'] = p
        print(f"  ✅ 분류 Function 코드 교체 (구버전 items 문법): [{nm}]")

    elif 'function' in t.lower() and ('메시지' in nm or '템플릿' in nm):
        p['functionCode'] = MSG_CODE
        node['parameters'] = p
        print(f"  ✅ 메시지 Function 코드 교체 (구버전 items 문법): [{nm}]")

    elif 'email' in t.lower():
        old = p.get('toEmail', p.get('sendTo', '없음'))
        # toEmail 설정, sendTo 제거
        p['toEmail'] = '={{ $json.sales_rep_email }}'
        p.pop('sendTo', None)
        p.setdefault('options', {})['ccList'] = 'htkim@dsti.co.kr'
        node['parameters'] = p
        print(f"  ✅ 이메일 TO: {old} → ={{{{ $json.sales_rep_email }}}}")
        print(f"     CC: htkim@dsti.co.kr")

# 3. DB 저장
print(f"\n[3/5] DB 저장...")
now = datetime.now().isoformat()
cur.execute(
    "UPDATE workflow_entity SET nodes=?, active=1, updatedAt=? WHERE id=?",
    (json.dumps(nodes, ensure_ascii=False), now, TARGET_ID)
)
cur.execute("UPDATE workflow_entity SET active=0 WHERE id!=?", (TARGET_ID,))
conn.commit()
conn.close()
print("  ✅ 완료")

# 4. 컨테이너에 복사
print(f"\n[4/5] 컨테이너에 DB 복사...")
run(f"docker cp {DB_LOCAL} {CONTAINER}:/home/node/.n8n/database.sqlite")
run(f"docker exec {CONTAINER} rm -f /home/node/.n8n/database.sqlite-wal /home/node/.n8n/database.sqlite-shm")
print("  ✅ 완료")

# 5. 재시작
print(f"\n[5/5] n8n 재시작...")
run(f"docker restart {CONTAINER}")
print("  ✅ 완료")

print("\n" + "=" * 60)
print("✅ v4 적용 완료!")
print("=" * 60)
print("""
수정 핵심:
  - Function 노드: $input.all() → items (구버전 호환)
  - functionCode 키 사용 (function 노드 전용)
  - 이메일 노드: toEmail = {{ $json.sales_rep_email }}
  - SQL: WITH email_map CTE 이메일 매핑 내장

테스트:
  http://43.203.181.195:5678 → 워크플로우 → Execute workflow
  → 각 노드 OUTPUT에서 sales_rep_email 확인
""")
