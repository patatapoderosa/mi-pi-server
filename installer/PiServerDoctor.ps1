<#
.SYNOPSIS
  v0.3.0 server doctor: structured diagnostics + allowlist self-heal.

.DESCRIPTION
  Dot-source AFTER installer/PiServerUpdate.ps1. No side effects on load.
  Invoke-ServerDoctor collects checks (no secrets ever in output) and writes
  data\doctor-report.json. Invoke-DoctorRepair performs ONLY allowlisted
  local recoveries behind a circuit breaker (max 3 automatic attempts per
  10 minutes); everything else is reported for manual intervention.

  5.1 compatible (no ??, ?., ternary). ASCII only. Helpers never throw.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:DoctorCircuitMax = 3
$script:DoctorCircuitWindowMin = 10

<#
.SYNOPSIS
  Read the repair circuit state. Never throws.
#>
function Read-DoctorCircuit {
  param([string]$CircuitPath = "")
  try {
    if ([string]::IsNullOrWhiteSpace($CircuitPath)) { return @() }
    if (-not (Test-Path -LiteralPath $CircuitPath)) { return @() }
    $arr = (Get-Content -LiteralPath $CircuitPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
    $out = @()
    foreach ($t in @($arr)) {
      try {
        if ($t -is [DateTimeOffset]) { $out += $t }
        elseif ($t -is [DateTime]) { $out += ([DateTimeOffset]$t) }
        else { $out += [DateTimeOffset]::Parse([string]$t, [System.Globalization.CultureInfo]::InvariantCulture) }
      } catch { }
    }
    return $out
  } catch { return @() }
}

<#
.SYNOPSIS
  Record one automatic repair attempt (pruned to the window). Never throws.
#>
function Write-DoctorCircuit {
  param([string]$CircuitPath = "")
  try {
    if ([string]::IsNullOrWhiteSpace($CircuitPath)) { return @{ Ok = $false; Error = "circuit path vuoto" } }
    $now = [DateTimeOffset]::UtcNow
    $keep = @()
    foreach ($t in (Read-DoctorCircuit -CircuitPath $CircuitPath)) {
      if (($now - $t).TotalMinutes -lt $script:DoctorCircuitWindowMin) { $keep += $t.ToString("o") }
    }
    $keep += $now.ToString("o")
    $dir = Split-Path -Parent $CircuitPath
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    (ConvertTo-Json -InputObject @($keep) -Depth 2) | Out-File -LiteralPath $CircuitPath -Encoding utf8 -ErrorAction Stop
    return @{ Ok = $true; Error = "" }
  } catch {
    return @{ Ok = $false; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  True when the circuit allows another automatic repair. Never throws.
#>
function Test-DoctorCircuit {
  param([string]$CircuitPath = "")
  try {
    $now = [DateTimeOffset]::UtcNow
    $n = 0
    foreach ($t in (Read-DoctorCircuit -CircuitPath $CircuitPath)) {
      if (($now - $t).TotalMinutes -lt $script:DoctorCircuitWindowMin) { $n++ }
    }
    if ($n -ge $script:DoctorCircuitMax) {
      return @{ Allowed = $false; Attempts = $n; Error = "circuit breaker: troppi recovery automatici, serve intervento manuale" }
    }
    return @{ Allowed = $true; Attempts = $n; Error = "" }
  } catch {
    return @{ Allowed = $false; Attempts = 0; Error = $_.Exception.Message }
  }
}

function New-DoctorCheck {
  param([string]$Name = "", [bool]$Ok = $false, [string]$Severity = "info", [string]$Detail = "", [bool]$Recoverable = $false)
  return @{
    name = $Name
    ok = $Ok
    severity = $Severity
    detail = $Detail
    recoverable = $Recoverable
  }
}

<#
.SYNOPSIS
  Collect structured server diagnostics. Never throws, never logs secrets.
.DESCRIPTION
  Injectable readers (production wires real Windows checks, tests wire
  fakes, daemon wires local readers):
    TaskReader:       param($TaskName) -> @{ Exists; State; LastResult; Detail }
    ProcessProbe:     param() -> array of @{ ProcessId; Name; CommandLine }
    ConnectionReader: param($Port) -> passthrough to Get-TcpListenerOwner
    TailscaleReader:  param() -> @{ Ok; Ip; Detail }
  Writes data\doctor-report.json (atomic) and returns
  @{ Status; Checks; ReportPath; Error } with Status in
  healthy|degraded|unhealthy.
#>
function Invoke-ServerDoctor {
  param(
    [hashtable]$Paths = $null,
    [scriptblock]$TaskReader = $null,
    [scriptblock]$ProcessProbe = $null,
    [scriptblock]$ConnectionReader = $null,
    [scriptblock]$TailscaleReader = $null
  )
  try {
    if ($null -eq $Paths) {
      return @{ Status = "unhealthy"; Checks = @(); ReportPath = ""; Error = "paths nulli" }
    }
    $checks = @()
    $crit = 0
    $warn = 0
    $add = {
      param($c)
      $script:__docChecks += $c
      if (-not $c.ok) {
        if ($c.severity -eq "critical") { $script:__docCrit++ } else { $script:__docWarn++ }
      }
    }
    $script:__docChecks = @()
    $script:__docCrit = 0
    $script:__docWarn = 0

    $ptr = Read-ActiveRelease -PointerPath $Paths.ActivePointer
    if ($ptr.Ok) {
      & $add (New-DoctorCheck -Name "active_release" -Ok $true -Severity "info" -Detail $ptr.Version)
    } else {
      & $add (New-DoctorCheck -Name "active_release" -Ok $false -Severity "critical" -Detail $ptr.Error -Recoverable $true)
    }
    $installed = Get-InstalledReleases -ReleasesRoot $Paths.Releases
    & $add (New-DoctorCheck -Name "installed_releases" -Ok ($installed.Count -gt 0) -Severity "critical" `
      -Detail (& { if ($installed.Count -gt 0) { ($installed -join ", ") } else { "nessuna release installata" } }))
    $leg = Test-LegacyLayout -Paths $Paths
    & $add (New-DoctorCheck -Name "legacy_layout" -Ok $true -Severity "info" `
      -Detail (& { if ($leg.Found) { ("presente (" + $leg.Version + "), intatto per recovery") } else { "assente (post-migrazione)" } }))
    if ($ptr.Ok) {
      $rd = Resolve-ReleaseDir -Root $Paths.Root -Version $ptr.Version
      if ($rd.Ok) {
        $mc = Test-ReleaseContent -PayloadDir $rd.Dir -ExpectedVersion $ptr.Version
        & $add (New-DoctorCheck -Name "active_manifest" -Ok $mc.Ok -Severity "critical" -Detail (& { if ($mc.Ok) { "manifest+VERSION OK" } else { $mc.Error } }) -Recoverable $true)
      } else {
        & $add (New-DoctorCheck -Name "active_manifest" -Ok $false -Severity "critical" -Detail $rd.Error -Recoverable $true)
      }
    }
    $me = Read-MachineEnv -EnvPath $Paths.MachineEnv
    & $add (New-DoctorCheck -Name "runtime_env" -Ok $me.Ok -Severity "critical" `
      -Detail (& { if ($me.Ok) { "machine facts OK" } else { $me.Error } }) -Recoverable $true)
    $settingsPath = Join-Path $Paths.AgentDir "settings.json"
    if (Test-Path -LiteralPath $settingsPath) {
      $sjOk = $false
      $sjDetail = ""
      try { (Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop | Out-Null; $sjOk = $true; $sjDetail = "valido" }
      catch { $sjDetail = "JSON non valido" }
      & $add (New-DoctorCheck -Name "settings_json" -Ok $sjOk -Severity "warning" -Detail $sjDetail)
    } else {
      & $add (New-DoctorCheck -Name "settings_json" -Ok $true -Severity "info" -Detail "assente (default Pi)")
    }
    $authPresent = Test-Path -LiteralPath (Join-Path $Paths.AgentDir "auth.json")
    & $add (New-DoctorCheck -Name "pi_auth_present" -Ok $authPresent -Severity "warning" `
      -Detail (& { if ($authPresent) { "presente" } else { "assente (serve /login)" } }))
    $hmacPresent = Test-Path -LiteralPath (Join-Path $Paths.SecretsDir "remote-hmac")
    & $add (New-DoctorCheck -Name "hmac_present" -Ok $hmacPresent -Severity "critical" -Detail (& { if ($hmacPresent) { "presente" } else { "assente" } }))
    $taskFn = $TaskReader
    if ($null -eq $taskFn) {
      $taskFn = {
        param($n)
        if ($env:OS -ne "Windows_NT") { return @{ Exists = $false; State = ""; LastResult = 0; Detail = "non-Windows" } }
        try {
          $t = Get-ScheduledTask -TaskName $n -ErrorAction Stop
          $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop
          return @{ Exists = $true; State = [string]$t.State; LastResult = [int]$info.LastTaskResult; Detail = ([string]$t.State + "/" + [int]$info.LastTaskResult) }
        } catch {
          return @{ Exists = $false; State = ""; LastResult = 0; Detail = ("task assente: " + $_.Exception.Message) }
        }
      }
    }
    foreach ($tn in @($Paths.TaskName, $Paths.RemoteTaskName)) {
      $tr = & $taskFn $tn
      $tOk = ($tr.Exists -and ($tr.State -eq "Ready" -or $tr.State -eq "Running"))
      $sev = "critical"
      if ($tr.Detail -eq "non-Windows") { $sev = "info" }
      & $add (New-DoctorCheck -Name ("task_" + $tn) -Ok $tOk -Severity $sev -Detail $tr.Detail -Recoverable $true)
    }
    $procs = @()
    try {
      if ($null -ne $ProcessProbe) { $procs = @(& $ProcessProbe) }
      elseif ($env:OS -eq "Windows_NT") { $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
    } catch { $procs = @() }
    $owned = @()
    $orphans = @()
    foreach ($p in $procs) {
      $opid = 0
      $cl = ""
      $nm = ""
      try { $opid = [int]$p.ProcessId } catch { continue }
      try { $cl = [string]$p.CommandLine } catch { }
      try { $nm = [string]$p.Name } catch { }
      if ($opid -le 0) { continue }
      $isOwned = $false
      if (($Paths.App -ne "") -and ($cl -match [regex]::Escape($Paths.App))) { $isOwned = $true }
      elseif (($Paths.Releases -ne "") -and ($cl -match [regex]::Escape($Paths.Releases))) { $isOwned = $true }
      elseif ($cl -match "pi-daemon\.mjs") { $isOwned = $true }
      elseif ($cl -match "pi-remote-server") { $isOwned = $true }
      if ($isOwned) { $owned += $opid }
      if ($cl -match "--mode rpc") { $orphans += $opid }
    }
    & $add (New-DoctorCheck -Name "owned_processes" -Ok $true -Severity "info" `
      -Detail (& { if ($owned.Count -gt 0) { ($owned.Count + " (pid " + ($owned -join ",") + ")") } else { "nessuno" } }))
    & $add (New-DoctorCheck -Name "mode_rpc_orphans" -Ok ($orphans.Count -eq 0) -Severity "warning" `
      -Detail (& { if ($orphans.Count -gt 0) { ("pid " + ($orphans -join ",")) } else { "nessuno" } }) -Recoverable ($orphans.Count -gt 0))
    $connFn = $ConnectionReader
    $lo = $null
    try {
      if ($null -ne $connFn) { $lo = & $connFn $Paths.RemotePortDefault }
      else { $lo = Get-TcpListenerOwner -Port $Paths.RemotePortDefault }
    } catch { $lo = $null }
    if ($null -eq $lo) {
      & $add (New-DoctorCheck -Name "remote_listener" -Ok $false -Severity "warning" -Detail "probe non disponibile")
    } elseif (-not $lo.Listening) {
      $sevL = "warning"
      if ([string]$lo.Detail -match "probe failed") { $sevL = "critical" }
      & $add (New-DoctorCheck -Name "remote_listener" -Ok $false -Severity $sevL -Detail $lo.Detail -Recoverable $true)
    } else {
      $ownOk = (Test-PortOwnerIsOurs -Owner $lo -Paths $Paths)
      & $add (New-DoctorCheck -Name "remote_listener" -Ok $ownOk -Severity "critical" `
        -Detail ("pid " + $lo.Pid + " " + $lo.Name) -Recoverable (-not $ownOk))
    }
    $tsFn = $TailscaleReader
    if ($null -eq $tsFn) {
      $tsFn = {
        try {
          $ip = (& tailscale ip -4 2>$null | Select-Object -First 1 | Out-String).Trim()
          if ($ip -match "^100\.\d+\.\d+\.\d+$") { return @{ Ok = $true; Ip = $ip; Detail = $ip } }
          return @{ Ok = $false; Ip = ""; Detail = "nessun IP tailnet" }
        } catch {
          return @{ Ok = $false; Ip = ""; Detail = "tailscale CLI indisponibile" }
        }
      }
    }
    $ts = & $tsFn
    & $add (New-DoctorCheck -Name "tailscale" -Ok $ts.Ok -Severity "warning" -Detail $ts.Detail)
    try {
      $drv = [System.IO.DriveInfo]::new((Split-Path -Qualifier $Paths.Root))
      if ([string]::IsNullOrWhiteSpace((Split-Path -Qualifier $Paths.Root))) {
        $drv = [System.IO.DriveInfo]::new($Paths.Root)
      }
      $freeGB = [math]::Round($drv.AvailableFreeSpace / 1GB, 2)
      & $add (New-DoctorCheck -Name "disk_free" -Ok ($freeGB -gt 1) -Severity "warning" -Detail ($freeGB.ToString() + " GB liberi"))
    } catch {
      & $add (New-DoctorCheck -Name "disk_free" -Ok $true -Severity "info" -Detail "non determinabile")
    }
    $stU = Read-UpdateState -StatePath $Paths.UpdateState
    if (-not $stU.Found) {
      & $add (New-DoctorCheck -Name "update_transaction" -Ok $true -Severity "info" -Detail "nessuna transazione pendente")
    } elseif ($stU.Corrupt) {
      & $add (New-DoctorCheck -Name "update_transaction" -Ok $false -Severity "critical" -Detail ("state corrotto: " + $stU.Error) -Recoverable $true)
    } elseif (@("completed", "failed", "rollback_completed") -contains $stU.State.phase) {
      & $add (New-DoctorCheck -Name "update_transaction" -Ok $true -Severity "info" -Detail ("terminale: " + $stU.State.phase))
    } else {
      & $add (New-DoctorCheck -Name "update_transaction" -Ok $false -Severity "warning" `
        -Detail ("pendente: " + $stU.State.fromVersion + " -> " + $stU.State.toVersion + " @ " + $stU.State.phase) -Recoverable $true)
    }
    $lastHist = ""
    try {
      if (Test-Path -LiteralPath $Paths.UpdateHistory) {
        $lines = Get-Content -LiteralPath $Paths.UpdateHistory -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($lines.Count -gt 0) {
          $lh = ($lines[-1] | ConvertFrom-Json -ErrorAction Stop)
          $lastHist = ([string]$lh.fromVersion + " -> " + [string]$lh.toVersion + " = " + [string]$lh.result)
        }
      }
    } catch { $lastHist = "history illeggibile" }
    & $add (New-DoctorCheck -Name "last_update" -Ok $true -Severity "info" -Detail (& { if ($lastHist -ne "") { $lastHist } else { "nessun update registrato" } }))
    $logNames = @(@{ N = "installer"; P = $Paths.InstallerLog }, @{ N = "updater"; P = $Paths.UpdaterLog }, @{ N = "doctor"; P = $Paths.DoctorLog }, @{ N = "pi-server"; P = $Paths.ServerLog }, @{ N = "remote"; P = $Paths.RemoteLog })
    $logInfo = @()
    foreach ($lg in $logNames) {
      try {
        if (Test-Path -LiteralPath $lg.P) {
          $lw = (Get-Item -LiteralPath $lg.P -ErrorAction Stop).LastWriteTimeUtc.ToString("o")
          $logInfo += ($lg.N + "=" + $lw)
        }
      } catch { }
    }
    & $add (New-DoctorCheck -Name "log_freshness" -Ok $true -Severity "info" -Detail (& { if ($logInfo.Count -gt 0) { ($logInfo -join " ") } else { "nessun log" } }))
    $recentFails = 0
    try {
      if (Test-Path -LiteralPath $Paths.UpdateHistory) {
        $hl = Get-Content -LiteralPath $Paths.UpdateHistory -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5
        foreach ($jl in $hl) {
          try {
            $he = ($jl | ConvertFrom-Json -ErrorAction Stop)
            if ([string]$he.result -match "fail|rollback") { $recentFails++ }
          } catch { }
        }
      }
    } catch { }
    & $add (New-DoctorCheck -Name "crash_loop" -Ok ($recentFails -lt 3) -Severity (& { if ($recentFails -ge 3) { "critical" } else { "info" } }) `
      -Detail ($recentFails.ToString() + " fallimenti negli ultimi 5 update"))
    $crit = $script:__docCrit
    $warn = $script:__docWarn
    $checks = $script:__docChecks
    Remove-Variable -Name __docChecks, __docCrit, __docWarn -Scope Script -ErrorAction SilentlyContinue
    $status = "healthy"
    if ($crit -gt 0) { $status = "unhealthy" }
    elseif ($warn -gt 0) { $status = "degraded" }
    $report = [ordered]@{
      schemaVersion = 1
      timestamp = ([DateTimeOffset]::UtcNow.ToString("o"))
      status = $status
      checks = @($checks)
    }
    $reportPath = ""
    $repErr = ""
    try {
      $rdir = Split-Path -Parent $Paths.DoctorReport
      if (-not (Test-Path -LiteralPath $rdir)) { New-Item -ItemType Directory -Path $rdir -Force -ErrorAction Stop | Out-Null }
      $rtmp = $Paths.DoctorReport + ".tmp-" + [System.Diagnostics.Process]::GetCurrentProcess().Id
      ($report | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $rtmp -Encoding utf8 -ErrorAction Stop
      if (Test-Path -LiteralPath $Paths.DoctorReport) {
        $rbak = $Paths.DoctorReport + ".bak"
        [System.IO.File]::Replace($rtmp, $Paths.DoctorReport, $rbak) | Out-Null
        try { Remove-Item -LiteralPath $rbak -Force -ErrorAction SilentlyContinue } catch { }
      } else {
        Move-Item -LiteralPath $rtmp -Destination $Paths.DoctorReport -Force -ErrorAction Stop
      }
      $reportPath = $Paths.DoctorReport
    } catch {
      $repErr = $_.Exception.Message
    }
    return @{ Status = $status; Checks = $checks; ReportPath = $reportPath; Error = $repErr }
  } catch {
    return @{ Status = "unhealthy"; Checks = @(); ReportPath = ""; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Allowlist self-heal behind the circuit breaker. Never throws.
.DESCRIPTION
  Allowed ONLY: start stopped owned tasks, restart owned runtime (stop via
  Stop-PiServerRuntime + task start), kill stale OWNED --mode rpc orphans,
  clear stale OWNED listener, recover incomplete update transaction,
  rollback active pointer to previousVersion, repoint stale task actions
  to bin\, regenerate machine env from trusted local probing.
  Forbidden: arbitrary process kill, arbitrary shell/services/registry/
  filesystem. Max 3 automatic attempts per 10 minutes, then refuse.
  Injectable hooks mirror the update engine plus:
    TaskStarter:       param($TaskName) -> @{ Ok; Detail }
    TaskActionUpdater: param($TaskName,$LauncherPath) -> @{ Ok; Detail }
    EnvProber:         param() -> @{ Ok; Env; Error }
#>
function Invoke-DoctorRepair {
  param(
    [hashtable]$Paths = $null,
    [string[]]$Only = @(),
    [scriptblock]$TaskReader = $null,
    [scriptblock]$TaskStarter = $null,
    [scriptblock]$ProcessProbe = $null,
    [scriptblock]$Stopper = $null,
    [scriptblock]$ConnectionReader = $null,
    [scriptblock]$TaskActionUpdater = $null,
    [scriptblock]$EnvProber = $null,
    [scriptblock]$StartRuntime = $null,
    [scriptblock]$VerifyHealth = $null
  )
  try {
    if ($null -eq $Paths) { return @{ Ok = $false; Repaired = @(); Detail = "paths nulli" } }
    $cb = Test-DoctorCircuit -CircuitPath $Paths.DoctorCircuit
    if (-not $cb.Allowed) {
      return @{ Ok = $false; Repaired = @(); Detail = $cb.Error }
    }
    $doc = Invoke-ServerDoctor -Paths $Paths -TaskReader $TaskReader -ProcessProbe $ProcessProbe `
      -ConnectionReader $ConnectionReader
    $repaired = @()
    $notes = @()
    $want = { param($n) (@($Only).Count -eq 0) -or (@($Only) -contains $n) }
    $failOf = {
      param($n)
      foreach ($c in $doc.Checks) { if ($c.name -eq $n) { return (-not $c.ok) } }
      return $false
    }
    if ((& $want "tasks") -and ((& $failOf ("task_" + $Paths.TaskName)) -or (& $failOf ("task_" + $Paths.RemoteTaskName)))) {
      if ($null -ne $TaskStarter) {
        foreach ($tn in @($Paths.TaskName, $Paths.RemoteTaskName)) {
          if (& $failOf ("task_" + $tn)) {
            $sr = & $TaskStarter $tn
            if ($sr.Ok) { $repaired += ("task_started:" + $tn) } else { $notes += ("task_start fallito " + $tn + ": " + (Get-HookDetail $sr)) }
          }
        }
      } else {
        $notes += "task riparabili ma TaskStarter assente"
      }
    }
    if ((& $want "orphans") -and (& $failOf "mode_rpc_orphans")) {
      $stop = Stop-PiServerRuntime -Paths $Paths -RemotePort 0 -TimeoutSec 20 `
        -TaskReader { param($n) return $null } -ProcessProbe $ProcessProbe -Stopper $Stopper
      if ($stop.Ok) { $repaired += "orphans_swept" } else { $notes += ("sweep orfani fallito: " + (Get-HookDetail $stop)) }
    }
    if ((& $want "listener") -and (& $failOf "remote_listener")) {
      $clr = Clear-OwnPortListener -Port $Paths.RemotePortDefault -Paths $Paths `
        -OwnerReader $ConnectionReader -Stopper $Stopper -TimeoutSec 15
      if ($clr.Ok) { $repaired += "listener_cleared" } else { $notes += ("listener non liberabile: " + (Get-HookDetail $clr)) }
    }
    if ((& $want "transaction") -and ((& $failOf "update_transaction") -or (& $failOf "active_release"))) {
      $rec = Invoke-UpdateRecovery -Paths $Paths -StartRuntime $StartRuntime -VerifyHealth $VerifyHealth
      if ($rec.Ok) { $repaired += ("transaction:" + $rec.Action) } else { $notes += ("recovery fallita: " + (Get-HookDetail $rec)) }
    }
    if ((& $want "taskdefs") -and ($null -ne $TaskActionUpdater)) {
      foreach ($t in @(@{ Name = $Paths.TaskName; Launcher = $Paths.BinRunPi }, @{ Name = $Paths.RemoteTaskName; Launcher = $Paths.BinRunRemote })) {
        $u = & $TaskActionUpdater $t.Name $t.Launcher
        if ($u.Ok) { $repaired += ("taskdef_ok:" + $t.Name) } else { $notes += ("taskdef " + $t.Name + ": " + (Get-HookDetail $u)) }
      }
    }
    if ((& $want "runtime_env") -and (& $failOf "runtime_env") -and ($null -ne $EnvProber)) {
      $ep = & $EnvProber
      if ($ep.Ok) {
        $we = Write-MachineEnv -EnvPath $Paths.MachineEnv -Env $ep.Env
        if ($we.Ok) { $repaired += "runtime_env_regenerated" } else { $notes += ("env regen fallita: " + (Get-HookDetail $we "Error")) }
      } else {
        $notes += ("env probing fallito: " + (Get-HookDetail $ep "Error"))
      }
    }
    if ($repaired.Count -gt 0) {
      Write-DoctorCircuit -CircuitPath $Paths.DoctorCircuit | Out-Null
    }
    $verify = Invoke-ServerDoctor -Paths $Paths -TaskReader $TaskReader -ProcessProbe $ProcessProbe `
      -ConnectionReader $ConnectionReader
    $detail = "status dopo repair: " + $verify.Status
    if ($notes.Count -gt 0) { $detail += " | note: " + ($notes -join " | ") }
    return @{ Ok = ($verify.Status -ne "unhealthy"); Repaired = $repaired; Detail = $detail }
  } catch {
    return @{ Ok = $false; Repaired = @(); Detail = $_.Exception.Message }
  }
}
