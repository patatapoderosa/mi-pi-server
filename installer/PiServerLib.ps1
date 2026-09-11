<#
.SYNOPSIS
  Pure helper functions for the PiServer Windows installer.
  Windows PowerShell 5.1 compatible (no ??, ?., ternary, && chains).

.DESCRIPTION
  This file MUST have no side effects when dot-sourced: only function
  definitions and constants. The smoke tests dot-source it on any OS.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Files the release payload must contain (relative to payload root).
$script:ReleaseManifest = @(
  "server\pi-daemon.mjs",
  "server\pi-remote-config\index.ts",
  "server\pi-remote-config\package.json",
  "shared\protocol.ts",
  "shared\modules.ts",
  "shared\store.ts",
  "installer\run-task.ps1",
  "installer\windows-installer.ps1"
)

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Test-AtLeastNode22 {
  param([string]$VersionString)
  if ([string]::IsNullOrWhiteSpace($VersionString)) { return $false }
  $m = [regex]::Match($VersionString.Trim(), "^v?(\d+)\.(\d+)\.(\d+)")
  if (-not $m.Success) { return $false }
  $major = [int]$m.Groups[1].Value
  return ($major -ge 22)
}

function Get-PiServerPaths {
  param([string]$Root = "C:\PiServer")
  $app = Join-Path $Root "app"
  $data = Join-Path $Root "data"
  $logs = Join-Path $Root "logs"
  return @{
    Root = $Root
    App = $app
    Data = $data
    Logs = $logs
    AgentDir = $data
    ExtDir = Join-Path $data "extensions"
    SharedDir = Join-Path $data "shared"
    SecretsDir = Join-Path $data "secrets"
    ConfigDir = Join-Path $data "server-config"
    Daemon = Join-Path $app "server\pi-daemon.mjs"
    RunTask = Join-Path $app "run-task.ps1"
    RuntimeEnv = Join-Path $app "runtime-env.json"
    VersionFile = Join-Path $app "VERSION"
    InstallerLog = Join-Path $logs "installer.log"
    ServerLog = Join-Path $logs "pi-server.log"
    ServerErrLog = Join-Path $logs "pi-server-error.log"
    TaskName = "PiHomeServer"
  }
}

function Backup-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  $bak = "$Path.bak-$stamp"
  Copy-Item -LiteralPath $Path -Destination $bak -Force
  return $bak
}

function Write-InstallLog {
  param(
    [string]$Message,
    [string]$LogFile = "",
    [ValidateSet("INFO", "OK", "WARN", "FAIL")][string]$Level = "INFO"
  )
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
  if ($Level -eq "FAIL") { Write-Host $line -ForegroundColor Red }
  elseif ($Level -eq "WARN") { Write-Host $line -ForegroundColor Yellow }
  elseif ($Level -eq "OK") { Write-Host $line -ForegroundColor Green }
  else { Write-Host $line }
  if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
    try {
      $dir = Split-Path -Parent $LogFile
      if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
      }
      Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
      # Logging must never break the install.
    }
  }
}

function Test-FileChecksum {
  param([string]$Path, [string]$ExpectedSha256)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return $false }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual.ToLowerInvariant() -eq $ExpectedSha256.Trim().ToLowerInvariant())
  } catch {
    return $false
  }
}

function Test-ReleaseManifest {
  param([string]$PayloadRoot)
  $missing = @()
  foreach ($rel in $script:ReleaseManifest) {
    $full = Join-Path $PayloadRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { $missing += $rel }
  }
  return @{ Ok = ($missing.Count -eq 0); Missing = $missing }
}

function Read-HiddenInput {
  param([string]$Prompt)
  $sec = Read-Host -Prompt $Prompt -AsSecureString
  if ($null -eq $sec) { return "" }
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  }
}

