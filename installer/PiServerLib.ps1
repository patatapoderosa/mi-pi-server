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
  "server\spawn-pi.mjs",
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

# Runtime layout contract (single source of truth): the payload ships launchers
# under installer\, but the LIVE app serves them at app ROOT because both
# launchers resolve runtime-env.json and logs relative to their own location
# ($AppDir = parent of script). Invoke-AppStaging promotes
# stage\installer\run-*.ps1 -> stage\run-*.ps1 BEFORE the atomic swap, so the
# live app always satisfies this manifest. Task Scheduler actions MUST point
# at Get-PiServerPaths RunTask/RunRemote (app root), never at installer\.
$script:AppManifest = @($script:ReleaseManifest | ForEach-Object { $_ }) + @(
  "run-task.ps1",
  "run-remote.ps1"
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
  # Defense in depth: a Telegram bot token must never reach logs even if a
  # caller interpolates one by mistake. Pattern covers '<digits>:<secret>'.
  $Message = $Message -replace 'bot\d+:[A-Za-z0-9_-]{20,}', 'bot<redacted>'
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
  param([string]$PayloadRoot, [string[]]$Manifest = @())
  if ($Manifest.Count -eq 0) { $Manifest = $script:ReleaseManifest }
  $missing = @()
  foreach ($rel in $Manifest) {
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
# Resume-safe runtime resolvers. The installer skips verified steps, so a step
# that ran in a PREVIOUS PowerShell session never assigns its variables in THIS
# session. These resolvers rebuild shared runtime state on demand from live
# machine state (PATH, well-known locations, validated config hints).
# They never throw and never touch the network: $null means "not found".
function Get-PiCandidatePaths {
  param([string]$RuntimeEnvPath = "")
  $cands = @()
  try {
    $npm = Resolve-ToolPath "npm"
    if ($null -ne $npm) {
      try {
        $prefix = ((& $npm prefix -g 2>$null | Out-String).Trim().Split("`n"))[0].Trim()
        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
          $c = Join-Path $prefix "pi.cmd"
          if (Test-Path -LiteralPath $c) { $cands += $c }
        }
      } catch { }
    }
    $fixed = @("C:\Program Files\nodejs\pi.cmd")
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { $fixed += (Join-Path $env:APPDATA "npm\pi.cmd") }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles})) { $fixed += (Join-Path ${env:ProgramFiles} "nodejs\pi.cmd") }
    foreach ($c in $fixed) {
      if (Test-Path -LiteralPath $c) {
        if ($cands -notcontains $c) { $cands += $c }
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeEnvPath) -and (Test-Path -LiteralPath $RuntimeEnvPath)) {
      try {
        $hint = ([string](Get-Content -LiteralPath $RuntimeEnvPath -Raw | ConvertFrom-Json).PiBin)
        if (-not [string]::IsNullOrWhiteSpace($hint) -and (Test-Path -LiteralPath $hint)) {
          if ($cands -notcontains $hint) { $cands += $hint }
        }
      } catch { }
    }
  } catch { }
  return $cands
}
function Resolve-PiRuntime {
  param([string]$RuntimeEnvPath = "")
  try {
    $p = Resolve-ToolPath "pi"
    if ($null -ne $p -and (Test-Path -LiteralPath $p)) { return $p }
    foreach ($c in (Get-PiCandidatePaths -RuntimeEnvPath $RuntimeEnvPath)) {
      if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
  } catch { return $null }
}
function Resolve-NodeRuntime {
  try {
    $n = Resolve-ToolPath "node"
    if ($null -eq $n) { return $null }
    $v = & $n -p "process.versions.node" 2>$null
    if (Test-AtLeastNode22 -VersionString $v) { return $n }
    return $null
  } catch { return $null }
}
<#
.SYNOPSIS
  Fail-closed syntax gate for JS runtime entrypoints (Bug: v0.2.6 shipped
  pi-daemon.mjs with a try-without-catch because nothing ran node --check
  on it).
.DESCRIPTION
  Runs `node --check` on every file (exit 0 required). Missing node, missing
  files, or any parse failure returns Ok=$false with actionable Failures.
  Never throws. Used by New-Release.ps1 (pre-ZIP), installer step 6
  (pre-task) and CI/smoke tests — single source of truth.
#>
function Test-RuntimeSyntax {
  param([string]$NodeExe = "", [string[]]$Files = @())
  $fails = @()
  try {
    $node = $NodeExe
    if ([string]::IsNullOrWhiteSpace($node)) {
      $c = Get-Command node -ErrorAction SilentlyContinue
      if ($null -ne $c) { $node = $c.Source }
    }
    if ([string]::IsNullOrWhiteSpace($node) -or (-not (Test-Path -LiteralPath $node))) {
      return @{ Ok = $false; Failures = @("node non disponibile per --check") }
    }
    if ($Files.Count -eq 0) { return @{ Ok = $false; Failures = @("nessun file da validare") } }
    foreach ($f in $Files) {
      if ([string]::IsNullOrWhiteSpace($f) -or (-not (Test-Path -LiteralPath $f))) {
        $fails += "file mancante: $f"
        continue
      }
      try {
        & $node --check $f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $fails += "syntax check fallito (exit $LASTEXITCODE): $f" }
      } catch {
        $fails += "syntax check errore ($($_.Exception.Message)): $f"
      }
    }
  } catch {
    $fails += "validazione interrotta: $($_.Exception.Message)"
  }
  return @{ Ok = ($fails.Count -eq 0); Failures = $fails }
}
function Resolve-RemotePort {
  param([string]$AgentDir = "")
  try {
    if ([string]::IsNullOrWhiteSpace($AgentDir)) { return "43128" }
    $cf = Join-Path $AgentDir "remote-server.json"
    if (-not (Test-Path -LiteralPath $cf)) { return "43128" }
    $port = ([string](Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json).port)
    if (Test-ValidPort $port) { return $port.Trim() }
    return "43128"
  } catch { return "43128" }
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
      # Promote task launchers to app ROOT before the swap (runtime contract:
      # launchers resolve runtime-env.json/logs from their own directory, and
      # Task Scheduler actions point at app root). Validated below: a failed
      # promotion aborts BEFORE the swap, live app untouched.
      foreach ($pair in @(@("installer\run-task.ps1", "run-task.ps1"), @("installer\run-remote.ps1", "run-remote.ps1"))) {
        $lSrc = Join-Path $stage $pair[0]
        if (-not (Test-Path -LiteralPath $lSrc)) { throw ("Launcher sorgente mancante nello stage: " + $pair[0]) }
        Copy-Item -LiteralPath $lSrc -Destination (Join-Path $stage $pair[1]) -Force -ErrorAction Stop
      }
      $stMan = Test-ReleaseManifest -PayloadRoot $stage -Manifest $script:AppManifest
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
  Validate a Telegram ServerBot token via getMe, classifying failures.
.DESCRIPTION
  Returns @{ Ok, Kind, Message, BotId, BotUsername, Transient }. Never logs
  the token or the full URL. -UseBasicParsing bypasses the IE engine on
  PS 5.1 (a whole failure class on fresh Windows). -Invoker injects a fake
  HTTP call for tests: scriptblock param($url, $timeoutSec).
  Kind: ok | empty | invalid-token | malformed | dns | timeout | tls |
  connection | server-busy | api-error | ie-engine | unknown.
#>
function Test-TelegramBotToken {
  param([string]$Token, [int]$TimeoutSec = 20, [scriptblock]$Invoker = $null)
  if ([string]::IsNullOrWhiteSpace($Token)) {
    return @{ Ok = $false; Kind = "empty"; Message = "Token vuoto."; BotId = ""; BotUsername = ""; Transient = $false }
  }
  $url = ("https://api.telegram.org/bot" + $Token.Trim() + "/getMe")
  try {
    if ($null -ne $Invoker) { $me = & $Invoker $url $TimeoutSec }
    else { $me = Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing }
  } catch {
    $facts = Get-TelegramFailureFacts -Exception $_
    $c = Classify-TelegramFailure -StatusCode $facts.StatusCode -WebStatus $facts.WebStatus -Message $facts.Message
    return @{ Ok = $false; Kind = $c.Kind; Message = $c.Message; BotId = ""; BotUsername = ""; Transient = $c.Transient }
  }
  return Test-TelegramGetMeResponse -Response $me
}

<#
.SYNOPSIS
  Pure shape check of a getMe response. No network, never throws.
#>
function Test-TelegramGetMeResponse {
  param($Response)
  try {
    if ($null -eq $Response -or $Response.ok -ne $true) {
      return @{ Ok = $false; Kind = "api-error"; Message = "Telegram ha risposto ok=false."; BotId = ""; BotUsername = ""; Transient = $false }
    }
    $id = ""; $un = ""
    try { $id = [string]$Response.result.id } catch { }
    try { $un = [string]$Response.result.username } catch { }
    if ($id -notmatch "^\d+$") {
      return @{ Ok = $false; Kind = "malformed"; Message = "Risposta getMe inattesa (id mancante)."; BotId = ""; BotUsername = ""; Transient = $false }
    }
    return @{ Ok = $true; Kind = "ok"; Message = "OK"; BotId = $id; BotUsername = $un; Transient = $false }
  } catch {
    return @{ Ok = $false; Kind = "malformed"; Message = "Risposta getMe inattesa."; BotId = ""; BotUsername = ""; Transient = $false }
  }
}

<#
.SYNOPSIS
  Extract network facts from a failed web call. Pure, never throws.
.DESCRIPTION
  Handles PS 5.1 WebException (.Response.StatusCode + .Status) and PS 7
  HttpResponseException (.StatusCode). Returns @{ StatusCode=[int];
  WebStatus=[string]; Message=[string] }. Message never contains the token:
  .NET web exceptions carry status text, not the request URL.
#>
function Get-TelegramFailureFacts {
  param($Exception)
  $code = 0; $ws = ""; $msg = ""
  try {
    $ex = $Exception
    # NOTE: do NOT probe $Exception.Exception directly: under Set-StrictMode 2.0
    # a missing property throws. -is is strict-safe.
    if (($ex -is [System.Management.Automation.ErrorRecord]) -and ($null -ne $ex.Exception)) { $ex = $ex.Exception }
    try { $msg = [string]$ex.Message } catch { }
    try {
      if ($null -ne $ex.Response -and $null -ne $ex.Response.StatusCode) {
        $code = [int]$ex.Response.StatusCode.value__
      } elseif ($null -ne $ex.StatusCode) {
        $code = [int]$ex.StatusCode.value__
      }
    } catch { }
    try {
      if ($null -ne $ex.Status) { $ws = [string]$ex.Status }
    } catch { }
  } catch { }
  return @{ StatusCode = $code; WebStatus = $ws; Message = $msg }
}

<#
.SYNOPSIS
  Classify a Telegram failure into Kind + Transient. Pure, never throws.
#>
function Classify-TelegramFailure {
  param([int]$StatusCode = 0, [string]$WebStatus = "", [string]$Message = "")
  if ($StatusCode -eq 401 -or $StatusCode -eq 403) {
    return @{ Kind = "invalid-token"; Transient = $false; Message = "Token rifiutato da Telegram (HTTP $StatusCode): revoca o rigenera via BotFather." }
  }
  if ($StatusCode -eq 404) {
    return @{ Kind = "malformed"; Transient = $false; Message = "Endpoint non trovato (HTTP 404): token malformato." }
  }
  if ($StatusCode -eq 429) {
    return @{ Kind = "server-busy"; Transient = $true; Message = "Telegram rate-limit (HTTP 429): riprovo." }
  }
  if ($StatusCode -ge 500 -and $StatusCode -le 599) {
    return @{ Kind = "server-busy"; Transient = $true; Message = "Telegram non disponibile (HTTP $StatusCode): riprovo." }
  }
  if ($StatusCode -ge 400 -and $StatusCode -lt 500) {
    return @{ Kind = "api-error"; Transient = $false; Message = "Errore API Telegram (HTTP $StatusCode)." }
  }
  # PS 5.1 WebException text often carries the code when .Response is gone.
  if ($Message -match "\((401|403)\)") {
    return @{ Kind = "invalid-token"; Transient = $false; Message = "Token rifiutato da Telegram (HTTP $($Matches[1])): revoca o rigenera via BotFather." }
  }
  if ($Message -match "\(404\)") {
    return @{ Kind = "malformed"; Transient = $false; Message = "Endpoint non trovato (HTTP 404): token malformato." }
  }
  if ($Message -match "\((429|5\d\d)\)") {
    return @{ Kind = "server-busy"; Transient = $true; Message = "Telegram non disponibile (HTTP $($Matches[1])): riprovo." }
  }
  $wl = $WebStatus.ToLowerInvariant()
  if ($wl -eq "nameresolutionfailure" -or $Message -match "could not be resolved|No such host|nome remoto|DNS") {
    return @{ Kind = "dns"; Transient = $true; Message = "api.telegram.org non risolvibile (DNS/rete locale)." }
  }
  if ($wl -eq "timeout" -or $Message -match "timed out|timeout|scaduto") {
    return @{ Kind = "timeout"; Transient = $true; Message = "Timeout verso api.telegram.org (rete lenta o proxy)." }
  }
  if ($wl -eq "securechannelfailure" -or $wl -eq "trustfailure" -or $Message -match "SSL/TLS|secure channel|TLS|certificat") {
    return @{ Kind = "tls"; Transient = $false; Message = "Errore TLS/certificato verso api.telegram.org." }
  }
  if ($wl -match "^(connectfailure|connectionclosed|keepalivefailure|sendfailure|receivefailure|pipelinefailure)$" -or $Message -match "Unable to connect|connessione|refused|reset|forcibly closed|impossibile connettersi") {
    return @{ Kind = "connection"; Transient = $true; Message = "Connessione a api.telegram.org fallita (rete/proxy/firewall)." }
  }
  if ($Message -match "Internet Explorer engine|first-launch|UseBasicParsing") {
    return @{ Kind = "ie-engine"; Transient = $false; Message = "Motore IE non disponibile (usa -UseBasicParsing)." }
  }
  return @{ Kind = "unknown"; Transient = $false; Message = "Errore imprevisto: $Message" }
}

<#
.SYNOPSIS
  Persistent install checkpoint. Atomic writes, crash-safe reads.
.DESCRIPTION
  State shape: @{ schemaVersion=1; targetRelease; completedSteps=[ ];
  skippedSteps=[ ]; currentStep; lastSuccessfulStep; lastErrorKind; updatedAt }.
  NEVER stores secrets: Write-InstallState strips botToken/hmac/authkey-ish
  keys defensively. Corrupt file -> backup + blank state (never abort).
  Old schemaVersion -> blank state + Notice (rebuild by real verification).
#>
function Read-InstallState {
  param([string]$Path)
  $blank = @{ schemaVersion = 1; targetRelease = ""; completedSteps = @(); skippedSteps = @(); currentStep = ""; lastSuccessfulStep = ""; lastErrorKind = ""; updatedAt = "" }
  if ([string]::IsNullOrWhiteSpace($Path) -or (-not (Test-Path -LiteralPath $Path))) {
    return @{ Ok = $true; State = $blank; Corrupt = $false; Notice = "" }
  }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $j = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $j -or $j.schemaVersion -ne 1) {
      return @{ Ok = $true; State = $blank; Corrupt = $false; Notice = "Schema checkpoint non riconosciuto: ricostruisco con verifica reale." }
    }
    $st = @{ schemaVersion = 1; targetRelease = [string]$j.targetRelease; completedSteps = @(); skippedSteps = @(); currentStep = [string]$j.currentStep; lastSuccessfulStep = [string]$j.lastSuccessfulStep; lastErrorKind = [string]$j.lastErrorKind; updatedAt = [string]$j.updatedAt }
    foreach ($s in @($j.completedSteps)) { if (-not [string]::IsNullOrWhiteSpace($s)) { $st.completedSteps += [string]$s } }
    foreach ($s in @($j.skippedSteps)) { if (-not [string]::IsNullOrWhiteSpace($s)) { $st.skippedSteps += [string]$s } }
    return @{ Ok = $true; State = $st; Corrupt = $false; Notice = "" }
  } catch {
    $bak = "$Path.corrupt-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    try { Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop } catch { $bak = "" }
    return @{ Ok = $true; State = $blank; Corrupt = $true; Notice = "Checkpoint corrotto (backup: $bak): ricostruisco con verifica reale." }
  }
}
function Write-InstallState {
  param([string]$Path, $State)
  try {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $d = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($d) -and (-not (Test-Path -LiteralPath $d))) {
      New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
    }
    $clean = @{}
    foreach ($k in @($State.Keys)) {
      if ($k -match "(?i)token|hmac|secret|authkey|password|passwd|pwd") { continue }
      $clean[$k] = $State[$k]
    }
    $clean["updatedAt"] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $tmp = "$Path.tmp-" + [Guid]::NewGuid().ToString("N")
    ($clean | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $tmp -Encoding utf8 -NoNewline -ErrorAction Stop
    Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    return $true
  } catch { return $false }
}

