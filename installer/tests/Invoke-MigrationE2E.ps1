<#
.SYNOPSIS
  v0.3.0 migration E2E on real Windows (legacy app -> pointer releases).

.DESCRIPTION
  Reproduces a v0.2.x box with REAL scheduled tasks, REAL launchers, the
  REAL pi-daemon (stub pi backend, TaskE2E pattern), the REAL remote server
  (loopback bind via fixture remote-server.json, fixture HMAC) plus live
  lock-holders (cwd-holder, --mode rpc orphan, TCP listener stub), then runs
  the REAL Invoke-LegacyMigration with REAL hooks (real task stop/start,
  real CIM sweep, real taskkill, real port/API/version checks).

  Scenario 1 (success): legacy v0.2.10 -> v0.3.0, pointer switch, tasks on
  bin\, legacy app\ untouched, locks swept, API pong on the new release.
  Scenario 2 (forced failure): candidate health fails -> automatic pointer
  rollback to the legacy snapshot, old tasks restarted, server ONLINE.

  No production task names, no C:\PiServer, no Tailscale, no Telegram.
  Temp dirs + PiE2E-mig-* tasks only. Teardown unregisters tasks, kills
  leftovers, removes temp dirs (retried).

  5.1 compatible. Skips (exit 0) off Windows / non-admin / no node.
  Exit 1 on any failure.

  Run:  powershell.exe -NoProfile -NonInteractive -File installer/tests/Invoke-MigrationE2E.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "PiServerLib.ps1")
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "PiServerUpdate.ps1")
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "PiServerDoctor.ps1")

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

if (-not (Test-IsAdmin)) {
  Write-Host "SKIP migration E2E (non admin)" -ForegroundColor Yellow
  exit 0
}
if ($env:OS -ne "Windows_NT") {
  Write-Host "SKIP migration E2E (non-Windows)" -ForegroundColor Yellow
  exit 0
}
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
  Write-Host "SKIP migration E2E (node assente)" -ForegroundColor Yellow
  exit 0
}
$NodeExe = $nodeCmd.Source

$TestPort = 44998
$probeBusy = Get-TcpListenerOwner -Port $TestPort
if ($probeBusy.Listening) {
  Write-Host ("SKIP migration E2E (porta test " + $TestPort + " occupata)") -ForegroundColor Yellow
  exit 0
}

$TestHmac = "e2e-test-hmac-0123456789abcdef"
$tag = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$FxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("piserver-mig-" + $tag)
$script:taskNames = @()
$script:stubPids = @()

function New-E2EReleaseFiles([string]$dir, [string]$ver) {
  $codeFiles = @(
    "server\pi-daemon.mjs", "server\spawn-pi.mjs",
    "server\pi-remote-config\index.ts", "server\pi-remote-config\package.json",
    "server\pi-remote-server\index.ts", "server\pi-remote-server\server.ts",
    "server\pi-remote-server\migrate.ts", "server\pi-remote-server\tailscale.ts",
    "shared\protocol.ts", "shared\modules.ts", "shared\store.ts", "shared\pi-model.ts",
    "installer\PiServerLib.ps1", "installer\PiServerUpdate.ps1", "installer\PiServerDoctor.ps1",
    "installer\windows-installer.ps1", "installer\run-task.ps1", "installer\run-remote.ps1",
    "installer\bin\run-pi.ps1", "installer\bin\run-remote.ps1",
    "installer\bin\updater.ps1", "installer\bin\doctor.ps1"
  )
  foreach ($rel in $codeFiles) {
    $src = Join-Path $RepoRoot $rel
    $dst = Join-Path $dir $rel
    $dd = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $src)) { throw ("sorgente repo mancante: " + $rel) }
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
  $ver | Out-File -LiteralPath (Join-Path $dir "VERSION") -Encoding ascii -NoNewline
}

function New-StubPi([string]$path) {
  '@echo {"type":"e2e-stub-ready"}' | Out-File -LiteralPath $path -Encoding ascii -NoNewline
  Add-Content -LiteralPath $path -Value "" -Encoding ascii
  Add-Content -LiteralPath $path -Value "ping -n 300 127.0.0.1 >nul" -Encoding ascii
}

function Register-E2ETask([string]$name, [string]$launcher, [string]$workDir) {
  $action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"" + $launcher + "`"") `
    -WorkingDirectory $workDir
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
    -Principal $principal -Description "PiServer migration E2E (ephemeral)" | Out-Null
  $script:taskNames += $name
}

