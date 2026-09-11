<#
.SYNOPSIS
  One-click setup of the 24/7 Pi node on Windows 10/11.

.DESCRIPTION
  Native-Windows approach (no WSL required):
  - Node.js 22 LTS via winget (fallback: manual download URL)
  - Pi Coding Agent + @llblab/pi-telegram via npm / pi package
  - pi-remote-config extension copied next to this repo (no symlinks: they
    need elevated privileges; a copy is robust — re-run to refresh)
  - Secrets in %APPDATA%\pi-remote\... no: in $env:USERPROFILE\.pi\agent\secrets
    with a restricted ACL (current user only)
  - Startup WITHOUT login via Task Scheduler (logon-independent task running
    `node pi-daemon.mjs`, which supervises `pi --mode rpc`)
  - PM2 is intentionally NOT used on Windows: Task Scheduler is the native,
    login-independent supervisor and avoids an extra npm service layer.
  - Sleep/hibernate off via powercfg.

  Idempotent: re-runnable, existing configs are backed up before overwrite.
  Run from an ELEVATED PowerShell (right click -> Run as administrator) for
  the Task Scheduler + powercfg steps; other steps work unprivileged.
#>

# NOTE (2026-09): for a clean Windows PC prefer the one-command installer:
#   irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 | iex
# See README.md + docs/INSTALL.md (Windows section). This script remains for
# manual installs from an existing repo checkout. Known limitation kept
# intentionally: the scheduled task below runs as SYSTEM, whose profile
# (systemprofile) does NOT see the installing user's %USERPROFILE%\.pi\agent,
# so Pi-as-SYSTEM misses config/secrets/extension. Use installer/ for the
# SYSTEM-safe C:\PiServer layout with explicit PI_CODING_AGENT_DIR.
[CmdletBinding()]
param(
  [string]$SystemDir = (Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
  [string]$AgentDir = (Join-Path $env:USERPROFILE ".pi\agent")
)

$ErrorActionPreference = "Stop"

function Info([string]$m)  { Write-Host "[setup] $m" -ForegroundColor Green }
function WarnM([string]$m) { Write-Host "[setup] $m" -ForegroundColor Yellow }
function Fatal([string]$m) { Write-Host "[setup] $m" -ForegroundColor Red; exit 1 }

function Backup-IfExists([string]$Path) {
  if (Test-Path $Path) {
    $bak = "$Path.bak-$(Get-Date -Format 'yyyyMMddTHHmmssZ')"
    Copy-Item $Path $bak -Force
    Info "backup: $Path -> $bak"
  }
}

function Read-Hidden([string]$Prompt) {
  $s = Read-Host -Prompt $Prompt -AsSecureString
  return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}

$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) { WarnM "not elevated: Task Scheduler + powercfg steps will need an admin shell" }

# ------------------------------------------------------------- Node ---
Info "step 1: Node.js >= 22"
$nodeOk = $false
try { $v = node -p "process.versions.node.split('.')[0]"; if ([int]$v -ge 22) { $nodeOk = $true } } catch {}
if (-not $nodeOk) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Info "installing Node.js 22 LTS via winget"
    winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                 [Environment]::GetEnvironmentVariable("Path", "User")
  } else {
    Fatal "winget not found. Install Node.js 22 LTS from https://nodejs.org then re-run."
  }
}
node --version

# ----------------------------------------------------------------- pi ---
Info "step 2: Pi Coding Agent"
if (Get-Command pi -ErrorAction SilentlyContinue) { Info "pi already installed: $(pi --version)" }
else { npm install -g @earendil-works/pi-coding-agent }
pi --version

# -------------------------------------------------------- pi-telegram ---
Info "step 3: @llblab/pi-telegram package"
$listed = (pi list 2>$null | Out-String)
if ($listed -match "pi-telegram") { Info "pi-telegram already installed" }
else {
  try { pi install "npm:@llblab/pi-telegram" }
  catch { WarnM "automatic install failed — run manually: pi install npm:@llblab/pi-telegram" }
}

