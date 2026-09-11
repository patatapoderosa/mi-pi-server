<#
.SYNOPSIS
  Uninstall the PiServer 24/7 node from Windows.

.DESCRIPTION
  Usage (any PowerShell, admin rights NOT required — self-elevates):
    irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/uninstall.ps1 | iex

  Stops and removes the PiHomeServer scheduled task, then removes the
  installation. Asks whether to keep configuration + credentials
  (default YES). Never deletes secrets without confirmation. Leaves
  Node.js, Pi CLI and npm packages installed (shared toolchain).

  5.1 compatible.
#>
[CmdletBinding()]
param(
  [string]$InstallRoot = "C:\PiServer",
  [switch]$KeepData,
  [switch]$RemoveData,
  [switch]$Yes
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$TaskName = "PiHomeServer"

function U-Fail([string]$why) {
  Write-Host ""
  Write-Host "DISINSTALLAZIONE FALLITA" -ForegroundColor Red
  Write-Host "Motivo: $why"
  exit 1
}

$isAdmin = $false
try {
  $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pp = New-Object Security.Principal.WindowsPrincipal($ident)
  $isAdmin = $pp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if (-not $isAdmin) {
  $tmpDir = Join-Path $env:TEMP ("piserver-uninst-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
  $selfFile = Join-Path $tmpDir "uninstall.ps1"
  try {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/uninstall.ps1" `
      -OutFile $selfFile -TimeoutSec 120
  } catch {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    U-Fail "Download uninstall.ps1 fallito: $($_.Exception.Message)"
  }
  $eArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$selfFile`"",
    "-InstallRoot", "`"$InstallRoot`"")
  if ($KeepData) { $eArgs += "-KeepData" }
  if ($RemoveData) { $eArgs += "-RemoveData" }
  if ($Yes) { $eArgs += "-Yes" }
  try {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $eArgs -Verb RunAs -Wait -PassThru
    $code = $p.ExitCode
  } catch {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    U-Fail "Auto-elevation rifiutata o fallita: $($_.Exception.Message)"
  }
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  exit $code
}

try {
  if ($env:OS -ne "Windows_NT") { throw "Questo script gira solo su Windows." }

  Write-Host ""
  Write-Host "====================================" -ForegroundColor Cyan
  Write-Host "     PI HOME SERVER UNINSTALL" -ForegroundColor Cyan
  Write-Host "====================================" -ForegroundColor Cyan

  $task2 = Get-ScheduledTask -TaskName "PiRemoteServer" -ErrorAction SilentlyContinue
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($null -ne $task) {
    Write-Host "Fermo il task $TaskName..."
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Seconds 3
    # Kill leftover node processes running the daemon (best effort).
    try {
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "pi-daemon\.mjs" } |
        ForEach-Object {
          try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task rimosso." -ForegroundColor Green
  if ($null -ne $task2) {
    Write-Host "Fermo il task PiRemoteServer..."
    try { Stop-ScheduledTask -TaskName "PiRemoteServer" -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Seconds 3
    try {
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "pi-remote-server" } |
        ForEach-Object {
          try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
    Unregister-ScheduledTask -TaskName "PiRemoteServer" -Confirm:$false
    Write-Host "Task PiRemoteServer rimosso." -ForegroundColor Green
  } else {
    Write-Host "Task PiRemoteServer assente (niente da fermare)."
  }
  } else {
    Write-Host "Task $TaskName assente (niente da fermare)."
  }

  $keep = $false
  if ($RemoveData) {
    $keep = $false
  } elseif ($KeepData -or $Yes) {
    $keep = $true
  } else {
    $ans = Read-Host "Vuoi conservare configurazione e credenziali in $InstallRoot\data? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($ans) -or ($ans -match "^[YySs]")) { $keep = $true }
  }

  $dataDir = Join-Path $InstallRoot "data"
  if (Test-Path -LiteralPath $InstallRoot) {
    if ($keep) {
      foreach ($sub in @("app", "logs")) {
        $p = Join-Path $InstallRoot $sub
        if (Test-Path -LiteralPath $p) {
          Remove-Item -LiteralPath $p -Recurse -Force
          Write-Host "Rimosso: $p"
        }
      }
      # Remove stale app backups too (code, not user data).
      Get-ChildItem -LiteralPath $InstallRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "app.backup-*" } |
        ForEach-Object {
          Remove-Item -LiteralPath $_.FullName -Recurse -Force
          Write-Host "Rimosso backup: $($_.FullName)"
        }
      Write-Host "Conservato: $dataDir (config, secrets, extension)" -ForegroundColor Green
    } else {
      Write-Host "Rimozione completa di $InstallRoot ..." -ForegroundColor Yellow
      Remove-Item -LiteralPath $InstallRoot -Recurse -Force
      Write-Host "Rimosso: $InstallRoot" -ForegroundColor Green
    }
  } else {
    Write-Host "$InstallRoot assente (niente da rimuovere)."
  }

  Write-Host ""
  Write-Host "Node.js, Pi CLI e pacchetti npm sono stati lasciati installati (toolchain condivisa)." -ForegroundColor Cyan
  Write-Host "DISINSTALLAZIONE COMPLETATA" -ForegroundColor Green
  exit 0
} catch {
  U-Fail $_.Exception.Message
}
