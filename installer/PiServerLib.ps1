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
  "installer\run-remote.ps1",
  "installer\windows-installer.ps1",
  "server\pi-remote-server\index.ts",
  "server\pi-remote-server\server.ts",
  "server\pi-remote-server\migrate.ts",
  "server\pi-remote-server\tailscale.ts"
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
    RemoteEntry = Join-Path $app "server\pi-remote-server\index.ts"
    RunRemote = Join-Path $app "run-remote.ps1"
    RuntimeEnv = Join-Path $app "runtime-env.json"
    VersionFile = Join-Path $app "VERSION"
    InstallerLog = Join-Path $logs "installer.log"
    ServerLog = Join-Path $logs "pi-server.log"
    ServerErrLog = Join-Path $logs "pi-server-error.log"
    RemoteLog = Join-Path $logs "remote-server.log"
    RemoteErrLog = Join-Path $logs "remote-server-error.log"
    TaskName = "PiHomeServer"
    RemoteTaskName = "PiRemoteServer"
    RemotePortDefault = 43128
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

<#
.SYNOPSIS
  Atomic staged deploy: payload -> stage -> validate -> swap.
.DESCRIPTION
  Copies server/, shared/, installer/ into a fresh stage dir (created first,
  fixing the PS 5.1 'container onto leaf' failure), stamps VERSION, validates
  the stage manifest, then swaps: backup in update mode, wipe otherwise.
  Never throws: returns @{ Ok, Error, BackupPath }. On failure the stage is
  removed and the live app is untouched (swap never ran).
