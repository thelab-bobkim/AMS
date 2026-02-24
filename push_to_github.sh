#!/bin/bash

# GitHub Push 스크립트
# 이 스크립트는 샌드박스에서 직접 실행할 수 없습니다.
# 로컬 머신에서 실행하세요.

echo "🚀 GitHub Push 준비..."

cd /home/user/attendance-system

# Git 상태 확인
echo ""
echo "📊 현재 Git 상태:"
git status

echo ""
echo "📝 커밋 내역:"
git log --oneline

echo ""
echo "🔗 원격 저장소:"
git remote -v

echo ""
echo "⚠️  주의사항:"
echo "1. 이 스크립트는 샌드박스에서 직접 push할 수 없습니다."
echo "2. 다음 중 하나의 방법으로 push하세요:"
echo ""
echo "방법 1: GitHub CLI (권장)"
echo "  gh auth login"
echo "  git push -u origin main"
echo ""
echo "방법 2: Personal Access Token"
echo "  git push -u origin main"
echo "  (Username: thelab-bobkim)"
echo "  (Password: Personal Access Token 입력)"
echo ""
echo "방법 3: 로컬 머신에서 실행"
echo "  1. attendance-system.tar.gz 다운로드"
echo "  2. 압축 해제"
echo "  3. cd attendance-system"
echo "  4. git push -u origin main"
echo ""
echo "🌐 GitHub 저장소: https://github.com/thelab-bobkim/AMS"
