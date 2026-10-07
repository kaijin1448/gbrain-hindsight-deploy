<#
brain-maintenance.ps1 — GBrain 维护窗口脚本（Hindsight 管道初始化 + 手动维护）
要求：opencode 完全退出（gbrain serve 未持锁）时运行；serve 持锁则退出码 2（可重试）。

步骤：
  1) 锁探测（gbrain stats；被占/异常 → 退出 2）
  2) 确保本地 llama 服务（embed:18080 / rerank:18081）
  3) config set: facts.default_visibility=world + search.reranker.enabled/model
  4) 回读校验 → 写 sweep-ready marker（开启导出器写门 + auto-sweep 门）
  5) 全量导出会话分段铺底（--max-segments 0 --no-sweep，带锁重试）
  6) 启动常驻导出器（幂等）
  7) dream 相位: extract_facts/consolidate/propose_takes/grade_takes/calibration_profile/embed（OpenCode 已重开则跳过）

退出码：0=成功；2=DB 被占用/可重试；3=可见性校验失败；1=参数/环境错误
用法：brain-maintenance.cmd（双击，带 pause）或 powershell -NoProfile -ExecutionPolicy Bypass -File brain-maintenance.ps1
#>
param(
  [switch]$SkipDream,
  [switch]$SkipExport
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Root     = $env:USERPROFILE
$Gbrain   = Join-Path $Root '.bun\bin\gbrain.exe'
$Bun      = Join-Path $Root '.bun\bin\bun.exe'
$Exporter = Join-Path $Root '.config\opencode\memory\scripts\gbrain-capture-export.ts'
$Starter  = Join-Path $Root '.config\opencode\memory\scripts\start-gbrain-capture.ps1'
$Marker   = Join-Path $Root '.gbrain\transcripts\sweep-enabled.md'
$LogDir   = Join-Path $Root '.config\opencode\memory\logs'
$LogFile  = Join-Path $LogDir ("brain-maintenance-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
# transcripts 目录是锁/marker/语料的落点；首次部署时 gbrain init 可能尚未创建它
$TransDir = Join-Path $Root '.gbrain\transcripts'
if (-not (Test-Path -LiteralPath $TransDir)) { New-Item -ItemType Directory -Path $TransDir -Force | Out-Null }
function Write-Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
  Write-Host $line
}
function Gb([string[]]$a) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = (& $Gbrain @a 2>&1 | Out-String); $c = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
  return @{ Code = $c; Out = $o }
}
function Port-Live([int]$port) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false)
    $live = ($ok -and $c.Connected)
    $c.Close(); return $live
  } catch { return $false }
}

Write-Log "===== brain-maintenance 开始（log=$LogFile）====="

