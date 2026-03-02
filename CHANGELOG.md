# AMS Changelog

## 근태관리 Ver-1 (2026-02-27)

### ✅ 주요 변경사항
- SenseLink relay data.list 파싱 수정 (commit 268b2203)
- DEPT_MAP 117명 loginId→부서명 매핑 추가 (commit 634b937d)
- userGroups 없는 재직자 DEPT_MAP 우선 처리 (commit e04d459a)
- 권주택(jtkwon) 부서 → 자회사 수정 (commit 020e0b7e)

### 📋 지원 부서 (33개)
Back-up팀, CS 1팀, CS 2팀, CS팀(BL), Cluster팀, Cohesity사업부,
DX사업본부, DX사업부, EV팀, Pre-Sales사업부, SI사업1부, SI사업본부,
TFT팀, 경영지원부, 공공사업본부, 금융사업부, 기업부설연구소,
보안사업부, 솔루션사업부, 솔루션팀, 수자원조사기술원,
인프라기술지원 1팀, 인프라기술지원 2팀, 인프라기술지원 3팀,
재무기획실, 중부사업부, 클라우드팀, 자회사 등

### ⏰ 자동 동기화 스케줄
- 매일 09:00, 12:00, 15:00, 18:00, 21:00 (KST)
- DauOffice 직원 동기화 + SenseLink 당월 동기화

### 🔌 API 엔드포인트
- GET/POST /api/attendance
- GET/POST /api/employees
- POST /api/senselink/sync
- POST /api/dauoffice/sync-employees
- POST /api/dauoffice/sync-attendance
- GET  /api/export/excel
- GET  /api/health

### 🖥️ 서버 정보
- AWS EC2: 13.125.163.126
- Docker: attendance-backend (Flask:5000)
- ngrok relay: https://luke-subfestive-phyliss.ngrok-free.dev

## [v1.1] - 2026-03-02

### 변경 사항
- **relay_server.py v8 정식 배포**
  - `start`/`end` 파라미터 지원 추가 (기존 dateTimeFrom/dateTimeTo 병행)
  - `dept or ALL` 버그 수정 → `dept or 'ALL'` (NameError 수정)
  - MySQL 직접 연동 (192.168.250.183:3306, bi_slink_base)
  - Flask 3.1.3 + PyMySQL 1.1.2 환경
- **start_ngrok_relay.bat 수정**
  - SENSELINK_URL: `175.198.93.89:8765` → `localhost:8765`
  - NGROK_DOMAIN: `.app` → `.dev` 도메인 수정
  - 주석 업데이트
- **ngrok 업그레이드**: v3.3.1 → v3.36.1 (최소 요구 버전 충족)
- **Windows 자동 시작 작업 스케줄러 등록**
  - AMS_relay_server: 로그인 시 relay_server.py 자동 실행
  - AMS_ngrok_relay: 로그인 시 ngrok 자동 실행

### 아키텍처 변경
```
[이전] AWS → ngrok → 175.198.93.89:8765 (SenseLink HTTP API, 불안정)
[이후] AWS → ngrok → localhost:8765 → MySQL 192.168.250.183 (직접 연동, 안정)
```

### 검증 결과
- /health: DB connected, total_records 109,815
- /attendance (2월): total 7,559건 정상 반환
- AWS sync (2월): fetched 7,559건, synced 967건, errors 0
