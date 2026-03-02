' ================================================================
'  AMS ngrok - 콘솔 창 없이 백그라운드 실행
'  위치: C:\AMS\run_ngrok_hidden.vbs
' ================================================================

Dim objShell
Set objShell = CreateObject("WScript.Shell")

' 기존 ngrok 종료
objShell.Run "taskkill /F /IM ngrok.exe", 0, True

' 2초 대기
WScript.Sleep 2000

' ngrok 백그라운드 실행 (창 없음 = 0)
objShell.Run "C:\AMS\start_ngrok_relay.bat", 0, False