<#
.SYNOPSIS
  Verify a step against the REAL machine. Never throws; $false = rerun.
.DESCRIPTION
  The machine is the source of truth: a checkpoint claiming 'done' is
  trusted only when the matching real check passes. -PiBin needed for
  the health step. sleep always reruns (instant + idempotent).
#>
<#
.SYNOPSIS
  Deep validation of one managed scheduled task (Bug 4: existence is not enough).
.DESCRIPTION
  A tasks step is OK only if the task exists AND its single action runs
  powershell.exe -File "<ExpectedFile>" (exact quoted launcher, which must
  exist), the working directory matches, the principal is SYSTEM, and no
  legacy/stale extra actions are present. -TaskReader injects
  param($TaskName) -> task object for tests. Never throws.
#>
function Test-TaskDefinition {
  param([string]$TaskName, [string]$ExpectedFile, [string]$ExpectedWorkDir, [scriptblock]$TaskReader = $null)
  try {
    if ([string]::IsNullOrWhiteSpace($TaskName) -or [string]::IsNullOrWhiteSpace($ExpectedFile)) { return $false }
    if (-not (Test-Path -LiteralPath $ExpectedFile)) { return $false }
    $t = $null
    if ($null -ne $TaskReader) { $t = & $TaskReader $TaskName }
    else { $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    if ($null -eq $t) { return $false }
    $acts = @()
    try { $acts = @($t.Actions) } catch { return $false }
    if ($acts.Count -ne 1) { return $false }
    if ([string]$acts[0].Execute -ne "powershell.exe") { return $false }
    if (-not ([string]$acts[0].Arguments).Contains('"' + $ExpectedFile + '"')) { return $false }
    if ([string]$acts[0].WorkingDirectory -ne $ExpectedWorkDir) { return $false }
    $uid = ""
    try { $uid = [string]$t.Principal.UserId } catch { return $false }
    if ($uid -ne "SYSTEM") { return $false }
    return $true
  } catch { return $false }
}

function Test-StepRealState {
  param([string]$Step, $Paths, [string]$PiBin = "", [scriptblock]$AuthRunner = $null, [string]$ExpectedRelease = "", [scriptblock]$TaskReader = $null)
  try {
    switch ($Step) {
      "windows" { return (Test-WindowsOS) }
      "node" {
        $n = Resolve-ToolPath "node"
        if ($null -eq $n) { return $false }
        $v = & $n -p "process.versions.node" 2>$null
        return (Test-AtLeastNode22 -VersionString $v)
      }
      "pi" {
        $p = Resolve-ToolPath "pi"
        if ($null -eq $p) { return $false }
        & $p --version 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
      }
      "pi-telegram" {
        $p = Resolve-ToolPath "pi"
        if ($null -eq $p) { return $false }
        $l = (& $p list 2>$null | Out-String)
        return ($l -match "pi-telegram")
      }
      "tailscale" {
        $ip = Get-TailscaleIpv4
        return (-not [string]::IsNullOrWhiteSpace($ip))
      }
      "deploy" {
        if ($null -eq $Paths -or (-not (Test-Path -LiteralPath $Paths.App))) { return $false }
        $m = Test-ReleaseManifest -PayloadRoot $Paths.App -Manifest $script:AppManifest
        if (-not $m.Ok) { return $false }
        $vf = Join-Path $Paths.App "VERSION"
        if (-not (Test-Path -LiteralPath $vf)) { return $false }
        $haveVer = ((Get-Content -LiteralPath $vf -Raw).Trim())
        if ($haveVer.Length -eq 0) { return $false }
        if (($ExpectedRelease -ne "") -and ($ExpectedRelease -ne "latest") -and ($haveVer -ne $ExpectedRelease)) { return $false }
        return $true
      }
      "config" {
        if ($null -eq $Paths) { return $false }
        $cf = Join-Path $Paths.AgentDir "remote-server.json"
        if (-not (Test-Path -LiteralPath $cf)) { return $false }
        $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json
        return (Test-ValidPort $c.port)
      }
      "secrets" {
        if ($null -eq $Paths) { return $false }
        $tf = Join-Path $Paths.SecretsDir "server-bot-token"
        $hf = Join-Path $Paths.SecretsDir "remote-hmac"
        foreach ($f in @($tf, $hf)) {
          if (-not (Test-Path -LiteralPath $f)) { return $false }
          if (((Get-Content -LiteralPath $f -Raw).Trim().Length) -eq 0) { return $false }
        }
        $tj = Join-Path $Paths.AgentDir "telegram.json"
        if (-not (Test-Path -LiteralPath $tj)) { return $false }
        $t = Get-Content -LiteralPath $tj -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($t.profiles.default.botToken)) { return $false }
        if (-not (Test-ValidOwnerId $t.profiles.default.allowedUserId)) { return $false }
        $pb2 = $PiBin
        if ([string]::IsNullOrWhiteSpace($pb2)) { $pb2 = Resolve-ToolPath "pi" }
        if ([string]::IsNullOrWhiteSpace($pb2)) { return $false }
        $authReal = $null
        if ($null -ne $AuthRunner) { $authReal = Test-PiAuthentication -PiExe $pb2 -AgentDir $Paths.AgentDir -Runner $AuthRunner }
        else { $authReal = Test-PiAuthentication -PiExe $pb2 -AgentDir $Paths.AgentDir }
        return ([bool]$authReal.Authenticated)
      }
      "tasks" {
        if ($env:OS -ne "Windows_NT") { return $false }
        if ($null -eq $Paths) { return $false }
        $wdMain = Split-Path -Parent $Paths.Daemon
        $wdRemote = Split-Path -Parent $Paths.RemoteEntry
        if (-not (Test-TaskDefinition -TaskName $Paths.TaskName -ExpectedFile $Paths.RunTask -ExpectedWorkDir $wdMain -TaskReader $TaskReader)) { return $false }
        return (Test-TaskDefinition -TaskName $Paths.RemoteTaskName -ExpectedFile $Paths.RunRemote -ExpectedWorkDir $wdRemote -TaskReader $TaskReader)
      }
      "sleep" { return $false }
      "health" {
        if ($null -eq $Paths) { return $false }
        $pb = $PiBin
        if ([string]::IsNullOrWhiteSpace($pb)) { $pb = Resolve-ToolPath "pi" }
        $h = Invoke-HealthCheck -Paths $Paths -PiBin $pb
        return ($h.Ok)
      }
    }
    return $false
  } catch { return $false }
}

