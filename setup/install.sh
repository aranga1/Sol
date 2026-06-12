#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$HOME/.sol"
VAULT_PATH="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Sol"
DAEMON_PORT=8765
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.sol.daemon.plist"
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
  "Sol Setup"

[[ "$(uname)" == "Darwin" ]] || { gum style --foreground 196 "Sol requires macOS."; exit 1; }
gum style --foreground 245 "  macOS $(sw_vers -productVersion)  ·  $(uname -m)"
echo ""

# ── Time estimate ─────────────────────────────────────────────────────────────
gum style \
  --border normal \
  --border-foreground 245 \
  --padding "0 2" \
  "$(gum style --foreground 212 --bold "Estimated time on a fast connection (~100 Mbps):")

  $(gum style --foreground 82 "~1 min")   Install dependencies (Homebrew, Python, Tailscale, Ollama, Obsidian)
  $(gum style --foreground 82 "~8 min")   Download AI model  (qwen2.5:7b · 4.7 GB)
  $(gum style --foreground 82 "~1 min")   Python environment + daemon setup
  $(gum style --foreground 82 "~2 min")   Tailscale auth + Obsidian plugin setup
  $(gum style --foreground 245 "─────────────────────────────────────────────")
  $(gum style --foreground 212 --bold "~10 min")   Total (may vary — model download dominates)"
echo ""

# ── 1. Dependencies ───────────────────────────────────────────────────────────
section "1 / 8  Dependencies"

install_brew_pkg() {
  local pkg="$1" cask="${2:-}"
  if [[ -n "$cask" ]]; then
    if brew list --cask "$pkg" &>/dev/null 2>&1; then
      skip "$pkg already installed"
      return
    fi
    spin "Installing $pkg..." brew install --quiet --cask "$pkg"
  else
    if brew list "$pkg" &>/dev/null 2>&1; then
      skip "$pkg already installed"
      return
    fi
    spin "Installing $pkg..." brew install --quiet "$pkg"
  fi
  ok "$pkg installed"
}

install_brew_pkg python@3.12
install_brew_pkg tailscale
install_brew_pkg ollama
install_brew_pkg obsidian cask

# ── 2. Ollama model ───────────────────────────────────────────────────────────
section "2 / 8  Ollama model (qwen2.5:7b)"

spin "Starting Ollama service..." brew services start ollama
sleep 2

if ollama list 2>/dev/null | grep -q "qwen2.5:7b"; then
  model_choice=$(ask "qwen2.5:7b is already downloaded." \
    "Keep existing model" \
    "Re-download (replace)")
  if [[ "$model_choice" == "Re-download (replace)" ]]; then
    spin "Pulling qwen2.5:7b..." ollama pull qwen2.5:7b
    ok "qwen2.5:7b updated"
  else
    skip "Using existing qwen2.5:7b"
  fi
else
  spin "Pulling qwen2.5:7b (~4.7 GB, this takes a few minutes)..." ollama pull qwen2.5:7b
  ok "qwen2.5:7b ready"
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
    "ollama_model": "qwen2.5:7b",
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
  -e "s|DAEMON_REPO_DIR|$REPO_DIR|g" \
  -e "s|SOL_CONFIG_PATH|$CONFIG_DIR/config.json|g" \
  -e "s|SOL_LOG_PATH|$CONFIG_DIR/daemon.log|g" \
  "$REPO_DIR/daemon/com.sol.daemon.plist" > "$LAUNCHD_PLIST"

launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
launchctl load "$LAUNCHD_PLIST"
ok "Daemon service running"

# ── 7. Tailscale ──────────────────────────────────────────────────────────────
section "7 / 8  Tailscale"

# Ensure tailscaled is running before any tailscale commands
if ! brew services list | grep -q "tailscale.*started"; then
  step "Starting Tailscale daemon..."
  sudo brew services start tailscale 2>/dev/null || brew services start tailscale 2>/dev/null || true
  sleep 3
fi

tailscale_auth() {
  local auth_choice
  auth_choice=$(ask "How would you like to authenticate?" \
    "Browser sign-in" \
    "Paste a pre-auth key")
  if [[ "$auth_choice" == "Paste a pre-auth key" ]]; then
    ts_key=$(gum input --placeholder "tskey-auth-...")
    tailscale up --auth-key="$ts_key" --accept-routes
  else
    gum style --foreground 245 "  A browser window will open — sign in and return here."
    gum style --foreground 245 "  If no browser opens, copy the URL printed below:"
    echo ""
    tailscale up --accept-routes  # blocks until auth complete; prints URL to stdout
  fi
}

if tailscale status &>/dev/null 2>&1; then
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
  skip "Already connected — IP: ${TAILSCALE_IP:-unknown}"
  ts_choice=$(ask "Tailscale is already set up." \
    "Keep existing connection" \
    "Re-authenticate")
  if [[ "$ts_choice" == "Re-authenticate" ]]; then
    tailscale_auth
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
  fi
else
  gum style --foreground 245 "  Tailscale connects your iPhone to this Mac from anywhere."
  echo ""
  tailscale_auth
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
fi

ok "Tailscale IP: $TAILSCALE_IP"

# ── 8. Obsidian plugin ────────────────────────────────────────────────────────
section "8 / 8  Obsidian Local REST API plugin"

PLUGIN_DATA="$VAULT_PATH/.obsidian/plugins/obsidian-local-rest-api/data.json"

