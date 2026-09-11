# INSTALL

## 0. Prerequisites

- Old PC (Ubuntu 22.04+/Debian 12+ or Windows 10/11), powered on and online.
- Mac with Pi Coding Agent installed + Telegram.
- Your Telegram account. Clone this repo on both machines
  (`~/pi-remote-system` is the conventional path).

## 1. Telegram: two bots + control group (10 manual minutes)

1. With @BotFather create **ServerBot** (e.g. `my_home_server_bot`) and
   **ControlBot** (e.g. `my_home_control_bot`). Save both tokens.
2. For **both** bots, open @BotFather → settings → enable
   **bot-to-bot communication mode** (requires Bot API ≥ 10.0; without it the
   bots cannot see each other).
3. Create a **private group** (e.g. `pi-control`), add both bots as
   **administrators** (admins receive every message) plus yourself.
4. Collect the numeric IDs:
   - your user id: message @userinfobot;
   - ControlBot id: forward one of its messages to @userinfobot (the `from` field);
   - group chat id: with both bots inside, use a bot like @getmyid_bot, or read
     the ControlBot `getUpdates` after writing in the group
     (the id is negative, e.g. `-123456789`).
5. On your phone, open the DM with ServerBot (needed for pi-telegram pairing).

Why the group: Telegram bots **cannot DM each other** (verified against current
docs: bot-to-bot only works in groups/business chats with opt-in). The Mac
sends with the ControlBot token into the group; ServerBot reads it through its
single `getUpdates` loop.

## 2. Linux server

```bash
cd ~/pi-remote-system
chmod +x server/setup-old-pc.sh
./server/setup-old-pc.sh
```

The script (idempotent, `set -euo pipefail`, backs up before overwriting)
installs Node 22, Pi, PM2, `@llblab/pi-telegram`, links the extension, creates
config + secrets (0600/0700), starts `pi-server` on PM2 with `pm2 save` +
`pm2 startup`, disables sleep/hibernate, and verifies `getMe` + PM2 status.
It asks you (hidden input): ServerBot token, owner id, ControlBot id, group
chat id, HMAC (ENTER = random one — copy it, the Mac needs the identical value).

Then, once: `pi` → `/telegram-setup` (if needed) → `/telegram-connect`,
and on your phone open the ServerBot DM for pairing.

## 3. Windows server (empty PC: one command)

Open PowerShell (no admin needed: it self-elevates) and paste:

```powershell
irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 | iex
```

### What does this command do?

1. Downloads `setup.ps1` (trust root: HTTPS+TLS 1.2 only, see `docs/SECURITY.md`).
2. Re-launches itself as administrator and propagates the exit code.
3. Downloads release `mi-pi-server-windows.zip` + `SHA256SUMS.txt`, verifies
   the SHA256 (fail closed: mismatch = stop) and extracts to `%TEMP%`.
4. Runs `installer/windows-installer.ps1`: [1/10] Windows, [2/10] Node.js 22
   (winget, MSI fallback), [3/10] Pi CLI, [4/10] pi-telegram, [5/10] app deploy to
   `C:\PiServer\app` + extension to `C:\PiServer\data`, [6/10] config (never
   overwritten), [7/10] secrets (SYSTEM+Administrators ACL) + Pi login,
   [8/10] `PiHomeServer` task (SYSTEM, at-startup, restart), [9/10] AC sleep off
   + hibernate off, [10/10] health check (on failure: SETUP FAILED, exit 1).
5. Cleans up temp files.

Disk layout: `C:\PiServer\app` (code), `C:\PiServer\logs` (rotated logs),
`C:\PiServer\data` (`PI_CODING_AGENT_DIR`: config, extension, secrets). The task runs
as SYSTEM with absolute paths stored in `runtime-env.json`: no login required,
user HOME irrelevant.

### Remaining manual steps

- During install: ServerBot token, ControlBot ID, group chat ID, HMAC
  (ENTER = generated, shown once) and owner ID. Non-interactive alternative:
  `$env:PI_SERVER_BOT_TOKEN`, `$env:PI_CONTROL_BOT_ID`, `$env:PI_CONTROL_CHAT_ID`,
  `$env:PI_REMOTE_HMAC`, `$env:PI_OWNER_ID` (never logged).
- If Pi has no credentials: complete `/login` when the installer asks
  (it opens Pi once), press ENTER.
- On the phone: open the ServerBot DM and send `/start` (pairing).
- On the Mac: `mac/setup-mac.sh` with the ControlBot token + the same HMAC.
- Reboot test: reboot; with no login the task must be Running and Telegram online.

### Update / uninstall

```powershell
# Pipes don't forward flags: to update, download setup.ps1 and relaunch it:
Invoke-WebRequest -Uri https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 -OutFile .\setup.ps1
.\setup.ps1 -Update
# Same copy is reusable for pinned versions:
# .\setup.ps1 -Version v0.2.0 -ExpectedSha256 <hash>   # checksum pinning

# Uninstall (stops task, asks whether to keep config/secrets):
irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/uninstall.ps1 | iex
```

### Manual alternative (repo already present)

If you already cloned the repo on the PC:

```powershell
cd $HOME\pi-remote-system
.\server\setup-old-pc.ps1   # from an elevated PowerShell
```

Differences vs one-click: no release download/verification, no update/rollback,
copied extension (Windows-safe). For fresh installs prefer `setup.ps1`.

## 4. Mac

```bash
cd ~/pi-remote-system
chmod +x mac/setup-mac.sh
./mac/setup-mac.sh
```

It links `pi-remote`, creates `~/.pi/agent/remote-server.json` (routing only, no
secrets) and stores the ControlBot token + the **same server HMAC** in the Keychain.

## 5. Final smoke test

1. Reboot the server → after reboot, with no login, `pm2 list` (Linux)
   or Task Scheduler (Windows) must show the process active.
2. Phone → ServerBot DM: `server status` (or `stato server` — IT+EN both work) →
   Pi answers with uptime and modules.
3. Mac → Pi: `give me the server status` → it must use `remote_server_status`
   on its own. Then: `set example-monitor to 45 minutes on the server`
   → it must use `remote_server_config` on its own and report the confirmation.
4. Tamper check: write a line starting with `PI_REMOTE_V1` but badly signed in
   the group → it must be silently consumed (never reaches the model) and logged
   as `rejected` in `remote-state.json`.

## Quick troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `response_timeout` from the Mac | server off, `pi-server` not online, bots not admin in the group, bot-to-bot OFF |
| `bad_sender` in `remote-state.json` | wrong ControlBot id in `remote-auth.json` |
| `bad_signature` | HMAC mismatch between Mac (Keychain) and server (`secrets/remote-hmac`) |
| `replay` | duplicate message (normal on Telegram redelivery) |
| Pi not restarting on reboot (Linux) | `pm2 startup` incomplete: rerun the command it printed |
| Extension not loaded | missing symlink in `~/.pi/agent/extensions/` or unreachable `shared/` (the link must point inside the repo so `../../shared` resolves) |
