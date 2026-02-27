# AMS n8n 유지보수 알림 시스템

## 📌 개요
계약 만료 전 D-90/D-60/D-45/D-30/D-14/D-7/D-0 단계별로 **담당 영업사원에게 자동 이메일 알림**을 발송하는 n8n 워크플로우입니다.

---

## 🐛 수정 이력 (v2.0)

| 문제 | 원인 | 수정 내용 |
|------|------|-----------|
| 모든 메일이 htkim@dsti.co.kr로 발송 | SQL에 `sales_rep_email` 컬럼 누락 | SELECT에 `sales_rep_email` 추가 |
| PostgreSQL 오류 (EXTRACT) | `EXTRACT(DAY FROM interval)::INT` 타입 오류 | `(end_date - CURRENT_DATE)` 로 수정 |
| 하루에 0건 발송 | WHERE 조건이 정확한 날짜만 매칭 | 범위 조건 (±3~5일)으로 변경 |
| 알림 단계 분류 실패 | `days_remaining`이 interval 문자열 | 숫자 변환 로직 추가 |
| 잘못된 DB 연결 | credential이 vbip-postgres를 가리킴 | n8n-postgres로 수정 |

---

## 🏗️ 디렉토리 구조

```
n8n/
├── workflows/
│   └── renewal-notification-workflow.json   ← n8n 임포트 파일
├── sql/
│   └── 01_create_tables.sql                 ← DB 초기화 SQL
├── scripts/
│   └── import_data.py                       ← Excel 데이터 임포트
├── docker-compose.n8n.yml                   ← n8n + PostgreSQL 구성
└── setup.sh                                 ← 자동 설치 스크립트
```

---

## 🚀 배포 방법

### 1. 환경 설정
```bash
export SMTP_USER=aikms.htkim5505@gmail.com
export SMTP_PASS=your_gmail_app_password
```

### 2. 컨테이너 실행
```bash
docker compose -f n8n/docker-compose.n8n.yml up -d
```

### 3. 데이터 임포트
```bash
# data-1.xlsx 파일이 있는 경우
XLSX_PATH=/home/ubuntu/data-1.xlsx python3 n8n/scripts/import_data.py
```

### 4. 워크플로우 설치
```bash
bash n8n/setup.sh
```

---

## ⚙️ n8n 수동 설정 (서버가 이미 실행 중인 경우)

### PostgreSQL Credential 수정
1. `http://서버IP:5678` 접속 (admin / ChangeThisPassword123!)
2. 좌측 **Credentials** → **PostgreSQL-Mainteance DB** 편집
3. 아래 값으로 수정:

| 항목 | 값 |
|------|-----|
| Host | `n8n-postgres` |
| Database | `n8n` |
| User | `n8n` |
| Password | `n8n_password_2024` |
| Port | `5432` |

4. **Test connection** → ✅ → **Save**

### 워크플로우 임포트
1. **Workflows** → 우상단 **+** → **Import from file**
2. `n8n/workflows/renewal-notification-workflow.json` 선택
3. **Activate** 토글 ON

---

## 📧 이메일 발송 구조

```
담당자 이메일 (TO)      ← contracts.sales_rep_email
   + htkim@dsti.co.kr (CC) ← 항상 CC 포함
```

### 담당자별 이메일 매핑 (data-1.xlsx 기준)
| 담당자 | 이메일 | 계약 수 |
|--------|--------|---------|
| 김재천 | jckim@dsti.co.kr | 53 |
| 박희열 | hypark@dsti.co.kr | 42 |
| 김준서 | jskim@dsti.co.kr | 37 |
| 이용건 | yklee@dsti.co.kr | 26 |
| 박상민 | smpark@dsti.co.kr | 21 |
| 임규빈 | gblim@dsti.co.kr | 19 |
| 최종민 | jmchoi@dsti.co.kr | 19 |
| 김형태 | hjyoo@dsti.co.kr | 17 |
| 임종만 | jmlim@dsti.co.kr | 15 |
| 오팔석 | palseokoh@dsti.co.kr | 13 |

---

## 🔍 문제 해결

### 이메일이 여전히 htkim@dsti.co.kr에만 오는 경우

```bash
# 1. DB에 이메일 데이터 확인
docker exec n8n-postgres psql -U n8n -d n8n \
  -c "SELECT sales_rep_name, sales_rep_email, COUNT(*) FROM contracts GROUP BY 1,2 ORDER BY 3 DESC LIMIT 10;"

# 2. n8n 워크플로우 SQL 테스트 (계약 데이터 조회 노드)
# n8n UI에서 해당 노드만 단독 실행 → OUTPUT에서 sales_rep_email 값 확인

# 3. 이메일 NULL 수동 업데이트
docker exec n8n-postgres psql -U n8n -d n8n -c "
  UPDATE contracts SET sales_rep_email = 'jckim@dsti.co.kr' WHERE sales_rep_name = '김재천' AND sales_rep_email IS NULL;
"
```

### EXTRACT 오류 발생 시
워크플로우 SQL에서 `EXTRACT(DAY FROM ...)::INT` 부분을 `(end_date - CURRENT_DATE)` 로 교체하세요.

---

## 📅 알림 일정

| 단계 | 발송 조건 | 긴급도 |
|------|----------|--------|
| D-90 | 만료 85~90일 전 | 정보 |
| D-60 | 만료 55~65일 전 | 주의 |
| D-45 | 만료 40~50일 전 | 중요 |
| D-30 | 만료 25~35일 전 | 긴급 |
| D-14 | 만료 10~16일 전 | 매우긴급 |
| D-7  | 만료 5~9일 전   | 최종경고 |
| D-0  | 만료 0~4일 전   | 위기 |
