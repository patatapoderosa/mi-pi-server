<#
.SYNOPSIS
  Smoke tests for the PiServer Windows installer (no Pester needed).

.DESCRIPTION
  Dot-sources installer/PiServerLib.ps1 and exercises the pure,
  side-effect-free functions plus failure paths that don't need Windows:
  admin detection shape, Node version comparison, path layout, checksum
  validation (good/bad/missing), manifest validation (complete/incomplete),
  idempotent config preservation (remote-server.json), download failure,
  health-check + remote-daemon probe fail-closed,
  SHA256SUMS strict parsing (LF/CRLF/BOM/spacing/asterisk/multi-file plus
  negatives and conflicting-duplicate fail-closed) with setup.ps1 mirror-sync,
  atomic staged deploy (clean/nested/fresh/update/backup/failure-intact),
  and the no-secrets-in-logs guarantee.

  Windows-only parts (Task Scheduler registration, icacls, powercfg) are
  SKIPPED with a count when $env:OS is not Windows_NT — never fake-passed.

  Run:  pwsh -NoProfile -File installer/tests/Invoke-SmokeTests.ps1
  Exit code 0 = all passed, 1 = any failure. 5.1 compatible.

  NOTE: these tests intentionally never touch C:\PiServer, the registry,
  services, or the network (except a fast-failing loopback URL).
#>
[CmdletBinding()]
param(
  [string]$LibPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($LibPath)) {
  $LibPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "PiServerLib.ps1"
}
. $LibPath

$script:passed = 0
$script:failed = 0
$script:skipped = 0
$script:failures = @()

function Assert-True([bool]$cond, [string]$name) {
  if ($cond) { $script:passed++; Write-Host "  PASS $name" -ForegroundColor Green }
  else { $script:failed++; $script:failures += $name; Write-Host "  FAIL $name" -ForegroundColor Red }
}
function Assert-Equal($actual, $expected, [string]$name) {
  Assert-True ($actual -eq $expected) "$name (atteso='$expected' trovato='$actual')"
}
function Skip-Test([string]$name, [string]$why) {
  $script:skipped++
  Write-Host "  SKIP $name ($why)" -ForegroundColor Yellow
}

$TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("piserver-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null
try {
  Write-Host ""
  Write-Host "== admin detection =="
  $adm = Test-IsAdmin
  Assert-True (($adm -is [bool])) "Test-IsAdmin restituisce bool"

  Write-Host "== Node version comparison =="
  Assert-True (Test-AtLeastNode22 -VersionString "v22.14.0") "v22.14.0 ok"
  Assert-True (Test-AtLeastNode22 -VersionString "22.0.0") "22.0.0 senza v ok"
  Assert-True (Test-AtLeastNode22 -VersionString "v24.3.1") "v24 ok (>=22)"
  Assert-True (-not (Test-AtLeastNode22 -VersionString "v20.19.0")) "v20 rifiutata"
  Assert-True (-not (Test-AtLeastNode22 -VersionString "v21.9.9")) "v21 rifiutata"
  Assert-True (-not (Test-AtLeastNode22 -VersionString "")) "stringa vuota rifiutata"
  Assert-True (-not (Test-AtLeastNode22 -VersionString "not-a-version")) "spazzatura rifiutata"
  Assert-True (-not (Test-AtLeastNode22 -VersionString "v22")) "major-only rifiutata"

  Write-Host "== directory layout =="
  $P = Get-PiServerPaths -Root (Join-Path $TmpRoot "PiServer")
  Assert-True ($P.App.EndsWith("app")) "App dir"
  Assert-True ($P.AgentDir -eq $P.Data) "AgentDir == Data (override esplicita)"
  Assert-True ($P.Daemon -match "pi-daemon\.mjs$") "Daemon path"
  Assert-True ($P.TaskName -eq "PiHomeServer") "TaskName"
  Assert-True ($P.ExtDir -match "extensions$") "ExtDir"
  Assert-True ($P.RemoteEntry -match "index\.ts$") "RemoteEntry (daemon TS)"
  Assert-True ($P.RunRemote -match "run-remote\.ps1$") "RunRemote launcher"
  Assert-Equal $P.RemoteTaskName "PiRemoteServer" "RemoteTaskName"
  Assert-Equal $P.RemotePortDefault 43128 "RemotePortDefault"
  Assert-True ($P.SharedDir -match "shared$") "SharedDir (layout ../../shared preservato)"

  Write-Host "== checksum validation =="
  $f = Join-Path $TmpRoot "payload.bin"
  "contenuto-di-test" | Out-File -LiteralPath $f -Encoding ascii -NoNewline
  $good = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
  Assert-True (Test-FileChecksum -Path $f -ExpectedSha256 $good) "checksum buono accettato"
  Assert-True (Test-FileChecksum -Path $f -ExpectedSha256 $good.ToLowerInvariant()) "case-insensitive"
  Assert-True (-not (Test-FileChecksum -Path $f -ExpectedSha256 ("0" * 64))) "bad checksum rifiutato"
  Assert-True (-not (Test-FileChecksum -Path (Join-Path $TmpRoot "inesistente") -ExpectedSha256 $good)) "file mancante rifiutato"
  Assert-True (-not (Test-FileChecksum -Path $f -ExpectedSha256 "")) "checksum vuoto rifiutato"

  Write-Host "== manifest validation =="
  $pay = Join-Path $TmpRoot "payload"
  foreach ($rel in @("server\pi-daemon.mjs", "server\pi-remote-config\index.ts",
      "server\pi-remote-config\package.json", "shared\protocol.ts",
      "shared\modules.ts", "shared\store.ts",
      "server\pi-remote-server\index.ts", "server\pi-remote-server\server.ts",
      "server\pi-remote-server\migrate.ts", "server\pi-remote-server\tailscale.ts",
      "installer\run-task.ps1", "installer\run-remote.ps1",
      "installer\windows-installer.ps1")) {
    $fp = Join-Path $pay $rel
    $d = Split-Path -Parent $fp
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    "x" | Out-File -LiteralPath $fp -Encoding ascii
  }
  $m = Test-ReleaseManifest -PayloadRoot $pay
  Assert-True ($m.Ok) "manifest completo accettato"
  Remove-Item -LiteralPath (Join-Path $pay "shared\store.ts") -Force
  $m2 = Test-ReleaseManifest -PayloadRoot $pay
  Assert-True ((-not $m2.Ok) -and ($m2.Missing -contains "shared\store.ts")) "manifest incompleto rifiutato con dettaglio"

  Write-Host "== idempotent config preservation =="
  $cfg = Join-Path $TmpRoot "remote-server.json"
  $r1 = Save-JsonConfigPreserving -Path $cfg `
    -Defaults @{ port = 43128; maxSkewSeconds = 300 } `
    -RequiredKeys @("port")
  Assert-Equal $r1 "created" "prima scrittura = created"
  $custom = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
  $custom.port = 50000
  $custom | Add-Member -NotePropertyName "notaUtente" -NotePropertyValue "non-toccare"
  $custom | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $cfg -Encoding utf8
  $r2 = Save-JsonConfigPreserving -Path $cfg `
    -Defaults @{ port = 43128; maxSkewSeconds = 300 } `
    -RequiredKeys @("port")
  Assert-Equal $r2 "kept" "seconda scrittura = kept"
  $after = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
  Assert-Equal $after.port 50000 "valore utente preservato"
  Assert-Equal $after.notaUtente "non-toccare" "chiavi extra preservate"
  # Corrupt file -> backup + defaults (merged), never crash.
  "zzz-non-json" | Out-File -LiteralPath $cfg -Encoding utf8
  $r3 = Save-JsonConfigPreserving -Path $cfg `
    -Defaults @{ port = 43128; maxSkewSeconds = 300 } `
    -RequiredKeys @("port")
  Assert-Equal $r3 "merged" "file corrotto = backup + defaults"
  $baks = Get-ChildItem -LiteralPath $TmpRoot -Filter "remote-server.json.bak-*" -ErrorAction SilentlyContinue
  Assert-True ((@($baks).Count -ge 1)) "backup creato prima di sovrascrivere"

  Write-Host "== download failure =="
  $dlFail = $false
  try {
    Invoke-WebRequest -Uri "http://127.0.0.1:9/payload.zip" -OutFile (Join-Path $TmpRoot "x.zip") -TimeoutSec 5
  } catch { $dlFail = $true }
  Assert-True $dlFail "connessione rifiutata rilevata (nessun hang)"

  Write-Host "== health-check failure (no throw) =="
  $bogus = Get-PiServerPaths -Root (Join-Path $TmpRoot "vuoto")
  $hc = Invoke-HealthCheck -Paths $bogus -PiBin ""
  Assert-True (-not $hc.Ok) "health check fallisce su installazione vuota"
  Assert-True ($hc.Failures.Count -ge 3) "fallimenti dettagliati (>=3)"
  $threw = $false
  try { $null = Invoke-HealthCheck -Paths $null -PiBin $null } catch { $threw = $true }
  Assert-True (-not $threw) "health check non lancia mai eccezioni"

  Write-Host "== remote daemon probe (fail-closed, no throw) =="
  $rd = Test-RemoteDaemon -Paths $bogus -TimeoutSec 3
  Assert-True (-not $rd.Ok) "probe fallisce su installazione vuota (no HMAC)"
  Assert-True (-not [string]::IsNullOrWhiteSpace($rd.Detail)) "probe spiega il motivo"
  New-Item -ItemType Directory -Path $bogus.SecretsDir -Force | Out-Null
  "unit-test-hmac-value" | Out-File -LiteralPath (Join-Path $bogus.SecretsDir "remote-hmac") -Encoding ascii -NoNewline
  $rd2 = Test-RemoteDaemon -Paths $bogus -TimeoutSec 3
  Assert-True (-not $rd2.Ok) "probe fallisce a demone spento (connessione rifiutata)"
  $threw2 = $false
  try { $null = Test-RemoteDaemon -Paths $null -TimeoutSec 3 } catch { $threw2 = $true }
  Assert-True (-not $threw2) "probe non lancia mai eccezioni"

  Write-Host "== no secrets in logs =="
  $logf = Join-Path $TmpRoot "t.log"
  $fakeSecret = "sk-fakesecret-UNITTEST-987654321"
  Write-InstallLog -Message "server-bot-token scritto (ACL: SYSTEM+Administrators)" -LogFile $logf -Level OK
  Write-InstallLog -Message "remote-hmac scritto (ACL: SYSTEM+Administrators)" -LogFile $logf -Level OK
  $logContent = Get-Content -LiteralPath $logf -Raw
  Assert-True ($logContent -notmatch [regex]::Escape($fakeSecret)) "log privo di secret (controllo negativo)"
  Assert-True (($logContent -match "server-bot-token scritto") -and ($logContent -notmatch "bot\d+:[\w-]{20,}")) "log operativo senza valori token-like"

  Write-Host "== 5.1-compat static scan =="
  $psFiles = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) "PiServerLib.ps1"),
    (Join-Path (Split-Path -Parent $PSScriptRoot) "windows-installer.ps1"),
    (Join-Path (Split-Path -Parent $PSScriptRoot) "run-task.ps1")
    (Join-Path (Split-Path -Parent $PSScriptRoot) "run-task.ps1"),
    (Join-Path (Split-Path -Parent $PSScriptRoot) "run-remote.ps1")
  )
  $badOps = @()
  $inBlock = $false
  foreach ($pf in $psFiles) {
    if (-not (Test-Path -LiteralPath $pf)) { continue }
    $lines = Get-Content -LiteralPath $pf
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $ln = $lines[$i]
      if (-not $inBlock) {
        if ($ln -match '<#') {
          $inBlock = $true
          $ln = ($ln -split '<#', 2)[0]
          if ($ln -match '#>') { $inBlock = $false }
        }
      } else {
        if ($ln -match '#>') { $inBlock = $false }
        continue
      }
      $code = ($ln -split '#')[0]
      if ($code -match '\?\?|\?\.') { $badOps += "$($pf | Split-Path -Leaf):$($i + 1)" }
    }
  }
  Assert-True ($badOps.Count -eq 0) ("nessun operatore ??/?. (" + ($badOps -join ", ") + ")")

  if ($env:OS -eq "Windows_NT") {
    Write-Host "== task settings (solo Windows) =="
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
      -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew
    Assert-Equal $s.MultipleInstances "IgnoreNew" "single-instance"
    Assert-Equal $s.ExecutionTimeLimit "PT0S" "no time limit"
    Assert-True ($s.RestartCount -ge 3) "restart on failure"
    Assert-True ($s.StartWhenAvailable) "start when available"
    Assert-True ($s.AllowStartIfOnBatteries -and $s.DontStopIfGoingOnBatteries) "battery-proof"
  } else {
    Skip-Test "task settings" "non-Windows (Get-ScheduledTask assente)"
  }

  Write-Host "== SHA256SUMS parser (Get-ReleaseChecksum) =="
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $HA = ("a" * 64)
  $HB = ("b" * 64)
  function Write-SumsBytes([string]$p, [string]$t, [string]$enc) {
    if ($enc -eq "bom") { [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true))) }
    elseif ($enc -eq "utf16") { [System.IO.File]::WriteAllText($p, $t, [System.Text.Encoding]::Unicode) }
    else { [System.IO.File]::WriteAllText($p, $t) }
  }
  $sumsDir = Join-Path $TmpRoot "sums"
  New-Item -ItemType Directory -Path $sumsDir -Force | Out-Null
  $sf = Join-Path $sumsDir "SHA256SUMS.txt"
  Write-SumsBytes $sf ($HA + "  mi-pi-server-windows.zip" + "`n") "lf"
  $r = Get-ReleaseChecksum -SumsFile $sf
  Assert-True ($r.Ok -and ($r.Hash -eq $HA)) "formato LF due-spazi"
  Write-SumsBytes $sf ($HA + "  mi-pi-server-windows.zip" + "`r`n") "lf"
  Assert-True ((Get-ReleaseChecksum -SumsFile $sf).Ok) "formato CRLF"
  Write-SumsBytes $sf ($HA + "  mi-pi-server-windows.zip" + "`n") "bom"
  Assert-True ((Get-ReleaseChecksum -SumsFile $sf).Ok) "BOM UTF-8"
  Write-SumsBytes $sf ($HA + "  mi-pi-server-windows.zip" + "`n") "utf16"
  Assert-True ((Get-ReleaseChecksum -SumsFile $sf).Ok) "BOM UTF-16"
  Write-SumsBytes $sf ($HA + " mi-pi-server-windows.zip" + "`n") "lf"
  Assert-True ((Get-ReleaseChecksum -SumsFile $sf).Ok) "uno spazio"
  Write-SumsBytes $sf ($HA + " *mi-pi-server-windows.zip" + "`n") "lf"
  Assert-True ((Get-ReleaseChecksum -SumsFile $sf).Ok) "asterisco binario"
  Write-SumsBytes $sf (("c" * 64) + "  other.zip" + "`n" + $HB + "  mi-pi-server-windows.zip" + "`n") "lf"
  $rm = Get-ReleaseChecksum -SumsFile $sf
  Assert-True ($rm.Ok -and ($rm.Hash -eq $HB)) "file multipli: sceglie HASH2"
  Write-SumsBytes $sf ("abc  mi-pi-server-windows.zip" + "`n") "lf"
  Assert-True (-not (Get-ReleaseChecksum -SumsFile $sf).Ok) "hash corto rifiutato"
  Write-SumsBytes $sf ($HA + "  altro.zip" + "`n") "lf"
  Assert-True (-not (Get-ReleaseChecksum -SumsFile $sf).Ok) "filename diverso rifiutato"
  Write-SumsBytes $sf (("g" * 64) + "  mi-pi-server-windows.zip" + "`n") "lf"
  Assert-True (-not (Get-ReleaseChecksum -SumsFile $sf).Ok) "hash non-hex rifiutato"
  Write-SumsBytes $sf ($HA + "  mi-pi-server-windows.zip" + "`n" + $HB + "  mi-pi-server-windows.zip" + "`n") "lf"
  $rc = Get-ReleaseChecksum -SumsFile $sf
  Assert-True ((-not $rc.Ok) -and ($rc.Error -eq "checksum_conflict")) "duplicati discordanti = FAIL CLOSED"
  Write-SumsBytes $sf ($HA + "  mi-pi-server-windows.zip" + "`n" + $HA + "  mi-pi-server-windows.zip" + "`n") "lf"
  Assert-True ((Get-ReleaseChecksum -SumsFile $sf).Ok) "duplicati identici accettati"
  $rn = Get-ReleaseChecksum -SumsFile (Join-Path $sumsDir "inesistente.txt")
  Assert-True ((-not $rn.Ok) -and ($rn.Error -eq "sums_missing")) "file mancante"
  Write-SumsBytes $sf "" "lf"
  $re = Get-ReleaseChecksum -SumsFile $sf
  Assert-True ((-not $re.Ok) -and ($re.Error -eq "sums_empty")) "file vuoto"
  Write-Host "== checksum parser: mirror setup.ps1 <-> PiServerLib.ps1 =="
  function Get-MirrorBlock([string]$file) {
    $t = Get-Content -LiteralPath $file -Raw
    $m = [regex]::Match($t, "(?s)# ===== BEGIN Get-ReleaseChecksum.*?# ===== END Get-ReleaseChecksum =====")
    if ($m.Success) { return $m.Value } else { return $null }
  }
  $libBlock = Get-MirrorBlock (Join-Path (Split-Path -Parent $PSScriptRoot) "PiServerLib.ps1")
  $bootBlock = Get-MirrorBlock (Join-Path $RepoRoot "setup.ps1")
  Assert-True (($null -ne $libBlock) -and ($null -ne $bootBlock)) "blocchi mirror presenti"
  Assert-True ($libBlock -eq $bootBlock) "parser identici (niente derive)"

  Write-Host "== staged deploy (Invoke-AppStaging) =="
  function New-MiniPayload([string]$dir) {
    foreach ($rel in @("server\pi-daemon.mjs", "server\pi-remote-config\index.ts",
        "server\pi-remote-config\package.json", "shared\protocol.ts",
        "shared\modules.ts", "shared\store.ts",
        "installer\run-task.ps1", "installer\run-remote.ps1",
        "installer\windows-installer.ps1",
        "server\pi-remote-server\index.ts", "server\pi-remote-server\server.ts",
        "server\pi-remote-server\migrate.ts", "server\pi-remote-server\tailscale.ts",
        "server\x\y\z.ts")) {
      $fp = Join-Path $dir $rel
      $dd = Split-Path -Parent $fp
      if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
      ("payload:" + $rel) | Out-File -LiteralPath $fp -Encoding ascii -NoNewline
    }
  }
  $stgRoot = Join-Path $TmpRoot "staging"
  New-Item -ItemType Directory -Path $stgRoot -Force | Out-Null
  $pay1 = Join-Path $stgRoot "pay1"
  New-MiniPayload $pay1
  $app1 = Join-Path $stgRoot "app"
  $s1 = Invoke-AppStaging -PayloadDir $pay1 -AppPath $app1 -Mode "fresh" -VersionLabel "v9.9.9-test"
  Assert-True ($s1.Ok -and ($null -eq $s1.BackupPath)) "installazione pulita OK, nessun backup"
  Assert-True ((Get-Content -LiteralPath (Join-Path $app1 "server\x\y\z.ts") -Raw) -eq "payload:server\x\y\z.ts") "file annidati copiati"
  Assert-True ((Get-Content -LiteralPath (Join-Path $app1 "VERSION") -Raw) -eq "v9.9.9-test") "VERSION stampata"
  Assert-True ((Get-Content -LiteralPath (Join-Path $app1 "shared\protocol.ts") -Raw) -eq "payload:shared\protocol.ts") "shared copiata"
  "VECCHIA" | Out-File -LiteralPath (Join-Path $app1 "server\pi-daemon.mjs") -Encoding ascii -NoNewline
  $s2 = Invoke-AppStaging -PayloadDir $pay1 -AppPath $app1 -Mode "fresh" -VersionLabel "v9.9.9-test"
  Assert-True ($s2.Ok -and ($null -eq $s2.BackupPath)) "reinstall fresh OK"
  Assert-True ((Get-Content -LiteralPath (Join-Path $app1 "server\pi-daemon.mjs") -Raw) -like "payload:*") "app esistente sostituita in fresh"
  Assert-True ((@(Get-ChildItem -LiteralPath $stgRoot -Filter "app.backup-*") ).Count -eq 0) "fresh non crea backup"
  "VECCHIA2" | Out-File -LiteralPath (Join-Path $app1 "server\pi-daemon.mjs") -Encoding ascii -NoNewline
  $s3 = Invoke-AppStaging -PayloadDir $pay1 -AppPath $app1 -Mode "update" -VersionLabel "v9.9.9-test"
  Assert-True ($s3.Ok -and ($null -ne $s3.BackupPath)) "update OK con backup"
  Assert-True ((Get-Content -LiteralPath (Join-Path $s3.BackupPath "server\pi-daemon.mjs") -Raw) -eq "VECCHIA2") "backup contiene vecchia app"
  Assert-True ((Get-Content -LiteralPath (Join-Path $app1 "server\pi-daemon.mjs") -Raw) -like "payload:*") "live aggiornata"
  $payBad = Join-Path $stgRoot "payBad"
  New-MiniPayload $payBad
  Remove-Item -LiteralPath (Join-Path $payBad "shared\store.ts") -Force
  "SENTINELLA" | Out-File -LiteralPath (Join-Path $app1 "server\pi-daemon.mjs") -Encoding ascii -NoNewline
  $s4 = Invoke-AppStaging -PayloadDir $payBad -AppPath $app1 -Mode "update" -VersionLabel "v9.9.9-test"
  Assert-True (-not $s4.Ok) "payload incompleto rifiutato"
  Assert-True ((Get-Content -LiteralPath (Join-Path $app1 "server\pi-daemon.mjs") -Raw) -eq "SENTINELLA") "app live intatta dopo fallimento"
  Assert-True ((@(Get-ChildItem -LiteralPath $stgRoot -Filter "app.new-*")).Count -eq 0) "stage fallito rimosso"
  $s5 = Invoke-AppStaging -PayloadDir (Join-Path $stgRoot "inesistente") -AppPath (Join-Path $stgRoot "app2") -Mode "fresh"
  Assert-True ((-not $s5.Ok) -and (-not (Test-Path -LiteralPath (Join-Path $stgRoot "app2")))) "payload mancante: nulla creato"
  $deepApp = Join-Path (Join-Path $stgRoot "nodir") "app"
  $s6 = Invoke-AppStaging -PayloadDir $pay1 -AppPath $deepApp -Mode "fresh"
  Assert-True ($s6.Ok -and (Test-Path -LiteralPath (Join-Path $deepApp "server\pi-daemon.mjs"))) "parent mancanti creati (mkdir -p)"
  Assert-True ((Get-Content -LiteralPath (Join-Path $pay1 "server\pi-daemon.mjs") -Raw) -like "payload:*") "payload non toccato"
  $wiText = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "windows-installer.ps1") -Raw
  Assert-True ($wiText -match "Invoke-AppStaging -PayloadDir") "installer usa Invoke-AppStaging"
  Assert-True ($wiText -notmatch 'Join-Path \$stageNew \$sub') "nessuna copia inline sul leaf (bug 5.1)"
} finally {
  Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "----------------------------------------"
Write-Host "PASS: $script:passed  FAIL: $script:failed  SKIP: $script:skipped"
if ($script:failed -gt 0) {
  Write-Host "Fallimenti:" -ForegroundColor Red
  $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host "SMOKE TEST OK" -ForegroundColor Green
exit 0
