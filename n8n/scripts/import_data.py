#!/usr/bin/env python3
"""
AMS - data-1.xlsx → PostgreSQL 임포트 스크립트
서버에서 실행: python3 import_data.py

요구사항: pip install pandas openpyxl psycopg2-binary
"""
import os
import sys
import json
import base64

# ── DB 설정 (환경변수 우선, 없으면 기본값) ──────────────────
DB_HOST = os.environ.get('DB_HOST', 'localhost')
DB_PORT = int(os.environ.get('DB_PORT', 5432))
DB_NAME = os.environ.get('DB_NAME', 'n8n')
DB_USER = os.environ.get('DB_USER', 'n8n')
DB_PASS = os.environ.get('DB_PASS', 'n8n_password_2024')
XLSX_PATH = os.environ.get('XLSX_PATH', '/home/ubuntu/data-1.xlsx')

print("=" * 60)
print("AMS 데이터 임포트 스크립트")
print(f"DB: {DB_HOST}:{DB_PORT}/{DB_NAME}")
print(f"파일: {XLSX_PATH}")
print("=" * 60)

try:
    import pandas as pd
    import psycopg2
    from psycopg2.extras import execute_values
except ImportError:
    print("패키지 설치 중...")
    os.system(f"{sys.executable} -m pip install pandas openpyxl psycopg2-binary -q")
    import pandas as pd
    import psycopg2
    from psycopg2.extras import execute_values

# ── Excel 읽기 ──────────────────────────────────────────────
if not os.path.exists(XLSX_PATH):
    print(f"❌ 파일 없음: {XLSX_PATH}")
    print("   data-1.xlsx 파일 경로를 XLSX_PATH 환경변수로 지정하세요")
    sys.exit(1)

df = pd.read_excel(XLSX_PATH)
print(f"✅ Excel 로드: {len(df)}행, 컬럼: {list(df.columns)}")

# ── 컬럼 매핑 (유연하게 처리) ──────────────────────────────
col_map = {}
for col in df.columns:
    c = str(col).strip()
    if any(k in c for k in ['계약번호', '품의번호', 'contract']):
        col_map['contract_number'] = col
    elif any(k in c for k in ['고객', '회사', 'customer']):
        col_map['customer_name'] = col
    elif any(k in c for k in ['서비스', '품목', 'service', '사업명']):
        col_map['service_type'] = col
    elif any(k in c for k in ['시작일', '계약시작', 'start']):
        col_map['start_date'] = col
    elif any(k in c for k in ['만료일', '종료일', '계약종료', 'end']):
        col_map['end_date'] = col
    elif any(k in c for k in ['금액', 'amount', '월']):
        col_map['monthly_amount'] = col
    elif any(k in c for k in ['담당자', '영업', 'sales_rep', 'rep_name']):
        col_map['sales_rep_name'] = col
    elif any(k in c for k in ['이메일', 'email', 'mail']):
        col_map['sales_rep_email'] = col

print(f"컬럼 매핑: {col_map}")

def safe_str(v):
    if v is None or (isinstance(v, float) and str(v) == 'nan'):
        return None
    return str(v).replace('\n', ' ').replace('\r', '').replace('\t', ' ').strip()

def safe_date(v):
    if v is None or (isinstance(v, float) and str(v) == 'nan'):
        return None
    try:
        import pandas as pd
        d = pd.to_datetime(v, errors='coerce')
        if pd.isna(d):
            return None
        return d.strftime('%Y-%m-%d')
    except:
        return None

def safe_num(v):
    if v is None or (isinstance(v, float) and str(v) == 'nan'):
        return 0
    try:
        return float(str(v).replace(',', '').strip())
    except:
        return 0

# ── 담당자 이메일 사전 (data-1.xlsx에서 추출) ──────────────
email_dict = {}
if 'sales_rep_name' in col_map and 'sales_rep_email' in col_map:
    for _, row in df.iterrows():
        name = safe_str(row.get(col_map['sales_rep_name']))
        email = safe_str(row.get(col_map['sales_rep_email']))
        if name and email and '@' in email:
            email_dict[name] = email
    print(f"✅ 담당자 이메일 {len(email_dict)}명 로드")

# ── 레코드 생성 ────────────────────────────────────────────
records = []
seen_numbers = set()

