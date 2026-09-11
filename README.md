# PiServer — a 24/7 Pi Coding Agent node on an old PC

Turn an old PC into an always-on [Pi Coding Agent](https://github.com/badlogic/pi-mono)
node. Talk to it in natural language — from your Mac and from your phone over
Telegram. No VPS, no port forwarding, no public IP, no inbound firewall rules.
Free and self-hosted.

## How it works

```text
Mac ── Pi ── pi-remote ──(signed HTTPS-less HTTP over Tailscale)──▶ ┌───────────────┐
     HMAC-SHA256, port 43128, tailnet IP only                        │ pi-remote-    │
                                                                     │ server daemon │──▶ modules + config files
Phone ──Telegram DM──▶ ServerBot ── Pi (old PC) ── pi-remote-config ─▶└───────────────┘         ▲
                                               │         │                                     │
                                               │         ├── server_config / server_status / service_control (local tools)
                                               │         └── shares remote-server.json (port, policy, service allowlist)
                                               └── supervisor: PM2 pi-server + pi-remote-server (Linux)
                                                   or Task Scheduler PiHomeServer + PiRemoteServer (Windows)
                                                   pi-daemon.mjs → pi --mode rpc
```


One Telegram bot only:

```text
Phone -> ServerBot -> Pi server (Telegram DM, pi-telegram)
Mac   -> Pi -> pi-remote -> signed HTTP -> Tailscale -> pi-remote-server
```
Three moving parts:

| Where | What it does |
| --- | --- |
| Old PC (Ubuntu/Debian or Windows) | Runs Pi headless (`--mode rpc`) under a supervisor (PM2 on Linux, Task Scheduler on Windows), plus `@llblab/pi-telegram` (the ServerBot, which owns the single `getUpdates` loop), the `pi-remote-config` extension (local tools), and the standalone `pi-remote-server` HTTP daemon (Mac remote control) |
| Mac | Runs Pi with the `pi-remote` extension, which turns natural-language requests ("set the server interval to 30 minutes") into HMAC-signed HTTP calls over the Tailscale tailnet — no slash commands to remember |
| Tailscale tailnet | Private encrypted network (WireGuard) joining Mac + server. No open ports, no public IPs, no webhooks. The daemon binds the tailnet IPv4 only |

## Quick start

### Windows — empty PC, one command

Open PowerShell (admin rights not needed, it self-elevates) and paste:

```powershell
irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 | iex
```

It asks only for secrets (ServerBot token, owner ID, HMAC) plus Tailscale login.
Everything else is automatic: Node 22, Pi CLI, pi-telegram, Tailscale, app deploy,
two startup tasks, Tailscale-scoped firewall rule, sleep off, health check.
Details in `docs/INSTALL.md` (Windows section).

### Ubuntu/Debian server

Read `docs/INSTALL.md`, then run `server/setup-old-pc.sh`.

### Mac controller

Run `mac/setup-mac.sh`. It stores the server tailnet address in
`~/.pi/agent/remote-server.json` (routing only, no secrets) and the **same** HMAC
as the server in your Keychain, then live-tests a signed `/v1/status` call.

## Repository layout

```text
shared/                  HMAC auth (headers, canonical base, freshness), module schemas, atomic store + anti-replay
server/pi-remote-server/ standalone HTTP daemon (index/server/tailscale/migrate) — Mac remote control
server/pi-remote-config/ server extension (local tools: server_config/server_status/service_control)
server/pi-daemon.mjs     RPC supervisor (stdout/stderr, signals, /telegram-connect)
server/ecosystem.config.cjs  PM2 apps (pi-server + pi-remote-server) — Linux
server/setup-old-pc.sh   Linux one-click setup (idempotent, 21 steps)
server/setup-old-pc.ps1  manual Windows setup (repo present; prefer setup.ps1)
setup.ps1                one-line Windows bootstrap (downloads verified release)
uninstall.ps1            Windows removal (both tasks, asks to keep config/secrets)
installer/               windows-installer + lib + run-task + run-remote + release + smoke test
mac/pi-remote/           Mac extension (remote_server_status/config, remote_module_enable/disable)
mac/setup-mac.sh         Mac setup (Tailscale check, Keychain HMAC, live signed test)
tests/                   node:test suite (61 tests, no deps)
docs/                    ARCHITECTURE / INSTALL / SECURITY / TESTING
```

## Docs

- `docs/ARCHITECTURE.md` — components, message flow, verified API facts and adaptations
- `docs/INSTALL.md` — step-by-step: bot, Tailscale, server, Mac, pairing, reboot test
- `docs/SECURITY.md` — threat model, protocol checks, permissions, what is (not) possible
- `docs/TESTING.md` — what is tested, how to run, what needs a live check

## Hard guarantees

- **One polling loop.** Only `pi-telegram` calls `getUpdates` for the ServerBot.
  There is no second bot, no control group, no Telegram transport for Mac→server.
- **No remote shell.** There is no `run_command`/`exec`/path/process tool —
  locally or remotely. Only typed routes on registered modules and an allowlisted
  PM2 service list. The daemon never runs commands or resolves client paths.
- **No inbound exposure.** The daemon binds the tailnet IPv4 only (never
  `0.0.0.0`); the Windows firewall rule allows the port on the Tailscale
  interface only. Nothing listens on LAN or the public internet.
- **Invalid remote input is rejected before touching state.** Bad headers,
  bad signature, stale timestamp, or replayed nonce → `401`, nothing applied.