<#
.SYNOPSIS
  Pure input validators. Never throw; return [bool].
#>
function Test-ValidPort {
  param($Value)
  try {
    $s = ([string]$Value).Trim()
    if ($s -notmatch "^\d{1,5}$") { return $false }
    $n = [int]$s
    return ($n -ge 1 -and $n -le 65535)
  } catch { return $false }
}
function Test-ValidOwnerId {
  param($Value)
  try { return (([string]$Value).Trim() -match "^[1-9]\d*$") } catch { return $false }
}
function Test-ValidTokenFormat {
  param($Value)
  try { return (([string]$Value).Trim() -match "^\d+:[A-Za-z0-9_-]{20,}$") } catch { return $false }
}
function Test-ValidHmac {
  param($Value)
  try {
    $s = [string]$Value
    if ($s.Length -lt 16) { return $false }
    if ($s -match "\s") { return $false }
    return ($s -match "^[\x20-\x7E]+$")
  } catch { return $false }
}

<#
.SYNOPSIS
  Prompt loop that never exits the process on bad input.
.DESCRIPTION
  -Validate is scriptblock param($value)->[bool]. -ReadFunc injects a fake
  reader for tests: scriptblock param($prompt)->[string]. Empty input
  returns -Default when set, otherwise reprompts. Returns the valid string.
