#!/usr/bin/env python3
"""sol — CLI utility for managing the Sol daemon and iOS app."""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR   = Path(__file__).resolve().parent
REPO_DIR     = SCRIPT_DIR.parent
CONFIG_DIR   = Path.home() / ".sol"
CONFIG_FILE  = CONFIG_DIR / "config.json"
LOG_FILE     = CONFIG_DIR / "daemon.log"
PLIST        = Path.home() / "Library/LaunchAgents/com.sol.daemon.plist"
VENV_PYTHON  = CONFIG_DIR / "venv/bin/python"
VERSION_FILE = REPO_DIR / "VERSION"

# ── ANSI colours ───────────────────────────────────────────────────────────────
_NO_COLOR = not sys.stdout.isatty() or os.environ.get("NO_COLOR")

def _c(code: str, text: str) -> str:
    return text if _NO_COLOR else f"\033[{code}m{text}\033[0m"

def green(t):  return _c("32", t)
def yellow(t): return _c("33", t)
def red(t):    return _c("31", t)
def bold(t):   return _c("1",  t)
def dim(t):    return _c("2",  t)
def cyan(t):   return _c("36", t)

def ok(msg):   print(f"  {green('✓')} {msg}")
def fail(msg): print(f"  {red('✗')} {msg}")
def info(msg): print(f"  {dim('·')} {msg}")
def step(msg): print(f"  {cyan('→')} {msg}")


# ── Config helpers ──────────────────────────────────────────────────────────────
def load_config() -> dict:
    if not CONFIG_FILE.exists():
        return {}
    with open(CONFIG_FILE) as f:
        return json.load(f)


# ── Daemon control ─────────────────────────────────────────────────────────────
def daemon_running() -> bool:
    result = subprocess.run(
        ["launchctl", "list", "com.sol.daemon"],
        capture_output=True, text=True
    )
    return result.returncode == 0

def _launchctl(verb: str):
    if not PLIST.exists():
        fail(f"Plist not found at {PLIST} — run setup/install.sh first")
        sys.exit(1)
    subprocess.run(["launchctl", verb, str(PLIST)], check=False)


# ── Commands ───────────────────────────────────────────────────────────────────
def cmd_status(_args):
    cfg = load_config()

    print()
    print(bold("  Sol status"))
    print()

    # Daemon
    if daemon_running():
        ok(f"Daemon     {green('running')}  (port {cfg.get('daemon_port', 8765)})")
    else:
        fail(f"Daemon     {red('stopped')}")

    # Ollama
    result = subprocess.run(["ollama", "list"], capture_output=True, text=True)
    model = cfg.get("ollama_model", "qwen2.5:3b")
    if result.returncode == 0 and model in result.stdout:
        ok(f"Ollama     {green('running')}  model={model}")
    else:
        fail(f"Ollama     {red('not running or model missing')}")

    # Tailscale
    ts = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True)
    if ts.returncode == 0:
        ip = ts.stdout.strip()
        ok(f"Tailscale  {green('connected')}  IP={ip}")
    else:
        fail(f"Tailscale  {red('not connected')}")

    # Vault note count
    vault_path = cfg.get("vault_path")
    if vault_path:
        notes = list(Path(vault_path).rglob("*.md"))
        info(f"Vault      {len(notes)} notes  ({vault_path})")
    else:
        info(f"Vault      {dim('unknown — config missing')}")

    print()


def cmd_start(_args):
    if daemon_running():
        info("Daemon is already running")
        return
    step("Starting daemon…")
    _launchctl("load")
    ok("Daemon started")


def cmd_stop(_args):
    if not daemon_running():
        info("Daemon is not running")
        return
    step("Stopping daemon…")
    _launchctl("unload")
    ok("Daemon stopped")


def cmd_restart(_args):
    step("Restarting daemon…")
    _launchctl("unload")
    _launchctl("load")
    ok("Daemon restarted")


def cmd_logs(_args):
    if not LOG_FILE.exists():
        fail(f"Log file not found: {LOG_FILE}")
        sys.exit(1)
    print(dim(f"  Tailing {LOG_FILE}  (Ctrl-C to exit)\n"))
    os.execlp("tail", "tail", "-f", str(LOG_FILE))


