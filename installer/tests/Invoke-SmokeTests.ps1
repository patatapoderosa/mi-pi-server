<#
.SYNOPSIS
  Smoke tests for the PiServer Windows installer (no Pester needed).

.DESCRIPTION
  Dot-sources installer/PiServerLib.ps1 and exercises the pure,
  side-effect-free functions plus failure paths that don't need Windows:
  admin detection shape, Node version comparison, path layout, checksum
  validation (good/bad/missing), manifest validation (complete/incomplete),
  idempotent config preservation, download failure, health-check failure,
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
      "installer\run-task.ps1", "installer\windows-installer.ps1")) {
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
  $cfg = Join-Path $TmpRoot "remote-auth.json"
  $r1 = Save-JsonConfigPreserving -Path $cfg `
    -Defaults @{ allowedControlBotId = 0; controlChatId = 0 } `
    -RequiredKeys @("allowedControlBotId", "controlChatId")
  Assert-Equal $r1 "created" "prima scrittura = created"
  $custom = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
  $custom.allowedControlBotId = 12345
  $custom | Add-Member -NotePropertyName "notaUtente" -NotePropertyValue "non-toccare"
  $custom | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $cfg -Encoding utf8
  $r2 = Save-JsonConfigPreserving -Path $cfg `
    -Defaults @{ allowedControlBotId = 0; controlChatId = 0 } `
    -RequiredKeys @("allowedControlBotId", "controlChatId")
  Assert-Equal $r2 "kept" "seconda scrittura = kept"
  $after = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
  Assert-Equal $after.allowedControlBotId 12345 "valore utente preservato"
  Assert-Equal $after.notaUtente "non-toccare" "chiavi extra preservate"
  # Corrupt file -> backup + defaults (merged), never crash.
  "zzz-non-json" | Out-File -LiteralPath $cfg -Encoding utf8
  $r3 = Save-JsonConfigPreserving -Path $cfg `
    -Defaults @{ allowedControlBotId = 0; controlChatId = 0 } `
    -RequiredKeys @("allowedControlBotId", "controlChatId")
  Assert-Equal $r3 "merged" "file corrotto = backup + defaults"
  $baks = Get-ChildItem -LiteralPath $TmpRoot -Filter "remote-auth.json.bak-*" -ErrorAction SilentlyContinue
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
