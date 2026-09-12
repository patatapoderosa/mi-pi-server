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
    shared\protocol.ts, modules.ts, store.ts
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

$wanted = @(
  "server\pi-daemon.mjs",
  "server\spawn-pi.mjs",
  "server\pi-remote-config\index.ts",
  "server\pi-remote-config\package.json",
  "server\pi-remote-server\index.ts",
  "server\pi-remote-server\server.ts",
  "server\pi-remote-server\migrate.ts",
  "server\pi-remote-server\tailscale.ts",
  "shared\protocol.ts",
  "shared\modules.ts",
  "shared\store.ts",
  "installer\PiServerLib.ps1",
  "installer\windows-installer.ps1",
  "installer\run-task.ps1",
  "installer\run-remote.ps1"
)

foreach ($rel in $wanted) {
  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel))) {
    Write-Host "RELEASE FALLITA" -ForegroundColor Red
    Write-Host "Motivo: file sorgente mancante: $rel"
    exit 1
  }
}

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
