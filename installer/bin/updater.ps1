<#
.SYNOPSIS
  Stable updater entry point (v0.3.0): update/status/rollback/recover.

.DESCRIPTION
  Thin wrapper over installer\PiServerUpdate.ps1 in the ACTIVE release.
  Actions (enum, never arbitrary code):
    status   - pointer + installed releases + pending transaction (read-only)
    update   - full pointer-based update to -Version (needs -StagingDir with
               a downloaded+extracted payload; download stays in the caller)
    rollback - pointer rollback to previousVersion from update-state
    recover  - deterministic crash recovery for an interrupted update
  Real Windows primitives (tasks/services/ports) are wired here; the engine
  stays injectable for tests. Exit 0 on success, 1 on failure, 2 when manual
  intervention is required, 3 on fail-closed validation.

  5.1 compatible. ASCII only. Logs to ..\logs\updater.log. Never logs secrets.
#>
[CmdletBinding()]
param(
  [string]$Action = "status",
  [string]$Version = "",
  [string]$StagingDir = "",
  [string]$Root = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$BinDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $BinDir }
$LogFile = Join-Path $Root "logs\updater.log"

function Write-UpdaterLog {
  param([string]$Message, [string]$Level = "INFO")
  $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] [updater] {2}" -f (Get-Date), $Level, $Message
  try {
    $ld = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $ld)) { New-Item -ItemType Directory -Path $ld -Force | Out-Null }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  } catch { }
}

try {
  $libBase = Join-Path $BinDir "PiServerLib.ps1"
  $updateLib = Join-Path $BinDir "PiServerUpdate.ps1"
  if (-not (Test-Path -LiteralPath $libBase)) { $libBase = Join-Path $Root "installer\PiServerLib.ps1" }
  $ptrProbe = Read-ActiveRelease -PointerPath (Join-Path $Root "data\active-release.json") 2>$null
  $activeLib = ""
  if ($ptrProbe.Ok) {
    $cand = Join-Path $Root ("releases\" + $ptrProbe.Version + "\installer\PiServerUpdate.ps1")
    if (Test-Path -LiteralPath $cand) { $activeLib = $cand }
  }
  if ($activeLib -ne "") { $updateLib = $activeLib }
  elseif (-not (Test-Path -LiteralPath $updateLib)) { $updateLib = Join-Path $Root "installer\PiServerUpdate.ps1" }
  if (-not (Test-Path -LiteralPath $libBase)) { throw "PiServerLib.ps1 assente" }
  if (-not (Test-Path -LiteralPath $updateLib)) { throw "PiServerUpdate.ps1 assente" }
  . $libBase
  . $updateLib
} catch {
  Write-UpdaterLog ("librerie indisponibili: " + $_.Exception.Message) "FAIL"
  exit 3
}

try {
  $Paths = Get-PiServerPaths -Root $Root
  $Action = $Action.ToLowerInvariant()
  switch ($Action) {
    "status" {
      $ptr = Read-ActiveRelease -PointerPath $Paths.ActivePointer
      $installed = Get-InstalledReleases -ReleasesRoot $Paths.Releases
      $stu = Read-UpdateState -StatePath $Paths.UpdateState
      $obj = [ordered]@{
        schemaVersion = 1
        active = (& { if ($ptr.Ok) { $ptr.Version } else { "" } })
        activeOk = $ptr.Ok
        installed = @($installed)
        pendingTransaction = (& { if ($stu.Found -and (-not $stU.Corrupt)) { $stu.State } else { $null } })
        stateCorrupt = (& { if ($stu.Found) { $stu.Corrupt } else { $false } })
      }
      $obj | ConvertTo-Json -Depth 5 | Write-Output
      Write-UpdaterLog ("status: active=" + $obj.active + " installed=" + ($installed -join ",")) "OK"
      exit 0
    }
    "update" {
      if ([string]::IsNullOrWhiteSpace($Version)) { throw "update richiede -Version (formato vX.Y.Z)" }
      if ([string]::IsNullOrWhiteSpace($StagingDir)) { throw "update richiede -StagingDir (payload scaricato+estratto dal chiamante)" }
      $nodeExe = ""
      $me = Read-MachineEnv -EnvPath $Paths.MachineEnv
      if ($me.Ok) { $nodeExe = $me.Env.NodeExe }
      $stopHook = {
        param($p) return (Stop-PiServerRuntime -Paths $p -RemotePort $p.RemotePortDefault -TimeoutSec 60)
      }
      $startHook = {
        param($p)
        $fails = @()
        foreach ($tn in @($p.TaskName, $p.RemoteTaskName)) {
          try { Start-ScheduledTask -TaskName $tn -ErrorAction Stop }
          catch { $fails += ($tn + ": " + $_.Exception.Message) }
        }
        if ($fails.Count -gt 0) { return @{ Ok = $false; Detail = ($fails -join " | ") } }
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
      $res = Invoke-ReleaseUpdate -Paths $Paths -TargetVersion $Version -StagingDir $StagingDir `
        -NodeExe $nodeExe -StopRuntime $stopHook -StartRuntime $startHook
      Write-UpdaterLog ("update " + $Version + ": " + $res.Action + " " + $res.Detail) (& { if ($res.Ok) { "OK" } else { "FAIL" } })
      if ($res.Ok) { exit 0 }
      if ($res.Action -eq "manual_intervention_required") { exit 2 }
      exit 1
    }
    "rollback" {
      $stu = Read-UpdateState -StatePath $Paths.UpdateState
      if ((-not $stu.Found) -or $stu.Corrupt) { throw "nessuna transazione valida per rollback" }
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
      $res = Invoke-UpdateRollback -Paths $Paths -State $stu.State -StartRuntime $startHook
      Write-UpdaterLog ("rollback: " + $res.Action + " " + $res.Detail) (& { if ($res.Ok) { "OK" } else { "FAIL" } })
      if ($res.Ok) { exit 0 }
      exit 2
    }
    "recover" {
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
      $res = Invoke-UpdateRecovery -Paths $Paths -StartRuntime $startHook
      Write-UpdaterLog ("recover: " + $res.Action + " " + $res.Detail) (& { if ($res.Ok) { "OK" } else { "FAIL" } })
      if ($res.Ok) { exit 0 }
      exit 2
    }
    default { throw ("azione non valida: " + $Action + " (status|update|rollback|recover)") }
  }
} catch {
  Write-UpdaterLog ("fatal: " + $_.Exception.Message) "FAIL"
  exit 1
}