echo ""
gum style \
  --border normal \
  --border-foreground 226 \
  --padding "1 3" \
  "$(gum style --foreground 226 --bold "Action required — Obsidian is opening now.")

$(gum style --foreground 255 "Step 1 ·") $(gum style --foreground 245 "If prompted, open the Sol vault from the vault switcher.")

$(gum style --foreground 255 "Step 2 ·") $(gum style --foreground 245 "Go to Settings (bottom-left cog) → Community Plugins.")
            $(gum style --foreground 245 "If you see a 'Turn on community plugins' button, click it.")

$(gum style --foreground 255 "Step 3 ·") $(gum style --foreground 245 "Click Browse, search for: Local REST API with MCP by Adam Coddington")
            $(gum style --foreground 245 "Click Install, then toggle it on to Enable.")

$(gum style --foreground 255 "Step 4 ·") $(gum style --foreground 245 "You may see a message about HTTPS certificates or browser trust — ignore it.")
            $(gum style --foreground 245 "Sol talks to the plugin directly and does not need that setup.")

$(gum style --foreground 255 "Step 5 ·") $(gum style --foreground 245 "Click the plugin's Options button (or Settings → Community Plugins → Local REST API).")
            $(gum style --foreground 245 "You will see an API Key field. Copy that key starting from 'Bearer <key>' — you will need it for the next step.")"

open -a Obsidian "$VAULT_PATH" 2>/dev/null || true
echo ""
gum confirm \
  --affirmative "Done — plugin is enabled" \
  --negative "" \
  "Confirm here once you have completed all 5 steps above." || true

echo ""

gum style --foreground 245 "  In Obsidian: Settings → Community Plugins → Local REST API → Options"
gum style --foreground 245 "  Copy the value in the 'API Key' field and paste it below."
echo ""
OBSIDIAN_API_KEY_FROM_PLUGIN=$(gum input --placeholder "Paste the Obsidian Local REST API key here...")

# Write the correct key into config.json
step "Syncing Obsidian API key to config..."
python3 - <<PYEOF
import json
path = "$CONFIG_DIR/config.json"
with open(path) as f:
    config = json.load(f)
config["obsidian_api_key"] = "$OBSIDIAN_API_KEY_FROM_PLUGIN"
with open(path, "w") as f:
    json.dump(config, f, indent=2)
PYEOF
ok "Config updated with Obsidian API key"

# Restart daemon so it picks up the new key
step "Restarting daemon..."
launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
launchctl load "$LAUNCHD_PLIST"
ok "Daemon restarted"

# ── QR code (connection) ──────────────────────────────────────────────────────
echo ""
step "Generating connection QR code..."
"$VENV/bin/python" "$SCRIPT_DIR/qr_generate.py" \
  --host "$TAILSCALE_IP" \
  --port "$DAEMON_PORT" \
  --api-key="$DAEMON_API_KEY" \
  --output "$CONFIG_DIR/sol-connect.png" \
  --terminal


# ── CLI shim ──────────────────────────────────────────────────────────────────
section "CLI  sol command"

step "Installing sol CLI shim..."
"$VENV/bin/python" "$SCRIPT_DIR/sol_cli.py" _install-shim
ok "sol CLI ready"

# Add ~/.local/bin to PATH in shell rc files if not already present
LOCAL_BIN="$HOME/.local/bin"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
RC_UPDATED=""
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  # Create .zshrc if it doesn't exist (common on fresh macOS)
  [[ "$rc" == "$HOME/.zshrc" ]] && touch "$rc"
  if [[ -f "$rc" ]] && ! grep -q "\.local/bin" "$rc"; then
    echo "" >> "$rc"
    echo "# Added by Sol installer" >> "$rc"
    echo "$PATH_LINE" >> "$rc"
    ok "Added ~/.local/bin to PATH in $(basename $rc)"
    RC_UPDATED="$rc"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
gum style \
  --border rounded \
  --border-foreground 82 \
  --foreground 82 \
  --bold \
  --padding "1 4" \
  --margin "1 0" \
  "Sol is ready!"

gum style "  Vault       $(gum style --foreground 245 "$VAULT_PATH")"
gum style "  Daemon      $(gum style --foreground 245 "http://$TAILSCALE_IP:$DAEMON_PORT")"
gum style "  Logs        $(gum style --foreground 245 "$CONFIG_DIR/daemon.log")"
gum style "  Connect QR  $(gum style --foreground 245 "$CONFIG_DIR/sol-connect.png")"
gum style "  CLI         $(gum style --foreground 245 "$LOCAL_BIN/sol --help")"
echo ""
gum style --foreground 245 "  iPhone next steps:"
gum style --foreground 245 "  1. Install Tailscale → sign in with the same account"
gum style --foreground 245 "  2. Install Sol (see GitHub Releases)"
gum style --foreground 245 "  3. Scan the connection QR code printed above"
gum style --foreground 245 "  4. Open Obsidian iOS → Open vault from iCloud → Sol"
echo ""
gum style \
  --border normal \
  --border-foreground 33 \
  --padding "0 2" \
  "$(gum style --foreground 33 --bold "Activate the sol command in this terminal:")

  $(gum style --foreground 255 "source ~/.zshrc")

  $(gum style --foreground 245 "Or open a new terminal — it will be available automatically from then on.")"
echo ""
