# PiServer — a 24/7 Pi Coding Agent node on an old PC

Turn an old PC into an always-on [Pi Coding Agent](https://github.com/badlogic/pi-mono)
node. Talk to it in natural language — from your Mac and from your phone over
Telegram. No VPS, no port forwarding, no public IP, no inbound firewall rules.
Free and self-hosted.

## How it works

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
                                              └── supervisor: PM2 pi-server (Linux) or Task Scheduler (Windows)
                                                  pi-daemon.mjs → pi --mode rpc
```

Three moving parts:

| Where | What it does |
| --- | --- |
| Old PC (Ubuntu/Debian or Windows) | Runs Pi headless (`--mode rpc`) under a supervisor (PM2 on Linux, Task Scheduler on Windows), plus `@llblab/pi-telegram` (the ServerBot, which owns the single `getUpdates` loop) and the `pi-remote-config` extension |
| Mac | Runs Pi with the `pi-remote` extension, which turns natural-language requests ("set the server interval to 30 minutes") into signed Telegram commands — no slash commands to remember |
| Telegram | Two bots — **ServerBot** (talks to you, receives remote ops) and **ControlBot** (Mac-only sender) — plus one private control group where they meet. Bots cannot DM each other (see `docs/ARCHITECTURE.md`) |

## Quick start

### Windows — empty PC, one command

Open PowerShell (admin rights not needed, it self-elevates) and paste:

```powershell
irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 | iex
```

It asks only for secrets (ServerBot token, group/chat IDs, HMAC). Everything
else is automatic: Node 22, Pi CLI, pi-telegram, extension deploy, startup
task, sleep off, health check. Details in `docs/INSTALL.md` (Windows section).

### Ubuntu/Debian server

Read `docs/INSTALL.md`, then run `server/setup-old-pc.sh`.

### Mac controller

Run `mac/setup-mac.sh`. It stores the ControlBot token and the **same** HMAC
as the server in your Keychain.

## Repository layout

```
shared/                  protocol (HMAC envelope), module schemas, atomic store + anti-replay
server/pi-remote-config/ server extension (local tools + secure remote ops)
server/pi-daemon.mjs     RPC supervisor (stdout/stderr, signals, /telegram-connect)
server/ecosystem.config.cjs  PM2 app(s) — Linux
server/setup-old-pc.sh   Linux one-click setup (idempotent)
server/setup-old-pc.ps1  manual Windows setup (repo present; prefer setup.ps1)
setup.ps1                one-line Windows bootstrap (downloads verified release)
uninstall.ps1            Windows removal (asks to keep config/secrets)
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
