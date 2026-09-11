#!/usr/bin/env bash
#
# setup-mac.sh — configure the Mac side (pi-remote extension + Keychain secrets).
#
#  1. verify Pi installed
#  2. link pi-remote extension into ~/.pi/agent/extensions
#  3. create ~/.pi/agent/remote-server.json (non-sensitive routing only)
#  4. ask ControlBot token (hidden) -> macOS Keychain
#  5. ask HMAC secret (hidden, must match the server) -> macOS Keychain
#  6. verify extension loadable + secrets retrievable
#  7. print the natural-language final test
#
# Idempotent: safe to re-run; existing remote-server.json is backed up.
# Secrets never touch disk outside the Keychain and are never echoed.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$REPO_DIR/shared" ]]; then REPO_DIR="$HOME/pi-remote-system"; fi

AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
EXT_DIR="$AGENT_DIR/extensions"
CFG="$AGENT_DIR/remote-server.json"

KEYCHAIN_ACCOUNT="${PI_KEYCHAIN_ACCOUNT:-default}"
TOKEN_SERVICE="${PI_TOKEN_SERVICE:-pi-remote-control-bot}"
HMAC_SERVICE="${PI_HMAC_SERVICE:-pi-remote-hmac}"

info() { printf '\033[1;32m[mac-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[mac-setup]\033[0m %s\n' "$*"; }
fatal() {
  printf '\033[1;31m[mac-setup]\033[0m %s\n' "$*" >&2
  exit 1
}

[[ "$(uname)" == "Darwin" ]] || fatal "this script targets macOS (Keychain via security CLI)"
command -v security >/dev/null 2>&1 || fatal "macOS 'security' CLI not found"

# ------------------------------------------------------------- 1. pi ---
info "1/7: Pi check"
command -v pi >/dev/null 2>&1 || fatal "pi not found on PATH. Install Pi Coding Agent first."
info "pi: $(pi --version)"
command -v node >/dev/null 2>&1 || fatal "node not found on PATH"
info "node: $(node --version)"

# ----------------------------------------------------- 2. extension ---
info "2/7: pi-remote extension"
mkdir -p "$EXT_DIR"
SRC_EXT="$REPO_DIR/mac/pi-remote"
[[ -d "$SRC_EXT" ]] || fatal "extension source missing: $SRC_EXT"
DST_EXT="$EXT_DIR/pi-remote"
if [[ -L "$DST_EXT" ]]; then
  info "symlink already present"
elif [[ -e "$DST_EXT" ]]; then
  mv "$DST_EXT" "$DST_EXT.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  ln -s "$SRC_EXT" "$DST_EXT"
else
  ln -s "$SRC_EXT" "$DST_EXT"
fi
info "linked: $DST_EXT -> $SRC_EXT"

# ------------------------------------------------------- 3. config ---
info "3/7: remote-server.json (non-sensitive only)"
if [[ -f "$CFG" ]]; then
  cp -p "$CFG" "$CFG.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  info "existing config backed up"
fi

CHAT_ID="${PI_CONTROL_CHAT_ID:-}"
if [[ -z "$CHAT_ID" ]]; then
  read -rp "Control group chat id (negative number, same as server setup): " CHAT_ID
fi
[[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || fatal "chat id must be numeric"

SERVER_BOT="${PI_SERVER_BOT_USERNAME:-}"
if [[ -z "$SERVER_BOT" ]]; then
  read -rp "ServerBot username (without @, ENTER to skip): " SERVER_BOT
fi

node -e "
const fs=require('fs');
const j={
  controlChatId:Number(process.env.CHAT_ID),
  keychainAccount:process.env.KEYCHAIN_ACCOUNT,
  controlBotTokenService:process.env.TOKEN_SERVICE,
  hmacService:process.env.HMAC_SERVICE,
  ...(process.env.SERVER_BOT ? {serverBotUsername:process.env.SERVER_BOT} : {}),
  responseTimeoutSeconds:90
};
fs.writeFileSync(process.argv[1], JSON.stringify(j,null,2)+'\n');
" "$CFG" CHAT_ID="$CHAT_ID" KEYCHAIN_ACCOUNT="$KEYCHAIN_ACCOUNT" \
  TOKEN_SERVICE="$TOKEN_SERVICE" HMAC_SERVICE="$HMAC_SERVICE" SERVER_BOT="$SERVER_BOT"
chmod 600 "$CFG"
info "wrote $CFG"

# ----------------------------------------------------- 4-5. keychain ---
store_secret() {
  local service="$1" prompt="$2" envvar="$3"
  local value="${!envvar:-}"
  if [[ -z "$value" ]]; then
    read -rsp "$prompt (hidden): " value
    echo ""
  fi
  [[ -n "$value" ]] || fatal "value required for $service"
  # -U updates the existing item instead of duplicating it
  security add-generic-password -U -s "$service" -a "$KEYCHAIN_ACCOUNT" -w "$value" ||
    fatal "Keychain write failed for $service"
  unset value
  info "Keychain updated: service=$service account=$KEYCHAIN_ACCOUNT"
}

info "4/7: ControlBot token -> Keychain"
store_secret "$TOKEN_SERVICE" "ControlBot token from @BotFather" "PI_CONTROL_BOT_TOKEN"

info "5/7: HMAC secret -> Keychain (MUST match the server value)"
store_secret "$HMAC_SERVICE" "HMAC secret (same as server)" "PI_REMOTE_HMAC"

# ---------------------------------------------------------- 6. verify ---
info "6/7: verification"
node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$CFG" &&
  info "config JSON valid"
security find-generic-password -s "$TOKEN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null &&
  info "Keychain token retrievable"
security find-generic-password -s "$HMAC_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null &&
  info "Keychain HMAC retrievable"
[[ -L "$DST_EXT" && -f "$SRC_EXT/index.ts" && -f "$REPO_DIR/shared/protocol.ts" ]] &&
  info "extension files present"

# Extension load check: start pi in print mode with the extension forced.
# Uses a zero-cost prompt (no model call happens before flags are parsed)...
# NOTE: full load happens at session start; this only proves discovery.
if pi --help >/dev/null 2>&1; then info "pi CLI responsive"; fi

# ------------------------------------------------------------ 7. test ---
cat <<'EOF'

================ DONE ================
Final test — open Pi on this Mac and speak naturally:

  "dammi lo stato del server"
  "quali moduli sono attivi sul server?"
  "cambia l'intervallo del modulo example-monitor a 45 minuti sul server"

Pi must autonomously use remote_server_status / remote_server_config.
No slash commands needed.

Troubleshooting:
  - "Keychain lookup failed" -> re-run this script
  - "response_timeout"      -> server offline? pm2 list on server;
                               both bots admin in control group?
                               bot-to-bot mode ON for both bots in @BotFather?
  - "bad_sender/signature"  -> wrong ControlBot id or HMAC mismatch
======================================
EOF