function Unregister-E2ETasks {
  foreach ($n in $script:taskNames) {
    try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
  }
  $script:taskNames = @()
}

function Stop-E2EStubs {
  foreach ($id in $script:stubPids) {
    try {
      $p = Get-Process -Id $id -ErrorAction SilentlyContinue
      if (($null -ne $p) -and (-not $p.HasExited)) {
        try { & taskkill /pid $id /T /F 2>&1 | Out-Null } catch { }
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
      }
    } catch { }
  }
  $script:stubPids = @()
}

function Get-TaskState([string]$name) {
  try {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction Stop
    return [string]$t.State
  } catch { return "missing" }
}

function Build-Scenario([string]$name) {
  $root = Join-Path $FxRoot $name
  $paths = (Get-PiServerPaths -Root (Join-Path $root "psrv")).Clone()
  $paths.TaskName = "PiE2E-mig-" + $tag + "-" + $name + "-Pi"
  $paths.RemoteTaskName = "PiE2E-mig-" + $tag + "-" + $name + "-Remote"
  $app = $paths.App
  New-Item -ItemType Directory -Path (Join-Path $app "server") -Force | Out-Null
  New-Item -ItemType Directory -Path $paths.Data -Force | Out-Null
  New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null
  New-E2EReleaseFiles $app "0.2.10"
  $stubPi = Join-Path $app "stub-pi.cmd"
  New-StubPi $stubPi
  (@{
      NodeExe = $NodeExe; PiBin = $stubPi; NpmGlobalBin = ""
      DaemonScript = Join-Path $app "server\pi-daemon.mjs"; NodeArgs = @()
      RemoteEntry = Join-Path $app "server\pi-remote-server\index.ts"; AgentDir = $paths.AgentDir
    } | ConvertTo-Json -Depth 3) | Out-File -LiteralPath (Join-Path $app "runtime-env.json") -Encoding utf8
  (@{ port = $TestPort; bindHost = "127.0.0.1"; maxSkewSeconds = 300 } | ConvertTo-Json -Depth 3) | Out-File -LiteralPath (Join-Path $paths.AgentDir "remote-server.json") -Encoding ascii -NoNewline
  New-Item -ItemType Directory -Path $paths.SecretsDir -Force | Out-Null
  $TestHmac | Out-File -LiteralPath (Join-Path $paths.SecretsDir "remote-hmac") -Encoding ascii -NoNewline
  $pay = Join-Path $root "pay30"
  New-E2EReleaseFiles $pay "v0.3.0"
  return @{ Paths = $paths; Payload = $pay; App = $app }
}

function Start-ScenarioRuntime([hashtable]$paths) {
  Register-E2ETask $paths.TaskName (Join-Path $paths.App "run-task.ps1") (Join-Path $paths.App "server")
  Register-E2ETask $paths.RemoteTaskName (Join-Path $paths.App "run-remote.ps1") (Join-Path $paths.App "server\pi-remote-server")
  Start-ScheduledTask -TaskName $paths.TaskName
  Start-ScheduledTask -TaskName $paths.RemoteTaskName
  $w = Wait-TaskStartup -TaskName $paths.TaskName -LauncherPath (Join-Path $paths.App "run-task.ps1") `
    -ProcessMatch "pi-daemon\.mjs" -LogPath $paths.ServerLog -TimeoutSec 30
  if (-not $w.Ok) { throw ("legacy pi non partito: " + $w.Detail) }
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $deadline) {
    $o = Get-TcpListenerOwner -Port $TestPort
    if ($o.Listening -and ([string]$o.CommandLine -match "pi-remote-server")) { break }
    Start-Sleep -Seconds 2
  }
  $o2 = Get-TcpListenerOwner -Port $TestPort
  if ((-not $o2.Listening) -or ([string]$o2.CommandLine -notmatch "pi-remote-server")) {
    throw ("legacy remote non in ascolto: " + $o2.Detail)
  }
  $ping = Test-RemoteApiPing -Paths $paths -Port $TestPort -TimeoutSec 10
  if (-not $ping.Ok) { throw ("legacy api senza pong: " + $ping.Detail) }
}

function Add-ScenarioLocks([string]$app, [int]$port) {
  $holder = Start-Process powershell.exe `
    -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 120 # lock-holder $app") `
    -WorkingDirectory $app -PassThru
  $script:stubPids += $holder.Id
  $orphan = Start-Process powershell.exe `
    -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 120 # marcatore --mode rpc") `
    -WorkingDirectory $app -PassThru
  $script:stubPids += $orphan.Id
  $lst = Start-Process powershell.exe `
    -ArgumentList @("-NoProfile", "-NonInteractive", "-Command", "`$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port); `$l.Start(); Start-Sleep 120 # lock-holder $app") `
    -WorkingDirectory $app -PassThru
  $script:stubPids += $lst.Id
  Start-Sleep -Seconds 3
}

