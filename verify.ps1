<#
.SYNOPSIS
  GBrain「Hindsight 三件套」部署验收（对齐部署报告 §6 清单）

.DESCRIPTION
  逐项检查并将结果打印为 PASS / FAIL / WARN 清单：
    1. gbrain 版本 ≥ 0.52.1
    2. 嵌入探针 200 / 重排探针 200
    3. gbrain providers test（serve 未运行时）
    4. sweep-enabled marker 存在
    5. facts.default_visibility = world
    6. 导出器日志持续出现 pass done
    7. corpus .txt/.ingested 计数
    8. 维护日志 dream 相位
    9. (可选) 检索召回测试

.PARAMETER EmbedPort
  嵌入服务端口（默认 18080）

.PARAMETER RerankPort
  重排服务端口（默认 18081）

.PARAMETER LlamaRoot
  .llama 目录位置（默认 %USERPROFILE%\.llama）

.PARAMETER RecallQuery
  可选：对 gbrain 发起一次检索以验证召回（如 "部署"）

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
#>

[CmdletBinding()]
param(
  [int]$EmbedPort = 18080,
  [int]$RerankPort = 18081,
  [string]$LlamaRoot = '',
  [string]$RecallQuery = ''
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if (-not $LlamaRoot) { $LlamaRoot = Join-Path $env:USERPROFILE '.llama' }

$script:Pass = 0; $script:Fail = 0; $script:Warn = 0
function R-Pass([string]$m) { Write-Host ("  [PASS] " + $m) -ForegroundColor Green; $script:Pass++ }
function R-Fail([string]$m) { Write-Host ("  [FAIL] " + $m) -ForegroundColor Red; $script:Fail++ }
function R-Warn([string]$m) { Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow; $script:Warn++ }
function R-Info([string]$m) { Write-Host ("  [ .. ] " + $m) -ForegroundColor Gray }

$gbrainExe = Join-Path $env:USERPROFILE '.bun\bin\gbrain.exe'
$bunExe    = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
$memoryDir = Join-Path $env:USERPROFILE '.config\opencode\memory'
$logsDir   = Join-Path $memoryDir 'logs'
$scriptsDir = Join-Path $memoryDir 'scripts'
$brainDir  = Join-Path $env:USERPROFILE '.gbrain'
$corpusDir = Join-Path $brainDir 'transcripts\corpus'
$marker    = Join-Path $brainDir 'transcripts\sweep-enabled.md'

Write-Host "===== GBrain Hindsight 三件套 · 验收 =====" -ForegroundColor Cyan
Write-Host ("机器: " + $env:COMPUTERNAME + " | 用户: " + $env:USERNAME + " | " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Write-Host ""

# 1. version
Write-Host "[1] gbrain 版本" -ForegroundColor Cyan
if (Test-Path -LiteralPath $gbrainExe) {
  $verOut = (& $gbrainExe --version 2>&1 | Out-String).Trim()
  if ($verOut -match '(\d+)\.(\d+)\.(\d+)') {
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]
    if (($maj -gt 0) -or ($min -ge 52)) { R-Pass ("gbrain " + $verOut) } else { R-Fail ("gbrain 版本过低: " + $verOut + "（需 ≥ 0.52.1）") }
  } else { R-Warn ("无法解析版本: " + $verOut) }
} else { R-Fail ('未找到 ' + $gbrainExe + '（先运行 deploy.ps1）') }

# 2. probes
Write-Host ""
Write-Host "[2] 本地服务探针" -ForegroundColor Cyan
$embOk = $false; $rerOk = $false
try {
  $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/embeddings" -f $EmbedPort) -Method Post `
    -Body ([Text.Encoding]::UTF8.GetBytes('{"input":"probe","model":"bge-m3"}')) `
    -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
  $embOk = ($r.StatusCode -eq 200)
} catch { }
if ($embOk) { R-Pass ("嵌入探针 200（127.0.0.1:" + $EmbedPort + "）") } else { R-Fail ("嵌入探针失败（127.0.0.1:" + $EmbedPort + "）→ 运行 ~\.llama\start-embed.ps1 后重试") }
try {
  $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/rerank" -f $RerankPort) -Method Post `
    -Body ([Text.Encoding]::UTF8.GetBytes('{"query":"q","documents":["a"],"model":"qwen3-reranker-06b"}')) `
    -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
  $rerOk = ($r.StatusCode -eq 200)
} catch { }
if ($rerOk) { R-Pass ("重排探针 200（127.0.0.1:" + $RerankPort + "）") } else { R-Warn ("重排探针失败（127.0.0.1:" + $RerankPort + "）→ 不装重排也能用（fail-open），或运行 start-rerank.ps1") }

# 3. providers test (only when serve not holding the DB)
Write-Host ""
Write-Host "[3] gbrain providers test（需 serve 未运行）" -ForegroundColor Cyan
$serveRunning = $false
try {
  $serveProc = Get-CimInstance Win32_Process -Filter "Name='gbrain.exe' or Name='bun.exe'" -ErrorAction SilentlyContinue |
    Where-Object { ('' + $_.CommandLine) -match 'serve' }
  $serveRunning = [bool]$serveProc
} catch { }
if (Test-Path -LiteralPath $gbrainExe) {
  if ($serveRunning) { R-Info 'gbrain serve 正在运行（opencode 开着）：跳过此项（属正常保护），可在关窗后单独运行 gbrain providers test' }
  else {
    $pt = (& $gbrainExe providers test 2>&1 | Out-String)
    if ($pt -match 'green|✓|pass|OK' ) { R-Pass 'gbrain providers test 通过' }
    elseif ($pt -match 'lock|already open') { R-Info 'DB 被占用（serve 在跑）：跳过' }
    else { R-Warn ('providers test 输出异常: ' + (($pt.Trim() -split "`r?`n" | Select-Object -First 2) -join ' | ')) }
  }
} else { R-Warn 'gbrain 缺失，跳过' }

# 4. marker
Write-Host ""
Write-Host "[4] 初始化 marker" -ForegroundColor Cyan
if (Test-Path -LiteralPath $marker) { R-Pass ('marker 存在: ' + $marker) }
else { R-Fail 'marker 不存在 → 说明首次初始化（维护窗口）尚未完成：完全退出 opencode ≥5 分钟，或双击 brain-maintenance.cmd' }

# 5. default visibility
Write-Host ""
Write-Host "[5] facts.default_visibility" -ForegroundColor Cyan
if (Test-Path -LiteralPath $gbrainExe) {
  $v = (& $gbrainExe config get facts.default_visibility 2>&1 | Out-String).Trim()
  if ($v -match 'world') { R-Pass 'facts.default_visibility = world' }
  elseif ($v -match 'lock|already open') { R-Info 'DB 被占用跳过（marker 存在即已配置 world）' }
  else { R-Warn ('当前值: ' + $v + '（期望 world；在维护窗口运行 gbrain config set facts.default_visibility world）') }
}

# 6. capture log
Write-Host ""
Write-Host "[6] 导出器活动（gbrain-capture.log）" -ForegroundColor Cyan
$capLog = Join-Path $logsDir 'gbrain-capture.log'
if (Test-Path -LiteralPath $capLog) {
  $tail = Get-Content -LiteralPath $capLog -Tail 80 -Encoding UTF8 -ErrorAction SilentlyContinue
  $doneLines = @($tail | Where-Object { $_ -match 'pass done' })
  if ($doneLines.Count -gt 0) {
    $last = $doneLines[-1]
    if ($last -match 'touched=(\d+).*\+(\d+) written') {
      R-Pass ('最近 pass: ' + $last.Substring(0, [Math]::Min(140, $last.Length)))
      if ($last -match 'touched=0') { R-Info '提示：touched=0 且你在活跃对话 → 检查导出器是否在运行（start-gbrain-capture.ps1）' }
    } else { R-Pass ('日志含 pass done ×' + $doneLines.Count) }
  } else { R-Warn '日志中没有 pass done（导出器可能未启动）' }
  # resident process?
  $exporter = Get-CimInstance Win32_Process -Filter "Name='bun.exe'" -ErrorAction SilentlyContinue |
    Where-Object { ('' + $_.CommandLine) -like '*gbrain-capture-export*' }
  if ($exporter) { R-Pass ('导出器驻留进程在运行（PID ' + ($exporter | Select-Object -First 1).ProcessId + '）') }
  else { R-Warn '未发现导出器驻留进程 → 运行 ' + (Join-Path $scriptsDir 'start-gbrain-capture.ps1') }
} else { R-Warn ('日志不存在: ' + $capLog + '（首次运行导出器后产生）') }

# 7. corpus counts
Write-Host ""
Write-Host "[7] 语料消化进度" -ForegroundColor Cyan
if (Test-Path -LiteralPath $corpusDir) {
  $txt = @(Get-ChildItem -LiteralPath $corpusDir -Filter *.txt -ErrorAction SilentlyContinue)
  $side = @(Get-ChildItem -LiteralPath $corpusDir -Filter *.ingested -ErrorAction SilentlyContinue)
  $pending = @($txt | Where-Object { -not (Test-Path -LiteralPath ($_.FullName + '.ingested')) -and -not (Test-Path -LiteralPath ($_.FullName + '.in-progress')) })
  R-Pass ("corpus: .txt=" + $txt.Count + "  .ingested=" + $side.Count + "  pending=" + $pending.Count)
  if ($pending.Count -gt 200) { R-Info '待消化较多属正常（首次回填需数小时~1 天，后台自动推进）' }
} else { R-Warn 'corpus 目录不存在（尚未产生语料）' }

# 8. dream log
Write-Host ""
Write-Host "[8] 维护日志（dream 相位）" -ForegroundColor Cyan
$maintLogs = @(Get-ChildItem -LiteralPath $logsDir -Filter 'brain-maintenance-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($maintLogs.Count -gt 0) {
  $latest = $maintLogs[0]
  $mText = Get-Content -LiteralPath $latest.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
  $dreamLines = @($mText | Where-Object { $_ -match 'dream\[' })
  if ($mText -match 'brain-maintenance 完成') { R-Pass ('最近维护成功: ' + $latest.Name) }
  elseif ($mText -match 'SKIP|被占用') { R-Info ('最近维护被跳过（锁占用：opencode 未退出）: ' + $latest.Name) }
  else { R-Warn ('最近维护未完成: ' + $latest.Name + ' → 查看日志') }
  if ($dreamLines.Count -gt 0) { R-Pass ('dream 相位记录 ×' + $dreamLines.Count) }
  elseif (-not ($mText -match 'SKIP|被占用')) { R-Warn '日志里没有 dream 相位记录' }
} else { R-Warn '暂无维护日志（首次初始化未跑）' }

# 9. optional recall
if ($RecallQuery) {
  Write-Host ""
  Write-Host "[9] 检索召回（query: $RecallQuery）" -ForegroundColor Cyan
  if ($serveRunning) {
    R-Info ('serve 在运行：请在 opencode 里直接问 gbrain "回忆一下 ' + $RecallQuery + '"')
  } elseif (Test-Path -LiteralPath $gbrainExe) {
    $sr = (& $gbrainExe search $RecallQuery --limit 3 2>&1 | Out-String)
    if ($sr -match 'lock|already open') { R-Info 'DB 被占用跳过' }
    elseif ([string]::IsNullOrWhiteSpace(($sr -replace '[\s\-]+', ''))) { R-Warn '检索无结果（语料可能仍在回填）' }
    else { R-Pass ('检索有输出（前 100 字符）: ' + $sr.Trim().Substring(0, [Math]::Min(100, $sr.Trim().Length)).Replace("`r", ' ').Replace("`n", ' ')) }
  }
}

# summary
Write-Host ""
Write-Host "===== 汇总 =====" -ForegroundColor Cyan
Write-Host ("  PASS: " + $script:Pass + "   WARN: " + $script:Warn + "   FAIL: " + $script:Fail)
if ($script:Fail -gt 0) { Write-Host '  有未通过项：按上面提示处理后重跑本脚本。' -ForegroundColor Yellow }
elseif ($script:Warn -gt 0) { Write-Host '  基本就绪（WARN 多为“时间未到”类项：回填/首次初始化）。' -ForegroundColor Green }
else { Write-Host '  全部通过。' -ForegroundColor Green }
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
