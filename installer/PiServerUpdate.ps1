<#
.SYNOPSIS
  v0.3.0 persistent-release update engine (pointer-based, no live rename).

.DESCRIPTION
  Dot-source AFTER installer/PiServerLib.ps1 (reuses its stop/port/task
  primitives). No side effects on load: function definitions only.

  Layout:
    <root>\bin\            stable launchers + updater/doctor entry points
    <root>\releases\<ver>\ immutable code (one dir per version)
    <root>\data\           active-release.json, update-state.json, history,
                           doctor-report.json, runtime-env.json (machine facts)
    <root>\logs\           updater.log, doctor.log, runtime logs
    <root>\app\            LEGACY v0.2.x layout (migration source, never renamed)

  5.1 compatible (no ??, ?., ternary). ASCII only. Helpers never throw:
  they return @{ Ok; ... } and let entry points decide.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# v3 payload manifest: v0.2.x files plus the update engine + stable launchers.
$script:ReleaseManifestV3 = @($script:ReleaseManifest | ForEach-Object { $_ }) + @(
  "installer\PiServerUpdate.ps1",
  "installer\PiServerDoctor.ps1",
  "installer\bin\run-pi.ps1",
  "installer\bin\run-remote.ps1",
  "installer\bin\updater.ps1",
  "installer\bin\doctor.ps1"
)

$script:ReleaseVersionRx = '^v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$'
$script:UpdatePhases = @(
  "preflight", "downloaded", "candidate_validated", "candidate_installed",
  "runtime_stopped", "pointer_switched", "runtime_started", "health_verifying",
  "completed", "failed", "rollback_started", "rollback_completed"
)

<#
.SYNOPSIS
  Strict version gate: vX.Y.Z with optional prerelease suffix, nothing else.
#>
function Test-ReleaseVersionFormat {
  param([string]$Version = "")
  try {
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    return ($Version -match $script:ReleaseVersionRx)
  } catch { return $false }
}

<#
.SYNOPSIS
  Read data\active-release.json. Never throws.
.DESCRIPTION
  Returns @{ Ok; Version; Error }. Missing file is NOT Ok (fail closed);
  the caller decides fallback (legacy layout, recovery from update state).
  Rejects non-object JSON, missing/extra-shaped version, bad format.
#>
function Read-ActiveRelease {
  param([string]$PointerPath = "")
  try {
    if ([string]::IsNullOrWhiteSpace($PointerPath)) {
      return @{ Ok = $false; Version = ""; Error = "pointer path vuoto" }
    }
    if (-not (Test-Path -LiteralPath $PointerPath)) {
      return @{ Ok = $false; Version = ""; Error = "pointer assente" }
    }
    $raw = Get-Content -LiteralPath $PointerPath -Raw -ErrorAction Stop
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $ver = ""
    try { $ver = [string]$obj.version } catch { $ver = "" }
    $schema = 0
    try { $schema = [int]$obj.schemaVersion } catch { $schema = 0 }
    if ($schema -ne 1) {
      return @{ Ok = $false; Version = ""; Error = ("schemaVersion non supportato: " + $schema) }
    }
    if (-not (Test-ReleaseVersionFormat -Version $ver)) {
      return @{ Ok = $false; Version = ""; Error = ("versione non valida: " + $ver) }
    }
    return @{ Ok = $true; Version = $ver; Error = "" }
  } catch {
    return @{ Ok = $false; Version = ""; Error = ("pointer illeggibile: " + $_.Exception.Message) }
  }
}

<#
.SYNOPSIS
  Atomic pointer write (temp + OS replace). Never throws.
.DESCRIPTION
  Uses [System.IO.File]::Replace when the pointer exists (atomic on NTFS:
  crash leaves old or new, never half-written). First write (no pointer yet)
  moves a temp file into place; recovery treats a missing pointer as
  pre-migration, never as an implicit version.
