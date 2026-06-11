#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$HOME/.alysha"
VAULT_PATH="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Alysha"
DAEMON_PORT=8765
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.alysha.daemon.plist"
VENV="$CONFIG_DIR/venv"

# ── Bootstrap gum ─────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew (required for setup)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
fi

if ! command -v gum &>/dev/null; then
  echo "Installing gum for terminal UI..."
  brew install gum --quiet
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
step()    { gum style --foreground 33  "  → $*"; }
ok()      { gum style --foreground 82  "  ✓ $*"; }
skip()    { gum style --foreground 245 "  – $*"; }
section() { echo ""; gum style --bold --foreground 212 "$*"; }
spin()    { gum spin --spinner dot --title " $1" -- "${@:2}"; }

ask() {
  # ask <header> <yes-label> <no-label>
  gum choose \
    --header "$1" \
    --cursor "▸ " \
    --cursor-prefix "  " \
    --selected-prefix "✓ " \
    "$2" "$3"
}

# ── Header ────────────────────────────────────────────────────────────────────
gum style \
  --border rounded \
  --border-foreground 212 \
  --foreground 212 \
  --bold \
  --padding "1 4" \
  --margin "1 0" \
  "Alysha Setup"

[[ "$(uname)" == "Darwin" ]] || { gum style --foreground 196 "Alysha requires macOS."; exit 1; }
gum style --foreground 245 "  macOS $(sw_vers -productVersion)  ·  $(uname -m)"
echo ""

# ── 1. Dependencies ───────────────────────────────────────────────────────────
section "1 / 8  Dependencies"

install_brew_pkg() {
  local pkg="$1" cask="${2:-}"
  local flags=(--quiet)
  [[ -n "$cask" ]] && flags+=(--cask)
  if brew list $cask "$pkg" &>/dev/null 2>&1; then
    skip "$pkg already installed"
  else
    spin "Installing $pkg..." brew install "${flags[@]}" "$pkg"
    ok "$pkg installed"
  fi
}

install_brew_pkg python@3.12
install_brew_pkg tailscale
install_brew_pkg ollama
install_brew_pkg obsidian cask

# ── 2. Ollama model ───────────────────────────────────────────────────────────
section "2 / 8  Ollama model (phi3.5)"

spin "Starting Ollama service..." brew services start ollama
sleep 2

if ollama list 2>/dev/null | grep -q "phi3.5"; then
  model_choice=$(ask "phi3.5 is already downloaded." \
    "Keep existing model" \
    "Re-download (replace)")
  if [[ "$model_choice" == "Re-download (replace)" ]]; then
    spin "Pulling phi3.5..." ollama pull phi3.5
    ok "phi3.5 updated"
  else
    skip "Using existing phi3.5"
  fi
else
  spin "Pulling phi3.5 (~2 GB, this takes a few minutes)..." ollama pull phi3.5
  ok "phi3.5 ready"
fi

# ── 3. Obsidian vault ─────────────────────────────────────────────────────────
section "3 / 8  Obsidian vault"

if [[ -d "$VAULT_PATH/.obsidian" ]]; then
  skip "Vault already exists at $VAULT_PATH"
else
  step "Creating vault..."
  python3 "$SCRIPT_DIR/obsidian_config.py" "$VAULT_PATH"
  ok "Vault created"
fi

# ── 4. Daemon config ──────────────────────────────────────────────────────────
section "4 / 8  Daemon config"

mkdir -p "$CONFIG_DIR"

if [[ -f "$CONFIG_DIR/config.json" ]]; then
  skip "config.json already exists — keeping existing API keys"
else
  step "Generating config and API keys..."
  OBSIDIAN_API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  DAEMON_API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  python3 - <<PYEOF
import json, os
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
os.chmod("$CONFIG_DIR/config.json", 0o600)
PYEOF
  ok "Config written (mode 600)"
fi

# Read daemon key for QR generation later
DAEMON_API_KEY=$(python3 -c "import json; d=json.load(open('$CONFIG_DIR/config.json')); print(d['daemon_api_key'])")

# ── 5. Python venv ────────────────────────────────────────────────────────────
section "5 / 8  Python environment"

if [[ -f "$VENV/bin/pip" ]]; then
  step "Venv exists — updating dependencies..."
  spin "Updating packages..." "$VENV/bin/pip" install --quiet --upgrade -r "$REPO_DIR/daemon/requirements.txt"
  ok "Dependencies up to date"
else
  step "Creating venv..."
  python3.12 -m venv "$VENV" 2>/dev/null || python3 -m venv "$VENV"
  spin "Installing packages..." "$VENV/bin/pip" install --quiet --upgrade pip
  spin "Installing daemon deps..." "$VENV/bin/pip" install --quiet -r "$REPO_DIR/daemon/requirements.txt"
  ok "Python environment ready"
fi

# ── 6. Daemon service ─────────────────────────────────────────────────────────
section "6 / 8  Daemon service"

