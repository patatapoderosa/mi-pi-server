# Pi Remote System — 24/7 Pi Coding Agent node on an old PC

Turn an old PC into an always-on Pi Coding Agent node. Control it in natural
language from your Mac (via a `pi-remote` extension) and from your phone
(via Telegram DM with the ServerBot). No VPS, no port forwarding, no public
IP, no open ports. Free and self-hosted.

```
Mac ── Pi ── pi-remote ──(HTTPS sendMessage, ControlBot token)──▶ ┌──────────────┐
                                                                   │  PRIVATE     │
                                                                   │  control     │──▶ ServerBot getUpdates
                                                                   │  GROUP       │    (pi-telegram owns the ONLY loop)
                                                                   └──────────────┘         │
Phone ──Telegram DM──▶ ServerBot ── Pi (old PC) ── pi-remote-config ──▶ ◀─────┘
                                              │         │
                                              │         ├── server_config / server_status / service_control
                                              │         └── signed remote ops (set_config/get_status/ping/service)
                                              └── PM2 pi-server (pi-daemon.mjs → pi --mode rpc)
```

## What runs where

| Where | What |
| --- | --- |
| Old PC (Ubuntu/Debian or Windows) | Pi (`--mode rpc`, headless) under PM2 (`pi-server`) or Task Scheduler, `@llblab/pi-telegram` (ServerBot, owns the single `getUpdates` loop), `pi-remote-config` extension |
| Mac | Pi + `pi-remote` extension (tools `remote_server_config`, `remote_server_status`), secrets in Keychain |
| Telegram | Two bots: **ServerBot** (talks to you + receives remote ops) and **ControlBot** (Mac-only sender). They meet in one **private control group** — bots cannot DM each other (see docs/ARCHITECTURE.md) |

## Quick start

### Windows (PC vuoto, un solo comando)

Apri PowerShell e incolla:

```powershell
irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 | iex
```

Ti chiede solo i secret (ServerBot token, ID gruppo, HMAC). Tutto il resto è
automatico: Node 22, Pi, pi-telegram, extension, task di avvio, sleep off,
health check. Dettagli in `docs/INSTALL.md` (sezione Windows).

### Linux / Mac (setup manuali)

- **Server (Ubuntu/Debian):** leggi `docs/INSTALL.md`, poi `server/setup-old-pc.sh`.
- **Mac:** `mac/setup-mac.sh`.
## Repository layout

```
shared/                  protocol (HMAC envelope), module schemas, atomic store + anti-replay
server/pi-remote-config/ server extension (local tools + secure remote ops)
server/pi-daemon.mjs     RPC supervisor (stdout/stderr, signals, /telegram-connect)
server/ecosystem.config.cjs  PM2 app(s)
server/setup-old-pc.sh   Linux one-click setup (idempotent)
server/setup-old-pc.ps1  Windows setup manuale (repo presente; preferisci setup.ps1)
setup.ps1                bootstrap one-line Windows (scarica release verificata)
uninstall.ps1            rimozione Windows (chiede keep config/secrets)
installer/               windows-installer + lib + run-task + release + smoke test
mac/pi-remote/           Mac extension (remote_server_config/status)
mac/setup-mac.sh         Mac setup (Keychain secrets)
tests/                   node:test suite (32 tests, no deps)
docs/                    ARCHITECTURE / INSTALL / SECURITY / TESTING
```

## Docs

- `docs/ARCHITECTURE.md` — components, message flow, verified API facts and adaptations
- `docs/INSTALL.md` — step-by-step: bots, group, server, Mac, pairing, reboot test
- `docs/SECURITY.md` — threat model, protocol checks, permissions, what is (not) possible
- `docs/TESTING.md` — what is tested, how to run, what needs a live Telegram check

## Hard guarantees

- **One polling loop.** Only `pi-telegram` calls `getUpdates` for the ServerBot.
  `pi-remote-config` uses the public update-handler registry and never polls.
  The Mac side does short-lived polls only on the ControlBot token (nothing else
  polls that bot).
- **No remote shell.** There is no `run_command`/`exec`/path/process tool —
  locally or remotely. Only typed ops on registered modules and an allowlisted
  PM2 service list.
- **Invalid remote input never reaches the model.** Any message with the remote
  prefix is consumed by the handler, valid or not.
