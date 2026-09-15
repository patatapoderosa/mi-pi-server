<#
.SYNOPSIS
  Build the versioned Windows release payload (dev/maintainer machine).

.DESCRIPTION
  Creates mi-pi-server-windows.zip containing exactly the files the installer
  manifest expects, plus SHA256SUMS.txt (BSD-style "<hash>  <file>" lines).

  Layout inside the ZIP (payload root):
    server\pi-daemon.mjs, spawn-pi.mjs
    server\pi-remote-config\index.ts + package.json
    server\pi-remote-server\index.ts, server.ts, migrate.ts, tailscale.ts
    shared\protocol.ts, modules.ts, store.ts, pi-model.ts
    installer\PiServerLib.ps1, windows-installer.ps1, run-task.ps1, run-remote.ps1
  Run from the repo root (any OS with pwsh):
    pwsh -NoProfile -File installer/New-Release.ps1 -Version v0.1.0

  Publish both files as GitHub release assets. The installer and setup.ps1
  verify the hash fail-closed before executing anything.

  5.1 compatible (runs on Windows PowerShell too).
#>
[CmdletBinding()]
param(
  [string]$Version = "",
  [string]$RepoRoot = "",
  [string]$OutDir = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
if ([string]::IsNullOrWhiteSpace($Version)) {
  $pkg = Get-Content -LiteralPath (Join-Path $RepoRoot "package.json") -Raw | ConvertFrom-Json
  $Version = "v" + [string]$pkg.version
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $RepoRoot "dist-release"
}

. (Join-Path (Split-Path -Parent $PSCommandPath) "PiServerLib.ps1")
$updateLibPath = Join-Path (Split-Path -Parent $PSCommandPath) "PiServerUpdate.ps1"
if (Test-Path -LiteralPath $updateLibPath) { . $updateLibPath }
$wanted = @($script:ReleaseManifest | ForEach-Object { $_ })
$v3Marker = Join-Path $RepoRoot "installer\PiServerUpdate.ps1"
if ((Test-Path -LiteralPath $v3Marker) -and ($null -ne $script:ReleaseManifestV3)) {
  $wanted = @($script:ReleaseManifestV3 | ForEach-Object { $_ })
}
foreach ($rel in $wanted) {
  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel))) {
    Write-Host "RELEASE FALLITA" -ForegroundColor Red
    Write-Host "Motivo: file sorgente mancante: $rel"
    exit 1
  }
}

# Pre-ZIP runtime gates: a release is shippable only if every runtime
# entrypoint parses. v0.2.6 shipped a syntactically broken pi-daemon.mjs
# because nothing checked it.
. (Join-Path (Split-Path -Parent $PSCommandPath) "PiServerLib.ps1")
$rtGate = Test-RuntimeSyntax -Files @(
  (Join-Path $RepoRoot "server\pi-daemon.mjs"),
  (Join-Path $RepoRoot "server\spawn-pi.mjs"))
if (-not $rtGate.Ok) {
  Write-Host "RELEASE FALLITA" -ForegroundColor Red
  Write-Host ("Motivo: runtime JS non valido: " + ($rtGate.Failures -join "; "))
  exit 1
}
Write-Host "runtime JS syntax OK (pi-daemon.mjs, spawn-pi.mjs)" -ForegroundColor Green
$psGateFiles = @($wanted | Where-Object { $_ -like "*.ps1" })
$psBad = @()
foreach ($rel in $psGateFiles) {
  $pf = Join-Path $RepoRoot $rel
  $tok = $null
  $errs = $null
  [System.Management.Automation.Language.Parser]::ParseFile($pf, [ref]$tok, [ref]$errs) | Out-Null
  if ($errs.Count -gt 0) { $psBad += ($rel + ": " + $errs[0].Message) }
}
if ($psBad.Count -gt 0) {
  Write-Host "RELEASE FALLITA" -ForegroundColor Red
  Write-Host ("Motivo: PowerShell non valido: " + ($psBad -join "; "))
  exit 1
}
Write-Host ("PowerShell syntax OK (" + $psGateFiles.Count + " file)") -ForegroundColor Green
try {
  & npm --prefix "$RepoRoot" run typecheck 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
} catch {
  Write-Host "RELEASE FALLITA" -ForegroundColor Red
  Write-Host ("Motivo: typecheck TS fallito: " + $_.Exception.Message)
  exit 1
}
Write-Host "typecheck TS OK" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$stage = Join-Path $OutDir ("stage-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
  foreach ($rel in $wanted) {
    $dst = Join-Path $stage $rel
    $d = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $d)) {
      New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot $rel) -Destination $dst -Force
  }
  $zipName = "mi-pi-server-windows.zip"
  $zipPath = Join-Path $OutDir $zipName
  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -Force
  $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  "$hash  $zipName" | Out-File -LiteralPath (Join-Path $OutDir "SHA256SUMS.txt") -Encoding ascii -NoNewline
  Write-Host "Release $Version pronta in $OutDir" -ForegroundColor Green
  Write-Host "  $zipName"
  Write-Host "  SHA256SUMS.txt ($hash)"
  Write-Host ""
  Write-Host "Pubblica entrambi come asset della release GitHub $Version."
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
