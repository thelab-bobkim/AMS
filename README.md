# 출근 관리 시스템

## 📋 프로젝트 개요
직원들의 출근 기록을 관리하는 웹 애플리케이션입니다.
- 다우오피스 OpenAPI 연동으로 자동 데이터 가져오기
- 다우오피스 미등록 직원은 수동 입력
- 월별 캘린더 형태로 출근 기록 관리
- 엑셀 파일로 내보내기

## 🛠️ 기술 스택
- **백엔드**: Python Flask + SQLAlchemy
- **프론트엔드**: Vue.js 3 + Bootstrap 5
- **데이터베이스**: SQLite (개발용) / PostgreSQL (프로덕션)
- **배포**: Docker + Nginx

## 📁 프로젝트 구조
```
attendance-system/
├── backend/                # Flask 백엔드
│   ├── app.py             # 메인 애플리케이션
│   ├── models.py          # 데이터베이스 모델
│   ├── dauoffice_api.py   # 다우오피스 API 클라이언트
│   ├── config.py          # 설정
│   └── requirements.txt   # Python 패키지
├── frontend/              # Vue.js 프론트엔드
│   ├── index.html         # 메인 HTML
│   └── js/
│       └── app.js         # Vue 앱
├── config/                # 설정 파일
│   └── .env.example       # 환경변수 예시
├── docker-compose.yml     # Docker Compose 설정
├── Dockerfile            # Docker 이미지
├── nginx.conf            # Nginx 설정
└── README.md             # 문서
```

## 🚀 설치 및 실행

### 1. 환경 설정
```bash
# .env 파일 생성
cp config/.env.example .env

# .env 파일 편집
# DAUOFFICE_API_KEY에 발급받은 API Key 입력
```

### 2. Docker로 실행 (권장)
```bash
# 빌드 및 실행
docker-compose up -d

# 로그 확인
docker-compose logs -f

# 중지
docker-compose down
```

### 3. 로컬 개발 환경
```bash
# 백엔드
cd backend
pip install -r requirements.txt
python app.py

# 프론트엔드 (별도 터미널)
cd frontend
# 간단한 HTTP 서버 실행
python -m http.server 8080
```

## 📖 사용 방법

### 1. 다우오피스 API Key 발급
1. 다우오피스 관리자 페이지 접속
2. 시스템관리 → 연동관리 → OpenAPI
3. "인증키 발급" 버튼 클릭
4. 발급된 API Key를 `.env` 파일에 입력

### 2. 직원 관리
- **다우오피스 동기화**: 상단 "🔄 다우오피스 동기화" 버튼 클릭
- **수동 추가**: "👥 직원 관리" → "➕ 직원 추가"

### 3. 출근 기록 입력
- 캘린더의 셀을 클릭하여 출근 시간 입력
- 기록 유형 선택:
  - 정상 출근: 시간 입력
  - 연차/반차/대체휴무
  - 출장 (메모에 장소 입력)

### 4. 엑셀 다운로드
- 원하는 년도/월 선택
- "📥 엑셀 다운로드" 버튼 클릭
- 기존 엑셀 형식으로 다운로드됨

## 🔧 API 엔드포인트

### 직원 관리
- `GET /api/employees` - 직원 목록 조회
- `POST /api/employees` - 직원 추가
- `PUT /api/employees/<id>` - 직원 수정
- `DELETE /api/employees/<id>` - 직원 삭제

### 출근 기록
- `GET /api/attendance?year=2026&month=1` - 월별 출근 기록 조회
- `POST /api/attendance` - 출근 기록 추가/수정
- `DELETE /api/attendance/<id>` - 출근 기록 삭제

### 다우오피스 연동
- `POST /api/dauoffice/sync-employees` - 직원 동기화
- `POST /api/dauoffice/sync-attendance` - 출근 기록 동기화

### 기타
- `GET /api/export/excel?year=2026&month=1` - 엑셀 다운로드
- `GET /api/health` - 서버 상태 확인

## 🔒 보안 주의사항
- `.env` 파일은 절대 Git에 커밋하지 마세요
- 프로덕션 환경에서는 `FLASK_SECRET_KEY`를 반드시 변경하세요
- HTTPS를 사용하세요 (Let's Encrypt 무료 인증서)

## 📦 AWS EC2 배포

### 1. EC2 인스턴스 접속
```bash
ssh -i your-key.pem ubuntu@13.125.163.126
```

### 2. Docker 설치
```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose
sudo usermod -aG docker $USER
```

### 3. 프로젝트 업로드
```bash
# 로컬에서 실행
scp -i your-key.pem -r attendance-system ubuntu@13.125.163.126:~/
```

### 4. 실행
```bash
cd attendance-system
docker-compose up -d
```

### 5. 방화벽 설정
AWS 콘솔에서 Security Group 설정:
- HTTP (80) 포트 오픈
- HTTPS (443) 포트 오픈

## 🐛 문제 해결

### 다우오피스 API 연동 실패
1. API Key가 올바른지 확인
2. 서버 IP가 화이트리스트에 등록되었는지 확인
3. 네트워크 방화벽 확인

### 데이터베이스 오류
```bash
# 데이터베이스 초기화
docker-compose down -v
docker-compose up -d
```

## 📝 라이선스
MIT License

## 👨‍💻 개발자
CA사업본부 출근 관리 시스템

## 🎯 향후 개발 계획
- [ ] 모바일 반응형 개선
- [ ] 알림 기능 (미출근 시 이메일)
- [ ] 통계 대시보드
- [ ] 승인 워크플로우 (연차 신청)
- [ ] 사용자 권한 관리 (관리자/팀장/직원)
