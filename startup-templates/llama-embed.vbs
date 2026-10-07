' llama-embed.vbs - silent launcher for llama embedding service
' Replaces llama-embed.cmd to prevent terminal window flash at startup
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%") & "\.llama\start-embed.ps1""", 0, False
