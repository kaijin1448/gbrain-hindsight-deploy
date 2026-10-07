# install.ps1 -- ASCII-only bootstrap for the one-liner:
#   irm https://raw.githubusercontent.com/kaijin1448/gbrain-hindsight-deploy/main/install.ps1 | iex
#
# WHY THIS FILE EXISTS: deploy.ps1 contains Chinese text and therefore must be
# saved as UTF-8 WITH a BOM for PowerShell 5.1. But when a BOM-authored script is
# piped through `Invoke-Expression`, the leading U+FEFF character is NOT stripped
# and the parser rejects the first token. So the remote one-liner must point at
# this file, which is pure ASCII with NO BOM, and this file then downloads the
# repository and runs the real deploy.ps1 with -File (which handles the BOM fine).
#
# This file performs NO configuration changes itself. It only fetches the
# repository, extracts it to a temp folder, and hands control to deploy.ps1.

[CmdletBinding()]
param(
  [string]$Ref = 'main',
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$DeployArgs
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$zipUrl = "https://github.com/kaijin1448/gbrain-hindsight-deploy/archive/refs/heads/$Ref.zip"
$work = Join-Path $env:TEMP ("gbrain-hindsight-deploy-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))

Write-Host "== GBrain Hindsight deploy :: remote bootstrap ==" -ForegroundColor Cyan
Write-Host ("  ref : " + $Ref)
Write-Host ("  temp: " + $work)

New-Item -ItemType Directory -Path $work -Force | Out-Null
$zip = Join-Path $work 'repo.zip'

Write-Host "  downloading repository archive..."
Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 300
Write-Host ("  downloaded: " + (Get-Item $zip).Length + " bytes")

Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

$root = Get-ChildItem -LiteralPath $work -Directory |
  Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'deploy.ps1') } |
  Select-Object -First 1
if (-not $root) { throw "Could not find deploy.ps1 after extraction under $work" }

$child = Join-Path $root.FullName 'deploy.ps1'
Write-Host ("  repository ready: " + $root.FullName)
Write-Host "  launching deploy.ps1 ..." -ForegroundColor Cyan
Write-Host ""

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $child) + $DeployArgs
$p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -ArgumentList $argList

# Do NOT call `exit` here: when run via `irm ... | iex` this script executes in
# the caller's session, and `exit` would close the user's console window.
if ($p.ExitCode -ne 0) {
  Write-Host ("deploy.ps1 finished with exit code " + $p.ExitCode + " - review the [WARN]/[ERR] lines above.") -ForegroundColor Yellow
} else {
  Write-Host "deploy.ps1 finished successfully." -ForegroundColor Green
}
