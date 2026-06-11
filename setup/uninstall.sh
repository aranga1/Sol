#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.alysha"
VAULT_PATH="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Alysha"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.alysha.daemon.plist"

# ── gum (TUI) ────────────────────────────────────────────────────────────────
if ! command -v gum &>/dev/null; then
  echo "Installing gum for terminal UI..."
  brew install gum --quiet
fi

# ── Header ───────────────────────────────────────────────────────────────────
gum style \
  --border rounded \
  --border-foreground 196 \
  --foreground 196 \
  --bold \
  --padding "1 4" \
  --margin "1 0" \
  "Alysha Uninstaller"

gum style --foreground 245 "This will remove the Alysha daemon, config, and any tools you choose below."
echo ""

# ── Confirm ──────────────────────────────────────────────────────────────────
if ! gum confirm --affirmative "Yes, uninstall" --negative "Cancel" "Continue with uninstall?"; then
  gum style --foreground 245 "Aborted. Nothing was changed."
  exit 0
fi
echo ""

# ── Helper ───────────────────────────────────────────────────────────────────
ask() {
  # ask <header> <yes-label> <no-label>
  gum choose \
    --header "$1" \
    --cursor "▸ " \
    --cursor-prefix "  " \
    --selected-prefix "✓ " \
    "$2" "$3"
}

step() { gum style --foreground 33 "  → $*"; }
ok()   { gum style --foreground 82 "  ✓ $*"; }
skip() { gum style --foreground 245 "  – $*"; }

# ── 1. Daemon service ─────────────────────────────────────────────────────────
gum style --bold "Daemon & Config"
step "Stopping Alysha daemon..."
launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
rm -f "$LAUNCHD_PLIST"
ok "Daemon service removed"

step "Removing ~/.alysha/ (config, venv, logs)..."
rm -rf "$CONFIG_DIR"
ok "~/.alysha/ removed"
echo ""

# ── 2. Vault ──────────────────────────────────────────────────────────────────
gum style --bold "Obsidian Vault"
gum style --foreground 245 "  $VAULT_PATH"
echo ""
vault_choice=$(ask "Delete your vault? This permanently removes all your notes." \
  "Yes, delete my notes" \
  "No, keep my notes")
if [[ "$vault_choice" == "Yes, delete my notes" ]]; then
  rm -rf "$VAULT_PATH"
  ok "Vault deleted"
else
  skip "Vault kept — open it any time in Obsidian"
fi
echo ""

# ── 3. Ollama ─────────────────────────────────────────────────────────────────
gum style --bold "Ollama"
step "Stopping Ollama service..."
brew services stop ollama 2>/dev/null || true
step "Removing qwen2.5:3b model..."
ollama rm qwen2.5:3b 2>/dev/null && ok "qwen2.5:3b removed" || skip "qwen2.5:3b not found"
echo ""
ollama_choice=$(ask "Remove Ollama entirely? (~/.ollama/ can be several GB)" \
  "Yes, uninstall Ollama" \
  "No, keep Ollama")
if [[ "$ollama_choice" == "Yes, uninstall Ollama" ]]; then
  brew uninstall ollama 2>/dev/null || skip "Ollama not installed via Homebrew"
  rm -rf "$HOME/.ollama"
  ok "Ollama and all models removed"
else
  skip "Ollama kept — qwen2.5:3b was removed, other models are untouched"
fi
echo ""

# ── 4. Tailscale ──────────────────────────────────────────────────────────────
gum style --bold "Tailscale"
ts_choice=$(ask "Remove Tailscale? (say no if you use it for other things)" \
  "Yes, uninstall Tailscale" \
  "No, keep Tailscale")
if [[ "$ts_choice" == "Yes, uninstall Tailscale" ]]; then
  sudo tailscale logout 2>/dev/null || tailscale logout 2>/dev/null || true
  brew uninstall tailscale 2>/dev/null || skip "Tailscale not installed via Homebrew"
  ok "Tailscale removed"
else
  skip "Tailscale kept"
fi
echo ""

# ── 5. Obsidian ───────────────────────────────────────────────────────────────
gum style --bold "Obsidian"
obs_choice=$(ask "Remove Obsidian app? (say no if you use it outside of Alysha)" \
  "Yes, uninstall Obsidian" \
  "No, keep Obsidian")
if [[ "$obs_choice" == "Yes, uninstall Obsidian" ]]; then
  brew uninstall --cask obsidian 2>/dev/null || skip "Obsidian not installed via Homebrew"
  ok "Obsidian removed"
else
  skip "Obsidian kept"
fi
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
gum style \
  --border rounded \
  --border-foreground 82 \
  --foreground 82 \
  --bold \
  --padding "1 4" \
  --margin "1 0" \
  "Alysha uninstalled."

gum style --foreground 245 "To reinstall: bash setup/install.sh"
echo ""
