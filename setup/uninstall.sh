#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.alysha"
VAULT_PATH="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Alysha"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.alysha.daemon.plist"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[alysha]${NC} $*"; }
success() { echo -e "${GREEN}[alysha]${NC} $*"; }
warn()    { echo -e "${YELLOW}[alysha]${NC} $*"; }

echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  Alysha Uninstall${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "This will remove:"
echo "  • Alysha daemon service (launchd)"
echo "  • Daemon config and Python venv (~/.alysha/)"
echo ""
echo "This will NOT remove:"
echo "  • Homebrew, Obsidian, Tailscale, Ollama (shared tools)"
echo "  • Your Obsidian vault (your notes are yours)"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# 1. Stop and unload daemon
info "Stopping daemon service..."
if [[ -f "$LAUNCHD_PLIST" ]]; then
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  rm -f "$LAUNCHD_PLIST"
  success "Daemon service removed"
else
  warn "No launchd plist found — skipping"
fi

# 2. Remove config dir (venv, config.json, logs, QR code)
info "Removing ~/.alysha/..."
if [[ -d "$CONFIG_DIR" ]]; then
  rm -rf "$CONFIG_DIR"
  success "~/.alysha/ removed"
else
  warn "~/.alysha/ not found — skipping"
fi

# 3. Optionally delete the vault
echo ""
echo -e "${YELLOW}Your Obsidian vault still exists at:${NC}"
echo "  $VAULT_PATH"
echo ""
echo "Delete it? This permanently removes all your notes."
read -rp "Delete vault? [y/N] " delete_vault
if [[ "${delete_vault,,}" == "y" ]]; then
  if [[ -d "$VAULT_PATH" ]]; then
    rm -rf "$VAULT_PATH"
    success "Vault deleted"
  else
    warn "Vault directory not found — skipping"
  fi
else
  info "Vault kept — you can open it in Obsidian at any time"
fi

# 4. Optionally disconnect Tailscale
echo ""
echo "Disconnect this Mac from Tailscale?"
echo "(Only do this if you're not using Tailscale for anything else)"
read -rp "Disconnect Tailscale? [y/N] " ts_logout
if [[ "${ts_logout,,}" == "y" ]]; then
  sudo tailscale logout 2>/dev/null || tailscale logout 2>/dev/null || warn "Could not disconnect — run 'tailscale logout' manually"
  success "Tailscale disconnected"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Alysha uninstalled.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "To reinstall later: bash setup/install.sh"
echo "To remove Obsidian/Ollama/Tailscale: brew uninstall <package>"