# --------------------------------------------------------------- dirs ---
Info "step 4: directories"
$ExtDir    = Join-Path $AgentDir "extensions"
$ConfigDir = Join-Path $AgentDir "server-config"
$Secrets   = Join-Path $AgentDir "secrets"
$LogDir    = Join-Path $AgentDir "logs"
@($AgentDir, $ExtDir, $ConfigDir, $Secrets, $LogDir) | ForEach-Object {
  if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ | Out-Null }
}
# Restrict secrets dir to current user (0600/0700 equivalent)
icacls $Secrets /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null

# ------------------------------------------------------ hidden inputs ---
Info "steps 5-7: Telegram identities (see docs/INSTALL.md for the bot-to-bot group)"
$botToken = $env:PI_SERVER_BOT_TOKEN
if (-not $botToken) { $botToken = Read-Hidden "ServerBot token (hidden)" }
if (-not $botToken) { Fatal "ServerBot token is required" }

$ownerId = $env:PI_OWNER_ID
if (-not $ownerId) { $ownerId = Read-Host "Owner Telegram user id (digits, from @userinfobot)" }
if ($ownerId -notmatch '^\d+$') { Fatal "owner id must be numeric" }

$controlBotId = $env:PI_CONTROL_BOT_ID
if (-not $controlBotId) { $controlBotId = Read-Host "ControlBot numeric id" }
if ($controlBotId -notmatch '^\d+$') { Fatal "control bot id must be numeric" }

$controlChatId = $env:PI_CONTROL_CHAT_ID
if (-not $controlChatId) { $controlChatId = Read-Host "Control group chat id (negative number)" }
if ($controlChatId -notmatch '^-?\d+$') { Fatal "control chat id must be numeric" }

$hmac = $env:PI_REMOTE_HMAC
if (-not $hmac) { $hmac = Read-Hidden "HMAC secret (ENTER to generate random)" }
if (-not $hmac) {
  $hmac = ([BitConverter]::ToString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(32))).Replace("-", "").ToLower()
  Info "generated random HMAC — store the SAME value on the Mac Keychain via mac/setup-mac.sh"
  Write-Host ""
  Write-Host "    HMAC (copy now, shown once): $hmac"
  Write-Host ""
}

# ------------------------------------------------------------ secrets ---
Info "step 8: secret files (restricted ACL)"
$botToken | Out-File -NoNewline -Encoding ascii (Join-Path $Secrets "server-bot-token")
$hmac     | Out-File -NoNewline -Encoding ascii (Join-Path $Secrets "remote-hmac")
icacls (Join-Path $Secrets "server-bot-token") /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
icacls (Join-Path $Secrets "remote-hmac") /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null

# -------------------------------------------------------- telegram.json ---
Info "step 9: telegram.json"
$tgJson = Join-Path $AgentDir "telegram.json"
Backup-IfExists $tgJson
$tg = @{}
if (Test-Path $tgJson) { $tg = Get-Content $tgJson -Raw | ConvertFrom-Json -AsHashtable }
if (-not $tg.profiles) { $tg.profiles = @{} }
$tg.profiles["default"] = @{ botToken = $botToken; allowedUserId = [long]$ownerId }
$tg | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 $tgJson

# ------------------------------------------------------ remote-auth.json ---
Info "step 10: remote-auth.json"
$authJson = Join-Path $AgentDir "remote-auth.json"
Backup-IfExists $authJson
@{
  allowedControlBotId = [long]$controlBotId
  controlChatId       = [long]$controlChatId
  maxSkewSeconds      = 300
  allowedServices     = @("pi-server")
} | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $authJson

# ---------------------------------------------------- server-config/... ---
Info "step 11: server-config defaults"
$core = Join-Path $ConfigDir "core.json"
if (-not (Test-Path $core)) {
  @{ maintenanceMode = $false; remoteControlEnabled = $true } | ConvertTo-Json | Out-File -Encoding utf8 $core
} else { Info "kept existing $core" }
$mon = Join-Path $ConfigDir "example-monitor.json"
if (-not (Test-Path $mon)) {
  @{ enabled = $true; intervalMinutes = 30 } | ConvertTo-Json | Out-File -Encoding utf8 $mon
} else { Info "kept existing $mon" }

