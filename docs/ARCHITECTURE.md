# ARCHITECTURE

## Components

### Old PC (server node)

- **Pi in RPC mode** (`pi --mode rpc`, the official headless mode: JSONL over
  stdio, no TTY). Supervised by **`server/pi-daemon.mjs`**, which logs frames
  compactly (`[pi-server]`), surfaces `extension_error` events, sends one
  idempotent `/telegram-connect` after startup (re-acquires pi-telegram polling
  ownership after reboot), forwards SIGTERM/SIGINT, and exits with Pi's code so
  the supervisor restarts it.
- **PM2** (Linux): app `pi-server` from `server/ecosystem.config.cjs`
  (autorestart, restart delay, memory cap, dated logs under
  `~/.pi/agent/logs/`). On Windows: **Task Scheduler** task `PiServer`
  (at-startup, SYSTEM, restart-on-failure) — PM2 is deliberately not used there.
- **`@llblab/pi-telegram`** (ServerBot): owns the **single** `getUpdates`
  long-poll loop. Phone DMs arrive here; so do the signed remote messages from
  the control group.
- **`pi-remote-config`** (this repo): (A) local tools `server_config`,
  `server_status`, `service_control`; (B) a Telegram update handler that
  verifies + applies remote ops and replies in the control group.

### Mac

- **Pi + `pi-remote`**: tools `remote_server_config` / `remote_server_status`
  with Italian+English trigger descriptions and prompt guidelines, so the model
  calls them on natural-language requests. Sends via ControlBot token (HTTPS),
  waits for the correlated signed reply (short-lived poll, `sequential`
  execution mode to avoid two concurrent polls).

### Telegram

- **ServerBot**: phone operator surface + remote-op receiver.
- **ControlBot**: send-only identity for the Mac.
- **Private control group** (ServerBot + ControlBot + owner, both bots admin).

## Message flow (Mac → server)

1. User: "cambia l'intervallo sul server a 30 minuti".
2. Mac Pi calls `remote_server_config({module:"example-monitor", settings:{intervalMinutes:30}})`.
3. Extension reads token+HMAC from Keychain, builds
   `PI_REMOTE_V1 <b64url>.<hmac>`, `sendMessage` to the control group.
4. ServerBot's `getUpdates` (pi-telegram) delivers the update; our handler
   (registered via the public v1 registry) verifies: sender id → optional chat
   check → HMAC (`timingSafeEqual`) → timestamp/skew → persisted nonce replay
   → op/module whitelist → field schema → applies (backup + atomic write) →
   replies `PI_REMOTE_RESP_V1 <...>` (same requestId) → returns `"consume"`.
5. Mac correlates `requestId`, verifies the reply signature, returns the result
   to the model, which answers in the user's language.

Phone flow is direct: DM → ServerBot → Pi → `server_status`/`server_config`.

## Verified API facts (checked before building)

- **pi-telegram companion API**: `registerTelegramUpdateHandler` from
  `@llblab/pi-telegram/updates`, or the zero-coupling
  `globalThis.__piTelegramUpdateHandlerRegistry__` v1 contract
  (`{version:1, add, dispatch}`). We use the **zero-coupling** form so load
  order never matters. Verdicts: `"consume"` skips default routing.
  Source: pi-telegram `docs/updates.md` + `docs/public-api.md` (v0.45.4).
- **There is no `pi.on("telegram:update")`.** The prompt's guess was wrong;
  we did not invent it — the registry above is the real API.
- **Bot-to-bot**: Telegram historically blocked all bot↔bot traffic. Since Bot
  API 10.0 (May 2026) bots can exchange messages **only in groups/business
  chats and only after each bot enables bot-to-bot mode in @BotFather**.
  Direct bot DMs remain impossible — hence the private control group design.
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

- `~/.pi/agent/remote-auth.json` — `{allowedControlBotId, controlChatId?, maxSkewSeconds, allowedServices}` (0600)
- `~/.pi/agent/secrets/{server-bot-token,remote-hmac}` (0600, dir 0700)
- `~/.pi/agent/server-config/<module>.json` — one file per module, fixed names (0600)
- `~/.pi/agent/remote-state.json` — nonce window + last remote update/error (0600)
- `~/.pi/agent/telegram.json` — pi-telegram profile (ServerBot token, allowedUserId)


### Windows one-click layout (`C:\PiServer`)

Same files, different root: `C:\PiServer\data` **is** the agent dir
(`PI_CODING_AGENT_DIR`, honored by Pi, pi-telegram and this extension).
`C:\PiServer\app` holds versioned code + `runtime-env.json` (absolute
`node.exe`/`pi.cmd`/daemon paths resolved at install time, because SYSTEM
PATH is minimal and the npm global bin is user-scoped). `C:\PiServer\logs`
holds rotated `pi-server.log` / `pi-server-error.log` / `installer.log`.
The `PiHomeServer` task runs as SYSTEM (at-startup, restart-on-failure,
single instance, no time limit) via `app\run-task.ps1`, which sets the env,
prepends node+npm-global to PATH, rotates logs and launches the daemon in
the foreground so the task stays Running. Secrets ACL: SYSTEM+Administrators.
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
