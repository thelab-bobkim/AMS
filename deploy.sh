#!/bin/bash

# AWS EC2 배포 스크립트
# 사용법: ./deploy.sh

echo "🚀 출근 관리 시스템 배포 시작..."

# 1. 서버 정보 설정
SERVER_IP="13.125.163.126"
SERVER_USER="ubuntu"  # 또는 ec2-user
KEY_FILE="your-key.pem"  # SSH 키 파일 경로

echo "📦 1. 프로젝트 파일 압축 중..."
tar -czf attendance-system.tar.gz \
    backend/ \
    frontend/ \
    config/ \
    docker-compose.yml \
    Dockerfile \
    nginx.conf \
    README.md

echo "📤 2. 서버로 파일 전송 중..."
scp -i $KEY_FILE attendance-system.tar.gz $SERVER_USER@$SERVER_IP:~/

echo "🔧 3. 서버에서 배포 실행 중..."
ssh -i $KEY_FILE $SERVER_USER@$SERVER_IP << 'ENDSSH'
    # 압축 해제
    tar -xzf attendance-system.tar.gz
    cd attendance-system
    
    # Docker 설치 확인
    if ! command -v docker &> /dev/null; then
        echo "Docker 설치 중..."
        sudo apt-get update
        sudo apt-get install -y docker.io docker-compose
        sudo usermod -aG docker $USER
    fi
    
    # .env 파일 생성 (수동으로 API Key 입력 필요)
    if [ ! -f .env ]; then
        cp config/.env.example .env
        echo "⚠️  .env 파일이 생성되었습니다. DAUOFFICE_API_KEY를 입력해주세요."
    fi
    
    # 기존 컨테이너 중지 및 제거
    sudo docker-compose down
    
    # 새로운 컨테이너 빌드 및 실행
    sudo docker-compose up -d --build
    
    echo "✅ 배포 완료!"
    echo "📊 서버 상태:"
    sudo docker-compose ps
ENDSSH

echo "🎉 배포가 완료되었습니다!"
echo "🌐 접속 주소: http://$SERVER_IP"
echo ""
echo "⚠️  다음 단계:"
echo "1. SSH로 서버 접속: ssh -i $KEY_FILE $SERVER_USER@$SERVER_IP"
echo "2. .env 파일 편집: cd attendance-system && nano .env"
echo "3. DAUOFFICE_API_KEY 입력 후 저장"
echo "4. 서비스 재시작: sudo docker-compose restart"

# 로컬 압축 파일 삭제
rm attendance-system.tar.gz
