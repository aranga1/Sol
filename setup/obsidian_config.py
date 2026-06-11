#!/usr/bin/env python3
"""Create Obsidian vault structure and plugin config."""
import json, sys
from pathlib import Path
from datetime import datetime, timezone

def setup_vault(vault_path: str) -> None:
    vault = Path(vault_path)
    vault.mkdir(parents=True, exist_ok=True)
    (vault / "Notes").mkdir(exist_ok=True)
    (vault / "Attachments").mkdir(exist_ok=True)

    obsidian = vault / ".obsidian"
    obsidian.mkdir(exist_ok=True)

    # app.json
    (obsidian / "app.json").write_text(json.dumps({
        "useMarkdownLinks": False,
        "newFileFolderPath": "Notes",
        "attachmentFolderPath": "Attachments"
    }, indent=2))

    # Enable community plugins
    (obsidian / "community-plugins.json").write_text(
        json.dumps(["obsidian-local-rest-api"])
    )

    # Local REST API plugin config (API key set by install.sh via config.json)
    plugin_dir = obsidian / "plugins" / "obsidian-local-rest-api"
    plugin_dir.mkdir(parents=True, exist_ok=True)
    (plugin_dir / "data.json").write_text(json.dumps({
        "port": 27124,
        "enableHttps": False,
        "apiKey": ""  # will be set when user enables plugin in Obsidian
    }, indent=2))

    # Welcome note
    welcome = vault / "Notes" / "Welcome to Alysha.md"
    if not welcome.exists():
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        welcome.write_text(f"""---
created: {ts}
tags:
  - alysha
  - welcome
---

# Welcome to Alysha

Your second brain vault is ready. Notes captured from your iPhone will appear here.

**Next steps:**
1. Enable the Local REST API community plugin in Obsidian settings
2. Scan the QR code shown in your terminal from the Alysha iPhone app
3. On iPhone: install Tailscale, install Alysha, open Obsidian iOS and sync this vault via iCloud
""")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: obsidian_config.py <vault_path>", file=sys.stderr)
        sys.exit(1)
    setup_vault(sys.argv[1])
    print(f"Vault configured at {sys.argv[1]}")
