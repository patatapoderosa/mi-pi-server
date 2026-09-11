#!/usr/bin/env bash
#
# setup-mac.sh — configure the Mac side (pi-remote extension over Tailscale).
#
#  1. verify Pi + node installed
#  2. verify/install Tailscale, verify tailnet connected
#  3. link pi-remote extension into ~/.pi/agent/extensions
#  4. ask the server Tailscale host -> remote-server.json {serverBaseUrl,...}
#  5. ask HMAC secret (hidden, must match the server) -> macOS Keychain
#     (removes the dead ControlBot token entry if present)
#  6. live-test GET /v1/status with a signed request
#  7. verify the extension is loadable + print the natural-language test
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
HMAC_SERVICE="${PI_HMAC_SERVICE:-pi-remote-hmac}"
LEGACY_TOKEN_SERVICE="${PI_TOKEN_SERVICE:-pi-remote-control-bot}"

info()  { printf '\033[1;32m[mac-setup]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[mac-setup]\033[0m %s\n' "$*" >&2; }
fatal() { printf '\033[1;31m[mac-setup]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fatal "this script targets macOS (Keychain via security CLI)"
command -v security >/dev/null 2>&1 || fatal "macOS 'security' CLI not found"

# ------------------------------------------------------------- 1. pi ---
info "1/7: Pi + node check"
command -v pi >/dev/null 2>&1 || fatal "pi not found on PATH. Install Pi Coding Agent first."
info "pi: $(pi --version)"
command -v node >/dev/null 2>&1 || fatal "node not found on PATH (needed for the signed status test)."
info "node: $(node --version)"

# ------------------------------------------------------ 2. tailscale ---
info "2/7: Tailscale check"
if ! command -v tailscale >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    info "installing Tailscale via Homebrew cask..."
    brew install --cask tailscale || fatal "brew install tailscale failed"
  else
    fatal "tailscale CLI not found. Install it (brew install --cask tailscale or https://tailscale.com/download/mac), run 'tailscale up', then re-run this script."
  fi
fi
if ! tailscale status >/dev/null 2>&1; then
  warn "Tailscale is installed but this Mac is not on the tailnet."
  warn "Run: tailscale up   (browser login once), then re-run this script."
  if ! tailscale status >/dev/null 2>&1; then
    fatal "tailnet not connected."
  fi
fi
info "tailnet connected: $(tailscale status --self 2>/dev/null | head -1 || echo ok)"

# ----------------------------------------------------- 3. extension ---
info "3/7: pi-remote extension"
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

# ---------------------------------------------------------- 4. server ---
info "4/7: server address (Tailscale)"
info "Use the server MagicDNS name (e.g. pi-server) or its 100.x IP."
SERVER_HOST="${PI_REMOTE_HOST:-}"
if [[ -z "$SERVER_HOST" ]]; then
  read -rp "Server Tailscale host [pi-server]: " SERVER_HOST
  [[ -z "$SERVER_HOST" ]] && SERVER_HOST="pi-server"
fi
SERVER_PORT="${PI_REMOTE_PORT:-43128}"
if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || [[ "$SERVER_PORT" -lt 1 || "$SERVER_PORT" -gt 65535 ]]; then
  fatal "port must be 1-65535"
fi
BASE_URL="http://$SERVER_HOST:$SERVER_PORT"
if [[ -f "$CFG" ]]; then
  cp -p "$CFG" "$CFG.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  info "existing config backed up (legacy ControlBot fields are dropped)"
fi
node -e "
const fs=require('fs');
const j={
  serverBaseUrl:process.env.BASE_URL,
  keychainAccount:process.env.KEYCHAIN_ACCOUNT,
  hmacService:process.env.HMAC_SERVICE,
  timeoutSeconds:30
};
fs.writeFileSync(process.argv[1], JSON.stringify(j,null,2)+'\n');
" "$CFG" BASE_URL="$BASE_URL" KEYCHAIN_ACCOUNT="$KEYCHAIN_ACCOUNT" HMAC_SERVICE="$HMAC_SERVICE"
chmod 600 "$CFG"
info "wrote $CFG -> $BASE_URL"

# ---------------------------------------------------------- 5. hmac ---
info "5/7: HMAC secret -> Keychain (MUST match the server value)"
HMAC_VALUE="${PI_REMOTE_HMAC:-}"
if [[ -z "$HMAC_VALUE" ]]; then
  read -rsp "HMAC secret (hidden, same as shown once by the Windows installer): " HMAC_VALUE
  echo ""
fi
[[ -n "$HMAC_VALUE" ]] || fatal "HMAC is required"
security add-generic-password -U -s "$HMAC_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$HMAC_VALUE" ||
  fatal "Keychain write failed for $HMAC_SERVICE"
unset HMAC_VALUE
info "Keychain updated: service=$HMAC_SERVICE account=$KEYCHAIN_ACCOUNT"
# Dead Telegram-transport leftover: the ControlBot token is useless now.
if security find-generic-password -s "$LEGACY_TOKEN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
  security delete-generic-password -s "$LEGACY_TOKEN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
  info "removed obsolete Keychain entry: $LEGACY_TOKEN_SERVICE (ControlBot transport deleted)"
fi

# ------------------------------------------------- 6. live status test ---
info "6/7: live test GET /v1/status (signed request)"
HMAC_NOW="$(security find-generic-password -s "$HMAC_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)" ||
  fatal "Keychain read failed for $HMAC_SERVICE"