for i, (_, row) in enumerate(df.iterrows()):
    cnum = safe_str(row.get(col_map.get('contract_number'))) or f'AUTO-{i+1:04d}'
    if cnum in seen_numbers:
        continue
    seen_numbers.add(cnum)

    rep_name = safe_str(row.get(col_map.get('sales_rep_name')))
    rep_email = safe_str(row.get(col_map.get('sales_rep_email')))

    # 이메일 없으면 사전에서 찾기
    if rep_name and (not rep_email or '@' not in str(rep_email or '')):
        rep_email = email_dict.get(rep_name)

    records.append({
        'contract_number': cnum,
        'customer_name':   safe_str(row.get(col_map.get('customer_name'))) or '미상',
        'service_type':    safe_str(row.get(col_map.get('service_type'))),
        'start_date':      safe_date(row.get(col_map.get('start_date'))),
        'end_date':        safe_date(row.get(col_map.get('end_date'))),
        'monthly_amount':  safe_num(row.get(col_map.get('monthly_amount'))),
        'sales_rep_name':  rep_name,
        'sales_rep_email': rep_email,
        'status':          'active',
        'renewal_probability': 70.0
    })

print(f"✅ 레코드 준비: {len(records)}건 (중복 제거 후)")

# ── DB 연결 및 임포트 ──────────────────────────────────────
conn = psycopg2.connect(
    host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
    user=DB_USER, password=DB_PASS
)
cur = conn.cursor()

# contracts 테이블 확인
cur.execute("""
    SELECT column_name FROM information_schema.columns
    WHERE table_name = 'contracts' ORDER BY ordinal_position
""")
cols = [r[0] for r in cur.fetchall()]
print(f"contracts 컬럼: {cols}")

if 'sales_rep_email' not in cols:
    print("⚠️ sales_rep_email 컬럼 추가 중...")
    cur.execute("ALTER TABLE contracts ADD COLUMN IF NOT EXISTS sales_rep_email VARCHAR(200)")
    conn.commit()

# 기존 테스트 데이터 정리
cur.execute("DELETE FROM contracts WHERE customer_name = '홍길동' OR sales_rep_name = '홍길동'")
conn.commit()

# 배치 임포트
batch_size = 50
total_inserted = 0
total_updated = 0

for i in range(0, len(records), batch_size):
    batch = records[i:i+batch_size]
    for r in batch:
        cur.execute("""
            INSERT INTO contracts (
                contract_number, customer_name, service_type,
                start_date, end_date, monthly_amount,
                sales_rep_name, sales_rep_email, status, renewal_probability
            ) VALUES (
                %(contract_number)s, %(customer_name)s, %(service_type)s,
                %(start_date)s, %(end_date)s, %(monthly_amount)s,
                %(sales_rep_name)s, %(sales_rep_email)s, %(status)s, %(renewal_probability)s
            )
            ON CONFLICT (contract_number) DO UPDATE SET
                sales_rep_email = EXCLUDED.sales_rep_email,
                sales_rep_name  = EXCLUDED.sales_rep_name,
                customer_name   = EXCLUDED.customer_name,
                service_type    = EXCLUDED.service_type,
                end_date        = EXCLUDED.end_date,
                monthly_amount  = EXCLUDED.monthly_amount,
                status          = EXCLUDED.status,
                updated_at      = NOW()
        """, r)
    conn.commit()
    total_inserted += len(batch)
    print(f"  진행: {min(i+batch_size, len(records))}/{len(records)}")

# 담당자 이메일 NULL 업데이트
if email_dict:
    for name, email in email_dict.items():
        cur.execute("""
            UPDATE contracts SET sales_rep_email = %s
            WHERE sales_rep_name = %s AND (sales_rep_email IS NULL OR sales_rep_email = '')
        """, (email, name))
    conn.commit()
    print(f"✅ NULL 이메일 자동 매핑 완료")

# 최종 확인
cur.execute("SELECT COUNT(*) FROM contracts")
total = cur.fetchone()[0]

cur.execute("""
    SELECT sales_rep_name, sales_rep_email, COUNT(*) AS cnt
    FROM contracts WHERE sales_rep_email IS NOT NULL
    GROUP BY sales_rep_name, sales_rep_email
    ORDER BY cnt DESC LIMIT 10
""")
rows = cur.fetchall()

cur.close()
conn.close()

print("\n" + "=" * 60)
print(f"✅ 임포트 완료! 총 계약 수: {total}")
print("\n담당자별 계약 현황:")
for name, email, cnt in rows:
    print(f"  {name:10s} {email:30s} {cnt:3d}건")
print("=" * 60)
