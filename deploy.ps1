<#
.SYNOPSIS
  GBrain「Hindsight 三件套」一键部署（Windows 10/11 · PowerShell 5.1+）

.DESCRIPTION
  把「会话自动记忆 + 语义检索与本地重排 + takes 学习」部署到本机：
    1. 环境体检 + 安装 bun / gbrain（缺什么装什么）
    2. 放置 ~\.llama（本地嵌入/重排服务与模型：优先本地拷贝，其次下载）
    3. 初始化并合并 ~\.gbrain\config.json（网关与 Key 只写入本机配置文件）
    4. 部署导出器与维护脚本到 ~\.config\opencode\memory\scripts
    5. 把 gbrain MCP 块安全合并进 ~\.config\opencode\opencode.jsonc（保留注释、自动备份）
    6. 放置开机自启项，并启动一次性初始化守望（关窗 ≥5 分钟自动完成首次初始化）
    7. 输出验收指引

  幂等：可重复运行。所有既有配置文件在修改前自动备份（.bak-时间戳）。
  无密钥：仓库不含任何密钥；Key 仅在本机询问后写入本机配置，绝不回显。
  无管理员权限要求。

.PARAMETER GatewayUrl
  chat/expansion 网关的 OpenAI 兼容 base_url（含 /v1），例如 http://192.168.1.10:3001/v1

.PARAMETER GatewayKey
  网关 Key（省略则运行时安全询问，不回显）

.PARAMETER GatewayModel
  网关模型名（默认 deepseek-flash，按你的网关实际模型填写）

.PARAMETER LlamaSource
  ~\.llama 的来源：文件夹（含 bin/models）或其 zip 压缩包；省略则询问是否下载

.PARAMETER EmbedPort
  嵌入服务端口（默认 18080）

.PARAMETER RerankPort
  重排服务端口（默认 18081）

.PARAMETER LlamaRoot
  .llama 目录位置（默认 %USERPROFILE%\.llama；仅测试用）

.PARAMETER SkipLlama
  跳过 llama 本地服务（不推荐：语义检索将不可用）

.PARAMETER SkipRerank
  只部署嵌入服务，跳过重排（低内存机器的降级方案）

.PARAMETER SkipAutostart
  不放置开机自启项、不启动守望

.PARAMETER SkipTools
  跳过 bun/gbrain 的安装检查（高级/测试用）

.PARAMETER DryRun
  只打印计划，不做任何写操作

.EXAMPLE
  # 仓库方式（推荐）
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1

.EXAMPLE
  # 远程一键（推荐走 install.ps1 —— 纯 ASCII 无 BOM，iex 管道安全）
  irm https://raw.githubusercontent.com/kaijin1448/gbrain-hindsight-deploy/main/install.ps1 | iex

.EXAMPLE
  # 由 install.ps1 自举进入时会自动调用本脚本；也可单独下载后 -File 运行
  powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1

.EXAMPLE
  # 全自动（带网关参数）
  .\deploy.ps1 -GatewayUrl http://192.168.1.10:3001/v1 -GatewayModel deepseek-flash -LlamaSource D:\llama-pack.zip
#>

[CmdletBinding()]
param(
  [string]$GatewayUrl = '',
  [string]$GatewayKey = '',
  [string]$GatewayModel = 'deepseek-flash',
  [string]$LlamaSource = '',
  [int]$EmbedPort = 18080,
  [int]$RerankPort = 18081,
  [string]$LlamaRoot = '',
  [switch]$SkipLlama,
  [switch]$SkipRerank,
  [switch]$SkipAutostart,
  [switch]$SkipTools,
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:RepoUrlZip = 'https://github.com/kaijin1448/gbrain-hindsight-deploy/archive/refs/heads/main.zip'
$script:Failed = $false

# ------------------------------------------------------------------ helpers
function Write-Banner([string]$t) { Write-Host ("`n== " + $t + " ==") -ForegroundColor Cyan }
function Write-Step([int]$n, [string]$t) { Write-Host ("`n[{0}/7] {1}" -f $n, $t) -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host ("  [OK]   " + $m) -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host ("  [..]   " + $m) -ForegroundColor Gray }
function Write-Warn([string]$m) { Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow }
function Write-Err([string]$m)  { Write-Host ("  [ERR]  " + $m) -ForegroundColor Red; $script:Failed = $true }
function Write-Planned([string]$m) { Write-Host ("  [dry-run] " + $m) -ForegroundColor DarkGray }

function Ask-YesNo([string]$q, [bool]$default = $true) {
  $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
  $a = Read-Host ("  " + $q + " " + $hint)
  if ([string]::IsNullOrWhiteSpace($a)) { return $default }
  return ($a.Trim().ToLower().StartsWith('y'))
}

function Get-FreeGB([string]$drive) {
  try { $d = Get-PSDrive -Name $drive -ErrorAction Stop; return [math]::Round(($d.Free / 1GB), 1) } catch { return -1 }
}

function Test-PortListening([int]$port) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(800, $false)
    $live = ($ok -and $c.Connected); $c.Close(); return $live
  } catch { return $false }
}

