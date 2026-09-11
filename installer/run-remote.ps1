<#
.SYNOPSIS
  Task Scheduler launcher for the pi-remote-server HTTP daemon.
  Runs as SYSTEM: sets explicit env, PATH, log rotation, then starts node.

.DESCRIPTION
  Invoked by the "PiRemoteServer" scheduled task as either:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PiServer\app\run-remote.ps1"
  (C:\PiServer layout: everything resolves from runtime-env.json next to
  this script), or with explicit args (repo-checkout layout used by the
  legacy server/setup-old-pc.ps1):
    -File run-remote.ps1 -AgentDir <agentDir> -EntryScript <index.ts path>
      -NodeExe <node.exe path> -LogDir <logs dir> [-NodeArgs <extra node args>]

  Why a wrapper instead of calling node.exe directly:
  - Scheduled-task actions cannot set environment variables. The daemon needs
    PI_CODING_AGENT_DIR (SYSTEM has a different HOME) and a PATH that includes
    node.exe (invisible to SYSTEM on user-scoped installs).
  - Task Scheduler does not capture stdout: we redirect to a rotated log file.
  - The daemon entry is TypeScript run via Node type-stripping; -NodeArgs
    carries "--experimental-strip-types" on Node builds that still need the
    flag (probed once at install time, stored in runtime-env.json).

  5.1 compatible. Writes only to the configured logs dir. Never logs secrets.
#>
[CmdletBinding()]
param(
  [string]$AgentDir = "",
  [string]$EntryScript = "",
  [string]$NodeExe = "",
  [string]$LogDir = "",
  [string[]]$NodeArgs = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $PSCommandPath
$EnvFile = Join-Path $AppDir "runtime-env.json"

function Write-RemoteLog([string]$Message, [string]$Level = "INFO") {
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] [run-remote] {2}" -f (Get-Date), $Level, $Message
  try {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
      New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    Add-Content -LiteralPath (Join-Path $script:LogDir "remote-server.log") -Value $line -Encoding UTF8
  } catch {
    # Last resort: stdout is lost under Task Scheduler; nothing else to do.
  }
}

function Rotate-RemoteLog([string]$Path) {
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $MaxBytes = 25MB
    if ((Get-Item -LiteralPath $Path).Length -lt $MaxBytes) { return }
    for ($i = 4; $i -ge 1; $i--) {
      $src = "$Path.$i"
      if (Test-Path -LiteralPath $src) {
        Move-Item -LiteralPath $src -Destination "$Path.$($i + 1)" -Force
      }
    }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
  } catch {
    # Rotation is best-effort; never block startup.
  }
}

try {
  if ([string]::IsNullOrWhiteSpace($AgentDir) -or
      [string]::IsNullOrWhiteSpace($EntryScript) -or
      [string]::IsNullOrWhiteSpace($NodeExe)) {
    # C:\PiServer layout: resolve everything from runtime-env.json.
    if (-not (Test-Path -LiteralPath $EnvFile)) {
      Write-RemoteLog "runtime-env.json missing at $EnvFile (and no explicit args)" "FAIL"
      exit 3
    }
    $env2 = Get-Content -LiteralPath $EnvFile -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($AgentDir)) { $AgentDir = [string]$env2.AgentDir }
    if ([string]::IsNullOrWhiteSpace($EntryScript)) {
      $EntryScript = Join-Path (Join-Path $AppDir "server") "pi-remote-server\index.ts"
      if (-not (Test-Path -LiteralPath $EntryScript)) {
        $EntryScript = Join-Path $AppDir "server\pi-remote-server\index.ts"
      }
    }
    if ([string]::IsNullOrWhiteSpace($NodeExe)) { $NodeExe = [string]$env2.NodeExe }
    if ($NodeArgs.Count -eq 0 -and $null -ne $env2.NodeArgs) {
      $NodeArgs = @($env2.NodeArgs | ForEach-Object { [string]$_ })
    }
    if ([string]::IsNullOrWhiteSpace($LogDir)) {
      $LogDir = Join-Path (Split-Path -Parent $AppDir) "logs"
    }
  }
  $script:LogDir = $LogDir

  foreach ($f in @("AgentDir", "EntryScript", "NodeExe")) {
    $v = Get-Variable -Name $f -ValueOnly
    if ([string]::IsNullOrWhiteSpace($v)) {
      Write-RemoteLog "missing required value: $f" "FAIL"
      exit 3
    }
  }
  foreach ($p in @($NodeExe, $EntryScript)) {
    if (-not (Test-Path -LiteralPath $p)) {
      Write-RemoteLog "configured path missing: $p" "FAIL"
      exit 3
    }
  }
  if (-not (Test-Path -LiteralPath $AgentDir)) {
    try { New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null }
    catch { Write-RemoteLog "cannot create agent dir: $AgentDir" "FAIL"; exit 3 }
  }

  $env:PI_CODING_AGENT_DIR = $AgentDir
  $nodeDir = Split-Path -Parent $NodeExe
  $env:PATH = $nodeDir + ";" + $env:PATH

  Rotate-RemoteLog -Path (Join-Path $LogDir "remote-server.log")

  Write-RemoteLog "starting pi-remote-server" "OK"

  # Foreground child: the task stays "Running" while node lives, and
  # Task Scheduler restart policy applies when this process exits.
  $allArgs = @() + $NodeArgs + @($EntryScript)
  $proc = Start-Process -FilePath $NodeExe -ArgumentList $allArgs -WorkingDirectory (Split-Path -Parent $EntryScript) -RedirectStandardOutput (Join-Path $LogDir "remote-server.log") -RedirectStandardError (Join-Path $LogDir "remote-server-error.log") -NoNewWindow -PassThru -Wait

  $code = $proc.ExitCode
  Write-RemoteLog "pi-remote-server exited with code $code" "WARN"
  exit $code
} catch {
  try { Write-RemoteLog ("fatal: " + $_.Exception.Message) "FAIL" } catch { }
  exit 1
}