function New-E2EHooks([hashtable]$paths, [scriptblock]$versionReader) {
  $stopHook = { param($p) return (Stop-PiServerRuntime -Paths $p -RemotePort $TestPort -TimeoutSec 60) }
  $startHook = {
    param($p)
    try { Start-ScheduledTask -TaskName $p.TaskName -ErrorAction Stop } catch { }
    try { Start-ScheduledTask -TaskName $p.RemoteTaskName -ErrorAction Stop } catch { }
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $seen = ""
    $portOk = $false
    while ([DateTime]::UtcNow -lt $deadline) {
      $sPi = Get-TaskState $p.TaskName
      $sRe = Get-TaskState $p.RemoteTaskName
      $seen = ($sPi + "," + $sRe)
      $o = Get-TcpListenerOwner -Port $TestPort
      $portOk = ($o.Listening -and ([string]$o.CommandLine -match "pi-remote-server"))
      if (($sPi -eq "Running") -and ($sRe -eq "Running") -and $portOk) { break }
      Start-Sleep -Seconds 3
    }
    if (($seen -ne "Running,Running") -or (-not $portOk)) { return @{ Ok = $false; Detail = ("runtime non pronto: tasks=" + $seen + " portOwned=" + $portOk) } }
    return @{ Ok = $true; Detail = "tasks avviati, tasks+porta pronti" }
  }
  $taskCheck = {
    param($p)
    $a = (Get-TaskState $p.TaskName) -eq "Running"
    $b = (Get-TaskState $p.RemoteTaskName) -eq "Running"
    return @{ PiRunning = $a; RemoteRunning = $b; Detail = ("pi=" + (Get-TaskState $p.TaskName) + " remote=" + (Get-TaskState $p.RemoteTaskName)) }
  }
  $portCheck = { param($pt) return (Get-TcpListenerOwner -Port $pt) }
  $apiCheck = { param($p) return (Test-RemoteApiPing -Paths $p -Port $TestPort -TimeoutSec 10) }
  $taskUpd = { param($n, $lp) return (Update-PiServerTaskAction -TaskName $n -LauncherPath $lp -WorkDir $paths.Bin) }
  return @{ Stop = $stopHook; Start = $startHook; TaskCheck = $taskCheck; PortCheck = $portCheck; ApiCheck = $apiCheck; VersionReader = $versionReader; TaskUpd = $taskUpd }
}

