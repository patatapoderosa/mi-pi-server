# ARCHITECTURE

## Components

### Old PC (server node)

- **Pi in RPC mode** (`pi --mode rpc`, the official headless mode: JSONL over
  stdio, no TTY). Supervised by **`server/pi-daemon.mjs`**, which logs frames
  compactly (`[pi-server]`), surfaces `extension_error` events, sends one
  idempotent `/telegram-connect` after startup (re-acquires pi-telegram polling
  ownership after reboot), forwards SIGTERM/SIGINT, and exits with Pi's code so
  the supervisor restarts it.
- **PM2** (Linux): apps `pi-server` and `pi-remote-server` from
  `server/ecosystem.config.cjs` (autorestart, restart delay, memory caps, dated
  logs under `<agent>/logs/`). On Windows: **Task Scheduler** tasks
  `PiHomeServer` and `PiRemoteServer` (at-startup, SYSTEM, restart-on-failure) —
  PM2 is deliberately not used there.
- **`@llblab/pi-telegram`** (ServerBot): owns the **single** `getUpdates`
  long-poll loop. Phone DMs arrive here. Nothing else polls Telegram.
- **`pi-remote-config`** (this repo): local tools `server_config`,
  `server_status`, `service_control`. No Telegram handler, no polling —
  the Mac never touches Telegram anymore.
- **`pi-remote-server`** (this repo, `server/pi-remote-server/`): standalone
  HTTP daemon for Mac remote control. Separate process on purpose: if Pi
  crashes, remote status/control keeps answering (fault isolation).

### Mac

- **Pi + `pi-remote`**: tools `remote_server_status` / `remote_server_config` /
  `remote_module_enable` / `remote_module_disable` with trigger descriptions
  and prompt guidelines, so the model calls them on natural-language requests.
  Each tool reads the HMAC from Keychain, signs the request
  (`X-Pi-Timestamp` / `X-Pi-Nonce` / `X-Pi-Signature`) and calls the daemon
  over plain HTTP inside the tailnet.

### Tailscale tailnet

- Private WireGuard mesh joining Mac + server. The daemon **binds only the
  tailnet IPv4** (validated `100.64.0.0/10`, never `0.0.0.0`): even with no
  firewall rule, LAN hosts cannot reach the socket. Windows adds a firewall
  rule scoped to the Tailscale interface as a second layer.
- No open ports, no public IPs, no webhooks, no VPS.

## Message flow (Mac → server)

1. User: "set the server interval to 30 minutes".
2. Mac Pi calls `remote_server_config({module:"example-monitor", settings:{intervalMinutes:30}})`.
3. Extension reads serverBaseUrl from `~/.pi/agent/remote-server.json` and the
   HMAC from Keychain, builds `PATCH /v1/modules/example-monitor/config` with
   `{patch:{intervalMinutes:30}}`, signs
   `METHOD\nPATH\nTS\nNONCE\nSHA256(raw body)` and sends it over the tailnet.
4. The daemon verifies: headers present+well-formed → signature
   (`timingSafeEqual`) → timestamp freshness → persisted nonce replay →
   route/module whitelist → field schema → applies (backup + atomic write) →
   replies `{ok:true, body:{...}}`.
5. The extension returns the result to the model, which answers in the user's
   language. Timeouts surface as tool errors (default 30 s), never as hangs.

Phone flow is direct: DM → ServerBot → Pi → `server_status`/`server_config`.

## HTTP API (`pi-remote-server`)

| Method + path | Auth | Effect |
| --- | --- | --- |
| `GET /v1/health` | none (supervisor liveness) | `{ok:true}` |
| `GET /v1/ping` | signed | `{pong:true}` |
| `GET /v1/status` | signed | hostname, app version, uptime, module list (no secrets) |
| `GET /v1/modules` | signed | `[{name, description, config, enabled}]` |
| `GET /v1/modules/:name/status` | signed | one module |
| `PATCH /v1/modules/:name/config` | signed | `{patch}` → validated atomic write + backup |
| `POST /v1/modules/:name/enable` | signed | flips `enabled` on |
| `POST /v1/modules/:name/disable` | signed | flips `enabled` off |

