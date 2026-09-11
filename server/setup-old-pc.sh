#!/usr/bin/env bash
#
# setup-old-pc.sh — one-click setup of the 24/7 Pi node on Ubuntu/Debian.
#
# Idempotent and re-runnable: existing configs are backed up (*.bak-<timestamp>)
# before being overwritten, secrets keep 0600/0700 permissions, and every step
# detects already-completed work.
#
# What it does:
#   1. OS check (Ubuntu/Debian)            12. HMAC secret (generate or ask)
#   2. base deps (curl, git, sudo)         13. secrets with correct chmod
#   3. Node.js >= 22 (NodeSource)          14. telegram.json (ServerBot)
#   4. Pi Coding Agent (npm -g)            15. remote-auth.json
#   5. PM2 (npm -g)                        16. server-config/*.json defaults
#   6. @llblab/pi-telegram (pi package)    17. symlink pi-remote-config extension
#   7. dirs (agent, server-config,          18. pm2 start + save + startup
#      secrets, logs)                      19. disable sleep/hibernate
#   8. ServerBot token (hidden prompt)     20. online verification
#   9. Owner Telegram user id              21. final instructions only
#  10. ControlBot id + control chat id
#  11. (bot-to-bot group must exist first — see docs/INSTALL.md)
#
set -euo pipefail

SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# When run from the checked-out repo the layout is <repo>/server/setup-old-pc.sh.
# Fall back to the canonical clone location.
if [[ ! -d "$SYSTEM_DIR/shared" ]]; then SYSTEM_DIR="$HOME/pi-remote-system"; fi

AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
EXT_DIR="$AGENT_DIR/extensions"
CONFIG_DIR="$AGENT_DIR/server-config"
SECRETS_DIR="$AGENT_DIR/secrets"
LOG_DIR="$AGENT_DIR/logs"

info() { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*"; }
fatal() {
  printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2
  exit 1
}

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local bak="$f.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$f" "$bak"
    info "backup: $f -> $bak"
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- OS ---
info "step 1/20: OS check"
if [[ ! -f /etc/os-release ]]; then fatal "cannot detect OS (no /etc/os-release)"; fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
  fatal "this script targets Ubuntu/Debian (detected: ${PRETTY_NAME:-unknown})"
fi
info "OS: ${PRETTY_NAME:-unknown}"

# --------------------------------------------------------------- deps ---
info "step 2/20: base dependencies"
if need_cmd sudo; then SUDO="sudo"; else SUDO=""; fi
$SUDO apt-get update -y
$SUDO apt-get install -y curl git ca-certificates gnupg

# --------------------------------------------------------------- node ---
info "step 3/20: Node.js >= 22"
if need_cmd node && [[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]]; then
  info "node already ok: $(node --version)"
else
  info "installing Node.js 22 via NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
fi
node --version
[[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]] || fatal "node >= 22 required"

# ----------------------------------------------------------------- pi ---
info "step 4/20: Pi Coding Agent"
if need_cmd pi; then info "pi already installed: $(pi --version)"; else $SUDO npm install -g @earendil-works/pi-coding-agent; fi
pi --version

# ---------------------------------------------------------------- pm2 ---
info "step 5/20: PM2"
if need_cmd pm2; then info "pm2 already installed: $(pm2 --version)"; else $SUDO npm install -g pm2; fi

# -------------------------------------------------------- pi-telegram ---
info "step 6/20: @llblab/pi-telegram package"
if pi list 2>/dev/null | grep -q "pi-telegram"; then
  info "pi-telegram already installed"
else
  info "installing via: pi install npm:@llblab/pi-telegram"
  if ! pi install "npm:@llblab/pi-telegram"; then
    warn "automatic install failed — after this script run: pi install npm:@llblab/pi-telegram"
    warn "then run: pi (and once inside) /telegram-setup + /telegram-connect"
  fi
fi

# --------------------------------------------------------------- dirs ---
info "step 7/20: directories"
mkdir -p "$AGENT_DIR" "$EXT_DIR" "$CONFIG_DIR" "$LOG_DIR"
mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
chmod 700 "$AGENT_DIR" 2>/dev/null || true

# ------------------------------------------------------ hidden inputs ---
info "steps 8-10/20: Telegram identities"
info "Create the two bots with @BotFather if you have not yet (see docs/INSTALL.md),"
info "enable bot-to-bot mode for BOTH, and create the private control group."
echo ""

BOT_TOKEN="${PI_SERVER_BOT_TOKEN:-}"
if [[ -z "$BOT_TOKEN" ]]; then
  read -rsp "ServerBot token (from @BotFather, hidden): " BOT_TOKEN
  echo ""
fi
[[ -n "$BOT_TOKEN" ]] || fatal "ServerBot token is required"

OWNER_ID="${PI_OWNER_ID:-}"
if [[ -z "$OWNER_ID" ]]; then
  read -rp "Owner Telegram user id (from @userinfobot, digits): " OWNER_ID
fi
[[ "$OWNER_ID" =~ ^[0-9]+$ ]] || fatal "owner id must be numeric"

CONTROL_BOT_ID="${PI_CONTROL_BOT_ID:-}"
if [[ -z "$CONTROL_BOT_ID" ]]; then
  read -rp "ControlBot id (numeric; forward a ControlBot message to @userinfobot): " CONTROL_BOT_ID
fi
[[ "$CONTROL_BOT_ID" =~ ^[0-9]+$ ]] || fatal "control bot id must be numeric"

CONTROL_CHAT_ID="${PI_CONTROL_CHAT_ID:-}"
if [[ -z "$CONTROL_CHAT_ID" ]]; then
  read -rp "Control group chat id (negative number, e.g. -123456789): " CONTROL_CHAT_ID
fi
[[ "$CONTROL_CHAT_ID" =~ ^-?[0-9]+$ ]] || fatal "control chat id must be numeric"

# -------------------------------------------------------------- secrets ---
info "steps 11-13/20: HMAC secret + secret files"
HMAC_SECRET="${PI_REMOTE_HMAC:-}"
if [[ -z "$HMAC_SECRET" ]]; then
  read -rsp "HMAC secret (ENTER to generate a random 32-byte one, hidden): " HMAC_SECRET
  echo ""
  if [[ -z "$HMAC_SECRET" ]]; then
    HMAC_SECRET="$(node -p 'require("crypto").randomBytes(32).toString("hex")')"
    info "generated random HMAC — IMPORTANT: store the SAME value on the Mac Keychain via mac/setup-mac.sh"
    echo ""
    echo "    HMAC (copy now, shown once): $HMAC_SECRET"
    echo ""
  fi
fi

printf '%s' "$BOT_TOKEN" >"$SECRETS_DIR/server-bot-token"
printf '%s' "$HMAC_SECRET" >"$SECRETS_DIR/remote-hmac"
chmod 600 "$SECRETS_DIR/server-bot-token" "$SECRETS_DIR/remote-hmac"
info "secrets written (0600)"

# -------------------------------------------------------- telegram.json ---
info "step 14/20: telegram.json (ServerBot profile)"
TG_JSON="$AGENT_DIR/telegram.json"
backup_if_exists "$TG_JSON"
if [[ -f "$TG_JSON" ]]; then
  node -e "
const fs=require('fs');
const f=process.argv[1];
const j=JSON.parse(fs.readFileSync(f,'utf8'));
j.profiles=j.profiles||{};
j.profiles.default={...(j.profiles.default||{}), botToken:process.env.BOT_TOKEN, allowedUserId:Number(process.env.OWNER_ID)};
fs.writeFileSync(f, JSON.stringify(j,null,2)+'\n');
" "$TG_JSON" BOT_TOKEN="$BOT_TOKEN" OWNER_ID="$OWNER_ID"
else
  node -e "
const fs=require('fs');
const j={profiles:{default:{botToken:process.env.BOT_TOKEN, allowedUserId:Number(process.env.OWNER_ID)}}};
fs.writeFileSync(process.argv[1], JSON.stringify(j,null,2)+'\n');
" "$TG_JSON" BOT_TOKEN="$BOT_TOKEN" OWNER_ID="$OWNER_ID"
fi
chmod 600 "$TG_JSON"
info "telegram.json updated (token in file; prefer secrets/server-bot-token — file wins at runtime)"

# ------------------------------------------------------ remote-auth.json ---
info "step 15/20: remote-auth.json"
AUTH_JSON="$AGENT_DIR/remote-auth.json"
backup_if_exists "$AUTH_JSON"
node -e "
const fs=require('fs');
const j={
  allowedControlBotId:Number(process.env.CONTROL_BOT_ID),
  controlChatId:Number(process.env.CONTROL_CHAT_ID),
  maxSkewSeconds:300,
  allowedServices:['pi-server']
};
fs.writeFileSync(process.argv[1], JSON.stringify(j,null,2)+'\n');
" "$AUTH_JSON" CONTROL_BOT_ID="$CONTROL_BOT_ID" CONTROL_CHAT_ID="$CONTROL_CHAT_ID"
chmod 600 "$AUTH_JSON"

# ---------------------------------------------------- server-config/... ---
info "step 16/20: server-config defaults"
for mod in core example-monitor; do
  f="$CONFIG_DIR/$mod.json"
  if [[ ! -f "$f" ]]; then
    if [[ "$mod" == "core" ]]; then
      printf '{\n  "maintenanceMode": false,\n  "remoteControlEnabled": true\n}\n' >"$f"
    else
      printf '{\n  "enabled": true,\n  "intervalMinutes": 30\n}\n' >"$f"
    fi
    chmod 600 "$f"
    info "created $f"
  else
    info "kept existing $f"
  fi
done

# ------------------------------------------------------------- extension ---
info "step 17/20: pi-remote-config extension"
SRC_EXT="$SYSTEM_DIR/server/pi-remote-config"
if [[ ! -d "$SRC_EXT" ]]; then fatal "extension source missing: $SRC_EXT (clone the repo to ~/pi-remote-system or set SYSTEM_DIR)"; fi
DST_EXT="$EXT_DIR/pi-remote-config"
if [[ -L "$DST_EXT" ]]; then
  info "extension symlink already present"
elif [[ -e "$DST_EXT" ]]; then
  backup_if_exists "$DST_EXT"
  rm -rf "$DST_EXT"
  ln -s "$SRC_EXT" "$DST_EXT"
else
  ln -s "$SRC_EXT" "$DST_EXT"
fi
info "extension linked: $DST_EXT -> $SRC_EXT"

# ------------------------------------------------------------------ pm2 ---
info "step 18/20: PM2 start + persistence"
export PI_REMOTE_SYSTEM_DIR="$SYSTEM_DIR"
export PI_CODING_AGENT_DIR="$AGENT_DIR"
pm2 describe pi-server >/dev/null 2>&1 && pm2 delete pi-server >/dev/null 2>&1 || true
pm2 start "$SYSTEM_DIR/server/ecosystem.config.cjs" --only pi-server
pm2 save
info "configuring pm2 startup (may ask for sudo once)"
if $SUDO env PATH="$PATH" pm2 startup systemd -u "$USER" --hp "$HOME" >/tmp/pi-pm2-startup.sh 2>&1; then
  info "pm2 startup configured"
else
  warn "pm2 startup needs manual step. Run the command printed by: pm2 startup"
fi

# ------------------------------------------------------ sleep/hibernate ---
info "step 19/20: disable sleep/hibernate (server must stay awake)"
$SUDO systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || warn "could not mask sleep targets"
if need_cmd gsettings; then
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
fi

# ----------------------------------------------------------- verify ---
info "step 20/20: verification"
sleep 6
pm2 list
echo ""
if curl -fsS --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | head -c 300; then echo ""; else warn "getMe failed — check the ServerBot token + network"; fi
echo ""
if pm2 describe pi-server 2>/dev/null | grep -q "online"; then
  info "pi-server is online under PM2"
else
  warn "pi-server is not online yet — inspect: pm2 logs pi-server"
fi

# --------------------------------------------------------------- final ---
cat <<'EOF'

================ DONE ================
Only remaining manual steps (once):

  1. Pair Telegram: run `pi`, then inside Pi: /telegram-setup  (if needed)
     and  /telegram-connect
  2. On your phone, open the ServerBot DM and pair (allowedUserId above).
  3. Verify bot-to-bot: both bots have bot-to-bot mode ON in @BotFather,
     both are admins in the private control group.
  4. On the Mac: run mac/setup-mac.sh (ControlBot token + SAME HMAC).
  5. Reboot test: sudo reboot — after restart `pm2 list` must show
     pi-server online without logging in.

Daily use (no commands to remember):
  - Phone -> ServerBot DM: "stato server", "disattiva il modulo X"
  - Mac -> Pi: "cambia l'intervallo sul server a 30 minuti"
======================================
EOF
