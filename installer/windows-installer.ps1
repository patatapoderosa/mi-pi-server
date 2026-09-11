<#
.SYNOPSIS
  Full Windows installer for the PiServer 24/7 node. Idempotent, with update
  and rollback. Must run elevated (self-elevates when launched directly).

.DESCRIPTION
  10 steps: Windows check, Node 22, Pi Coding Agent, pi-telegram, app deploy
  (release ZIP verified by SHA256), extension deploy, config, secrets,
  startup task, sleep settings, health check (fail closed).

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
  [string]$PayloadDir = "",
  [string]$InstallRoot = "C:\PiServer"
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
  try {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $elevArgs -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
  } catch {
    Fail "Auto-elevation rifiutata o fallita: $($_.Exception.Message)"
  }
}

try {
  Start-Transcript -Path $LogFile -Append | Out-Null
} catch {
  # Transcript is a bonus; Write-InstallLog still writes the file.
}

try {
  # ================= [1/10] Windows =================
  Step "1/10" "Controllo Windows"
  if (-not (Test-WindowsOS)) { Fail "Questo installer gira solo su Windows." }
  $os = Get-CimInstance Win32_OperatingSystem
  L "OS: $($os.Caption) build $($os.BuildNumber)" "OK"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {
    Fail "Impossibile abilitare TLS 1.2: $($_.Exception.Message)"
  }

  # ================= [2/10] Node =================
  Step "2/10" "Node.js 22"
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
      if ($null -eq $rel) { Fail "Nessuna release Node 22 trovata su nodejs.org." }
      $msiUrl = "https://nodejs.org/dist/$($rel.version)/node-$($rel.version)-x64.msi"
      $msi = Join-Path $env:TEMP ("node-{0}.msi" -f $rel.version)
      Invoke-WebRequest -Uri $msiUrl -OutFile $msi -TimeoutSec 300
      Start-Process msiexec.exe -ArgumentList @("/qn", "/i", "`"$msi`"") -Wait
      Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
      $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + $env:PATH
    }
    $v = & node -p "process.versions.node" 2>$null
    if (-not (Test-AtLeastNode22 -VersionString $v)) {
      Fail "Node.js >= 22 non disponibile dopo l'installazione (trovato: '$v')."
    }
    L "Node.js $v installato" "OK"
  }
  $NodeExe = Resolve-ToolPath "node"
  if ($null -eq $NodeExe) { Fail "node.exe non risolvibile dopo l'installazione." }

  # ================= [3/10] Pi =================
  Step "3/10" "Pi Coding Agent"
  $piCmd = Resolve-ToolPath "pi"
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
    if ($null -eq $npm) { Fail "npm non trovato (installazione Node incompleta?)." }
    & $npm install -g "@earendil-works/pi-coding-agent" --no-audit --no-fund
    $piCmd = Resolve-ToolPath "pi"
    if ($null -eq $piCmd) {
      # npm global bin may not be on PATH yet: probe default locations.
      foreach ($cand in @(
        (Join-Path $env:APPDATA "npm\pi.cmd"),
        "C:\Program Files\nodejs\pi.cmd",
        (Join-Path ${env:ProgramFiles} "nodejs\pi.cmd"))) {
        if (Test-Path -LiteralPath $cand) { $piCmd = $cand; break }
      }
    }
    if ($null -eq $piCmd) { Fail "Pi installato ma pi.cmd non trovato. Controlla il prefisso npm globale." }
    L "Pi installato: $piCmd" "OK"
  }
  $NpmGlobalBin = Split-Path -Parent $piCmd

  # ================= [4/10] pi-telegram =================
  Step "4/10" "pi-telegram"
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
      Fail "pi-telegram non risulta installato (pi list). Rete disponibile? Riesegui con -Update dopo 'pi install npm:@llblab/pi-telegram' manuale."
    }
    L "pi-telegram installato" "OK"
  }

  # ================= [5/10] App deploy =================
  Step "5/10" "Remote extension (deploy app)"
  $payload = $PayloadDir
  $tmpPayload = ""
  if ([string]::IsNullOrWhiteSpace($payload)) {
    $tmpRoot = Join-Path $env:TEMP ("piserver-dl-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    $tmpPayload = $tmpRoot
    $zipPath = Join-Path $tmpRoot "payload.zip"
    if ($SourceZip -ne "") {
      L "payload locale: $SourceZip"
      if (-not (Test-Path -LiteralPath $SourceZip)) { Fail "SourceZip non trovato: $SourceZip" }
      Copy-Item -LiteralPath $SourceZip -Destination $zipPath -Force
      if ($ExpectedSha256 -ne "") {
        if (-not (Test-FileChecksum -Path $zipPath -ExpectedSha256 $ExpectedSha256)) {
          Fail "Checksum dello ZIP locale non coincide (-ExpectedSha256). Abortito."
        }
        L "checksum ZIP locale OK" "OK"
      } else {
        L "ZIP locale senza checksum: verifica solo manifest (origine fidata dall'operatore)" "WARN"
      }
    } else {
      $dl = Get-ReleaseDownload -Repo $Repo -Version $Version
      L "download $($dl.ZipUrl)"
      Invoke-WebRequest -Uri $dl.ZipUrl -OutFile $zipPath -TimeoutSec 300
      $want = $ExpectedSha256
      if ([string]::IsNullOrWhiteSpace($want)) { $want = $dl.Sha256 }
      if ([string]::IsNullOrWhiteSpace($want)) {
        Fail "Nessun checksum disponibile per questa release (né -ExpectedSha256 né SHA256SUMS.txt). Fail closed: crea una release con SHA256SUMS.txt o passa -ExpectedSha256."
      }
      if (-not (Test-FileChecksum -Path $zipPath -ExpectedSha256 $want)) {
        Fail "Checksum release non coincide. File scartato (fail closed)."
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
    Fail ("Manifest incompleto, file mancanti: " + ($man.Missing -join ", "))
  }
  L "manifest payload OK" "OK"

  $appBackup = $null
  foreach ($d in @($Paths.Logs, $Paths.Data)) {
    if (-not (Test-Path -LiteralPath $d)) {
      New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
  }
  # Stage the new app FIRST: a failed copy must never leave live app/ half-written.
  # (On failure the previous app/ is untouched, so no rollback is needed here.)
  $stageNew = $Paths.App + ".new-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  if (Test-Path -LiteralPath $stageNew) {
    Remove-Item -LiteralPath $stageNew -Recurse -Force
  }
  New-Item -ItemType Directory -Path $stageNew -Force | Out-Null
  try {
    foreach ($sub in @("server", "shared", "installer")) {
      $src = Join-Path $payload $sub
      if (Test-Path -LiteralPath $src) {
        Copy-Item -Path (Join-Path $src "*") -Destination (Join-Path $stageNew $sub) -Recurse -Force
      }
    }
    $ver = $Version
    if ($ver -eq "latest") { $ver = "latest@$(Get-Date -Format 'yyyyMMdd')" }
    $ver | Out-File -LiteralPath (Join-Path $stageNew "VERSION") -Encoding ascii -NoNewline
  } catch {
    Remove-Item -LiteralPath $stageNew -Recurse -Force -ErrorAction SilentlyContinue
    throw "Deploy staging fallito (app esistente intatta): $($_.Exception.Message)"
  }
  if ((Test-Path -LiteralPath $Paths.App) -and ($Mode -eq "update")) {
    $appBackup = $Paths.App + ".backup-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    L "backup app -> $appBackup"
    Move-Item -LiteralPath $Paths.App -Destination $appBackup -Force
  } elseif (Test-Path -LiteralPath $Paths.App) {
    Remove-Item -LiteralPath $Paths.App -Recurse -Force
  }
  Move-Item -LiteralPath $stageNew -Destination $Paths.App -Force
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

  # runtime-env.json with absolute paths (SYSTEM-safe).
  @{
    NodeExe = $NodeExe
    PiBin = $piCmd
    NpmGlobalBin = $NpmGlobalBin
    DaemonScript = $Paths.Daemon
    AgentDir = $Paths.AgentDir
  } | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $Paths.RuntimeEnv -Encoding utf8
  L "runtime-env.json scritto (path assoluti)" "OK"

  if ($tmpPayload -ne "") {
    Remove-Item -LiteralPath $tmpPayload -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ================= [6/10] Config =================
  Step "6/10" "Config"
  $authPath = Join-Path $Paths.AgentDir "remote-auth.json"
  $authExists = Test-Path -LiteralPath $authPath
  $cid = $env:PI_CONTROL_BOT_ID
  $chat = $env:PI_CONTROL_CHAT_ID
  if (-not $authExists) {
    Write-Host "Serve il gruppo di controllo Telegram (vedi README: due bot + gruppo privato)."
    if ([string]::IsNullOrWhiteSpace($cid)) {
      $cid = Read-Host "ControlBot ID (numerico)"
    }
    if ([string]::IsNullOrWhiteSpace($chat)) {
      $chat = Read-Host "Chat ID gruppo di controllo (negativo)"
    }
    if ($cid -notmatch "^\d+$") { Fail "ControlBot ID deve essere numerico." }
    if ($chat -notmatch "^-?\d+$") { Fail "Chat ID deve essere numerico (negativo per i gruppi)." }
  }
  $authDefaults = @{
    allowedControlBotId = 0
    controlChatId = 0
    maxSkewSeconds = 300
    allowedServices = @("pi-server")
  }
  $st = Save-JsonConfigPreserving -Path $authPath -Defaults $authDefaults `
    -RequiredKeys @("allowedControlBotId", "controlChatId", "maxSkewSeconds", "allowedServices")
  if (-not $authExists) {
    $a = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    $a.allowedControlBotId = [long]$cid
    $a.controlChatId = [long]$chat
    $a | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $authPath -Encoding utf8
    L "remote-auth.json creata" "OK"
  } else {
    L "remote-auth.json: $st (config utente preservata)" "OK"
  }
  $coreDefaults = @{ maintenanceMode = $false; remoteControlEnabled = $true }
  $monDefaults = @{ enabled = $true; intervalMinutes = 30 }
  Save-JsonConfigPreserving -Path (Join-Path $Paths.ConfigDir "core.json") `
    -Defaults $coreDefaults -RequiredKeys @("maintenanceMode", "remoteControlEnabled") | Out-Null
  Save-JsonConfigPreserving -Path (Join-Path $Paths.ConfigDir "example-monitor.json") `
    -Defaults $monDefaults -RequiredKeys @("enabled", "intervalMinutes") | Out-Null
  L "server-config defaults OK (mai sovrascritti)" "OK"

  # ================= [7/10] Secrets =================
  Step "7/10" "Secrets e login Pi"
  L "--- step 7/10 (secrets+login)"
  if (-not (Test-Path -LiteralPath $Paths.SecretsDir)) {
    New-Item -ItemType Directory -Path $Paths.SecretsDir -Force | Out-Null
  }
  & icacls $Paths.SecretsDir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F" | Out-Null
  $tokFile = Join-Path $Paths.SecretsDir "server-bot-token"
  $hmacFile = Join-Path $Paths.SecretsDir "remote-hmac"
  $botToken = $env:PI_SERVER_BOT_TOKEN
  if (-not (Test-Path -LiteralPath $tokFile)) {
    if ([string]::IsNullOrWhiteSpace($botToken)) {
      $botToken = Read-HiddenInput -Prompt "ServerBot token (nascosto)"
    }
    if ([string]::IsNullOrWhiteSpace($botToken)) { Fail "ServerBot token obbligatorio." }
    $botToken | Out-File -LiteralPath $tokFile -Encoding ascii -NoNewline
    & icacls $tokFile /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
    L "server-bot-token scritto (ACL: SYSTEM+Administrators)" "OK"
  } else {
    L "server-bot-token esistente preservato" "OK"
  }
  $hmacShowOnce = ""
  if (-not (Test-Path -LiteralPath $hmacFile)) {
    $hmac = $env:PI_REMOTE_HMAC
    if ([string]::IsNullOrWhiteSpace($hmac)) {
      $hmac = Read-HiddenInput -Prompt "HMAC secret [INVIO = genera automaticamente] (nascosto)"
    }
    if ([string]::IsNullOrWhiteSpace($hmac)) {
      $hmac = New-RandomHex -Bytes 32
      $hmacShowOnce = $hmac
      L "HMAC generato (RNG crittografico)" "OK"
    }
    $hmac | Out-File -LiteralPath $hmacFile -Encoding ascii -NoNewline
    & icacls $hmacFile /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
    L "remote-hmac scritto (ACL: SYSTEM+Administrators)" "OK"
  } else {
    L "remote-hmac esistente preservato (nessuna rigenerazione)" "OK"
  }
  # telegram.json profile (token via file is preferred by the extension, but
  # pi-telegram itself reads telegram.json: keep both in sync, token redacted in logs).
  $tgJson = Join-Path $Paths.AgentDir "telegram.json"
  $ownerId = $env:PI_OWNER_ID
  if ([string]::IsNullOrWhiteSpace($ownerId)) {
    try {
      $old = Get-Content -LiteralPath $tgJson -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($null -ne $old.profiles -and $null -ne $old.profiles.default) {
        $ownerId = [string]$old.profiles.default.allowedUserId
      }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($ownerId) -or ($ownerId -eq "0")) {
      $ownerId = Read-Host "Owner Telegram user id (numerico, da @userinfobot)"
    }
  }
  if ($ownerId -notmatch "^\d+$") { Fail "Owner id deve essere numerico." }
  $tokNow = ""
  if (Test-Path -LiteralPath $tokFile) {
    $tokNow = (Get-Content -LiteralPath $tokFile -Raw).Trim()
  }
  if ($tokNow -eq "") { Fail "Token ServerBot illeggibile dopo la scrittura." }
  @{ profiles = @{ default = @{ botToken = $tokNow; allowedUserId = [long]$ownerId } } } |
    ConvertTo-Json -Depth 5 | Out-File -LiteralPath $tgJson -Encoding utf8
  L "telegram.json sincronizzato (token non stampato nei log)" "OK"

  # Token validity (getMe) without ever logging the token.
  try {
    $me = Invoke-RestMethod -Uri ("https://api.telegram.org/bot" + $tokNow + "/getMe") -TimeoutSec 20
    if ($null -eq $me.ok -or -not $me.ok) { throw "getMe ok=false" }
    L ("ServerBot getMe OK (id=" + $me.result.id + ")") "OK"
  } catch {
    Fail "ServerBot token non valido o rete assente: $($_.Exception.Message)"
  }

  # ---- Pi login (stesso step 7/10: niente credenziali = niente server) ----
  Write-Host ""
  Write-Host "[7/10 seguito] Autenticazione Pi" -ForegroundColor Cyan
  $env:PI_CODING_AGENT_DIR = $Paths.AgentDir
  $authOk = $false
  try {
    & $piCmd auth check 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $authOk = $true }
  } catch { }
  if (-not $authOk) {
    Write-Host ""
    Write-Host "[!] Pi richiede autenticazione provider." -ForegroundColor Yellow
    Write-Host "    Si aprira Pi: completa /login nel tuo browser/terminale, poi esci."
    try {
      & $piCmd
    } catch { }
    Write-Host "Premi INVIO quando hai terminato il login..."
    [void](Read-Host)
    # The interactive login above ran as YOU (user profile). Copy the
    # credentials into the service data dir so the SYSTEM task can use them.
    $userAuth = Join-Path (Join-Path $env:USERPROFILE ".pi\agent") "auth.json"
    $svcAuth = Join-Path $Paths.AgentDir "auth.json"
    if (-not (Test-Path -LiteralPath $svcAuth) -and (Test-Path -LiteralPath $userAuth)) {
      Copy-Item -LiteralPath $userAuth -Destination $svcAuth -Force
      & icacls $svcAuth /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
      L "auth.json copiato dal profilo utente al data dir" "OK"
    }
    try {
      & $piCmd auth check 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $authOk = $true }
    } catch { }
    if (-not $authOk) {
      Fail "Pi ancora senza credenziali (pi auth check fallisce). Completa /login e rilancia con -Update."
    }
  }
  L "Pi autenticato (pi auth check OK)" "OK"

  # ================= [8/10] Task =================
  Step "8/10" "Windows startup (Task Scheduler)"
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
  try {
    Start-ScheduledTask -TaskName $TaskName
    L "task avviata" "OK"
  } catch {
    Fail "Registrata ma avvio fallito: $($_.Exception.Message)"
  }

  # ================= [9/10] Sleep =================
  Step "9/10" "Sleep settings"
  try {
    & powercfg /change standby-timeout-ac 0
    & powercfg /hibernate off
    L "sleep AC disabilitato + hibernate off" "OK"
  } catch {
    Fail "powercfg fallito: $($_.Exception.Message)"
  }

  # ================= [10/10] Health =================
  Step "10/10" "Health check"
  Start-Sleep -Seconds 10
  $hc = Invoke-HealthCheck -Paths $Paths -PiBin $piCmd
  if (-not $hc.Ok) {
    if (($Mode -eq "update") -and ($null -ne $appBackup)) {
      L ("health check fallito (" + ($hc.Failures -join "; ") + "): ROLLBACK a " + $appBackup) "FAIL"
      if (Test-Path -LiteralPath $Paths.App) {
        Remove-Item -LiteralPath $Paths.App -Recurse -Force
      }
      Move-Item -LiteralPath $appBackup -Destination $Paths.App -Force
      # The extension copy in data/ already has NEW code: restore it from the old app too.
      $rbExt = Join-Path $Paths.ExtDir "pi-remote-config"
      if (Test-Path -LiteralPath $rbExt) { Remove-Item -LiteralPath $rbExt -Recurse -Force }
      Copy-Item -Path (Join-Path $Paths.App "server\pi-remote-config") -Destination $rbExt -Recurse -Force
      if (Test-Path -LiteralPath $Paths.SharedDir) { Remove-Item -LiteralPath $Paths.SharedDir -Recurse -Force }
      Copy-Item -Path (Join-Path $Paths.App "shared") -Destination $Paths.SharedDir -Recurse -Force
      try { Start-ScheduledTask -TaskName $TaskName } catch { }
      Fail ("Update fallito, rollback eseguito. Errori: " + ($hc.Failures -join "; "))
    }
    Fail ("Health check fallito: " + ($hc.Failures -join "; "))
  }
  L "health check OK" "OK"

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
    try { Start-Transcript -Path $LogFile -Append | Out-Null } catch { }
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
