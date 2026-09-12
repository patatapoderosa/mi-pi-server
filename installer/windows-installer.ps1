<#
.SYNOPSIS
  Full Windows installer for the PiServer 24/7 node. Idempotent, with update
  and rollback. Must run elevated (self-elevates when launched directly).

.DESCRIPTION
  11 steps: Windows check, Node 22, Pi Coding Agent, pi-telegram, Tailscale,
  app deploy (release ZIP verified by SHA256), extension deploy, config,
  secrets, startup tasks (PiHomeServer + PiRemoteServer), sleep settings,
  health check (fail closed).

  Layout:
    C:\PiServer\app      code (server\, shared\, installer\, VERSION, runtime-env.json)
    C:\PiServer\logs     pi-server.log, pi-server-error.log, installer.log (rotated)
    C:\PiServer\data     PI_CODING_AGENT_DIR (agent configs, extensions, secrets...)

  The scheduled task runs as SYSTEM with PI_CODING_AGENT_DIR set explicitly,
  because SYSTEM has a different HOME and cannot see the installing user's
  %USERPROFILE%\.pi\agent. All binaries are resolved to absolute paths at
  install time and stored in runtime-env.json (SYSTEM PATH is minimal).

  5.1 compatible. Exit code 0 only when every health check passes.

.PARAMETER Repo
  GitHub repo "OWNER/NAME" used for release download.

.PARAMETER Version
  Release tag (e.g. "v0.1.0") or "latest". Ignored with -SourceZip.

.PARAMETER SourceZip
  Local release ZIP path (testing / offline). Checksum check skipped only
  when -ExpectedSha256 is also empty, with an explicit warning.

.PARAMETER ExpectedSha256
  Optional pinned hash. When set, it wins over SHA256SUMS.txt.

.PARAMETER Update
  Update mode: backup app, deploy, restart task, health check, rollback on failure.

.PARAMETER TailscaleAuthKey
  Optional Tailscale auth key for non-interactive login. When empty and the
  machine is not on the tailnet, the installer prints the login URL and waits.
  The key is never logged.

.PARAMETER PayloadDir
  Directory already containing an extracted payload (server\, shared\, ...).
  Skips download; still runs manifest validation.
