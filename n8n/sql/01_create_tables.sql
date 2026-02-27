-- ============================================================
-- AMS (Automatic Maintenance System) - 데이터베이스 초기화
-- PostgreSQL 13+
-- ============================================================

-- 계약 테이블
CREATE TABLE IF NOT EXISTS contracts (
    id               SERIAL PRIMARY KEY,
    contract_id      VARCHAR(50),
    contract_number  VARCHAR(50) UNIQUE,
    customer_name    VARCHAR(200) NOT NULL,
    service_type     VARCHAR(500),
    start_date       DATE,
    end_date         DATE,
    monthly_amount   NUMERIC(15,2) DEFAULT 0,
    sales_rep_name   VARCHAR(100),
    sales_rep_email  VARCHAR(200),   -- ← 담당자 이메일 (필수)
    sales_rep_phone  VARCHAR(50),
    customer_email   VARCHAR(200),
    customer_phone   VARCHAR(50),
    renewal_probability NUMERIC(5,2) DEFAULT 70.0,
    status           VARCHAR(20) DEFAULT 'active',
    created_at       TIMESTAMP DEFAULT NOW(),
    updated_at       TIMESTAMP DEFAULT NOW()
);

-- status에 공백 있을 경우 정리
UPDATE contracts SET status = TRIM(status) WHERE status != TRIM(status);

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_contracts_end_date  ON contracts(end_date);
CREATE INDEX IF NOT EXISTS idx_contracts_status    ON contracts(status);
CREATE INDEX IF NOT EXISTS idx_contracts_sales_rep ON contracts(sales_rep_email);

-- 알림 이력 테이블
CREATE TABLE IF NOT EXISTS notification_history (
    id                SERIAL PRIMARY KEY,
    contract_id       VARCHAR(50),
    contract_number   VARCHAR(50),
    customer_name     VARCHAR(200),
    sales_rep_name    VARCHAR(100),
    sales_rep_email   VARCHAR(200),
    alert_stage       VARCHAR(20),
    notification_date TIMESTAMP DEFAULT NOW(),
    email_sent        BOOLEAN DEFAULT FALSE,
    created_at        TIMESTAMP DEFAULT NOW()
);

-- 담당자 이메일 매핑 테이블 (보조)
CREATE TABLE IF NOT EXISTS sales_managers (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    email       VARCHAR(200) NOT NULL,
    phone       VARCHAR(50),
    department  VARCHAR(100),
    created_at  TIMESTAMP DEFAULT NOW(),
    UNIQUE(name)
);

-- 기본 담당자 데이터 (data-1.xlsx 기준)
INSERT INTO sales_managers (name, email) VALUES
    ('김재천', 'jckim@dsti.co.kr'),
    ('박희열', 'hypark@dsti.co.kr'),
    ('김준서', 'jskim@dsti.co.kr'),
    ('이용건', 'yklee@dsti.co.kr'),
    ('박상민', 'smpark@dsti.co.kr'),
    ('임규빈', 'gblim@dsti.co.kr'),
    ('최종민', 'jmchoi@dsti.co.kr'),
    ('김형태', 'hjyoo@dsti.co.kr'),
    ('임종만', 'jmlim@dsti.co.kr'),
    ('오팔석', 'palseokoh@dsti.co.kr'),
    ('김규헌', 'ghkim1@dsti.co.kr'),
    ('이종갑', 'jglee@dsti.co.kr')
ON CONFLICT (name) DO UPDATE SET email = EXCLUDED.email;

-- sales_rep_email이 NULL인 계약에 담당자 이메일 자동 매핑
UPDATE contracts c
SET sales_rep_email = sm.email
FROM sales_managers sm
WHERE c.sales_rep_name = sm.name
  AND (c.sales_rep_email IS NULL OR c.sales_rep_email = '');

COMMENT ON TABLE contracts IS 'AMS - 유지보수 계약 정보';
COMMENT ON COLUMN contracts.sales_rep_email IS '담당자 이메일 - n8n 워크플로우에서 이메일 발송 대상';

-- 결과 확인
SELECT '계약 수: ' || COUNT(*) FROM contracts;
SELECT '이메일 있는 계약: ' || COUNT(*) FROM contracts WHERE sales_rep_email IS NOT NULL;
SELECT '담당자별 집계:' AS info;
SELECT sales_rep_name, sales_rep_email, COUNT(*) AS cnt
FROM contracts
WHERE sales_rep_email IS NOT NULL
GROUP BY sales_rep_name, sales_rep_email
ORDER BY cnt DESC
LIMIT 15;
