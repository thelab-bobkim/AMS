# 유지보수 갱신 알림 시스템 v2.0
> DSTI 유지보수 계약 자동 갱신 알림 (n8n 기반)

---

## 📋 시스템 개요

- **목적**: 유지보수 계약 만료 90일 전부터 담당 영업에게 자동 이메일 알림 발송
- **실행 주기**: 매일 오전 08:00 (Asia/Seoul)
- **대상**: contracts 테이블에서 `status = 'active'` AND `end_date <= CURRENT_DATE + 90 days`
- **발송 방식**: 담당 영업 개인 이메일 TO + htkim@dsti.co.kr CC 항상 포함

---

## 🏗️ 인프라 구성

| 컨테이너 | 역할 | 재시작 정책 |
|----------|------|-------------|
| `n8n-renewal-system` | n8n 워크플로우 엔진 | `unless-stopped` |
| `n8n-postgres` | 계약 데이터 PostgreSQL | `unless-stopped` |
| `n8n-redis` | n8n 큐 Redis | `unless-stopped` |

- **n8n 네트워크**: `n8n-renewal-system_n8n-network`
- **n8n UI**: http://43.203.181.195:5678
- **DB 접속**: Host=`n8n-postgres`, DB=`n8n`, User=`n8n`, PW=`n8n_password_2024`

---

## 📊 워크플로우 구성

**활성 워크플로우 ID**: `6lc-nueOiN7y9SWIY1zd6`  
**워크플로우명**: 계약갱신 자동알림 (간단버전)

```
[매일 08:00 스케줄]
    ↓
[계약 데이터 조회] ← PostgreSQL (WITH email_map CTE 포함)
    ↓
[알림 단계 분류] ← D-7/D-14/D-30/D-45/D-60/D-90 분류
    ↓
[메시지 생성] ← 이메일 제목/본문 생성
    ↓
[Send an Email] ← TO: 담당 영업 이메일, CC: htkim@dsti.co.kr
```

---

## 🔑 핵심 수정 사항 (v1 → v2)

### 1. SQL - 담당자 이메일 매핑 내장 (WITH email_map CTE)
```sql
WITH email_map AS (
  SELECT * FROM (VALUES
    ('박희열', 'hypark@dsti.co.kr'),
    ('오팔석', 'palseokoh@dsti.co.kr'),
    -- ...22명 전체...
  ) AS t(rep_name, rep_email)
)
SELECT
    COALESCE(em.rep_email, c.sales_rep_email, 'htkim@dsti.co.kr') AS sales_rep_email,
    c.start_date,  -- v2에서 추가
    ...
FROM contracts c
LEFT JOIN email_map em ON em.rep_name = c.sales_rep_name
WHERE c.status = 'active'
  AND c.end_date >= CURRENT_DATE
  AND c.end_date <= CURRENT_DATE + INTERVAL '90 days'
```

### 2. 이메일 노드 - 동적 수신자
- `toEmail`: `={{ $json.sales_rep_email }}`
- `ccList`: `htkim@dsti.co.kr`

### 3. 메시지 형식 (원본 복원)
```
안녕하세요. 유지보수 계약팀 입니다.
계약번호: {contract_number}
고객사: {customer_name}
유지보수 만료일: {end_date}
남은 일수: {days}일
...
담당자: {sales_rep_name}
연락처: {sales_rep_phone}
이메일: {sales_rep_email}
...
※ 문의: nadacompany@gmail.com
```

---

## 👥 담당자 이메일 매핑 (22명)

| 이름 | 이메일 |
|------|--------|
| 김규헌 | ghkim1@dsti.co.kr |
| 김용태 | ytkim@dsti.co.kr |
| 김윤식 | karisma5882@naver.com |
| 김재천 | jckim@dsti.co.kr |
| 김준서 | jskim@dsti.co.kr |
| 김형태 | hjyoo@dsti.co.kr |
| 박민식 | hushms@dsti.co.kr |
| 박상민 | smpark@dsti.co.kr |
| 박용석 | hj.lee@dsti.co.kr |
| 박정재 | pjj@dsti.co.kr |
| 박희열 | hypark@dsti.co.kr |
| 손지원 | jws@dsti.co.kr |
| 오팔석 | palseokoh@dsti.co.kr |
| 윤윤원 | ywyoun@dsti.co.kr |
| 이용건 | yklee@dsti.co.kr |
| 이종갑 | cklee@dsti.co.kr |
| 임규동 | gdlim@dsti.co.kr |
| 임규빈 | gblim@dsti.co.kr |
| 임종만 | jmlim@dsti.co.kr |
| 장창훈 | chjang@dsti.co.kr |
| 정석우 | swjeong@dsti.co.kr |
| 최종민 | jmchoi@dsti.co.kr |

---

## 🔄 서비스 유지 설정

### 자동 재시작 (Docker)
```bash
docker update --restart=unless-stopped n8n-renewal-system n8n-postgres n8n-redis
```

### 헬스체크 크론잡 (5분마다 자동 복구)
```bash
*/5 * * * * docker inspect -f '{{.State.Running}}' n8n-renewal-system | grep -q true || docker start n8n-renewal-system n8n-postgres n8n-redis
```

---

## 🛠️ 문제 발생 시 수정 스크립트

| 스크립트 | 용도 |
|----------|------|
| `fix_v6_msg_only.py` | **최신** - 메시지 형식 + start_date 수정 |
| `fix_v5_final.py` | Code 노드 jsCode 수정 |
| `fix_complete_v3.py` | SQL email_map CTE 내장 |

### 빠른 복구
```bash
cd ~/AMS && git pull origin main && python3 ~/AMS/n8n/fix_v6_msg_only.py
```

---

## 📁 파일 구조

```
n8n/
├── README_v2.md                  ← 이 파일
├── workflows/
│   └── renewal-notification-workflow.json  ← 워크플로우 JSON
├── sql/
│   ├── 01_create_tables.sql      ← contracts 테이블 생성
│   └── 02_email_mapping.sql      ← 담당자 이메일 UPDATE
├── fix_v6_msg_only.py            ← 최신 수정 스크립트
├── fix_v5_final.py
├── fix_complete_v3.py
├── docker-compose.n8n.yml
└── setup.sh
```

---

## ✅ 운영 체크리스트

- [ ] 매일 오전 8시 워크플로우 실행 확인
- [ ] 각 담당 영업 이메일 수신 확인
- [ ] htkim@dsti.co.kr CC 수신 확인
- [ ] 신규 담당자 추가 시 EMAIL_MAP 업데이트 필요

---

*최종 업데이트: 2026-02-28 | DSTI 유지보수 계약팀*
