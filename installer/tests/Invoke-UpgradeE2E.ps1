<#
.SYNOPSIS
  Upgrade-transaction E2E on real Windows (live lock + real port + real swap).

.DESCRIPTION
  Reproduces the v0.2.6->v0.2.7 failure class without secrets, Tailscale,
  Telegram or admin rights: a stub powershell process holds its working
  directory inside the fake app AND a real TCP listener on a test port
  (mirroring pi-remote-server on 43128). Then it runs the REAL production
  path: Stop-PiServerRuntime (real task cmdlets find no tasks, real
  Get-CimInstance sweep, real taskkill) via the REAL Invoke-AppStaging
  -PreSwapAction hook, swaps to v2, verifies the stub is gone and the port
  is free, then runs a REAL Invoke-AppRollback and verifies the old tree
  is back. No SYSTEM tasks, no registry, no C:\PiServer. Temp dirs only.

  5.1 compatible. Skips (exit 0) off Windows. Exit 1 on any failure.
  Teardown kills leftovers and removes temp dirs (retried).

  Run:  powershell.exe -NoProfile -NonInteractive -File installer/tests/Invoke-UpgradeE2E.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "PiServerLib.ps1")

$script:passed = 0
$script:failed = 0
$script:failures = @()
function Assert-True([bool]$cond, [string]$name) {
  if ($cond) { $script:passed++; Write-Host "  PASS $name" -ForegroundColor Green }
  else { $script:failed++; $script:failures += $name; Write-Host "  FAIL $name" -ForegroundColor Red }
}
function Assert-Equal($actual, $expected, [string]$name) {
  Assert-True ($actual -eq $expected) "$name (atteso='$expected' trovato='$actual')"
}

if ($env:OS -ne "Windows_NT") {
  Write-Host "SKIP upgrade E2E (non-Windows)" -ForegroundColor Yellow
  exit 0
}

$TestPort = 44999
$probeBusy = Get-TcpListenerOwner -Port $TestPort
if ($probeBusy.Listening) {
  Write-Host ("SKIP upgrade E2E (porta test " + $TestPort + " occupata)") -ForegroundColor Yellow
  exit 0
}

$FxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("piserver-upg-" + [Guid]::NewGuid().ToString("N"))
$stubPid = 0
try {
  New-Item -ItemType Directory -Path $FxRoot -Force | Out-Null
  $fxPaths = Get-PiServerPaths -Root (Join-Path $FxRoot "psrv")
  $app = $fxPaths.App

  function New-E2EPayload([string]$dir, [string]$tag) {
    foreach ($rel in $script:ReleaseManifest) {
      $fp = Join-Path $dir $rel
      $dd = Split-Path -Parent $fp
      if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
      ($tag + ":" + $rel) | Out-File -LiteralPath $fp -Encoding ascii -NoNewline
    }
  }

  Write-Host "== upgrade E2E: live lock + swap =="
  $payV1 = Join-Path $FxRoot "payV1"
  New-E2EPayload $payV1 "v1"
  $sV1 = Invoke-AppStaging -PayloadDir $payV1 -AppPath $app -Mode "fresh" -VersionLabel "v9.9.9-old"
  Assert-True $sV1.Ok "deploy v1 iniziale"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $app "VERSION") -Raw) "v9.9.9-old" "VERSION v1"

  $stubCmd = "Set-Location '" + $app + "'; " + `
    "`$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, " + $TestPort + "); " + `
    "`$l.Start(); Start-Sleep 120 # lock-holder " + $app
  $stubProc = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", $stubCmd) `
    -WorkingDirectory $app -PassThru
  $stubPid = $stubProc.Id
  Start-Sleep -Seconds 3

  $ownLive = Get-TcpListenerOwner -Port $TestPort
  Assert-True ($ownLive.Listening -and ($ownLive.Pid -eq $stubPid)) "porta occupata dallo stub (pid reale)"
  Assert-True (Test-PortOwnerIsOurs -Owner $ownLive -Paths $fxPaths) "stub riconosciuto come nostro"

  $payV2 = Join-Path $FxRoot "payV2"
  New-E2EPayload $payV2 "v2"
  $hook = {
    $s = Stop-PiServerRuntime -Paths $fxPaths -RemotePort $TestPort
    if (-not $s.Ok) { throw $s.Detail }
    return $null
  }
  $sV2 = Invoke-AppStaging -PayloadDir $payV2 -AppPath $app -Mode "update" -VersionLabel "v9.9.9-new" -PreSwapAction $hook
  Assert-True $sV2.Ok "swap con runtime stoppato"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $app "VERSION") -Raw) "v9.9.9-new" "VERSION v2 dopo swap"
  Assert-True (($null -ne $sV2.BackupPath) -and (Test-Path -LiteralPath (Join-Path $sV2.BackupPath "VERSION"))) "backup con VERSION vecchia"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $sV2.BackupPath "VERSION") -Raw) "v9.9.9-old" "backup contiene v1"

  $gone = $false
  try { $p = Get-Process -Id $stubPid -ErrorAction Stop; $gone = $p.HasExited } catch { $gone = $true }
  Assert-True $gone "stub terminato dallo stop"
  $freeAfter = Get-TcpListenerOwner -Port $TestPort
  Assert-True (-not $freeAfter.Listening) "porta libera dopo stop"

  Write-Host "== upgrade E2E: rollback =="
  $global:upE2EStarted = @()
  $starterE2E = { param($n) $global:upE2EStarted += $n }
  $healthE2E = { return @{ Ok = $true; Failures = @() } }
  $stopReal = { return @{ Ok = $true; Detail = "niente da fermare (fake)" } }
  $rb = Invoke-AppRollback -Paths $fxPaths -BackupPath $sV2.BackupPath -PiBin "" -RemotePort 0 `
    -RuntimeStopper $stopReal -TaskStarter $starterE2E -HealthChecker $healthE2E
  Assert-True $rb.Ok "rollback E2E"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $app "VERSION") -Raw) "v9.9.9-old" "app tornata a v1"
  Assert-True ((($global:upE2EStarted -contains $fxPaths.TaskName) -and ($global:upE2EStarted -contains $fxPaths.RemoteTaskName))) "restart entrambi i task"
  Remove-Variable -Name upE2EStarted -Scope Global -ErrorAction SilentlyContinue
} catch {
  Write-Host ("  FAIL eccezione E2E: " + $_.Exception.Message) -ForegroundColor Red
  $script:failed++
  $script:failures += "eccezione E2E"
} finally {
  try {
    if ($stubPid -gt 0) {
      $still = $null
      try { $still = Get-Process -Id $stubPid -ErrorAction Stop } catch { }
      if (($null -ne $still) -and (-not $still.HasExited)) {
        try { & taskkill /pid $stubPid /T /F 2>&1 | Out-Null } catch { }
        try { Stop-Process -Id $stubPid -Force -ErrorAction SilentlyContinue } catch { }
      }
    }
  } catch { }
  Start-Sleep -Seconds 1
  for ($i = 0; $i -lt 3; $i++) {
    try {
      if (Test-Path -LiteralPath $FxRoot) { Remove-Item -LiteralPath $FxRoot -Recurse -Force -ErrorAction Stop }
      break
    } catch { Start-Sleep -Seconds 2 }
  }
}

Write-Host ""
Write-Host "----------------------------------------"
Write-Host "PASS: $script:passed  FAIL: $script:failed"
if ($script:failed -gt 0) {
  Write-Host "Fallimenti:" -ForegroundColor Red
  $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host "UPGRADE E2E OK" -ForegroundColor Green
exit 0