#>
function Read-Validated {
  param([string]$Prompt, [scriptblock]$Validate, [string]$InvalidMessage = "Valore non valido. Riprova.", [string]$Default = $null, [scriptblock]$ReadFunc = $null)
  while ($true) {
    if ($null -ne $ReadFunc) { $v = & $ReadFunc $Prompt }
    else { $v = Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($v) -and $null -ne $Default) { return $Default }
    $ok = $false
    try { $ok = & $Validate $v } catch { $ok = $false }
    if ($ok) { return $v }
    Write-Host $InvalidMessage -ForegroundColor Yellow
  }
}
function Read-ValidatedPort {
  param([string]$Prompt = "Remote API port [43128]", [string]$Default = "43128", [scriptblock]$ReadFunc = $null)
  return Read-Validated -Prompt $Prompt -Validate { param($x) Test-ValidPort $x } -InvalidMessage "Porta non valida. Inserisci un numero tra 1 e 65535." -Default $Default -ReadFunc $ReadFunc
}
function Read-ValidatedOwnerId {
  param([string]$Prompt = "Owner Telegram user id (numerico, da @userinfobot)", [string]$Default = $null, [scriptblock]$ReadFunc = $null)
  return Read-Validated -Prompt $Prompt -Validate { param($x) Test-ValidOwnerId $x } -InvalidMessage "ID non valido. Deve essere numerico (solo cifre, non zero)." -Default $Default -ReadFunc $ReadFunc
}
function Read-ValidatedYesNo {
  param([string]$Prompt, [string]$Default = "Y", [scriptblock]$ReadFunc = $null)
  while ($true) {
    if ($null -ne $ReadFunc) { $a = & $ReadFunc "$Prompt" }
    else { $a = Read-Host "$Prompt" }
    $t = ([string]$a).Trim().ToLowerInvariant()
    if ($t -eq "" ) { $t = $Default.Trim().ToLowerInvariant() }
    if ($t -eq "y" -or $t -eq "yes" -or $t -eq "s" -or $t -eq "si") { return $true }
    if ($t -eq "n" -or $t -eq "no") { return $false }
    Write-Host "Risposta non valida: digita Y (si) o N (no)." -ForegroundColor Yellow
  }
}
function Read-ValidatedHmac {
  param([string]$Prompt = "HMAC secret [INVIO = genera automaticamente] (nascosto)", [scriptblock]$ReadFunc = $null)
  while ($true) {
    if ($null -ne $ReadFunc) { $h = & $ReadFunc $Prompt }
    else { $h = Read-HiddenInput -Prompt $Prompt }
    if ([string]::IsNullOrWhiteSpace($h)) { return @{ Secret = (New-RandomHex -Bytes 32); Generated = $true } }
    if (Test-ValidHmac $h) { return @{ Secret = [string]$h; Generated = $false } }
    Write-Host "HMAC non valido: minimo 16 caratteri stampabili, senza spazi. Riprova (INVIO = genera)." -ForegroundColor Yellow
  }
}
function Read-ValidatedHidden {
  param([string]$Prompt, [scriptblock]$Validate, [string]$InvalidMessage = "Valore non valido. Riprova.", [scriptblock]$ReadFunc = $null)
  while ($true) {
    if ($null -ne $ReadFunc) { $v = & $ReadFunc $Prompt }
    else { $v = Read-HiddenInput -Prompt $Prompt }
    $ok = $false
    try { $ok = & $Validate $v } catch { $ok = $false }
    if ($ok) { return $v }
    Write-Host $InvalidMessage -ForegroundColor Yellow
  }
}

