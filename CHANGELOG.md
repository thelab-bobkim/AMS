# AMS (Attendance Management System) CHANGELOG

---

## [v3.0] - 2026-03-11 🔐 권한 분리 및 로그인 시스템 구축

### ✨ 신규 기능
- **로그인 화면 추가**: 시스템 접속 시 로그인 필수
- **JWT 인증 시스템**: 로그인 후 JWT 토큰 발급 (8시간 유효)
- **관리자/일반직원 권한 분리**:
  - 관리자 (htkim, hnsong, dijo): 전체 기록 조회·편집, 직원 관리, 동기화, 엑셀 다운로드
  - 일반직원: 본인 기록만 조회·편집 가능

### 🔧 변경 사항
- **관리자 인증**: 다우오피스 최고관리자 계정 ID 기반 (`.env ADMIN_USERS`)
  - 기존 AdminUser DB 테이블 방식 → `.env` 파일 기반으로 단순화
  - 관리자 계정: htkim (김형태), hnsong (송하늘), dijo (조동익)
- **일반직원 인증**: 다우오피스 영문 ID (`dauoffice_user_id`) + 공통 비밀번호
  - 영문 ID 없을 경우 한글 이름으로도 로그인 가능 (수동 등록 직원 대비)
  - 공통 비밀번호: `.env USER_DEFAULT_PASSWORD` (기본값 `1234`)
- **models.py**: AdminUser 테이블 제거 (불필요)
- **app.py**: bcrypt 의존성 제거, AdminUser 관련 코드 전면 삭제

### 🔒 보안
- 모든 API 엔드포인트에 JWT 인증 데코레이터 적용
- 관리자 전용 API: `@require_admin` 데코레이터
- 일반 사용자: 본인 employee_id 기준 데이터만 접근 가능

### ⚙️ .env 신규 항목
```
ADMIN_USERS=htkim,hnsong,dijo
ADMIN_PASSWORD=DstiAdmin2026!
USER_DEFAULT_PASSWORD=1234
```

---

## [v2.0] - 2026-03-06 🔒 HTTPS SSL 적용

### ✨ 신규 기능
- Let's Encrypt 무료 SSL 인증서 발급
- 도메인: `attendance.dsti.cloud`
- HTTP → HTTPS 자동 리다이렉트
- TLS 1.2 / 1.3 적용
- Docker Compose 인증서 볼륨 마운트
- 인증서 자동갱신 (Certbot cron)
- 인증서 만료: 2026-06-04

---

## [v1.0] - 2026-03-02 🚀 최초 배포

### ✨ 기능
- Flask 백엔드 (포트 5000)
- Nginx 프론트엔드 (포트 80)
- Docker Compose 구성
- 다우오피스 직원/출근 동기화
- SenseLink 출입 기록 연동
- SQLite DB (출근 기록)
- 엑셀 내보내기
- AWS Lightsail 배포 (IP: 13.125.163.126)
- DaouOffice 링크 메뉴 등록
