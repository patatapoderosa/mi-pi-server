<#
.SYNOPSIS
  End-to-end task-chain test on real Windows (Task Scheduler + run-task.ps1 +
  pi-daemon.mjs + stub pi.cmd). No secrets, no Tailscale, no Telegram.

.DESCRIPTION
  Builds a temp PiServer layout under $env:ProgramData (path WITH A SPACE, to
  exercise quoted-exe spawning), registers a real SYSTEM scheduled task
  pointing at a copy of installer/run-task.ps1, starts it, and verifies with
  the REAL lib Wait-TaskStartup poller: daemon process alive (CommandLine
  match), task State=Running, pi-server.log contains "starting pi-daemon",
  still alive after 10s. Teardown unregisters the task and kills the tree.

  5.1 compatible. Must run elevated (Task Scheduler + SYSTEM task).
  Exit 0 = pass (or SKIP when not admin), 1 = fail. Never touches C:\PiServer.

  Run:  powershell.exe -NoProfile -NonInteractive -File installer/tests/Invoke-TaskE2E.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "PiServerLib.ps1")

$script:failed = @()
function Fail([string]$m) {
  $script:failed += $m
  Write-Host "  FAIL $m" -ForegroundColor Red
}
function Ok([string]$m) {
  Write-Host "  PASS $m" -ForegroundColor Green
}

if (-not (Test-IsAdmin)) {
  Write-Host "SKIP task E2E (non admin)" -ForegroundColor Yellow
  exit 0
}
if ($env:OS -ne "Windows_NT") {
  Write-Host "SKIP task E2E (non-Windows)" -ForegroundColor Yellow
  exit 0
}
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
  Write-Host "SKIP task E2E (node assente)" -ForegroundColor Yellow
  exit 0
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$daemonSrc = Join-Path $RepoRoot "server\pi-daemon.mjs"
$spawnSrc = Join-Path $RepoRoot "server\spawn-pi.mjs"
$launcherSrc = Join-Path (Split-Path -Parent $PSScriptRoot) "run-task.ps1"

# E2E 1: syntax gate first (fast fail, same files CI checks).
foreach ($f in @($daemonSrc, $spawnSrc)) {
  & $nodeCmd.Source --check $f 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "node --check fallito: $f"; exit 1 }
}
Ok "node --check daemon + spawn"

$tag = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$work = Join-Path $env:ProgramData ("piserver e2e " + $tag)
$app = Join-Path $work "app"
$taskName = "PiE2E-" + $tag

try {
  New-Item -ItemType Directory -Path (Join-Path $app "server") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $work "data") -Force | Out-Null
  Copy-Item -LiteralPath $daemonSrc -Destination (Join-Path $app "server\pi-daemon.mjs") -Force
  Copy-Item -LiteralPath $spawnSrc -Destination (Join-Path $app "server\spawn-pi.mjs") -Force
  Copy-Item -LiteralPath $launcherSrc -Destination (Join-Path $app "run-task.ps1") -Force
  $stub = Join-Path $app "stub-pi.cmd"
  '@echo {"type":"e2e-stub-ready"}' | Out-File -LiteralPath $stub -Encoding ascii -NoNewline
  Add-Content -LiteralPath $stub -Value "" -Encoding ascii
  Add-Content -LiteralPath $stub -Value "ping -n 60 127.0.0.1 >nul" -Encoding ascii
  # NOTE: NpmGlobalBin volutamente assente (chiave opzionale): prova che il
  # launcher degrada con grazia invece di crashare sotto StrictMode.
  $envObj = @{
    NodeExe      = $nodeCmd.Source
    PiBin        = $stub
    DaemonScript = Join-Path $app "server\pi-daemon.mjs"
    AgentDir     = Join-Path $work "data"
  }
  $envObj | ConvertTo-Json -Depth 3 | Out-File -LiteralPath (Join-Path $app "runtime-env.json") -Encoding utf8

  $action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"" + (Join-Path $app "run-task.ps1") + "`"") `
    -WorkingDirectory (Join-Path $app "server")
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Description "PiServer task-chain E2E (ephemeral)" | Out-Null
  Ok "task registrata"
  Start-ScheduledTask -TaskName $taskName

  $logPath = Join-Path $work "logs\pi-server.log"
  $w = Wait-TaskStartup -TaskName $taskName -LauncherPath (Join-Path $app "run-task.ps1") `
    -ProcessMatch "pi-daemon\.mjs" -LogPath $logPath -TimeoutSec 25
  if (-not $w.Ok) { Fail ("startup polling: " + $w.Detail) }
  else { Ok ("startup polling: " + $w.Detail) }

  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (($null -eq $t) -or ([string]$t.State -ne "Running")) { Fail ("State atteso Running, trovato: " + [string]$t.State) }
  else { Ok "State=Running" }
  $info = $null
  try { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop } catch { }
  if ($null -eq $info) { Fail "Get-ScheduledTaskInfo fallita" }
  else { Ok ("LastTaskResult=" + [string]$info.LastTaskResult + " LastRunTime=" + [string]$info.LastRunTime) }

  $logRaw = ""
  try { $logRaw = Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop } catch { }
  if ($logRaw -match "starting pi-daemon") { Ok "log contiene starting pi-daemon" }
  else { Fail "log senza starting pi-daemon" }

  Start-Sleep -Seconds 10
  $esc = [regex]::Escape((Join-Path $app "server\pi-daemon.mjs"))
  $alive = @()
  try {
    $alive = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
      $_.CommandLine -match "pi-daemon\.mjs" -and $_.CommandLine -match $esc
    })
  } catch { }
  if ($alive.Count -ge 1) { Ok "daemon vivo dopo 10s" }
  else { Fail "daemon morto entro 10s" }
  if ($script:failed.Count -gt 0) {
    foreach ($lf in @($logPath, (Join-Path (Split-Path -Parent $logPath) "pi-server-error.log"))) {
      Write-Host ("--- " + $lf) 
      try {
        $lc = Get-Content -LiteralPath $lf -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($lc)) { Write-Host "(vuoto)" }
        else { Write-Host ($lc.Substring(0, [Math]::Min(2000, $lc.Length))) }
      } catch { Write-Host "(non leggibile)" }
    }
  }
} catch {
  Fail ("eccezione: " + $_.Exception.Message)
} finally {
  try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
  try {
    $esc2 = [regex]::Escape($app)
    $left = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ([string]$_.CommandLine) -match $esc2
    })
    foreach ($p in $left) {
      try { & taskkill /pid $p.ProcessId /T /F 2>&1 | Out-Null } catch { }
      try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
  } catch { }
  try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
  Start-Sleep -Seconds 2
  for ($i = 0; $i -lt 3; $i++) {
    try {
      if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop }
      break
    } catch { Start-Sleep -Seconds 2 }
  }
}

if ($script:failed.Count -gt 0) {
  Write-Host ("TASK E2E FAILED (" + $script:failed.Count + ")") -ForegroundColor Red
  exit 1
}
Write-Host "TASK E2E OK" -ForegroundColor Green
exit 0