<#
.SYNOPSIS
  Step error taxonomy: New-StepError tags, Split-StepError reads.
.DESCRIPTION
  Bodies throw (New-StepError 'Transient'|'System'|'Fatal' 'msg').
  Split-StepError returns @{ Kind; Text }, defaulting Kind to System for
  raw .NET exceptions. Classify-SystemException maps raw network errors
  to Transient kinds (timeout/dns/connection) so plain cmdlet throws
  also retry instead of killing the setup.
#>
function New-StepError {
  param([string]$Kind, [string]$Message)
  return "[StepError:$Kind] $Message"
}
function Split-StepError {
  param([string]$Message)
  $m = [regex]::Match([string]$Message, "^\[StepError:(Transient|System|Fatal|UserInput)\]\s?(.*)$", "Singleline")
  if ($m.Success) { return @{ Kind = $m.Groups[1].Value; Text = $m.Groups[2].Value } }
  $c = Classify-SystemException -Message ([string]$Message)
  return @{ Kind = $c.Kind; Text = ([string]$Message) }
}
function Classify-SystemException {
  param([string]$Message = "")
  $t = [string]$Message
  if ($t -match "timed out|timeout|TimeoutSec|scaduto") { return @{ Kind = "Transient"; Note = "timeout" } }
  if ($t -match "could not be resolved|No such host|nome remoto|DNS|NameResolution") { return @{ Kind = "Transient"; Note = "dns" } }
  if ($t -match "Unable to connect|connessione|refused|reset|forcibly closed|impossibile connettersi|ConnectFailure|404.*tailscale|not connected|non connesso") { return @{ Kind = "Transient"; Note = "connection" } }
  if ($t -match "checksum|Checksum|manifest|Manifest|corrupt|integrity|hmac-once|inconsistente") { return @{ Kind = "Fatal"; Note = "integrity" } }
  return @{ Kind = "System"; Note = "" }
}

<#
.SYNOPSIS
  Retry delay schedule 2/4/8s. Pure, tested. Capped at 30s.
#>
function Get-RetryDelaySec {
  param([int]$Attempt = 1, [int]$BaseDelaySec = 2)
  try {
    if ($Attempt -lt 1) { $Attempt = 1 }
    $d = $BaseDelaySec
    for ($i = 1; $i -lt $Attempt; $i++) { $d = $d * 2 }
    if ($d -gt 30) { $d = 30 }
    return $d
  } catch { return $BaseDelaySec }
}

<#
.SYNOPSIS
  Generic retry engine. Pure side-effect-free apart from Action/Sleep.
.DESCRIPTION
  -Action: scriptblock returning a value or throwing. -IsTransient:
  scriptblock param($exception)->[bool]. Sleeps BaseDelaySec*2^(n-1)
  between attempts (0 in tests). Returns @{ Ok; Value; Attempts; Error }.
  Never throws.
#>
function Invoke-WithRetry {
  param([scriptblock]$Action, [scriptblock]$IsTransient, [int]$MaxAttempts = 3, [int]$BaseDelaySec = 2)
  $res = @{ Ok = $false; Value = $null; Attempts = 0; Error = "" }
  try {
    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    for ($n = 1; $n -le $MaxAttempts; $n++) {
      $res.Attempts = $n
      try {
        $res.Value = & $Action
        $res.Ok = $true
        return $res
      } catch {
        $transient = $false
        try { $transient = & $IsTransient $_ } catch { $transient = $false }
        $res.Error = $_.Exception.Message
        if (-not $transient -or $n -ge $MaxAttempts) { return $res }
        Start-Sleep -Seconds (Get-RetryDelaySec -Attempt $n -BaseDelaySec $BaseDelaySec)
      }
    }
    return $res
  } catch {
    $res.Error = $_.Exception.Message
    return $res
  }
}

<#
.SYNOPSIS
  Decide the next action after a step failure. Pure, tested.
.DESCRIPTION
  Returns 'retry' | 'menu' | 'fail'. Transient auto-retries while
  Attempt < MaxAttempts, then menu. System always menus. Fatal (integrity)
  never retries: checkpoint + exit. UserInput never reaches here (loops).
#>
function Resolve-StepAction {
  param([string]$Kind, [int]$Attempt = 1, [int]$MaxAttempts = 3)
  if ($Kind -eq "Fatal") { return "fail" }
  if ($Kind -eq "Transient" -and $Attempt -lt $MaxAttempts) { return "retry" }
  return "menu"
}

<#
.SYNOPSIS
  Interactive step menu. Returns 'retry' | 'skip' | 'exit'.
.DESCRIPTION
  -ReadFunc injects a fake reader for tests: scriptblock -> [string].
  Default is R. -AllowSkip:$false hides S (security-critical steps).
  D prints details then re-loops. Never throws.
#>
function Show-StepMenu {
  param([string]$StepLabel, [string]$Title, [string]$ErrorMessage, [string]$Details = "", [switch]$AllowSkip, [scriptblock]$ReadFunc = $null, [string]$Default = "R")
  $opts = "[R]iprova / [D]ettagli / [E]sci e riprendi dopo"
  if ($AllowSkip) { $opts = "[R]iprova / [S]alta se sicuro / [D]ettagli / [E]sci e riprendi dopo" }
  while ($true) {
    Write-Host ""
    Write-Host "------------------------------------------------" -ForegroundColor Red
    Write-Host ("Errore nello step " + $StepLabel + " - " + $Title) -ForegroundColor Red
    Write-Host "------------------------------------------------" -ForegroundColor Red
    Write-Host $ErrorMessage -ForegroundColor Yellow
    Write-Host "Il tuo progresso NON e perso (checkpoint salvato)."
    if ($null -ne $ReadFunc) { $a = & $ReadFunc $opts }
    else { $a = Read-Host "$opts [$Default]" }
    $t = ([string]$a).Trim().ToLowerInvariant()
    if ($t -eq "") { $t = $Default.Trim().ToLowerInvariant() }
    if ($t -eq "r" -or $t -eq "riprova") { return "retry" }
    if ($AllowSkip -and ($t -eq "s" -or $t -eq "salta")) { return "skip" }
    if ($t -eq "e" -or $t -eq "esci") { return "exit" }
    if ($t -eq "d" -or $t -eq "dettagli") {
      if ($Details -ne "") { Write-Host $Details } else { Write-Host "(nessun dettaglio aggiuntivo)" }
    } else {
      Write-Host "Scelta non valida: R, D, E." -ForegroundColor Yellow
    }
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
  Crash-safe text write: tmp + flush + rename. Never throws (bool).
.DESCRIPTION
  A killed process can only leave the old file (intact) or a tmp file
  (ignored); never a half-written target. -Encoding ascii|utf8.
#>
function Write-AtomicTextFile {
  param([string]$Path, [string]$Content, [string]$Encoding = "ascii")
  try {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($null -eq $Content) { $Content = "" }
    $d = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($d) -and (-not (Test-Path -LiteralPath $d))) {
      New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
    }
    $tmp = "$Path.tmp-" + [Guid]::NewGuid().ToString("N")
    if ($Encoding -eq "utf8") { $Content | Out-File -LiteralPath $tmp -Encoding utf8 -NoNewline -ErrorAction Stop }
    else { $Content | Out-File -LiteralPath $tmp -Encoding ascii -NoNewline -ErrorAction Stop }
    Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    return $true
  } catch { return $false }
}
<#
.SYNOPSIS
  Post-install health check. Fail closed: returns @{ Ok, Failures }.
.DESCRIPTION
  Never throws: every probe is guarded so a broken environment yields
  Failures entries instead of an exception. On non-Windows the Task
  Scheduler probes report failure (honest: the runtime needs Windows).
#>
<#
.SYNOPSIS
  Null-safe CommandLine regex match for Win32_Process objects.
.DESCRIPTION
  $_.CommandLine is $null for SYSTEM/idle processes; matching the CIM object
  itself (instead of .CommandLine) never matches. Returns $false on $null.
#>
function Test-CommandLineMatch {
  param($Process, [string]$Pattern)
  try {
    if ($null -eq $Process) { return $false }
    $cl = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($cl)) { return $false }
    return ($cl -match $Pattern)
  } catch { return $false }
}

