# PiServer bootstrap marker v1 (setup.ps1 sanity check: the downloaded file must contain this line).
<#
.SYNOPSIS
  One-line bootstrap for the PiServer 24/7 node on a clean Windows PC.

.DESCRIPTION
  Usage (single command in any PowerShell, admin rights NOT required):
    irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 | iex

  What it does:
  1. Enables modern TLS, checks Windows/PowerShell.
  2. Materializes itself to %TEMP% (required for auto-elevation from a pipe).
  3. Re-launches elevated (Start-Process -Verb RunAs) when not admin,
     propagating arguments and exit code.
  4. Downloads the versioned release ZIP + SHA256SUMS.txt over HTTPS.
  5. Verifies the SHA256 (fail closed), extracts, validates the installer
     manifest, launches installer\windows-installer.ps1 -PayloadDir, propagates
     its exit code, and cleans the temp files.

  TRUST ROOT (read this): this file itself is fetched over HTTPS from
  raw.githubusercontent.com and is NOT checksum-verified (nothing verifies the
  verifier). Everything it executes afterwards IS hash-verified. If you need
  stronger guarantees, download a tagged setup.ps1, inspect it, and pass
  -ExpectedSha256 for the payload. See docs/SECURITY.md.

  5.1 compatible. Never logs secrets (it never handles any).
#>
[CmdletBinding()]
param(
  [string]$Repo = "patatapoderosa/mi-pi-server",
  [string]$Version = "latest",
  [string]$ExpectedSha256 = "",
  [switch]$Update,
  [switch]$Resume,
  [switch]$Force,
  [int]$FromStep = 0,
  [string]$InstallRoot = "C:\PiServer",
  [string]$TailscaleAuthKey = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Boot-Fail([string]$why) {
  Write-Host ""
  Write-Host "BOOTSTRAP FALLITO" -ForegroundColor Red
  Write-Host "Motivo: $why"
  exit 1
}

# ===== BEGIN Get-ReleaseChecksum (mirror: installer/PiServerLib.ps1 <-> setup.ps1) =====
# Canonical SHA256SUMS parser. setup.ps1 embeds a byte-identical copy because
# the bootstrap must stay standalone; the smoke test asserts both blocks match.
function Get-ReleaseChecksum {
  param([string]$SumsFile, [string]$AssetName = "mi-pi-server-windows.zip")
  if ([string]::IsNullOrWhiteSpace($SumsFile) -or (-not (Test-Path -LiteralPath $SumsFile))) {
    return @{ Ok = $false; Hash = ""; Error = "sums_missing"; Detail = "SHA256SUMS file not found: $SumsFile" }
  }
  try {
    $fi = Get-Item -LiteralPath $SumsFile -ErrorAction Stop
    if ($fi.Length -le 0) {
      return @{ Ok = $false; Hash = ""; Error = "sums_empty"; Detail = "SHA256SUMS file is empty (0 bytes): $SumsFile" }
    }
    # ReadAllText strips BOM (UTF-8/UTF-16) via .NET detection. Get-Content -Raw
    # on PS 5.1 would keep BOM chars and decode without-BOM files as ANSI.
    $text = [System.IO.File]::ReadAllText($fi.FullName)
    $size = $fi.Length
  } catch {
    return @{ Ok = $false; Hash = ""; Error = "sums_unreadable"; Detail = "Cannot read SHA256SUMS file: $($_.Exception.Message)" }
  }
  $text = $text -replace "`r`n", "`n"
  $assetRx = [regex]::Escape($AssetName)
  $found = @()
  $others = @()
  $lines = 0
  foreach ($line in ($text -split "`n")) {
    $t = $line.Trim()
    if ($t -eq "") { continue }
    $lines++
    # BSD coreutils form: '<64hex><spaces>[*]<file>' — strict, exact filename only.
    $m = [regex]::Match($t, "^([0-9a-fA-F]{64})[ \t]+\*?$assetRx$")
    if ($m.Success) { $found += $m.Groups[1].Value.ToLowerInvariant() }
    else {
      $om = [regex]::Match($t, "^([0-9a-fA-F]{64})[ \t]+\*?(\S+)$")
      if ($om.Success) { $others += $om.Groups[2].Value }
    }
  }
  $distinct = @($found | Select-Object -Unique)
  if ($distinct.Count -eq 0) {
    return @{ Ok = $false; Hash = ""; Error = "checksum_not_found"; Detail = "No valid line for '$AssetName' (file ${size}B, $lines non-empty lines, other entries: $($others -join ', '))" }
  }
  if ($distinct.Count -gt 1) {
    return @{ Ok = $false; Hash = ""; Error = "checksum_conflict"; Detail = "Conflicting hashes for '$AssetName' ($($distinct.Count) distinct). Refusing." }
  }
  return @{ Ok = $true; Hash = $distinct[0]; Error = ""; Detail = "OK (${size}B, $lines lines)" }
}
# ===== END Get-ReleaseChecksum =====

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  Boot-Fail "Impossibile abilitare TLS 1.2: $($_.Exception.Message)"
}