# ------------------------------------------------------------- extension ---
Info "step 12: pi-remote-config extension (copy, refresh on re-run)"
$src = Join-Path $SystemDir "server\pi-remote-config"
if (-not (Test-Path $src)) { $src = Join-Path $SystemDir "server/pi-remote-config" }
if (-not (Test-Path $src)) { Fatal "extension source missing under $SystemDir" }
$dst = Join-Path $ExtDir "pi-remote-config"
if (Test-Path $dst) { Backup-IfExists (Join-Path $ConfigDir "core.json"); Remove-Item $dst -Recurse -Force }
Copy-Item $src $dst -Recurse
# The extension imports ../../shared/*.ts, which from $dst resolves to
# $AgentDir/shared: mirror it or the extension fails to load (this was
# previously broken: $sharedDst was computed but never copied).
$sharedSrc = Join-Path $SystemDir "shared"
if (-not (Test-Path $sharedSrc)) { Fatal "shared source missing under $SystemDir" }
$sharedDst = Join-Path $ExtDir "..\shared"
if (Test-Path $sharedDst) { Remove-Item $sharedDst -Recurse -Force }
Copy-Item $sharedSrc $sharedDst -Recurse
Info "extension copied to $dst"

# --------------------------------------------------- scheduled task ---
Info "step 13: Task Scheduler (start at boot, no login required)"
$daemon = Join-Path $SystemDir "server\pi-daemon.mjs"
if (-not (Test-Path $daemon)) { $daemon = Join-Path $SystemDir "server/pi-daemon.mjs" }
$nodeExe = (Get-Command node).Source
$action = New-ScheduledTaskAction -Execute $nodeExe -Argument "`"$daemon`"" `
  -WorkingDirectory (Split-Path $daemon)
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit 0
try {
  if (Get-ScheduledTask -TaskName "PiServer" -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName "PiServer" -Confirm:$false
  }
  Register-ScheduledTask -TaskName "PiServer" -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "24/7 Pi Coding Agent node (pi --mode rpc via pi-daemon.mjs)" | Out-Null
  Start-ScheduledTask -TaskName "PiServer"
  Info "PiServer task registered and started"
} catch {
  Fatal "Task Scheduler setup failed (elevated shell required): $($_.Exception.Message)"
}

# ------------------------------------------------------ sleep/hibernate ---
Info "step 14: disable sleep/hibernate"
try {
  powercfg /change standby-timeout-ac 0
  powercfg /change standby-timeout-dc 0
  powercfg /hibernate off
  Info "sleep/hibernate disabled"
} catch { WarnM "powercfg failed: $($_.Exception.Message)" }

# --------------------------------------------------------------- verify ---
Info "step 15: verification"
Start-Sleep -Seconds 8
Get-ScheduledTask -TaskName "PiServer" | Select-Object TaskName, State | Format-Table | Out-String | Write-Host
try {
  $me = Invoke-RestMethod -Uri "https://api.telegram.org/bot$botToken/getMe" -TimeoutSec 15
  Info "ServerBot getMe ok: @$(($me.result).username)"
} catch { WarnM "getMe failed — check token + network" }

Write-Host ""
Write-Host "================ DONE ================" -ForegroundColor Green
Write-Host "Remaining once-only steps:"
Write-Host "  1. Pair Telegram: run `pi`, then /telegram-setup (if needed) + /telegram-connect"
Write-Host "  2. Phone: open the ServerBot DM and pair."
Write-Host "  3. Both bots: bot-to-bot mode ON (@BotFather), both admins in the control group."
Write-Host "  4. Mac: run mac/setup-mac.sh (ControlBot token + SAME HMAC)."
Write-Host "  5. Reboot test: the PiServer task must be Running with no login."
Write-Host "NOTE: the extension was COPIED (Windows-safe). Re-run this script"
Write-Host "after `git pull` to refresh the copy."
