#!/usr/bin/env python3
"""
fix_v6 - 메시지 형식 복원 + start_date 추가만 수정
건드리는 것: SQL(start_date 추가), 메시지 생성 코드
건드리지 않는 것: 알림 단계 분류 노드, 이메일 노드, 기타 모든 것
"""
import sqlite3, json, subprocess, shutil
from datetime import datetime

CONTAINER = 'n8n-renewal-system'
TARGET_ID = '6lc-nueOiN7y9SWIY1zd6'
DB_LOCAL  = '/tmp/n8n_v6_fix.sqlite'
DB_BACKUP = '/tmp/n8n_v6_backup.sqlite'

# ── 이메일 매핑 (SQL CTE용) ──────────────────────────────
EMAIL_MAP = {
    '김규헌': 'ghkim1@dsti.co.kr', '김용태': 'ytkim@dsti.co.kr',
    '김윤식': 'karisma5882@naver.com', '김재천': 'jckim@dsti.co.kr',
    '김준서': 'jskim@dsti.co.kr', '김형태': 'hjyoo@dsti.co.kr',
    '박민식': 'hushms@dsti.co.kr', '박상민': 'smpark@dsti.co.kr',
    '박용석': 'hj.lee@dsti.co.kr', '박정재': 'pjj@dsti.co.kr',
    '박희열': 'hypark@dsti.co.kr', '손지원': 'jws@dsti.co.kr',
    '오팔석': 'palseokoh@dsti.co.kr', '윤윤원': 'ywyoun@dsti.co.kr',
    '이용건': 'yklee@dsti.co.kr', '이종갑': 'cklee@dsti.co.kr',
    '임규동': 'gdlim@dsti.co.kr', '임규빈': 'gblim@dsti.co.kr',
    '임종만': 'jmlim@dsti.co.kr', '장창훈': 'chjang@dsti.co.kr',
    '정석우': 'swjeong@dsti.co.kr', '최종민': 'jmchoi@dsti.co.kr',
}
values_list = ',\n    '.join(f"('{n}', '{e}')" for n, e in EMAIL_MAP.items())

# ── SQL: start_date 추가, email_map CTE 유지 ────────────
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
    c.start_date,
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

# ── 메시지 생성 코드: 사용자 원본 형식 복원 ────────────
MSG_CODE = r"""
// 메시지 생성 - 사용자 원본 형식
const allItems = $input.all();
const result = [];

for (const item of allItems) {
  const d = item.json;
  const days     = Number(d.days_remaining) || 0;
  const repEmail = d.sales_rep_email || 'htkim@dsti.co.kr';
  const repName  = d.sales_rep_name  || '담당자';
  const repPhone = d.sales_rep_phone || '정보 없음';
  const custName = d.customer_name   || '';
  const svcType  = d.service_type    || '';
  const stage    = d.alert_stage     || 'D-??';
  const contNo   = d.contract_number || '-';
  const monthly  = Number(d.monthly_amount) || 0;
  const endDate  = d.end_date  || '';
  const startDate = d.start_date || '정보 없음';

  const subject = `[${stage} 갱신알림] ${custName} - ${svcType}`;

  const body =
`안녕하세요. 유지보수 계약팀 입니다.
계약번호: ${contNo}
고객사: ${custName}
유지보수 만료일: ${endDate}
남은 일수: ${days}일
본 유지보수의 계약 갱신을 위해서 담당 영업은 고객사와 협의를 해주시기 바랍니다.
________________________________________
📌 추가 정보
서비스 유형: ${svcType}
계약 시작일: ${startDate}
월 계약 금액: ${monthly}원
담당자: ${repName}
연락처: ${repPhone}
이메일: ${repEmail}
________________________________________
🔔 알림 설정
※ 계약 만료 30일 이내이므로 매일 알림이 발송됩니다. 
✅ 갱신이 확정되었다면 알림을 중지할 수 있습니다.
관리자 또는 담당자에게 연락하여 "갱신 확정" 처리를 요청하세요. 
감사합니다.
DSTI 유지보수 계약팀
________________________________________
※ 본 메일은 자동 발송되었습니다.
※ 문의: nadacompany@gmail.com`;

  result.push({ json: {
    ...d,
    sales_rep_email: repEmail,
    email_subject:   subject,
    email_body:      body
  }});
}

return result;
"""

def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if out: print(f"  {out[:200]}")
    return r

print("=" * 55)
print("fix_v6: 메시지 형식 + start_date 수정만")
print("=" * 55)

# DB 복사
print("\n[1/5] DB 복사...")
r = run(f"docker cp {CONTAINER}:/home/node/.n8n/database.sqlite {DB_LOCAL}")
if r.returncode != 0: print("❌ 실패"); exit(1)
shutil.copy2(DB_LOCAL, DB_BACKUP)
sz = subprocess.check_output(f"ls -lh {DB_LOCAL}", shell=True).decode().split()[4]
print(f"  ✅ {DB_LOCAL} ({sz})")

conn = sqlite3.connect(DB_LOCAL)
cur  = conn.cursor()
cur.execute("SELECT nodes FROM workflow_entity WHERE id=?", (TARGET_ID,))
row = cur.fetchone()
if not row: print("❌ 워크플로우 없음"); conn.close(); exit(1)

nodes = json.loads(row[0] or '[]')

print("\n[2/5] 노드 수정 (SQL + 메시지만)...")
fixed = 0
for node in nodes:
    t  = node.get('type', '')
    nm = node.get('name', '')
    p  = node.get('parameters', {})

    # PostgreSQL 계약 조회 노드만 (start_date 추가)
    if 'postgres' in t.lower() and '계약' in nm:
        p['query'] = NEW_SQL
        node['parameters'] = p
        print(f"  ✅ SQL start_date 추가: [{nm}]"); fixed += 1

    # 메시지 생성 노드만
    elif t == 'n8n-nodes-base.code' and ('메시지' in nm or '템플릿' in nm):
        p['jsCode'] = MSG_CODE
        node['parameters'] = p
        print(f"  ✅ 메시지 형식 복원: [{nm}]"); fixed += 1

    else:
        print(f"  ⬜ 변경 없음: [{nm}] (건드리지 않음)")

print(f"\n  수정된 노드: {fixed}개")

print("\n[3/5] DB 저장...")
now = datetime.now().isoformat()
cur.execute(
    "UPDATE workflow_entity SET nodes=?, updatedAt=? WHERE id=?",
    (json.dumps(nodes, ensure_ascii=False), now, TARGET_ID)
)
conn.commit(); conn.close()
print("  ✅")

print("\n[4/5] 컨테이너에 DB 복사...")
run(f"docker cp {DB_LOCAL} {CONTAINER}:/home/node/.n8n/database.sqlite")
run(f"docker exec {CONTAINER} rm -f /home/node/.n8n/database.sqlite-wal /home/node/.n8n/database.sqlite-shm")
print("  ✅")

print("\n[5/5] n8n 재시작...")
run(f"docker restart {CONTAINER}")
print("  ✅")

print("\n" + "=" * 55)
print("✅ v6 완료 - 메시지 형식 + start_date만 수정")
print("=" * 55)
print("""
수정 내용:
  SQL  : start_date 컬럼 추가 (기존 email_map 유지)
  메시지: 사용자 원본 형식으로 복원
    - 이메일: ${repEmail}  (정보 없음 → 실제 이메일)
    - 연락처: ${repPhone}
    - 계약 시작일: ${startDate}

건드리지 않은 것:
  - 알림 단계 분류 노드
  - 이메일 전송 노드
  - 활성화 상태
""")