#>
function Invoke-AppStaging {
  param([string]$PayloadDir, [string]$AppPath, [string]$Mode = "fresh", [string]$VersionLabel = "")
  $res = @{ Ok = $false; Error = ""; BackupPath = $null }
  try {
    if ([string]::IsNullOrWhiteSpace($PayloadDir) -or (-not (Test-Path -LiteralPath $PayloadDir))) {
      $res.Error = "payload dir missing: $PayloadDir"; return $res
    }
    if ([string]::IsNullOrWhiteSpace($AppPath)) { $res.Error = "app path empty"; return $res }
    $man = Test-ReleaseManifest -PayloadRoot $PayloadDir
    if (-not $man.Ok) { $res.Error = "Manifest incompleto: " + ($man.Missing -join ", "); return $res }
    $stage = $AppPath + ".new-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $stage -Force -ErrorAction Stop | Out-Null
    try {
      foreach ($sub in @("server", "shared", "installer")) {
        $src = Join-Path $PayloadDir $sub
        if (-not (Test-Path -LiteralPath $src)) { continue }
        # Destination MUST exist first: on PS 5.1 a wildcard Copy-Item onto a
        # missing path fails ('container onto existing leaf item').
        $dst = Join-Path $stage $sub
        New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop | Out-Null
        Copy-Item -Path (Join-Path $src "*") -Destination $dst -Recurse -Force -ErrorAction Stop
      }
      if ($VersionLabel -ne "") {
        $VersionLabel | Out-File -LiteralPath (Join-Path $stage "VERSION") -Encoding ascii -NoNewline -ErrorAction Stop
      }
      $stMan = Test-ReleaseManifest -PayloadRoot $stage
      if (-not $stMan.Ok) { throw ("Manifest dello stage incompleto: " + ($stMan.Missing -join ", ")) }
    } catch {
      Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
      throw
    }
    $backup = $null
    if ((Test-Path -LiteralPath $AppPath) -and ($Mode -eq "update")) {
      $backup = $AppPath + ".backup-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
      Move-Item -LiteralPath $AppPath -Destination $backup -Force -ErrorAction Stop
    } elseif (Test-Path -LiteralPath $AppPath) {
      Remove-Item -LiteralPath $AppPath -Recurse -Force -ErrorAction Stop
    }
    try {
      Move-Item -LiteralPath $stage -Destination $AppPath -Force -ErrorAction Stop
    } catch {
      $swapErr = $_.Exception.Message
      if ($null -ne $backup) {
        try { Move-Item -LiteralPath $backup -Destination $AppPath -Force -ErrorAction Stop }
        catch { throw "Swap fallito E restore del backup fallito (ripristino manuale da: $backup). Errore swap: $swapErr" }
        throw "Swap fallito, backup ripristinato. Errore swap: $swapErr"
      }
      throw "Swap fallito: $swapErr"
    }
    $res.Ok = $true
    $res.BackupPath = $backup
    return $res
  } catch {
    $res.Error = $_.Exception.Message
    return $res
  }
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
  $sumsError = ""
  if (-not [string]::IsNullOrWhiteSpace($sums)) {
    # Never parse IWR .Content in-memory (fragile on PS 5.1 IE engine):
    # download to file, then run the strict Get-ReleaseChecksum parser.
    $sumsFile = Join-Path ([System.IO.Path]::GetTempPath()) ("piserver-sums-" + [Guid]::NewGuid().ToString("N") + ".txt")
    try {
      Invoke-WebRequest -Uri $sums -OutFile $sumsFile -TimeoutSec 30
      $par = Get-ReleaseChecksum -SumsFile $sumsFile
      if ($par.Ok) { $sha = $par.Hash }
      else { $sumsError = $par.Error + " (" + $par.Detail + ")" }
    } catch {
      $sumsError = "download failed: $($_.Exception.Message)"
    } finally {
      Remove-Item -LiteralPath $sumsFile -Force -ErrorAction SilentlyContinue
    }
  }
  return @{ Tag = [string]$rel.tag_name; ZipUrl = [string]$zip; Sha256 = $sha; SumsError = $sumsError }
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
    foreach ($f in @((Join-Path $Paths.AgentDir "remote-server.json"), (Join-Path $Paths.SecretsDir "server-bot-token"), (Join-Path $Paths.SecretsDir "remote-hmac"))) {
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
        $rt = Get-ScheduledTask -TaskName $Paths.RemoteTaskName -ErrorAction SilentlyContinue
        if ($null -eq $rt) {
          $script:hcFail += "task $($Paths.RemoteTaskName) assente"
        } else {
          $rprocs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_ -match "pi-remote-server" }
          if (($null -eq $rprocs) -or (@($rprocs).Count -eq 0)) {
            $script:hcFail += "processo pi-remote-server non in esecuzione"
          }
          $rp = Test-RemoteDaemon -Paths $Paths -TimeoutSec 10
          if (-not $rp.Ok) { $script:hcFail += "remote daemon: $($rp.Detail)" }
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

<#
.SYNOPSIS
  Authenticated liveness probe of the remote daemon (HMAC-signed GET /v1/ping).
.DESCRIPTION
  Reads the HMAC from the secrets dir (installer runs elevated, ACL allows
  it) and signs exactly like the Mac client. Never throws: returns
  @{ Ok, Detail }. Never logs the HMAC or the signature.
#>
function Test-RemoteDaemon {
  param($Paths, [int]$TimeoutSec = 10)
  try {
    $cfgPath = Join-Path $Paths.AgentDir "remote-server.json"
    $port = $Paths.RemotePortDefault
    if (Test-Path -LiteralPath $cfgPath) {
      try {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($cfg.port -is [int] -and $cfg.port -ge 1 -and $cfg.port -le 65535) { $port = $cfg.port }
      } catch { }
    }
    $hmacFile = Join-Path $Paths.SecretsDir "remote-hmac"
    if (-not (Test-Path -LiteralPath $hmacFile)) { return @{ Ok = $false; Detail = "HMAC file missing" } }
    $hmac = (Get-Content -LiteralPath $hmacFile -Raw -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($hmac)) { return @{ Ok = $false; Detail = "HMAC file empty" } }
    $bind = "127.0.0.1"
    try {
      $tsOut = & tailscale ip -4 2>$null
      $tip = ($tsOut | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match "^100\.(6[4-9]|[78]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$" } | Select-Object -First 1)
      if (-not [string]::IsNullOrWhiteSpace($tip)) { $bind = $tip }
    } catch { }
    $ts = [string][int](Get-Date -UFormat %s)
    $nonce = [Guid]::NewGuid().ToString("N")
    $emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    $base = "GET`n/v1/ping`n$ts`n$nonce`n$emptyHash"
    $key = [Text.Encoding]::UTF8.GetBytes($hmac)
    $h = New-Object Security.Cryptography.HMACSHA256(, $key)
    try {
      $sig = ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($base)) | ForEach-Object { $_.ToString("x2") }) -join ""
    } finally { $h.Dispose() }
    $url = "http://${bind}:$port/v1/ping"
    $r = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop `
      -Headers @{ "x-pi-timestamp" = $ts; "x-pi-nonce" = $nonce; "x-pi-signature" = $sig }
    $j = $r.Content | ConvertFrom-Json
    if ($j.ok -eq $true) { return @{ Ok = $true; Detail = "pong via $bind" } }
    return @{ Ok = $false; Detail = "refused: $($j.error)" }
  } catch {
    return @{ Ok = $false; Detail = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Our tailnet IPv4 (100.64.0.0/10) or empty when Tailscale is down.
#>
function Get-TailscaleIpv4 {
  try {
    $out = & tailscale ip -4 2>$null
    foreach ($line in @($out)) {
      $t = "$line".Trim()
      if ($t -match "^100\.(6[4-9]|[78]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$") { return $t }
    }
  } catch { }
  return ""
}

<#
.SYNOPSIS
  Tailscale interface alias for scoped firewall rules (empty when absent).
#>
function Get-TailscaleInterfaceAlias {
  try {
    $nics = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match "Tailscale" }
    $first = @($nics) | Select-Object -First 1
    if ($null -ne $first) { return [string]$first.InterfaceAlias }
  } catch { }
  return ""
}