<#
.SYNOPSIS
  Last sanitized lines of a log file (secrets never surface).
.DESCRIPTION
  Returns up to MaxLines tail lines joined by ' | ', each truncated to
  MaxChars, with bot-token and HMAC/bearer-like secrets redacted.
  Returns '' when missing/empty/unreadable. Never throws.
#>
function Get-SanitizedLogTail {
  param([string]$Path, [int]$MaxLines = 5, [int]$MaxChars = 200)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $lines = Get-Content -LiteralPath $Path -Tail $MaxLines -ErrorAction Stop
    if ($null -eq $lines) { return "" }
    $out = @()
    foreach ($ln in @($lines)) {
      $s = [string]$ln
      $s = $s -replace 'bot\d+:[A-Za-z0-9_-]{20,}', 'bot<redacted>'
      $s = $s -replace '(?i)(hmac|signature|bearer|authorization|bot[_-]?token|api[_-]?key)\s*[:=]\s*\S+', '$1=<redacted>'
      if ($s.Length -gt $MaxChars) { $s = $s.Substring(0, $MaxChars) + "..." }
      $out += $s.Trim()
    }
    return ($out -join " | ")
  } catch { return "" }
}

<#
.SYNOPSIS
  Per-task health diagnostics: empty when healthy, actionable failures otherwise.
.DESCRIPTION
  Checks action contract (single powershell.exe action pointing at the exact
  quoted launcher, which must exist), log presence/freshness, crash-loop
  signatures and process presence. When anything fails, appends a context line
  (State/LastTaskResult/action/launcher) plus a sanitized stderr tail.
  $TaskInfo/$Processes inject live objects for tests (avoids Windows-only
  cmdlets off-Windows). Never throws.
#>
function Format-TaskDiagnostics {
  param($Task, [string]$TaskName, [string]$ExpectedFile, [string]$LogPath, [string]$ProcessPattern, [string]$ErrLogPath = "", $TaskInfo = $null, $Processes = $null)
  $fails = @()
  try {
    $acts = @()
    try { $acts = @($Task.Actions) } catch { }
    if ($acts.Count -ne 1) {
      $fails += "${TaskName}: action count=$($acts.Count) (attesa 1: possibile action legacy/stale)"
    } else {
      if ([string]$acts[0].Execute -ne "powershell.exe") { $fails += "${TaskName}: action Execute='$($acts[0].Execute)' (atteso powershell.exe)" }
      if (-not ([string]$acts[0].Arguments).Contains('"' + $ExpectedFile + '"')) { $fails += "${TaskName}: action non punta al launcher atteso ($ExpectedFile)" }
    }
    if (-not (Test-Path -LiteralPath $ExpectedFile)) { $fails += "${TaskName}: launcher mancante: $ExpectedFile" }
    if (-not (Test-Path -LiteralPath $LogPath)) {
      $fails += "${TaskName}: log assente (task mai partita?): $LogPath"
    } else {
      try {
        $age = (Get-Date) - (Get-Item -LiteralPath $LogPath).LastWriteTime
        if ($age.TotalMinutes -gt 15) { $fails += "${TaskName}: log fermo da $([int]$age.TotalMinutes) min: $LogPath" }
      } catch { }
      try {
        $tail = Get-Content -LiteralPath $LogPath -Tail 30 -ErrorAction Stop
        if ($null -ne $tail) {
          $crashes = @($tail | Where-Object { $_ -match "pi exited unexpectedly|spawn failed|uncaught" }).Count
          if ($crashes -gt 3) { $fails += "${TaskName}: crash loop nel log ($crashes/30 righe)" }
        }
      } catch { }
    }
    $found = $false
    if ($null -ne $Processes) {
      foreach ($p in @($Processes)) { if (Test-CommandLineMatch -Process $p -Pattern $ProcessPattern) { $found = $true; break } }
    }
    if (-not $found) { $fails += "${TaskName}: processo assente (pattern $ProcessPattern)" }
    if ($fails.Count -gt 0) {
      $state = ""
      $lrc = ""
      $exec = ""
      $argStr = ""
      try { $state = [string]$Task.State } catch { }
      try {
        if ($null -ne $TaskInfo) { $lrc = [string]$TaskInfo.LastTaskResult }
        else { $lrc = [string](Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop).LastTaskResult }
      } catch { }
      try { if ($acts.Count -ge 1) { $exec = [string]$acts[0].Execute; $argStr = [string]$acts[0].Arguments } } catch { }
      $lex = Test-Path -LiteralPath $ExpectedFile
      $fails += "${TaskName}: State=$state LastTaskResult=$lrc Execute=$exec Args=$argStr LauncherExists=$lex"
      if ((-not [string]::IsNullOrWhiteSpace($ErrLogPath)) -and (Test-Path -LiteralPath $ErrLogPath)) {
        $st = Get-SanitizedLogTail -Path $ErrLogPath -MaxLines 5
        if (-not [string]::IsNullOrWhiteSpace($st)) { $fails += "${TaskName}: stderr: $st" }
      }
    }
  } catch { $fails += "${TaskName}: diagnostica interrotta: $($_.Exception.Message)" }
  return $fails
}

<#
.SYNOPSIS
  Start a task and poll until its payload process is alive (fail fast on instant exit).
.DESCRIPTION
  Our launchers never exit on success, so State=Ready (or Disabled) with no
  matching process means the payload died immediately: returns fail WITHOUT
  waiting for the full timeout. Success = process CommandLine match found
  (log presence reported, not required). Returns @{ Ok; Detail } with a
  secret-free diagnostic block. -TaskReader/-TaskInfoReader/-ProcessProbe
  inject fakes for tests. Never throws.
