' ================================================================
'  AMS ngrok 자동 시작 - 작업 스케줄러 등록 스크립트
'  더블클릭으로 실행하면 작업 스케줄러에 자동 등록됩니다
' ================================================================

Dim objShell, objFSO, strResult

Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")

' 배치 파일 경로
Dim batPath
batPath = "C:\AMS\start_ngrok_relay.bat"

' C:\AMS 폴더 생성
If Not objFSO.FolderExists("C:\AMS") Then
    objFSO.CreateFolder("C:\AMS")
End If
If Not objFSO.FolderExists("C:\AMS\logs") Then
    objFSO.CreateFolder("C:\AMS\logs")
End If

' 작업 스케줄러 등록 명령어
Dim xmlTask
xmlTask = "<?xml version=""1.0"" encoding=""UTF-16""?>" & vbCrLf & _
"<Task version=""1.2"" xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task"">" & vbCrLf & _
"  <Triggers>" & vbCrLf & _
"    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>" & vbCrLf & _
"  </Triggers>" & vbCrLf & _
"  <Settings>" & vbCrLf & _
"    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>" & vbCrLf & _
"    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>" & vbCrLf & _
"    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>" & vbCrLf & _
"  </Settings>" & vbCrLf & _
"  <Actions>" & vbCrLf & _
"    <Exec>" & vbCrLf & _
"      <Command>wscript.exe</Command>" & vbCrLf & _
"      <Arguments>""C:\AMS\run_ngrok_hidden.vbs""</Arguments>" & vbCrLf & _
"    </Exec>" & vbCrLf & _
"  </Actions>" & vbCrLf & _
"</Task>"

' XML 파일 저장
Dim xmlFile
xmlFile = objShell.ExpandEnvironmentStrings("%TEMP%") & "\ams_ngrok_task.xml"
Dim fWrite
Set fWrite = objFSO.CreateTextFile(xmlFile, True, True)
fWrite.Write xmlTask
fWrite.Close

' 작업 스케줄러에 등록
Dim cmd
cmd = "schtasks /Create /TN ""AMS_ngrok_relay"" /XML """ & xmlFile & """ /F"
Dim ret
ret = objShell.Run("cmd /c " & cmd, 0, True)

If ret = 0 Then
    MsgBox "✅ 작업 스케줄러 등록 완료!" & vbCrLf & vbCrLf & _
           "작업명: AMS_ngrok_relay" & vbCrLf & _
           "실행조건: 로그인 시 자동 시작" & vbCrLf & vbCrLf & _
           "지금 바로 시작하려면 확인 후" & vbCrLf & _
           "C:\AMS\start_ngrok_relay.bat 를 실행하세요.", _
           vbInformation, "AMS ngrok 자동 시작 설정"
Else
    MsgBox "❌ 등록 실패 (코드: " & ret & ")" & vbCrLf & vbCrLf & _
           "관리자 권한으로 다시 실행하거나" & vbCrLf & _
           "수동으로 작업 스케줄러에 등록하세요.", _
           vbCritical, "AMS ngrok 자동 시작 설정"
End If