def cmd_update(_args):
    step("Pulling latest changes…")
    subprocess.run(["git", "-C", str(REPO_DIR), "pull"], check=True)

    step("Updating Python dependencies…")
    # Install solidrag first — it's a local editable package and must be installed
    # before the rest of the daemon deps reference it.
    subprocess.run(
        [str(VENV_PYTHON), "-m", "pip", "install", "--quiet", "-e",
         str(REPO_DIR / "packages/solidrag")],
        check=True,
    )
    req = REPO_DIR / "daemon/requirements.txt"
    subprocess.run(
        [str(VENV_PYTHON), "-m", "pip", "install", "--quiet", "--upgrade", "-r", str(req)],
        cwd=str(REPO_DIR / "daemon"),
        check=True,
    )

    step("Re-copying CLI shim…")
    _install_shim()

    cmd_restart(None)
    ok("Update complete")


def cmd_index_images(_args):
    """Find unindexed images, describe them with the vision model, and add to the index."""
    import os
    import numpy as np

    cfg = load_config()
    vault_path = cfg.get("vault_path")
    if not vault_path:
        fail("vault_path not set in config")
        sys.exit(1)

    try:
        from pathlib import Path as _Path
        import sys as _sys
        _sys.path.insert(0, str(REPO_DIR / "packages/solidrag"))
        from solidrag import SolidRagConfig
        from solidrag.index.manifest import IndexManifest
        from solidrag.index.nodestore import NodeStore
        from solidrag.index.builder import (
            _embed_nodes, _node_id_to_int, _vault_rel_path, _IMAGE_EXTENSIONS,
            cleanup_deleted_images,
        )
        from solidrag.extractors.image import ImageExtractor
        import faiss
        import httpx
    except ImportError as e:
        fail(f"Could not import solidrag or dependencies: {e}")
        fail("Run: sol update")
        sys.exit(1)

    solidrag_cfg = SolidRagConfig(
        source_dirs=[_Path(vault_path)],
        ollama_base_url=cfg.get("ollama_base_url", "http://localhost:11434"),
        ollama_model=cfg.get("ollama_model", "qwen2.5:3b"),
        vision_model=cfg.get("vision_model", "llava"),
    )

    persist_dir = _Path(solidrag_cfg.persist_dir)
    faiss_path  = persist_dir / "solidrag.faiss"

    if not faiss_path.exists():
        fail("FAISS index not found — start the daemon first to build the initial index")
        sys.exit(1)

    manifest  = IndexManifest(persist_dir / "manifest.json")
    nodestore = NodeStore(persist_dir / "nodestore.json")
    manifest.load()
    nodestore.load()
    faiss_index = faiss.read_index(str(faiss_path))

    # ── Prune deleted images ─────────────────────────────────────────────────
    step("Checking for deleted images to prune…")
    removed = cleanup_deleted_images(faiss_index, manifest, nodestore)
    if removed:
        for r in removed:
            info(f"  Pruned: {_Path(r).name}")
        faiss.write_index(faiss_index, str(faiss_path))
        manifest.save()
        nodestore.save()
        ok(f"Pruned {len(removed)} deleted image(s)")
    else:
        ok("Nothing to prune")

    # ── Find unindexed images ────────────────────────────────────────────────
    step("Scanning for unindexed images…")
    unindexed: list[str] = []
    for dirpath, _dirs, filenames in os.walk(vault_path):
        for filename in filenames:
            if _Path(filename).suffix.lower() in _IMAGE_EXTENSIONS:
                full = str(_Path(dirpath) / filename)
                if manifest.get(full) is None:
                    unindexed.append(full)

    if not unindexed:
        ok("No unindexed images found — nothing to do")
        return

    info(f"Found {len(unindexed)} unindexed image(s)")
    print()

    # ── Load vision model ────────────────────────────────────────────────────
    vision_model = solidrag_cfg.vision_model
    step(f"Loading vision model ({vision_model})…")
    try:
        # Send a minimal warmup request so Ollama loads the model weights before
        # we start processing images — avoids timeout on the first real request.
        httpx.post(
            f"{solidrag_cfg.ollama_base_url}/api/generate",
            json={"model": vision_model, "prompt": "hi", "stream": False},
            timeout=120.0,
        ).raise_for_status()
        ok(f"Model loaded")
    except Exception as e:
        fail(f"Could not load vision model '{vision_model}': {e}")
        fail("Is Ollama running and the model pulled?  Try: ollama pull " + vision_model)
        sys.exit(1)

    # ── Extract + embed + index ──────────────────────────────────────────────
    print()
    img_extractor = ImageExtractor(
        ollama_base_url=solidrag_cfg.ollama_base_url,
        vision_model=vision_model,
    )

    indexed_files  = 0
    indexed_nodes  = 0

    for filepath in unindexed:
        fname = _Path(filepath).name
        step(f"Describing {fname}…")
        try:
            nodes = img_extractor.extract(_Path(filepath))
        except Exception as e:
            fail(f"  Vision extraction failed: {e}")
            continue

        if not nodes:
            info(f"  No content extracted — skipping")
            continue

        try:
            embeddings = _embed_nodes(nodes, solidrag_cfg)
        except Exception as e:
            fail(f"  Embedding failed: {e}")
            continue

        ids = np.array([_node_id_to_int(n.node_id) for n in nodes], dtype=np.int64)
        faiss_index.add_with_ids(embeddings, ids)

        try:
            mtime = os.path.getmtime(filepath)
        except OSError:
            mtime = 0.0

        manifest.update(filepath, mtime, [n.node_id for n in nodes])
        rel = _vault_rel_path(filepath, solidrag_cfg)
        for node in nodes:
            nodestore.add(node.node_id, node.get_content(), rel)

        indexed_files += 1
        indexed_nodes += len(nodes)
        ok(f"  {fname}  ({len(nodes)} node(s))")

    # ── Persist ──────────────────────────────────────────────────────────────
    if indexed_files:
        print()
        step("Saving index…")
        faiss.write_index(faiss_index, str(faiss_path))
        manifest.save()
        nodestore.save()
        ok(f"Indexed {indexed_files} image(s), {indexed_nodes} node(s) total")

        # Reload the daemon so it picks up the updated index
        step("Reloading daemon…")
        _launchctl("unload")
        _launchctl("load")
        ok("Daemon reloaded — images are now searchable")
    else:
        info("No images were successfully indexed")

    # ── Unload vision model ──────────────────────────────────────────────────
    print()
    step("Unloading vision model from memory…")
    try:
        httpx.post(
            f"{solidrag_cfg.ollama_base_url}/api/generate",
            json={"model": vision_model, "keep_alive": 0},
            timeout=10.0,
        )
        ok("Vision model unloaded")
    except Exception:
        info("Could not explicitly unload model (will expire from Ollama cache naturally)")

    print()


