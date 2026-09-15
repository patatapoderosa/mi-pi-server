<#
.SYNOPSIS
  Stable doctor entry point (v0.3.0): diagnose [-Repair] [-Json].

.DESCRIPTION
  Thin wrapper over installer\PiServerDoctor.ps1 in the ACTIVE release.
  Default prints a human summary + writes data\doctor-report.json.
  -Repair runs allowlist self-heal behind the circuit breaker.
  -Json emits the structured report on stdout (for the remote daemon).
  Exit 0 healthy / 1 degraded-or-repaired / 2 unhealthy-or-manual /
  3 fail-closed.

  5.1 compatible. ASCII only. Logs to ..\logs\doctor.log. Never logs secrets.
#>
[CmdletBinding()]
param(
  [switch]$Repair,
  [switch]$Json,
  [string]$Root = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$BinDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $BinDir }
$LogFile = Join-Path $Root "logs\doctor.log"

function Write-DoctorLog {
  param([string]$Message, [string]$Level = "INFO")
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] [doctor] {2}" -f (Get-Date), $Level, $Message
  try {
    $ld = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $ld)) { New-Item -ItemType Directory -Path $ld -Force | Out-Null }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  } catch { }
}

try {
  $libBase = Join-Path $BinDir "PiServerLib.ps1"
  $updateLib = Join-Path $BinDir "PiServerUpdate.ps1"
  $doctorLib = Join-Path $BinDir "PiServerDoctor.ps1"
  if (-not (Test-Path -LiteralPath $libBase)) { $libBase = Join-Path $Root "installer\PiServerLib.ps1" }
  if (-not (Test-Path -LiteralPath $updateLib)) { $updateLib = Join-Path $Root "installer\PiServerUpdate.ps1" }
  if (-not (Test-Path -LiteralPath $doctorLib)) { $doctorLib = Join-Path $Root "installer\PiServerDoctor.ps1" }
  foreach ($lf in @($libBase, $updateLib, $doctorLib)) {
    if (-not (Test-Path -LiteralPath $lf)) { throw ("libreria assente: " + $lf) }
    . $lf
  }
} catch {
  Write-DoctorLog ("librerie indisponibili: " + $_.Exception.Message) "FAIL"
  exit 3
}

try {
  $Paths = Get-PiServerPaths -Root $Root
  if ($Repair) {
    $startHook = {
      param($p)
      foreach ($tn in @($p.TaskName, $p.RemoteTaskName)) {
        try { Start-ScheduledTask -TaskName $tn -ErrorAction Stop } catch { }
      }
      $deadline = [DateTime]::UtcNow.AddSeconds(30)
      $seen = ""
      while ([DateTime]::UtcNow -lt $deadline) {
        $states = @()
        foreach ($tn in @($p.TaskName, $p.RemoteTaskName)) {
          try { $states += [string](Get-ScheduledTask -TaskName $tn -ErrorAction Stop).State } catch { $states += "missing" }
        }
        $seen = ($states -join ",")
        if (($states[0] -eq "Running") -and ($states[1] -eq "Running")) { break }
        Start-Sleep -Seconds 2
      }
      if ($seen -ne "Running,Running") { return @{ Ok = $false; Detail = ("tasks non Running dopo start: " + $seen) } }
      return @{ Ok = $true; Detail = "tasks avviati e Running" }
    }
    $res = Invoke-DoctorRepair -Paths $Paths -StartRuntime $startHook
    Write-DoctorLog ("repair: " + ($res.Repaired -join ",") + " | " + $res.Detail) (& { if ($res.Ok) { "OK" } else { "FAIL" } })
    if ($Json) {
      ([ordered]@{ schemaVersion = 1; repaired = @($res.Repaired); detail = $res.Detail } | ConvertTo-Json -Depth 4) | Write-Output
    } else {
      Write-Output ("repair: " + ($res.Repaired -join ", "))
      Write-Output $res.Detail
    }
    if ($res.Ok) { exit 1 }
    exit 2
  }
  $doc = Invoke-ServerDoctor -Paths $Paths
  Write-DoctorLog ("diagnosi: " + $doc.Status + " (" + $doc.Checks.Count + " checks)") (& { if ($doc.Status -eq "healthy") { "OK" } else { "WARN" } })
  if ($Json) {
    ([ordered]@{ schemaVersion = 1; status = $doc.Status; checks = @($doc.Checks) } | ConvertTo-Json -Depth 6) | Write-Output
  } else {
    Write-Output ("status: " + $doc.Status)
    foreach ($c in $doc.Checks) {
      $mark = "[ok]"
      if (-not $c.ok) { $mark = "[KO:" + $c.severity + "]" }
      Write-Output ("  " + $mark + " " + $c.name + " :: " + $c.detail)
    }
  }
  if ($doc.Status -eq "healthy") { exit 0 }
  if ($doc.Status -eq "degraded") { exit 1 }
  exit 2
} catch {
  Write-DoctorLog ("fatal: " + $_.Exception.Message) "FAIL"
  exit 1
}
