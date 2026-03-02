@echo off
:: ================================================================
::  AMS ngrok 전체 설치 스크립트
::  관리자 권한으로 실행하세요 (우클릭 → 관리자 권한으로 실행)
:: ================================================================

echo ================================================================
echo   AMS SenseLink Relay - ngrok 자동 시작 설치
echo ================================================================
echo.

:: ── 관리자 권한 확인 ─────────────────────────────────────────
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ❌ 관리자 권한이 필요합니다.
    echo    이 파일을 우클릭 후 "관리자 권한으로 실행" 하세요.
    pause
    exit /b 1
)

:: ── 폴더 생성 ────────────────────────────────────────────────
echo ▶ 1단계: C:\AMS 폴더 생성...
if not exist "C:\AMS" mkdir "C:\AMS"
if not exist "C:\AMS\logs" mkdir "C:\AMS\logs"
if not exist "C:\tools\ngrok" mkdir "C:\tools\ngrok"
echo    ✅ 폴더 생성 완료

:: ── 스크립트 파일 복사 ───────────────────────────────────────
echo ▶ 2단계: 스크립트 파일 복사...
copy /Y "%~dp0start_ngrok_relay.bat"  "C:\AMS\start_ngrok_relay.bat"  >nul
copy /Y "%~dp0run_ngrok_hidden.vbs"   "C:\AMS\run_ngrok_hidden.vbs"   >nul
echo    ✅ 파일 복사 완료

:: ── ngrok 설치 확인 ──────────────────────────────────────────
echo ▶ 3단계: ngrok 설치 확인...
where ngrok >nul 2>&1
if %ERRORLEVEL% == 0 (
    FOR /F "tokens=*" %%i IN ('where ngrok') DO SET NGROK_FOUND=%%i
    echo    ✅ ngrok 발견: %NGROK_FOUND%
    :: start_ngrok_relay.bat의 경로 자동 수정
    powershell -Command "(Get-Content 'C:\AMS\start_ngrok_relay.bat') -replace 'SET NGROK_PATH=C:\\tools\\ngrok\\ngrok.exe', 'SET NGROK_PATH=%NGROK_FOUND%' | Set-Content 'C:\AMS\start_ngrok_relay.bat'"
) else (
    if exist "C:\tools\ngrok\ngrok.exe" (
        echo    ✅ ngrok 발견: C:\tools\ngrok\ngrok.exe
    ) else (
        echo    ⚠️  ngrok이 없습니다. 자동 다운로드 중...
        :: winget으로 설치 시도
        winget install ngrok.ngrok --silent >nul 2>&1
        if %ERRORLEVEL% == 0 (
            echo    ✅ ngrok 설치 완료 (winget)
        ) else (
            echo    ⚠️  winget 설치 실패. 수동 설치 안내:
            echo       1. https://ngrok.com/download 에서 Windows용 다운로드
            echo       2. ngrok.exe를 C:\tools\ngrok\ 에 복사
            echo       3. 이 스크립트를 다시 실행하세요
            pause
        )
    )
)

:: ── ngrok authtoken 설정 확인 ────────────────────────────────
echo ▶ 4단계: ngrok 인증 토큰 확인...
ngrok config check >nul 2>&1
if %ERRORLEVEL% == 0 (
    echo    ✅ ngrok 인증 토큰 설정됨
) else (
    echo    ⚠️  ngrok 인증 토큰이 없습니다.
    echo       https://dashboard.ngrok.com/get-started/your-authtoken 에서 토큰 확인 후:
    set /p NGROK_TOKEN="    ngrok authtoken 입력: "
    ngrok config add-authtoken %NGROK_TOKEN%
    echo    ✅ 인증 토큰 설정 완료
)

:: ── 작업 스케줄러 등록 ───────────────────────────────────────
echo ▶ 5단계: 작업 스케줄러 등록 (로그인 시 자동 시작)...
schtasks /Delete /TN "AMS_ngrok_relay" /F >nul 2>&1

schtasks /Create /TN "AMS_ngrok_relay" ^
  /TR "wscript.exe \"C:\AMS\run_ngrok_hidden.vbs\"" ^
  /SC ONLOGON ^
  /RL HIGHEST ^
  /F >nul 2>&1

if %ERRORLEVEL% == 0 (
    echo    ✅ 작업 스케줄러 등록 완료
    echo       작업명: AMS_ngrok_relay
    echo       실행조건: 로그인 시 자동 시작 (백그라운드)
) else (
    echo    ❌ 작업 스케줄러 등록 실패
)

:: ── 지금 즉시 실행 ───────────────────────────────────────────
echo ▶ 6단계: ngrok 즉시 시작...
taskkill /F /IM ngrok.exe >nul 2>&1
timeout /t 1 /nobreak >nul
start "" /B wscript.exe "C:\AMS\run_ngrok_hidden.vbs"
timeout /t 5 /nobreak >nul

tasklist /FI "IMAGENAME eq ngrok.exe" 2>nul | find /I "ngrok.exe" >nul
if %ERRORLEVEL% == 0 (
    echo    ✅ ngrok 실행 중!
) else (
    echo    ❌ ngrok 실행 실패 - 로그 확인: C:\AMS\logs\ngrok_relay.log
)

:: ── 연결 테스트 ──────────────────────────────────────────────
echo ▶ 7단계: relay 연결 테스트 (10초 대기)...
timeout /t 10 /nobreak >nul
curl -s -o nul -w "   HTTP 응답코드: %%{http_code}" ^
  "https://luke-subfestive-phyliss.ngrok-free.app/sl/api/v5/records?page=1&size=1" 2>nul || ^
  echo    ⚠️  curl 없음 - 브라우저에서 확인하세요

:: ── 완료 ─────────────────────────────────────────────────────
echo.
echo ================================================================
echo   ✅ 설치 완료!
echo ================================================================
echo.
echo   📋 등록된 작업: AMS_ngrok_relay
echo   🔗 relay URL : https://luke-subfestive-phyliss.ngrok-free.app
echo   📄 로그 파일 : C:\AMS\logs\ngrok_relay.log
echo   🔄 재부팅 후 : 자동으로 ngrok이 백그라운드 실행됩니다
echo.
echo   ※ 작업 스케줄러 확인: 시작 → 작업 스케줄러 → AMS_ngrok_relay
echo.
pause
