# TESTING

## Unit tests (no deps, no network)

```bash
npm install   # once: typescript, @types/node, typebox, pi types
npm test      # node --test "tests/*.test.ts"  → 32 tests
npm run typecheck  # tsc --noEmit
```

Real coverage (no fakes):

| Area | Cases |
| --- | --- |
| Signature | valid, wrong, wrong secret, byte-exact tampered payload |
| Freshness | expired (`ts_expired`), future (`ts_future`), at the skew boundary |
| Shape | malformed prefixes/shapes, non-object payload, invalid op (`run_command` rejected) |
| Responses | `requestId` correlation, same-HMAC verification, other-secret rejection |
| Replay store | duplicates, restart persistence (file re-read), expiry + prune, last update/error |
| Atomicity | valid write, no leftover tmp, overwrite, backup, corrupt-file fallback |
| Modules | valid patch + merge, unknown fields (`filePath`, `shellCommand`, `command`, `script`…), wrong types, ranges, empty/huge/non-object patches, traversal filenames rejected |

## Windows installer smoke tests (no Pester, no Windows required)

```powershell
pwsh -NoProfile -File installer/tests/Invoke-SmokeTests.ps1
# or: npm run test:windows
```

35 self-contained tests covering the pure installer library: admin detection
shape, Node version comparison, directory layout, checksum validation
(good/bad/missing/empty), manifest validation (complete/incomplete),
idempotent config preservation (created/kept/merged + backup on overwrite),
fast-failing download errors, never-throwing health check, no-secrets-in-logs,
and a static scan for PowerShell 7-only operators (the installer must stay
5.1-compatible). Windows-only parts (Task Scheduler settings) are skipped
with a count outside Windows — never fake-passed.

## Live checklist (needs real Telegram, once)

1. `getMe` for both bots (done by the setup scripts).
2. Mac → server: `remote_server_status` → signed reply < 90s.
3. Mac → server: valid `set_config` → `✅` confirmation + backup created in `server-config/`.
4. Mac → server: `set_config` with unknown field → `invalid_patch`, file untouched.
5. Replay: re-send the same message (copy it from the group) → `replay`, ignored.
6. Broken-signature prefix → consumed, never reaches the model, `rejected` in `remote-state.json`.
7. Reboot server → `pi-server` online with no login; automatic `/telegram-connect`
   (look for `[pi-server]` in PM2 / Task Scheduler logs).
8. Phone → ServerBot DM: `server status`, `disable example-monitor`,
   `which services are running` (Italian equivalents work too).

## Known limits of automated tests

- The end-to-end Telegram flow cannot be simulated without real bots (no fake
  Bot API mocks): the cases above are a manual checklist.
- `pi-daemon.mjs` + `ecosystem.config.cjs` are verified on the server
  (`pm2 logs pi-server`, `pm2 describe pi-server`) — not in CI.
- Extensions are typechecked (`tsc`), but real jiti loading is tested with
  `pi` + `/reload` and the `session_start` notify.
