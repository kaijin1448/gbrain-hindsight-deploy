' gbrain-capture.vbs - silent launcher for the gbrain corpus exporter
' Runs start-gbrain-capture.ps1 hidden so no console window flashes at login.
' The launch is idempotent: if the exporter is already running, the script exits.
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%") & "\.config\opencode\memory\scripts\start-gbrain-capture.ps1""", 0, False
