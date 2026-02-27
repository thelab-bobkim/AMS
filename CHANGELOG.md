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
