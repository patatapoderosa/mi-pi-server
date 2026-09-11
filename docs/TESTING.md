# TESTING

## Unit tests (no deps, no network)

```bash
npm install   # once: typescript, @types/node, typebox, pi types
npm test      # node --test "tests/*.test.ts"  →  61 tests
npm run typecheck  # tsc --noEmit
```

Real coverage (no fakes):

| Area | Cases |
| --- | --- |
| HMAC auth | valid signature, wrong secret, tampered body/path/method, malformed headers (`missing_auth`, `bad_ts`, `bad_nonce`, `bad_signature_shape`), canonical-base byte-exactness |
| Freshness | expired (`ts_expired`), future (`ts_future`), at the skew boundary, non-integer/negative timestamps |
| Replay store | duplicates, restart persistence (file re-read), expiry + prune, last update/error, corrupt-file fallback, fail-closed add |
| Atomicity | valid write, no leftover tmp, overwrite, backup, corrupt-file fallback |
| Modules | valid patch + merge, unknown fields (`filePath`, `shellCommand`, `command`, `script`…), wrong types, ranges, empty/huge/non-object patches, traversal filenames rejected, enable/disable flips |
| Daemon HTTP | live server on `127.0.0.1:0`: health/ping/status/modules/config/enable/disable round-trips, 401 on bad signature/stale ts/replay, 404 on unknown routes, 256 KiB body cap |
| Tailscale helpers | CGNAT range validation (100.64–127.x), garbage rejection, bind resolution (override / tailnet / loopback-fallback + warning) |
| Migration | legacy `remote-auth.json` → `remote-server.json`: HMAC preserved, dead Telegram fields dropped, `*.bak-<ts>.migrated` backup, missing/corrupt legacy handled |

## Windows installer smoke tests (no Pester, no Windows required)

```powershell
pwsh -NoProfile -File installer/tests/Invoke-SmokeTests.ps1
# or: npm run test:windows
```

43 self-contained tests covering the pure installer library: admin detection
shape, Node version comparison, directory layout (incl. `RemoteEntry`,
`RunRemote`, `RemoteTaskName`, `RemotePortDefault`), checksum validation
(good/bad/missing/empty), manifest validation (complete/incomplete, incl. the
new daemon files), idempotent config preservation on `remote-server.json`
(created/kept/merged + backup on overwrite), fast-failing download errors,
never-throwing health check, fail-closed `Test-RemoteDaemon` probe
(no HMAC / daemon down / null paths — never throws), no-secrets-in-logs,
and a static scan for PowerShell 7-only operators (the installer must stay
5.1-compatible; `run-remote.ps1` included). Windows-only parts (Task Scheduler
settings) are skipped with a count outside Windows — never fake-passed.

## Live checklist (needs the real machines, once)

1. `getMe` for the ServerBot (done by the setup scripts).
2. Tailscale: `tailscale status` connected on both sides, `tailscale ip -4`
   on the server prints a `100.x` address.
3. Mac → server: `remote_server_status` → signed reply with hostname, version,
   module list.
4. Mac → server: valid `remote_server_config` → confirmation + backup created
   in `server-config/`.
5. Mac → server: config with unknown field → `invalid_patch`, file untouched.
6. Replay: call twice with the same nonce (or redeliver) → `replay`, ignored.
7. Broken signature / missing headers (curl without headers) → `401`,
   nothing applied.
8. Reboot server → `pi-server` AND `pi-remote-server` online with no login;
   automatic `/telegram-connect` (look for `[pi-server]` in PM2 / Task
   Scheduler logs).
9. Phone → ServerBot DM: `server status`, `disable example-monitor`
   (Italian equivalents work too).

## Known limits of automated tests

- The tailnet path cannot be simulated without two real Tailscale nodes (no
  fake coordination server): cases 2–7 above are a manual checklist. The daemon
  tests bind loopback (`PI_REMOTE_BIND=127.0.0.1` equivalent) instead.
- `pi-daemon.mjs` + `ecosystem.config.cjs` are verified on the server
  (`pm2 logs pi-server`, `pm2 describe pi-server`) — not in CI.
- Extensions are typechecked (`tsc`), but real jiti loading is tested with
  `pi` + `/reload` and the `session_start` notify.
