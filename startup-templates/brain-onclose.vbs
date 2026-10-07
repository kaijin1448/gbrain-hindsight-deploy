' brain-onclose.vbs - silent one-shot maintenance watcher (optional)
' If opencode stays closed >= 5 minutes, runs brain-maintenance.ps1 once, then retires.
' Only needed for the first-time initialization; it removes its own Startup entry when done.
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%") & "\.config\opencode\memory\scripts\brain-onclose.ps1""", 0, False