Auth (every `/v1/*` route except `/v1/health`), verification order:
headers → signature (constant-time) → freshness → persisted anti-replay →
route/schema. Bodies capped at 256 KiB; unknown routes → 404.

## Verified API facts (checked before building)

- **Tailscale CLI surface used**: `tailscale up [--auth-key=file:]`,
  `tailscale ip -4`, `tailscale status`, MagicDNS names. Install: `winget`
  (`Tailscale.Tailscale`, machine scope) or the official MSI
  (`TS_NOLAUNCH=1`); on Linux the official `install.sh`.
- **Node runs the daemon entry directly**: `server/pi-remote-server/index.ts`
  is TypeScript executed by Node type-stripping (native ≥22.18, probed
  `--experimental-strip-types` flag on older 22.x — probed once at install on
  Windows via `node --check`, probed at load on Linux in `ecosystem.config.cjs`).
  No build step, shared files imported relatively so the layout survives deploy.
- **Pi headless**: `pi --mode rpc` is the official headless/daemon mode
  (docs/rpc.md). Extension `prompt` commands (e.g. `/telegram-connect`) work
  over RPC, which the daemon uses for post-boot ownership acquire.
- **Extensions**: default-export factory `(pi: ExtensionAPI) => void`,
  `pi.registerTool({name,label,description,parameters(TypeBox),execute})`,
  `pi.on("session_start"|...)`, auto-discovery from
  `~/.pi/agent/extensions/*/index.ts`. Tools support `promptSnippet`,
  `promptGuidelines`, `executionMode: "sequential"`.
- **Node**: Pi and pi-telegram require Node ≥ 22.19 (setup installs Node 22).

## Data on disk (server)

- `<agent>/remote-server.json` — `{port, bindHost?, maxSkewSeconds, allowedServices}` (0600).
  `port` default 43128; `maxSkewSeconds` clamped 30–3600 (default 300).
- `<agent>/secrets/{server-bot-token,remote-hmac}` (0600, dir 0700).
- `<agent>/server-config/<module>.json` — one file per module, fixed names (0600).
- `<agent>/remote-state.json` — nonce window + last remote update/error (0600).
- `<agent>/telegram.json` — pi-telegram profile (ServerBot token, allowedUserId).
- Legacy `remote-auth.json` (ControlBot era) is migrated on daemon boot:
  HMAC-preserving, `{port,maxSkewSeconds,allowedServices}` carried over,
  dead Telegram fields dropped, original backed up to `*.bak-<ts>.migrated`.

### Windows one-click layout (`C:\PiServer`)

Same files, different root: `C:\PiServer\data` **is** the agent dir
(`PI_CODING_AGENT_DIR`, honored by Pi, pi-telegram and this daemon).
`C:\PiServer\app` holds versioned code + `runtime-env.json` (absolute
`node.exe`/`pi.cmd`/daemon paths plus probed `NodeArgs`, because SYSTEM
PATH is minimal and the npm global bin is user-scoped). `C:\PiServer\logs`
holds rotated `pi-server.log` / `remote-server.log` / `installer.log`.
The `PiHomeServer` + `PiRemoteServer` tasks run as SYSTEM (at-startup,
restart-on-failure, single instance, no time limit) via `app\run-task.ps1` /
`app\run-remote.ps1`, which set the env, prepend node+npm-global to PATH,
rotate logs and launch the processes in the foreground so the tasks stay
Running. Secrets ACL: SYSTEM+Administrators.
Pi provider credentials: the interactive `/login` runs as the installing user,
then `auth.json` is copied into the data dir (idempotent, backed up).

## Adding a new module (no protocol/auth/transport changes)

1. Append a `ModuleDefinition` (name, fixed `configFile`, defaults, field
   schema with min/max/enum) — see `shared/modules.ts` `BUILTIN_MODULES`.
2. Optionally pass `onConfigApplied` (reload work) and `getStatus` (extra rows)
   via `registerRemoteModule()` from an in-process companion extension.
3. Add defaults in both setup scripts; the Mac model learns the module from the
   `remote_server_status` reply (module list is dynamic).

Rules: fixed file name (regex, no slashes), ≤25 patch keys, unknown fields
rejected, service names allowlisted separately. Never add filePath/command
fields — the validator rejects them by construction (not in any schema).
