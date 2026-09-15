<#
.SYNOPSIS
  Stable task launcher: PiRemoteServer -> active release remote daemon (v0.3.0).

.DESCRIPTION
  Task Scheduler ALWAYS points here (C:\PiServer\bin\run-remote.ps1), never
  into a release dir. Resolves data\active-release.json (strict allowlist +
  canonical child check), loads machine facts from data\runtime-env.json and
  starts releases\<version>\server\pi-remote-server\index.ts in the
  foreground (Node type-stripping via stored NodeArgs). Invalid pointer =
  fail closed (exit 3), never guess a version.

  5.1 compatible. ASCII only. Writes only to ..\logs. Never logs secrets.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$BinDir = Split-Path -Parent $PSCommandPath
$RootDir = Split-Path -Parent $BinDir
$LogDir = Join-Path $RootDir "logs"
$OutLog = Join-Path $LogDir "remote-server.log"
$ErrLog = Join-Path $LogDir "remote-server-error.log"
$MaxLogBytes = 25MB
$KeepRotations = 5
$VersionRx = '^v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$'

function Write-RemoteLog {
  param([string]$Message, [string]$Level = "INFO")
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] [run-remote] {2}" -f (Get-Date), $Level, $Message
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) {
      New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Add-Content -LiteralPath $OutLog -Value $line -Encoding UTF8
  } catch { }
}

function Rotate-Log {
  param([string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-Item -LiteralPath $Path).Length -lt $MaxLogBytes) { return }
    $oldest = "$Path.$KeepRotations"
    if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force }
    for ($i = $KeepRotations - 1; $i -ge 1; $i--) {
      $src = "$Path.$i"
      if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination "$Path.$($i + 1)" -Force }
    }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
  } catch { }
}

function Fail-Closed {
  param([string]$Message)
  Write-RemoteLog $Message "FAIL"
  exit 3
}

try {
  $pointerPath = Join-Path $RootDir "data\active-release.json"
  if (-not (Test-Path -LiteralPath $pointerPath)) { Fail-Closed "active pointer missing: $pointerPath" }
  $pointer = (Get-Content -LiteralPath $pointerPath -Raw) | ConvertFrom-Json
  if ([int]$pointer.schemaVersion -ne 1) { Fail-Closed "active pointer schemaVersion unsupported" }
  $version = [string]$pointer.version
  if ($version -notmatch $VersionRx) { Fail-Closed "active pointer version rejected: $version" }
  $releasesBase = [System.IO.Path]::GetFullPath((Join-Path $RootDir "releases"))
  $releaseDir = [System.IO.Path]::GetFullPath((Join-Path $releasesBase $version))
  if ((Split-Path -Parent $releaseDir) -ne $releasesBase) { Fail-Closed "release traversal rejected: $version" }
  $entry = Join-Path $releaseDir "server\pi-remote-server\index.ts"
  if (-not (Test-Path -LiteralPath $entry)) { Fail-Closed "remote entry missing in release: $version" }

  $envPath = Join-Path $RootDir "data\runtime-env.json"
  if (-not (Test-Path -LiteralPath $envPath)) { $envPath = Join-Path $releaseDir "runtime-env.json" }
  if (-not (Test-Path -LiteralPath $envPath)) { Fail-Closed "runtime-env.json missing (data + release)" }
  $env2 = (Get-Content -LiteralPath $envPath -Raw) | ConvertFrom-Json
  foreach ($field in @("NodeExe", "AgentDir")) {
    if ([string]::IsNullOrWhiteSpace([string]$env2.$field)) { Fail-Closed "runtime-env.json lacks field: $field" }
  }
  if (-not (Test-Path -LiteralPath ([string]$env2.NodeExe))) { Fail-Closed "node missing: $($env2.NodeExe)" }

  $agentDir = [string]$env2.AgentDir
  if (-not (Test-Path -LiteralPath $agentDir)) {
    try { New-Item -ItemType Directory -Path $agentDir -Force | Out-Null }
    catch { Fail-Closed "cannot create agent dir: $agentDir" }
  }
  $env:PI_CODING_AGENT_DIR = $agentDir
  $nodeDir = Split-Path -Parent ([string]$env2.NodeExe)
  $env:PATH = $nodeDir + ";" + $env:PATH

  Rotate-Log -Path $OutLog
  Rotate-Log -Path $ErrLog

  Write-RemoteLog "starting pi-remote-server release=$version" "OK"

  $allArgs = @()
  try { foreach ($a in @($env2.NodeArgs)) { if (-not [string]::IsNullOrWhiteSpace([string]$a)) { $allArgs += [string]$a } } } catch { }
  $allArgs += "`"$entry`""
  $proc = Start-Process -FilePath ([string]$env2.NodeExe) `
    -ArgumentList $allArgs `
    -WorkingDirectory (Split-Path -Parent $entry) `
    -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog `
    -NoNewWindow -PassThru -Wait

  $code = $proc.ExitCode
  Write-RemoteLog "pi-remote-server exited with code $code (release=$version)" "WARN"
  exit $code
} catch {
  Write-RemoteLog ("fatal: " + $_.Exception.Message) "FAIL"
  exit 1
}
