
# ================================================================
#  AMS ngrok relay - PowerShell 설치 스크립트
# ================================================================
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  AMS SenseLink Relay - ngrok 자동 시작 설치" -ForegroundColor Cyan
Write-Host "================================================================"
Write-Host ""

# [1/5] 폴더 생성
Write-Host "[1/5] C:\AMS 폴더 생성 중..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path "C:\AMS" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\AMS\logs" | Out-Null
Write-Host "      완료" -ForegroundColor Green

# [2/5] GitHub에서 파일 다운로드
Write-Host "[2/5] GitHub에서 파일 다운로드 중..." -ForegroundColor Yellow
$base = "https://raw.githubusercontent.com/thelab-bobkim/AMS/main/scripts/windows"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri "$base/start_ngrok_relay.bat" -OutFile "C:\AMS\start_ngrok_relay.bat" -UseBasicParsing
    Write-Host "      start_ngrok_relay.bat 완료" -ForegroundColor Green
    Invoke-WebRequest -Uri "$base/run_ngrok_hidden.vbs"  -OutFile "C:\AMS\run_ngrok_hidden.vbs"  -UseBasicParsing
    Write-Host "      run_ngrok_hidden.vbs 완료" -ForegroundColor Green
} catch {
    Write-Host "      다운로드 실패: $_" -ForegroundColor Red
    # 직접 파일 내용 생성 (fallback)
    Write-Host "      직접 파일 생성 중 (fallback)..." -ForegroundColor Yellow

    $bat = @'
@echo off
SET NGROK_PATH=ngrok
SET SENSELINK_URL=http://175.198.93.89:8765
SET NGROK_DOMAIN=luke-subfestive-phyliss.ngrok-free.app
SET LOG_FILE=C:\AMS\logs\ngrok_relay.log
if not exist "C:\AMS\logs" mkdir "C:\AMS\logs"
taskkill /F /IM ngrok.exe >nul 2>&1
timeout /t 2 /nobreak >nul
echo [%date% %time%] ngrok relay 시작 >> "%LOG_FILE%"
start "" /B %NGROK_PATH% http --domain=%NGROK_DOMAIN% %SENSELINK_URL%
'@
    $bat | Out-File -FilePath "C:\AMS\start_ngrok_relay.bat" -Encoding ascii
    Write-Host "      start_ngrok_relay.bat 생성 완료" -ForegroundColor Green

    $vbs = @'
Dim objShell
Set objShell = CreateObject("WScript.Shell")
objShell.Run "taskkill /F /IM ngrok.exe", 0, True
WScript.Sleep 2000
objShell.Run "C:\AMS\start_ngrok_relay.bat", 0, False
'@
    $vbs | Out-File -FilePath "C:\AMS\run_ngrok_hidden.vbs" -Encoding ascii
    Write-Host "      run_ngrok_hidden.vbs 생성 완료" -ForegroundColor Green
}

# [3/5] ngrok 확인 및 설치
Write-Host "[3/5] ngrok 확인 중..." -ForegroundColor Yellow
$ngrokPath = (Get-Command ngrok -ErrorAction SilentlyContinue)?.Source
if (-not $ngrokPath) { $ngrokPath = "C:\tools\ngrok\ngrok.exe" }

if (Test-Path $ngrokPath) {
    Write-Host "      ngrok 발견: $ngrokPath" -ForegroundColor Green
    # start_ngrok_relay.bat 경로 업데이트
    (Get-Content "C:\AMS\start_ngrok_relay.bat") -replace 'SET NGROK_PATH=ngrok', "SET NGROK_PATH=$ngrokPath" |
        Set-Content "C:\AMS\start_ngrok_relay.bat"
} else {
    Write-Host "      ngrok 없음 - winget 설치 시도..." -ForegroundColor Yellow
    try {
        winget install ngrok.ngrok --silent --accept-source-agreements --accept-package-agreements
        Write-Host "      ngrok 설치 완료" -ForegroundColor Green
    } catch {
        Write-Host "      [중요] ngrok을 수동 설치해주세요:" -ForegroundColor Red
        Write-Host "        1. https://ngrok.com/download 방문" -ForegroundColor White
        Write-Host "        2. Windows 64-bit 다운로드" -ForegroundColor White
        Write-Host "        3. ngrok.exe 를 C:\tools\ngrok\ 에 복사" -ForegroundColor White
        Write-Host "        4. 이 스크립트 다시 실행" -ForegroundColor White
        Read-Host "계속하려면 Enter"
    }
}

# [4/5] 작업 스케줄러 등록
Write-Host "[4/5] 작업 스케줄러 등록 중..." -ForegroundColor Yellow
$action  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument '"C:\AMS\run_ngrok_hidden.vbs"'
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId (whoami) -RunLevel Highest

try {
    Unregister-ScheduledTask -TaskName "AMS_ngrok_relay" -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName "AMS_ngrok_relay" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "      등록 완료: 로그인 시 자동 시작 (AMS_ngrok_relay)" -ForegroundColor Green
} catch {
    Write-Host "      [경고] 작업 스케줄러 등록 실패: $_" -ForegroundColor Red
}

# [5/5] ngrok 즉시 실행
Write-Host "[5/5] ngrok 즉시 시작 중..." -ForegroundColor Yellow
Stop-Process -Name ngrok -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Start-Process wscript.exe -ArgumentList '"C:\AMS\run_ngrok_hidden.vbs"' -WindowStyle Hidden
Start-Sleep -Seconds 7

$ngrokProc = Get-Process -Name ngrok -ErrorAction SilentlyContinue
if ($ngrokProc) {
    Write-Host "      ngrok 실행 중 (PID: $($ngrokProc.Id))" -ForegroundColor Green
} else {
    Write-Host "      [경고] ngrok 미실행 - 로그 확인: C:\AMS\logs\ngrok_relay.log" -ForegroundColor Red
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  설치 완료!" -ForegroundColor Green
Write-Host "================================================================"
Write-Host ""
Write-Host "  relay URL  : https://luke-subfestive-phyliss.ngrok-free.app" -ForegroundColor White
Write-Host "  로그 파일  : C:\AMS\logs\ngrok_relay.log" -ForegroundColor White
Write-Host "  작업 스케줄: 작업 스케줄러 > AMS_ngrok_relay" -ForegroundColor White
Write-Host ""
Write-Host "  재부팅 후 ngrok이 자동으로 백그라운드 실행됩니다." -ForegroundColor Yellow
Write-Host ""
Read-Host "완료. Enter를 누르면 창이 닫힙니다"
