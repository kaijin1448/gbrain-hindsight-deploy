<#
brain-onclose.ps1 — 一次性守望：opencode 完全关闭 ≥5 分钟后自动执行 brain-maintenance.ps1
触发条件（二选一）：
  A) 首次初始化：sweep-enabled marker 不存在时
  B) 按需维护：存在请求旗标 ~\.gbrain\transcripts\maintenance-requested.md 时（跑完自动清除）
行为：
  - 单实例守卫；marker 已存在且无请求旗标 → 清理 Startup 入口并退出
  - 每 30s 检查 OpenCode.exe：关闭 ≥5 分钟宽限 → 调 brain-maintenance.ps1
  - 维护 rc=0 → 清除请求旗标、自退并清理 Startup\brain-onclose.cmd；rc=2/3 → 继续守望下次关闭；rc=1/其它 → 退出（需手动）
由 Startup\brain-onclose.cmd 于登录时拉起（幂等），也可手动启动。
#>
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Root       = $env:USERPROFILE
$LogDir     = Join-Path $Root '.config\opencode\memory\logs'
$Log        = Join-Path $LogDir 'brain-onclose.log'
$Marker     = Join-Path $Root '.gbrain\transcripts\sweep-enabled.md'
$Maint      = Join-Path $Root '.config\opencode\memory\scripts\brain-maintenance.ps1'
$StartupCmd = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\brain-onclose.cmd'
$GraceMinutes = 5

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
# transcripts 目录是锁/marker 的落点；首次部署时可能尚未创建
$TransDir = Join-Path $Root '.gbrain\transcripts'
if (-not (Test-Path -LiteralPath $TransDir)) { New-Item -ItemType Directory -Path $TransDir -Force | Out-Null }
function Write-Log([string]$msg) {
  try { Add-Content -LiteralPath $Log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}

# 单实例守卫（PID 锁文件；旧锁的 PID 已死则自动接管）
$LockFile = Join-Path $Root '.gbrain\transcripts\brain-onclose.lock'
$lockBusy = $false
if (Test-Path -LiteralPath $LockFile) {
  $parts = ((Get-Content -LiteralPath $LockFile -Raw -ErrorAction SilentlyContinue) + '').Trim() -split '@'
  $oldPid = 0
  if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$oldPid) }
  if ($oldPid -gt 0 -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) { $lockBusy = $true }
}
if ($lockBusy) { Write-Log '已有另一个 watcher 实例（PID 锁存活）- 退出'; exit 0 }
[IO.File]::WriteAllText($LockFile, ("{0}@{1}" -f $PID, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), (New-Object Text.UTF8Encoding($false)))

Write-Log ("watcher 启动 pid={0}" -f $PID)
$Request = Join-Path $Root '.gbrain\transcripts\maintenance-requested.md'
if ((Test-Path -LiteralPath $Marker) -and -not (Test-Path -LiteralPath $Request)) {
  Write-Log 'marker 已存在且无维护请求 - 清理 Startup 入口并退出'
  try { Remove-Item -LiteralPath $StartupCmd -Force -ErrorAction Stop; Write-Log 'Startup 入口已清理' } catch { Write-Log ('Startup 清理失败: ' + $_.Exception.Message) }
  exit 0
}
if (Test-Path -LiteralPath $Request) { Write-Log '检测到维护请求旗标 - 进入守望（等待关闭窗口）' }

$closedSince = $null
while ($true) {
  $oc = Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue
  if ($oc) {
    if ($null -ne $closedSince) { Write-Log 'opencode 重新打开 - 宽限计时清零' }
    $closedSince = $null
  } else {
    if ($null -eq $closedSince) {
      $closedSince = Get-Date
      Write-Log 'opencode 已关闭 - 开始 5 分钟宽限计时'
    } elseif (((Get-Date) - $closedSince).TotalMinutes -ge $GraceMinutes) {
      Write-Log '宽限期满 - 执行 brain-maintenance.ps1'
      $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Maint 2>&1 | Out-String); $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
      Write-Log ("维护返回 rc={0} | {1}" -f $rc, (($out.Trim() -split "`r?`n" | Select-Object -Last 3) -join ' | '))
      if ($rc -eq 0) {
        try { Remove-Item -LiteralPath $Request -Force -ErrorAction SilentlyContinue; Write-Log '维护请求旗标已清除' } catch {}
        Write-Log '维护成功 - watcher 一次性任务完成，自退'
        try { Remove-Item -LiteralPath $StartupCmd -Force -ErrorAction Stop; Write-Log 'Startup 入口已清理' } catch { Write-Log ('Startup 清理失败: ' + $_.Exception.Message) }
        exit 0
      }
      if ($rc -eq 2 -or $rc -eq 3) { Write-Log ("维护被跳过（rc={0}，环境未就绪）- 继续守望下一次关闭" -f $rc); $closedSince = $null }
      else {
        Write-Log ("维护失败 rc={0} - watcher 退出；请手动运行 brain-maintenance.cmd 并在 brain-maintenance-*.log 查看原因" -f $rc)
        exit 1
      }
    }
  }
  Start-Sleep -Seconds 30
}