#>
function Wait-TaskStartup {
  param([string]$TaskName, [string]$LauncherPath, [string]$ProcessMatch, [string]$LogPath, [int]$TimeoutSec = 20, [int]$EarlyExitSec = 6, [scriptblock]$TaskReader = $null, [scriptblock]$TaskInfoReader = $null, [scriptblock]$ProcessProbe = $null)
  try {
    $start = Get-Date
    $lastState = ""
    $lastRc = ""
    while ((((Get-Date) - $start).TotalSeconds) -lt $TimeoutSec) {
      $running = $false
      try {
        if ($null -ne $ProcessProbe) { $running = [bool](& $ProcessProbe) }
        else {
          $ps = Get-CimInstance Win32_Process -ErrorAction Stop
          foreach ($p in @($ps)) { if (Test-CommandLineMatch -Process $p -Pattern $ProcessMatch) { $running = $true; break } }
        }
      } catch { $running = $false }
      if ($running) {
        $logOk = Test-Path -LiteralPath $LogPath
        return @{ Ok = $true; Detail = "$TaskName avviato (processo presente, log presente=$logOk)" }
      }
      try {
        if ($null -ne $TaskReader) { $rt = & $TaskReader $TaskName; $lastState = [string]$rt.State }
        else { $lastState = [string](Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).State }
      } catch { }
      try {
        if ($null -ne $TaskInfoReader) { $ri = & $TaskInfoReader $TaskName; $lastRc = [string]$ri.LastTaskResult }
        else { $lastRc = [string](Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop).LastTaskResult }
      } catch { }
      $elapsed = ((Get-Date) - $start).TotalSeconds
      if (($lastState -eq "Disabled") -or (($elapsed -ge $EarlyExitSec) -and ($lastState -eq "Ready"))) { break }
      Start-Sleep -Seconds 2
    }
    $lex = Test-Path -LiteralPath $LauncherPath
    $logEx = Test-Path -LiteralPath $LogPath
    $logWord = "absent"
    if ($logEx) { $logWord = "present" }
    return @{ Ok = $false; Detail = "$TaskName startup failed | State: $lastState | LastTaskResult: $lastRc | Launcher: $LauncherPath | LauncherExists: $lex | Process: absent | Log: $logWord" }
  } catch {
    return @{ Ok = $false; Detail = "$TaskName startup check interrotto: $($_.Exception.Message)" }
  }
}

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
      $allProcs = @()
      try { $allProcs = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { $allProcs = @() }
      $t = Get-ScheduledTask -TaskName $Paths.TaskName -ErrorAction SilentlyContinue
      if ($null -eq $t) {
        $script:hcFail += "task $($Paths.TaskName) assente"
      } else {
        $ti = $null
        try { $ti = Get-ScheduledTaskInfo -TaskName $Paths.TaskName -ErrorAction Stop } catch { }
        foreach ($f in (Format-TaskDiagnostics -Task $t -TaskName $Paths.TaskName -ExpectedFile $Paths.RunTask -LogPath $Paths.ServerLog -ErrLogPath $Paths.ServerErrLog -ProcessPattern "pi-daemon\.mjs" -TaskInfo $ti -Processes $allProcs)) { $script:hcFail += $f }
      }
      $rt = Get-ScheduledTask -TaskName $Paths.RemoteTaskName -ErrorAction SilentlyContinue
      if ($null -eq $rt) {
        $script:hcFail += "task $($Paths.RemoteTaskName) assente"
      } else {
          $rti = $null
          try { $rti = Get-ScheduledTaskInfo -TaskName $Paths.RemoteTaskName -ErrorAction Stop } catch { }
          foreach ($f in (Format-TaskDiagnostics -Task $rt -TaskName $Paths.RemoteTaskName -ExpectedFile $Paths.RunRemote -LogPath $Paths.RemoteLog -ErrLogPath $Paths.RemoteErrLog -ProcessPattern "pi-remote-server" -TaskInfo $rti -Processes $allProcs)) { $script:hcFail += $f }
          $rp = Test-RemoteDaemon -Paths $Paths -TimeoutSec 10
          if (-not $rp.Ok) { $script:hcFail += "remote daemon: $($rp.Detail)" }
        }
      }
    if (-not [string]::IsNullOrWhiteSpace($PiBin)) {
      try {
        $authHc = Test-PiAuthentication -PiExe $PiBin -AgentDir $Paths.AgentDir
        if (-not $authHc.Authenticated) { $script:hcFail += "pi auth non valida ($($authHc.Reason))" }
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
<#
.SYNOPSIS
  Culture-invariant Unix timestamp (whole seconds, Int64).
.DESCRIPTION
  The Get-Date UFormat percent-s verb is culture-dependent (it-IT yields a comma
  decimal like '1789215834,20616', which breaks int casts and HMAC timestamps)
  and [int] overflows in 2038.
  This is the ONLY approved Unix-timestamp source for HMAC signing.
#>
function Get-UnixTimestampSeconds {
  return [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

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
    $ts = Get-UnixTimestampSeconds
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
  Verify REAL Pi authentication for one agent dir via the official CLI.
.DESCRIPTION
  Runs `<pi> auth check --provider <id> --json --no-refresh` for every
  provider key found in <AgentDir>\auth.json (contract verified on pi
  0.85.1: getAgentDir() honors PI_CODING_AGENT_DIR, auth lives in
  auth.json, bare `auth check` always fails, exit 0=ready 1=not_ready
  2=invalid). PI_CODING_AGENT_DIR is scoped to the child call only
  (saved/restored, never left behind). Returns
  @{ Authenticated=[bool]; Provider=""; SourcePath=""; Reason="" }.
  Only provider IDs (key names), status and reason ever surface: credential
  values are never read into output, logs, or errors. Never throws.
  -Runner injects a fake executor for tests: scriptblock
  param($PiExe, $ArgList, $AgentDir) -> @{ ExitCode=[int]; Stdout=[string] }.
#>
function Test-PiAuthentication {
  param([string]$PiExe, [string]$AgentDir, [scriptblock]$Runner = $null)
  if ([string]::IsNullOrWhiteSpace($PiExe) -or (-not (Test-Path -LiteralPath $PiExe))) {
    return @{ Authenticated = $false; Provider = ""; SourcePath = ""; Reason = "pi-not-found" }
  }
  if ([string]::IsNullOrWhiteSpace($AgentDir)) {
    return @{ Authenticated = $false; Provider = ""; SourcePath = ""; Reason = "no-agent-dir" }
  }
  $authPath = Join-Path $AgentDir "auth.json"
  if (-not (Test-Path -LiteralPath $authPath)) {
    return @{ Authenticated = $false; Provider = ""; SourcePath = $authPath; Reason = "no-auth-file" }
  }
  $providers = @()
  try {
    $raw = Get-Content -LiteralPath $authPath -Raw -ErrorAction Stop
    $data = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -ne $data -and ($data -is [System.Management.Automation.PSCustomObject])) {
      foreach ($prop in @($data.PSObject.Properties)) { $providers += [string]$prop.Name }
    }
  } catch {
    return @{ Authenticated = $false; Provider = ""; SourcePath = $authPath; Reason = "corrupt-auth-file" }
  }
  if ($providers.Count -eq 0) {
    return @{ Authenticated = $false; Provider = ""; SourcePath = $authPath; Reason = "no-providers" }
  }
  if ($null -eq $Runner) {
    $Runner = {
      param($Exe, $ArgList, $Dir)
      $hadOld = $false
      $old = $null
      try { $hadOld = Test-Path Env:\PI_CODING_AGENT_DIR; if ($hadOld) { $old = $env:PI_CODING_AGENT_DIR } } catch { }
      try {
        $env:PI_CODING_AGENT_DIR = $Dir
        $out = & $Exe @ArgList 2>&1 | Out-String
        $code = 900
        try { $code = [int]$LASTEXITCODE } catch { }
        return @{ ExitCode = $code; Stdout = [string]$out }
      } catch {
        return @{ ExitCode = 900; Stdout = "" }
      } finally {
        try {
          if ($hadOld) { $env:PI_CODING_AGENT_DIR = $old }
          else { Remove-Item Env:\PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue }
        } catch { }
      }
    }
  }
  $lastReason = "no-ready-provider"
  foreach ($prov in $providers) {
    $args = @("auth", "check", "--provider", $prov, "--json", "--no-refresh")
    try {
      $res = & $Runner $PiExe $args $AgentDir
    } catch {
      return @{ Authenticated = $false; Provider = ""; SourcePath = $authPath; Reason = "check-failed" }
    }
    $code = 900
    $status = ""
    $reason = ""
    try {
      if ($null -ne $res) {
        try { $code = [int]$res.ExitCode } catch { }
        $txt = ([string]$res.Stdout).Trim()
        if ($txt -ne "") {
          $lines = @($txt -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try {
              $j = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
              if ($null -ne $j -and $null -ne $j.status) {
                $status = [string]$j.status
                try { if ($null -ne $j.reason) { $reason = [string]$j.reason } } catch { }
                try { if ($null -ne $j.provider) { $prov = [string]$j.provider } } catch { }
                break
              }
            } catch { }
          }
        }
      }
    } catch { }
    if (($status -eq "ready") -and ($code -eq 0)) {
      return @{ Authenticated = $true; Provider = $prov; SourcePath = $authPath; Reason = "" }
    }
    if ($reason -ne "") { $lastReason = $prov + ": " + $reason }
    elseif ($status -ne "") { $lastReason = $prov + ": " + $status }
    else { $lastReason = $prov + ": check-failed" }
  }
  return @{ Authenticated = $false; Provider = ""; SourcePath = $authPath; Reason = $lastReason }
}

<#
.SYNOPSIS
  Check SYSTEM readability of an auth file via icacls. Windows-only.
.DESCRIPTION
  Returns @{ Ok=[bool]; Detail="" }. Non-Windows always returns Ok=$false
  (callers gate on OS; tests assert the shape, never fake-pass).
#>
function Test-AuthAcl {
  param([string]$Path)
  try {
    if ($env:OS -ne "Windows_NT") { return @{ Ok = $false; Detail = "non-windows" } }
    if ([string]::IsNullOrWhiteSpace($Path) -or (-not (Test-Path -LiteralPath $Path))) {
      return @{ Ok = $false; Detail = "missing" }
    }
    $acl = & icacls $Path 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($acl)) { return @{ Ok = $false; Detail = "icacls-empty" } }
    $rights = @()
    foreach ($m in @([regex]::Matches($acl, "SYSTEM:\(([^)]*)\)"))) { $rights += $m.Groups[1].Value }
    foreach ($r in $rights) {
      if ($r -match "F") { return @{ Ok = $true; Detail = "SYSTEM:F" } }
    }
    foreach ($r in $rights) {
      if ($r -match "R") { return @{ Ok = $true; Detail = "SYSTEM:R" } }
    }
    return @{ Ok = $false; Detail = "no-system-rights" }
  } catch { return @{ Ok = $false; Detail = "error" } }
}

<#
.SYNOPSIS
  Migrate a user auth.json into the server dir. Atomic, validated, ACL'd.
.DESCRIPTION
  Copies ONLY auth.json (never the whole profile dir): backs up any existing
  server file via Backup-File, copies through a temp file + Move-Item rename
  (same volume = atomic), preserves the original, then locks the copy to
  SYSTEM+Administrators on Windows. Never reads file contents into output:
  Detail carries only paths and status words. Returns
  @{ Ok=[bool]; Backup=""; Detail="" }. Never throws.
#>
function Copy-PiAuthToServerDir {
  param([string]$UserAuthPath, [string]$ServerAuthPath)
  try {
    if ([string]::IsNullOrWhiteSpace($UserAuthPath) -or (-not (Test-Path -LiteralPath $UserAuthPath))) {
      return @{ Ok = $false; Backup = ""; Detail = "user-missing" }
    }
    if ([string]::IsNullOrWhiteSpace($ServerAuthPath)) {
      return @{ Ok = $false; Backup = ""; Detail = "server-path-empty" }
    }
    $dir = Split-Path -Parent $ServerAuthPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and (-not (Test-Path -LiteralPath $dir))) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $bak = ""
    if (Test-Path -LiteralPath $ServerAuthPath) {
      try { $bak = Backup-File -Path $ServerAuthPath } catch { $bak = "" }
    }
    $tmp = "$ServerAuthPath.tmp-" + [Guid]::NewGuid().ToString("N")
    Copy-Item -LiteralPath $UserAuthPath -Destination $tmp -Force -ErrorAction Stop
    Move-Item -LiteralPath $tmp -Destination $ServerAuthPath -Force -ErrorAction Stop
    if ($env:OS -eq "Windows_NT") {
      & icacls $ServerAuthPath /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
      if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Backup = $bak; Detail = "acl-failed" } }
    }
    return @{ Ok = $true; Backup = $bak; Detail = "copied" }
  } catch {
    return @{ Ok = $false; Backup = ""; Detail = "copy-failed" }
  }
}