step "Installing launchd service..."
sed \
  -e "s|DAEMON_VENV_PYTHON|$VENV/bin/python|g" \
  -e "s|DAEMON_MAIN_PY|$REPO_DIR/daemon/main.py|g" \
  -e "s|ALYSHA_CONFIG_PATH|$CONFIG_DIR/config.json|g" \
  -e "s|ALYSHA_LOG_PATH|$CONFIG_DIR/daemon.log|g" \
  "$REPO_DIR/daemon/com.alysha.daemon.plist" > "$LAUNCHD_PLIST"

launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
launchctl load "$LAUNCHD_PLIST"
ok "Daemon service running"

# ── 7. Tailscale ──────────────────────────────────────────────────────────────
section "7 / 8  Tailscale"

if tailscale status &>/dev/null 2>&1; then
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
  skip "Already connected — IP: ${TAILSCALE_IP:-unknown}"
  ts_choice=$(ask "Tailscale is already set up." \
    "Keep existing connection" \
    "Re-authenticate")
  if [[ "$ts_choice" == "Keep existing connection" ]]; then
    ok "Using existing Tailscale connection"
  else
    gum style --foreground 245 ""
    gum style --foreground 245 "  1) Paste a pre-auth key (login.tailscale.com → Settings → Keys)"
    gum style --foreground 245 "  2) Browser sign-in"
    echo ""
    auth_choice=$(ask "How would you like to re-authenticate?" \
      "Paste a pre-auth key" \
      "Browser sign-in")
    if [[ "$auth_choice" == "Paste a pre-auth key" ]]; then
      ts_key=$(gum input --placeholder "tskey-auth-...")
      sudo tailscale up --auth-key="$ts_key" --accept-routes 2>/dev/null || tailscale up --auth-key="$ts_key"
    else
      sudo tailscale up --accept-routes 2>/dev/null || tailscale up
      gum confirm --affirmative "I've signed in" --negative "" "Complete sign-in in the browser, then confirm." || true
    fi
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
  fi
else
  gum style --foreground 245 "  Tailscale connects your iPhone to this Mac from anywhere."
  echo ""
  auth_choice=$(ask "How would you like to authenticate?" \
    "Paste a pre-auth key" \
    "Browser sign-in")
  if [[ "$auth_choice" == "Paste a pre-auth key" ]]; then
    ts_key=$(gum input --placeholder "tskey-auth-...")
    sudo tailscale up --auth-key="$ts_key" --accept-routes 2>/dev/null || tailscale up --auth-key="$ts_key"
  else
    sudo tailscale up --accept-routes 2>/dev/null || tailscale up
    gum confirm --affirmative "I've signed in" --negative "" "Complete sign-in in the browser, then confirm." || true
  fi
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
fi

ok "Tailscale IP: $TAILSCALE_IP"

# ── 8. Obsidian plugin ────────────────────────────────────────────────────────
section "8 / 8  Obsidian Local REST API plugin"

echo ""
gum style \
  --border normal \
  --border-foreground 226 \
  --foreground 226 \
  --padding "0 2" \
  "Action required — do this in Obsidian:
  1. Open Obsidian and select the Alysha vault
  2. Settings → Community Plugins → disable Safe Mode
  3. Browse → search 'Local REST API' → Install → Enable"

open -a Obsidian "$VAULT_PATH" 2>/dev/null || true
echo ""
gum confirm --affirmative "Done, Local REST API is enabled" --negative "" "Press confirm once the plugin is enabled." || true

# ── QR code ───────────────────────────────────────────────────────────────────
echo ""
step "Generating connection QR code..."
"$VENV/bin/python" "$SCRIPT_DIR/qr_generate.py" \
  --host "$TAILSCALE_IP" \
  --port "$DAEMON_PORT" \
  --api-key "$DAEMON_API_KEY" \
  --output "$CONFIG_DIR/alysha-connect.png" \
  --terminal

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
gum style \
  --border rounded \
  --border-foreground 82 \
  --foreground 82 \
  --bold \
  --padding "1 4" \
  --margin "1 0" \
  "Alysha is ready!"

gum style "  Vault    $(gum style --foreground 245 "$VAULT_PATH")"
gum style "  Daemon   $(gum style --foreground 245 "http://$TAILSCALE_IP:$DAEMON_PORT")"
gum style "  Logs     $(gum style --foreground 245 "$CONFIG_DIR/daemon.log")"
gum style "  QR code  $(gum style --foreground 245 "$CONFIG_DIR/alysha-connect.png")"
echo ""
gum style --foreground 245 "  iPhone next steps:"
gum style --foreground 245 "  1. Install Tailscale → sign in with the same account"
gum style --foreground 245 "  2. Install Alysha (see GitHub Releases)"
gum style --foreground 245 "  3. Scan the QR code printed above"
gum style --foreground 245 "  4. Open Obsidian iOS → Open vault from iCloud → Alysha"
echo ""
