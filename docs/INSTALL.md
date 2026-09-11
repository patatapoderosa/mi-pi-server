# INSTALL

## 0. Prerequisites

- Old PC (Ubuntu 22.04+/Debian 12+ or Windows 10/11), powered on and online.
- Mac with Pi Coding Agent installed.
- Your Telegram account (phone with Telegram for pairing).
- A Tailscale account (free): both machines join the same tailnet.
  Clone this repo on the server and the Mac (`~/pi-remote-system` is the
  conventional path).

## 1. Telegram: one bot (5 manual minutes)

1. With @BotFather create **ServerBot** (e.g. `my_home_server_bot`). Save the token.
2. Collect your numeric user id: message @userinfobot.
3. On your phone, open the DM with ServerBot (needed for pi-telegram pairing).

That's it — no second bot, no group. The Mac reaches the server over Tailscale,
never through Telegram.

## 2. Linux server

```bash
cd ~/pi-remote-system
chmod +x server/setup-old-pc.sh
./server/setup-old-pc.sh
```

The script (idempotent, `set -euo pipefail`, backs up before overwriting)
installs Node 22, Pi, PM2, `@llblab/pi-telegram`, links the extension, creates
config + secrets (0600/0700), installs Tailscale and joins the tailnet,
writes `remote-server.json`, starts **both** `pi-server` and `pi-remote-server`
on PM2 with `pm2 save` + `pm2 startup`, disables sleep/hibernate, and verifies
`getMe` + PM2 status + a signed `/v1/ping` against the local daemon.
It asks you (hidden input): ServerBot token, owner id, HMAC (ENTER = random
one — copy it, the Mac needs the identical value). Tailscale login is either
`PI_TAILSCALE_AUTHKEY` (headless) or one interactive browser login.

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
4. Runs `installer/windows-installer.ps1`: [1/11] Windows, [2/11] Node.js 22
   (winget, MSI fallback), [3/11] Pi CLI, [4/11] pi-telegram,
   [5/11] Tailscale install + tailnet login (interactive browser login, or
   `-TailscaleAuthKey` for headless), [6/11] app deploy to `C:\PiServer\app`
   - daemon files + extension to `C:\PiServer\data`, [7/11]
   `remote-server.json` (port 43128, no Telegram IDs anywhere), [8/11] secrets
   (SYSTEM+Administrators ACL) + Pi login, [9/11] `PiHomeServer` +
   `PiRemoteServer` tasks (SYSTEM, at-startup, restart) + Tailscale-scoped
   firewall rule, [10/11] AC sleep off + hibernate off, [11/11] health check
   (daemon `/v1/ping` probe included; on failure: SETUP FAILED, exit 1).
5. Cleans up temp files.

Disk layout: `C:\PiServer\app` (code), `C:\PiServer\logs` (rotated logs),
`C:\PiServer\data` (`PI_CODING_AGENT_DIR`: config, extension, secrets). The tasks run
as SYSTEM with absolute paths stored in `runtime-env.json`: no login required,
user HOME irrelevant.

### Remaining manual steps

- During install: ServerBot token, owner ID, HMAC (ENTER = generated, shown
  once). Non-interactive alternative: `$env:PI_SERVER_BOT_TOKEN`,
  `$env:PI_REMOTE_HMAC`, `$env:PI_OWNER_ID`, `$env:PI_TAILSCALE_AUTHKEY`
  (never logged; the auth key is accepted only when `setup.ps1` already runs
  elevated — it is never forwarded through the auto-elevation relaunch).
- Tailscale: authorize the PC in the browser when asked (or pass the auth key).
- If Pi has no credentials: complete `/login` when the installer asks
  (it opens Pi once), press ENTER.
- On the phone: open the ServerBot DM and send `/start` (pairing).
- On the Mac: `mac/setup-mac.sh` with the server tailnet name + the same HMAC.
- Reboot test: reboot; with no login both tasks must be Running and Telegram online.

### Update / uninstall

```powershell
# Pipes don't forward flags: to update, download setup.ps1 and relaunch it:
Invoke-WebRequest -Uri https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 -OutFile .\setup.ps1
.\setup.ps1 -Update
# Same copy is reusable for pinned versions:
# .\setup.ps1 -Version v0.2.0 -ExpectedSha256 <hash>   # checksum pinning

# Uninstall (stops both tasks, asks whether to keep config/secrets):
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

It checks Pi + node, checks/installs Tailscale (Homebrew cask) and verifies the
tailnet, links `pi-remote`, writes `~/.pi/agent/remote-server.json`
(`serverBaseUrl` like `http://pi-server:43128`, Keychain pointers — routing
only, no secrets), stores the **same server HMAC** in the Keychain
(`security add-generic-password`), deletes the dead ControlBot token entry if
present, and live-tests a signed `GET /v1/status`.

## 5. Final smoke test

1. Reboot the server → after reboot, with no login, `pm2 list` (Linux)
   or Task Scheduler (Windows) must show **both** processes active.
2. Phone → ServerBot DM: `server status` → Pi answers with uptime and modules.
3. Mac → Pi: `give me the server status` → it must use `remote_server_status`
   on its own. Then: `set example-monitor to 45 minutes on the server`
   → it must use `remote_server_config` on its own and report the confirmation.
   Then: `disable example-monitor` / `re-enable it` → `remote_module_disable` /
   `remote_module_enable`.
4. Tamper check (proves auth is real): from any machine on the tailnet,
   `curl http://<server>:43128/v1/status` with no headers → `401 missing_auth`;
   with a wrong signature → `401`. Nothing is applied, nothing leaks.

## Quick troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Mac tool error `server unreachable` / timeout | server off, `pi-remote-server` not online, Tailscale down on either side (`tailscale status`), wrong hostname in `~/.pi/agent/remote-server.json` |
| `bad_signature` | HMAC mismatch between Mac (Keychain) and server (`secrets/remote-hmac`) |
| `ts_expired` / `ts_future` | clock skew > `maxSkewSeconds` (default 300 s): fix NTP/clock |
| `replay` | duplicate nonce (normal on retry): retry once with a fresh call |
| `unknown_module` / `invalid_patch` | wrong module name or field not in the registry schema |
| Pi not restarting on reboot (Linux) | `pm2 startup` incomplete: rerun the command it printed |
| Extension not loaded | missing symlink in `~/.pi/agent/extensions/` or unreachable `shared/` (the link must point inside the repo so `../../shared` resolves) |
| Windows task Running but daemon unreachable | Tailscale not connected yet at boot (`tailscale ip -4` empty → loopback fallback): daemon logs the bind source on every start |
