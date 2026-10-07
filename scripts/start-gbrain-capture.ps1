# start-gbrain-capture.ps1
# opencode -> GBrain 语料导出器（bun 常驻循环）的幂等启动脚本。
# 用途：登录自启（Startup\gbrain-capture.cmd）与手动运行；已在运行则直接退出。
# 注意：必须用 bun.exe 运行 —— DLP 下 bun 写 .txt 为明文；
#       而 opencode(信任进程)写 .txt 会被加密（%TSD），gbrain(untrusted) 读不了。
$ErrorActionPreference = 'Continue'

$bun    = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
$script = Join-Path $env:USERPROFILE '.config\opencode\memory\scripts\gbrain-capture-export.ts'

$running = Get-CimInstance Win32_Process -Filter "Name='bun.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*gbrain-capture-export*' }
if ($running) {
  Write-Output 'gbrain-capture 导出器已在运行 - 无需操作。'
  exit 0
}

if (-not (Test-Path $bun))    { Write-Output "ERROR: 缺少 $bun";    exit 1 }
if (-not (Test-Path $script)) { Write-Output "ERROR: 缺少 $script"; exit 1 }

Start-Process -FilePath $bun -ArgumentList @('run', "`"$script`"") -WindowStyle Hidden -WorkingDirectory (Split-Path $script)
Write-Output 'gbrain-capture 导出器已启动（常驻循环，默认 180s 间隔）。'
exit 0