#>
[CmdletBinding()]
param(
  [string]$Repo = "patatapoderosa/mi-pi-server",
  [string]$Version = "latest",
  [string]$SourceZip = "",
  [string]$ExpectedSha256 = "",
  [switch]$Update,
  [switch]$Resume,
  [switch]$Force,
  [int]$FromStep = 0,
  [string]$PayloadDir = "",
  [string]$InstallRoot = "C:\PiServer",
  [string]$TailscaleAuthKey = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$LibHere = Join-Path (Split-Path -Parent $PSCommandPath) "PiServerLib.ps1"
. $LibHere

$Paths = Get-PiServerPaths -Root $InstallRoot
$LogFile = $Paths.InstallerLog
$TaskName = $Paths.TaskName
$Mode = "install"
if ($Update) { $Mode = "update" }

function L([string]$m, [string]$lvl = "INFO") {
  Write-InstallLog -Message $m -LogFile $LogFile -Level $lvl
}

function Step([string]$n, [string]$title) {
  Write-Host ""
  Write-Host "[$n] $title" -ForegroundColor Cyan
  L "--- step $n : $title"
}

function Fail([string]$why) {
  L $why "FAIL"
  Write-Host ""
  Write-Host "SETUP FALLITO" -ForegroundColor Red
  Write-Host "Motivo: $why"
  exit 1
}

# Resume-safe strict resolvers. The hydration block below initializes shared
# runtime variables; these helpers re-resolve strictly at the top of every step
# that needs them (a skipped step never ran in this session). They read the
# outer variable (traverses up to script scope) and RETURN the resolved path:
# callers assign the result. Throw StepError only when truly required.
function Resolve-PiOrThrow([string]$why) {
  $cur = $piCmd
  if ($null -eq $cur -or -not (Test-Path -LiteralPath ([string]$cur))) {
    $cur = Resolve-PiRuntime -RuntimeEnvPath $Paths.RuntimeEnv
  }
  if ($null -eq $cur) { throw (New-StepError "System" $why) }
  return $cur
}
function Resolve-NodeOrThrow([string]$why) {
  $cur = $NodeExe
  if ($null -eq $cur -or -not (Test-Path -LiteralPath ([string]$cur))) {
    $cur = Resolve-NodeRuntime
  }
  if ($null -eq $cur) { throw (New-StepError "System" $why) }
  return $cur
}

# ---- 0. elevation (self-relaunch; works for direct runs, setup.ps1 pre-elevates pipe runs)
if (-not (Test-IsAdmin)) {
  Write-Host "Riavvio come amministratore..." -ForegroundColor Yellow
  $me = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($me)) {
    Fail "Non elevato e percorso script sconosciuto: rilancia da PowerShell 'Run as Administrator'."
  }
  $elevArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$me`"",
    "-Repo", "`"$Repo`"", "-Version", "`"$Version`"",
    "-InstallRoot", "`"$InstallRoot`"")
  if ($Update) { $elevArgs += "-Update" }
  if ($SourceZip -ne "") { $elevArgs += @("-SourceZip", "`"$SourceZip`"") }
  if ($ExpectedSha256 -ne "") { $elevArgs += @("-ExpectedSha256", "`"$ExpectedSha256`"") }
  if ($PayloadDir -ne "") { $elevArgs += @("-PayloadDir", "`"$PayloadDir`"") }
  if ($Resume) { $elevArgs += "-Resume" }
  if ($Force) { $elevArgs += "-Force" }
  if ($FromStep -gt 0) { $elevArgs += @("-FromStep", "$FromStep") }
  # NOTE: TailscaleAuthKey is deliberately NOT forwarded on auto-elevation:
  # command lines are visible to other users (wmic/tasklist). Pass it only
  # to an already-elevated shell, or log in interactively.
  try {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $elevArgs -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
  } catch {
    Fail "Auto-elevation rifiutata o fallita: $($_.Exception.Message)"
  }
}

try {
  Start-Transcript -Path $Paths.InstallerTranscript -Append | Out-Null
} catch {
  # Transcript is a bonus; Write-InstallLog still writes the file.
}

# ---- install state (resume): checkpoint + real-state verification ----
$script:StatePath = Join-Path $Paths.Data "install-state.json"
$script:StepSkip = @{}
function Save-StepState() {
  $null = Write-InstallState -Path $script:StatePath -State $script:InstallState
}
function Complete-InstallStep([string]$Name) {
  if ($script:InstallState.completedSteps -notcontains $Name) { $script:InstallState.completedSteps += $Name }
  $script:InstallState.currentStep = ""
  $script:InstallState.lastSuccessfulStep = $Name
  $script:InstallState.lastErrorKind = ""
  Save-StepState
}
function Skip-InstallStep([string]$Name) {
  if ($script:InstallState.skippedSteps -notcontains $Name) { $script:InstallState.skippedSteps += $Name }
  $script:InstallState.currentStep = ""
  Save-StepState
}
function Resolve-StepFailure {
  param([string]$Name, [string]$Label, [string]$Title, $Err, [int]$Attempt, [switch]$AllowSkip)
  $msg = ""
  try { $msg = $Err.Exception.Message } catch { $msg = [string]$Err }
  $se = Split-StepError -Message $msg
  $script:InstallState.lastErrorKind = $se.Kind
  $script:InstallState.currentStep = $Name
  Save-StepState
  L "step $Label ($Name) errore [$($se.Kind)] tentativo $Attempt : $($se.Text)" "FAIL"
  $act = Resolve-StepAction -Kind $se.Kind -Attempt $Attempt -MaxAttempts 3
  if ($act -eq "retry") {
    $d = Get-RetryDelaySec -Attempt $Attempt
    L "retry automatico $Name tra ${d}s (tentativo $($Attempt + 1)/3)" "WARN"
    Write-Host "Errore temporaneo, riprovo tra ${d}s... (tentativo $($Attempt + 1)/3)" -ForegroundColor Yellow
    Start-Sleep -Seconds $d
    return "retry"
  }
  if ($act -eq "fail") {
    L "errore fatale in $Label ($Name): $($se.Text)" "FAIL"
    Write-Host ""
    Write-Host "ERRORE FATALE nello step $Label - $Title" -ForegroundColor Red
    Write-Host $se.Text -ForegroundColor Yellow
    Write-Host "Checkpoint salvato: $script:StatePath"
    Write-Host "Rilancia lo stesso comando per riprendere (verifica automatica)."
    exit 1
  }
  $choice = Show-StepMenu -StepLabel $Label -Title $Title -ErrorMessage $se.Text -Details $msg -AllowSkip:$AllowSkip
  if ($choice -eq "skip") { Skip-InstallStep -Name $Name; L "step $Label saltato su scelta operatore" "WARN"; return "skip" }
  if ($choice -eq "exit") {
    Write-Host ""
    Write-Host "Uscita con checkpoint. Per riprendere, rilancia lo stesso comando." -ForegroundColor Cyan
    Write-Host "Stato: $script:StatePath"
    exit 2
  }
  return "retry"
}
$script:StepCatalog = @(
  @{ N = 1; Name = "windows"; Label = "1/11"; Title = "Controllo Windows" },
  @{ N = 2; Name = "node"; Label = "2/11"; Title = "Node.js 22" },
  @{ N = 3; Name = "pi"; Label = "3/11"; Title = "Pi Coding Agent" },
  @{ N = 4; Name = "pi-telegram"; Label = "4/11"; Title = "pi-telegram" },
  @{ N = 5; Name = "tailscale"; Label = "5/11"; Title = "Tailscale (private network)" },
  @{ N = 6; Name = "deploy"; Label = "6/11"; Title = "Remote extension (deploy app)" },
  @{ N = 7; Name = "config"; Label = "7/11"; Title = "Config (remote-server.json, no Telegram IDs anymore)" },
  @{ N = 8; Name = "secrets"; Label = "8/11"; Title = "Secrets e login Pi" },
  @{ N = 9; Name = "tasks"; Label = "9/11"; Title = "Windows startup (2 tasks) + firewall" },
  @{ N = 10; Name = "sleep"; Label = "10/11"; Title = "Sleep settings" },
  @{ N = 11; Name = "health"; Label = "11/11"; Title = "Health check" }
)
$stFile = Read-InstallState -Path $script:StatePath
$script:InstallState = $stFile.State
if ($stFile.Notice -ne "") { Write-Host $stFile.Notice -ForegroundColor Yellow; L $stFile.Notice "WARN" }
if ($Force) {
  $script:InstallState = @{ schemaVersion = 1; targetRelease = ""; completedSteps = @(); skippedSteps = @(); currentStep = ""; lastSuccessfulStep = ""; lastErrorKind = ""; updatedAt = "" }
  L "-Force: checkpoint ignorato, verifica/rieseguo tutto" "WARN"
}
if ($FromStep -lt 0 -or $FromStep -gt 11) { Write-Host "-FromStep ignorato (range 1-11)." -ForegroundColor Yellow; $FromStep = 0 }
# Auto-update detection: the one-liner never passes -Update, so an existing
# install with a different VERSION than the requested target must still use
# backup-preserving semantics. -Update stays as explicit override.
$installedVer = ""
try { $installedVer = ((Get-Content -LiteralPath $Paths.VersionFile -Raw -ErrorAction Stop).Trim()) } catch { }
if ((-not $Update) -and (Test-ShouldAutoUpdate -InstalledVersion $installedVer -TargetVersion $Version)) {
  $Mode = "update"
  L ("auto-update rilevato (installata=" + $installedVer + " target=" + $Version + "): backup preservato") "WARN"
}
$script:DeployWillRun = $false
foreach ($s in $script:StepCatalog) {
  $run = $true
  if ($Force) { $run = $true }
  elseif ($FromStep -gt 0 -and $s.N -ge $FromStep) { $run = $true }
  elseif ($Mode -eq "update" -and $s.Name -eq "deploy") { $run = $true }
  elseif (($Version -ne "latest") -and ($Version -ne "") -and ($s.Name -eq "deploy") -and ($script:InstallState.targetRelease -ne "") -and ($script:InstallState.targetRelease -ne $Version)) { $run = $true }
  elseif ($script:InstallState.completedSteps -contains $s.Name) {
    $ok = $false
    try { $ok = Test-StepRealState -Step $s.Name -Paths $Paths -ExpectedRelease $Version } catch { $ok = $false }
    if ($ok) { $run = $false }
  }
  $script:StepSkip[$s.Name] = (-not $run)
  if ($s.Name -eq "deploy") { $script:DeployWillRun = (-not $script:StepSkip.deploy) }
  if ((($s.Name -eq "tasks") -or ($s.Name -eq "health")) -and $script:DeployWillRun) { $script:StepSkip[$s.Name] = $false }
}
if ($stFile.Corrupt -or $Force -or ($script:InstallState.lastSuccessfulStep -ne "") -or ($script:InstallState.completedSteps.Count -gt 0)) {
  Write-Host ""
  Write-Host "Installazione precedente rilevata." -ForegroundColor Cyan
  foreach ($s in $script:StepCatalog) {
    $mark = "da eseguire"
    if ($script:StepSkip[$s.Name]) { $mark = "gia OK" }
    Write-Host (("[" + $s.Label + "] " + $s.Title + " .......... " + $mark))
  }
  if ($script:InstallState.currentStep -ne "") {
    Write-Host ("Ripresa da: " + $script:InstallState.currentStep)
  }
}
$script:InstallState.targetRelease = $Version
Save-StepState

# ---- runtime context hydration (resume-safe, unconditional) ----
# A step skipped by resume never ran in THIS PowerShell session, so shared
# runtime variables must not depend on it. Re-resolve best effort here (never
# throws: resolvers return $null / defaults when tools are not installed yet).
# Each dependent step still re-resolves strictly before use; these inits only
# guarantee StrictMode-safe reads and sane session defaults.
$NodeExe = Resolve-NodeRuntime
$piCmd = Resolve-PiRuntime -RuntimeEnvPath $Paths.RuntimeEnv
if ($null -ne $piCmd) { $NpmGlobalBin = Split-Path -Parent $piCmd } else { $NpmGlobalBin = $null }
$RemotePort = Resolve-RemotePort -AgentDir $Paths.AgentDir
$appBackup = $null
$hmacShowOnce = ""

try {
  # ================= [1/11] Windows =================
  Step "1/11" "Controllo Windows"
  if ($script:StepSkip.windows) { L "step 1/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "windows"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  if (-not (Test-WindowsOS)) { throw (New-StepError "System" "Questo installer gira solo su Windows.") }
  $os = Get-CimInstance Win32_OperatingSystem
  L "OS: $($os.Caption) build $($os.BuildNumber)" "OK"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {
    throw (New-StepError "System" "Impossibile abilitare TLS 1.2: $($_.Exception.Message)")
  }

        Complete-InstallStep -Name "windows"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "windows" -Label "1/11" -Title "Controllo Windows" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [2/11] Node =================
  Step "2/11" "Node.js 22"
  if ($script:StepSkip.node) { L "step 2/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "node"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $nodeOk = $false
  try {
    $v = & node -p "process.versions.node" 2>$null
    if (Test-AtLeastNode22 -VersionString $v) {
      $nodeOk = $true
      L "Node.js $v gia presente" "OK"
      Write-Host "Node.js $v  gia presente" -ForegroundColor Green
    }
  } catch { }
  if (-not $nodeOk) {
    L "Node.js mancante o < 22: installazione"
    $winget = Resolve-ToolPath "winget"
    if ($null -ne $winget) {
      L "install via winget (OpenJS.NodeJS.LTS, scope machine)"
      & $winget install -e --id OpenJS.NodeJS.LTS --scope machine `
        --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
      $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + $env:PATH
    } else {
      L "winget assente: fallback MSI da nodejs.org" "WARN"
      $index = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -TimeoutSec 30
      $rel = $index | Where-Object { $_.version -match "^v22\." } | Select-Object -First 1
      if ($null -eq $rel) { throw (New-StepError "Transient" "Nessuna release Node 22 trovata su nodejs.org.") }
      $msiUrl = "https://nodejs.org/dist/$($rel.version)/node-$($rel.version)-x64.msi"
      $msi = Join-Path $env:TEMP ("node-{0}.msi" -f $rel.version)
      Invoke-WebRequest -Uri $msiUrl -OutFile $msi -TimeoutSec 300
      Start-Process msiexec.exe -ArgumentList @("/qn", "/i", "`"$msi`"") -Wait
      Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
      $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + $env:PATH
    }
    $v = & node -p "process.versions.node" 2>$null
    if (-not (Test-AtLeastNode22 -VersionString $v)) {
      throw (New-StepError "System" "Node.js >= 22 non disponibile dopo l'installazione (trovato: '$v').")
    }
    L "Node.js $v installato" "OK"
  }
  $NodeExe = Resolve-NodeRuntime
  if ($null -eq $NodeExe) { throw (New-StepError "System" "node.exe non risolvibile dopo l'installazione.") }

        Complete-InstallStep -Name "node"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "node" -Label "2/11" -Title "Node.js 22" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [3/11] Pi =================
  Step "3/11" "Pi Coding Agent"
  if ($script:StepSkip.pi) { L "step 3/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "pi"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $piCmd = Resolve-PiRuntime -RuntimeEnvPath $Paths.RuntimeEnv
  if ($null -ne $piCmd) {
    try {
      $pv = & $piCmd --version 2>$null
      L "Pi gia presente ($pv)" "OK"
      Write-Host "Pi $pv  gia presente" -ForegroundColor Green
    } catch { $piCmd = $null }
  }
  if ($null -eq $piCmd) {
    L "install npm -g @earendil-works/pi-coding-agent"
    $npm = Resolve-ToolPath "npm"
    if ($null -eq $npm) { throw (New-StepError "System" "npm non trovato (installazione Node incompleta?).") }
    & $npm install -g "@earendil-works/pi-coding-agent" --no-audit --no-fund
    $piCmd = Resolve-PiRuntime -RuntimeEnvPath $Paths.RuntimeEnv
    if ($null -eq $piCmd) {
      # npm global bin may not be on PATH yet: probe default locations.
      foreach ($cand in @(
        (Join-Path $env:APPDATA "npm\pi.cmd"),
        "C:\Program Files\nodejs\pi.cmd",
        (Join-Path ${env:ProgramFiles} "nodejs\pi.cmd"))) {
        if (Test-Path -LiteralPath $cand) { $piCmd = $cand; break }
      }
    }
    if ($null -eq $piCmd) { throw (New-StepError "System" "Pi installato ma pi.cmd non trovato. Controlla il prefisso npm globale.") }
    L "Pi installato: $piCmd" "OK"
  }
  $NpmGlobalBin = Split-Path -Parent $piCmd

        Complete-InstallStep -Name "pi"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "pi" -Label "3/11" -Title "Pi Coding Agent" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [4/11] pi-telegram =================
  Step "4/11" "pi-telegram"
  if ($script:StepSkip["pi-telegram"]) { L "step 4/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "pi-telegram"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $piCmd = Resolve-PiOrThrow "pi.cmd non risolvibile (step 3 saltato ma Pi assente). Riesegui senza resume o reinstalla Pi."
  $NpmGlobalBin = Split-Path -Parent $piCmd
  $listed = ""
  try { $listed = (& $piCmd list 2>$null | Out-String) } catch { }
  if ($listed -match "pi-telegram") {
    L "pi-telegram gia installato" "OK"
    Write-Host "pi-telegram  gia presente" -ForegroundColor Green
  } else {
    L "install package npm:@llblab/pi-telegram"
    try {
      & $piCmd install "npm:@llblab/pi-telegram"
    } catch {
      L "pi install fallito: $($_.Exception.Message)" "WARN"
    }
    $listed = ""
    try { $listed = (& $piCmd list 2>$null | Out-String) } catch { }
    if ($listed -notmatch "pi-telegram") {
      throw (New-StepError "System" "pi-telegram non risulta installato (pi list). Rete disponibile? Riesegui con -Update dopo 'pi install npm:@llblab/pi-telegram' manuale.")
    }
    L "pi-telegram installato" "OK"
  }

        Complete-InstallStep -Name "pi-telegram"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "pi-telegram" -Label "4/11" -Title "pi-telegram" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [5/11] Tailscale =================
  Step "5/11" "Tailscale (private network)"
  if ($script:StepSkip.tailscale) { L "step 5/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "tailscale"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $tsExe = Resolve-ToolPath "tailscale"
  if ($null -eq $tsExe) {
    $tsExe = Join-Path ${env:ProgramFiles} "Tailscale\tailscale.exe"
    if (-not (Test-Path -LiteralPath $tsExe)) { $tsExe = $null }
  }
  if ($null -eq $tsExe) {
    L "Tailscale mancante: installazione"
    $winget = Resolve-ToolPath "winget"
    if ($null -ne $winget) {
      L "install via winget (Tailscale.Tailscale, scope machine)"
      & $winget install -e --id Tailscale.Tailscale --scope machine --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
    } else {
      L "winget assente: fallback MSI da pkgs.tailscale.com" "WARN"
      $msiUrl = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
      $msi = Join-Path $env:TEMP ("tailscale-setup-" + [Guid]::NewGuid().ToString("N") + ".msi")
      Invoke-WebRequest -Uri $msiUrl -OutFile $msi -TimeoutSec 300
      Start-Process msiexec.exe -ArgumentList @("/i", "`"$msi`"", "/quiet", "/norestart", "TS_NOLAUNCH=1") -Wait
      Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 5
    $tsExe = Join-Path ${env:ProgramFiles} "Tailscale\tailscale.exe"
    if (-not (Test-Path -LiteralPath $tsExe)) { $tsExe = Resolve-ToolPath "tailscale" }
    if ($null -eq $tsExe -or (-not (Test-Path -LiteralPath $tsExe))) { throw (New-StepError "System" "Tailscale installato ma tailscale.exe non trovato.") }
    L "Tailscale installato" "OK"
  } else {
    L "Tailscale gia presente" "OK"
  }
  $tsUp = $false
  try {
    & $tsExe status 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $tsUp = $true }
  } catch { }
  if (-not $tsUp) {
    if (-not [string]::IsNullOrWhiteSpace($TailscaleAuthKey)) {
      L "login Tailscale via auth key (valore mai loggato)"
      $keyFile = Join-Path $env:TEMP ("tskey-" + [Guid]::NewGuid().ToString("N") + ".txt")
      try {
        $TailscaleAuthKey | Out-File -LiteralPath $keyFile -Encoding ascii -NoNewline
        & icacls $keyFile /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
        & $tsExe up --auth-key=file:$keyFile 2>&1 | Out-Null
      } finally {
        Remove-Item -LiteralPath $keyFile -Force -ErrorAction SilentlyContinue
      }
    } else {
      Write-Host ""
      Write-Host "[!] Apri il link Tailscale e autorizza questo PC." -ForegroundColor Yellow
      Write-Host "    Si aprira il browser (o segui l URL stampato qui sotto), poi premi INVIO."
      try { & $tsExe up } catch { }
      Write-Host "Premi INVIO quando hai autorizzato questo PC su Tailscale..."
      [void](Read-Host)
    }
    try {
      & $tsExe status 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $tsUp = $true }
    } catch { }
    if (-not $tsUp) { throw (New-StepError "Transient" "Tailscale non connesso (tailscale status fallisce). Completa il login e riprova.") }
  }
  $tsIp = ""
  try { $tsIp = ((& $tsExe ip -4 2>$null | Out-String).Trim().Split("`n")[0]).Trim() } catch { }
  if ($tsIp -notmatch "^100\.(6[4-9]|[78]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$") {
    throw (New-StepError "Transient" "IP Tailscale non valido o assente. Verifica tailscale status.")
  }
  L "tailnet OK (this node: $tsIp)" "OK"

        Complete-InstallStep -Name "tailscale"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "tailscale" -Label "5/11" -Title "Tailscale (private network)" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [6/11] App deploy =================
  Step "6/11" "Remote extension (deploy app)"
  if ($script:StepSkip.deploy) { L "step 6/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "deploy"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $NodeExe = Resolve-NodeOrThrow "node.exe non risolvibile (step 2 saltato ma Node assente). Riesegui senza resume o reinstalla Node 22."
  $piCmd = Resolve-PiOrThrow "pi.cmd non risolvibile (step 3 saltato ma Pi assente). Riesegui senza resume o reinstalla Pi."
  $NpmGlobalBin = Split-Path -Parent $piCmd
  $payload = $PayloadDir
  $tmpPayload = ""
  if ([string]::IsNullOrWhiteSpace($payload)) {
    $tmpRoot = Join-Path $env:TEMP ("piserver-dl-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    $tmpPayload = $tmpRoot
    $zipPath = Join-Path $tmpRoot "payload.zip"
    if ($SourceZip -ne "") {
      L "payload locale: $SourceZip"
      if (-not (Test-Path -LiteralPath $SourceZip)) { throw (New-StepError "System" "SourceZip non trovato: $SourceZip") }
      Copy-Item -LiteralPath $SourceZip -Destination $zipPath -Force
      if ($ExpectedSha256 -ne "") {
        if (-not (Test-FileChecksum -Path $zipPath -ExpectedSha256 $ExpectedSha256)) {
          throw (New-StepError "Fatal" "Checksum dello ZIP locale non coincide (-ExpectedSha256). Abortito.")
        }
        L "checksum ZIP locale OK" "OK"
      } else {
        L "ZIP locale senza checksum: verifica solo manifest (origine fidata dall'operatore)" "WARN"
      }
    } else {
      $dl = Get-ReleaseDownload -Repo $Repo -Version $Version
      $script:InstallState.targetRelease = $dl.Tag; Save-StepState
      L "download $($dl.ZipUrl)"
      Invoke-WebRequest -Uri $dl.ZipUrl -OutFile $zipPath -TimeoutSec 300
      $want = $ExpectedSha256
      if ([string]::IsNullOrWhiteSpace($want)) { $want = $dl.Sha256 }
      if ([string]::IsNullOrWhiteSpace($want)) {
        throw (New-StepError "Fatal" ("Nessun checksum disponibile per questa release (né -ExpectedSha256 né SHA256SUMS.txt: " + $dl.SumsError + "). Fail closed: crea una release con SHA256SUMS.txt o passa -ExpectedSha256."))
      }
      if (-not (Test-FileChecksum -Path $zipPath -ExpectedSha256 $want)) {
        throw (New-StepError "Fatal" "Checksum release non coincide. File scartato (fail closed).")
      }
      L "checksum release OK" "OK"
    }
    $payload = Join-Path $tmpRoot "payload"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $payload -Force
    # Archive may wrap everything in a single top-level folder.
    $payload = Resolve-PayloadRoot -Dir $payload
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
  }
  $payload = Resolve-PayloadRoot -Dir $payload
  $man = Test-ReleaseManifest -PayloadRoot $payload
  if (-not $man.Ok) {
    throw (New-StepError "Fatal" ("Manifest incompleto, file mancanti: " + ($man.Missing -join ", ")))
  }
  L "manifest payload OK" "OK"

  $appBackup = $null
  foreach ($d in @($Paths.Logs, $Paths.Data)) {
    if (-not (Test-Path -LiteralPath $d)) {
      New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
  }
  # Stage the new app FIRST via Invoke-AppStaging (lib): payload -> stage ->
  # validate -> swap. A failed staging never touches the live app/ (no rollback
  # needed here); in update mode the previous app/ is preserved as backup.
  $ver = [string]$script:InstallState.targetRelease
  if ([string]::IsNullOrWhiteSpace($ver) -or ($ver -eq "latest")) { $ver = $Version }
  if ($ver -eq "latest") { $ver = "latest@$(Get-Date -Format 'yyyyMMdd')" }
  $haveVerNow = ""
  try { $haveVerNow = ((Get-Content -LiteralPath $Paths.VersionFile -Raw -ErrorAction Stop).Trim()) } catch { }
  $effMode = $Mode
  if (Test-ShouldAutoUpdate -InstalledVersion $haveVerNow -TargetVersion $ver) { $effMode = "update" }
  if (($effMode -eq "update") -and ($Mode -ne "update")) { L ("auto-update in step 6 (installata=" + $haveVerNow + " target=" + $ver + ")") "WARN" }
  $remotePortNum = 0
  try { if ($RemotePort -match "^\d+$") { $remotePortNum = [int]$RemotePort } } catch { }
  $preSwap = {
    $stop = Stop-PiServerRuntime -Paths $Paths -RemotePort $remotePortNum
    L ("runtime stop pre-swap: " + $stop.Detail) "INFO"
    if (-not $stop.Ok) { throw ("runtime ancora attivo, swap annullato: " + $stop.Detail) }
    return $null
  }
  $st = Invoke-AppStaging -PayloadDir $payload -AppPath $Paths.App -Mode $effMode -VersionLabel $ver -PreSwapAction $preSwap
  if (-not $st.Ok) { throw (New-StepError "Fatal" ("Deploy staging fallito (app esistente intatta): " + $st.Error)) }
  $appBackup = $st.BackupPath
  if ($null -ne $appBackup) { L "backup app -> $appBackup" }
  L "app deployata (VERSION=$ver)" "OK"

  # Extension + shared into the agent dir, preserving ../../shared layout.
  $dstExt = Join-Path $Paths.ExtDir "pi-remote-config"
  if (Test-Path -LiteralPath $dstExt) {
    Remove-Item -LiteralPath $dstExt -Recurse -Force
  }
  Copy-Item -Path (Join-Path $Paths.App "server\pi-remote-config") -Destination $dstExt -Recurse -Force
  if (Test-Path -LiteralPath $Paths.SharedDir) {
    Remove-Item -LiteralPath $Paths.SharedDir -Recurse -Force
  }
  Copy-Item -Path (Join-Path $Paths.App "shared") -Destination $Paths.SharedDir -Recurse -Force
  $extPkg = Join-Path $dstExt "package.json"
  if (Test-Path -LiteralPath $extPkg) {
    try {
      $pkg = Get-Content -LiteralPath $extPkg -Raw | ConvertFrom-Json
      if ($null -ne $pkg.dependencies) {
        L "npm install dipendenze extension"
        $npmCli = Join-Path (Split-Path -Parent $NodeExe) "node_modules\npm\bin\npm-cli.js"
        if (-not (Test-Path -LiteralPath $npmCli)) { throw "npm-cli.js non trovato accanto a node.exe" }
        & $NodeExe $npmCli install --omit=dev --no-audit --no-fund --prefix $dstExt 2>&1 | Out-Null
      }
    } catch {
      L "npm install extension fallito (continuo): $($_.Exception.Message)" "WARN"
    }
  }
  L "extension deployata in data\extensions + data\shared" "OK"

  # Node type-stripping probe for the TS remote daemon entry (no build step).
  # New Node (>=22.18) runs .ts directly; older 22.x needs the explicit flag.
  $nodeStripArgs = @()
  $stripProbe = Join-Path $Paths.App "server\pi-remote-server\index.ts"
  $stripped = $false
  foreach ($candidate in @(@(), @("--experimental-strip-types"))) {
    try {
      & $NodeExe @candidate --check $stripProbe 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $nodeStripArgs = $candidate; $stripped = $true; break }
    } catch { }
  }
  if (-not $stripped) { throw (New-StepError "System" "Node cannot type-check the remote daemon entry (node --check failed). Upgrade Node 22.") }
  L "node type-stripping: $(if ($nodeStripArgs.Count -eq 0) { 'native (no flag)' } else { $nodeStripArgs -join ' ' })" "OK"
  $rtSyn = Test-RuntimeSyntax -NodeExe $NodeExe -Files @($Paths.Daemon, (Join-Path (Split-Path -Parent $Paths.Daemon) "spawn-pi.mjs"))
  if (-not $rtSyn.Ok) { throw (New-StepError "System" ("Runtime JS non valido PRIMA dei task (deploy corrotto?): " + ($rtSyn.Failures -join "; "))) }
  L "runtime JS syntax OK (pi-daemon.mjs, spawn-pi.mjs)" "OK"

  # runtime-env.json with absolute paths (SYSTEM-safe).
  @{
    NodeExe = $NodeExe
    PiBin = $piCmd
    NpmGlobalBin = $NpmGlobalBin
    DaemonScript = $Paths.Daemon
    NodeArgs = $nodeStripArgs
    RemoteEntry = $Paths.RemoteEntry
    AgentDir = $Paths.AgentDir
  } | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $Paths.RuntimeEnv -Encoding utf8
  L "runtime-env.json scritto (path assoluti)" "OK"

  if ($tmpPayload -ne "") {
    Remove-Item -LiteralPath $tmpPayload -Recurse -Force -ErrorAction SilentlyContinue
  }

        Complete-InstallStep -Name "deploy"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "deploy" -Label "6/11" -Title "Remote extension (deploy app)" -Err $_ -Attempt $attempt
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [7/11] Config =================
  Step "7/11" "Config (remote-server.json, no Telegram IDs anymore)"
  if ($script:StepSkip.config) { L "step 7/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "config"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $serverCfgPath = Join-Path $Paths.AgentDir "remote-server.json"
  $serverCfgExists = Test-Path -LiteralPath $serverCfgPath
  $portRaw = $env:PI_REMOTE_PORT
  if (-not $serverCfgExists) {
    $portEnv = $env:PI_REMOTE_PORT
    if ((Test-ValidPort $portEnv)) { $portRaw = ([string]$portEnv).Trim() }
    else {
      if (-not [string]::IsNullOrWhiteSpace($portEnv)) { Write-Host "PI_REMOTE_PORT non valida, chiedo interattivamente." -ForegroundColor Yellow }
      $portRaw = Read-ValidatedPort
    }
  }
  $serverDefaults = @{
    port = 43128
    maxSkewSeconds = 300
    allowedServices = @("pi-server")
  }
  $st = Save-JsonConfigPreserving -Path $serverCfgPath -Defaults $serverDefaults `
    -RequiredKeys @("port", "maxSkewSeconds", "allowedServices")
  if (-not $serverCfgExists) {
    $sc = Get-Content -LiteralPath $serverCfgPath -Raw | ConvertFrom-Json
    $sc.port = [int]$portRaw
    $sc | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $serverCfgPath -Encoding utf8
    L "remote-server.json created (port $portRaw, tailnet bind)" "OK"
  } else {
    L "remote-server.json: $st (user config preserved)" "OK"
  }
  $RemotePort = Resolve-RemotePort -AgentDir $Paths.AgentDir
  L "remote API port: $RemotePort" "OK"

        Complete-InstallStep -Name "config"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "config" -Label "7/11" -Title "Config (remote-server.json)" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [8/11] Secrets =================
  Step "8/11" "Secrets e login Pi"
  if ($script:StepSkip.secrets) { L "step 8/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "secrets"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $piCmd = Resolve-PiOrThrow "pi.cmd non risolvibile (step 3 saltato ma Pi assente). Riesegui senza resume o reinstalla Pi."
  L "--- step 8/11 (secrets+login)"
  if (-not (Test-Path -LiteralPath $Paths.SecretsDir)) {
    New-Item -ItemType Directory -Path $Paths.SecretsDir -Force | Out-Null
  }
  & icacls $Paths.SecretsDir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F" | Out-Null
  $tokFile = Join-Path $Paths.SecretsDir "server-bot-token"
  $hmacFile = Join-Path $Paths.SecretsDir "remote-hmac"
  # Token flow: validate FIRST, write ONLY when verified. Existing valid token
  # is preserved; an unverifiable existing file is never deleted (only replaced
  # after a new token verifies). The token value is never logged.
  $botToken = $null
  $botInfo = $null
  $envTok = $env:PI_SERVER_BOT_TOKEN
  if (-not [string]::IsNullOrWhiteSpace($envTok)) {
    if (-not (Test-ValidTokenFormat $envTok)) { Write-Host "PI_SERVER_BOT_TOKEN malformato, lo ignoro e chiedo." -ForegroundColor Yellow }
    else {
      L "verifico token da env con Telegram..."
      $chkEnv = Test-TelegramBotToken -Token $envTok.Trim() -TimeoutSec 20
      if ($chkEnv.Ok) { $botToken = $envTok.Trim(); $botInfo = $chkEnv }
      elseif ($chkEnv.Kind -eq "invalid-token") { Write-Host ("Token da env rifiutato: " + $chkEnv.Message) -ForegroundColor Yellow }
      else {
        $pickEnv = Show-StepMenu -StepLabel "8/11" -Title "Secrets e login Pi" -ErrorMessage ("Token da env non verificabile: " + $chkEnv.Message) -Details $chkEnv.Kind
        if ($pickEnv -eq "exit") { Write-Host ""; Write-Host "Uscita con checkpoint. Per riprendere, rilancia lo stesso comando." -ForegroundColor Cyan; exit 2 }
      }
    }
  }
  if (($null -eq $botToken) -and (Test-Path -LiteralPath $tokFile)) {
    $oldTok = ""
    try { $oldTok = (Get-Content -LiteralPath $tokFile -Raw -ErrorAction Stop).Trim() } catch { $oldTok = "" }
    if ($oldTok -ne "") {
      L "verifico token esistente con Telegram..."
      $chkOld = Test-TelegramBotToken -Token $oldTok -TimeoutSec 20
      if ($chkOld.Ok) {
        $botToken = $oldTok; $botInfo = $chkOld
        L ("server-bot-token esistente verificato (id=" + $chkOld.BotId + ")") "OK"
      }
      elseif ($chkOld.Kind -eq "invalid-token") { Write-Host "Token esistente non piu valido: ne chiedo uno nuovo (il file resta finche il nuovo non e verificato)." -ForegroundColor Yellow }
      else {
        $pickOld = Show-StepMenu -StepLabel "8/11" -Title "Secrets e login Pi" -ErrorMessage ("Token esistente non verificabile: " + $chkOld.Message) -Details $chkOld.Kind
        if ($pickOld -eq "exit") { Write-Host ""; Write-Host "Uscita con checkpoint. Per riprendere, rilancia lo stesso comando." -ForegroundColor Cyan; exit 2 }
      }
    }
  }
  while ($null -eq $botToken) {
    $cand = Read-ValidatedHidden -Prompt "ServerBot token (nascosto)" -Validate { param($x) Test-ValidTokenFormat $x } -InvalidMessage "Formato token non valido (atteso 123456:ABC... da BotFather). Riprova."
    $cand = $cand.Trim()
    $attemptT = 0
    while ($null -eq $botToken) {
      $attemptT++
      Write-Host "Verifico con Telegram..."
      $chk = Test-TelegramBotToken -Token $cand -TimeoutSec 20
      if ($chk.Ok) {
        Write-Host ""
        Write-Host "Bot trovato:" -ForegroundColor Green
        Write-Host ("  ID: " + $chk.BotId)
        if (-not [string]::IsNullOrWhiteSpace($chk.BotUsername)) { Write-Host ("  Username: @" + $chk.BotUsername) }
        if (Read-ValidatedYesNo -Prompt "Usare questo bot? [Y/n]" -Default "Y") { $botToken = $cand; $botInfo = $chk }
        break
      }
      if ($chk.Kind -eq "invalid-token") {
        Write-Host ("Token Telegram non valido. " + $chk.Message) -ForegroundColor Yellow
        Write-Host "Controlla BotFather e riprova."
        break
      }
      Write-Host ("Token non ancora verificabile: " + $chk.Message) -ForegroundColor Yellow
      if ($attemptT -lt 3) {
        $dT = Get-RetryDelaySec -Attempt $attemptT
        Write-Host "Riprovo tra ${dT}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $dT
      } else {
        $pickT = Show-StepMenu -StepLabel "8/11" -Title "Secrets e login Pi" -ErrorMessage ("Token non verificabile: " + $chk.Message) -Details $chk.Kind
        if ($pickT -eq "exit") { Write-Host ""; Write-Host "Uscita con checkpoint. Per riprendere, rilancia lo stesso comando." -ForegroundColor Cyan; exit 2 }
      }
    }
  }
  $writeTok = $true
  if (Test-Path -LiteralPath $tokFile) {
    try { if (((Get-Content -LiteralPath $tokFile -Raw -ErrorAction Stop).Trim()) -eq $botToken) { $writeTok = $false; L "server-bot-token esistente preservato (gia verificato)" "OK" } } catch { }
  }
  if ($writeTok) {
    if (-not (Write-AtomicTextFile -Path $tokFile -Content $botToken -Encoding "ascii")) { throw (New-StepError "Fatal" "Impossibile scrivere server-bot-token (secret state inconsistente).") }
    & icacls $tokFile /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
    L "server-bot-token scritto (ACL: SYSTEM+Administrators)" "OK"
  }
  $hmacShowOnce = ""
  if (-not (Test-Path -LiteralPath $hmacFile)) {
    $envHmac = $env:PI_REMOTE_HMAC
    $hmac = $null
    if ((Test-ValidHmac $envHmac)) { $hmac = @{ Secret = ([string]$envHmac); Generated = $false } }
    else {
      if (-not [string]::IsNullOrWhiteSpace($envHmac)) { Write-Host "PI_REMOTE_HMAC non valido (min 16 stampabili, no spazi), chiedo." -ForegroundColor Yellow }
      $hmac = Read-ValidatedHmac
    }
    if ($hmac.Generated) { $hmacShowOnce = $hmac.Secret; L "HMAC generato (RNG crittografico)" "OK" }
    if (-not (Write-AtomicTextFile -Path $hmacFile -Content $hmac.Secret -Encoding "ascii")) { throw (New-StepError "Fatal" "Impossibile scrivere remote-hmac (secret state inconsistente).") }
    & icacls $hmacFile /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
    L "remote-hmac scritto (ACL: SYSTEM+Administrators)" "OK"
  } else {
    L "remote-hmac esistente preservato (nessuna rigenerazione)" "OK"
  }
  # telegram.json profile (token via file is preferred by the extension, but
  # pi-telegram itself reads telegram.json: keep both in sync, token redacted in logs).
  $tgJson = Join-Path $Paths.AgentDir "telegram.json"
  $ownerId = $env:PI_OWNER_ID
  if (-not (Test-ValidOwnerId $ownerId)) {
    if (-not [string]::IsNullOrWhiteSpace($ownerId)) { Write-Host "PI_OWNER_ID non valido, chiedo." -ForegroundColor Yellow }
    $defOwner = $null
    try {
      $old = Get-Content -LiteralPath $tgJson -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($null -ne $old.profiles -and $null -ne $old.profiles.default) {
        $cand = [string]$old.profiles.default.allowedUserId
        if (Test-ValidOwnerId $cand) { $defOwner = $cand }
      }
    } catch { }
    if ($null -ne $defOwner) { $ownerId = Read-ValidatedOwnerId -Prompt ("Owner Telegram user id (numerico, da @userinfobot) [" + $defOwner + "]") -Default $defOwner }
    else { $ownerId = Read-ValidatedOwnerId }
  }
  # Token gia verificato in acquisizione: sincronizzo telegram.json atomicamente.
  # (Nessuna seconda getMe: la validita e stata provata prima della scrittura.)
  $tgBody = @{ profiles = @{ default = @{ botToken = $botToken; allowedUserId = [long]$ownerId } } } | ConvertTo-Json -Depth 5
  if (-not (Write-AtomicTextFile -Path $tgJson -Content $tgBody -Encoding "utf8")) { throw (New-StepError "Fatal" "Impossibile scrivere telegram.json (secret state inconsistente).") }
  L ("telegram.json sincronizzato (token non stampato nei log, bot id=" + $botInfo.BotId + ")") "OK"

  # ---- Pi login (same step 8/11: no credentials = no server) ----
  Write-Host ""
  Write-Host "[8/11 seguito] Autenticazione Pi" -ForegroundColor Cyan
  $userAgentDir = Join-Path $env:USERPROFILE ".pi\agent"
  $piAuthDone = $false
  while (-not $piAuthDone) {
    $authServer = Test-PiAuthentication -PiExe $piCmd -AgentDir $Paths.AgentDir
    if ($authServer.Authenticated) {
      L ("Pi autenticato in server dir (provider=" + $authServer.Provider + ")") "OK"
      $aclCheck = Test-AuthAcl -Path $authServer.SourcePath
      if (-not $aclCheck.Ok) {
        Write-Host ("ACL auth server da verificare: " + $aclCheck.Detail) -ForegroundColor Yellow
        L ("ACL auth server: " + $aclCheck.Detail) "WARN"
      }
      $piAuthDone = $true
      break
    }
    $authUser = Test-PiAuthentication -PiExe $piCmd -AgentDir $userAgentDir
    $srvFile = Join-Path $Paths.AgentDir "auth.json"
    $usrFile = Join-Path $userAgentDir "auth.json"
    Write-Host ""
    Write-Host "Autenticazione Pi non rilevata nella directory del server." -ForegroundColor Yellow
    Write-Host ("  Pi executable: " + $piCmd)
    Write-Host ("  Server agent dir: " + $Paths.AgentDir)
    Write-Host ("  User agent dir:   " + $userAgentDir)
    if (Test-Path -LiteralPath $srvFile) {
      Write-Host ("  Auth server: presente ma non valida (" + $authServer.Reason + ")")
    } else {
      Write-Host "  Auth server: assente"
    }
    if (Test-Path -LiteralPath $usrFile) {
      if ($authUser.Authenticated) {
        Write-Host ("  Auth user: valida (provider=" + $authUser.Provider + ")")
      } else {
        Write-Host ("  Auth user: presente ma non valida (" + $authUser.Reason + ")")
      }
    } else {
      Write-Host "  Auth user: assente"
    }
    Write-Host ("  Verifica: " + $authServer.Reason)
    $choice = Show-PiAuthMenu -HasUserAuth ($authUser.Authenticated)
    if ($choice -eq "exit") {
      $script:InstallState.currentStep = "secrets"
      $script:InstallState.lastErrorKind = "UserExit"
      Save-StepState
      Write-Host ""
      Write-Host "Uscita con checkpoint. Per riprendere, rilancia lo stesso comando." -ForegroundColor Cyan
      Write-Host ("Stato: " + $script:StatePath)
      exit 2
    } elseif ($choice -eq "retry") {
      continue
    } elseif ($choice -eq "migrate") {
      if (-not $authUser.Authenticated) {
        Write-Host "Login utente non valido: migrazione annullata, fai login diretto." -ForegroundColor Yellow
        continue
      }
      Write-Host "Autenticazione Pi esistente trovata nel profilo utente."
      if (Read-ValidatedYesNo -Prompt "Copiarla nella directory del server? [Y/n]" -Default "Y") {
        $mig = Copy-PiAuthToServerDir -UserAuthPath $usrFile -ServerAuthPath $srvFile
        if (-not $mig.Ok) {
          Write-Host ("Migrazione fallita: " + $mig.Detail) -ForegroundColor Red
          L ("Migrazione auth fallita: " + $mig.Detail) "FAIL"
          continue
        }
        if ($mig.Backup -ne "") { L ("Backup auth server precedente: " + $mig.Backup) "WARN" }
        L "auth.json migrata nel data dir (originale preservato)" "OK"
        $acl2 = Test-AuthAcl -Path $srvFile
        if (-not $acl2.Ok) {
          Write-Host ("ACL post-migrazione da verificare: " + $acl2.Detail) -ForegroundColor Yellow
        }
      } else {
        Write-Host "Migrazione saltata: fai login diretto." -ForegroundColor Yellow
      }
      continue
    } else {
      Write-Host ""
      Write-Host "Si apre Pi usando la directory dati del server:" -ForegroundColor Cyan
      Write-Host (" " + $Paths.AgentDir)
      Write-Host "Esegui /login, completa l'autenticazione, poi esci da Pi."
      $oldDir = $null
      $hadOld = $false
      try { $hadOld = Test-Path Env:\PI_CODING_AGENT_DIR; if ($hadOld) { $oldDir = $env:PI_CODING_AGENT_DIR } } catch { }
      try {
        $env:PI_CODING_AGENT_DIR = $Paths.AgentDir
        & $piCmd
      } catch { }
      finally {
        try {
          if ($hadOld) { $env:PI_CODING_AGENT_DIR = $oldDir }
          else { Remove-Item Env:\PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue }
        } catch { }
      }
      L "Sessione Pi interattiva terminata, riverifico auth server dir" "INFO"
      continue
    }
  }
  L "Pi autenticato (verifica ufficiale auth check)" "OK"

        Complete-InstallStep -Name "secrets"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "secrets" -Label "8/11" -Title "Secrets e login Pi" -Err $_ -Attempt $attempt
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [9/11] Task =================
  Step "9/11" "Windows startup (2 tasks) + firewall"
  if ($script:StepSkip.tasks) { L "step 9/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "tasks"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $RemotePort = Resolve-RemotePort -AgentDir $Paths.AgentDir
  $action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($Paths.RunTask)`"" `
    -WorkingDirectory (Split-Path -Parent $Paths.Daemon)
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($null -ne $existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    L "task esistente rimossa (nessun duplicato)" "OK"
  }
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "PiServer 24/7 node (pi --mode rpc via pi-daemon.mjs)" | Out-Null
  L "task PiHomeServer registrata (SYSTEM, at-startup, restart-on-failure)" "OK"
  # Second task: the HTTP remote daemon. Separate process on purpose:
  # if Pi crashes, remote control (and its status answers) keeps working.
  $remoteAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($Paths.RunRemote)`"" `
    -WorkingDirectory (Split-Path -Parent $Paths.RemoteEntry)
  $remoteTask = $Paths.RemoteTaskName
  $existingRemote = Get-ScheduledTask -TaskName $remoteTask -ErrorAction SilentlyContinue
  if ($null -ne $existingRemote) {
    Unregister-ScheduledTask -TaskName $remoteTask -Confirm:$false
    L "remote task esistente rimossa (nessun duplicato)" "OK"
  }
  Register-ScheduledTask -TaskName $remoteTask -Action $remoteAction -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "PiServer remote API daemon (HMAC HTTP over Tailscale)" | Out-Null
  L "task PiRemoteServer registrata (SYSTEM, at-startup, restart-on-failure)" "OK"
  # Firewall: allow the remote port ONLY on the Tailscale interface.
  # The daemon binds the tailnet IP anyway (defense in depth, not the
  # primary enforcement). Best effort: a missing adapter only warns.
  try {
    Remove-NetFirewallRule -DisplayName "PiServer remote (Tailscale only)" -ErrorAction SilentlyContinue | Out-Null
    $tsNic = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.InterfaceDescription -match "Tailscale" } | Select-Object -First 1
    if ($null -ne $tsNic) {
      New-NetFirewallRule -DisplayName "PiServer remote (Tailscale only)" -Direction Inbound `
        -Protocol TCP -LocalPort $RemotePort -InterfaceAlias $tsNic.InterfaceAlias `
        -Action Allow -Profile Any | Out-Null
      L "firewall: porta $RemotePort solo su interfaccia Tailscale ($($tsNic.InterfaceAlias))" "OK"
    } else {
      L "firewall: adattatore Tailscale non trovato, regola saltata (il bind resta tailnet-only)" "WARN"
    }
  } catch {
    L "firewall: regola non creata ($($_.Exception.Message)); il bind resta tailnet-only" "WARN"
  }
  $startPortNum = 0
  try { if ($RemotePort -match "^\d+$") { $startPortNum = [int]$RemotePort } } catch { }
  $portGate = Clear-OwnPortListener -Port $startPortNum -Paths $Paths
  L ("porta " + $RemotePort + ": " + $portGate.Detail) "INFO"
  if (-not $portGate.Ok) { throw (New-StepError "System" ("Porta remote non avviabile: " + $portGate.Detail)) }
  try {
    Start-ScheduledTask -TaskName $TaskName
    Start-ScheduledTask -TaskName $remoteTask
    L "tasks avviati (verifico payload reale)" "OK"
  } catch {
    throw (New-StepError "System" "Registrati ma avvio fallito: $($_.Exception.Message)")
  }
  $w1 = Wait-TaskStartup -TaskName $TaskName -LauncherPath $Paths.RunTask -ProcessMatch "pi-daemon\.mjs" -LogPath $Paths.ServerLog -TimeoutSec 20
  if (-not $w1.Ok) { throw (New-StepError "System" $w1.Detail) }
  L $w1.Detail "OK"
  $w2 = Wait-TaskStartup -TaskName $remoteTask -LauncherPath $Paths.RunRemote -ProcessMatch "pi-remote-server" -LogPath $Paths.RemoteLog -TimeoutSec 20
  if (-not $w2.Ok) { throw (New-StepError "System" $w2.Detail) }
  L $w2.Detail "OK"

        Complete-InstallStep -Name "tasks"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "tasks" -Label "9/11" -Title "Windows startup (2 tasks) + firewall" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [10/11] Sleep =================
  Step "10/11" "Sleep settings"
  if ($script:StepSkip.sleep) { L "step 10/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "sleep"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  try {
    & powercfg /change standby-timeout-ac 0
    & powercfg /hibernate off
    L "sleep AC disabilitato + hibernate off" "OK"
  } catch {
    throw (New-StepError "System" "powercfg fallito: $($_.Exception.Message)")
  }

        Complete-InstallStep -Name "sleep"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "sleep" -Label "10/11" -Title "Sleep settings" -Err $_ -Attempt $attempt -AllowSkip
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= [11/11] Health =================
  Step "11/11" "Health check"
  if ($script:StepSkip.health) { L "step 11/11 gia OK (verificato), skip" "OK" }
  else {
    $script:InstallState.currentStep = "health"; Save-StepState
    $attempt = 0
    while ($true) {
      $attempt++
      try {
  $piCmd = Resolve-PiOrThrow "pi.cmd non risolvibile (step 3 saltato ma Pi assente). Riesegui senza resume o reinstalla Pi."
  Start-Sleep -Seconds 10
  $hc = Invoke-HealthCheck -Paths $Paths -PiBin $piCmd
  if (-not $hc.Ok) {
    $canRb = (($null -ne $appBackup) -and (Test-Path -LiteralPath $appBackup))
    if ($canRb) {
      L ("health check fallito (" + ($hc.Failures -join "; ") + "): ROLLBACK transazionale da " + $appBackup) "FAIL"
      $rbPortNum = 0
      try { if ($RemotePort -match "^\d+$") { $rbPortNum = [int]$RemotePort } } catch { }
      $rb = Invoke-AppRollback -Paths $Paths -BackupPath $appBackup -PiBin $piCmd -RemotePort $rbPortNum
      if (-not $rb.Ok) { throw (New-StepError "System" ("Update fallito, ROLLBACK FALLITO: " + $rb.Detail + ". Errori health: " + ($hc.Failures -join "; "))) }
      L ("rollback: " + $rb.Detail) "WARN"
      throw (New-StepError "System" ("Update fallito, rollback eseguito. " + $rb.Detail + " Errori health: " + ($hc.Failures -join "; ")))
    }
    throw (New-StepError "System" ("Health check fallito: " + ($hc.Failures -join "; ")))
  }
  L "health check OK" "OK"

        Complete-InstallStep -Name "health"
        break
      } catch {
        $dec = Resolve-StepFailure -Name "health" -Label "11/11" -Title "Health check" -Err $_ -Attempt $attempt
        if ($dec -eq "skip") { break }
      }
    }
  }

  # ================= HMAC once =================
  if ($hmacShowOnce -ne "") {
    $onceFile = Join-Path $Paths.Data "hmac-once.txt"
    $hmacShowOnce | Out-File -LiteralPath $onceFile -Encoding ascii -NoNewline
    & icacls $onceFile /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host ""
    Write-Host "HMAC generato (mostrato UNA volta, NON nel log). Copialo sul Mac:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    $hmacShowOnce"
    Write-Host ""
    Write-Host "Copia di sicurezza (ACL ristretta): $onceFile"
    Write-Host "ELIMINALO dopo aver configurato il Mac."
    Write-Host ""
    try { Start-Transcript -Path $Paths.InstallerTranscript -Append | Out-Null } catch { }
    L "HMAC mostrato una volta a schermo + hmac-once.txt (da eliminare)" "WARN"
  }

  Write-Host ""
  Write-Host "====================================" -ForegroundColor Green
  Write-Host "        SETUP COMPLETATO" -ForegroundColor Green
  Write-Host "====================================" -ForegroundColor Green
  L "SETUP COMPLETATO (mode=$Mode)" "OK"
  exit 0
} catch {
  try { Stop-Transcript | Out-Null } catch { }
  $msg = $_.Exception.Message
  Write-Host ""
  Write-Host "SETUP FALLITO" -ForegroundColor Red
  Write-Host "Motivo: $msg"
  try { L "SETUP FALLITO: $msg" "FAIL" } catch { }
  exit 1
}
