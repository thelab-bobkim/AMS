# 🚀 AWS EC2 배포 가이드

## 준비사항
- AWS EC2 인스턴스 (Ubuntu 20.04/22.04 권장)
- SSH 접근 권한
- 다우오피스 OpenAPI 인증키

## 방법 1: 자동 배포 스크립트 (권장)

### 1. 로컬에서 실행
```bash
# deploy.sh 파일 수정
# SERVER_IP, KEY_FILE 정보 입력 후 실행
./deploy.sh
```

### 2. 서버에서 API Key 설정
```bash
# SSH 접속
ssh -i your-key.pem ubuntu@13.125.163.126

# .env 파일 편집
cd attendance-system
nano .env

# DAUOFFICE_API_KEY에 발급받은 API Key 입력
DAUOFFICE_API_KEY=your_actual_api_key_here

# 저장 후 재시작
sudo docker-compose restart
```

---

## 방법 2: 수동 배포

### 1. 서버 접속
```bash
ssh -i your-key.pem ubuntu@13.125.163.126
```

### 2. Docker 설치
```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose git
sudo usermod -aG docker $USER
```

### 3. 프로젝트 업로드
```bash
# 로컬에서 실행 (별도 터미널)
scp -r -i your-key.pem attendance-system ubuntu@13.125.163.126:~/
```

### 4. 환경 설정
```bash
cd attendance-system
cp config/.env.example .env
nano .env

# DAUOFFICE_API_KEY 입력
```

### 5. 실행
```bash
sudo docker-compose up -d
```

### 6. 로그 확인
```bash
sudo docker-compose logs -f
```

---

## 방법 3: 로컬 테스트 (개발용)

### 백엔드 실행
```bash
cd backend
pip install -r requirements.txt
python create_sample_data.py  # 샘플 데이터 생성
python app.py
```

### 프론트엔드 실행
```bash
cd frontend
python -m http.server 8080
```

브라우저에서 http://localhost:8080 접속

---

## 🔍 확인사항

### 1. 서버 상태 확인
```bash
sudo docker-compose ps
```

### 2. API 테스트
```bash
curl http://localhost/api/health
```

### 3. 로그 확인
```bash
# 백엔드 로그
sudo docker-compose logs backend

# Nginx 로그
sudo docker-compose logs nginx
```

---

## 🔒 보안 설정

### 1. AWS Security Group
- HTTP (80) 포트 오픈
- HTTPS (443) 포트 오픈 (SSL 설정 시)
- SSH (22) 포트는 필요한 IP만 허용

### 2. SSL 인증서 (Let's Encrypt)
```bash
# Certbot 설치
sudo apt-get install certbot python3-certbot-nginx

# 인증서 발급
sudo certbot --nginx -d yourdomain.com
```

---

## 🐛 문제 해결

### 포트 충돌
```bash
# 기존 서비스 확인
sudo netstat -tlnp | grep :80

# 기존 서비스 중지
sudo systemctl stop apache2  # 또는 nginx
```

### Docker 권한 오류
```bash
sudo usermod -aG docker $USER
# 로그아웃 후 다시 로그인
```

### 데이터베이스 초기화
```bash
sudo docker-compose down -v
sudo docker-compose up -d
```

---

## 📞 연락처
문제 발생 시 시스템 관리자에게 문의하세요.