# 单实例守卫（PID 锁文件；旧锁的 PID 已死则自动接管）
$LockFile = Join-Path $Root '.gbrain\transcripts\brain-maintenance.lock'
$lockBusy = $false
if (Test-Path -LiteralPath $LockFile) {
  $parts = ((Get-Content -LiteralPath $LockFile -Raw -ErrorAction SilentlyContinue) + '').Trim() -split '@'
  $oldPid = 0
  if ($parts.Count -ge 1) { [void][int]::TryParse($parts[0], [ref]$oldPid) }
  if ($oldPid -gt 0 -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) { $lockBusy = $true }
}
if ($lockBusy) { Write-Log '已有另一个 maintenance 在运行（PID 锁存活）- 退出'; exit 2 }
[IO.File]::WriteAllText($LockFile, ("{0}@{1}" -f $PID, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')), (New-Object Text.UTF8Encoding($false)))

# 1) 锁探测
$probe = Gb @('stats')
if ($probe.Code -ne 0) {
  if ($probe.Out -match 'already open|pglite_busy') { Write-Log 'SKIP: gbrain serve 仍持锁（请完全退出 opencode 再试）'; exit 2 }
  Write-Log ("SKIP: stats 异常 exit={0}: {1}" -f $probe.Code, (($probe.Out.Trim() -split "`r?`n" | Select-Object -First 1)))
  exit 2
}
Write-Log '锁探测通过（DB 空闲）'

# 2) llama 服务（启动脚本自带端点探针+幂等，直接调用；TCP 检查会被同端口 wildcard 应用欺骗，G-064）
foreach ($s in @(
  @{ n = 'embed';  script = (Join-Path $Root '.llama\start-embed.ps1') },
  @{ n = 'rerank'; script = (Join-Path $Root '.llama\start-rerank.ps1') }
)) {
  if (Test-Path -LiteralPath $s.script) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s.script 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
    Write-Log ("llama-{0}: {1}" -f $s.n, (($out.Trim() -split "`r?`n" | Select-Object -First 1)))
  } else { Write-Log ("WARN: 缺少 {0}" -f $s.script) }
}

# 2.1) 等待端点真正就绪（最多 120s；防"进程在但模型未加载完"）
foreach ($ep in @(
  @{ n = 'embed';  url = 'http://127.0.0.1:18080/v1/embeddings'; body = '{"input":"probe","model":"bge-m3"}' },
  @{ n = 'rerank'; url = 'http://127.0.0.1:18081/v1/rerank';     body = '{"query":"probe","documents":["a"],"model":"qwen3-reranker-06b"}' }
)) {
  $up = $false
  for ($i = 0; $i -lt 60; $i++) {
    try {
      $r = Invoke-WebRequest -Uri $ep.url -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($ep.body)) -ContentType 'application/json' -UseBasicParsing -TimeoutSec 8
      if ($r.StatusCode -eq 200) { $up = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
  }
  Write-Log ("llama-{0} 就绪={1}" -f $ep.n, $up)
}

# 2.5) 健康自检（serve 未运行，CLI 直测）：embed 探针 + 搜索模式/reranker 解析
$pt = Gb @('providers', 'test')
Write-Log ("embed 健康检查 => exit={0} | {1}" -f $pt.Code, (($pt.Out.Trim() -split "`r?`n" | Select-Object -Last 2) -join ' | '))
$sm = Gb @('search', 'modes')
Write-Log ("search modes => exit={0} | {1}" -f $sm.Code, ((($sm.Out -split "`r?`n") | Where-Object { $_ -match 'reranker|mode|Mode' } | Select-Object -First 10) -join ' | '))

# 3) config set（可见性 + reranker）
foreach ($kv in @(
  @('facts.default_visibility', 'world'),
  @('search.reranker.enabled', 'true'),
  @('search.reranker.model', 'llama-server-reranker:qwen3-reranker-06b'),
  @('search.reranker.timeout_ms', '20000'),
  @('search.reranker.top_n_in', '10')
)) {
  $r = Gb @('config', 'set', $kv[0], $kv[1])
  Write-Log ("config set {0}={1} => exit={2} {3}" -f $kv[0], $kv[1], $r.Code, (($r.Out.Trim() -split "`r?`n" | Select-Object -First 1)))
}

# 4) 校验 + marker
$vis = Gb @('config', 'get', 'facts.default_visibility')
if ($vis.Code -ne 0 -or $vis.Out -notmatch 'world') {
  Write-Log ("ABORT: facts.default_visibility 回读异常 exit={0} out={1}" -f $vis.Code, $vis.Out.Trim())
  exit 3
}
$rr = Gb @('config', 'get', 'search.reranker.enabled')
Write-Log ("回读 search.reranker.enabled = {0}" -f $rr.Out.Trim())
Set-Content -LiteralPath $Marker -Value ("enabled_at={0}`r`nconfig=facts.default_visibility=world`r`nby=brain-maintenance.ps1" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
Write-Log ("marker 已写：{0}" -f $Marker)

# 5) 全量导出铺底（marker 已写 → 写门开放；--no-sweep：serve 不在不触发 sweep）
if (-not $SkipExport) {
  $exportDone = $false
  for ($try = 1; $try -le 4; $try++) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = (& $Bun run $Exporter --once --max-segments 0 --no-sweep 2>&1 | Out-String); $c = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($out -match 'holds the lock') { Write-Log ("全量导出第 {0} 次: lock busy，5s 后重试" -f $try); Start-Sleep -Seconds 5; continue }
    Write-Log ("全量导出 => exit={0} | {1}" -f $c, (($out.Trim() -split "`r?`n" | Select-Object -Last 2) -join ' | '))
    $exportDone = $true; break
  }
  if (-not $exportDone) { Write-Log '全量导出未拿到锁（常驻导出器在跑）- 由其按节奏续跑，继续后续步骤' }
}

# 6) 启动常驻导出器（幂等）
if ((-not $SkipExport) -and (Test-Path -LiteralPath $Starter)) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Starter 2>&1 | Out-String) } finally { $ErrorActionPreference = $old }
  Write-Log ("启动导出器: {0}" -f $out.Trim())
}

# 7) dream 相位（重开 opencode 则跳过；避免 serve 抢锁竞争）
$oc = Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue
if ($SkipDream) { Write-Log 'dream 已按参数跳过' }
elseif ($oc) { Write-Log 'WARN: 检测到 OpenCode 已在运行，跳过 dream 相位（避免锁竞争）' }
else {
  Write-Log 'dream 开始（6 相位逐项执行；重开 opencode 则中止剩余）'
  foreach ($ph in @('extract_facts', 'consolidate', 'propose_takes', 'grade_takes', 'calibration_profile', 'embed')) {
    if (Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue) { Write-Log 'WARN: opencode 已重新打开，中止剩余 dream 相位'; break }
    Write-Log ("dream[{0}] 开始…" -f $ph)
    $t0 = Get-Date
    $r = Gb @('dream', '--phase', $ph, '--json')
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    Write-Log ("dream[{0}] => exit={1} 用时 {2}s | {3}" -f $ph, $r.Code, $secs, (($r.Out.Trim() -split "`r?`n" | Select-Object -Last 2) -join ' | '))
  }
}

Write-Log '===== brain-maintenance 完成 ====='
exit 0
