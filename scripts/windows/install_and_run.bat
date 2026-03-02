@echo off
:: ================================================================
::  AMS ngrok relay - CMD 원클릭 설치
::  실행: 관리자 CMD에서 이 파일을 실행
:: ================================================================
echo ================================================================
echo   AMS SenseLink Relay - ngrok 자동 시작 설치
echo   GitHub: thelab-bobkim/AMS
echo ================================================================
echo.

:: 관리자 권한 확인
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [오류] 관리자 권한으로 실행해주세요.
    echo        CMD 우클릭 ^> 관리자 권한으로 실행
    pause & exit /b 1
)

:: C:\AMS 폴더 생성
echo [1/5] 폴더 생성 중...
if not exist "C:\AMS"       mkdir "C:\AMS"
if not exist "C:\AMS\logs"  mkdir "C:\AMS\logs"
echo       완료: C:\AMS

:: GitHub RAW URL 베이스
set BASE=https://raw.githubusercontent.com/thelab-bobkim/AMS/main/scripts/windows

:: 파일 다운로드 (curl - Windows 10/11 기본 내장)
echo [2/5] GitHub에서 파일 다운로드 중...
curl -s -L "%BASE%/start_ngrok_relay.bat" -o "C:\AMS\start_ngrok_relay.bat"
echo       start_ngrok_relay.bat 완료
curl -s -L "%BASE%/run_ngrok_hidden.vbs"  -o "C:\AMS\run_ngrok_hidden.vbs"
echo       run_ngrok_hidden.vbs  완료
echo       다운로드 완료

:: ngrok 설치 확인
echo [3/5] ngrok 설치 확인 중...
where ngrok >nul 2>&1
if %ERRORLEVEL% == 0 (
    for /f "tokens=*" %%i in ('where ngrok') do set NGROK_EXE=%%i
    echo       ngrok 발견: %NGROK_EXE%
    powershell -Command "(Get-Content 'C:\AMS\start_ngrok_relay.bat') -replace 'C:\\tools\\ngrok\\ngrok.exe', '%NGROK_EXE:\=\\%' | Set-Content 'C:\AMS\start_ngrok_relay.bat'"
) else if exist "C:\tools\ngrok\ngrok.exe" (
    echo       ngrok 발견: C:\tools\ngrok\ngrok.exe
) else (
    echo       ngrok 없음 - winget으로 설치 중...
    winget install ngrok.ngrok --silent --accept-source-agreements --accept-package-agreements
    if %ERRORLEVEL% == 0 (
        echo       ngrok 설치 완료
        for /f "tokens=*" %%i in ('where ngrok 2^>nul') do set NGROK_EXE=%%i
        if defined NGROK_EXE (
            powershell -Command "(Get-Content 'C:\AMS\start_ngrok_relay.bat') -replace 'C:\\tools\\ngrok\\ngrok.exe', '%NGROK_EXE:\=\\%' | Set-Content 'C:\AMS\start_ngrok_relay.bat'"
        )
    ) else (
        echo       winget 실패 - ngrok.exe를 C:\tools\ngrok\ 에 수동으로 복사 후 재실행
        pause & exit /b 1
    )
)

:: 작업 스케줄러 등록 (로그인 시 자동 시작)
echo [4/5] 작업 스케줄러 등록 중...
schtasks /Delete /TN "AMS_ngrok_relay" /F >nul 2>&1
schtasks /Create /TN "AMS_ngrok_relay" /TR "wscript.exe \"C:\AMS\run_ngrok_hidden.vbs\"" /SC ONLOGON /RL HIGHEST /F >nul 2>&1
if %ERRORLEVEL% == 0 (
    echo       등록 완료: 로그인 시 자동 시작
) else (
    echo       [경고] 작업 스케줄러 등록 실패
)

:: ngrok 즉시 시작
echo [5/5] ngrok 즉시 시작 중...
taskkill /F /IM ngrok.exe >nul 2>&1
timeout /t 1 /nobreak >nul
start "" wscript.exe "C:\AMS\run_ngrok_hidden.vbs"
timeout /t 6 /nobreak >nul

tasklist /FI "IMAGENAME eq ngrok.exe" 2>nul | find /I "ngrok.exe" >nul
if %ERRORLEVEL% == 0 (
    echo       ngrok 실행 중
) else (
    echo       [경고] ngrok 실행 실패
    echo              로그: C:\AMS\logs\ngrok_relay.log
)

echo.
echo ================================================================
echo   설치 완료!
echo ================================================================
echo.
echo   relay URL : https://luke-subfestive-phyliss.ngrok-free.app
echo   로그 파일 : C:\AMS\logs\ngrok_relay.log
echo   작업 확인 : 작업 스케줄러 ^> AMS_ngrok_relay
echo.
echo   재부팅 후 ngrok이 자동으로 백그라운드 실행됩니다.
echo.
pause
