#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$HOME/.alysha"
VAULT_PATH="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Alysha"
DAEMON_PORT=8765
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.alysha.daemon.plist"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[alysha]${NC} $*"; }
success() { echo -e "${GREEN}[alysha]${NC} $*"; }
warn()    { echo -e "${YELLOW}[alysha]${NC} $*"; }
fail()    { echo -e "${RED}[alysha] ERROR:${NC} $*" >&2; exit 1; }

# 1. Check macOS
[[ "$(uname)" == "Darwin" ]] || fail "Alysha requires macOS."
info "macOS $(sw_vers -productVersion)"

# 2. Homebrew
if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
fi
success "Homebrew ready"

# 3. Dependencies
info "Installing dependencies..."
brew install --quiet tailscale ollama python@3.12 2>/dev/null || true
brew install --cask --quiet obsidian 2>/dev/null || true
success "Dependencies installed"

# 4. Ollama model
info "Pulling Ollama model (phi3.5)..."
brew services start ollama 2>/dev/null || true
sleep 3
ollama pull phi3.5 || warn "Model pull failed — run 'ollama pull phi3.5' manually"
success "Ollama ready"

# 5. Vault
info "Creating Obsidian vault..."
python3 "$SCRIPT_DIR/obsidian_config.py" "$VAULT_PATH"
success "Vault created at $VAULT_PATH"

# 6. Daemon config
info "Configuring daemon..."
mkdir -p "$CONFIG_DIR"
OBSIDIAN_API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
DAEMON_API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
# Only write if not exists
if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
  python3 - <<PYEOF
import json
config = {
    "vault_path": "$VAULT_PATH",
    "daemon_port": $DAEMON_PORT,
    "obsidian_api_key": "$OBSIDIAN_API_KEY",
    "obsidian_port": 27124,
    "daemon_api_key": "$DAEMON_API_KEY",
    "ollama_model": "phi3.5",
    "ollama_base_url": "http://localhost:11434"
}
with open("$CONFIG_DIR/config.json", "w") as f:
    json.dump(config, f, indent=2)
import os; os.chmod("$CONFIG_DIR/config.json", 0o600)
PYEOF
fi
# Read the daemon API key from config for QR generation
DAEMON_API_KEY=$(python3 -c "import json; d=json.load(open('$CONFIG_DIR/config.json')); print(d['daemon_api_key'])")
success "Config written (mode 600)"

# 7. Python venv + deps
info "Installing daemon Python dependencies..."
VENV="$CONFIG_DIR/venv"
python3.12 -m venv "$VENV" 2>/dev/null || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$REPO_DIR/daemon/requirements.txt"
success "Python environment ready"

# 8. launchd
info "Installing daemon service..."
sed \
  -e "s|DAEMON_VENV_PYTHON|$VENV/bin/python|g" \
  -e "s|DAEMON_MAIN_PY|$REPO_DIR/daemon/main.py|g" \
  -e "s|ALYSHA_CONFIG_PATH|$CONFIG_DIR/config.json|g" \
  -e "s|ALYSHA_LOG_PATH|$CONFIG_DIR/daemon.log|g" \
  "$REPO_DIR/daemon/com.alysha.daemon.plist" > "$LAUNCHD_PLIST"
launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
launchctl load "$LAUNCHD_PLIST"
success "Daemon service installed and started"

# 9. Tailscale
info "Setting up Tailscale..."
echo ""
echo -e "${YELLOW}Tailscale connects your iPhone to this Mac from anywhere.${NC}"
echo "  1) Paste a pre-auth key  (get one at login.tailscale.com/admin/settings/keys)"
echo "  2) Browser auth flow"
echo ""
read -rp "Choose [1/2, default=2]: " ts_choice
if [[ "${ts_choice:-2}" == "1" ]]; then
  read -rp "Paste pre-auth key: " ts_key
  sudo tailscale up --auth-key="$ts_key" --accept-routes 2>/dev/null || tailscale up --auth-key="$ts_key"
else
  sudo tailscale up --accept-routes 2>/dev/null || tailscale up
  echo "Complete sign-in in the browser, then press Enter..."
  read -r
fi
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
success "Tailscale IP: $TAILSCALE_IP"

# 10. Obsidian plugin instructions
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  ACTION REQUIRED: Enable Obsidian Local REST API${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  1. Open Obsidian (launching now...)"
echo "  2. Open the Alysha vault"
echo "  3. Settings → Community Plugins → disable Safe Mode"
echo "  4. Browse → search 'Local REST API' → Install → Enable"
echo ""
open -a Obsidian "$VAULT_PATH" 2>/dev/null || true
read -rp "Press Enter once Local REST API is enabled..."

# 11. QR code
info "Generating connection QR code..."
python3 "$SCRIPT_DIR/qr_generate.py" \
  --host "$TAILSCALE_IP" \
  --port "$DAEMON_PORT" \
  --api-key "$DAEMON_API_KEY" \
  --output "$CONFIG_DIR/alysha-connect.png" \
  --terminal

# 12. Summary
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Alysha setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Vault:    $VAULT_PATH"
echo "  Daemon:   http://$TAILSCALE_IP:$DAEMON_PORT"
echo "  Logs:     $CONFIG_DIR/daemon.log"
echo "  QR code:  $CONFIG_DIR/alysha-connect.png"
echo ""
echo "  iPhone next steps:"
echo "  1. Install Tailscale → sign in with same account"
echo "  2. Install Alysha app (see GitHub Releases)"
echo "  3. Scan the QR code above"
echo "  4. Open Obsidian iOS → Open vault from iCloud → Alysha"