<#
.SYNOPSIS
  Pi-auth menu: login / migrate / retry / exit. Returns the choice string.
.DESCRIPTION
  -ReadFunc injects a fake reader for tests: scriptblock -> [string].
  M (migrate) is offered only when -HasUserAuth. Invalid input reprompts
  (the menu itself never exits the process). Never throws.
#>
function Show-PiAuthMenu {
  param([bool]$HasUserAuth, [scriptblock]$ReadFunc = $null, [string]$Default = "R")
  $opts = "[L]ogin ora / [R]iprova rilevamento / [E]sci e riprendi dopo"
  if ($HasUserAuth) { $opts = "[L]ogin ora / [M]igra login utente / [R]iprova rilevamento / [E]sci e riprendi dopo" }
  while ($true) {
    Write-Host ""
    if ($null -ne $ReadFunc) { $a = & $ReadFunc $opts }
    else { $a = Read-Host "$opts [$Default]" }
    $t = ([string]$a).Trim().ToLowerInvariant()
    if ($t -eq "") { $t = $Default.Trim().ToLowerInvariant() }
    if ($t -eq "l" -or $t -eq "login") { return "login" }
    if ($t -eq "m" -or $t -eq "migra") {
      if ($HasUserAuth) { return "migrate" }
    }
    if ($t -eq "r" -or $t -eq "riprova") { return "retry" }
    if ($t -eq "e" -or $t -eq "esci") { return "exit" }
    Write-Host "Scelta non valida: L, R, E." -ForegroundColor Yellow
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
