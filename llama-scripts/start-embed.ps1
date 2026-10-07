# start-embed.ps1
# Idempotent launcher for the local bge-m3 embedding service (llama-server).
# Used by: HKCU Run "llama-embed" (login autostart), Startup\llama-embed.cmd (backup channel), and manual runs.
# Safe to run any time.

$ErrorActionPreference = 'Continue'

$root  = Join-Path $env:USERPROFILE '.llama'
$exe   = Join-Path $root 'bin\llama-server.exe'
$model = Join-Path $root 'models\bge-m3-Q8_0.gguf'
$log   = Join-Path $root 'server.log'

function Test-EmbedPort {
  # Endpoint probe: a plain TCP connect is fooled by a foreign app's wildcard bind on
  # Dedicated embed port 18080 (moved off 8080 on 2026-09-29: OrderSystem3 holds the 0.0.0.0/[::]:8080 wildcard; plain TCP checks were fooled by it - keep using this endpoint probe).
  try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:18080/v1/embeddings' -Method Post `
      -Body ([Text.Encoding]::UTF8.GetBytes('{"input":"probe","model":"bge-m3"}')) `
      -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
    return ($r.StatusCode -eq 200 -and $r.RawContentLength -gt 50)
  } catch { return $false }
}

# 1) Service already listening?
if (Test-EmbedPort) {
  Write-Output 'llama-server (embed) already running on 127.0.0.1:18080 - nothing to do.'
  exit 0
}

# 2) Process exists but port not ready yet -> wait (avoids double-start race between autostart channels)
# PS 5.1: Get-Process has no CommandLine -> use CIM and match OUR flag (--embeddings).
$proc = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue |
  Where-Object { ('' + $_.CommandLine) -match '--embeddings' }
if ($proc) {
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    if (Test-EmbedPort) { Write-Output 'llama-server (embed) became ready - nothing to do.'; exit 0 }
  }
  Write-Output 'WARN: llama-server embed process exists but port 18080 not ready after 60s.'
  exit 1
}

# 3) Verify artifacts
if (-not (Test-Path $exe))   { Write-Output "ERROR: missing $exe";   exit 1 }
if (-not (Test-Path $model)) { Write-Output "ERROR: missing $model"; exit 1 }

# 4) Launch hidden and detached; llama-server writes its own log file.
#    -b/-ub raised from the 2048/512 defaults so long chunks (>512 tokens) embed without
#    "input is too large to process" failures (GBrain import of long pages).
Start-Process -FilePath $exe `
  -ArgumentList @('--model', "`"$model`"", '--embeddings', '--host', '127.0.0.1', '--port', '18080', '-c', '8192', '-b', '4096', '-ub', '4096', '--log-file', "`"$log`"") `
  -WorkingDirectory (Join-Path $root 'bin') `
  -WindowStyle Hidden

Write-Output 'llama-server (embed) started on 127.0.0.1:18080.'
exit 0