def cmd_config(_args):
    if not CONFIG_FILE.exists():
        fail(f"Config not found: {CONFIG_FILE}")
        sys.exit(1)
    editor = os.environ.get("EDITOR", "nano")
    os.execlp(editor, editor, str(CONFIG_FILE))


def cmd_uninstall(_args):
    uninstall_sh = SCRIPT_DIR / "uninstall.sh"
    if not uninstall_sh.exists():
        fail(f"uninstall.sh not found at {uninstall_sh}")
        sys.exit(1)
    os.execlp("bash", "bash", str(uninstall_sh))


def cmd_qr(_args):
    cfg = load_config()
    ts = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True)
    if ts.returncode != 0:
        fail("Tailscale is not connected — cannot generate QR")
        sys.exit(1)

    ip       = ts.stdout.strip()
    port     = cfg.get("daemon_port", 8765)
    api_key  = cfg.get("daemon_api_key", "")
    out_file = CONFIG_DIR / "sol-connect.png"

    subprocess.run([
        str(VENV_PYTHON), str(SCRIPT_DIR / "qr_generate.py"),
        "--host", ip, "--port", str(port), f"--api-key={api_key}",
        "--output", str(out_file), "--terminal"
    ], check=True)


def cmd_notify(args):
    if len(args) < 2:
        fail("Usage: sol notify <title> <body> [info|warning|update]")
        sys.exit(1)
    title = args[0]
    body  = args[1]
    kind  = args[2] if len(args) > 2 else "info"

    cfg  = load_config()
    port = cfg.get("daemon_port", 8765)
    key  = cfg.get("daemon_api_key", "")

    payload = json.dumps({"title": title, "body": body, "type": kind}).encode()
    req = urllib.request.Request(
        f"http://localhost:{port}/api/notify",
        data=payload,
        headers={"X-API-Key": key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5):
            pass
        ok(f"Notification queued — bring the app to foreground to receive it")
        info(f"Title: {title}")
        info(f"Body:  {body}")
        info(f"Type:  {kind}")
    except urllib.error.URLError as e:
        fail(f"Could not reach daemon: {e}")
        sys.exit(1)


def cmd_update_ios(_args):
    print()
    step("Checking for iOS updates…")

    local_version = VERSION_FILE.read_text().strip() if VERSION_FILE.exists() else "unknown"

    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/aranga1/Sol/releases/latest",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "sol-cli"}
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read())
    except (urllib.error.URLError, OSError):
        fail("Could not reach GitHub — check your internet connection")
        sys.exit(1)

    latest_tag = data.get("tag_name", "")
    latest_ver = latest_tag.lstrip("v")

    print()
    if latest_ver and latest_ver != local_version:
        print(f"  {yellow('Update available')}  {dim(local_version)} → {green(latest_ver)}")
    elif latest_ver:
        print(f"  {green('Up to date')}  {dim(local_version)}")
    else:
        print(f"  {dim('Could not determine latest version')}")

    # Find manifest.plist asset
    assets = {a["name"]: a["browser_download_url"] for a in data.get("assets", [])}
    manifest_url = assets.get("manifest.plist")

    print()
    if manifest_url:
        ota_url = f"itms-services://?action=download-manifest&url={manifest_url}"
        print(f"  {bold('OTA install URL:')}")
        print(f"    {cyan(ota_url)}")
        print()

        # Render terminal QR via qrcode if available in venv
        out_file = CONFIG_DIR / "sol-ios-update.png"
        result = subprocess.run([
            str(VENV_PYTHON), str(SCRIPT_DIR / "qr_generate.py"),
            "--url", ota_url,
            "--label", f"Install Sol {latest_tag} on iPhone",
            "--output", str(out_file),
            "--terminal"
        ], check=False)
        if result.returncode == 0:
            info(f"QR saved to {out_file}")
    else:
        info("No manifest.plist in this release — visit GitHub Releases to install manually")

    print(f"  {dim('Releases page: https://github.com/aranga1/Sol/releases/latest')}")
    print()