#>
function Write-ActiveRelease {
  param([string]$PointerPath = "", [string]$Version = "")
  try {
    if ([string]::IsNullOrWhiteSpace($PointerPath)) {
      return @{ Ok = $false; Error = "pointer path vuoto" }
    }
    if (-not (Test-ReleaseVersionFormat -Version $Version)) {
      return @{ Ok = $false; Error = ("versione non valida: " + $Version) }
    }
    $dir = Split-Path -Parent $PointerPath
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $body = (@{ schemaVersion = 1; version = $Version } | ConvertTo-Json -Depth 3 -Compress)
    $tmp = $PointerPath + ".tmp-" + [System.Diagnostics.Process]::GetCurrentProcess().Id + "-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
      [System.IO.File]::WriteAllText($tmp, $body + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch {
      return @{ Ok = $false; Error = ("scrittura temp fallita: " + $_.Exception.Message) }
    }
    try {
      if (Test-Path -LiteralPath $PointerPath) {
        $bak = $PointerPath + ".bak"
        [System.IO.File]::Replace($tmp, $PointerPath, $bak) | Out-Null
        try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch { }
      } else {
        Move-Item -LiteralPath $tmp -Destination $PointerPath -Force -ErrorAction Stop
      }
    } catch {
      try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
      return @{ Ok = $false; Error = ("switch atomico fallito: " + $_.Exception.Message) }
    }
    $check = Read-ActiveRelease -PointerPath $PointerPath
    if ((-not $check.Ok) -or ($check.Version -ne $Version)) {
      return @{ Ok = $false; Error = ("verifica post-scrittura fallita: " + $check.Error) }
    }
    return @{ Ok = $true; Error = "" }
  } catch {
    return @{ Ok = $false; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Resolve a pointer version to a release dir. Never throws.
.DESCRIPTION
  Version allowlist + canonical-path check: the resolved dir must be a
  DIRECT child of <root>\releases. Rejects .., absolute/UNC/drive paths,
  and missing/minimal-manifest releases. Returns @{ Ok; Dir; Error }.
#>
function Resolve-ReleaseDir {
  param([string]$Root = "", [string]$Version = "")
  try {
    if ([string]::IsNullOrWhiteSpace($Root)) {
      return @{ Ok = $false; Dir = ""; Error = "root vuoto" }
    }
    if (-not (Test-ReleaseVersionFormat -Version $Version)) {
      return @{ Ok = $false; Dir = ""; Error = ("versione non valida: " + $Version) }
    }
    $releases = Join-Path $Root "releases"
    $base = ""
    $full = ""
    try {
      $base = [System.IO.Path]::GetFullPath($releases)
      $full = [System.IO.Path]::GetFullPath((Join-Path $releases $Version))
    } catch {
      return @{ Ok = $false; Dir = ""; Error = ("path non canonico: " + $_.Exception.Message) }
    }
    $parent = Split-Path -Parent $full
    if ($parent -ne $base) {
      return @{ Ok = $false; Dir = ""; Error = "traversal rifiutato (non child diretto di releases)" }
    }
    if (-not (Test-Path -LiteralPath $full)) {
      return @{ Ok = $false; Dir = ""; Error = ("release assente: " + $Version) }
    }
    $daemon = Join-Path $full "server\pi-daemon.mjs"
    if (-not (Test-Path -LiteralPath $daemon)) {
      return @{ Ok = $false; Dir = ""; Error = ("manifest minimo assente in: " + $Version) }
    }
    return @{ Ok = $true; Dir = $full; Error = "" }
  } catch {
    return @{ Ok = $false; Dir = ""; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Validate a candidate payload dir for an expected version. Never throws.
.DESCRIPTION
  Checks v3 manifest files, VERSION content match (normalized with leading
  v), and node --check on the daemon entries when -NodeExe is given
  (empty = syntax gate skipped, reported in Detail).
#>
function Test-ReleaseContent {
  param([string]$PayloadDir = "", [string]$ExpectedVersion = "", [string]$NodeExe = "")
  try {
    if ([string]::IsNullOrWhiteSpace($PayloadDir)) {
      return @{ Ok = $false; Error = "payload dir vuota"; Detail = "" }
    }
    if (-not (Test-ReleaseVersionFormat -Version $ExpectedVersion)) {
      return @{ Ok = $false; Error = ("versione attesa non valida: " + $ExpectedVersion); Detail = "" }
    }
    if (-not (Test-Path -LiteralPath $PayloadDir)) {
      return @{ Ok = $false; Error = "payload assente"; Detail = "" }
    }
    $missing = @()
    foreach ($rel in $script:ReleaseManifestV3) {
      if (-not (Test-Path -LiteralPath (Join-Path $PayloadDir $rel))) { $missing += $rel }
    }
    if ($missing.Count -gt 0) {
      return @{ Ok = $false; Error = ("manifest incompleto (" + $missing.Count + ")"); Detail = ($missing -join "; ") }
    }
    $verRaw = ""
    try { $verRaw = ((Get-Content -LiteralPath (Join-Path $PayloadDir "VERSION") -Raw -ErrorAction Stop) | Out-String).Trim() } catch { $verRaw = "" }
    $verNorm = $verRaw
    if (($verNorm -ne "") -and (-not $verNorm.StartsWith("v"))) { $verNorm = "v" + $verNorm }
    if ($verNorm -ne $ExpectedVersion) {
      return @{ Ok = $false; Error = ("VERSION mismatch (atteso=" + $ExpectedVersion + " trovato=" + $verRaw + ")"); Detail = "" }
    }
    if ([string]::IsNullOrWhiteSpace($NodeExe)) {
      return @{ Ok = $true; Error = ""; Detail = "syntax gate saltato (node assente)" }
    }
    if (-not (Test-Path -LiteralPath $NodeExe)) {
      return @{ Ok = $false; Error = "node assente per syntax gate"; Detail = "" }
    }
    $jsFiles = @(
      (Join-Path $PayloadDir "server\pi-daemon.mjs"),
      (Join-Path $PayloadDir "server\spawn-pi.mjs")
    )
    $bad = @()
    foreach ($jf in $jsFiles) {
      try {
        & $NodeExe --check $jf 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $bad += (Split-Path -Leaf $jf) }
      } catch { $bad += (Split-Path -Leaf $jf) }
    }
    if ($bad.Count -gt 0) {
      return @{ Ok = $false; Error = "syntax JS fallita"; Detail = ($bad -join ", ") }
    }
    return @{ Ok = $true; Error = ""; Detail = "manifest+VERSION+syntax OK" }
  } catch {
    return @{ Ok = $false; Error = $_.Exception.Message; Detail = "" }
  }
}

<#
.SYNOPSIS
  Promote a validated payload into releases\<version> (copy, never move).
  Never throws.
.DESCRIPTION
  If releases\<version> exists: byte-compare VERSION + manifest files.
  Identical -> Reused (idempotent). Different -> fail closed, never
  overwrite. New -> copy (crash-safe: incomplete copies fail the manifest
  check on next run and are removed before failing).
#>
function Install-ReleaseCandidate {
  param([string]$StagingDir = "", [string]$ReleasesRoot = "", [string]$Version = "")
  try {
    if ([string]::IsNullOrWhiteSpace($StagingDir) -or
        [string]::IsNullOrWhiteSpace($ReleasesRoot) -or
        (-not (Test-ReleaseVersionFormat -Version $Version))) {
      return @{ Ok = $false; Reused = $false; Dir = ""; Error = "parametri non validi" }
    }
    $dest = Join-Path $ReleasesRoot $Version
    if (Test-Path -LiteralPath $dest) {
      $same = $true
      $diff = @()
      $cmpFiles = @($script:ReleaseManifestV3 | ForEach-Object { $_ }) + @("VERSION")
      foreach ($rel in $cmpFiles) {
        $a = Join-Path $StagingDir $rel
        $b = Join-Path $dest $rel
        $ha = ""
        $hb = ""
        try { $ha = (Get-FileHash -LiteralPath $a -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $ha = "MISSING-A" }
        try { $hb = (Get-FileHash -LiteralPath $b -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hb = "MISSING-B" }
        if ($ha -ne $hb) { $same = $false; $diff += $rel }
      }
      if ($same) {
        return @{ Ok = $true; Reused = $true; Dir = $dest; Error = "" }
      }
      $show = $diff | Select-Object -First 5
      return @{ Ok = $false; Reused = $false; Dir = ""; Error = ("release esistente con contenuto diverso (fail closed): " + ($show -join ", ")) }
    }
    if (-not (Test-Path -LiteralPath $ReleasesRoot)) {
      New-Item -ItemType Directory -Path $ReleasesRoot -Force -ErrorAction Stop | Out-Null
    }
    try {
      Copy-Item -LiteralPath $StagingDir -Destination $dest -Recurse -Force -ErrorAction Stop
    } catch {
      try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue } catch { }
      return @{ Ok = $false; Reused = $false; Dir = ""; Error = ("copia fallita: " + $_.Exception.Message) }
    }
    $chk = Test-ReleaseContent -PayloadDir $dest -ExpectedVersion $Version
    if (-not $chk.Ok) {
      try { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue } catch { }
      return @{ Ok = $false; Reused = $false; Dir = ""; Error = ("candidate corrotto dopo copia: " + $chk.Error) }
    }
    return @{ Ok = $true; Reused = $false; Dir = $dest; Error = "" }
  } catch {
    return @{ Ok = $false; Reused = $false; Dir = ""; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  List installed releases (version dirs with minimal manifest). Never throws.
#>
function Get-InstalledReleases {
  param([string]$ReleasesRoot = "")
  $none = @()
  try {
    if ([string]::IsNullOrWhiteSpace($ReleasesRoot)) { return ,$none }
    if (-not (Test-Path -LiteralPath $ReleasesRoot)) { return ,$none }
    $out = @()
    foreach ($d in (Get-ChildItem -LiteralPath $ReleasesRoot -Directory -ErrorAction SilentlyContinue)) {
      $v = $d.Name
      if (-not (Test-ReleaseVersionFormat -Version $v)) { continue }
      if (Test-Path -LiteralPath (Join-Path $d.FullName "server\pi-daemon.mjs")) { $out += $v }
    }
    $sorted = @($out | Sort-Object)
    return ,$sorted
  } catch { return ,$none }
}

<#
.SYNOPSIS
  Read data\runtime-env.json machine facts (validated subset). Never throws.
.DESCRIPTION
  Returns @{ Ok; Env; Error } where Env has NodeExe, PiBin, NpmGlobalBin,
  NodeArgs, AgentDir. DaemonScript/RemoteEntry legacy fields are ignored:
  v3 launchers construct code paths from the active pointer.
#>
function Read-MachineEnv {
  param([string]$EnvPath = "")
  try {
    if ([string]::IsNullOrWhiteSpace($EnvPath)) {
      return @{ Ok = $false; Env = $null; Error = "env path vuoto" }
    }
    if (-not (Test-Path -LiteralPath $EnvPath)) {
      return @{ Ok = $false; Env = $null; Error = "runtime-env assente" }
    }
    $obj = (Get-Content -LiteralPath $EnvPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
    $env2 = @{
      NodeExe = ""
      PiBin = ""
      NpmGlobalBin = ""
      NodeArgs = @()
      AgentDir = ""
    }
    try { $env2.NodeExe = [string]$obj.NodeExe } catch { }
    try { $env2.PiBin = [string]$obj.PiBin } catch { }
    try { $env2.NpmGlobalBin = [string]$obj.NpmGlobalBin } catch { }
    try { $env2.AgentDir = [string]$obj.AgentDir } catch { }
    try {
      if ($null -ne $obj.NodeArgs) { $env2.NodeArgs = @($obj.NodeArgs | ForEach-Object { [string]$_ }) }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($env2.NodeExe)) {
      return @{ Ok = $false; Env = $null; Error = "NodeExe mancante" }
    }
    if (-not (Test-Path -LiteralPath $env2.NodeExe)) {
      return @{ Ok = $false; Env = $null; Error = ("node assente: " + $env2.NodeExe) }
    }
    return @{ Ok = $true; Env = $env2; Error = "" }
  } catch {
    return @{ Ok = $false; Env = $null; Error = ("env illeggibile: " + $_.Exception.Message) }
  }
}

<#
.SYNOPSIS
  Write data\runtime-env.json machine facts (atomic temp+replace).
  Never throws.
#>
function Write-MachineEnv {
  param([string]$EnvPath = "", [hashtable]$Env = $null)
  try {
    if ([string]::IsNullOrWhiteSpace($EnvPath)) { return @{ Ok = $false; Error = "env path vuoto" } }
    if ($null -eq $Env) { return @{ Ok = $false; Error = "env nullo" } }
    foreach ($k in @("NodeExe", "AgentDir")) {
      if ([string]::IsNullOrWhiteSpace([string]$Env[$k])) {
        return @{ Ok = $false; Error = ("campo obbligatorio mancante: " + $k) }
      }
    }
    $dir = Split-Path -Parent $EnvPath
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $doc = [ordered]@{
      NodeExe = [string]$Env["NodeExe"]
      PiBin = [string]$Env["PiBin"]
      NpmGlobalBin = [string]$Env["NpmGlobalBin"]
      NodeArgs = @($Env["NodeArgs"] | ForEach-Object { [string]$_ })
      AgentDir = [string]$Env["AgentDir"]
    }
    $tmp = $EnvPath + ".tmp-" + [System.Diagnostics.Process]::GetCurrentProcess().Id
    ($doc | ConvertTo-Json -Depth 3) | Out-File -LiteralPath $tmp -Encoding utf8 -ErrorAction Stop
    if (Test-Path -LiteralPath $EnvPath) {
      $bak = $EnvPath + ".bak"
      [System.IO.File]::Replace($tmp, $EnvPath, $bak) | Out-Null
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch { }
    } else {
      Move-Item -LiteralPath $tmp -Destination $EnvPath -Force -ErrorAction Stop
    }
    return @{ Ok = $true; Error = "" }
  } catch {
    return @{ Ok = $false; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Resolve runtime code paths for a release version. Never throws.
.DESCRIPTION
  Combines pointer resolution with the machine env: returns DaemonScript,
  SpawnScript, RemoteEntry, NodeExe, NodeArgs, AgentDir for the release.
#>
function Get-ReleaseRuntime {
  param([string]$Root = "", [string]$Version = "", [string]$EnvPath = "")
  try {
    $rd = Resolve-ReleaseDir -Root $Root -Version $Version
    if (-not $rd.Ok) { return @{ Ok = $false; Error = $rd.Error } }
    $me = Read-MachineEnv -EnvPath $EnvPath
    if (-not $me.Ok) {
      $legacyEnv = Join-Path $rd.Dir "runtime-env.json"
      $me = Read-MachineEnv -EnvPath $legacyEnv
      if (-not $me.Ok) {
        return @{ Ok = $false; Error = ("machine env indisponibile: " + $me.Error) }
      }
    }
    $daemon = Join-Path $rd.Dir "server\pi-daemon.mjs"
    $spawn = Join-Path $rd.Dir "server\spawn-pi.mjs"
    $remote = Join-Path $rd.Dir "server\pi-remote-server\index.ts"
    foreach ($need in @($daemon, $remote)) {
      if (-not (Test-Path -LiteralPath $need)) {
        return @{ Ok = $false; Error = ("file release mancante: " + $need) }
      }
    }
    return @{
      Ok = $true
      Error = ""
      ReleaseDir = $rd.Dir
      DaemonScript = $daemon
      SpawnScript = $spawn
      RemoteEntry = $remote
      NodeExe = $me.Env.NodeExe
      NodeArgs = @($me.Env.NodeArgs)
      PiBin = $me.Env.PiBin
      NpmGlobalBin = $me.Env.NpmGlobalBin
      AgentDir = $me.Env.AgentDir
    }
  } catch {
    return @{ Ok = $false; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Read data\update-state.json (crash-safe transaction record). Never throws.
.DESCRIPTION
  Missing file returns @{ Found = $false } (no transaction ever started).
  Corrupt file returns @{ Found = $true; Corrupt = $true } so recovery can
  quarantine it instead of guessing. No secrets are ever stored here.
#>
<#
.SYNOPSIS
  Safe Detail/Error read from an injectable hook result. Never throws.
.DESCRIPTION
  Hook fakes in tests (and future daemon hooks) may omit the cosmetic
  Detail/Error key; under Set-StrictMode a missing key throws. Required
  fields (.Ok) stay strict on purpose: a missing .Ok is a contract
  violation and must surface loudly.
#>
function Get-HookDetail {
  param($HookResult, [string]$Field = "Detail")
  try {
    if ($null -eq $HookResult) { return "" }
    if ([string]::IsNullOrWhiteSpace($Field)) { return "" }
    $v = $HookResult.$Field
    if ($null -eq $v) { return "" }
    return [string]$v
  } catch { return "" }
}

function Read-UpdateState {
  param([string]$StatePath = "")
  try {
    if ([string]::IsNullOrWhiteSpace($StatePath)) {
      return @{ Found = $false; Corrupt = $false; State = $null; Error = "state path vuoto" }
    }
    if (-not (Test-Path -LiteralPath $StatePath)) {
      return @{ Found = $false; Corrupt = $false; State = $null; Error = "" }
    }
    $obj = (Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
    $st = @{
      schemaVersion = 1
      transactionId = ""
      fromVersion = ""
      toVersion = ""
      phase = ""
      previousVersion = ""
      startedAt = ""
      updatedAt = ""
    }
    try { $st.schemaVersion = [int]$obj.schemaVersion } catch { }
    try { $st.transactionId = [string]$obj.transactionId } catch { }
    try { $st.fromVersion = [string]$obj.fromVersion } catch { }
    try { $st.toVersion = [string]$obj.toVersion } catch { }
    try { $st.phase = [string]$obj.phase } catch { }
    try { $st.previousVersion = [string]$obj.previousVersion } catch { }
    try { $st.startedAt = [string]$obj.startedAt } catch { }
    try { $st.updatedAt = [string]$obj.updatedAt } catch { }
    if ($st.schemaVersion -ne 1) {
      return @{ Found = $true; Corrupt = $true; State = $null; Error = "schemaVersion non supportato" }
    }
    if ([string]::IsNullOrWhiteSpace($st.transactionId) -or
        (-not (Test-ReleaseVersionFormat -Version $st.fromVersion)) -or
        (-not (Test-ReleaseVersionFormat -Version $st.toVersion)) -or
        ($script:UpdatePhases -notcontains $st.phase)) {
      return @{ Found = $true; Corrupt = $true; State = $null; Error = "campi transazione non validi" }
    }
    if (($st.previousVersion -ne "") -and (-not (Test-ReleaseVersionFormat -Version $st.previousVersion))) {
      return @{ Found = $true; Corrupt = $true; State = $null; Error = "previousVersion non valida" }
    }
    return @{ Found = $true; Corrupt = $false; State = $st; Error = "" }
  } catch {
    return @{ Found = $true; Corrupt = $true; State = $null; Error = ("state illeggibile: " + $_.Exception.Message) }
  }
}

<#
.SYNOPSIS
  Atomic update-state write (temp + OS replace). Never throws.
#>
function Write-UpdateState {
  param([string]$StatePath = "", [hashtable]$State = $null)
  try {
    if ([string]::IsNullOrWhiteSpace($StatePath)) { return @{ Ok = $false; Error = "state path vuoto" } }
    if ($null -eq $State) { return @{ Ok = $false; Error = "state nullo" } }
    if ([string]::IsNullOrWhiteSpace([string]$State["transactionId"])) {
      return @{ Ok = $false; Error = "transactionId mancante" }
    }
    if (($script:UpdatePhases -notcontains [string]$State["phase"])) {
      return @{ Ok = $false; Error = ("phase non valida: " + [string]$State["phase"]) }
    }
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $doc = [ordered]@{
      schemaVersion = 1
      transactionId = [string]$State["transactionId"]
      fromVersion = [string]$State["fromVersion"]
      toVersion = [string]$State["toVersion"]
      phase = [string]$State["phase"]
      previousVersion = [string]$State["previousVersion"]
      startedAt = [string]$State["startedAt"]
      updatedAt = ([DateTimeOffset]::UtcNow.ToString("o"))
    }
    $tmp = $StatePath + ".tmp-" + [System.Diagnostics.Process]::GetCurrentProcess().Id
    ($doc | ConvertTo-Json -Depth 3) | Out-File -LiteralPath $tmp -Encoding utf8 -ErrorAction Stop
    if (Test-Path -LiteralPath $StatePath) {
      $bak = $StatePath + ".bak"
      [System.IO.File]::Replace($tmp, $StatePath, $bak) | Out-Null
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch { }
    } else {
      Move-Item -LiteralPath $tmp -Destination $StatePath -Force -ErrorAction Stop
    }
    return @{ Ok = $true; Error = "" }
  } catch {
    return @{ Ok = $false; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Clear a terminal update-state (completed/failed/rollback_completed).
  Never throws. Non-terminal states are left alone (recovery owns them).
#>
function Clear-UpdateState {
  param([string]$StatePath = "")
  try {
    $cur = Read-UpdateState -StatePath $StatePath
    if (-not $cur.Found) { return @{ Ok = $true; Cleared = $false; Error = "" } }
    if ($cur.Corrupt) {
      $q = $StatePath + ".corrupt-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      try { Move-Item -LiteralPath $StatePath -Destination $q -Force -ErrorAction Stop } catch { }
      return @{ Ok = $true; Cleared = $true; Error = "" }
    }
    if (@("completed", "failed", "rollback_completed") -contains $cur.State.phase) {
      try { Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop } catch { }
      return @{ Ok = $true; Cleared = $true; Error = "" }
    }
    return @{ Ok = $true; Cleared = $false; Error = "" }
  } catch {
    return @{ Ok = $false; Cleared = $false; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Append one JSON line to data\update-history.jsonl. Never throws.
#>
function Add-UpdateHistory {
  param([string]$HistoryPath = "", [hashtable]$Entry = $null)
  try {
    if ([string]::IsNullOrWhiteSpace($HistoryPath)) { return @{ Ok = $false; Error = "history path vuoto" } }
    if ($null -eq $Entry) { return @{ Ok = $false; Error = "entry nulla" } }
    $dir = Split-Path -Parent $HistoryPath
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $doc = [ordered]@{
      timestamp = ([DateTimeOffset]::UtcNow.ToString("o"))
      transactionId = [string]$Entry["transactionId"]
      fromVersion = [string]$Entry["fromVersion"]
      toVersion = [string]$Entry["toVersion"]
      result = [string]$Entry["result"]
      durationMs = [long]$Entry["durationMs"]
      rollback = [bool]$Entry["rollback"]
      healthBefore = [string]$Entry["healthBefore"]
      healthAfter = [string]$Entry["healthAfter"]
    }
    (($doc | ConvertTo-Json -Depth 3 -Compress) + [Environment]::NewLine) | Out-File -LiteralPath $HistoryPath -Encoding utf8 -Append -ErrorAction Stop
    return @{ Ok = $true; Error = "" }
  } catch {
    return @{ Ok = $false; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Deterministic crash recovery for an interrupted update. Never throws.
.DESCRIPTION
  Reads update-state + pointer and finishes what the crash interrupted.
  -StopRuntime/-StartRuntime/-VerifyHealth are injectable scriptblocks
  (production wires task/port/API checks; tests wire fakes):
    StopRuntime:  param($Paths) -> @{ Ok; Detail }
    StartRuntime: param($Paths) -> @{ Ok; Detail }
    VerifyHealth: param($Paths,$Version) -> @{ Ok; Detail }
  Returns @{ Ok; Action; Detail } where Action names what was done
  (nothing_to_do, resumed_old_running, switched_verified_completed,
  rolled_back_healthy, state_quarantined, ...). Fail closed: when the old
  release cannot be verified either, reports manual_intervention_required
  and never guesses a version.
#>
function Invoke-UpdateRecovery {
  param(
    [hashtable]$Paths = $null,
    [scriptblock]$StopRuntime = $null,
    [scriptblock]$StartRuntime = $null,
    [scriptblock]$VerifyHealth = $null
  )
  try {
    if ($null -eq $Paths) { return @{ Ok = $false; Action = "no_paths"; Detail = "paths nulli" } }
    $st = Read-UpdateState -StatePath $Paths.UpdateState
    if (-not $st.Found) { return @{ Ok = $true; Action = "nothing_to_do"; Detail = "nessuna transazione" } }
    if ($st.Corrupt) {
      $q = $Paths.UpdateState + ".corrupt-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      try { Move-Item -LiteralPath $Paths.UpdateState -Destination $q -Force -ErrorAction Stop } catch { }
      return @{ Ok = $false; Action = "state_quarantined"; Detail = ("state corrotto, quarantena: " + $st.Error) }
    }
    $s = $st.State
    $ptr = Read-ActiveRelease -PointerPath $Paths.ActivePointer
    $stopFn = $StopRuntime
    if ($null -eq $stopFn) { $stopFn = { param($p) return @{ Ok = $true; Detail = "stop skipped (no hook)" } } }
    $startFn = $StartRuntime
    if ($null -eq $startFn) { $startFn = { param($p) return @{ Ok = $true; Detail = "start skipped (no hook)" } } }
    $healthFn = $VerifyHealth
    if ($null -eq $healthFn) { $healthFn = { param($p, $v) return @{ Ok = $true; Detail = "health skipped (no hook)" } } }

    switch ($s.phase) {
      "completed" {
        Clear-UpdateState -StatePath $Paths.UpdateState | Out-Null
        return @{ Ok = $true; Action = "nothing_to_do"; Detail = "transazione gia completata" }
      }
      "failed" {
        Clear-UpdateState -StatePath $Paths.UpdateState | Out-Null
        return @{ Ok = $true; Action = "nothing_to_do"; Detail = "transazione gia chiusa (failed)" }
      }
      "rollback_completed" {
        Clear-UpdateState -StatePath $Paths.UpdateState | Out-Null
        return @{ Ok = $true; Action = "nothing_to_do"; Detail = "rollback gia completato" }
      }
      { $_ -in @("preflight", "downloaded", "candidate_validated", "candidate_installed") } {
        $h = & $healthFn $Paths $s.fromVersion
        if ($h.Ok) {
          return @{ Ok = $true; Action = "old_verified_safe_to_resume"; Detail = ("pointer ancora su " + $s.fromVersion + ", update ripristinabile") }
        }
        $st2 = & $startFn $Paths
        $h2 = & $healthFn $Paths $s.fromVersion
        if ($st2.Ok -and $h2.Ok) {
          return @{ Ok = $true; Action = "resumed_old_running"; Detail = "runtime precedente riavviato e verificato" }
        }
        return @{ Ok = $false; Action = "manual_intervention_required"; Detail = ("precedente non verificabile: " + (Get-HookDetail $h2)) }
      }
      "runtime_stopped" {
        $st2 = & $startFn $Paths
        $h2 = & $healthFn $Paths $s.fromVersion
        if ($st2.Ok -and $h2.Ok) {
          return @{ Ok = $true; Action = "resumed_old_running"; Detail = "runtime precedente riavviato dopo crash in stop" }
        }
        return @{ Ok = $false; Action = "manual_intervention_required"; Detail = ("precedente non verificabile: " + (Get-HookDetail $h2)) }
      }
      { $_ -in @("pointer_switched", "runtime_started", "health_verifying") } {
        $st2 = & $startFn $Paths
        $h2 = & $healthFn $Paths $s.toVersion
        if ($st2.Ok -and $h2.Ok) {
          $s.phase = "completed"
          Write-UpdateState -StatePath $Paths.UpdateState -State $s | Out-Null
          return @{ Ok = $true; Action = "switched_verified_completed"; Detail = ("nuova release verificata: " + $s.toVersion) }
        }
        return (Invoke-UpdateRollback -Paths $Paths -State $s -StartRuntime $startFn -VerifyHealth $healthFn)
      }
      "rollback_started" {
        return (Invoke-UpdateRollback -Paths $Paths -State $s -StartRuntime $startFn -VerifyHealth $healthFn)
      }
      default {
        return @{ Ok = $false; Action = "manual_intervention_required"; Detail = ("phase sconosciuta: " + $s.phase) }
      }
    }
  } catch {
    return @{ Ok = $false; Action = "manual_intervention_required"; Detail = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Pointer rollback to previousVersion + restart + verify. Never throws.
#>
function Invoke-UpdateRollback {
  param(
    [hashtable]$Paths = $null,
    [hashtable]$State = $null,
    [scriptblock]$StartRuntime = $null,
    [scriptblock]$VerifyHealth = $null
  )
  try {
    if (($null -eq $Paths) -or ($null -eq $State)) {
      return @{ Ok = $false; Action = "manual_intervention_required"; Detail = "paths/state nulli" }
    }
    $prev = [string]$State["previousVersion"]
    if (-not (Test-ReleaseVersionFormat -Version $prev)) {
      return @{ Ok = $false; Action = "manual_intervention_required"; Detail = "previousVersion assente/non valida" }
    }
    $rd = Resolve-ReleaseDir -Root $Paths.Root -Version $prev
    if (-not $rd.Ok) {
      return @{ Ok = $false; Action = "manual_intervention_required"; Detail = ("release precedente inutilizzabile: " + $rd.Error) }
    }
    $State["phase"] = "rollback_started"
    Write-UpdateState -StatePath $Paths.UpdateState -State $State | Out-Null
    $sw = Write-ActiveRelease -PointerPath $Paths.ActivePointer -Version $prev
    if (-not $sw.Ok) {
      return @{ Ok = $false; Action = "manual_intervention_required"; Detail = ("pointer rollback fallito: " + $sw.Error) }
    }
    $startFn = $StartRuntime
    if ($null -eq $startFn) { $startFn = { param($p) return @{ Ok = $true; Detail = "start skipped" } } }
    $healthFn = $VerifyHealth
    if ($null -eq $healthFn) { $healthFn = { param($p, $v) return @{ Ok = $true; Detail = "health skipped" } } }
    $st2 = & $startFn $Paths
    $h2 = & $healthFn $Paths $prev
    if ($st2.Ok -and $h2.Ok) {
      $State["phase"] = "rollback_completed"
      Write-UpdateState -StatePath $Paths.UpdateState -State $State | Out-Null
      return @{ Ok = $true; Action = "rolled_back_healthy"; Detail = ("rollback su " + $prev + " verificato") }
    }
    return @{ Ok = $false; Action = "manual_intervention_required"; Detail = ("precedente non verificabile dopo rollback: " + (Get-HookDetail $h2)) }
  } catch {
    return @{ Ok = $false; Action = "manual_intervention_required"; Detail = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Health gate for a release version (injectable primitives). Never throws.
.DESCRIPTION
  Default primitives are best-effort local checks; production wires
  task/port/API checkers, tests wire fakes:
    TaskChecker:  param($Paths) -> @{ PiRunning; RemoteRunning; Detail }
    PortChecker:  param($Port) -> @{ Listening; Pid; CommandLine; Detail }
    ApiChecker:   param($Paths) -> @{ Ok; Detail }
    VersionReader:param($Paths) -> @{ Ok; Version }
  A release is HEALTHY only if tasks run, the port is owned, the API
  answers and the running code reports the expected version.
#>
function Test-ReleaseHealth {
  param(
    [hashtable]$Paths = $null,
    [string]$Version = "",
    [int]$Port = 43128,
    [scriptblock]$TaskChecker = $null,
    [scriptblock]$PortChecker = $null,
    [scriptblock]$ApiChecker = $null,
    [scriptblock]$VersionReader = $null
  )
  try {
    if (($null -eq $Paths) -or (-not (Test-ReleaseVersionFormat -Version $Version))) {
      return @{ Ok = $false; Detail = "paths/versione non validi" }
    }
    $fails = @()
    if ($null -ne $TaskChecker) {
      $t = & $TaskChecker $Paths
      if ((-not $t.PiRunning) -or (-not $t.RemoteRunning)) {
        $fails += ("tasks: " + (Get-HookDetail $t))
      }
    }
    if ($null -ne $PortChecker) {
      $po = & $PortChecker $Port
      if (-not $po.Listening) {
        $fails += ("porta " + $Port + " non in ascolto")
      } elseif ([string]$po.CommandLine -notmatch "pi-remote-server") {
        $fails += ("porta posseduta da estraneo (pid " + $po.Pid + ")")
      }
    }
    if ($null -ne $ApiChecker) {
      $a = & $ApiChecker $Paths
      if (-not $a.Ok) { $fails += ("api: " + (Get-HookDetail $a)) }
    }
    if ($null -ne $VersionReader) {
      $vr = & $VersionReader $Paths
      if ((-not $vr.Ok) -or ([string]$vr.Version -ne $Version)) {
        $fails += ("versione attiva=" + [string]$vr.Version + " attesa=" + $Version + " " + (Get-HookDetail $vr))
      }
    } else {
      $rd = Resolve-ReleaseDir -Root $Paths.Root -Version $Version
      if (-not $rd.Ok) { $fails += ("release non risolvibile: " + $rd.Error) }
    }
    if ($fails.Count -gt 0) {
      return @{ Ok = $false; Detail = ($fails -join " | ") }
    }
    return @{ Ok = $true; Detail = ("healthy " + $Version) }
  } catch {
    return @{ Ok = $false; Detail = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Full pointer-based update: candidate -> quiesce -> switch -> verify.
  Never throws.
.DESCRIPTION
  -StagingDir is a validated payload dir (download/extract/checksum stays
  in the caller: installer or remote apply handler). Phases are recorded
  in update-state.json; any health failure triggers automatic pointer
  rollback. History is appended on every terminal outcome. Live releases
  are never renamed, moved or overwritten: only the pointer file changes.
  Injectable hooks (same shape as Invoke-UpdateRecovery plus TaskChecker,
  PortChecker, ApiChecker, VersionReader for Test-ReleaseHealth).
#>
function Invoke-ReleaseUpdate {
  param(
    [hashtable]$Paths = $null,
    [string]$TargetVersion = "",
    [string]$StagingDir = "",
    [string]$NodeExe = "",
    [scriptblock]$StopRuntime = $null,
    [scriptblock]$StartRuntime = $null,
    [scriptblock]$TaskChecker = $null,
    [scriptblock]$PortChecker = $null,
    [scriptblock]$ApiChecker = $null,
    [scriptblock]$VersionReader = $null
  )
  $t0 = [DateTimeOffset]::UtcNow
  $tx = "upd-" + $t0.ToUnixTimeSeconds() + "-" + [System.Diagnostics.Process]::GetCurrentProcess().Id
  $hist = @{
    transactionId = $tx; fromVersion = ""; toVersion = $TargetVersion
    result = ""; durationMs = 0; rollback = $false
    healthBefore = ""; healthAfter = ""
  }
  try {
    if (($null -eq $Paths) -or (-not (Test-ReleaseVersionFormat -Version $TargetVersion))) {
      $hist.result = "rejected_bad_params"
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $false; Action = "rejected"; Detail = "paths/versione non validi" }
    }
    $hist.toVersion = $TargetVersion
    $ptr = Read-ActiveRelease -PointerPath $Paths.ActivePointer
    if (-not $ptr.Ok) {
      $hist.result = "rejected_no_active"
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $false; Action = "rejected"; Detail = ("active pointer non valido: " + $ptr.Error) }
    }
    $from = $ptr.Version
    $hist.fromVersion = $from
    if ($from -eq $TargetVersion) {
      $hist.result = "noop_already_active"
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $true; Action = "noop"; Detail = ("già attivo: " + $from) }
    }
    $st = @{
      schemaVersion = 1; transactionId = $tx
      fromVersion = $from; toVersion = $TargetVersion
      phase = "preflight"; previousVersion = $from
      startedAt = ($t0.ToString("o")); updatedAt = ""
    }
    $phase = { param($p) $st.phase = $p; Write-UpdateState -StatePath $Paths.UpdateState -State $st | Out-Null }
    $healthOf = {
      param($v)
      return (Test-ReleaseHealth -Paths $Paths -Version $v -Port $Paths.RemotePortDefault `
        -TaskChecker $TaskChecker -PortChecker $PortChecker -ApiChecker $ApiChecker -VersionReader $VersionReader)
    }
    $hb = & $healthOf $from
    $hist.healthBefore = (& { if ($hb.Ok) { "healthy" } else { "unhealthy: " + (Get-HookDetail $hb) } })
    & $phase "preflight"
    $cv = Test-ReleaseContent -PayloadDir $StagingDir -ExpectedVersion $TargetVersion -NodeExe $NodeExe
    if (-not $cv.Ok) {
      $st.phase = "failed"
      Write-UpdateState -StatePath $Paths.UpdateState -State $st | Out-Null
      $hist.result = "rejected_bad_candidate"
      $hist.durationMs = [long]([DateTimeOffset]::UtcNow - $t0).TotalMilliseconds
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $false; Action = "rejected"; Detail = ("candidate non valido: " + $cv.Error + " " + $cv.Detail) }
    }
    & $phase "candidate_validated"
    $inst = Install-ReleaseCandidate -StagingDir $StagingDir -ReleasesRoot $Paths.Releases -Version $TargetVersion
    if (-not $inst.Ok) {
      $st.phase = "failed"
      Write-UpdateState -StatePath $Paths.UpdateState -State $st | Out-Null
      $hist.result = "rejected_install"
      $hist.durationMs = [long]([DateTimeOffset]::UtcNow - $t0).TotalMilliseconds
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $false; Action = "rejected"; Detail = ("installazione candidate fallita: " + $inst.Error) }
    }
    & $phase "candidate_installed"
    $stopFn = $StopRuntime
    if ($null -eq $stopFn) { $stopFn = { param($p) return @{ Ok = $true; Detail = "stop skipped" } } }
    $stp = & $stopFn $Paths
    if (-not $stp.Ok) {
      $st.phase = "failed"
      Write-UpdateState -StatePath $Paths.UpdateState -State $st | Out-Null
      $hist.result = "failed_stop"
      $hist.durationMs = [long]([DateTimeOffset]::UtcNow - $t0).TotalMilliseconds
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $false; Action = "failed"; Detail = ("quiesce fallito, pointer intatto su " + $from + ": " + (Get-HookDetail $stp)) }
    }
    & $phase "runtime_stopped"
    $sw = Write-ActiveRelease -PointerPath $Paths.ActivePointer -Version $TargetVersion
    if (-not $sw.Ok) {
      $st.phase = "failed"
      Write-UpdateState -StatePath $Paths.UpdateState -State $st | Out-Null
      $hist.result = "failed_switch"
      $hist.durationMs = [long]([DateTimeOffset]::UtcNow - $t0).TotalMilliseconds
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $false; Action = "failed"; Detail = ("switch pointer fallito (runtime fermo, pointer su " + $from + "): " + $sw.Error) }
    }
    & $phase "pointer_switched"
    $startFn = $StartRuntime
    if ($null -eq $startFn) { $startFn = { param($p) return @{ Ok = $true; Detail = "start skipped" } } }
    $str = & $startFn $Paths
    & $phase "runtime_started"
    & $phase "health_verifying"
    $okStart = $str.Ok
    $ha = & $healthOf $TargetVersion
    $hist.healthAfter = (& { if ($ha.Ok) { "healthy" } else { "unhealthy: " + (Get-HookDetail $ha) } })
    if ($okStart -and $ha.Ok) {
      $st.phase = "completed"
      Write-UpdateState -StatePath $Paths.UpdateState -State $st | Out-Null
      Clear-UpdateState -StatePath $Paths.UpdateState | Out-Null
      $hist.result = "completed"
      $hist.durationMs = [long]([DateTimeOffset]::UtcNow - $t0).TotalMilliseconds
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $true; Action = "updated"; Detail = ($from + " -> " + $TargetVersion + " verificato") }
    }
    $rb = Invoke-UpdateRollback -Paths $Paths -State $st -StartRuntime $startFn -VerifyHealth {
      param($p, $v)
      return (Test-ReleaseHealth -Paths $p -Version $v -Port $p.RemotePortDefault `
        -TaskChecker $TaskChecker -PortChecker $PortChecker -ApiChecker $ApiChecker -VersionReader $VersionReader)
    }
    $hist.rollback = $true
    $hist.durationMs = [long]([DateTimeOffset]::UtcNow - $t0).TotalMilliseconds
    if ($rb.Ok) {
      $hist.result = "update_failed_rollback_healthy"
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
      return @{ Ok = $false; Action = "rolled_back"; Detail = ("nuova release non sana (" + (Get-HookDetail $ha) + "); rollback su " + $from + " verificato") }
    }
    $hist.result = "update_failed_rollback_failed"
    Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
    return @{ Ok = $false; Action = "manual_intervention_required"; Detail = ("nuova release non sana E rollback fallito: " + $rb.Detail) }
  } catch {
    try {
      $hist.result = "exception"
      $hist.durationMs = [long]([DateTimeOffset]::UtcNow - $t0).TotalMilliseconds
      Add-UpdateHistory -HistoryPath $Paths.UpdateHistory -Entry $hist | Out-Null
    } catch { }
    return @{ Ok = $false; Action = "manual_intervention_required"; Detail = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Detect a legacy v0.2.x layout (C:\PiServer\app). Never throws.
#>
function Test-LegacyLayout {
  param([hashtable]$Paths = $null)
  try {
    if ($null -eq $Paths) { return @{ Found = $false; Version = ""; Error = "paths nulli" } }
    $app = [string]$Paths.App
    if ([string]::IsNullOrWhiteSpace($app)) { return @{ Found = $false; Version = ""; Error = "app path vuoto" } }
    $vf = Join-Path $app "VERSION"
    $dm = Join-Path $app "server\pi-daemon.mjs"
    if ((-not (Test-Path -LiteralPath $vf)) -or (-not (Test-Path -LiteralPath $dm))) {
      return @{ Found = $false; Version = ""; Error = "" }
    }
    $raw = ""
    try { $raw = ((Get-Content -LiteralPath $vf -Raw -ErrorAction Stop) | Out-String).Trim() } catch { $raw = "" }
    $norm = $raw
    if (($norm -ne "") -and (-not $norm.StartsWith("v"))) { $norm = "v" + $norm }
    if (-not (Test-ReleaseVersionFormat -Version $norm)) {
      return @{ Found = $true; Version = ""; Error = ("legacy VERSION non valida: " + $raw) }
    }
    return @{ Found = $true; Version = $norm; Error = "" }
  } catch {
    return @{ Found = $false; Version = ""; Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Copy-only migration from legacy app\ to releases\ + bin\. Never throws.
.DESCRIPTION
  1. Validates the legacy app (VERSION + daemon present).
  2. Creates bin\ + releases\ + data\ dirs.
  3. Copies (never moves) legacy app -> releases\<legacyVersion>.
  4. Promotes legacy runtime-env.json machine facts to data\.
  5. Installs the v0.3.0+ candidate payload into releases\<target>.
  6. Points active-release at the LEGACY snapshot first, repoints tasks
     to bin\, restarts, verifies old code through the NEW launcher.
  7. Switches the pointer to the target, restarts, verifies; on failure
     rolls the pointer back to the legacy snapshot.
  The legacy app\ dir is never renamed, moved or deleted: it stays intact
  for manual recovery. Injectable hooks mirror Invoke-ReleaseUpdate plus:
    TaskActionUpdater: param($TaskName,$LauncherPath) -> @{ Ok; Detail }
#>
function Invoke-LegacyMigration {
  param(
    [hashtable]$Paths = $null,
    [string]$StagingDir = "",
    [string]$TargetVersion = "",
    [string]$NodeExe = "",
    [scriptblock]$StopRuntime = $null,
    [scriptblock]$StartRuntime = $null,
    [scriptblock]$TaskChecker = $null,
    [scriptblock]$PortChecker = $null,
    [scriptblock]$ApiChecker = $null,
    [scriptblock]$VersionReader = $null,
    [scriptblock]$TaskActionUpdater = $null
  )
  try {
    if (($null -eq $Paths) -or (-not (Test-ReleaseVersionFormat -Version $TargetVersion))) {
      return @{ Ok = $false; Action = "rejected"; Detail = "paths/versione non validi" }
    }
    $leg = Test-LegacyLayout -Paths $Paths
    if (-not $leg.Found) {
      return @{ Ok = $false; Action = "rejected"; Detail = ("layout legacy non trovato: " + $leg.Error) }
    }
    if ($leg.Version -eq "") {
      return @{ Ok = $false; Action = "rejected"; Detail = ("legacy VERSION inutilizzabile: " + $leg.Error) }
    }
    $legacyVer = $leg.Version
    $cv = Test-ReleaseContent -PayloadDir $StagingDir -ExpectedVersion $TargetVersion -NodeExe $NodeExe
    if (-not $cv.Ok) {
      return @{ Ok = $false; Action = "rejected"; Detail = ("candidate non valido: " + $cv.Error + " " + $cv.Detail) }
    }
    foreach ($d in @($Paths.Bin, $Paths.Releases, $Paths.Data, $Paths.Logs)) {
      if (-not (Test-Path -LiteralPath $d)) {
        try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
        catch { return @{ Ok = $false; Action = "rejected"; Detail = ("creazione dir fallita: " + $d) } }
      }
    }
    $snapDest = Join-Path $Paths.Releases $legacyVer
    if (-not (Test-Path -LiteralPath $snapDest)) {
      try {
        Copy-Item -LiteralPath $Paths.App -Destination $snapDest -Recurse -Force -ErrorAction Stop
      } catch {
        try { Remove-Item -LiteralPath $snapDest -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        return @{ Ok = $false; Action = "rejected"; Detail = ("snapshot legacy fallito (app intatta): " + $_.Exception.Message) }
      }
    }
    $legacyEnvPath = Join-Path $Paths.App "runtime-env.json"
    $me = Read-MachineEnv -EnvPath $legacyEnvPath
    if ($me.Ok) {
      $wme = Write-MachineEnv -EnvPath $Paths.MachineEnv -Env $me.Env
      if (-not $wme.Ok) {
        return @{ Ok = $false; Action = "rejected"; Detail = ("promozione machine env fallita: " + $wme.Error) }
      }
    } else {
      return @{ Ok = $false; Action = "rejected"; Detail = ("legacy runtime-env inutilizzabile: " + $me.Error) }
    }
    $inst = Install-ReleaseCandidate -StagingDir $StagingDir -ReleasesRoot $Paths.Releases -Version $TargetVersion
    if (-not $inst.Ok) {
      return @{ Ok = $false; Action = "rejected"; Detail = ("installazione target fallita: " + $inst.Error) }
    }
    $wp = Write-ActiveRelease -PointerPath $Paths.ActivePointer -Version $legacyVer
    if (-not $wp.Ok) {
      return @{ Ok = $false; Action = "rejected"; Detail = ("pointer iniziale fallito: " + $wp.Error) }
    }
    $updFn = $TaskActionUpdater
    if ($null -eq $updFn) { $updFn = { param($n, $p) return @{ Ok = $true; Detail = "task updater skipped" } } }
    foreach ($t in @(@{ Name = $Paths.TaskName; Launcher = $Paths.BinRunPi }, @{ Name = $Paths.RemoteTaskName; Launcher = $Paths.BinRunRemote })) {
      $u = & $updFn $t.Name $t.Launcher
      if (-not $u.Ok) {
        return @{ Ok = $false; Action = "rejected"; Detail = ("repoint task fallito (" + $t.Name + "): " + (Get-HookDetail $u) + " (task legacy intatti)") }
      }
    }
    $stopFn = $StopRuntime
    if ($null -eq $stopFn) { $stopFn = { param($p) return @{ Ok = $true; Detail = "stop skipped" } } }
    $startFn = $StartRuntime
    if ($null -eq $startFn) { $startFn = { param($p) return @{ Ok = $true; Detail = "start skipped" } } }
    $healthOf = {
      param($v)
      return (Test-ReleaseHealth -Paths $Paths -Version $v -Port $Paths.RemotePortDefault `
        -TaskChecker $TaskChecker -PortChecker $PortChecker -ApiChecker $ApiChecker -VersionReader $VersionReader)
    }
    $stp = & $stopFn $Paths
    if (-not $stp.Ok) {
      return @{ Ok = $false; Action = "rejected"; Detail = ("stop pre-migrazione fallito: " + (Get-HookDetail $stp)) }
    }
    $str = & $startFn $Paths
    $hLeg = & $healthOf $legacyVer
    if ((-not $str.Ok) -or (-not $hLeg.Ok)) {
      return @{ Ok = $false; Action = "rejected"; Detail = ("legacy via nuovo launcher non sano (server fermo su legacy): " + $hLeg.Detail) }
    }
    $up = Invoke-ReleaseUpdate -Paths $Paths -TargetVersion $TargetVersion -StagingDir $StagingDir `
      -NodeExe $NodeExe -StopRuntime $StopRuntime -StartRuntime $StartRuntime `
      -TaskChecker $TaskChecker -PortChecker $PortChecker -ApiChecker $ApiChecker -VersionReader $VersionReader
    if ($up.Ok) {
      return @{ Ok = $true; Action = "migrated"; Detail = ("legacy " + $legacyVer + " -> " + $TargetVersion + " (app intatta per recovery)") }
    }
    if ($up.Action -eq "rolled_back") {
      return @{ Ok = $false; Action = "migration_rolled_back"; Detail = ("target non sano, pointer su legacy " + $legacyVer + " verificato; server ONLINE") }
    }
    return @{ Ok = $false; Action = $up.Action; Detail = $up.Detail }
  } catch {
    return @{ Ok = $false; Action = "manual_intervention_required"; Detail = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Authenticated liveness ping to the local remote daemon. Never throws.
.DESCRIPTION
  Signs GET /v1/ping exactly like shared/protocol.ts (HMAC-SHA256 over
  METHOD\npath\nts\nonce\nbodyHash). Reads the HMAC file (validates shape,
  never logs content). Returns @{ Ok; Detail }. 10s timeout, localhost only.
#>
function Test-RemoteApiPing {
  param([hashtable]$Paths = $null, [int]$Port = 43128, [int]$TimeoutSec = 10)
  try {
    if ($null -eq $Paths) { return @{ Ok = $false; Detail = "paths nulli" } }
    if (($Port -lt 1) -or ($Port -gt 65535)) { return @{ Ok = $false; Detail = "porta non valida" } }
    $hmacPath = Join-Path $Paths.SecretsDir "remote-hmac"
    if (-not (Test-Path -LiteralPath $hmacPath)) {
      return @{ Ok = $false; Detail = "hmac assente" }
    }
    $secret = ""
    try { $secret = ((Get-Content -LiteralPath $hmacPath -Raw -ErrorAction Stop) | Out-String).Trim() } catch { $secret = "" }
    if (($secret.Length -lt 16) -or ($secret -match "\s")) {
      return @{ Ok = $false; Detail = "hmac non valido" }
    }
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $nonceBytes = New-Object byte[] 16
    try { (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($nonceBytes) }
    catch { (New-Object System.Random).NextBytes($nonceBytes) }
    $nonce = (($nonceBytes | ForEach-Object { $_.ToString("x2") }) -join "")
    $emptyHashBytes = (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.Text.Encoding]::UTF8.GetBytes(""))
    $emptyHash = (($emptyHashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
    $base = "GET`n/v1/ping`n" + $ts + "`n" + $nonce + "`n" + $emptyHash
    $hm = New-Object System.Security.Cryptography.HMACSHA256(, [System.Text.Encoding]::UTF8.GetBytes($secret))
    $sig = (($hm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($base)) | ForEach-Object { $_.ToString("x2") }) -join "")
    try { $hm.Dispose() } catch { }
    $headers = @{
      "X-Pi-Timestamp" = [string]$ts
      "X-Pi-Nonce" = $nonce
      "X-Pi-Signature" = $sig
    }
    $resp = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + "/v1/ping") -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
    $pong = $false
    try { $pong = [bool]$resp.pong } catch { }
    if ($pong) { return @{ Ok = $true; Detail = "pong" } }
    return @{ Ok = $false; Detail = "risposta senza pong" }
  } catch {
    return @{ Ok = $false; Detail = ("ping fallito: " + $_.Exception.Message) }
  }
}

<#
.SYNOPSIS
  Sync payload bin\ launchers into <root>\bin\ (hash-compare, skip if same).
  Never throws. Bootstrap files change rarely; identical content is skipped
  so running tasks never observe a write.
#>
function Install-BinFiles {
  param([string]$PayloadDir = "", [string]$BinDir = "")
  try {
    if ([string]::IsNullOrWhiteSpace($PayloadDir) -or [string]::IsNullOrWhiteSpace($BinDir)) {
      return @{ Ok = $false; Written = @(); Error = "parametri non validi" }
    }
    $srcBin = Join-Path $PayloadDir "installer\bin"
    if (-not (Test-Path -LiteralPath $srcBin)) {
      return @{ Ok = $false; Written = @(); Error = "payload senza installer\\bin" }
    }
    if (-not (Test-Path -LiteralPath $BinDir)) {
      New-Item -ItemType Directory -Path $BinDir -Force -ErrorAction Stop | Out-Null
    }
    $names = @("run-pi.ps1", "run-remote.ps1", "updater.ps1", "doctor.ps1")
    $written = @()
    foreach ($n in $names) {
      $src = Join-Path $srcBin $n
      if (-not (Test-Path -LiteralPath $src)) {
        return @{ Ok = $false; Written = $written; Error = ("launcher mancante nel payload: " + $n) }
      }
      $dst = Join-Path $BinDir $n
      $same = $false
      if (Test-Path -LiteralPath $dst) {
        try {
          $ha = (Get-FileHash -LiteralPath $src -Algorithm SHA256 -ErrorAction Stop).Hash
          $hb = (Get-FileHash -LiteralPath $dst -Algorithm SHA256 -ErrorAction Stop).Hash
          $same = ($ha -eq $hb)
        } catch { $same = $false }
      }
      if (-not $same) {
        try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; $written += $n }
        catch { return @{ Ok = $false; Written = $written; Error = ("scrittura bin fallita (" + $n + "): " + $_.Exception.Message) } }
      }
    }
    foreach ($lib in @("PiServerLib.ps1", "PiServerUpdate.ps1", "PiServerDoctor.ps1")) {
      $lsrc = Join-Path $PayloadDir ("installer\" + $lib)
      if (Test-Path -LiteralPath $lsrc) {
        try { Copy-Item -LiteralPath $lsrc -Destination (Join-Path $BinDir $lib) -Force -ErrorAction Stop } catch { }
      }
    }
    return @{ Ok = $true; Written = $written; Error = "" }
  } catch {
    return @{ Ok = $false; Written = @(); Error = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Layout-aware real-state for v3 deploy/tasks steps. Never throws.
.DESCRIPTION
  "deploy": pointer valid + active release manifest + VERSION match.
  "tasks" (Windows only): both task actions point at bin\ launchers.
  Legacy Test-StepRealState is untouched; the installer branches here
  when a v3 pointer flow is active.
#>
function Test-StepRealStateV3 {
  param([string]$Step = "", $Paths, [string]$ExpectedRelease = "", [scriptblock]$TaskReader = $null)
  try {
    if ($null -eq $Paths) { return $false }
    switch ($Step) {
      "deploy" {
        $ptr = Read-ActiveRelease -PointerPath $Paths.ActivePointer
        if (-not $ptr.Ok) { return $false }
        if (($ExpectedRelease -ne "") -and ($ExpectedRelease -ne "latest") -and ($ptr.Version -ne $ExpectedRelease)) { return $false }
        $rd = Resolve-ReleaseDir -Root $Paths.Root -Version $ptr.Version
        if (-not $rd.Ok) { return $false }
        $mc = Test-ReleaseContent -PayloadDir $rd.Dir -ExpectedVersion $ptr.Version
        return $mc.Ok
      }
      "tasks" {
        if ($env:OS -ne "Windows_NT") { return $false }
        $r1 = Test-TaskDefinition -TaskName $Paths.TaskName -ExpectedFile $Paths.BinRunPi -ExpectedWorkDir $Paths.Bin -TaskReader $TaskReader
        if (-not $r1) { return $false }
        return (Test-TaskDefinition -TaskName $Paths.RemoteTaskName -ExpectedFile $Paths.BinRunRemote -ExpectedWorkDir $Paths.Bin -TaskReader $TaskReader)
      }
    }
    return $false
  } catch { return $false }
}

<#
.SYNOPSIS
  Full v3 deploy orchestration (migrate-or-update + bin + env). Never throws.
.DESCRIPTION
  Decides fresh install vs legacy migration vs pointer update, syncs bin\,
  writes machine facts to data\, and leaves the runtime verified on the
  target (or rolled back). Extension/shared deployment and task
  registration stay in the caller (installer), which reads the active
  release from the pointer afterwards. Returns
  @{ Ok; Action; ActiveVersion; Migrated; Detail }.
#>
function Invoke-V3Deploy {
  param(
    [hashtable]$Paths = $null,
    [string]$PayloadDir = "",
    [string]$TargetVersion = "",
    [hashtable]$MachineFacts = $null,
    [string]$NodeExe = "",
    [scriptblock]$StopRuntime = $null,
    [scriptblock]$StartRuntime = $null,
    [scriptblock]$TaskChecker = $null,
    [scriptblock]$PortChecker = $null,
    [scriptblock]$ApiChecker = $null,
    [scriptblock]$VersionReader = $null,
    [scriptblock]$TaskActionUpdater = $null
  )
  try {
    if (($null -eq $Paths) -or (-not (Test-ReleaseVersionFormat -Version $TargetVersion))) {
      return @{ Ok = $false; Action = "rejected"; ActiveVersion = ""; Migrated = $false; Detail = "paths/versione non validi" }
    }
    $cv = Test-ReleaseContent -PayloadDir $PayloadDir -ExpectedVersion $TargetVersion -NodeExe $NodeExe
    if (-not $cv.Ok) {
      return @{ Ok = $false; Action = "rejected"; ActiveVersion = ""; Migrated = $false; Detail = ("payload non valido: " + $cv.Error + " " + $cv.Detail) }
    }
    $ptr = Read-ActiveRelease -PointerPath $Paths.ActivePointer
    $leg = Test-LegacyLayout -Paths $Paths
    if ($ptr.Ok) {
      $up = Invoke-ReleaseUpdate -Paths $Paths -TargetVersion $TargetVersion -StagingDir $PayloadDir `
        -NodeExe $NodeExe -StopRuntime $StopRuntime -StartRuntime $StartRuntime `
        -TaskChecker $TaskChecker -PortChecker $PortChecker -ApiChecker $ApiChecker -VersionReader $VersionReader
      if (-not $up.Ok) {
        return @{ Ok = $false; Action = $up.Action; ActiveVersion = $ptr.Version; Migrated = $false; Detail = $up.Detail }
      }
      $bin = Install-BinFiles -PayloadDir $PayloadDir -BinDir $Paths.Bin
      if (($null -ne $MachineFacts) -and ($null -ne $MachineFacts["NodeExe"])) {
        Write-MachineEnv -EnvPath $Paths.MachineEnv -Env $MachineFacts | Out-Null
      }
      if (-not $bin.Ok) {
        return @{ Ok = $true; Action = $up.Action; ActiveVersion = $TargetVersion; Migrated = $false; Detail = ($up.Detail + " | AVVISO bin non sincronizzati: " + $bin.Error) }
      }
      return @{ Ok = $true; Action = $up.Action; ActiveVersion = $TargetVersion; Migrated = $false; Detail = $up.Detail }
    }
    if ($leg.Found -and ($leg.Version -ne "")) {
      $mg = Invoke-LegacyMigration -Paths $Paths -StagingDir $PayloadDir -TargetVersion $TargetVersion `
        -NodeExe $NodeExe -StopRuntime $StopRuntime -StartRuntime $StartRuntime `
        -TaskChecker $TaskChecker -PortChecker $PortChecker -ApiChecker $ApiChecker -VersionReader $VersionReader `
        -TaskActionUpdater $TaskActionUpdater
      if (-not $mg.Ok) {
        return @{ Ok = $false; Action = $mg.Action; ActiveVersion = ""; Migrated = $false; Detail = $mg.Detail }
      }
      $bin = Install-BinFiles -PayloadDir $PayloadDir -BinDir $Paths.Bin
      if (($null -ne $MachineFacts) -and ($null -ne $MachineFacts["NodeExe"])) {
        Write-MachineEnv -EnvPath $Paths.MachineEnv -Env $MachineFacts | Out-Null
      }
      if (-not $bin.Ok) {
        return @{ Ok = $true; Action = $mg.Action; ActiveVersion = $TargetVersion; Migrated = $true; Detail = ($mg.Detail + " | AVVISO bin non sincronizzati: " + $bin.Error) }
      }
      return @{ Ok = $true; Action = $mg.Action; ActiveVersion = $TargetVersion; Migrated = $true; Detail = $mg.Detail }
    }
    foreach ($d in @($Paths.Bin, $Paths.Releases, $Paths.Data, $Paths.Logs)) {
      if (-not (Test-Path -LiteralPath $d)) {
        try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
        catch { return @{ Ok = $false; Action = "rejected"; ActiveVersion = ""; Migrated = $false; Detail = ("creazione dir fallita: " + $d) } }
      }
    }
    $inst = Install-ReleaseCandidate -StagingDir $PayloadDir -ReleasesRoot $Paths.Releases -Version $TargetVersion
    if (-not $inst.Ok) {
      return @{ Ok = $false; Action = "rejected"; ActiveVersion = ""; Migrated = $false; Detail = ("installazione fallita: " + $inst.Error) }
    }
    $bin = Install-BinFiles -PayloadDir $PayloadDir -BinDir $Paths.Bin
    if (-not $bin.Ok) {
      return @{ Ok = $false; Action = "rejected"; ActiveVersion = ""; Migrated = $false; Detail = ("bin mancanti: " + $bin.Error) }
    }
    if (($null -ne $MachineFacts) -and ($null -ne $MachineFacts["NodeExe"])) {
      $wme = Write-MachineEnv -EnvPath $Paths.MachineEnv -Env $MachineFacts
      if (-not $wme.Ok) {
        return @{ Ok = $false; Action = "rejected"; ActiveVersion = ""; Migrated = $false; Detail = ("machine env fallita: " + $wme.Error) }
      }
    }
    $wp = Write-ActiveRelease -PointerPath $Paths.ActivePointer -Version $TargetVersion
    if (-not $wp.Ok) {
      return @{ Ok = $false; Action = "rejected"; ActiveVersion = ""; Migrated = $false; Detail = ("pointer iniziale fallito: " + $wp.Error) }
    }
    return @{ Ok = $true; Action = "fresh_installed"; ActiveVersion = $TargetVersion; Migrated = $false; Detail = ("installazione fresca " + $TargetVersion + " (tasks da registrare)") }
  } catch {
    return @{ Ok = $false; Action = "manual_intervention_required"; ActiveVersion = ""; Migrated = $false; Detail = $_.Exception.Message }
  }
}

<#
.SYNOPSIS
  Repoint a task action to a bin\ launcher (Windows only). Never throws.
.DESCRIPTION
  Uses Set-ScheduledTask to replace the single action, preserving trigger,
  principal, settings and registration. Fails (never creates) when the task
  is missing. This is the production TaskActionUpdater hook.
#>
function Update-PiServerTaskAction {
  param([string]$TaskName = "", [string]$LauncherPath = "", [string]$WorkDir = "")
  try {
    if ([string]::IsNullOrWhiteSpace($TaskName) -or [string]::IsNullOrWhiteSpace($LauncherPath)) {
      return @{ Ok = $false; Detail = "task/launcher vuoti" }
    }
    if ($env:OS -ne "Windows_NT") {
      return @{ Ok = $false; Detail = "non-Windows" }
    }
    if (-not (Test-Path -LiteralPath $LauncherPath)) {
      return @{ Ok = $false; Detail = ("launcher assente: " + $LauncherPath) }
    }
    $wd = $WorkDir
    if ([string]::IsNullOrWhiteSpace($wd)) { $wd = Split-Path -Parent $LauncherPath }
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if ($null -eq $t) { return @{ Ok = $false; Detail = "task assente" } }
    $acts = @($t.Actions)
    if ($acts.Count -ne 1) {
      return @{ Ok = $false; Detail = ("task con " + $acts.Count + " azioni (attesa 1)") }
    }
    $newAction = New-ScheduledTaskAction -Execute "powershell.exe" `
      -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"" + $LauncherPath + "`"") `
      -WorkingDirectory $wd -ErrorAction Stop
    Set-ScheduledTask -TaskName $TaskName -Action $newAction -ErrorAction Stop | Out-Null
    return @{ Ok = $true; Detail = ("task repointato su " + $LauncherPath) }
  } catch {
    return @{ Ok = $false; Detail = $_.Exception.Message }
  }
}