if ($env:OS -ne "Windows_NT") {
  Boot-Fail "Questo bootstrap gira solo su Windows."
}

$IsAdminNow = $false
try {
  $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
  $ppal = New-Object Security.Principal.WindowsPrincipal($ident)
  $IsAdminNow = $ppal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# ---- Materialize this script to TEMP so elevation works from a pipe ----
$selfUrl = ""
if ($Version -eq "latest") {
  $selfUrl = "https://raw.githubusercontent.com/$Repo/main/setup.ps1"
} else {
  $selfUrl = "https://raw.githubusercontent.com/$Repo/$Version/setup.ps1"
}
$tmpDir = Join-Path $env:TEMP ("piserver-boot-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$selfFile = Join-Path $tmpDir "setup.ps1"
try {
  Invoke-WebRequest -Uri $selfUrl -OutFile $selfFile -TimeoutSec 120
} catch {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  Boot-Fail "Download setup.ps1 fallito ($selfUrl): $($_.Exception.Message)"
}
$probe = Get-Content -LiteralPath $selfFile -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($probe) -or ($probe -notmatch "PiServer bootstrap marker")) {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  Boot-Fail "setup.ps1 scaricato non valido (contenuto inatteso)."
}

if (-not $IsAdminNow) {
  Write-Host "Riavvio come amministratore..." -ForegroundColor Yellow
  $eArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$selfFile`"",
    "-Repo", "`"$Repo`"", "-Version", "`"$Version`"", "-InstallRoot", "`"$InstallRoot`"")
  if ($Update) { $eArgs += "-Update" }
  if ($Resume) { $eArgs += "-Resume" }
  if ($Force) { $eArgs += "-Force" }
  if ($FromStep -gt 0) { $eArgs += @("-FromStep", "$FromStep") }
  if ($ExpectedSha256 -ne "") { $eArgs += @("-ExpectedSha256", "`"$ExpectedSha256`"") }
  try {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $eArgs -Verb RunAs -Wait -PassThru
    $code = $p.ExitCode
  } catch {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Boot-Fail "Auto-elevation rifiutata o fallita: $($_.Exception.Message)"
  }
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  exit $code
}

# ---- Elevated from here: fetch release, verify, extract, delegate ----
Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "       PI HOME SERVER SETUP" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

try {
  if ($Repo -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
    throw "Repo non valido (atteso OWNER/NAME): '$Repo'"
  }
  if ($Version -eq "latest") {
    $api = "https://api.github.com/repos/$Repo/releases/latest"
  } else {
    $api = "https://api.github.com/repos/$Repo/releases/tags/$Version"
  }
  $rel = Invoke-RestMethod -Uri $api -TimeoutSec 60
  $zipUrl = $null
  $sumsUrl = $null
  foreach ($a in $rel.assets) {
    if ($a.name -eq "mi-pi-server-windows.zip") { $zipUrl = $a.browser_download_url }
    if ($a.name -eq "SHA256SUMS.txt") { $sumsUrl = $a.browser_download_url }
  }
  if ([string]::IsNullOrWhiteSpace($zipUrl)) {
    throw "Asset mi-pi-server-windows.zip assente nella release $($rel.tag_name)."
  }
  # Resume senza riscaricare: se il checkpoint dice deploy/config/secrets/tasks
  # fatti per QUESTA release e app/VERSION esistono, salto download+verify+extract.
  # L'installer riverifica comunque ogni step sulla macchina reale.
  $bootSkipDownload = $false
  try {
    $peekRaw = Get-Content -LiteralPath (Join-Path $InstallRoot "data\install-state.json") -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $peekDone = @($peekRaw.completedSteps)
    $peekOk = $true
    foreach ($pn in @("deploy", "config", "secrets", "tasks")) { if ($peekDone -notcontains $pn) { $peekOk = $false } }
    if ($peekOk -and ([string]$peekRaw.targetRelease -eq [string]$rel.tag_name) -and (Test-Path -LiteralPath (Join-Path $InstallRoot "app\server\pi-daemon.mjs")) -and (Test-Path -LiteralPath (Join-Path $InstallRoot "app\VERSION")) -and (Test-Path -LiteralPath (Join-Path $InstallRoot "app\installer\windows-installer.ps1"))) {
      $bootSkipDownload = $true
      Write-Host "Deploy gia verificato per $($rel.tag_name): salto il download, riprendo dall'installer." -ForegroundColor Cyan
    }
  } catch { $bootSkipDownload = $false }
  $payload = ""
  if (-not $bootSkipDownload) {
  $want = $ExpectedSha256
  if ([string]::IsNullOrWhiteSpace($want) -and (-not [string]::IsNullOrWhiteSpace($sumsUrl))) {
    # Never parse IWR .Content in-memory: on PS 5.1 that path depends on the IE
    # engine and silently yields nothing. Download to file, then strict-parse.
    $sumsFile = Join-Path $tmpDir "SHA256SUMS.txt"
    try {
      Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsFile -TimeoutSec 60
    } catch {
      throw "Download SHA256SUMS.txt fallito ($sumsUrl): $($_.Exception.Message)"
    }
    $par = Get-ReleaseChecksum -SumsFile $sumsFile
    if ($par.Ok) {
      $want = $par.Hash
    } else {
      $diag = @("release: $($rel.tag_name)",
        "asset cercati: mi-pi-server-windows.zip, SHA256SUMS.txt",
        "asset trovati: " + ((@($rel.assets) | ForEach-Object { $_.name }) -join ", "),
        "URL checksum: $sumsUrl")
      try { $diag += ("file scaricato: " + (Get-Item -LiteralPath $sumsFile).Length + " bytes") } catch { }
      throw ("SHA256SUMS non utilizzabile [" + $par.Error + "]: " + $par.Detail + " | " + ($diag -join " | "))
    }
  }
  if ([string]::IsNullOrWhiteSpace($want)) {
    throw "Nessun checksum disponibile (né -ExpectedSha256 né SHA256SUMS.txt). Fail closed."
  }
  $zipPath = Join-Path $tmpDir "payload.zip"
  Write-Host "Download release $($rel.tag_name)..."
  Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -TimeoutSec 600
  $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $want.Trim().ToLowerInvariant()) {
    throw "Checksum release non coincide. File scartato (fail closed)."
  }
  Write-Host "Checksum OK." -ForegroundColor Green

  $payload = Join-Path $tmpDir "payload"
  Expand-Archive -LiteralPath $zipPath -DestinationPath $payload -Force
  # Unwrap single top-level folder (GitHub zips nest everything one level deep).
  $probeDaemon = Join-Path $payload "server\pi-daemon.mjs"
  if (-not (Test-Path -LiteralPath $probeDaemon)) {
    $subs = Get-ChildItem -LiteralPath $payload -Directory -ErrorAction SilentlyContinue
    if (($null -ne $subs) -and (@($subs).Count -eq 1)) {
      $inner = Join-Path $subs[0].FullName "server\pi-daemon.mjs"
      if (Test-Path -LiteralPath $inner) { $payload = $subs[0].FullName }
    }
  }
  $installer = Join-Path $payload "installer\windows-installer.ps1"
  if (-not (Test-Path -LiteralPath $installer)) {
    throw "Manifest bootstrap fallito: installer\windows-installer.ps1 assente nel payload."
  }
  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

  } else {
    $installer = Join-Path $InstallRoot "app\installer\windows-installer.ps1"
  }
  $iArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$installer`"",
    "-Repo", "`"$Repo`"", "-Version", "`"$Version`"",
    "-InstallRoot", "`"$InstallRoot`"")
  if ($payload -ne "") { $iArgs += @("-PayloadDir", "`"$payload`"") }
  if ($Update) { $iArgs += "-Update" }
  if ($Resume) { $iArgs += "-Resume" }
  if ($Force) { $iArgs += "-Force" }
  if ($FromStep -gt 0) { $iArgs += @("-FromStep", "$FromStep") }
  if ($ExpectedSha256 -ne "") { $iArgs += @("-ExpectedSha256", "`"$ExpectedSha256`"") }
  # Auth key travels only inside this already-elevated session (still visible
  # in this process command line: prefer interactive login when shoulder-surfing matters).
  if ($TailscaleAuthKey -ne "") { $iArgs += @("-TailscaleAuthKey", "`"$TailscaleAuthKey`"") }
  # Run in-process so output streams live; exit code propagates.
  # 0 = ok, 1 = failed, 2 = paused with checkpoint (rilancia per riprendere).
  & powershell.exe @iArgs
  $code = $LASTEXITCODE
  if ($code -eq 2) { Write-Host "Installer in pausa (checkpoint salvato). Rilancia lo stesso comando per riprendere." -ForegroundColor Cyan }
} catch {
  Write-Host ""
  Write-Host "BOOTSTRAP FALLITO" -ForegroundColor Red
  Write-Host "Motivo: $($_.Exception.Message)"
  $code = 1
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