export HMAC_NOW BASE_URL
node -e "
const crypto = require('crypto');
const ts = Math.floor(Date.now() / 1000);
const nonce = crypto.randomBytes(16).toString('hex');
const body = '';
const base = ['GET', '/v1/status', String(ts), nonce, crypto.createHash('sha256').update(body).digest('hex')].join('\n');
const sig = crypto.createHmac('sha256', process.env.HMAC_NOW).update(base, 'utf8').digest('hex');
fetch(process.env.BASE_URL + '/v1/status', {
  headers: { 'x-pi-timestamp': String(ts), 'x-pi-nonce': nonce, 'x-pi-signature': sig },
  signal: AbortSignal.timeout(15000),
}).then(async (r) => {
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.ok !== true) throw new Error('HTTP ' + r.status + ' ' + (j.error || 'refused'));
  const b = j.body || {};
  console.log('STATUS_OK host=' + (b.hostname || '?') + ' app=' + (b.appVersion || '?') + ' modules=' + ((b.modules || []).map((m) => m.name).join(',')));
}).catch((e) => { console.error('STATUS_FAIL: ' + (e.message || e)); process.exit(1); });
" || fatal "live status test failed. Is Tailscale up, the hostname right, the daemon online, and the HMAC identical on both sides?"
unset HMAC_NOW
info "server answered with signed status"

# ---------------------------------------------------------- 7. verify ---
info "7/7: verification"
node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$CFG" &&
  info "config JSON valid"
security find-generic-password -s "$HMAC_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null &&
  info "Keychain HMAC retrievable"
[[ -L "$DST_EXT" && -f "$SRC_EXT/index.ts" && -f "$REPO_DIR/shared/protocol.ts" ]] &&
  info "extension files present"
if pi --help >/dev/null 2>&1; then info "pi CLI responsive"; fi

cat <<'EOF'

================ DONE ================
Final test — open Pi on this Mac and speak naturally:

  "server status"
  "which modules are active?"
  "set example-monitor to 45 minutes"
  "disable example-monitor" / "re-enable it"

Pi must autonomously use remote_server_status / remote_server_config /
remote_module_disable / remote_module_enable. No slash commands needed.

Troubleshooting:
  - "Keychain lookup failed"      -> re-run this script
  - "server unreachable"          -> Tailscale down? tailscale status on both
                                     machines; wrong hostname? daemon online?
                                     (check C:\PiServer\logs on Windows)
  - 401 bad_signature/ts_expired  -> HMAC mismatch or clock skew > 5 min
  - 401 replay                    -> duplicate delivery; harmless, retry once
======================================
EOF
