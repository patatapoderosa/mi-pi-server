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
  pi authentication verifier (valid/invalid/corrupt/missing auth, env restore,
  user-vs-server confusion, menu, atomic migration, ACL shape, resume verifier),
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
  foreach ($rel in @("server\pi-daemon.mjs", "server\spawn-pi.mjs", "server\pi-remote-config\index.ts",
      "server\pi-remote-config\package.json", "shared\protocol.ts",
      "shared\modules.ts", "shared\store.ts", "shared\pi-model.ts",
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
    if ($s.PSObject.Properties.Name -contains "AllowStartIfOnBatteries") {
      Assert-True ($s.AllowStartIfOnBatteries -and $s.DontStopIfGoingOnBatteries) "battery-proof"
    } else {
      Skip-Test "battery-proof" "Server SKU: no battery settings"
    }
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
    foreach ($rel in @("server\pi-daemon.mjs", "server\spawn-pi.mjs", "server\pi-remote-config\index.ts",
        "server\pi-remote-config\package.json", "shared\protocol.ts",
        "shared\modules.ts", "shared\store.ts", "shared\pi-model.ts",
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

  Write-Host "== telegram failure taxonomy =="
  $k401 = Classify-TelegramFailure -StatusCode 401
  Assert-True (($k401.Kind -eq "invalid-token") -and (-not $k401.Transient)) "401 = token invalido, non transient"
  $k403 = Classify-TelegramFailure -StatusCode 403
  Assert-True ($k403.Kind -eq "invalid-token") "403 = token invalido"
  Assert-True ((Classify-TelegramFailure -StatusCode 404).Kind -eq "malformed") "404 = malformed"
  $k500 = Classify-TelegramFailure -StatusCode 500
  Assert-True (($k500.Kind -eq "server-busy") -and $k500.Transient) "500 = transient"
  Assert-True ((Classify-TelegramFailure -StatusCode 0 -WebStatus "Timeout").Kind -eq "timeout") "timeout WebStatus"
  Assert-True ((Classify-TelegramFailure -StatusCode 0 -WebStatus "NameResolutionFailure").Kind -eq "dns") "dns WebStatus"
  Assert-True ((Classify-TelegramFailure -StatusCode 0 -WebStatus "SecureChannelFailure").Kind -eq "tls") "tls WebStatus"
  Assert-True ((Classify-TelegramFailure -StatusCode 0 -WebStatus "ConnectFailure").Kind -eq "connection") "connection WebStatus"
  Assert-True ((Classify-TelegramFailure -Message "The remote server returned an error: (401) Unauthorized.").Kind -eq "invalid-token") "401 nel testo (PS 5.1 senza Response)"
  Assert-True ((Classify-TelegramFailure -Message "qualcosa di strano").Kind -eq "unknown") "sconosciuto = unknown"
  $weTimeout = New-Object System.Net.WebException("The operation has timed out", [System.Net.WebExceptionStatus]::Timeout)
  $fTimeout = Get-TelegramFailureFacts -Exception $weTimeout
  Assert-True (($fTimeout.WebStatus -eq "Timeout") -and ((Classify-TelegramFailure -StatusCode $fTimeout.StatusCode -WebStatus $fTimeout.WebStatus -Message $fTimeout.Message).Kind -eq "timeout")) "facts+classify timeout end-to-end"
  $weDns = New-Object System.Net.WebException("The remote name could not be resolved", [System.Net.WebExceptionStatus]::NameResolutionFailure)
  $fDns = Get-TelegramFailureFacts -Exception $weDns
  Assert-True ((Classify-TelegramFailure -StatusCode $fDns.StatusCode -WebStatus $fDns.WebStatus -Message $fDns.Message).Kind -eq "dns") "facts+classify dns end-to-end"
  $fNull = Get-TelegramFailureFacts -Exception $null
  Assert-True (($fNull.StatusCode -eq 0) -and ($fNull.WebStatus -eq "")) "facts su null non lancia"
  $okResp = [pscustomobject]@{ ok = $true; result = [pscustomobject]@{ id = 123456789; username = "my_bot" } }
  $pr = Test-TelegramGetMeResponse -Response $okResp
  Assert-True ($pr.Ok -and ($pr.BotId -eq "123456789") -and ($pr.BotUsername -eq "my_bot")) "getMe ok parsata"
  Assert-True (-not (Test-TelegramGetMeResponse -Response ([pscustomobject]@{ ok = $false })).Ok) "getMe ok=false rifiutata"
  Assert-True (-not (Test-TelegramGetMeResponse -Response $null).Ok) "getMe null rifiutata"
  Assert-True (-not (Test-TelegramGetMeResponse -Response ([pscustomobject]@{ ok = $true; result = [pscustomobject]@{} })).Ok) "getMe senza id rifiutata"
  $invOk = { param($u, $t) return [pscustomobject]@{ ok = $true; result = [pscustomobject]@{ id = 42; username = "b" } } }
  $tr = Test-TelegramBotToken -Token "123456:ABCDEFghij1234567890abcdefghij" -Invoker $invOk
  Assert-True ($tr.Ok -and ($tr.BotId -eq "42")) "token valido via invoker"
  $inv401 = { param($u, $t) throw (New-Object System.Net.WebException("The remote server returned an error: (401) Unauthorized.", [System.Net.WebExceptionStatus]::ProtocolError)) }
  $tr401 = Test-TelegramBotToken -Token "123456:ERRATO" -Invoker $inv401
  Assert-True ((-not $tr401.Ok) -and ($tr401.Kind -eq "invalid-token") -and (-not $tr401.Transient)) "token 401 = riprompt, non retry"
  Assert-True ($tr401.Message -notmatch "123456:ERRATO") "token mai nel messaggio"
  $invTo = { param($u, $t) throw (New-Object System.Net.WebException("The operation has timed out", [System.Net.WebExceptionStatus]::Timeout)) }
  $trTo = Test-TelegramBotToken -Token "123456:TIMEOUTTEST" -Invoker $invTo
  Assert-True ((-not $trTo.Ok) -and $trTo.Transient) "timeout = transient"
  Assert-True ($trTo.Message -notmatch "TIMEOUTTEST") "token mai nel messaggio (timeout)"
  $trEmpty = Test-TelegramBotToken -Token ""
  Assert-True ((-not $trEmpty.Ok) -and ($trEmpty.Kind -eq "empty")) "token vuoto"

  Write-Host "== input validators + prompt loops =="
  Assert-True (-not (Test-ValidPort "abc")) "porta abc rifiutata"
  Assert-True (-not (Test-ValidPort "0")) "porta 0 rifiutata"
  Assert-True (-not (Test-ValidPort "65536")) "porta 65536 rifiutata"
  Assert-True (-not (Test-ValidPort "")) "porta vuota rifiutata"
  Assert-True (Test-ValidPort "43128") "porta 43128 accettata"
  Assert-True (Test-ValidPort "1") "porta 1 accettata"
  Assert-True (Test-ValidPort "65535") "porta 65535 accettata"
  Assert-True (-not (Test-ValidOwnerId "abc")) "owner abc rifiutato"
  Assert-True (-not (Test-ValidOwnerId "0")) "owner 0 rifiutato"
  Assert-True (Test-ValidOwnerId "123456789") "owner numerico accettato"
  Assert-True (Test-ValidTokenFormat "123456:ABCDEFghij1234567890abcdefghij") "formato token ok"
  Assert-True (-not (Test-ValidTokenFormat "nontoken")) "formato token rifiutato"
  Assert-True (-not (Test-ValidHmac "corto")) "hmac corto rifiutato"
  Assert-True (-not (Test-ValidHmac "ha spazi dentro qui okkk")) "hmac con spazi rifiutato"
  Assert-True (Test-ValidHmac "0123456789abcdef0123456789abcdef") "hmac valido accettato"
  $script:fakeAnswers = @()
  $fakeRead = { param($p) $a = $null; if ($script:fakeAnswers.Count -gt 0) { $a = $script:fakeAnswers[0]; $script:fakeAnswers = @($script:fakeAnswers | Select-Object -Skip 1) }; return $a }
  $script:fakeAnswers = @("abc", "90000", "43128")
  Assert-Equal (Read-ValidatedPort -ReadFunc $fakeRead) "43128" "porta: due errori poi valore"
  $script:fakeAnswers = @("")
  Assert-Equal (Read-ValidatedPort -ReadFunc $fakeRead) "43128" "porta vuota = default"
  $script:fakeAnswers = @("abc", "123")
  Assert-Equal (Read-ValidatedOwnerId -ReadFunc $fakeRead) "123" "owner: errore poi valore"
  $script:fakeAnswers = @("forse", "s")
  Assert-True (Read-ValidatedYesNo -Prompt "Confermi?" -ReadFunc $fakeRead) "yesno: garbage poi s = true"
  $script:fakeAnswers = @("n")
  Assert-True (-not (Read-ValidatedYesNo -Prompt "Confermi?" -ReadFunc $fakeRead)) "yesno: n = false"
  $script:fakeAnswers = @("")
  Assert-True (Read-ValidatedYesNo -Prompt "Confermi?" -ReadFunc $fakeRead) "yesno: vuoto = default Y"
  $script:fakeAnswers = @("")
  $genHmac = Read-ValidatedHmac -ReadFunc $fakeRead
  Assert-True (($genHmac.Secret.Length -eq 64) -and ($genHmac.Secret -notmatch "\s") -and $genHmac.Generated) "hmac vuoto = generato 64hex"
  $script:fakeAnswers = @("corto", "0123456789abcdef0123456789abcdef")
  $typedHmac = Read-ValidatedHmac -ReadFunc $fakeRead
  Assert-True (($typedHmac.Secret -eq "0123456789abcdef0123456789abcdef") -and (-not $typedHmac.Generated)) "hmac: errore poi valore digitato"
  $script:fakeAnswers = @("")
  Assert-Equal (Read-ValidatedOwnerId -Prompt "Owner" -Default "777" -ReadFunc $fakeRead) "777" "owner vuoto = default esistente"
  $atomPath = Join-Path $TmpRoot "atomico.txt"
  Assert-True (Write-AtomicTextFile -Path $atomPath -Content "uno") "atomic write ok"
  Assert-Equal (Get-Content -LiteralPath $atomPath -Raw) "uno" "atomic contenuto"
  Assert-True (Write-AtomicTextFile -Path $atomPath -Content "due") "atomic overwrite ok"
  Assert-Equal (Get-Content -LiteralPath $atomPath -Raw) "due" "atomic overwrite contenuto"
  Assert-True ((@(Get-ChildItem -LiteralPath $TmpRoot -Filter "atomico.txt.tmp-*")).Count -eq 0) "atomic: nessun tmp residuo"
  Assert-True (-not (Write-AtomicTextFile -Path "" -Content "x")) "atomic path vuoto = false"
  $script:fakeAnswers = @("nontoken", "123456:ABCDEFghij1234567890abcdefghij")
  $tokLoop = Read-ValidatedHidden -Prompt "Token" -Validate { param($x) Test-ValidTokenFormat $x } -InvalidMessage "bad" -ReadFunc $fakeRead
  Assert-Equal $tokLoop "123456:ABCDEFghij1234567890abcdefghij" "token: formato errato poi valido"

  Write-Host "== retry engine + step taxonomy =="
  Assert-Equal (Get-RetryDelaySec -Attempt 1) 2 "delay 1 = 2s"
  Assert-Equal (Get-RetryDelaySec -Attempt 2) 4 "delay 2 = 4s"
  Assert-Equal (Get-RetryDelaySec -Attempt 3) 8 "delay 3 = 8s"
  Assert-Equal (Get-RetryDelaySec -Attempt 10) 30 "delay cap 30s"
  $script:flakyN = 0
  $rw1 = Invoke-WithRetry -Action { $script:flakyN++; if ($script:flakyN -lt 2) { throw "timeout simulato" }; return "fatto" } -IsTransient { param($e) ($e.Exception.Message -match "timeout") } -BaseDelaySec 0
  Assert-True ($rw1.Ok -and ($rw1.Value -eq "fatto") -and ($rw1.Attempts -eq 2)) "retry: transient poi successo"
  $rw2 = Invoke-WithRetry -Action { throw "checksum mismatch simulato" } -IsTransient { param($e) $false } -BaseDelaySec 0
  Assert-True ((-not $rw2.Ok) -and ($rw2.Attempts -eq 1)) "non-transient: nessun retry"
  $script:alwaysN = 0
  $rw3 = Invoke-WithRetry -Action { $script:alwaysN++; throw "connessione persa" } -IsTransient { param($e) $true } -MaxAttempts 3 -BaseDelaySec 0
  Assert-True ((-not $rw3.Ok) -and ($rw3.Attempts -eq 3)) "sempre-transient: 3 tentativi poi stop"
  $se1 = Split-StepError (New-StepError "Transient" "x timeout y")
  Assert-True ($se1.Kind -eq "Transient") "tag Transient letto"
  $se2 = Split-StepError (New-StepError "Fatal" "checksum bad")
  Assert-True ($se2.Kind -eq "Fatal") "tag Fatal letto"
  $se3 = Split-StepError "The operation has timed out"
  Assert-True ($se3.Kind -eq "Transient") "eccezione raw timeout = Transient"
  $se4 = Split-StepError "qualcosa di generico" 
  Assert-True ($se4.Kind -eq "System") "default = System"
  Assert-Equal (Resolve-StepAction -Kind "Fatal" -Attempt 1) "fail" "fatal = fail"
  Assert-Equal (Resolve-StepAction -Kind "Transient" -Attempt 1) "retry" "transient tentativo 1 = retry"
  Assert-Equal (Resolve-StepAction -Kind "Transient" -Attempt 3) "menu" "transient tentativo 3 = menu"
  Assert-Equal (Resolve-StepAction -Kind "System" -Attempt 1) "menu" "system = menu"
  $mRetry = Show-StepMenu -StepLabel "8/11" -Title "T" -ErrorMessage "e" -ReadFunc { param($o) return "r" }
  Assert-Equal $mRetry "retry" "menu R"
  $mSkip = Show-StepMenu -StepLabel "8/11" -Title "T" -ErrorMessage "e" -AllowSkip -ReadFunc { param($o) return "s" }
  Assert-Equal $mSkip "skip" "menu S (consentito)"
  $script:mns = 0
  $mNoSkip = Show-StepMenu -StepLabel "8/11" -Title "T" -ErrorMessage "e" -ReadFunc { param($o) if ($script:mns -ne 1) { $script:mns = 1; return "s" } else { return "e" } }
  Assert-Equal $mNoSkip "exit" "menu S negato su step critico"
  $script:mns = 0
  $mDet = Show-StepMenu -StepLabel "8/11" -Title "T" -ErrorMessage "e" -Details "dettagli-ok" -ReadFunc { param($o) if ($script:mns -ne 1) { $script:mns = 1; return "d" } else { return "e" } }
  Assert-Equal $mDet "exit" "menu D poi E"
  $script:mns = 0
  $mDef = Show-StepMenu -StepLabel "8/11" -Title "T" -ErrorMessage "e" -ReadFunc { param($o) return "" }
  Assert-Equal $mDef "retry" "menu vuoto = default R"

  Write-Host "== checkpoint atomico =="
  $cpPath = Join-Path $TmpRoot "install-state.json"
  $rMissing = Read-InstallState -Path (Join-Path $TmpRoot "nonesiste.json")
  Assert-True (($rMissing.State.completedSteps.Count -eq 0) -and (-not $rMissing.Corrupt)) "checkpoint mancante = blank"
  $st0 = @{ schemaVersion = 1; targetRelease = "v9.9.9"; completedSteps = @("windows", "node"); skippedSteps = @(); currentStep = "pi"; lastSuccessfulStep = "node"; lastErrorKind = ""; updatedAt = "" }
  Assert-True (Write-InstallState -Path $cpPath -State $st0) "scrittura checkpoint"
  $rBack = Read-InstallState -Path $cpPath
  Assert-True (($rBack.State.targetRelease -eq "v9.9.9") -and ($rBack.State.completedSteps -contains "node") -and ($rBack.State.currentStep -eq "pi")) "round-trip checkpoint"
  Assert-True ((@(Get-ChildItem -LiteralPath $TmpRoot -Filter "install-state.json.tmp-*")).Count -eq 0) "nessun tmp residuo"
  "NON-JSON{{{" | Out-File -LiteralPath $cpPath -Encoding ascii -Force
  $rCorr = Read-InstallState -Path $cpPath
  Assert-True ($rCorr.Corrupt -and ($rCorr.State.completedSteps.Count -eq 0)) "corrotto = backup + blank"
  Assert-True ((@(Get-ChildItem -LiteralPath $TmpRoot -Filter "install-state.json.corrupt-*")).Count -ge 1) "backup corrotto creato"
  '{ "schemaVersion": 99, "completedSteps": ["windows"] }' | Out-File -LiteralPath $cpPath -Encoding ascii -Force
  $rOld = Read-InstallState -Path $cpPath
  Assert-True (($rOld.State.completedSteps.Count -eq 0) -and ($rOld.Notice -ne "")) "schema vecchio = blank + notice"
  $stSecret = @{ schemaVersion = 1; targetRelease = "v"; completedSteps = @(); skippedSteps = @(); currentStep = ""; lastSuccessfulStep = ""; lastErrorKind = ""; updatedAt = ""; botToken = "123456:SEGRETOTEST999"; remoteHmac = "hmac-segreto-test" }
  [void](Write-InstallState -Path $cpPath -State $stSecret)
  $cpRaw = Get-Content -LiteralPath $cpPath -Raw
  Assert-True (($cpRaw -notmatch "SEGRETOTEST999") -and ($cpRaw -notmatch "hmac-segreto-test")) "secret mai nel checkpoint"

  Write-Host "== redazione log + verifiche real-state =="
  $logf2 = Join-Path $TmpRoot "t2.log"
  Write-InstallLog -Message "prova bot123456:ABCDEFghij1234567890abcdefghij fine" -LogFile $logf2 -Level OK
  $lc2 = Get-Content -LiteralPath $logf2 -Raw
  Assert-True (($lc2 -match "bot<redacted>") -and ($lc2 -notmatch "ABCDEFghij1234567890abcdefghij")) "token redactato nei log"
  $bogus2 = Get-PiServerPaths -Root (Join-Path $TmpRoot "vuoto2")
  Assert-True (-not (Test-StepRealState -Step "deploy" -Paths $bogus2)) "verify deploy vuoto = false"
  Assert-True (-not (Test-StepRealState -Step "secrets" -Paths $bogus2)) "verify secrets vuoto = false"
  Assert-True (-not (Test-StepRealState -Step "sconosciuto" -Paths $bogus2)) "verify step ignoto = false"
  Assert-True (-not (Test-StepRealState -Step "sleep" -Paths $bogus2)) "sleep sempre rieseguito"
  $threw3 = $false
  try { $null = Test-StepRealState -Step "deploy" -Paths $null } catch { $threw3 = $true }
  Assert-True (-not $threw3) "verifier non lancia mai"

  Write-Host "== pi authentication verifier =="
  $fakeBin = Join-Path $TmpRoot "fakebin"
  New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
  $piFake = Join-Path $fakeBin "pi-fake.exe"
  "fake" | Out-File -LiteralPath $piFake -Encoding ascii -NoNewline
  $noAuthDir = Join-Path $TmpRoot "noauthdir"
  New-Item -ItemType Directory -Path $noAuthDir -Force | Out-Null
  $srvDir = Join-Path $TmpRoot "srvagent"
  New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
  $usrDir = Join-Path $TmpRoot "usragent"
  New-Item -ItemType Directory -Path $usrDir -Force | Out-Null
  $fakeKey = "sk-ant-fake-UNITTEST-999"
  $goodJson = '{"anthropic":{"type":"api_key","key":"' + $fakeKey + '"}}'
  $goodJson | Out-File -LiteralPath (Join-Path $srvDir "auth.json") -Encoding ascii -NoNewline
  $runReady = { param($E, $A, $D) return @{ ExitCode = 0; Stdout = '{"status":"ready","provider":"anthropic","authType":"api_key"}' } }
  $runNotReady = { param($E, $A, $D) return @{ ExitCode = 1; Stdout = '{"status":"not_ready","provider":"anthropic","reason":"credentials_not_configured"}' } }
  $runInvalid = { param($E, $A, $D) return @{ ExitCode = 2; Stdout = '{"status":"invalid","provider":"anthropic","reason":"invalid_state"}' } }
  $runThrow = { param($E, $A, $D) throw "runner-boom" }
  $runGarbage = { param($E, $A, $D) return @{ ExitCode = 0; Stdout = "hello" } }
  $rReady = Test-PiAuthentication -PiExe $piFake -AgentDir $srvDir -Runner $runReady
  Assert-True ($rReady.Authenticated -and ($rReady.Provider -eq "anthropic") -and ($rReady.SourcePath -eq (Join-Path $srvDir "auth.json"))) "auth valida riconosciuta"
  Assert-True ((($rReady | ConvertTo-Json -Depth 3) -notmatch "UNITTEST-999")) "secret mai nel risultato"
  $rNotReady = Test-PiAuthentication -PiExe $piFake -AgentDir $srvDir -Runner $runNotReady
  Assert-True ((-not $rNotReady.Authenticated) -and ($rNotReady.Reason -match "credentials_not_configured")) "auth non pronta rifiutata"
  $rInvalid = Test-PiAuthentication -PiExe $piFake -AgentDir $srvDir -Runner $runInvalid
  Assert-True ((-not $rInvalid.Authenticated) -and ($rInvalid.Reason -match "invalid")) "auth invalida rifiutata"
  $rThrow = Test-PiAuthentication -PiExe $piFake -AgentDir $srvDir -Runner $runThrow
  Assert-True ((-not $rThrow.Authenticated) -and ($rThrow.Reason -eq "check-failed")) "runner che lancia non propaga"
  $rGarbage = Test-PiAuthentication -PiExe $piFake -AgentDir $srvDir -Runner $runGarbage
  Assert-True (-not $rGarbage.Authenticated) "output non-JSON rifiutato"
  $rNoFile = Test-PiAuthentication -PiExe $piFake -AgentDir $noAuthDir -Runner $runReady
  Assert-True ((-not $rNoFile.Authenticated) -and ($rNoFile.Reason -eq "no-auth-file")) "auth.json assente"
  $badDir = Join-Path $TmpRoot "badauth"
  New-Item -ItemType Directory -Path $badDir -Force | Out-Null
  "not-json{{{" | Out-File -LiteralPath (Join-Path $badDir "auth.json") -Encoding ascii -NoNewline
  $rBad = Test-PiAuthentication -PiExe $piFake -AgentDir $badDir -Runner $runReady
  Assert-True ((-not $rBad.Authenticated) -and ($rBad.Reason -eq "corrupt-auth-file")) "auth.json corrotto"
  $emptyDir = Join-Path $TmpRoot "emptyauth"
  New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
  "{}" | Out-File -LiteralPath (Join-Path $emptyDir "auth.json") -Encoding ascii -NoNewline
  $rEmpty = Test-PiAuthentication -PiExe $piFake -AgentDir $emptyDir -Runner $runReady
  Assert-True ((-not $rEmpty.Authenticated) -and ($rEmpty.Reason -eq "no-providers")) "auth.json vuoto"
  $rNoPi = Test-PiAuthentication -PiExe (Join-Path $TmpRoot "nonesiste.exe") -AgentDir $srvDir -Runner $runReady
  Assert-True ((-not $rNoPi.Authenticated) -and ($rNoPi.Reason -eq "pi-not-found")) "pi mancante"
  $threw4 = $false
  try { $null = Test-PiAuthentication -PiExe $null -AgentDir $null -Runner $null } catch { $threw4 = $true }
  Assert-True (-not $threw4) "verifier non lancia mai (null)"
  $env:PI_CODING_AGENT_DIR = "SENTINEL-XYZ"
  $null = Test-PiAuthentication -PiExe $piFake -AgentDir $srvDir -Runner $runThrow
  Assert-Equal $env:PI_CODING_AGENT_DIR "SENTINEL-XYZ" "env globale intatto (runner fake)"
  Remove-Item Env:\PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($null -eq $nodeExe) { Skip-Test "env restore (default runner)" "node assente" }
  else {
    $env:PI_CODING_AGENT_DIR = "SENTINEL-XYZ"
    $null = Test-PiAuthentication -PiExe $nodeExe -AgentDir $srvDir
    Assert-Equal $env:PI_CODING_AGENT_DIR "SENTINEL-XYZ" "env ripristinato (default runner)"
    Remove-Item Env:\PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue
  }
  $script:seenDirs = @()
  $runCapA = { param($E, $A, $D) $script:seenDirs += "A:" + $D; return @{ ExitCode = 0; Stdout = '{"status":"ready","provider":"provA"}' } }
  $runCapB = { param($E, $A, $D) $script:seenDirs += "B:" + $D; return @{ ExitCode = 0; Stdout = '{"status":"ready","provider":"provB"}' } }
  $usrDir2 = Join-Path $TmpRoot "usragent2"
  New-Item -ItemType Directory -Path $usrDir2 -Force | Out-Null
  '{"provB":{"type":"api_key","key":"x"}}' | Out-File -LiteralPath (Join-Path $usrDir2 "auth.json") -Encoding ascii -NoNewline
  $rS = Test-PiAuthentication -PiExe $piFake -AgentDir $srvDir -Runner $runCapA
  $rU = Test-PiAuthentication -PiExe $piFake -AgentDir $usrDir2 -Runner $runCapB
  Assert-True (($rS.Provider -eq "provA") -and ($rU.Provider -eq "provB")) "server-dir e user-dir non confusi"
  Assert-True (($script:seenDirs -contains ("A:" + $srvDir)) -and ($script:seenDirs -contains ("B:" + $usrDir2))) "runner riceve la dir corretta"

  Write-Host "== pi-auth menu + migrazione =="
  Assert-Equal (Show-PiAuthMenu -HasUserAuth $true -ReadFunc { param($o) return "l" }) "login" "menu L"
  Assert-Equal (Show-PiAuthMenu -HasUserAuth $true -ReadFunc { param($o) return "m" }) "migrate" "menu M con user auth"
  $script:menuN = 0
  $mNoM = Show-PiAuthMenu -HasUserAuth $false -ReadFunc { param($o) $script:menuN++; if ($script:menuN -eq 1) { return "m" } else { return "e" } }
  Assert-Equal $mNoM "exit" "menu M senza user auth = reprompt poi E"
  $script:menuN = 0
  $mBad = Show-PiAuthMenu -HasUserAuth $false -ReadFunc { param($o) $script:menuN++; if ($script:menuN -eq 1) { return "xyz" } else { return "r" } }
  Assert-Equal $mBad "retry" "menu invalido = reprompt"
  $mDef = Show-PiAuthMenu -HasUserAuth $false -ReadFunc { param($o) return "" }
  Assert-Equal $mDef "retry" "menu vuoto = default R"
  $migSrc = Join-Path $TmpRoot "mig-user-auth.json"
  $migDst = Join-Path $TmpRoot "mig-srv-auth.json"
  $goodJson | Out-File -LiteralPath $migSrc -Encoding ascii -NoNewline
  $mig1 = Copy-PiAuthToServerDir -UserAuthPath $migSrc -ServerAuthPath $migDst
  Assert-True ($mig1.Ok -and ($mig1.Backup -eq "")) "migrazione ok senza backup"
  Assert-Equal (Get-Content -LiteralPath $migDst -Raw) $goodJson "contenuto migrato identico"
  Assert-Equal (Get-Content -LiteralPath $migSrc -Raw) $goodJson "originale preservato"
  Assert-True ((($mig1 | ConvertTo-Json -Depth 3) -notmatch "UNITTEST-999")) "secret mai nel risultato migrazione"
  "vecchio" | Out-File -LiteralPath $migDst -Encoding ascii -NoNewline
  $mig2 = Copy-PiAuthToServerDir -UserAuthPath $migSrc -ServerAuthPath $migDst
  Assert-True ($mig2.Ok -and ($mig2.Backup -ne "") -and (Test-Path -LiteralPath $mig2.Backup)) "migrazione con backup esistente"
  Assert-Equal (Get-Content -LiteralPath $migDst -Raw) $goodJson "contenuto sostituito"
  $mig3 = Copy-PiAuthToServerDir -UserAuthPath (Join-Path $TmpRoot "assente.json") -ServerAuthPath $migDst
  Assert-True ((-not $mig3.Ok) -and ($mig3.Detail -eq "user-missing")) "sorgente mancante"
  Assert-True ((@(Get-ChildItem -LiteralPath $TmpRoot -Filter "mig-srv-auth.json.tmp-*")).Count -eq 0) "nessun tmp residuo"
  $aclShape = Test-AuthAcl -Path (Join-Path $TmpRoot "assente.json")
  Assert-True ((-not $aclShape.Ok) -and ($aclShape.Detail -ne "")) "acl: shape su path mancante"
  if ($env:OS -ne "Windows_NT") { Skip-Test "ACL SYSTEM positiva" "non-Windows (icacls assente)" }
  else {
    $aclPos = Test-AuthAcl -Path $migDst
    Assert-True $aclPos.Ok "ACL SYSTEM presente dopo migrazione (solo Windows)"
  }

  Write-Host "== verifier secrets con auth reale =="
  $vRoot = Get-PiServerPaths -Root (Join-Path $TmpRoot "VPi")
  New-Item -ItemType Directory -Path $vRoot.SecretsDir -Force | Out-Null
  New-Item -ItemType Directory -Path $vRoot.AgentDir -Force | Out-Null
  "tok" | Out-File -LiteralPath (Join-Path $vRoot.SecretsDir "server-bot-token") -Encoding ascii -NoNewline
  "hm" | Out-File -LiteralPath (Join-Path $vRoot.SecretsDir "remote-hmac") -Encoding ascii -NoNewline
  '{"profiles":{"default":{"botToken":"x","allowedUserId":123}}}' | Out-File -LiteralPath (Join-Path $vRoot.AgentDir "telegram.json") -Encoding ascii -NoNewline
  $goodJson | Out-File -LiteralPath (Join-Path $vRoot.AgentDir "auth.json") -Encoding ascii -NoNewline
  Assert-True (Test-StepRealState -Step "secrets" -Paths $vRoot -PiBin $piFake -AuthRunner $runReady) "secrets ok con auth valida (resume salta)"
  Assert-True (-not (Test-StepRealState -Step "secrets" -Paths $vRoot -PiBin $piFake -AuthRunner $runNotReady)) "secrets ko con auth invalida (resume riesegue)"
  Remove-Item -LiteralPath (Join-Path $vRoot.AgentDir "auth.json") -Force
  Assert-True (-not (Test-StepRealState -Step "secrets" -Paths $vRoot -PiBin $piFake -AuthRunner $runReady)) "secrets ko senza auth.json"

  Write-Host "== runtime hydration (resume-safe) =="
  $instPath = Join-Path $RepoRoot "installer\windows-installer.ps1"
  $instText = Get-Content -LiteralPath $instPath -Raw
  Assert-True ($instText -match '\$hmacShowOnce = ""') "init hmacShowOnce anti-strict"
  Assert-True ($instText -match '\$piCmd = \$null') "init piCmd anti-strict"
  Assert-True ($instText -match '\$NpmGlobalBin = \$null') "init NpmGlobalBin anti-strict"
  Assert-True ($instText -match '\$appBackup = \$null') "init appBackup anti-strict"
  Assert-True ($instText -match 'Set-StrictMode -Version 2\.0') "strict mode attivo"
  Assert-True ($instText -notmatch 'Set-StrictMode -Off') "strict mai disabilitato"
  Assert-True (((($instText -split 'Resolve-PiRuntime').Count - 1)) -ge 4) "Resolve-PiRuntime cablato"
  Assert-True (((($instText -split 'Resolve-NodeRuntime').Count - 1)) -ge 3) "Resolve-NodeRuntime cablato"
  Assert-True (((($instText -split 'Resolve-RemotePort').Count - 1)) -ge 3) "Resolve-RemotePort cablato"
  Assert-True (((($instText -split 'Resolve-PiOrThrow').Count - 1)) -ge 5) "guard PiOrThrow negli step"
  Assert-True (((($instText -split 'Resolve-NodeOrThrow').Count - 1)) -ge 2) "guard NodeOrThrow negli step"
  $hydIdx = $instText.IndexOf('$NodeExe = Resolve-NodeRuntime')
  $step1Idx = $instText.IndexOf('Step "1/11"')
  Assert-True (($hydIdx -gt 0) -and ($hydIdx -lt $step1Idx)) "hydration incondizionata prima degli step"

  $rpDir = Join-Path $TmpRoot "rp"
  New-Item -ItemType Directory -Path $rpDir -Force | Out-Null
  Assert-Equal (Resolve-RemotePort -AgentDir $rpDir) "43128" "porta default senza config"
  Assert-Equal (Resolve-RemotePort -AgentDir "") "43128" "porta default senza dir"
  '{"port":43129,"maxSkewSeconds":300,"allowedServices":["pi-server"]}' | Out-File -LiteralPath (Join-Path $rpDir "remote-server.json") -Encoding ascii -NoNewline
  Assert-Equal (Resolve-RemotePort -AgentDir $rpDir) "43129" "porta da config valida"
  '{"port":"abc"}' | Out-File -LiteralPath (Join-Path $rpDir "remote-server.json") -Encoding ascii -NoNewline
  Assert-Equal (Resolve-RemotePort -AgentDir $rpDir) "43128" "porta invalida -> default"
  '{"port":99999}' | Out-File -LiteralPath (Join-Path $rpDir "remote-server.json") -Encoding ascii -NoNewline
  Assert-Equal (Resolve-RemotePort -AgentDir $rpDir) "43128" "porta fuori range -> default"
  'not-json{{{' | Out-File -LiteralPath (Join-Path $rpDir "remote-server.json") -Encoding ascii -NoNewline
  Assert-Equal (Resolve-RemotePort -AgentDir $rpDir) "43128" "config corrotto -> default"

  $oldAppData = $env:APPDATA
  try {
    $fakeAppData = Join-Path $TmpRoot "appdata"
    New-Item -ItemType Directory -Path (Join-Path $fakeAppData "npm") -Force | Out-Null
    $fakeAppPi = Join-Path $fakeAppData "npm\pi.cmd"
    "x" | Out-File -LiteralPath $fakeAppPi -Encoding ascii -NoNewline
    $env:APPDATA = $fakeAppData
    Assert-True ((@(Get-PiCandidatePaths) -contains $fakeAppPi)) "fallback APPDATA trovato"
    $hintTarget = Join-Path $TmpRoot "hintpi\pi.cmd"
    New-Item -ItemType Directory -Path (Split-Path -Parent $hintTarget) -Force | Out-Null
    "x" | Out-File -LiteralPath $hintTarget -Encoding ascii -NoNewline
    $envFile = Join-Path $TmpRoot "runtime-env-hint.json"
    ('{"PiBin":"' + $hintTarget.Replace('\', '\\') + '"}') | Out-File -LiteralPath $envFile -Encoding ascii -NoNewline
    Assert-True ((@(Get-PiCandidatePaths -RuntimeEnvPath $envFile) -contains $hintTarget)) "hint runtime-env valido usato"
    $staleTarget = Join-Path $TmpRoot "stale-xyz\pi.cmd"
    $staleFile = Join-Path $TmpRoot "runtime-env-stale.json"
    ('{"PiBin":"' + $staleTarget.Replace('\', '\\') + '"}') | Out-File -LiteralPath $staleFile -Encoding ascii -NoNewline
    Assert-True ((@(Get-PiCandidatePaths -RuntimeEnvPath $staleFile) -notcontains $staleTarget)) "hint stale ignorato"
  } finally {
    if ($null -eq $oldAppData) { Remove-Item Env:\APPDATA -ErrorAction SilentlyContinue }
    else { $env:APPDATA = $oldAppData }
  }

  $oldPath = $env:PATH
  try {
    $fakeBin = Join-Path $TmpRoot "fakebin"
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    if ($env:OS -eq "Windows_NT") {
      $fakePi = Join-Path $fakeBin "pi.cmd"
      "@echo off`r`nexit /b 0`r`n" | Out-File -LiteralPath $fakePi -Encoding ascii -NoNewline
    } else {
      $fakePi = Join-Path $fakeBin "pi"
      "#!/bin/sh`nexit 0`n" | Out-File -LiteralPath $fakePi -Encoding ascii -NoNewline
      try { & chmod +x $fakePi } catch { }
    }
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    Assert-Equal (Resolve-PiRuntime) $fakePi "pi trovato via PATH (step 2/3 skipped -> ricostruito)"
    $nodeRes = Resolve-NodeRuntime
    if ($null -eq (Resolve-ToolPath "node")) { Assert-True ($null -eq $nodeRes) "node assente -> null" }
    else {
      Assert-True (($null -ne $nodeRes) -and (Test-Path -LiteralPath $nodeRes)) "node presente -> path valido"
      $nv = & $nodeRes -p "process.versions.node" 2>$null
      Assert-True (Test-AtLeastNode22 -VersionString $nv) "node risolto >= 22"
    }
  } finally { $env:PATH = $oldPath }

  $oldPath2 = $env:PATH
  try {
    $nopeEnv = Join-Path $TmpRoot "nope.json"
    if ($env:OS -eq "Windows_NT") {
      $fixedC = @((Join-Path $env:APPDATA "npm\pi.cmd"), "C:\Program Files\nodejs\pi.cmd", (Join-Path ${env:ProgramFiles} "nodejs\pi.cmd"))
      $anyFixed = (@($fixedC | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0)
      if ($anyFixed) { Skip-Test "pi-assente" "pi esiste fuori PATH (assenza non simulabile)" }
      else {
        $env:PATH = "C:\Windows\System32;C:\Windows"
        Assert-True ($null -eq (Resolve-PiRuntime -RuntimeEnvPath $nopeEnv)) "pi assente -> null, nessun throw"
      }
    } else {
      $env:PATH = "/usr/bin:/bin"
      Assert-True ($null -eq (Resolve-PiRuntime -RuntimeEnvPath $nopeEnv)) "pi assente -> null, nessun throw"
    }
  } finally { $env:PATH = $oldPath2 }

  $childHost = $null
  if ($env:OS -eq "Windows_NT") {
    $ps51 = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $ps51) { $childHost = $ps51 }
  }
  if ($null -eq $childHost) {
    $wc = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $wc) { $childHost = $wc.Source }
  }
  if ($null -eq $childHost) { Skip-Test "fresh-session" "nessun host figlio disponibile" }
  else {
    $childLines = @(
      '. "' + $LibPath + '"',
      'Set-StrictMode -Version 2.0',
      '$NodeExe = $null',
      '$piCmd = $null',
      '$NpmGlobalBin = $null',
      '$RemotePort = $null',
      '$strictOn = $false',
      'try { $z = $noSuchVarHydrationCheck123 } catch { $strictOn = $true }',
      'if (-not $strictOn) { exit 10 }',
      '$piCmd = Resolve-PiRuntime',
      '$RemotePort = Resolve-RemotePort -AgentDir ""',
      'if ($RemotePort -ne "43128") { exit 11 }',
      'if (($null -ne $piCmd) -and (-not (Test-Path -LiteralPath $piCmd))) { exit 12 }',
      'exit 0')
    $childFile = Join-Path $TmpRoot "fresh-hydration.ps1"
    $childLines | Out-File -LiteralPath $childFile -Encoding ascii -NoNewline
    & $childHost -NoProfile -NonInteractive -File $childFile
    Assert-Equal $LASTEXITCODE 0 "fresh PowerShell: hydration senza UndefinedVariable"
  }

  Write-Host "== runtime layout contract (Bug 1) =="
  $layRoot = Join-Path $TmpRoot "layout"
  New-Item -ItemType Directory -Path $layRoot -Force | Out-Null
  $payL = Join-Path $layRoot "pay"
  New-MiniPayload $payL
  $appL = Join-Path $layRoot "app"
  $stL = Invoke-AppStaging -PayloadDir $payL -AppPath $appL -Mode "fresh" -VersionLabel "v9.9.9-layout"
  Assert-True $stL.Ok "staging con launcher OK"
  Assert-True ((Test-Path -LiteralPath (Join-Path $appL "run-task.ps1")) -and (Test-Path -LiteralPath (Join-Path $appL "run-remote.ps1"))) "launcher promossi in app root"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $appL "run-task.ps1") -Raw) "payload:installer\run-task.ps1" "contenuto launcher preservato"
  Assert-True ((Test-ReleaseManifest -PayloadRoot $appL -Manifest $script:AppManifest).Ok) "live app soddisfa AppManifest"
  $payNoL = Join-Path $layRoot "payNoL"
  New-MiniPayload $payNoL
  Remove-Item -LiteralPath (Join-Path $payNoL "installer\run-task.ps1") -Force
  "SENTINELLA-LAYOUT" | Out-File -LiteralPath (Join-Path $appL "server\pi-daemon.mjs") -Encoding ascii -NoNewline
  $stNoL = Invoke-AppStaging -PayloadDir $payNoL -AppPath $appL -Mode "update" -VersionLabel "v9.9.9-nol"
  Assert-True (-not $stNoL.Ok) "staging senza launcher rifiutato pre-swap"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $appL "server\pi-daemon.mjs") -Raw) "SENTINELLA-LAYOUT" "live intatta dopo promotion fallita"
  $mOld = Test-ReleaseManifest -PayloadRoot $payL -Manifest $script:AppManifest
  Assert-True ((-not $mOld.Ok) -and ($mOld.Missing -contains "run-task.ps1")) "layout v0.2.5 rilevato come incompleto"

  Write-Host "== task real-state deep check (Bug 4) =="
  function New-FakeTask {
    param([string]$Exe, [string]$ArgList, [string]$WorkDir, [string]$User, [string]$State = "Ready")
    $fa = [PSCustomObject]@{ Execute = $Exe; Arguments = $ArgList; WorkingDirectory = $WorkDir }
    return [PSCustomObject]@{ Actions = @($fa); Principal = [PSCustomObject]@{ UserId = $User }; State = $State }
  }
  $taskRoot = Join-Path $TmpRoot "tasks"
  New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
  $goodLauncher = Join-Path $taskRoot "run-task.ps1"
  "launcher" | Out-File -LiteralPath $goodLauncher -Encoding ascii -NoNewline
  $goodWd = Join-Path $taskRoot "server"
  New-Item -ItemType Directory -Path $goodWd -Force | Out-Null
  $goodArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $goodLauncher + '"'
  $global:ttGood = New-FakeTask -Exe "powershell.exe" -ArgList $goodArgs -WorkDir $goodWd -User "SYSTEM"
  $rGood = { param($n) return $global:ttGood }
  Assert-True (Test-TaskDefinition -TaskName "T" -ExpectedFile $goodLauncher -ExpectedWorkDir $goodWd -TaskReader $rGood) "task corretta = true"
  $global:ttStale = New-FakeTask -Exe "powershell.exe" -ArgList '-NoProfile -ExecutionPolicy Bypass -File "C:\PiServer\app\installer\run-task.ps1"' -WorkDir $goodWd -User "SYSTEM"
  $rStale = { param($n) return $global:ttStale }
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile $goodLauncher -ExpectedWorkDir $goodWd -TaskReader $rStale)) "action stale v0.2.5 = false"
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile (Join-Path $taskRoot "assente.ps1") -ExpectedWorkDir $goodWd -TaskReader $rGood)) "launcher mancante = false"
  $ma1 = [PSCustomObject]@{ Execute = "powershell.exe"; Arguments = $goodArgs; WorkingDirectory = $goodWd }
  $ma2 = [PSCustomObject]@{ Execute = "powershell.exe"; Arguments = $goodArgs; WorkingDirectory = $goodWd }
  $global:ttMulti = [PSCustomObject]@{ Actions = @($ma1, $ma2); Principal = [PSCustomObject]@{ UserId = "SYSTEM" }; State = "Ready" }
  $rMulti = { param($n) return $global:ttMulti }
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile $goodLauncher -ExpectedWorkDir $goodWd -TaskReader $rMulti)) "action extra legacy = false"
  $global:ttExe = New-FakeTask -Exe "cmd.exe" -ArgList $goodArgs -WorkDir $goodWd -User "SYSTEM"
  $rExe = { param($n) return $global:ttExe }
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile $goodLauncher -ExpectedWorkDir $goodWd -TaskReader $rExe)) "execute errato = false"
  $global:ttWd = New-FakeTask -Exe "powershell.exe" -ArgList $goodArgs -WorkDir $taskRoot -User "SYSTEM"
  $rWd = { param($n) return $global:ttWd }
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile $goodLauncher -ExpectedWorkDir $goodWd -TaskReader $rWd)) "working dir errata = false"
  $global:ttUser = New-FakeTask -Exe "powershell.exe" -ArgList $goodArgs -WorkDir $goodWd -User "Administrators"
  $rUser = { param($n) return $global:ttUser }
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile $goodLauncher -ExpectedWorkDir $goodWd -TaskReader $rUser)) "principal non-SYSTEM = false"
  $rNull = { param($n) return $null }
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile $goodLauncher -ExpectedWorkDir $goodWd -TaskReader $rNull)) "task assente = false"

  Write-Host "== unix timestamp culture-invariant (Bug 2) =="
  $oldCult = [Threading.Thread]::CurrentThread.CurrentCulture
  try {
    foreach ($cn in @("it-IT", "en-US", "de-DE")) {
      try { [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cn) } catch { continue }
      $tsc = Get-UnixTimestampSeconds
      Assert-True ($tsc -match "^\d+$") ("timestamp " + $cn + " solo cifre")
    }
  } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCult }
  $tsNum = Get-UnixTimestampSeconds
  $tsLong = [long]0
  Assert-True ([long]::TryParse($tsNum, [ref]$tsLong) -and ($tsLong -gt 1700000000)) "timestamp Int64 plausibile"
  $libText = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "PiServerLib.ps1") -Raw
  Assert-True ($libText -notmatch "-UFormat %s") "niente UFormat residuo"
  Assert-True ($libText -match "ToUnixTimeSeconds") "sorgente Int64 unica"
  Assert-True ($libText -match '\$ts = Get-UnixTimestampSeconds') "probe usa helper"

  Write-Host "== process CommandLine match (Bug 3) =="
  $fp1 = [PSCustomObject]@{ CommandLine = "node.exe C:\PiServer\app\server\pi-remote-server\index.ts" }
  Assert-True (Test-CommandLineMatch -Process $fp1 -Pattern "pi-remote-server") "match CommandLine"
  Assert-True (-not (Test-CommandLineMatch -Process ([PSCustomObject]@{ CommandLine = $null }) -Pattern "pi-remote-server")) "CommandLine null = false"
  Assert-True (-not (Test-CommandLineMatch -Process $null -Pattern "pi-remote-server")) "processo null = false"
  Assert-True (-not (Test-CommandLineMatch -Process $fp1 -Pattern "pi-daemon\.mjs")) "pattern diverso = false"
  Assert-True ($libText -match '-ProcessPattern "pi-remote-server"') "health cerca processo remoto"
  Assert-True ($libText -notmatch '\$_ -match "pi-remote-server"') "niente match su oggetto CIM"

  Write-Host "== task startup polling =="
  $probeDead = { return $false }
  $readerReady = { param($n) return [PSCustomObject]@{ State = "Ready" } }
  $infoFail = { param($n) return [PSCustomObject]@{ LastTaskResult = 1 } }
  $wDead = Wait-TaskStartup -TaskName "TKO" -LauncherPath (Join-Path $TmpRoot "nope.ps1") -ProcessMatch "zzz-inesistente" -LogPath (Join-Path $TmpRoot "nope.log") -TimeoutSec 30 -EarlyExitSec 0 -TaskReader $readerReady -TaskInfoReader $infoFail -ProcessProbe $probeDead
  Assert-True ((-not $wDead.Ok) -and ($wDead.Detail -match "LastTaskResult") -and ($wDead.Detail -match "LauncherExists: False")) "exit immediato diagnosticato"
  $probeLive = { return $true }
  $wLive = Wait-TaskStartup -TaskName "TOK" -LauncherPath $goodLauncher -ProcessMatch "zzz" -LogPath (Join-Path $TmpRoot "nope.log") -TimeoutSec 5 -TaskReader $readerReady -TaskInfoReader $infoFail -ProcessProbe $probeLive
  Assert-True ($wLive.Ok -and ($wLive.Detail -match "processo presente")) "processo vivo = ok"

  Write-Host "== health diagnostics =="
  $global:ttDiag = New-FakeTask -Exe "powershell.exe" -ArgList $goodArgs -WorkDir $goodWd -User "SYSTEM" -State "Ready"
  $infoD = [PSCustomObject]@{ LastTaskResult = 1 }
  $dMissing = Format-TaskDiagnostics -Task $global:ttDiag -TaskName "TDIAG" -ExpectedFile $goodLauncher -LogPath (Join-Path $taskRoot "assente.log") -ProcessPattern "zzz-inesistente" -TaskInfo $infoD -Processes @()
  Assert-True ((@($dMissing) -match "log assente").Count -ge 1) "log assente diagnosticato"
  Assert-True ((@($dMissing) -match "State=Ready").Count -ge 1) "contesto State presente"
  Assert-True ((@($dMissing) -match "LastTaskResult=1").Count -ge 1) "contesto LastTaskResult presente"
  $secLog = Join-Path $taskRoot "sec.log"
  @("riga normale", "riga con bot123456:ABCDEFghijklmnopqrstuvwxyz1234567890 dentro", "hmac=deadbeef1234") | Out-File -LiteralPath $secLog -Encoding ascii
  $st5 = Get-SanitizedLogTail -Path $secLog -MaxLines 5
  Assert-True (($st5 -match "bot<redacted>") -and ($st5 -notmatch "ABCDEF")) "token redatto"
  Assert-True (($st5 -match "hmac=<redacted>") -and ($st5 -notmatch "deadbeef")) "hmac redatto"
  Assert-True ((Get-SanitizedLogTail -Path (Join-Path $taskRoot "assente.log")) -eq "") "tail assente = stringa vuota"

  Write-Host "== resume v0.2.5 rotta -> autoriparazione =="
  $setupText = Get-Content -LiteralPath (Join-Path $RepoRoot "setup.ps1") -Raw
  Assert-True ($setupText -match '\$concreteTag = \[string\]\$rel\.tag_name') "bootstrap risolve tag concreto"
  $wiText2 = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "windows-installer.ps1") -Raw
  Assert-True ($wiText2 -match '\$ver = \[string\]\$script:InstallState\.targetRelease') "VERSION da targetRelease concreto"
  $oldRoot = Get-PiServerPaths -Root (Join-Path $TmpRoot "v255")
  New-Item -ItemType Directory -Path $oldRoot.App -Force | Out-Null
  foreach ($rel in $script:ReleaseManifest) {
    $ofp = Join-Path $oldRoot.App $rel
    $odd = Split-Path -Parent $ofp
    if (-not (Test-Path -LiteralPath $odd)) { New-Item -ItemType Directory -Path $odd -Force | Out-Null }
    ("v255:" + $rel) | Out-File -LiteralPath $ofp -Encoding ascii -NoNewline
  }
  "v0.2.5" | Out-File -LiteralPath $oldRoot.VersionFile -Encoding ascii -NoNewline
  Assert-True (-not (Test-StepRealState -Step "deploy" -Paths $oldRoot -ExpectedRelease "v0.2.6")) "VERSION mismatch forza deploy"
  Assert-True (-not (Test-StepRealState -Step "deploy" -Paths $oldRoot -ExpectedRelease "")) "layout v0.2.5 senza launcher fallisce AppManifest"
  "v0.2.6" | Out-File -LiteralPath $oldRoot.VersionFile -Encoding ascii -NoNewline
  "L1" | Out-File -LiteralPath $oldRoot.RunTask -Encoding ascii -NoNewline
  "L2" | Out-File -LiteralPath $oldRoot.RunRemote -Encoding ascii -NoNewline
  Assert-True (Test-StepRealState -Step "deploy" -Paths $oldRoot -ExpectedRelease "v0.2.6") "deploy riparato = true"
  $oldWd = Split-Path -Parent $oldRoot.Daemon
  $global:ttOld = New-FakeTask -Exe "powershell.exe" -ArgList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $oldRoot.App "installer\run-task.ps1") + '"') -WorkDir $oldWd -User "SYSTEM"
  $rOld = { param($n) return $global:ttOld }
  Assert-True (-not (Test-TaskDefinition -TaskName "T" -ExpectedFile $oldRoot.RunTask -ExpectedWorkDir $oldWd -TaskReader $rOld)) "task v0.2.5 invalida il real-state"
  Remove-Variable -Name ttGood,ttStale,ttMulti,ttExe,ttWd,ttUser,ttDiag,ttOld -Scope Global -ErrorAction SilentlyContinue

  Write-Host "== transactional upgrade (auto-update, stop, swap, rollback) =="
  Assert-True (-not (Test-ShouldAutoUpdate -InstalledVersion "" -TargetVersion "v0.2.8")) "fresh install mai update"
  Assert-True (-not (Test-ShouldAutoUpdate -InstalledVersion "v0.2.7" -TargetVersion "v0.2.7")) "stessa versione mai update"
  Assert-True (Test-ShouldAutoUpdate -InstalledVersion "v0.2.6" -TargetVersion "v0.2.7") "versione diversa auto-update"
  Assert-True (Test-ShouldAutoUpdate -InstalledVersion "v0.2.6" -TargetVersion "latest") "latest + installato auto-update"
  Assert-True (Test-ShouldAutoUpdate -InstalledVersion "v0.2.6" -TargetVersion "") "target vuoto + installato auto-update (fail-safe)"
  Assert-True (-not (Test-ShouldAutoUpdate -InstalledVersion "" -TargetVersion "latest")) "latest senza installato mai update"
  $ppPaths = Get-PiServerPaths -Root (Join-Path $TmpRoot "psrv")
  Assert-True (($ppPaths.InstallerTranscript -ne $ppPaths.InstallerLog)) "transcript separato da installer.log"
  Assert-True ((Split-Path -Parent $ppPaths.InstallerTranscript) -eq (Split-Path -Parent $ppPaths.InstallerLog)) "transcript nella stessa logs dir"
  Assert-True ($ppPaths.InstallerTranscript -like "*installer-transcript.log") "nome transcript"
  $connFree = { param($p) return @() }
  $oFree = Get-TcpListenerOwner -Port 43128 -ConnectionReader $connFree
  Assert-True ((-not $oFree.Listening) -and ($oFree.Detail -eq "free")) "porta libera"
  $connHit = { param($p) return @([PSCustomObject]@{ LocalPort = 43128; State = "Listen"; OwningProcess = 1234 }) }
  $procHit = { param($x) return @([PSCustomObject]@{ ProcessId = 1234; Name = "node.exe"; CommandLine = "node C:\PiServer\app\server\pi-remote-server\index.ts" }) }
  $oHit = Get-TcpListenerOwner -Port 43128 -ConnectionReader $connHit -ProcessReader $procHit
  Assert-True (($oHit.Listening) -and ($oHit.Pid -eq 1234) -and ($oHit.Name -eq "node.exe")) "listener risolto con pid/nome"
  $oBad = Get-TcpListenerOwner -Port 0 -ConnectionReader $connHit
  Assert-True (-not $oBad.Listening) "porta invalida"
  $ownForeign = @{ Listening = $true; Pid = 9999; Name = "other.exe"; CommandLine = "C:\Other\app.exe --serve"; Detail = "x" }
  Assert-True (-not (Test-PortOwnerIsOurs -Owner $ownForeign -Paths $ppPaths)) "foreign non nostro"
  $ownOurs = @{ Listening = $true; Pid = 4321; Name = "node.exe"; CommandLine = ("node " + $ppPaths.App + "\server\pi-remote-server\index.ts"); Detail = "x" }
  Assert-True (Test-PortOwnerIsOurs -Owner $ownOurs -Paths $ppPaths) "approot nostro"
  $ownMark = @{ Listening = $true; Pid = 4322; Name = "pwsh"; CommandLine = "pi-daemon.mjs --x"; Detail = "x" }
  Assert-True (Test-PortOwnerIsOurs -Owner $ownMark -Paths $ppPaths) "marker nostro"
  Assert-True (-not (Test-PortOwnerIsOurs -Owner $null -Paths $ppPaths)) "owner null = false"
  Assert-True (-not (Test-PortOwnerIsOurs -Owner @{ Listening = $false } -Paths $ppPaths)) "non-listening = false"
  $global:upKillLog = @()
  $stopRec = { param($p) $global:upKillLog += $p }
  $rFreeOwner = { param($x) return @{ Listening = $false; Pid = 0; Name = ""; CommandLine = ""; Detail = "free" } }
  $cFree = Clear-OwnPortListener -Port 43128 -Paths $ppPaths -OwnerReader $rFreeOwner -Stopper $stopRec
  Assert-True (($cFree.Ok) -and ($cFree.ActionTaken -eq "none")) "porta libera: nessun kill"
  Assert-True ($global:upKillLog.Count -eq 0) "nessun kill su porta libera"
  $global:upForeign = @{ Listening = $true; Pid = 9999; Name = "other.exe"; CommandLine = "C:\Other\app.exe --serve"; Detail = "x" }
  $rForeign = { param($x) return $global:upForeign }
  $cFor = Clear-OwnPortListener -Port 43128 -Paths $ppPaths -OwnerReader $rForeign -Stopper $stopRec
  Assert-True ((-not $cFor.Ok) -and ($cFor.ActionTaken -eq "none") -and ($cFor.Detail -match "9999")) "foreign: fail senza kill"
  Assert-True ($global:upKillLog.Count -eq 0) "foreign mai killato"
  $global:upFlapGone = $false
  $global:upOwn = @{ Listening = $true; Pid = 4321; Name = "node.exe"; CommandLine = ("node " + $ppPaths.App + "\server\x.js"); Detail = "x" }
  $rFlap = { param($x) if ($global:upFlapGone) { return @{ Listening = $false; Pid = 0; Name = ""; CommandLine = ""; Detail = "free" } } else { return $global:upOwn } }
  $stopFlap = { param($p) $global:upKillLog += $p; $global:upFlapGone = $true }
  $cOwn = Clear-OwnPortListener -Port 43128 -Paths $ppPaths -OwnerReader $rFlap -Stopper $stopFlap -TimeoutSec 10
  Assert-True (($cOwn.Ok) -and ($cOwn.ActionTaken -eq "stopped-pid-4321")) "stale own killato e porta libera"
  $cPers = Clear-OwnPortListener -Port 43128 -Paths $ppPaths -OwnerReader $rForeign -Stopper $stopRec -TimeoutSec 1
  Assert-True ((-not $cPers.Ok) -and ($cPers.ActionTaken -eq "none")) "foreign persistente: fail senza retry di kill"
  $global:upPersOwn = @{ Listening = $true; Pid = 4322; Name = "node.exe"; CommandLine = ("node " + $ppPaths.App + "\server\y.js"); Detail = "x" }
  $rPersOwn = { param($x) return $global:upPersOwn }
  $cPersOwn = Clear-OwnPortListener -Port 43128 -Paths $ppPaths -OwnerReader $rPersOwn -Stopper $stopRec -TimeoutSec 1
  Assert-True ((-not $cPersOwn.Ok) -and ($cPersOwn.ActionTaken -eq "stop-ineffective")) "stale persistente: fail"
  $rNoTasks = { param($n) return $null }
  $probeIdle = { return @() }
  $sIdle = Stop-PiServerRuntime -Paths $ppPaths -RemotePort 43128 -TaskReader $rNoTasks -ProcessProbe $probeIdle -ConnectionReader $connFree
  Assert-True (($sIdle.Ok) -and (-not $sIdle.WasPiRunning) -and (-not $sIdle.WasRemoteRunning)) "niente task/processi: Ok immediato"
  $rRun = { param($n) return [PSCustomObject]@{ State = "Running" } }
  $global:upProcs = @([PSCustomObject]@{ ProcessId = 555; Name = "powershell.exe"; CommandLine = ($ppPaths.App + "\run-task.ps1") })
  $global:upKilled = $false
  $global:upKills = @()
  $probeFlap = { if ($global:upKilled) { return @() } else { return $global:upProcs } }
  $stopFlap2 = { param($p) $global:upKills += $p; $global:upKilled = $true }
  $sStop = Stop-PiServerRuntime -Paths $ppPaths -RemotePort 43128 -TaskReader $rRun -ProcessProbe $probeFlap -ConnectionReader $connFree -Stopper $stopFlap2
  Assert-True (($sStop.Ok) -and $sStop.WasPiRunning -and $sStop.WasRemoteRunning) "task running fermati"
  Assert-True (($global:upKills.Count -eq 1) -and ($global:upKills[0] -eq 555)) "kill sul pid giusto"
  $sPers = Stop-PiServerRuntime -Paths $ppPaths -RemotePort 0 -TimeoutSec 1 -TaskReader $rNoTasks -ProcessProbe { return @([PSCustomObject]@{ ProcessId = 556; Name = "node.exe"; CommandLine = ($ppPaths.App + "\server\pi-daemon.mjs") }) } -Stopper { param($p) }
  Assert-True ((-not $sPers.Ok) -and ($sPers.RemainingProcesses -contains 556)) "processi residui: fail con elenco"
  $selfPid = 0
  try { $selfPid = [System.Diagnostics.Process]::GetCurrentProcess().Id } catch { }
  $global:upSelfHit = $false
  $sSelf = Stop-PiServerRuntime -Paths $ppPaths -RemotePort 0 -TaskReader $rNoTasks -ProcessProbe { return @([PSCustomObject]@{ ProcessId = $selfPid; Name = "pwsh"; CommandLine = ($ppPaths.App + "\x.ps1") }) } -Stopper { param($p) $global:upSelfHit = $true }
  Assert-True ($sSelf.Ok -and (-not $global:upSelfHit)) "self mai killato"
  $rbRoot = Join-Path $TmpRoot "rollback"
  $rbPaths = Get-PiServerPaths -Root (Join-Path $rbRoot "psrv")
  $rbApp = $rbPaths.App
  New-Item -ItemType Directory -Path $rbApp -Force | Out-Null
  New-Item -ItemType Directory -Path $rbPaths.ExtDir -Force | Out-Null
  "NEWAPP" | Out-File -LiteralPath (Join-Path $rbApp "VERSION") -Encoding ascii -NoNewline
  $rbBackup = Join-Path $rbRoot "app.backup-test"
  New-Item -ItemType Directory -Path (Join-Path $rbBackup "server\pi-remote-config") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $rbBackup "shared") -Force | Out-Null
  "OLDAPP" | Out-File -LiteralPath (Join-Path $rbBackup "VERSION") -Encoding ascii -NoNewline
  "ext" | Out-File -LiteralPath (Join-Path $rbBackup "server\pi-remote-config\index.ts") -Encoding ascii -NoNewline
  "sh" | Out-File -LiteralPath (Join-Path $rbBackup "shared\store.ts") -Encoding ascii -NoNewline
  $global:upStarted = @()
  $starterOk = { param($n) $global:upStarted += $n }
  $healthOk = { return @{ Ok = $true; Failures = @() } }
  $stopOk = { return @{ Ok = $true; Detail = "fermo (fake)" } }
  $rb = Invoke-AppRollback -Paths $rbPaths -BackupPath $rbBackup -PiBin "" -RemotePort 0 -RuntimeStopper $stopOk -TaskStarter $starterOk -HealthChecker $healthOk
  Assert-True $rb.Ok "rollback happy path"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $rbApp "VERSION") -Raw) "OLDAPP" "backup ripristinato"
  Assert-True ((($global:upStarted -contains $rbPaths.TaskName) -and ($global:upStarted -contains $rbPaths.RemoteTaskName))) "entrambi i task riavviati"
  Assert-True ($rb.Detail -match "health rollback: OK") "report cita health"
  Assert-True (-not (Invoke-AppRollback -Paths $rbPaths -BackupPath (Join-Path $rbRoot "assente") -RuntimeStopper $stopOk -TaskStarter $starterOk -HealthChecker $healthOk).Ok) "backup assente: fail"
  "NEW2" | Out-File -LiteralPath (Join-Path $rbApp "VERSION") -Encoding ascii -NoNewline
  $stopKo = { return @{ Ok = $false; Detail = "stop rotto (fake)" } }
  $rbNoStop = Invoke-AppRollback -Paths $rbPaths -BackupPath $rbBackup -RuntimeStopper $stopKo -TaskStarter $starterOk -HealthChecker $healthOk
  Assert-True ((-not $rbNoStop.Ok) -and ((Get-Content -LiteralPath (Join-Path $rbApp "VERSION") -Raw) -eq "NEW2")) "stop fallito: app intatta"
  New-Item -ItemType Directory -Path (Join-Path $rbBackup "server\pi-remote-config") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $rbBackup "shared") -Force | Out-Null
  "OLDAPP" | Out-File -LiteralPath (Join-Path $rbBackup "VERSION") -Encoding ascii -NoNewline
  "ext" | Out-File -LiteralPath (Join-Path $rbBackup "server\pi-remote-config\index.ts") -Encoding ascii -NoNewline
  "sh" | Out-File -LiteralPath (Join-Path $rbBackup "shared\store.ts") -Encoding ascii -NoNewline
  $starterKo = { param($n) throw "avvio rotto (fake)" }
  $rbNoStart = Invoke-AppRollback -Paths $rbPaths -BackupPath $rbBackup -RuntimeStopper $stopOk -TaskStarter $starterKo -HealthChecker $healthOk
  Assert-True ((-not $rbNoStart.Ok) -and ((Get-Content -LiteralPath (Join-Path $rbApp "VERSION") -Raw) -eq "OLDAPP")) "start fallito: app ripristinata"
  $hookRoot = Join-Path $TmpRoot "hook"
  New-Item -ItemType Directory -Path $hookRoot -Force | Out-Null
  $payH = Join-Path $hookRoot "pay"
  New-MiniPayload $payH
  $appH = Join-Path $hookRoot "app"
  $global:upHookCalls = 0
  $hookOk = { $global:upHookCalls++; return $null }
  $stHook = Invoke-AppStaging -PayloadDir $payH -AppPath $appH -Mode "fresh" -VersionLabel "v9.9.9-hook" -PreSwapAction $hookOk
  Assert-True ($stHook.Ok -and ($global:upHookCalls -eq 1)) "hook eseguito pre-swap"
  $hookBoom = { return "boom-di-prova" }
  "SENTINELLA-HOOK" | Out-File -LiteralPath (Join-Path $appH "server\pi-daemon.mjs") -Encoding ascii -NoNewline
  $stHookBoom = Invoke-AppStaging -PayloadDir $payH -AppPath $appH -Mode "update" -VersionLabel "v9.9.9-boom" -PreSwapAction $hookBoom
  Assert-True ((-not $stHookBoom.Ok) -and ($stHookBoom.Error -match "boom-di-prova")) "hook con errore blocca swap"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $appH "server\pi-daemon.mjs") -Raw) "SENTINELLA-HOOK" "live intatta dopo hook fallito"
  $hookThrow = { throw "eccezione-hook" }
  $stHookThrow = Invoke-AppStaging -PayloadDir $payH -AppPath $appH -Mode "update" -VersionLabel "v9.9.9-throw" -PreSwapAction $hookThrow
  Assert-True (-not $stHookThrow.Ok) "hook che lancia blocca swap"
  $wiUp = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "windows-installer.ps1") -Raw
  Assert-True ($wiUp -match "Stop-PiServerRuntime -Paths") "step 6 ferma il runtime pre-swap"
  Assert-True ($wiUp -match "-PreSwapAction") "staging riceve hook pre-swap"
  Assert-True ($wiUp -match "Clear-OwnPortListener") "step 9 cancella listener stale"
  Assert-True ($wiUp -match "Invoke-AppRollback") "step 11 rollback transazionale"
  Assert-True ($wiUp -match '\$Paths\.InstallerTranscript') "transcript separato"
  Assert-True ($wiUp -notmatch 'Start-Transcript -Path \$LogFile') "niente transcript su installer.log"
  Assert-True ($wiUp -match "DeployWillRun") "dipendenze deploy->tasks/health"
  Assert-True ($wiUp -match "Test-ShouldAutoUpdate") "auto-update detection"
  Remove-Variable -Name upKillLog,upForeign,upFlapGone,upOwn,upPersOwn,upProcs,upKilled,upKills,upSelfHit,upStarted,upHookCalls -Scope Global -ErrorAction SilentlyContinue

  Write-Host "== orphan pi sweep + move retry + probe verdict (v0.2.9) =="
  $global:upOrphanKills = @()
  $global:upOrphanGone = $false
  $probeOrphan = {
    if ($global:upOrphanGone) { return @() }
    return @(
      [PSCustomObject]@{ ProcessId = 777; Name = "node.exe"; CommandLine = "C:\Users\x\AppData\Roaming\npm\node_modules\picli\cli.js --mode rpc" },
      [PSCustomObject]@{ ProcessId = 778; Name = "notepad.exe"; CommandLine = "C:\Windows\notepad.exe" }
    )
  }
  $stopOrphan = { param($p) $global:upOrphanKills += $p; $global:upOrphanGone = $true }
  $sOrphan = Stop-PiServerRuntime -Paths $ppPaths -RemotePort 0 -TimeoutSec 5 -TaskReader $rNoTasks -ProcessProbe $probeOrphan -Stopper $stopOrphan
  Assert-True $sOrphan.Ok "orfano pi fermato"
  Assert-True (($global:upOrphanKills.Count -eq 1) -and ($global:upOrphanKills[0] -eq 777)) "kill solo orfano, foreign intatto"
  Assert-Equal (Test-ConnectionProbeResult -Connections @() -HadError $false) "free" "vuoto senza errori = free"
  Assert-Equal (Test-ConnectionProbeResult -Connections $null -HadError $true) "probe-failed" "vuoto con errore = probe-failed"
  Assert-Equal (Test-ConnectionProbeResult -Connections @(@{ x = 1 }) -HadError $true) "found" "dati presenti vince"
  $mvRoot = Join-Path $TmpRoot "mvretry"
  $mvSrc = Join-Path $mvRoot "src"
  $mvDst = Join-Path $mvRoot "dst"
  New-Item -ItemType Directory -Path $mvSrc -Force | Out-Null
  "x" | Out-File -LiteralPath (Join-Path $mvSrc "f.txt") -Encoding ascii -NoNewline
  $global:upMvCalls = 0
  $moverFlaky = { param($s, $d) $global:upMvCalls++; if ($global:upMvCalls -lt 3) { throw "lock simulato" }; Move-Item -LiteralPath $s -Destination $d -Force -ErrorAction Stop }
  $rFlaky = Move-ItemWithRetry -Source $mvSrc -Destination $mvDst -Attempts 5 -DelaySec 0 -Mover $moverFlaky
  Assert-True (($rFlaky.Ok) -and ($rFlaky.Attempts -eq 3)) "retry riesce al terzo tentativo"
  Assert-True (Test-Path -LiteralPath (Join-Path $mvDst "f.txt")) "contenuto spostato"
  $moverDead = { param($s, $d) throw "sempre rotto" }
  $rDead = Move-ItemWithRetry -Source (Join-Path $mvRoot "nope") -Destination (Join-Path $mvRoot "dst2") -Attempts 3 -DelaySec 0 -Mover $moverDead
  Assert-True ((-not $rDead.Ok) -and ($rDead.Attempts -eq 3) -and ($rDead.Error -match "sempre rotto")) "sempre rotto: fail dopo N tentativi"
  $rEmpty = Move-ItemWithRetry -Source "" -Destination "x"
  Assert-True ((-not $rEmpty.Ok) -and ($rEmpty.Attempts -eq 0)) "sorgente vuota: fail immediato"
  $repNone = Get-ProcessBlockerReport -Path "" -ProcessProbe { return @() }
  Assert-True ($repNone -eq "") "path vuoto = stringa vuota"
  $repClean = Get-ProcessBlockerReport -Path "C:\PiServer\app" -ProcessProbe { return @() }
  Assert-True ($repClean -eq "") "nessun match = stringa vuota"
  $repSec = Get-ProcessBlockerReport -Path "C:\PiServer\app" -ProcessProbe {
    return @([PSCustomObject]@{ ProcessId = 888; Name = "node.exe"; CommandLine = "node app.js --mode rpc --api-key sk-super-segreta-123" })
  }
  Assert-True (($repSec -match "888") -and ($repSec -notmatch "sk-super-segreta") -and ($repSec -match "redacted")) "secret redatto nel report"
  $repCap = Get-ProcessBlockerReport -Path "C:\PiServer\app" -MaxEntries 1 -ProcessProbe {
    return @(
      [PSCustomObject]@{ ProcessId = 1; Name = "a.exe"; CommandLine = "x --mode rpc" },
      [PSCustomObject]@{ ProcessId = 2; Name = "b.exe"; CommandLine = "y --mode rpc" }
    )
  }
  Assert-True (($repCap -match "pid 1") -and ($repCap -notmatch "pid 2")) "cap MaxEntries"
  $libUp = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "PiServerLib.ps1") -Raw
  Assert-True ($libUp -match "Move-ItemWithRetry -Source") "swap usa move con retry"
  Assert-True ($libUp -match '--mode rpc"\) \{ \$hit = \$true \}') "sweep copre pi orfani"
  Remove-Variable -Name upOrphanKills,upOrphanGone,upMvCalls -Scope Global -ErrorAction SilentlyContinue

  Write-Host "== runtime syntax gate (daemon try/catch v0.2.6) =="
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $nodeCmd) {
    Skip-Test "runtime syntax gate" "node assente"
  } else {
    $rtOk = Test-RuntimeSyntax -NodeExe $nodeCmd.Source -Files @(
      (Join-Path $RepoRoot "server\pi-daemon.mjs"),
      (Join-Path $RepoRoot "server\spawn-pi.mjs"))
    Assert-True $rtOk.Ok "node --check daemon + spawn = exit 0"
    $synDir = Join-Path $TmpRoot "syntax"
    New-Item -ItemType Directory -Path $synDir -Force | Out-Null
    'console.log("ok");' | Out-File -LiteralPath (Join-Path $synDir "good.mjs") -Encoding ascii -NoNewline
    'try { foo() }' | Out-File -LiteralPath (Join-Path $synDir "bad.mjs") -Encoding ascii -NoNewline
    $rtBad = Test-RuntimeSyntax -NodeExe $nodeCmd.Source -Files @((Join-Path $synDir "good.mjs"), (Join-Path $synDir "bad.mjs"))
    Assert-True ((-not $rtBad.Ok) -and ((@($rtBad.Failures) -match "bad\.mjs").Count -ge 1)) "fixture try-senza-catch rifiutata"
    $rtNoNode = Test-RuntimeSyntax -NodeExe (Join-Path $TmpRoot "no-such-node") -Files @((Join-Path $synDir "good.mjs"))
    Assert-True (-not $rtNoNode.Ok) "node assente = fail closed"
    $rtNoFiles = Test-RuntimeSyntax -NodeExe $nodeCmd.Source -Files @()
    Assert-True (-not $rtNoFiles.Ok) "nessun file = fail closed"
  }
  $wiText3 = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "windows-installer.ps1") -Raw
  $gateIdx = $wiText3.IndexOf("Test-RuntimeSyntax -NodeExe")
  $regIdx = $wiText3.IndexOf("Register-ScheduledTask")
  Assert-True (($gateIdx -gt 0) -and ($regIdx -gt $gateIdx)) "step 6 valida daemon PRIMA dei task"
  Assert-True ($wiText3 -match 'Join-Path \(Split-Path -Parent \$Paths\.Daemon\) "spawn-pi\.mjs"') "step 6 controlla anche spawn-pi.mjs"
  $nrText = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "New-Release.ps1") -Raw
  $nrGateIdx = $nrText.IndexOf("Test-RuntimeSyntax")
  $nrZipIdx = $nrText.IndexOf("Compress-Archive")
  Assert-True (($nrGateIdx -gt 0) -and ($nrZipIdx -gt $nrGateIdx)) "release builder valida PRIMA dello ZIP"
  Assert-True ($nrText -match "npm.*run typecheck") "release builder richiede typecheck TS"
  $ciText = Get-Content -LiteralPath (Join-Path $RepoRoot ".github\workflows\ci.yml") -Raw
  Assert-True ($ciText -match "node --check server/pi-daemon\.mjs") "CI controlla pi-daemon.mjs"
  Assert-True ($ciText -match "node --check server/spawn-pi\.mjs") "CI controlla spawn-pi.mjs"

  Write-Host "== release builder rifiuta daemon rotto =="
  $psChild = Join-Path $PSHOME "powershell.exe"
  if (-not (Test-Path -LiteralPath $psChild)) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $pwshCmd) { $psChild = "pwsh" } else { $psChild = "" }
  }
  if ([string]::IsNullOrWhiteSpace($psChild)) {
    Skip-Test "release refusal" "nessun host figlio disponibile"
  } else {
    $fixRepo = Join-Path $TmpRoot "fixrepo"
    New-Item -ItemType Directory -Path $fixRepo -Force | Out-Null
    foreach ($rel in @("server\pi-daemon.mjs", "server\spawn-pi.mjs", "server\pi-remote-config\index.ts",
        "server\pi-remote-config\package.json", "server\pi-remote-server\index.ts", "server\pi-remote-server\server.ts",
        "server\pi-remote-server\migrate.ts", "server\pi-remote-server\tailscale.ts", "shared\protocol.ts",
        "shared\modules.ts", "shared\store.ts", "shared\pi-model.ts", "installer\PiServerLib.ps1", "installer\windows-installer.ps1",
        "installer\run-task.ps1", "installer\run-remote.ps1")) {
      $fd = Join-Path $fixRepo $rel
      $dd = Split-Path -Parent $fd
      if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
      "x" | Out-File -LiteralPath $fd -Encoding ascii -NoNewline
    }
    'try { foo() }' | Out-File -LiteralPath (Join-Path $fixRepo "server\pi-daemon.mjs") -Encoding ascii -NoNewline
    $fixOut = Join-Path $TmpRoot "fixout"
    $nrPath = Join-Path (Split-Path -Parent $PSScriptRoot) "New-Release.ps1"
    $nrOut = & $psChild -NoProfile -NonInteractive -File $nrPath -RepoRoot $fixRepo -OutDir $fixOut -Version "v9.9.9-neg" 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0) "builder esce non-zero su daemon rotto"
    Assert-True ((@(Get-ChildItem -LiteralPath $fixOut -Filter "*.zip" -ErrorAction SilentlyContinue)).Count -eq 0) "nessuno ZIP creato"
    Assert-True ($nrOut -match "(?i)syntax|pi-daemon") "motivo cita la sintassi"
  }
  Write-Host "== v0.3.0 pointer model (immutable releases) =="
  $v3LibDir = Split-Path -Parent $PSScriptRoot
  . (Join-Path $v3LibDir "PiServerUpdate.ps1")
  . (Join-Path $v3LibDir "PiServerDoctor.ps1")
  function New-V3Payload([string]$dir, [string]$ver) {
    foreach ($rel in $script:ReleaseManifestV3) {
      $fp = Join-Path $dir $rel
      $dd = Split-Path -Parent $fp
      if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
      ("v3:" + $rel) | Out-File -LiteralPath $fp -Encoding ascii -NoNewline
    }
    $ver | Out-File -LiteralPath (Join-Path $dir "VERSION") -Encoding ascii -NoNewline
  }
  function New-V3Root([string]$dir) {
    $pp = Get-PiServerPaths -Root $dir
    foreach ($d in @((Join-Path $dir "bin"), (Join-Path $dir "releases"), $pp.Data, $pp.Logs)) {
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    return $pp
  }
  Assert-True (Test-ReleaseVersionFormat -Version "v0.3.0") "formato v0.3.0 ok"
  Assert-True (Test-ReleaseVersionFormat -Version "v10.20.30-rc.1") "prerelease ok"
  Assert-True (-not (Test-ReleaseVersionFormat -Version "0.3.0")) "senza v rifiutata"
  Assert-True (-not (Test-ReleaseVersionFormat -Version "v0.3")) "incompleta rifiutata"
  Assert-True (-not (Test-ReleaseVersionFormat -Version "../../foo")) "traversal rifiutato (F)"
  Assert-True (-not (Test-ReleaseVersionFormat -Version "C:\x\v0.3.0")) "drive path rifiutato"
  Assert-True (-not (Test-ReleaseVersionFormat -Version "\\\\srv\\v0.3.0")) "UNC rifiutata"
  Assert-True (-not (Test-ReleaseVersionFormat -Version "")) "vuota rifiutata"
  $ptrRoot = Join-Path $TmpRoot "v3ptr"
  $ppPtr = New-V3Root $ptrRoot
  $rMiss = Read-ActiveRelease -PointerPath $ppPtr.ActivePointer
  Assert-True ((-not $rMiss.Ok) -and ($rMiss.Error -match "assente")) "pointer assente = fail (E)"
  $w1 = Write-ActiveRelease -PointerPath $ppPtr.ActivePointer -Version "v0.3.0"
  Assert-True $w1.Ok "pointer write ok"
  $r1 = Read-ActiveRelease -PointerPath $ppPtr.ActivePointer
  Assert-True (($r1.Ok) -and ($r1.Version -eq "v0.3.0")) "pointer round-trip"
  $wBad = Write-ActiveRelease -PointerPath $ppPtr.ActivePointer -Version "../../evil"
  Assert-True (-not $wBad.Ok) "pointer write traversal rifiutato"
  $rStill = Read-ActiveRelease -PointerPath $ppPtr.ActivePointer
  Assert-True (($rStill.Ok) -and ($rStill.Version -eq "v0.3.0")) "pointer intatto dopo write rifiutato"
  "non-json{{{" | Out-File -LiteralPath $ppPtr.ActivePointer -Encoding ascii -NoNewline
  $rCorr = Read-ActiveRelease -PointerPath $ppPtr.ActivePointer
  Assert-True (-not $rCorr.Ok) "pointer corrotto = fail (E)"
  (@{ schemaVersion = 99; version = "v0.3.0" } | ConvertTo-Json) | Out-File -LiteralPath $ppPtr.ActivePointer -Encoding ascii -NoNewline
  $rSchema = Read-ActiveRelease -PointerPath $ppPtr.ActivePointer
  Assert-True (-not $rSchema.Ok) "schema futuro rifiutato"
  $resRoot = Join-Path $TmpRoot "v3res"
  $ppRes = New-V3Root $resRoot
  $payRes = Join-Path $resRoot "pay"
  New-V3Payload $payRes "v0.3.0"
  $rdMiss = Resolve-ReleaseDir -Root $resRoot -Version "v0.3.0"
  Assert-True (-not $rdMiss.Ok) "release assente rifiutata"
  $inst0 = Install-ReleaseCandidate -StagingDir $payRes -ReleasesRoot $ppRes.Releases -Version "v0.3.0"
  Assert-True (($inst0.Ok) -and (-not $inst0.Reused)) "install fresca"
  $rd0 = Resolve-ReleaseDir -Root $resRoot -Version "v0.3.0"
  Assert-True (($rd0.Ok) -and (Test-Path -LiteralPath (Join-Path $rd0.Dir "server\pi-daemon.mjs"))) "resolve release valida"
  $rdTrav = Resolve-ReleaseDir -Root $resRoot -Version "v0.3.0" 
  Assert-True $rdTrav.Ok "resolve sanity"
  $instReuse = Install-ReleaseCandidate -StagingDir $payRes -ReleasesRoot $ppRes.Releases -Version "v0.3.0"
  Assert-True (($instReuse.Ok) -and $instReuse.Reused) "contenuto identico = reuse (G)"
  "DIVERSO" | Out-File -LiteralPath (Join-Path $payRes "shared\store.ts") -Encoding ascii -NoNewline
  $instDiff = Install-ReleaseCandidate -StagingDir $payRes -ReleasesRoot $ppRes.Releases -Version "v0.3.0"
  Assert-True ((-not $instDiff.Ok) -and ($instDiff.Error -match "diverso")) "contenuto diverso = fail closed (G)"
  Assert-True ((Get-Content -LiteralPath (Join-Path $ppRes.Releases "v0.3.0\shared\store.ts") -Raw) -ne "DIVERSO") "release installata intatta dopo rifiuto"
  $rdDot = Resolve-ReleaseDir -Root $resRoot -Version "v1.2.3-.."
  Assert-True (-not $rdDot.Ok) "suffix .. passa formato ma traversal rifiutato"
  $upRoot = Join-Path $TmpRoot "v3upd"
  $ppUp = New-V3Root $upRoot
  $pay30 = Join-Path $upRoot "pay30"
  $pay31 = Join-Path $upRoot "pay31"
  New-V3Payload $pay30 "v0.3.0"
  New-V3Payload $pay31 "v0.3.1"
  $i30 = Install-ReleaseCandidate -StagingDir $pay30 -ReleasesRoot $ppUp.Releases -Version "v0.3.0"
  Assert-True $i30.Ok "setup v0.3.0"
  $wPtr = Write-ActiveRelease -PointerPath $ppUp.ActivePointer -Version "v0.3.0"
  Assert-True $wPtr.Ok "setup pointer"
  $noop = Invoke-ReleaseUpdate -Paths $ppUp -TargetVersion "v0.3.0" -StagingDir $pay30
  Assert-True (($noop.Ok) -and ($noop.Action -eq "noop")) "stessa versione = noop"
  $hookOk = { param($p) return @{ Ok = $true; Detail = "ok (fake)" } }
  $healthOk = { param($p, $v) return @{ Ok = $true; Detail = ("healthy " + $v) } }
  $upA = Invoke-ReleaseUpdate -Paths $ppUp -TargetVersion "v0.3.1" -StagingDir $pay31 -StopRuntime $hookOk -StartRuntime $hookOk -VersionReader { param($p) return @{ Ok = $true; Version = "v0.3.1" } }
  Assert-True (($upA.Ok) -and ($upA.Action -eq "updated")) "update A: switch+verify (A)"
  Assert-Equal (Read-ActiveRelease -PointerPath $ppUp.ActivePointer).Version "v0.3.1" "pointer su v0.3.1 dopo A"
  Assert-True ((Test-Path -LiteralPath (Join-Path $ppUp.Releases "v0.3.0\server\pi-daemon.mjs")) -and (Test-Path -LiteralPath (Join-Path $ppUp.Releases "v0.3.1\server\pi-daemon.mjs"))) "entrambe le release intatte (no rename)"
  $healthKo = { param($p, $v) if ($v -eq "v0.3.2") { return @{ Ok = $false; Detail = "nuova rotta (fake)" } } return @{ Ok = $true; Detail = "ok" } }
  $pay32 = Join-Path $upRoot "pay32"
  New-V3Payload $pay32 "v0.3.2"
  $vrStale = { param($p) return @{ Ok = $true; Version = "v0.3.1" } }
  $upB = Invoke-ReleaseUpdate -Paths $ppUp -TargetVersion "v0.3.2" -StagingDir $pay32 -StopRuntime $hookOk -StartRuntime $hookOk -VersionReader $vrStale
  Assert-True ((-not $upB.Ok) -and ($upB.Action -eq "rolled_back")) "update B: health fail -> rollback (B)"
  Assert-Equal (Read-ActiveRelease -PointerPath $ppUp.ActivePointer).Version "v0.3.1" "pointer tornato su v0.3.1 dopo B"
  $histLines = @(Get-Content -LiteralPath $ppUp.UpdateHistory | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Assert-True ($histLines.Count -ge 3) "history append-only (>=3 voci)"
  $lastH = ($histLines[-1] | ConvertFrom-Json)
  Assert-True (([string]$lastH.result -eq "update_failed_rollback_healthy") -and ([bool]$lastH.rollback)) "history registra rollback"
  Assert-True ((Get-Content -LiteralPath (Join-Path $ppUp.Releases "v0.3.2\VERSION") -Raw) -eq "v0.3.2") "candidate fallita resta installata ma inattiva"
  $recRoot = Join-Path $TmpRoot "v3rec"
  $ppRec = New-V3Root $recRoot
  $payR0 = Join-Path $recRoot "payR0"
  $payR1 = Join-Path $recRoot "payR1"
  New-V3Payload $payR0 "v0.3.0"
  New-V3Payload $payR1 "v0.3.1"
  Install-ReleaseCandidate -StagingDir $payR0 -ReleasesRoot $ppRec.Releases -Version "v0.3.0" | Out-Null
  Install-ReleaseCandidate -StagingDir $payR1 -ReleasesRoot $ppRec.Releases -Version "v0.3.1" | Out-Null
  Write-ActiveRelease -PointerPath $ppRec.ActivePointer -Version "v0.3.0" | Out-Null
  function Set-RecState([string]$phase, [string]$ptrVer) {
    $s = @{ schemaVersion = 1; transactionId = "tx-test"; fromVersion = "v0.3.0"; toVersion = "v0.3.1"; phase = $phase; previousVersion = "v0.3.0"; startedAt = "t"; updatedAt = "" }
    Write-UpdateState -StatePath $ppRec.UpdateState -State $s | Out-Null
    Write-ActiveRelease -PointerPath $ppRec.ActivePointer -Version $ptrVer | Out-Null
  }
  $recHealth = { param($p, $v) return @{ Ok = $true; Detail = "ok" } }
  $recStart = { param($p) return @{ Ok = $true; Detail = "started" } }
  Set-RecState "candidate_installed" "v0.3.0"
  $rc1 = Invoke-UpdateRecovery -Paths $ppRec -StartRuntime $recStart -VerifyHealth $recHealth
  Assert-True (($rc1.Ok) -and ($rc1.Action -eq "old_verified_safe_to_resume")) "crash pre-switch (C): old attivo, ripristinabile"
  Assert-Equal (Read-ActiveRelease -PointerPath $ppRec.ActivePointer).Version "v0.3.0" "pointer intatto pre-switch"
  Set-RecState "runtime_stopped" "v0.3.0"
  $rc2 = Invoke-UpdateRecovery -Paths $ppRec -StartRuntime $recStart -VerifyHealth $recHealth
  Assert-True (($rc2.Ok) -and ($rc2.Action -eq "resumed_old_running")) "crash in stop: old riavviato"
  Set-RecState "pointer_switched" "v0.3.1"
  $rc3 = Invoke-UpdateRecovery -Paths $ppRec -StartRuntime $recStart -VerifyHealth $recHealth
  Assert-True (($rc3.Ok) -and ($rc3.Action -eq "switched_verified_completed")) "crash post-switch (D): nuova verificata"
  Set-RecState "health_verifying" "v0.3.1"
  $recKo = { param($p, $v) if ($v -eq "v0.3.1") { return @{ Ok = $false; Detail = "rotta" } } return @{ Ok = $true; Detail = "ok" } }
  $rc4 = Invoke-UpdateRecovery -Paths $ppRec -StartRuntime $recStart -VerifyHealth $recKo
  Assert-True (($rc4.Ok) -and ($rc4.Action -eq "rolled_back_healthy")) "crash in verify con nuova rotta: rollback"
  Assert-Equal (Read-ActiveRelease -PointerPath $ppRec.ActivePointer).Version "v0.3.0" "pointer rollback dopo crash"
  Set-RecState "rollback_started" "v0.3.0"
  $rc5 = Invoke-UpdateRecovery -Paths $ppRec -StartRuntime $recStart -VerifyHealth $recHealth
  Assert-True (($rc5.Ok) -and ($rc5.Action -eq "rolled_back_healthy")) "crash in rollback: rollback completato"
  Remove-Item -LiteralPath $ppRec.UpdateState -Force
  $rc6 = Invoke-UpdateRecovery -Paths $ppRec -StartRuntime $recStart -VerifyHealth $recHealth
  Assert-True (($rc6.Ok) -and ($rc6.Action -eq "nothing_to_do")) "senza state: nothing to do"
  $migRoot = Join-Path $TmpRoot "v3mig"
  $legApp = Join-Path $migRoot "psrv\app"
  New-Item -ItemType Directory -Path (Join-Path $legApp "server") -Force | Out-Null
  "x" | Out-File -LiteralPath (Join-Path $legApp "server\pi-daemon.mjs") -Encoding ascii -NoNewline
  "0.2.10" | Out-File -LiteralPath (Join-Path $legApp "VERSION") -Encoding ascii -NoNewline
  $legPaths = Get-PiServerPaths -Root (Join-Path $migRoot "psrv")
  $fakeNode = Join-Path $migRoot "node-fake.exe"
  "x" | Out-File -LiteralPath $fakeNode -Encoding ascii -NoNewline
  (@{ NodeExe = $fakeNode; PiBin = ""; NpmGlobalBin = ""; NodeArgs = @(); AgentDir = $legPaths.AgentDir } | ConvertTo-Json) | Out-File -LiteralPath (Join-Path $legApp "runtime-env.json") -Encoding ascii -NoNewline
  $legChk = Test-LegacyLayout -Paths $legPaths
  Assert-True (($legChk.Found) -and ($legChk.Version -eq "v0.2.10")) "legacy rilevato, VERSION normalizzata"
  $payMig = Join-Path $migRoot "payMig"
  New-V3Payload $payMig "v0.3.0"
  $taskActs = @{}
  $updater = { param($n, $p) $taskActs[$n] = $p; return @{ Ok = $true; Detail = "ok" } }
  $vrLive = { param($p) return @{ Ok = $true; Version = (Read-ActiveRelease -PointerPath $legPaths.ActivePointer).Version } }
  $mig = Invoke-LegacyMigration -Paths $legPaths -StagingDir $payMig -TargetVersion "v0.3.0" -StopRuntime $hookOk -StartRuntime $hookOk -VersionReader $vrLive -TaskActionUpdater $updater
  Assert-True (($mig.Ok) -and ($mig.Action -eq "migrated")) "migration copy-only felice"
  Assert-Equal (Read-ActiveRelease -PointerPath $legPaths.ActivePointer).Version "v0.3.0" "pointer su target dopo migration"
  Assert-True (Test-Path -LiteralPath (Join-Path $legPaths.Releases "v0.2.10\server\pi-daemon.mjs")) "snapshot legacy installato"
  Assert-True (Test-Path -LiteralPath (Join-Path $legPaths.Releases "v0.3.0\server\pi-daemon.mjs")) "target installato"
  Assert-True (Test-Path -LiteralPath (Join-Path $legApp "VERSION")) "legacy app intatta (H, mai rename)"
  Assert-Equal (Get-Content -LiteralPath (Join-Path $legApp "VERSION") -Raw) "0.2.10" "legacy VERSION intatta"
  Assert-True (($taskActs[$legPaths.TaskName] -eq $legPaths.BinRunPi) -and ($taskActs[$legPaths.RemoteTaskName] -eq $legPaths.BinRunRemote)) "task repointati su bin"
  Assert-True ((Read-MachineEnv -EnvPath $legPaths.MachineEnv).Ok) "machine env promossa in data"
  $migRoot2 = Join-Path $TmpRoot "v3migfail"
  $ppMig2 = New-V3Root $migRoot2
  $legApp2 = Join-Path $migRoot2 "psrv\app"
  New-Item -ItemType Directory -Path (Join-Path $legApp2 "server") -Force | Out-Null
  "x" | Out-File -LiteralPath (Join-Path $legApp2 "server\pi-daemon.mjs") -Encoding ascii -NoNewline
  "vCORROTTA!!!" | Out-File -LiteralPath (Join-Path $legApp2 "VERSION") -Encoding ascii -NoNewline
  $legPaths2 = Get-PiServerPaths -Root (Join-Path $migRoot2 "psrv")
  $migBad = Invoke-LegacyMigration -Paths $legPaths2 -StagingDir $payMig -TargetVersion "v0.3.0" -StopRuntime $hookOk -StartRuntime $hookOk
  Assert-True ((-not $migBad.Ok) -and ($migBad.Action -eq "rejected")) "VERSION legacy invalida: migration rifiutata, legacy intatto"
  $docRoot = Join-Path $TmpRoot "v3doc"
  $ppDoc = New-V3Root $docRoot
  $payDoc = Join-Path $docRoot "payDoc"
  New-V3Payload $payDoc "v0.3.0"
  Install-ReleaseCandidate -StagingDir $payDoc -ReleasesRoot $ppDoc.Releases -Version "v0.3.0" | Out-Null
  Write-ActiveRelease -PointerPath $ppDoc.ActivePointer -Version "v0.3.0" | Out-Null
  "{}" | Out-File -LiteralPath (Join-Path $ppDoc.AgentDir "settings.json") -Encoding ascii -NoNewline
  "x" | Out-File -LiteralPath (Join-Path $ppDoc.AgentDir "auth.json") -Encoding ascii -NoNewline
  New-Item -ItemType Directory -Path $ppDoc.SecretsDir -Force | Out-Null
  "0123456789abcdef" | Out-File -LiteralPath (Join-Path $ppDoc.SecretsDir "remote-hmac") -Encoding ascii -NoNewline
  $docNode = Join-Path $docRoot "node-fake.exe"
  "x" | Out-File -LiteralPath $docNode -Encoding ascii -NoNewline
  $wmeDoc = Write-MachineEnv -EnvPath $ppDoc.MachineEnv -Env @{ NodeExe = $docNode; PiBin = ""; NpmGlobalBin = ""; NodeArgs = @(); AgentDir = $ppDoc.AgentDir }
  Assert-True $wmeDoc.Ok "setup machine env doctor"
  $fakeTasks = { param($n) return @{ Exists = $true; State = "Running"; LastResult = 0; Detail = "Running/0" } }
  $fakeConn = { param($p) return @{ Listening = $false; Pid = 0; Name = ""; CommandLine = ""; Detail = "free" } }
  $fakeTs = { return @{ Ok = $true; Ip = "100.64.0.1"; Detail = "100.64.0.1" } }
  $doc1 = Invoke-ServerDoctor -Paths $ppDoc -TaskReader $fakeTasks -ConnectionReader $fakeConn -TailscaleReader $fakeTs -ProcessProbe { return @() }
  Assert-True (($doc1.Status -eq "degraded") -and ($doc1.ReportPath -eq $ppDoc.DoctorReport)) "doctor degraded (listener free) + report scritto"
  $rep = (Get-Content -LiteralPath $ppDoc.DoctorReport -Raw | ConvertFrom-Json)
  Assert-True (($rep.status -eq "degraded") -and ($rep.checks.Count -ge 12)) "report strutturato >=12 checks"
  $repRaw = Get-Content -LiteralPath $ppDoc.DoctorReport -Raw
  Assert-True (($repRaw -notmatch "0123456789abcdef") -and ($repRaw -notmatch "[Ss]ecret")) "report senza secrets"
  $global:upDocStarted = @()
  $starter = { param($n) $global:upDocStarted += $n; return @{ Ok = $true; Detail = "started" } }
  $deadTasks = { param($n) return @{ Exists = $false; State = ""; LastResult = 0; Detail = "assente" } }
  $rep1 = Invoke-DoctorRepair -Paths $ppDoc -Only @("tasks") -TaskReader $deadTasks -TaskStarter $starter -ConnectionReader $fakeConn -TailscaleReader $fakeTs -ProcessProbe { return @() }
  Assert-True ((($global:upDocStarted -contains $ppDoc.TaskName) -and ($global:upDocStarted -contains $ppDoc.RemoteTaskName))) "repair avvia task fermi (allowlist)"
  Remove-Variable -Name upDocStarted -Scope Global -ErrorAction SilentlyContinue
  Write-DoctorCircuit -CircuitPath $ppDoc.DoctorCircuit | Out-Null
  Write-DoctorCircuit -CircuitPath $ppDoc.DoctorCircuit | Out-Null
  Write-DoctorCircuit -CircuitPath $ppDoc.DoctorCircuit | Out-Null
  $cb = Test-DoctorCircuit -CircuitPath $ppDoc.DoctorCircuit
  Assert-True (-not $cb.Allowed) "circuit breaker scatta dopo 3 (max 3/10min)"
  $repBlocked = Invoke-DoctorRepair -Paths $ppDoc -TaskReader $deadTasks -TaskStarter $starter -ConnectionReader $fakeConn
  Assert-True ((-not $repBlocked.Ok) -and ($repBlocked.Detail -match "circuit breaker")) "repair rifiutata a circuito aperto"
  $v3Files = @((Join-Path $v3LibDir "PiServerUpdate.ps1"), (Join-Path $v3LibDir "PiServerDoctor.ps1"), (Join-Path $v3LibDir "bin\run-pi.ps1"), (Join-Path $v3LibDir "bin\run-remote.ps1"), (Join-Path $v3LibDir "bin\updater.ps1"), (Join-Path $v3LibDir "bin\doctor.ps1"))
  $moveViolations = @()
  $v3InBlock = $false
  foreach ($vf in $v3Files) {
    $ln = 0
    foreach ($line in (Get-Content -LiteralPath $vf)) {
      $ln++
      $scan = $line
      if (-not $v3InBlock) {
        if ($scan -match '<#') { $v3InBlock = $true; $scan = ($scan -split '<#', 2)[0]; if ($scan -match '#>') { $v3InBlock = $false } }
      } else {
        if ($scan -match '#>') { $v3InBlock = $false }
        continue
      }
      $code = ($scan -split '#')[0]
      if ($code -match "\bMove-Item\b|\bRename-Item\b|\bRemove-Item\b") {
        if (($code -match '\$Paths\.App|\$rd\.Dir|\$releaseDir|\$snapDest|\$dest\b|ReleasesRoot') -and ($code -notmatch "SilentlyContinue")) {
          $moveViolations += ((Split-Path -Leaf $vf) + ":" + $ln)
        }
      }
      if ($code -match "\?\?|\?\.") { $moveViolations += ((Split-Path -Leaf $vf) + ":" + $ln + " (operatore 5.1)") }
    }
  }
  Assert-True ($moveViolations.Count -eq 0) ("no live rename/remove + 5.1 ok (" + ($moveViolations -join ", ") + ")")
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