function Test-EmbedProbe([int]$port) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/embeddings" -f $port) -Method Post `
      -Body ([Text.Encoding]::UTF8.GetBytes('{"input":"probe","model":"bge-m3"}')) `
      -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Test-RerankProbe([int]$port) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/rerank" -f $port) -Method Post `
      -Body ([Text.Encoding]::UTF8.GetBytes('{"query":"q","documents":["a"],"model":"qwen3-reranker-06b"}')) `
      -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Wait-Probe([string]$kind, [int]$port, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if ($kind -eq 'embed') { if (Test-EmbedProbe $port) { return $true } }
    else { if (Test-RerankProbe $port) { return $true } }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Get-FileSha256([string]$path) {
  try { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } catch { return '' }
}

function Install-FileSafe([string]$src, [string]$dst) {
  # returns: 'planned' | 'same' | 'installed' | 'failed'
  $dir = Split-Path -Parent $dst
  if (-not (Test-Path -LiteralPath $dir)) {
    if ($DryRun) { Write-Planned ("创建目录 " + $dir) } else { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  }
  if ((Test-Path -LiteralPath $dst) -and ((Get-FileSha256 $src) -eq (Get-FileSha256 $dst))) { return 'same' }
  if ($DryRun) { Write-Planned ("部署文件 " + $dst) ; return 'planned' }
  if (Test-Path -LiteralPath $dst) {
    $bak = "{0}.bak-{1}" -f $dst, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $dst -Destination $bak -Force
  }
  try { Copy-Item -LiteralPath $src -Destination $dst -Force; return 'installed' }
  catch { Write-Err ("复制失败: " + $src + " -> " + $dst); return 'failed' }
}

function Set-PortsInPs1File([string]$path, [int]$embedPort, [int]$rerankPort) {
  # rewrite 18080/18081 tokens when custom ports were chosen; keeps UTF-8 BOM.
  # two-pass with placeholders so a swapped pair (18080<->18081) can't collide.
  $enc = New-Object System.Text.UTF8Encoding($true)
  $t = [IO.File]::ReadAllText($path, $enc)
  $t2 = $t.Replace('18080', '__EMBED_PORT__').Replace('18081', '__RERANK_PORT__')
  $t2 = $t2.Replace('__EMBED_PORT__', [string]$embedPort).Replace('__RERANK_PORT__', [string]$rerankPort)
  if ($t2 -ne $t) { [IO.File]::WriteAllText($path, $t2, $enc) }
}

function Download-File([string]$url, [string]$dest) {
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 7200
}

# ------------------------------------------------------------------ bootstrap
# When run via `irm ... | iex` ($PSScriptRoot empty) or without the repo files:
# download the repo zip, extract to TEMP, re-run the real deploy.ps1 from there.
$script:RepoReady = $false
if ($PSScriptRoot) {
  $probe = Join-Path $PSScriptRoot 'scripts\gbrain-capture-export.ts'
  if (Test-Path -LiteralPath $probe) { $script:RepoReady = $true }
}

if (-not $script:RepoReady) {
  if ($DryRun) { Write-Err '未在仓库目录内运行（dry-run 模式无法自举）。请先 git clone 或用仓库内 deploy.ps1。'; return }
  Write-Banner '远程自举模式：下载仓库并重新执行'
  try {
    $work = Join-Path $env:TEMP ("gbrain-hindsight-deploy-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'repo.zip'
    Write-Info ("下载 " + $script:RepoUrlZip)
    Download-File $script:RepoUrlZip $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
    $root = Get-ChildItem -LiteralPath $work -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'deploy.ps1') } | Select-Object -First 1
    if (-not $root) { throw '解压后未找到 deploy.ps1' }
    $child = Join-Path $root.FullName 'deploy.ps1'
    Write-Ok ("仓库已就绪：" + $root.FullName)
    Write-Info '转入完整部署流程…'
    $extra = @()
    if ($LlamaSource) { $extra += @('-LlamaSource', $LlamaSource) }
    if ($EmbedPort -ne 18080) { $extra += @('-EmbedPort', [string]$EmbedPort) }
    if ($RerankPort -ne 18081) { $extra += @('-RerankPort', [string]$RerankPort) }
    if ($SkipLlama)     { $extra += '-SkipLlama' }
    if ($SkipRerank)    { $extra += '-SkipRerank' }
    if ($SkipAutostart) { $extra += '-SkipAutostart' }
    $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File', $child) + $extra)
    $global:LASTEXITCODE = $p.ExitCode
    return
  } catch {
    Write-Err ("自举失败：" + $_.Exception.Message)
    Write-Info '请改用：git clone https://github.com/kaijin1448/gbrain-hindsight-deploy.git，然后运行 .\deploy.ps1'
    return
  }
}

$Root = $PSScriptRoot
if (-not $LlamaRoot) { $LlamaRoot = Join-Path $env:USERPROFILE '.llama' }
$scriptsDst = Join-Path $env:USERPROFILE '.config\opencode\memory\scripts'
$ocJsonc    = Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'
$gbrainCfg  = Join-Path $env:USERPROFILE '.gbrain\config.json'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'

Write-Banner 'GBrain Hindsight 三件套 · 一键部署'
Write-Info ("仓库目录 : " + $Root)
Write-Info ("用户目录 : " + $env:USERPROFILE)
Write-Info ("端口规划 : 嵌入 " + $EmbedPort + " / 重排 " + $RerankPort)
if ($DryRun) { Write-Host "  (dry-run：只展示计划，不写入任何内容)" -ForegroundColor DarkGray }

# ------------------------------------------------------------------ [1/7] 环境体检 + bun/gbrain
Write-Step 1 '环境体检与工具准备（bun / gbrain）'

$bunExe    = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
$gbrainExe = Join-Path $env:USERPROFILE '.bun\bin\gbrain.exe'

# OS / PowerShell
Write-Info ("OS: " + (Get-CimInstance Win32_OperatingSystem).Caption + " | PowerShell " + $PSVersionTable.PSVersion.ToString())
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Info ("物理内存: " + $ramGB + " GB（推荐 ≥16GB；不足时可用 -SkipRerank 降级）")

# disk
$sysDrive = ($env:USERPROFILE -split ':')[0]
$freeGB = Get-FreeGB $sysDrive
if ($freeGB -ge 0) {
  if ($freeGB -lt 5) { Write-Warn ("系统盘剩余空间仅 " + $freeGB + " GB，建议先清理（模型约 1.3GB + 大脑数据库）") }
  else { Write-Ok ("系统盘剩余空间 " + $freeGB + " GB") }
}

if (-not $SkipTools) {
  # bun
  $bunOk = Test-Path -LiteralPath $bunExe
  if ($bunOk) { Write-Ok ("bun 已安装：" + (& $bunExe --version 2>$null)) }
  else {
    $haveBun = Get-Command bun -ErrorAction SilentlyContinue
    if ($haveBun) { $bunExe = $haveBun.Source; $bunOk = $true; Write-Ok ("bun 已在 PATH：" + (& $bunExe --version 2>$null)) }
  }
  if (-not $bunOk) {
    if ($DryRun) { Write-Planned '安装 bun（官方脚本 irm bun.sh/install.ps1 | iex）' }
    else {
      Write-Warn '未找到 bun。'
      if (Ask-YesNo '现在通过 bun 官方安装脚本安装？(irm bun.sh/install.ps1 | iex)' $true) {
        try {
          Invoke-Expression (Invoke-RestMethod 'https://bun.sh/install.ps1')
          $bunExe = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
          if (Test-Path -LiteralPath $bunExe) { Write-Ok ("bun 安装完成：" + (& $bunExe --version 2>$null)) }
          else { Write-Err 'bun 安装后仍未找到 ~\.bun\bin\bun.exe，请手动安装后重跑本脚本' }
        } catch { Write-Err ("bun 安装失败：" + $_.Exception.Message + "（网络受限时请手动安装 bun 后重跑）") }
      } else { Write-Err '缺少 bun：无法继续（可手动安装后重跑本脚本）' }
    }
  }

  # gbrain
  if (-not (Test-Path -LiteralPath $gbrainExe)) {
    if ($DryRun) { Write-Planned 'bun install -g gbrain' }
    elseif ($bunOk -and (Test-Path -LiteralPath $bunExe)) {
      Write-Info '安装 gbrain（bun install -g gbrain）…'
      try {
        & $bunExe install -g gbrain 2>&1 | Out-String | Write-Verbose
        if (Test-Path -LiteralPath $gbrainExe) { Write-Ok ("gbrain 安装完成：" + (& $gbrainExe --version 2>$null)) }
        else { Write-Err 'gbrain 安装后仍未找到 ~\.bun\bin\gbrain.exe（网络受限时请手动安装）' }
      } catch { Write-Err ("gbrain 安装失败：" + $_.Exception.Message) }
    }
  } else {
    Write-Ok ("gbrain 已安装：" + (& $gbrainExe --version 2>$null))
  }
} else { Write-Info '已跳过 bun/gbrain 安装检查（-SkipTools）' }

# port check
foreach ($p in @(@{ n = '嵌入'; port = $EmbedPort; probe = 'embed' }, @{ n = '重排'; port = $RerankPort; probe = 'rerank' })) {
  if (Test-PortListening $p.port) {
    $alive = $false
    if ($p.probe -eq 'embed') { $alive = Test-EmbedProbe $p.port } else { $alive = Test-RerankProbe $p.port }
    if ($alive) { Write-Ok ($p.n + " 服务已在 127.0.0.1:" + $p.port + " 正常运行") }
    else { Write-Warn ($p.n + " 端口 " + $p.port + " 被其它程序占用（探针非 200）。请更换端口：-EmbedPort/-RerankPort，或先释放该端口") }
  } else { Write-Ok ($p.n + " 端口 " + $p.port + " 空闲") }
}

# ------------------------------------------------------------------ [2/7] .llama 本地服务与模型
Write-Step 2 '部署本地 llama 服务（嵌入 + 重排）与模型'

if ($SkipLlama) {
  Write-Warn '已按参数跳过 llama 本地服务（语义检索将不可用，仅关键词检索）'
} else {
  $llamaExe   = Join-Path $LlamaRoot 'bin\llama-server.exe'
  $embModel   = Join-Path $LlamaRoot 'models\bge-m3-Q8_0.gguf'
  $rerModel   = Join-Path $LlamaRoot 'models\qwen3-reranker-0.6b-q8_0.gguf'

  $haveExe    = Test-Path -LiteralPath $llamaExe
  $haveEmbed  = Test-Path -LiteralPath $embModel
  $haveRerank = Test-Path -LiteralPath $rerModel
  if ($haveExe -and $haveEmbed -and $haveRerank) {
    Write-Ok ('本地资源已齐全：' + $LlamaRoot)
  } else {
    # try to acquire from source
    $src = $LlamaSource
    if (-not $src) {
      if ($DryRun) { Write-Planned ('询问/下载 .llama 资源 → ' + $LlamaRoot) }
      else {
        Write-Warn '本机缺少 ~\.llama 资源（bin 与两个模型，约 1.3GB）。'
        Write-Host '   来源选项：' -ForegroundColor Gray
        Write-Host '     1) 已有拷贝（文件夹或 zip）——最快，推荐' -ForegroundColor Gray
        Write-Host '     2) 现在下载（llama.cpp b11136 + bge-m3 + qwen3-reranker，约 1.3GB）' -ForegroundColor Gray
        Write-Host '     3) 跳过（稍后手动放置后重跑）' -ForegroundColor Gray
        $choice = Read-Host '   输入 1 / 2 / 3'
        if ($choice -eq '1') { $src = Read-Host '   请输入文件夹或 zip 的完整路径' }
        elseif ($choice -eq '2') { $src = 'DOWNLOAD' }
        else { Write-Warn '已跳过 .llama 部署；完成后请把资源放到 ' + $LlamaRoot + ' 再重跑本脚本或手动执行两个 start 脚本' }
      }
    }
    if ($src -eq 'DOWNLOAD') {
      if ($DryRun) { Write-Planned '下载 llama.cpp + 两个模型' }
      else {
        $tmpDl = Join-Path $env:TEMP ("llama-dl-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $tmpDl -Force | Out-Null
        $needa = -not (Test-Path -LiteralPath $llamaExe); $needm = -not $haveEmbed; $needr = -not $haveRerank -and -not $SkipRerank
        if ($needa) {
          $zip = Join-Path $tmpDl 'llama-win.zip'
          Write-Info '下载 llama.cpp b11136（约 18MB）…'
          Download-File 'https://github.com/ggml-org/llama.cpp/releases/download/b11136/llama-b11136-bin-win-cpu-x64.zip' $zip
          $ex = Join-Path $tmpDl 'llama'
          Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
          $binDst = Join-Path $LlamaRoot 'bin'
          New-Item -ItemType Directory -Path $binDst -Force | Out-Null
          Get-ChildItem -LiteralPath $ex -Recurse -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $binDst -Force }
          Write-Ok 'llama.cpp 已放置到 ~\.llama\bin'
        }
        if ($needm) {
          New-Item -ItemType Directory -Path (Join-Path $LlamaRoot 'models') -Force | Out-Null
          Write-Info '下载 bge-m3-Q8_0.gguf（约 605MB）…'
          Download-File 'https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf' $embModel
          Write-Ok 'bge-m3 已就位'
        }
        if ($needr) {
          Write-Info '下载 qwen3-reranker-0.6b-q8_0.gguf（约 610MB）…'
          Download-File 'https://huggingface.co/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/main/qwen3-reranker-0.6b-q8_0.gguf' $rerModel
          Write-Ok 'qwen3-reranker 已就位'
        }
      }
    } elseif ($src -and $src -ne 'DOWNLOAD') {
      if (-not (Test-Path -LiteralPath $src)) { Write-Err ('来源不存在：' + $src) }
      elseif ($DryRun) { Write-Planned ('从 ' + $src + ' 复制 .llama 资源 → ' + $LlamaRoot) }
      else {
        $item = Get-Item -LiteralPath $src
        if ($item.PSIsContainer) {
          Copy-Item -Path (Join-Path $src '*') -Destination $LlamaRoot -Recurse -Force
        } else {
          $ex = Join-Path $env:TEMP ("llama-src-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
          Expand-Archive -LiteralPath $src -DestinationPath $ex -Force
          # zip may contain a single top folder with bin/ and models/
          $inner = Get-ChildItem -LiteralPath $ex
          $srcRoot = $ex
          if ($inner.Count -eq 1 -and $inner[0].PSIsContainer -and (Test-Path (Join-Path $inner[0].FullName 'bin'))) { $srcRoot = $inner[0].FullName }
          New-Item -ItemType Directory -Path $LlamaRoot -Force | Out-Null
          Copy-Item -Path (Join-Path $srcRoot '*') -Destination $LlamaRoot -Recurse -Force
        }
        Write-Ok ('资源已复制到 ' + $LlamaRoot)
      }
    }
  }

  # place launcher scripts (+ ports rewrite if custom)
  $embedPs1  = Join-Path $LlamaRoot 'start-embed.ps1'
  $rerankPs1 = Join-Path $LlamaRoot 'start-rerank.ps1'
  $pairs = @(@{ s = "$Root\llama-scripts\start-embed.ps1"; d = $embedPs1 })
  if (-not $SkipRerank) { $pairs += @{ s = "$Root\llama-scripts\start-rerank.ps1"; d = $rerankPs1 } }
  foreach ($pair in $pairs) {
    $res = Install-FileSafe $pair.s $pair.d
    if ($res -eq 'installed') { Write-Ok ('已部署 ' + $pair.d) }
    elseif ($res -eq 'failed') { }
    if (($EmbedPort -ne 18080 -or $RerankPort -ne 18081) -and -not $DryRun -and (Test-Path -LiteralPath $pair.d)) {
      Set-PortsInPs1File $pair.d $EmbedPort $RerankPort
    }
  }

  if ($SkipRerank) {
    Write-Warn '已跳过重排服务（-SkipRerank）：检索将 fail-open（无重排）'
  }

  # start + verify (only when resources are actually present)
  if ($DryRun) { Write-Planned '启动两个 llama 服务并做端点探针' }
  else {
    $canEmbed  = (Test-Path -LiteralPath (Join-Path $LlamaRoot 'bin\llama-server.exe')) -and (Test-Path -LiteralPath (Join-Path $LlamaRoot 'models\bge-m3-Q8_0.gguf'))
    $canRerank = (-not $SkipRerank) -and (Test-Path -LiteralPath (Join-Path $LlamaRoot 'bin\llama-server.exe')) -and (Test-Path -LiteralPath (Join-Path $LlamaRoot 'models\qwen3-reranker-0.6b-q8_0.gguf'))
    if ($canEmbed -and (Test-Path -LiteralPath $embedPs1)) {
      $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $embedPs1 2>&1 | Out-String
      Write-Info ('嵌入服务: ' + ($out.Trim() -split "`r?`n" | Select-Object -First 1))
      if (Wait-Probe 'embed' $EmbedPort 90) { Write-Ok ('嵌入探针 200（127.0.0.1:' + $EmbedPort + '）') }
      else { Write-Err ('嵌入探针未通：请检查 ' + $LlamaRoot + '\server.log') }
    } else { Write-Warn '嵌入资源缺失，跳过启动（放置资源后重跑本脚本）' }
    if ($canRerank -and (Test-Path -LiteralPath $rerankPs1)) {
      $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rerankPs1 2>&1 | Out-String
      Write-Info ('重排服务: ' + ($out.Trim() -split "`r?`n" | Select-Object -First 1))
      if (Wait-Probe 'rerank' $RerankPort 120) { Write-Ok ('重排探针 200（127.0.0.1:' + $RerankPort + '）') }
      else { Write-Err ('重排探针未通：请检查 ' + $LlamaRoot + '\server-rerank.log') }
    } elseif (-not $SkipRerank) { Write-Warn '重排资源缺失，跳过启动（放置资源后重跑本脚本）' }
  }
}

# ------------------------------------------------------------------ [3/7] gbrain 初始化 + config.json
Write-Step 3 '初始化大脑并合并配置（网关 Key 只写入本机）'

# Pre-read the existing config so an idempotent re-run never re-prompts.
$existingCfg = $null
if (Test-Path -LiteralPath $gbrainCfg) {
  try { $existingCfg = [IO.File]::ReadAllText($gbrainCfg, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $existingCfg = $null }
}
if ($existingCfg) {
  if (-not $GatewayUrl) {
    try { $v = [string]$existingCfg.provider_base_urls.deepseek; if ($v) { $GatewayUrl = $v } } catch { }
  }
  if (-not $GatewayKey) {
    try { $v = [string]$existingCfg.deepseek_api_key; if ($v) { $GatewayKey = $v } } catch { }
  }
  if ($existingCfg.chat_model -and $GatewayModel -eq 'deepseek-flash') {
    try { $cm = [string]$existingCfg.chat_model; if ($cm -match ':') { $GatewayModel = ($cm -split ':')[-1] } } catch { }
  }
}

# gateway inputs: ask only for what is still missing (never echo the key)
if (-not $DryRun) {
  if (-not $GatewayUrl) {
    $GatewayUrl = Read-Host '  网关 base_url（OpenAI 兼容、含 /v1，例 http://192.168.1.10:3001/v1）'
  } else { Write-Info ('网关: ' + $GatewayUrl) }
  if (-not $GatewayKey) {
    Write-Host '  网关 Key（输入不回显；仅写入本机配置文件）' -ForegroundColor Gray
    $sec = Read-Host '  Key' -AsSecureString
    if ($sec -and $sec.Length -gt 0) {
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try { $GatewayKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
  }
} else {
  if (-not $GatewayUrl) { Write-Planned '询问网关 base_url 与 Key（仅本机写入）' }
}

if ((Test-Path -LiteralPath $gbrainExe) -and -not $SkipTools) {
  $brainDir = Join-Path $env:USERPROFILE '.gbrain'
  $dbDir = Join-Path $brainDir 'brain.pglite'
  if (-not (Test-Path -LiteralPath $dbDir)) {
    if ($DryRun) { Write-Planned 'gbrain init（PGLite 首次初始化）' }
    else {
      Write-Info '首次初始化大脑（gbrain init）…'
      try { & $gbrainExe init 2>&1 | Out-String | Write-Verbose; Write-Ok 'gbrain init 完成' }
      catch { Write-Err ('gbrain init 失败：' + $_.Exception.Message) }
    }
  } elseif (Test-Path -LiteralPath (Join-Path $brainDir 'config.json')) {
    Write-Ok '检测到已有大脑数据（沿用现有 ~\.gbrain）'
  }
} else { Write-Info '未找到 gbrain（或 -SkipTools）：跳过 DB 初始化，仅文件面配置' }

# config.json merge (file-level; no DB lock needed)
if (-not $DryRun) {
  $profEsc = $env:USERPROFILE.Replace('\', '\\')
  $tpl = [ordered]@{
    engine = 'pglite'
    database_path = ($env:USERPROFILE + '\.gbrain\brain.pglite')
    embedding_model = 'llama-server:bge-m3'
    embedding_dimensions = 1024
    provider_base_urls = [ordered]@{
      'llama-server' = ('http://127.0.0.1:{0}/v1' -f $EmbedPort)
      'llama-server-reranker' = ('http://127.0.0.1:{0}/v1' -f $RerankPort)
    }
    chat_model = ('deepseek:{0}' -f $GatewayModel)
    expansion_model = ('deepseek:{0}' -f $GatewayModel)
    memory = [ordered]@{ auto_writeback = 'salient'; visibility_posture = 'world' }
  }
  if ($GatewayUrl) { $tpl.provider_base_urls['deepseek'] = $GatewayUrl }
  if ($GatewayKey) { $tpl['deepseek_api_key'] = $GatewayKey }

  $brainDir = Join-Path $env:USERPROFILE '.gbrain'
  if (-not (Test-Path -LiteralPath $brainDir)) { New-Item -ItemType Directory -Path $brainDir -Force | Out-Null }

  $cfgObj = $null
  if (Test-Path -LiteralPath $gbrainCfg) {
    try { $cfgObj = [IO.File]::ReadAllText($gbrainCfg, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Write-Warn 'config.json 解析失败（可能被 DLP 加密损坏）：将重建合并'; $cfgObj = $null }
  }
  if ($null -eq $cfgObj) { $cfgObj = New-Object PSObject }

  $changed = $false
  $props = @{}; foreach ($p in $cfgObj.PSObject.Properties) { $props[$p.Name] = $p }
  foreach ($k in $tpl.Keys) {
    $v = $tpl[$k]
    if ($props.ContainsKey($k)) {
      if ($v -is [System.Collections.IDictionary]) {
        $cur = $cfgObj.$k
        $subNames = @(); foreach ($p2 in $cur.PSObject.Properties) { $subNames += $p2.Name }
        foreach ($sk in $v.Keys) {
          if ($subNames -notcontains $sk) {
            $cur | Add-Member -NotePropertyName $sk -NotePropertyValue $v[$sk]
            $changed = $true; Write-Ok ('config 补充: ' + $k + '.' + $sk)
          } else { Write-Info ('config 保留: ' + $k + '.' + $sk + '（已存在）') }
        }
      } else { Write-Info ('config 保留: ' + $k + '（已存在）') }
    } else {
      if ($v -is [System.Collections.IDictionary]) {
        $sub = New-Object PSObject
        foreach ($sk in $v.Keys) { $sub | Add-Member -NotePropertyName $sk -NotePropertyValue $v[$sk] }
        $cfgObj | Add-Member -NotePropertyName $k -NotePropertyValue $sub
      } else {
        $cfgObj | Add-Member -NotePropertyName $k -NotePropertyValue $v
      }
      $changed = $true; Write-Ok ('config 新增: ' + $k)
    }
  }
  if ($changed) {
    if (Test-Path -LiteralPath $gbrainCfg) {
      Copy-Item -LiteralPath $gbrainCfg -Destination ("{0}.bak-{1}" -f $gbrainCfg, (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    }
    $json = $cfgObj | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($gbrainCfg, $json, (New-Object Text.UTF8Encoding($false)))
    Write-Ok ('已写入 ' + $gbrainCfg + '（保持无 BOM）')
  } else { Write-Ok 'config.json 无需变更' }
} else { Write-Planned '合并 ~\.gbrain\config.json（引擎/嵌入/provider/模型/memory）' }

# ------------------------------------------------------------------ [4/7] memory scripts
Write-Step 4 '部署脚本到 ~\.config\opencode\memory\scripts'

$scriptFiles = @(
  'gbrain-capture-export.ts', 'start-gbrain-capture.ps1', 'brain-maintenance.ps1',
  'brain-maintenance.cmd', 'brain-onclose.ps1', 'fix-gbrain-config.py'
)
foreach ($f in $scriptFiles) {
  $res = Install-FileSafe (Join-Path $Root "scripts\$f") (Join-Path $scriptsDst $f)
  if ($res -eq 'same') { Write-Info ('已是同版本: ' + $f) }
  elseif ($res -eq 'installed') { Write-Ok ('已部署: ' + $f) }
}
# ports rewrite for maintenance script if custom
if (($EmbedPort -ne 18080 -or $RerankPort -ne 18081) -and -not $DryRun -and (Test-Path -LiteralPath (Join-Path $scriptsDst 'brain-maintenance.ps1'))) {
  Set-PortsInPs1File (Join-Path $scriptsDst 'brain-maintenance.ps1') $EmbedPort $RerankPort
  Write-Ok '维护脚本端口已同步'
}

# ------------------------------------------------------------------ [5/7] opencode.jsonc merge
Write-Step 5 '接线 opencode（安全合并 mcp.gbrain 块，保留注释、自动备份）'

if (-not (Test-Path -LiteralPath (Join-Path $scriptsDst 'gbrain-capture-export.ts'))) { Write-Warn '缺少部署脚本（上一步未完成）' }

$ocDir = Split-Path -Parent $ocJsonc
if (-not (Test-Path -LiteralPath $ocDir)) {
  if ($DryRun) { Write-Planned ('创建目录 ' + $ocDir) } else { New-Item -ItemType Directory -Path $ocDir -Force | Out-Null }
}
if (-not (Test-Path -LiteralPath $ocJsonc)) {
  if ($DryRun) { Write-Planned ('新建空配置 ' + $ocJsonc) }
  else { [IO.File]::WriteAllText($ocJsonc, "{`n}`n", (New-Object Text.UTF8Encoding($false))); Write-Ok '已新建 opencode.jsonc（空骨架）' }
}

# build runtime fragment (username + ports substituted)
$fragSrc = Join-Path $Root 'templates\opencode-mcp.fragment.jsonc'
$fragTmp = Join-Path $env:TEMP ("gbrain-mcp-fragment-{0}.jsonc" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$fragText = [IO.File]::ReadAllText($fragSrc, [Text.Encoding]::UTF8)
$fragText = $fragText.Replace('<你的用户名>', $env:USERNAME)
$fragText = $fragText.Replace('18080', [string]$EmbedPort).Replace('18081', [string]$RerankPort)
if ($DryRun) { Write-Planned '生成运行时 mcp 片段（用户名/端口替换）并调用 merge-mcp.mjs' }
else {
  [IO.File]::WriteAllText($fragTmp, $fragText, (New-Object Text.UTF8Encoding($false)))
  $mergeTool = Join-Path $Root 'tools\merge-mcp.mjs'
  $runner = $null
  if (Test-Path -LiteralPath $bunExe) { $runner = $bunExe }
  else { $cmd = Get-Command node -ErrorAction SilentlyContinue; if ($cmd) { $runner = $cmd.Source } }
  if (-not $runner) { Write-Err '需要 bun 或 node 运行合并工具（都未找到）' }
  else {
    $mout = & $runner $mergeTool --file $ocJsonc --fragment $fragTmp 2>&1 | Out-String
    Write-Info ('merge-mcp: ' + $mout.Trim())
    $mergeOk = $LASTEXITCODE -eq 0
    if ($mergeOk) { Write-Ok 'mcp.gbrain 块已合并进 opencode.jsonc' } else { Write-Err '合并失败：请检查 opencode.jsonc 语法' }
    if ($mout -match 'KEPT') {
      Write-Warn '检测到已有不同的 gbrain 块（已保留原样）。如需用模板标准化它（先备份再替换）：'
      Write-Host ('    ' + $runner + ' "' + $mergeTool + '" --file "' + $ocJsonc + '" --fragment "' + $fragTmp + '" --replace') -ForegroundColor Gray
    } else {
      Remove-Item -LiteralPath $fragTmp -Force -ErrorAction SilentlyContinue
    }
  }
}

# ------------------------------------------------------------------ [6/7] autostart + watcher
Write-Step 6 '开机自启与首次初始化守望'

if ($SkipAutostart) { Write-Info '已跳过（-SkipAutostart）：每次开机需手动运行 2-3 个启动脚本' }
else {
  if (-not (Test-Path -LiteralPath $startupDir)) { if (-not $DryRun) { New-Item -ItemType Directory -Path $startupDir -Force | Out-Null } }
  $startupFiles = @('llama-embed.vbs', 'llama-rerank.vbs', 'gbrain-capture.vbs')
  if ($SkipRerank) { $startupFiles = @('llama-embed.vbs', 'gbrain-capture.vbs') }
  foreach ($f in $startupFiles) {
    $src = Join-Path $Root ("startup-templates\" + $f)
    $res = Install-FileSafe $src (Join-Path $startupDir $f)
    if ($res -eq 'installed') { Write-Ok ('自启项: ' + $f) } elseif ($res -eq 'same') { Write-Info ('自启项已存在: ' + $f) }
  }
  # 清理旧版部署遗留的 .cmd 自启项（本部署所有，避免与新 .vbs 形成双启动通道）
  foreach ($legacy in @('llama-embed.cmd', 'llama-rerank.cmd', 'gbrain-capture.cmd', 'brain-onclose.cmd')) {
    $lp = Join-Path $startupDir $legacy
    if (Test-Path -LiteralPath $lp) {
      if ($DryRun) { Write-Planned ('移除旧自启项 ' + $legacy) }
      else { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue; Write-Ok ('已移除旧自启项: ' + $legacy) }
    }
  }
  # optional one-shot watcher for first init (self-retires after success)
  $marker = Join-Path $env:USERPROFILE '.gbrain\transcripts\sweep-enabled.md'
  if (-not (Test-Path -LiteralPath $marker)) {
    $res = Install-FileSafe (Join-Path $Root 'startup-templates\brain-onclose.vbs') (Join-Path $startupDir 'brain-onclose.vbs')
    if (-not $DryRun) {
      $watcher = Join-Path $scriptsDst 'brain-onclose.ps1'
      if (Test-Path -LiteralPath $watcher) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $watcher) -WindowStyle Hidden
        Write-Ok '初始化守望已启动（完全退出 opencode ≥5 分钟后自动完成首次初始化）'
      }
    } else { Write-Planned '启动 brain-onclose 守望' }
  } else { Write-Info '初始化已完成过（marker 存在），不放置守望' }
}

# ------------------------------------------------------------------ [7/7] receipt
Write-Step 7 '回执与下一步'
Write-Host ''
if ($script:Failed) {
  Write-Host '部署完成（有告警，请核对上面 [WARN]/[ERR] 行）' -ForegroundColor Yellow
} else {
  Write-Host '部署完成。' -ForegroundColor Green
}

Write-Host '  下一步（首次初始化，二选一）：' -ForegroundColor Cyan
Write-Host ('    A. 完全退出 opencode 并保持 ≥5 分钟 —— 守望自动完成初始化（推荐）')
Write-Host ('    B. 手动双击: ' + (Join-Path $scriptsDst 'brain-maintenance.cmd'))
Write-Host ('  完成后：重开 opencode → 运行 ' + (Join-Path $Root 'verify.ps1') + ' 验收')
Write-Host ''
Write-Host '  说明：' -ForegroundColor Gray
Write-Host '    - 网关 Key 只写入了本机配置文件，未出现在任何输出中'
Write-Host '    - 首次回填（数千段语料）需数小时~1 天，全自动运行，不用值守'
Write-Host '    - 若改了 opencode.jsonc，重启 opencode 后 gbrain 工具才生效'
Write-Host ''

if ($script:Failed) { exit 1 } else { exit 0 }
