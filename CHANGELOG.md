# Changelog

## v0.2.1 — 2026-09-11

### Fixed

- Fixed SHA256SUMS parsing on Windows PowerShell 5.1: the bootstrap and
  the installer downloaded the file but parsed the in-memory
  `Invoke-WebRequest` `.Content` (IE-engine dependent, silently empty).
  Both now download `SHA256SUMS.txt` with `-OutFile` and run it through
  a single strict parser (`Get-ReleaseChecksum`, mirrored byte-identical
  in `setup.ps1` and `installer/PiServerLib.ps1`): file must exist and be
  non-empty, BOM stripped, CRLF normalized, exact 64-hex hash for the exact
  asset name (`HASH[ ][*]mi-pi-server-windows.zip`), conflicting duplicates
  fail closed, useful diagnostics (tag, asset names, URL, file size).
- Fixed Windows staging deployment failing with
  "Cannot copy container onto existing leaf item": stage subdirectories
  (`server/`, `shared/`, `installer/`) are now created before the wildcard
  `Copy-Item`. Staging lives in `Invoke-AppStaging` (lib):
  payload → stage → in-stage manifest validation → swap (backup in update
  mode), best-effort backup restore if the swap itself fails, failed stages
  always removed, live app untouched.
- Added regression tests for Windows checksum parsing and staged deploy
  (34 new smoke assertions) and a Windows PowerShell 5.1 CI job
  (`powershell.exe` parser + smoke tests on `windows-latest`).

### Upgrade notes

- No migration needed: rerun the one-liner (it resolves `latest` → v0.2.1)
  or `setup.ps1 -Update`. Pinned installs keep working:
  `setup.ps1 -Version v0.2.1 -ExpectedSha256 <hash>`.


## v0.2.0 — 2026-09-11

### Major changes

- Replaced the Telegram Mac→server transport with signed HTTP over Tailscale.
- Removed the ControlBot requirement: only one Telegram ServerBot is needed.
- Added a dedicated `pi-remote-server` daemon (standalone process, fault-isolated
  from Pi): `GET /v1/health|ping|status|modules`, `PATCH /v1/modules/:name/config`,
  `POST /v1/modules/:name/enable|disable`. No shell, no paths, no commands.
- Added Tailscale setup/integration (install + tailnet login on Windows, Linux,
  Mac; daemon binds the tailnet IPv4 only; Windows firewall rule scoped to the
  Tailscale interface).
- HMAC-SHA256 request auth (`X-Pi-Timestamp` / `X-Pi-Nonce` / `X-Pi-Signature`
  over `METHOD PATH TS NONCE SHA256(body)`) with clock-skew and persisted
  anti-replay checks, fail-closed on storage errors.
- Updated the Windows installer (11 steps, two `Task Scheduler` tasks,
  `run-remote.ps1` launcher, probed Node type-stripping flags, daemon ping probe
  in the health check) and the Mac setup (Keychain HMAC, live signed test,
  legacy token cleanup).
- Fixed Linux PM2 startup: `server/ecosystem.config.cjs` previously declared
  only `pi-server` while setup attempted to launch `pi-remote-server`; it now
  declares both apps.
- Legacy migration: a `remote-auth.json` from the ControlBot era is converted
  on daemon boot (HMAC preserved, dead Telegram fields dropped, original backed
  up to `*.bak-<ts>.migrated`).
- Rewrote documentation (ARCHITECTURE / INSTALL / SECURITY / TESTING) and added
  29 Node tests + 8 Windows smoke tests for the new transport.

### Fixes

- Linux PM2 config previously declared only `pi-server` while setup attempted
  to launch `pi-remote-server` (`--only pi-remote-server` failed). Both apps are
  now declared and started.
- `ReplayStore.has()` now explicitly rejects invalid input fail-closed
  (treated as already seen) instead of relying only on the surrounding guard.

### Upgrade notes (breaking for existing installs)

- Mac setups from v0.1.0 stop working: re-run `mac/setup-mac.sh` (it removes the
  dead ControlBot Keychain entry) with the server tailnet name and the same HMAC.
- The server migrates automatically on daemon boot (backup kept); no manual
  config edit needed. After upgrading, verify with the signed `/v1/status` test
  in `mac/setup-mac.sh` step 6/7 and the reboot test in `docs/INSTALL.md` §5.
- Port `43128` must be reachable Mac→server inside the tailnet (default;
  configurable via `remote-server.json`).

## v0.1.0 — 2026-09-10

- Initial release: 24/7 Pi node on an old PC (Windows one-command installer,
  Linux setup), phone control via Telegram ServerBot, Mac control via
  ControlBot + private group transport, HMAC-signed remote ops.