try {
  New-Item -ItemType Directory -Path $FxRoot -Force | Out-Null

  Write-Host "== migration E2E scenario 1: legacy -> v0.3.0 =="
  $s1 = Build-Scenario "s1"
  $p1 = $s1.Paths
  Start-ScenarioRuntime $p1
  Assert-True ((Get-TaskState $p1.TaskName) -eq "Running") "legacy pi task Running"
  Assert-True ((Get-TaskState $p1.RemoteTaskName) -eq "Running") "legacy remote task Running (loopback)"
  Add-ScenarioLocks $s1.App $TestPort
  $vrLive = { param($p) $pv = Read-ActiveRelease -PointerPath $p.ActivePointer; return @{ Ok = $pv.Ok; Version = $pv.Version } }
  $h1 = New-E2EHooks $p1 $vrLive
  $mig1 = Invoke-LegacyMigration -Paths $p1 -StagingDir $s1.Payload -TargetVersion "v0.3.0" -NodeExe $NodeExe `
    -StopRuntime $h1.Stop -StartRuntime $h1.Start -TaskChecker $h1.TaskCheck -PortChecker $h1.PortCheck `
    -ApiChecker $h1.ApiCheck -VersionReader $h1.VersionReader -TaskActionUpdater $h1.TaskUpd
  Assert-True (($mig1.Ok) -and ($mig1.Action -eq "migrated")) "migration scenario 1 migrata"
  Assert-Equal (Read-ActiveRelease -PointerPath $p1.ActivePointer).Version "v0.3.0" "pointer v0.3.0"
  Assert-True (Test-Path -LiteralPath (Join-Path $p1.Releases "v0.2.10\server\pi-daemon.mjs")) "snapshot legacy presente"
  Assert-True (Test-Path -LiteralPath (Join-Path $p1.Releases "v0.3.0\server\pi-daemon.mjs")) "release v0.3.0 presente"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $s1.App "VERSION") -Raw) "0.2.10" "legacy app intatta"
  $tPi = Get-ScheduledTask -TaskName $p1.TaskName -ErrorAction SilentlyContinue
  $tRe = Get-ScheduledTask -TaskName $p1.RemoteTaskName -ErrorAction SilentlyContinue
  Assert-True (([string]$tPi.Actions[0].Arguments).Contains('"' + $p1.BinRunPi + '"')) "task Pi su bin\run-pi.ps1"
  Assert-True (([string]$tRe.Actions[0].Arguments).Contains('"' + $p1.BinRunRemote + '"')) "task Remote su bin\run-remote.ps1"
  Assert-True ((Get-TaskState $p1.TaskName) -eq "Running") "pi task Running post-migration (nuovo launcher)"
  Assert-True ((Get-TaskState $p1.RemoteTaskName) -eq "Running") "remote task Running post-migration"
  $pingNew = Test-RemoteApiPing -Paths $p1 -Port $TestPort -TimeoutSec 10
  Assert-True $pingNew.Ok "api pong sulla nuova release"
  $goneAll = $true
  foreach ($id in $script:stubPids) {
    try { $pp = Get-Process -Id $id -ErrorAction Stop; if (-not $pp.HasExited) { $goneAll = $false } } catch { }
  }
  Assert-True $goneAll "lock-holder + orfano + listener spazzati dallo sweep"
  Stop-E2EStubs
  Unregister-E2ETasks

  Write-Host "== migration E2E scenario 2: failure -> rollback, online =="
  $s2 = Build-Scenario "s2"
  $p2 = $s2.Paths
  Start-ScenarioRuntime $p2
  Add-ScenarioLocks $s2.App $TestPort
  $vrFailNew = {
    param($p)
    $pv = Read-ActiveRelease -PointerPath $p.ActivePointer
    if ($pv.Ok -and ($pv.Version -eq "v0.3.0")) { return @{ Ok = $true; Version = "v0.0.0-broken" } }
    return @{ Ok = $pv.Ok; Version = $pv.Version }
  }
  $h2 = New-E2EHooks $p2 $vrFailNew
  $mig2 = Invoke-LegacyMigration -Paths $p2 -StagingDir $s2.Payload -TargetVersion "v0.3.0" -NodeExe $NodeExe `
    -StopRuntime $h2.Stop -StartRuntime $h2.Start -TaskChecker $h2.TaskCheck -PortChecker $h2.PortCheck `
    -ApiChecker $h2.ApiCheck -VersionReader $h2.VersionReader -TaskActionUpdater $h2.TaskUpd
  Assert-True ((-not $mig2.Ok) -and ($mig2.Action -eq "migration_rolled_back")) "failure -> migration_rolled_back"
  Assert-Equal (Read-ActiveRelease -PointerPath $p2.ActivePointer).Version "v0.2.10" "pointer su snapshot legacy"
  Assert-True ((Get-TaskState $p2.TaskName) -eq "Running") "server ONLINE: pi task Running dopo rollback"
  Assert-True ((Get-TaskState $p2.RemoteTaskName) -eq "Running") "server ONLINE: remote task Running dopo rollback"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $s2.App "VERSION") -Raw) "0.2.10" "legacy app intatta dopo rollback"
  $pingOld = Test-RemoteApiPing -Paths $p2 -Port $TestPort -TimeoutSec 10
  Assert-True $pingOld.Ok "api pong sulla release precedente"
  Stop-E2EStubs
  Unregister-E2ETasks
} catch {
  Write-Host ("  FAIL eccezione E2E: " + $_.Exception.Message) -ForegroundColor Red
  $script:failed++
  $script:failures += "eccezione E2E"
} finally {
  try {
    Stop-E2EStubs
    Unregister-E2ETasks
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
Write-Host "MIGRATION E2E OK" -ForegroundColor Green
exit 0
