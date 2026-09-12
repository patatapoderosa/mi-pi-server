# Changelog

## v0.2.4 — 2026-09-12

### Fixed

- Fixed PowerShell 5.1 parse failure in `server/setup-old-pc.ps1`: the file is
  UTF-8 without BOM and had em-dashes (U+2014) inside three double-quoted
  strings. On 5.1 the file is decoded as ANSI, so byte `0x94` becomes U+201D
  (right double quote) and the tokenizer closes the string early — cascading
  into terminator/brace/argument errors. The three strings now use ASCII
  `--` (pwsh 7 was unaffected: it defaults to UTF-8).
- Fixed Windows smoke tests on Server SKUs (e.g. Windows Server 2025 CI):
  `TaskSettings` has no battery properties there, and strict mode threw
  `PropertyNotFound` on the `battery-proof` assertion. The assertion now
  runs only when the property exists, otherwise SKIP.

### Upgrade notes

- No migration needed: rerun the one-liner (resolves `latest` → v0.2.4).

## v0.2.3 — 2026-09-12

### Fixed

- Fixed Pi-login loop on Windows: step 8/11 kept asking for `/login` even
  after a successful login. Two root causes: (1) the verifier ran bare
  `pi auth check`, which always fails on pi 0.85.1 (it requires
  `--provider`/`--model`); (2) auth lived in `%USERPROFILE%\.pi\agent`
  while the server reads `C:\PiServer\data` (`PI_CODING_AGENT_DIR`).
- New `Test-PiAuthentication` verifier uses the official contract
  (`auth.json` in `getAgentDir()`, `auth check --provider <id> --json
  --no-refresh`, exit 0 = ready): login is recognized once, resume skips
  step 8 automatically.
- Interactive `/login` now runs with `PI_CODING_AGENT_DIR=C:\PiServer\data`
  scoped to that process only (saved/restored, never left behind).
- Safe migration of an existing user login: offered only when the user
  auth verifies, copies ONLY `auth.json` (atomic tmp+rename, original
  preserved, existing server file backed up), locks it to
  SYSTEM+Administrators, re-verifies afterwards. No blind full-profile copy.
- Failure menu with diagnostics (exe paths, both agent dirs, found/not
  found, reason — never secrets): [L]ogin / [M]igrate / [R]etry / [E]xit
  with checkpoint. No infinite loop.
- Added ~35 smoke assertions (verifier matrix, env restore, user/server
  confusion, menu, atomic migration, ACL shape, resume verifier).

### Upgrade notes

- No migration needed: rerun the one-liner (resolves `latest` → v0.2.3).
  A login done in the user profile is offered for migration; a login already
  in the server dir is recognized immediately.


## v0.2.2 — 2026-09-11

### Fixed

- Fixed false Telegram error on Windows: the installer showed
  "ServerBot token non valido o rete assente" even for valid tokens.
  Token validation now uses `Test-TelegramBotToken` (with
  `-UseBasicParsing`, no IE engine on PS 5.1) which classifies the real
  cause: 401/403 invalid vs DNS vs timeout vs TLS vs connection vs 5xx.
  The misleading message is gone; each case gets accurate guidance.
- Token is now validated with `getMe` BEFORE saving: existing valid tokens
  are preserved, network failures never overwrite good config, and
  `telegram.json` is written atomically only after verification.
- User input errors no longer kill the setup: port/owner/HMAC/token/yes-no
  prompts reprompt in a loop (`Read-Validated*` helpers) instead of
  `SETUP FALLITO / exit 1`.
- Added error taxonomy (UserInput / Transient / System / Fatal): transient
  errors auto-retry 2s/4s/8s then offer [R]etry/[S]kip/[D]etails/[E]xit;
  system errors show the same menu; fatal (integrity) errors save a
  checkpoint and exit with resume instructions. Exit-with-checkpoint uses
  exit code 2 (0 = ok, 1 = failed).
- Added crash-safe resume: atomic `C:\PiServer\data\install-state.json`
  checkpoint (tmp+rename, secrets never stored, corrupt file backed up),
  per-step real-state verification (machine is source of truth), resume UX
  listing already-OK steps, `-Force` / `-FromStep` flags, and bootstrap
  download skip when the release is already deployed+verified.
- Added ~90 smoke assertions (telegram taxonomy, validators, prompt loops,
  retry/taxonomy/menu, checkpoint, log redaction, real-state verifiers).

### Upgrade notes

- No migration needed: rerun the one-liner (resolves `latest` → v0.2.2).
  Interrupted installs resume automatically from the failed step.
  `-Update` keeps working (deploy always re-runs in update mode).


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
