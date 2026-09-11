# SECURITY

## Threat model

We defend against: forged Telegram messages in the control group, replays of
legitimate messages, model mistakes (invented fields), corrupt config files,
phone/machine theft, network/process crashes.

We do NOT defend against: compromised Telegram PIN + physical access to both
machines + unlocked Keychain (at that point the attacker already is the user).

## Protocol checks (server, in order)

Every message with the `PI_REMOTE_V1` prefix is **consumed** in all cases
(never reaches the model). Before executing:

1. `from.id === allowedControlBotId` (silent toward strangers: no confirmation).
2. (if configured) `chat.id === controlChatId`.
3. HMAC-SHA256 over canonical JSON (sorted keys) with `crypto.timingSafeEqual`.
4. `|now - ts| ≤ maxSkewSeconds` (default 300, clamped 30–3600).
5. Persisted nonce (`remote-state.json`, 2×skew window, prune, max 500):
   duplicate → `replay`, even across restarts.
6. `op ∈ {set_config, get_status, ping, service}`.
7. Registered `module` (`core`, `example-monitor`, …) with the master switches
   `core.remoteControlEnabled` / `maintenanceMode` honored.
8. `patch`: object with ≤25 keys, only fields declared in the module schema,
   type/range/enum validated; merged over defaults + known current values.
9. `service ∈ allowedServices` (names only, never commands) for `service/*`.
10. Atomic writes (tmp+rename) + timestamped backup before overwriting.

`PI_REMOTE_RESP_V1` replies are signed with the same HMAC and correlated via
`requestId`; the Mac verifies them before displaying.

## Secrets & permissions

- Server (Linux): `secrets/` 0700, files 0600. Tokens/HMAC never in logs (the
  code has no logging statement that includes them; Telegram HTTP errors report
  only status/description).
- Server (Windows): secrets ACL restricted to SYSTEM+Administrators; same
  no-secrets-in-logs rule (`installer.log` never contains token/HMAC values —
  the generated HMAC is shown once on screen with the transcript suspended).
- Mac: ControlBot token + HMAC only in the Keychain (`security`
  `find-generic-password`); `remote-server.json` holds routing only.
- `telegram.json` holds the ServerBot token: fine at 0600, but at runtime
  `secrets/server-bot-token` wins when present.

## What does NOT exist (by design)

- No `run_command`/`exec`/`terminal` tool, local or remote.
- No `filePath`/`shellCommand`/`processName`/`command`/`script` field in any
  message: the validator rejects every off-schema key.
- No open ports, no webhooks, no VPS: everything goes out over HTTPS to
  `api.telegram.org`; nothing accepts inbound connections.
- No second `getUpdates` loop on the ServerBot (Telegram returns 409 conflict
  if two pollers insist on the same bot). The Mac short-polls only the
  ControlBot, with tools in `sequential` mode so they never overlap.

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
- No inbound firewall rules, no port forwarding: Telegram stays the transport.
- `installer.log` never contains secrets (tokens/HMAC only in ACL'd files or
  shown once on screen with the transcript suspended).

## Known residuals / future hardening

- The control group is visible to its members: payloads are signed but not
  encrypted (a malicious member cannot forge, only read the ops). For future
  sensitive ops, consider payload encryption (same HMAC as KDF).
- 32-byte hex HMAC generated with `randomBytes`: manual rotation (change it on
  server + Keychain). No key versioning (protocol `v:1` ready).
- Rate limiting: none beyond natural long-polling; a correctly signed flood is
  only possible with stolen HMAC+token (rotate them at that point).