# ── Shim installer (called by install.sh + sol update) ──────────────────────
def _install_shim():
    shim_dir = Path.home() / ".local/bin"
    shim_dir.mkdir(parents=True, exist_ok=True)
    shim = shim_dir / "sol"
    shim.write_text(f"""#!/usr/bin/env bash
exec "{VENV_PYTHON}" "{Path(__file__).resolve()}" "$@"
""")
    shim.chmod(0o755)
    return shim


def cmd_install_shim(_args):
    shim = _install_shim()
    ok(f"Shim installed at {shim}")
    info(f"Add {shim.parent} to your PATH if not already present:")
    info(f'  export PATH="$HOME/.local/bin:$PATH"')


# ── Help ───────────────────────────────────────────────────────────────────────
USAGE = f"""\
{bold('sol')} — manage your Sol second brain

{bold('USAGE')}
  sol <command> [options]

{bold('COMMANDS')}
  {cyan('status')}        Show daemon, Ollama, Tailscale, and vault state
  {cyan('start')}         Start the daemon
  {cyan('stop')}          Stop the daemon
  {cyan('restart')}       Restart the daemon
  {cyan('logs')}          Tail the daemon log  (~/.sol/daemon.log)
  {cyan('update')}        Pull latest code, update deps, restart daemon
  {cyan('config')}        Open config.json in $EDITOR
  {cyan('uninstall')}     Run the uninstall script
  {cyan('qr')}            Regenerate the iPhone connection QR code
  {cyan('notify')}        Queue a notification to your iPhone  (title body [type])
  {cyan('update-ios')}    Check for a new iOS app release and show install QR
  {cyan('index-images')}  Describe unindexed images with the vision model and add to index

{bold('OPTIONS')}
  -h, --help    Show this help message
"""


# ── Dispatch ───────────────────────────────────────────────────────────────────
COMMANDS = {
    "status":       cmd_status,
    "start":        cmd_start,
    "stop":         cmd_stop,
    "restart":      cmd_restart,
    "logs":         cmd_logs,
    "update":       cmd_update,
    "config":       cmd_config,
    "uninstall":    cmd_uninstall,
    "qr":           cmd_qr,
    "notify":       cmd_notify,
    "update-ios":   cmd_update_ios,
    "index-images": cmd_index_images,
    "_install-shim": cmd_install_shim,  # called by install.sh
}

def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(USAGE)
        return
    cmd = args[0]
    if cmd not in COMMANDS:
        fail(f"Unknown command: {cmd}")
        print(f"  Run {bold('sol --help')} for usage.")
        sys.exit(1)
    COMMANDS[cmd](args[1:])

if __name__ == "__main__":
    main()
