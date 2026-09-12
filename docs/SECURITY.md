# SECURITY

## Threat model

We defend against: forged HTTP requests on the tailnet, replays of
legitimate requests, model mistakes (invented fields), corrupt config files,
phone/machine theft, network/process crashes.

We do NOT defend against: compromised Tailscale tailnet + stolen HMAC
(at that point rotate the HMAC on server + Keychain), or physical access to
both machines + unlocked Keychain (at that point the attacker already is
the user).

## Protocol checks (daemon, in order)

Every `/v1/*` request except `/v1/health` must carry `X-Pi-Timestamp` /
`X-Pi-Nonce` / `X-Pi-Signature`. Before executing anything:

1. Headers present + well-formed (`missing_auth`): timestamp = unix seconds
   (≤10 digits), nonce 8–128 chars of `[A-Za-z0-9_.-]` (`bad_nonce`),
   signature = 64 hex chars (`bad_signature_shape`).
2. HMAC-SHA256 over `METHOD\nPATH\nTS\nNONCE\nSHA256(raw body)` with
   `crypto.timingSafeEqual` (`bad_signature`). PATH is the pathname only,
   body is the exact raw bytes (empty string hashed when bodiless).
3. `|now - ts| ≤ maxSkewSeconds` (default 300, clamped 30–3600):
   `ts_expired` / `ts_future`.
4. Persisted nonce (`remote-state.json`, 2×skew window, prune, max 500):
   duplicate → `replay`, even across restarts. A nonce that cannot be
   persisted is refused (`replay_store`) — fail closed, never fail open.
5. Route + registered `module` (`core`, `example-monitor`, …) with the master
   switches `core.remoteControlEnabled` / `maintenanceMode` honored.
6. `patch`: object with ≤25 keys, only fields declared in the module schema,
   type/range/enum validated; merged over defaults + known current values.
   Bodies over 256 KiB are refused before parsing.
7. Atomic writes (tmp+rename) + timestamped backup before overwriting.

Failures return `401` (auth) or `400/404` (route/schema) with a short error
code and no state change. The Mac surfaces them as tool errors.

## Secrets & permissions

- Server (Linux): `secrets/` 0700, files 0600. HMAC never in logs
  (no logging statement includes it; HTTP errors report only status/error).
- Server (Windows): secrets ACL restricted to SYSTEM+Administrators; same
  no-secrets-in-logs rule (`installer.log` never contains token/HMAC values —
  the generated HMAC is shown once on screen with the transcript suspended).
- Mac: HMAC only in the Keychain (`security find-generic-password`);
  `remote-server.json` holds routing (URL + Keychain pointers) only.
- `telegram.json` holds the ServerBot token: fine at 0600, but at runtime
  `secrets/server-bot-token` wins when present.
- Tailscale auth keys (`-TailscaleAuthKey` / `PI_TAILSCALE_AUTHKEY`) are passed
  via file (`--auth-key=file:`) or env, never logged; `setup.ps1` accepts the
  key only when already elevated — it is never forwarded through the
  auto-elevation relaunch.

## What does NOT exist (by design)

- No `run_command`/`exec`/`terminal` tool, local or remote.
- No `filePath`/`shellCommand`/`processName`/`command`/`script` field in any
  request: the validator rejects every off-schema key.
- No second Telegram bot, no control group: the Mac never touches Telegram.
- No open ports, no webhooks, no VPS, no public IPs: Mac→server traffic stays
  inside the WireGuard-encrypted tailnet; the daemon binds the tailnet IPv4
  only (never `0.0.0.0`), and the Windows firewall allows the port on the
  Tailscale interface only.
- No second `getUpdates` loop on the ServerBot (Telegram returns 409 conflict
  if two pollers insist on the same bot). Only pi-telegram polls, only the
  ServerBot.
- `service_control` restarts explicitly allowlisted PM2 services by name only
  (`allowedServices` in `remote-server.json`): no commands, paths, or scripts
  can pass through it.

- `server_model` runs only fixed Pi CLI commands (`--list-models`,
  `auth check --provider <allowlisted-id> --json --no-refresh` where the
  provider comes from Pi's own catalog, never raw client input) and reads
  / writes exactly one fixed path (`<agentDir>/settings.json`, never
  `~/.pi`). Responses carry catalog metadata + booleans only — no tokens,
  keys, auth.json content, or environment secrets. Writes are backup +
  atomic rename; corrupt settings files are refused, never overwritten.
## Supply chain (Windows installer)

- Honest trust root: `setup.ps1` is downloaded over HTTPS from
  `raw.githubusercontent.com` and is NOT checksum-verified (nothing verifies
  the verifier). Everything it executes afterwards — `mi-pi-server-windows.zip` —
  is SHA256-verified against the release `SHA256SUMS.txt` (or `-ExpectedSha256`)
  with fail-closed behavior: different or missing hash = stop, nothing runs.
- The checksum protects against transit corruption/tampering and wrong assets,
  it is NOT a signature: whoever controls the GitHub repo or TLS can still
  ship a malicious payload. For sensitive installs: download a tagged
  `setup.ps1`, read it, and pin `-ExpectedSha256`. Protect the GitHub account
  with 2FA and branch protection on `main`.
- The installer also validates the manifest (expected files present) after extraction.
- Tailscale itself is installed from its official sources (winget package
  `Tailscale.Tailscale` or `pkgs.tailscale.com` MSI): same trust reasoning as
  Node.js (winget/NodeSource) and Pi (npm) — documented, not verified by us.
- `installer.log` never contains secrets (tokens/HMAC only in ACL'd files or
  shown once on screen with the transcript suspended).

## Known residuals / future hardening

- Tailnet members can reach the daemon port: payloads are signed but the
  channel relies on Tailscale's WireGuard encryption + HMAC auth (a tailnet
  intruder without the HMAC gets only `401`s). Keep the tailnet membership
  minimal; rotate the HMAC if the tailnet is ever compromised.
- 32-byte hex HMAC generated with `randomBytes`: manual rotation (change it on
  server + Keychain). No key versioning (protocol `v:1` ready).
- Rate limiting: none beyond supervisor restarts; a correctly signed flood is
  only possible with stolen HMAC (rotate it at that point).
- `/v1/health` is unauthenticated by design (supervisor liveness): it reveals
  only `{ok:true}`, no config, no version, no host identity.