function New-RandomHex {
  param([int]$Bytes = 32)
  $buf = New-Object byte[] $Bytes
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($buf)
  } finally {
    $rng.Dispose()
  }
  return ([BitConverter]::ToString($buf)).Replace("-", "").ToLowerInvariant()
}

function Resolve-ToolPath {
  param([string]$Name)
  try {
    $cmd = Get-Command $Name -ErrorAction Stop
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
      return $cmd.Source
    }
    return $null
  } catch {
    return $null
  }
}
function Test-WindowsOS {
  return ($env:OS -eq "Windows_NT")
}

<#
.SYNOPSIS
  Resolve a GitHub release to a ZIP URL plus its expected SHA256.
.DESCRIPTION
  Version 'latest' uses releases/latest; otherwise releases/tags/<Version>.
  Asset names: mi-pi-server-windows.zip + SHA256SUMS.txt ("<hash>  <file>" lines).
  Returns @{ Tag, ZipUrl, Sha256 }. Throws when the release or assets are missing.
#>
function Get-ReleaseDownload {
  param([string]$Repo, [string]$Version)
  if ([string]::IsNullOrWhiteSpace($Repo) -or ($Repo -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) {
    throw "Repo non valido (atteso OWNER/NAME): '$Repo'"
  }
  if ($Version -eq "latest") {
    $api = "https://api.github.com/repos/$Repo/releases/latest"
  } else {
    $api = "https://api.github.com/repos/$Repo/releases/tags/$Version"
  }
  $rel = Invoke-RestMethod -Uri $api -TimeoutSec 30
  $zip = $null
  $sums = $null
  foreach ($a in $rel.assets) {
    if ($a.name -eq "mi-pi-server-windows.zip") { $zip = $a.browser_download_url }
    if ($a.name -eq "SHA256SUMS.txt") { $sums = $a.browser_download_url }
  }
  if ([string]::IsNullOrWhiteSpace($zip)) {
    throw "Asset mi-pi-server-windows.zip assente nella release $($rel.tag_name)."
  }
  $sha = ""
  if (-not [string]::IsNullOrWhiteSpace($sums)) {
    $txt = Invoke-WebRequest -Uri $sums -TimeoutSec 30 | Select-Object -ExpandProperty Content
    foreach ($line in ($txt -split "`r?`n")) {
      $m = [regex]::Match($line.Trim(), "^([0-9a-fA-F]{64})\s+mi-pi-server-windows\.zip$")
      if ($m.Success) { $sha = $m.Groups[1].Value.ToLowerInvariant() }
    }
  }
  return @{ Tag = [string]$rel.tag_name; ZipUrl = [string]$zip; Sha256 = $sha }
}

<#
.SYNOPSIS
  Normalize an extracted payload dir (unwrap single top-level folder).
#>
function Resolve-PayloadRoot {
  param([string]$Dir)
  $probe = Join-Path $Dir "server\pi-daemon.mjs"
  if (Test-Path -LiteralPath $probe) { return $Dir }
  $subs = Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue
  if (($null -ne $subs) -and (@($subs).Count -eq 1)) {
    $inner = Join-Path $subs[0].FullName "server\pi-daemon.mjs"
    if (Test-Path -LiteralPath $inner) { return $subs[0].FullName }
  }
  return $Dir
}


<#
.SYNOPSIS
  Write a JSON config file only when missing; otherwise keep user data and
  back up before any merge. Returns "created", "kept" or "merged".
#>
function Save-JsonConfigPreserving {
  param(
    [string]$Path,
    [hashtable]$Defaults,
    [string[]]$RequiredKeys = @()
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Defaults | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8
    return "created"
  }
  try {
    $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
  } catch {
    Backup-File -Path $Path | Out-Null
    $Defaults | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8
    return "merged"
  }
  $merged = $false
  foreach ($k in $RequiredKeys) {
    if ($null -eq $existing.PSObject.Properties[$k]) {
      Backup-File -Path $Path | Out-Null
      $existing | Add-Member -NotePropertyName $k -NotePropertyValue $Defaults[$k]
      $merged = $true
    }
  }
  if ($merged) {
    $existing | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8
    return "merged"
  }
  return "kept"
}

<#
.SYNOPSIS
  Post-install health check. Fail closed: returns @{ Ok, Failures }.
.DESCRIPTION
  Never throws: every probe is guarded so a broken environment yields
  Failures entries instead of an exception. On non-Windows the Task
  Scheduler probes report failure (honest: the runtime needs Windows).
#>
function Invoke-HealthCheck {
  param($Paths, [string]$PiBin = "")
  $script:hcFail = @()
  try {
    $nodeOut = ""
    try { $nodeOut = (& node --version 2>$null) } catch { }
    if (-not (Test-AtLeastNode22 -VersionString ([string]$nodeOut))) {
      $script:hcFail += "node: assente o < 22 (trovato: '$nodeOut')"
    }
    if ([string]::IsNullOrWhiteSpace($PiBin) -or (-not (Test-Path -LiteralPath $PiBin))) {
      $script:hcFail += "pi: binario non trovato ($PiBin)"
    }
    $idx = Join-Path $Paths.ExtDir "pi-remote-config\index.ts"
    if (-not (Test-Path -LiteralPath $idx)) {
      $script:hcFail += "extension mancante: $idx"
    }
    foreach ($name in @("protocol.ts", "modules.ts", "store.ts")) {
      $sf = Join-Path $Paths.SharedDir $name
      if (-not (Test-Path -LiteralPath $sf)) {
        $script:hcFail += "shared mancante: $sf"
      }
    }
    foreach ($f in @((Join-Path $Paths.AgentDir "remote-auth.json"), (Join-Path $Paths.SecretsDir "server-bot-token"), (Join-Path $Paths.SecretsDir "remote-hmac"))) {
      if (-not (Test-Path -LiteralPath $f)) { $script:hcFail += "config/secret mancante: $f" }
    }
    if (-not (Test-WindowsOS)) {
      $script:hcFail += "non-Windows: Task Scheduler non verificabile"
    } else {
      $t = Get-ScheduledTask -TaskName $Paths.TaskName -ErrorAction SilentlyContinue
      if ($null -eq $t) {
        $script:hcFail += "task $($Paths.TaskName) assente"
      } else {
        $log = $Paths.ServerLog
        if (-not (Test-Path -LiteralPath $log)) {
          $script:hcFail += "log assente (task mai partita?): $log"
        } else {
          $age = (Get-Date) - (Get-Item -LiteralPath $log).LastWriteTime
          if ($age.TotalMinutes -gt 15) {
            $script:hcFail += "log fermo da $([int]$age.TotalMinutes) min: $log"
          }
          $tail = Get-Content -LiteralPath $log -Tail 30 -ErrorAction SilentlyContinue
          if ($null -ne $tail) {
            $crashes = @($tail | Where-Object { $_ -match "pi exited unexpectedly|spawn failed|uncaught" }).Count
            if ($crashes -gt 3) { $script:hcFail += "crash loop nel log ($crashes/30 righe)" }
          }
        }
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "pi-daemon\.mjs" }
        if (($null -eq $procs) -or (@($procs).Count -eq 0)) {
          $script:hcFail += "processo pi-daemon.mjs non in esecuzione"
        }
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($PiBin)) {
      $env:PI_CODING_AGENT_DIR = $Paths.AgentDir
      try {
        & $PiBin auth check 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $script:hcFail += "pi auth check fallito (login mancante?)" }
      } catch {
        $script:hcFail += "pi auth check errore: $($_.Exception.Message)"
      }
    }
  } catch {
    $script:hcFail += "health check interrotto: $($_.Exception.Message)"
  }
  $res = $script:hcFail
  $script:hcFail = $null
  return @{ Ok = ($res.Count -eq 0); Failures = $res }
}
