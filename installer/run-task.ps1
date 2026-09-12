<#
.SYNOPSIS
  Task Scheduler launcher for the PiServer 24/7 node.
  Runs as SYSTEM: sets explicit env, PATH, log rotation, then starts pi-daemon.

.DESCRIPTION
  Invoked by the "PiHomeServer" scheduled task as:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PiServer\app\run-task.ps1"

  Why a wrapper instead of calling node.exe directly:
  - Scheduled-task actions cannot set environment variables. The daemon and Pi
    need PI_CODING_AGENT_DIR (SYSTEM has a different HOME) and PI_BIN plus a
    PATH that includes node.exe and the npm global bin (both user-scoped on a
    normal install, hence invisible to SYSTEM).
  - Task Scheduler does not capture stdout: we redirect to rotated log files.
  - All paths come from runtime-env.json (written at install time with
    absolute paths), never from PATH probing or the working directory.

  5.1 compatible. Writes only to C:\PiServer\logs. Never logs secrets.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $PSCommandPath
$EnvFile = Join-Path $AppDir "runtime-env.json"
$LogDir = Join-Path (Split-Path -Parent $AppDir) "logs"
$OutLog = Join-Path $LogDir "pi-server.log"
$ErrLog = Join-Path $LogDir "pi-server-error.log"
$MaxLogBytes = 25MB
$KeepRotations = 5

function Write-TaskLog {
  param([string]$Message, [string]$Level = "INFO")
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] [run-task] {2}" -f (Get-Date), $Level, $Message
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) {
      New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Add-Content -LiteralPath $OutLog -Value $line -Encoding UTF8
  } catch {
    # Last resort: event log would need a registered source; stdout is lost
    # under Task Scheduler, so there is nothing else useful to do here.
  }
}

function Rotate-Log {
  param([string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt $MaxLogBytes) { return }
    $oldest = "$Path.$KeepRotations"
    if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force }
    for ($i = $KeepRotations - 1; $i -ge 1; $i--) {
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
  if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-TaskLog "runtime-env.json missing at $EnvFile" "FAIL"
    exit 3
  }
  $env2 = Get-Content -LiteralPath $EnvFile -Raw | ConvertFrom-Json

  foreach ($field in @("NodeExe", "PiBin", "DaemonScript", "AgentDir")) {
    if ([string]::IsNullOrWhiteSpace($env2.$field)) {
      Write-TaskLog "runtime-env.json lacks field: $field" "FAIL"
      exit 3
    }
  }
  foreach ($p in @($env2.NodeExe, $env2.DaemonScript)) {
    if (-not (Test-Path -LiteralPath $p)) {
      Write-TaskLog "configured path missing: $p" "FAIL"
      exit 3
    }
  }

  $env:PI_CODING_AGENT_DIR = $env2.AgentDir
  $env:PI_BIN = $env2.PiBin
  $nodeDir = Split-Path -Parent $env2.NodeExe
  $npmBinDir = ""
  try { if (-not [string]::IsNullOrWhiteSpace($env2.NpmGlobalBin)) { $npmBinDir = $env2.NpmGlobalBin } } catch { }
  $parts = @($nodeDir)
  if ($npmBinDir -ne "") { $parts += $npmBinDir }
  $parts += $env:PATH
  $env:PATH = ($parts -join ";")

  Rotate-Log -Path $OutLog
  Rotate-Log -Path $ErrLog

  Write-TaskLog "starting pi-daemon (node=$(Split-Path -Leaf $env2.NodeExe), agentDir=$($env2.AgentDir))" "OK"

  # Foreground child: the task stays "Running" while node lives, and
  # Task Scheduler restart policy applies when this process exits.
  # stdout->pi-server.log, stderr->pi-server-error.log (append).
  $proc = Start-Process -FilePath $env2.NodeExe `
    -ArgumentList @("`"$($env2.DaemonScript)`"") `
    -WorkingDirectory (Split-Path -Parent $env2.DaemonScript) `
    -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog `
    -NoNewWindow -PassThru -Wait

  $code = $proc.ExitCode
  Write-TaskLog "pi-daemon exited with code $code" "WARN"
  exit $code
} catch {
  Write-TaskLog ("fatal: " + $_.Exception.Message) "FAIL"
  exit 1
}
