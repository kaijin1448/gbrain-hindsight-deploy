# start-rerank.ps1
# Idempotent launcher for the local Qwen3-Reranker reranking service (llama-server).
# Used by: Startup\llama-rerank.cmd (login autostart), and manual runs.
# Sibling of start-embed.ps1 (embeddings on 18080); reranker on 18081 (--reranking
# and --embeddings are mutually exclusive at server launch, so two processes).
# Safe to run any time.

$ErrorActionPreference = 'Continue'

$root  = Join-Path $env:USERPROFILE '.llama'
$exe   = Join-Path $root 'bin\llama-server.exe'
$model = Join-Path $root 'models\qwen3-reranker-0.6b-q8_0.gguf'
$log   = Join-Path $root 'server-rerank.log'

function Test-RerankPort {
  # Endpoint probe (TCP-connect alone can be fooled by a foreign wildcard bind on 18081).
  try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:18081/v1/rerank' -Method Post `
      -Body ([Text.Encoding]::UTF8.GetBytes('{"query":"probe","documents":["a"],"model":"qwen3-reranker-06b"}')) `
      -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

# 1) Service already listening?
if (Test-RerankPort) {
  Write-Output 'llama-server (rerank) already running on 127.0.0.1:18081 - nothing to do.'
  exit 0
}

# 2) Process exists but port not ready yet -> wait
# PS 5.1: Get-Process has no CommandLine -> use CIM and match OUR flag (--reranking).
$proc = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue |
  Where-Object { ('' + $_.CommandLine) -match '--reranking' }
if ($proc) {
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    if (Test-RerankPort) { Write-Output 'llama-server (rerank) became ready - nothing to do.'; exit 0 }
  }
  Write-Output 'WARN: llama-server rerank process exists but port 18081 not ready after 60s.'
  exit 1
}

# 3) Verify artifacts
if (-not (Test-Path $exe))   { Write-Output "ERROR: missing $exe";   exit 1 }
if (-not (Test-Path $model)) { Write-Output "ERROR: missing $model"; exit 1 }

# 4) Launch hidden and detached. --alias gives a short model id for gbrain's
#    reranker model string (llama-server-reranker:qwen3-reranker-06b).
Start-Process -FilePath $exe `
  -ArgumentList @('--model', "`"$model`"", '--alias', 'qwen3-reranker-06b', '--reranking', '--host', '127.0.0.1', '--port', '18081', '-c', '8192', '-b', '4096', '-ub', '4096', '--log-file', "`"$log`"") `
  -WorkingDirectory (Join-Path $root 'bin') `
  -WindowStyle Hidden

Write-Output 'llama-server (rerank) started on 127.0.0.1:18081.'
exit 0
