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
  Start-Transcript -Path $LogFile -Append | Out-Null
} catch {
  # Transcript is a bonus; Write-InstallLog still writes the file.
}

try {
  # ================= [1/11] Windows =================
  Step "1/11" "Controllo Windows"
  if (-not (Test-WindowsOS)) { Fail "Questo installer gira solo su Windows." }
  $os = Get-CimInstance Win32_OperatingSystem
  L "OS: $($os.Caption) build $($os.BuildNumber)" "OK"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {
    Fail "Impossibile abilitare TLS 1.2: $($_.Exception.Message)"
  }

  # ================= [2/11] Node =================
  Step "2/11" "Node.js 22"
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

  # ================= [3/11] Pi =================
  Step "3/11" "Pi Coding Agent"
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

  # ================= [4/11] pi-telegram =================
  Step "4/11" "pi-telegram"
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

  # ================= [5/11] Tailscale =================
  Step "5/11" "Tailscale (private network)"
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
    if ($null -eq $tsExe -or (-not (Test-Path -LiteralPath $tsExe))) { Fail "Tailscale installato ma tailscale.exe non trovato." }
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
    if (-not $tsUp) { Fail "Tailscale non connesso (tailscale status fallisce). Rilancia con -Update dopo il login." }
  }
  $tsIp = ""
  try { $tsIp = ((& $tsExe ip -4 2>$null | Out-String).Trim().Split("`n")[0]).Trim() } catch { }
  if ($tsIp -notmatch "^100\.(6[4-9]|[78]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}$") {
    Fail "IP Tailscale non valido o assente. Verifica tailscale status."
  }
  L "tailnet OK (this node: $tsIp)" "OK"

  # ================= [6/11] App deploy =================
  Step "6/11" "Remote extension (deploy app)"
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
  if (-not $stripped) { Fail "Node cannot type-check the remote daemon entry (node --check failed). Upgrade Node 22." }
  L "node type-stripping: $(if ($nodeStripArgs.Count -eq 0) { 'native (no flag)' } else { $nodeStripArgs -join ' ' })" "OK"

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

  # ================= [7/11] Config =================
  Step "7/11" "Config (remote-server.json, no Telegram IDs anymore)"
  $serverCfgPath = Join-Path $Paths.AgentDir "remote-server.json"
  $serverCfgExists = Test-Path -LiteralPath $serverCfgPath
  $portRaw = $env:PI_REMOTE_PORT
  if (-not $serverCfgExists) {
    if ([string]::IsNullOrWhiteSpace($portRaw)) {
      $portRaw = Read-Host "Remote API port [43128]"
      if ([string]::IsNullOrWhiteSpace($portRaw)) { $portRaw = "43128" }
    }
    if ($portRaw -notmatch "^\d+$" -or [int]$portRaw -lt 1 -or [int]$portRaw -gt 65535) {
      Fail "Port must be 1-65535."
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
  $RemotePort = ([string](Get-Content -LiteralPath $serverCfgPath -Raw | ConvertFrom-Json).port)
  if ($RemotePort -notmatch "^\d+$") { $RemotePort = "43128" }
  L "remote API port: $RemotePort" "OK"

  # ================= [8/11] Secrets =================
  Step "8/11" "Secrets e login Pi"
  L "--- step 8/11 (secrets+login)"
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

  # ---- Pi login (same step 8/11: no credentials = no server) ----
  Write-Host ""
  Write-Host "[8/11 seguito] Autenticazione Pi" -ForegroundColor Cyan
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

  # ================= [9/11] Task =================
  Step "9/11" "Windows startup (2 tasks) + firewall"
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
  try {
    Start-ScheduledTask -TaskName $TaskName
    Start-ScheduledTask -TaskName $remoteTask
    L "tasks avviati" "OK"
  } catch {
    Fail "Registrati ma avvio fallito: $($_.Exception.Message)"
  }

  # ================= [10/11] Sleep =================
  Step "10/11" "Sleep settings"
  try {
    & powercfg /change standby-timeout-ac 0
    & powercfg /hibernate off
    L "sleep AC disabilitato + hibernate off" "OK"
  } catch {
    Fail "powercfg fallito: $($_.Exception.Message)"
  }

  # ================= [11/11] Health =================
  Step "11/11" "Health check"
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
      try { Start-ScheduledTask -TaskName $Paths.RemoteTaskName } catch { }
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
