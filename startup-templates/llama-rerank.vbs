' llama-rerank.vbs - silent launcher for llama reranking service
' Replaces llama-rerank.cmd to prevent terminal window flash at startup
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%") & "\.llama\start-rerank.ps1""", 0, False
