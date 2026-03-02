@echo off
:: ================================================================
::  AMS SenseLink Relay - ngrok 자동 시작 스크립트
::  위치: C:\AMS\start_ngrok_relay.bat
::  설명: 부팅 시 ngrok을 백그라운드로 자동 실행
:: ================================================================

title AMS SenseLink Relay

:: ngrok 설치 경로 (설치 위치에 맞게 수정)
SET NGROK_PATH=C:\tools\ngrok\ngrok.exe
:: ngrok이 PATH에 등록되어 있으면 아래 줄 사용
:: SET NGROK_PATH=ngrok

:: SenseLink 서버 주소
SET SENSELINK_URL=http://175.198.93.89:8765

:: ngrok static domain
SET NGROK_DOMAIN=luke-subfestive-phyliss.ngrok-free.app

:: 로그 파일
SET LOG_FILE=C:\AMS\logs\ngrok_relay.log

:: ── 로그 폴더 생성 ──────────────────────────────────────────
if not exist "C:\AMS\logs" mkdir "C:\AMS\logs"

:: ── 이미 실행 중인 ngrok 종료 ───────────────────────────────
taskkill /F /IM ngrok.exe >nul 2>&1
timeout /t 2 /nobreak >nul

:: ── ngrok 실행 로그 기록 ─────────────────────────────────────
echo [%date% %time%] AMS ngrok relay 시작 >> "%LOG_FILE%"
echo [%date% %time%] Domain: %NGROK_DOMAIN% >> "%LOG_FILE%"
echo [%date% %time%] Target: %SENSELINK_URL% >> "%LOG_FILE%"

:: ── ngrok 백그라운드 실행 ────────────────────────────────────
start "" /B "%NGROK_PATH%" http --domain=%NGROK_DOMAIN% %SENSELINK_URL% >> "%LOG_FILE%" 2>&1

:: ── 실행 확인 (5초 대기 후 체크) ────────────────────────────
timeout /t 5 /nobreak >nul

tasklist /FI "IMAGENAME eq ngrok.exe" 2>nul | find /I "ngrok.exe" >nul
if %ERRORLEVEL% == 0 (
    echo [%date% %time%] ngrok 실행 성공 >> "%LOG_FILE%"
    echo ✅ ngrok relay 시작 완료
    echo    Domain: https://%NGROK_DOMAIN%
    echo    Target: %SENSELINK_URL%
) else (
    echo [%date% %time%] ❌ ngrok 실행 실패 >> "%LOG_FILE%"
    echo ❌ ngrok 실행 실패 - 경로를 확인하세요: %NGROK_PATH%
    pause
)
