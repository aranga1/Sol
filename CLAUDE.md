# Sol — Claude Code Notes

## Architecture

Sol is a personal RAG-based second-brain. Three tiers:
- **Daemon** (`daemon/`) — FastAPI server on macOS. Manages the FAISS index, runs background watchers, serves queries via SSE streaming.
- **solidRag** (`packages/solidrag/`) — Local Python package. Contains all indexing, retrieval, and query logic. Installed editable into `~/.sol/venv`.
- **iOS app** (`ios/Sol/`) — SwiftUI iPad/iPhone client. Connects to the daemon over Tailscale.

## Critical: Two Venvs

There are **two separate Python virtual environments**. Only one matters for the running daemon:

| Venv | Used by | How to install |
|---|---|---|
| `~/.sol/venv` | **LaunchAgent daemon (production)** | `~/.sol/venv/bin/pip install -e packages/solidrag/.` |
| `packages/solidrag/.venv` | Local pytest / dev tools | `cd packages/solidrag && source .venv/bin/activate` |

**When making Python changes**, always install into `~/.sol/venv` before restarting:
```bash
~/.sol/venv/bin/pip install -e packages/solidrag/. && sol restart
```
Running `pip install` against `.venv` only does NOT update the running daemon.

## Critical: One Daemon

There must be **only one daemon process**. The LaunchAgent (`~/Library/LaunchAgents/com.sol.daemon.plist`) is the authoritative one — it binds to `0.0.0.0:8765` so iOS can reach it via Tailscale.

**Never** start a second daemon with `python -m uvicorn daemon.main:app` — it binds to `localhost:8765` only, creating a second process that intercepts your curl tests but not iOS traffic. This caused many hours of debugging: code changes appeared to work locally but iOS always hit the old daemon.

**Correct restart workflow:**
```bash
sol restart        # bounce the LaunchAgent daemon
sol update         # pull + reinstall solidrag + restart (use after git pull)
```

Verify only one process is running:
```bash
lsof -i :8765 | grep LISTEN   # should show exactly one entry with TCP *:8765
```

## iOS ↔ Daemon Connection

iOS connects via **Tailscale** to the Mac's Tailscale IP on port 8765. Always test daemon changes via the Tailscale IP, not localhost:
```bash
curl -s http://$(tailscale ip -4):8765/api/health
```

## Calendar Integration

### How calendar indexing works
1. `CalendarWatcher` polls EventKit every 60s → `CalendarExtractor.sync()` → `IndexDiff`
2. `apply_source_diff()` in `builder.py` writes vectors to FAISS **and** content to `NodeStore`
3. NodeStore is required for retrieval — FAISS only stores vectors; content lookup goes through NodeStore
4. On-demand: `sol index-calendar` triggers immediate sync via `POST /api/index-calendar`

### Calendar RAG retrieval
Calendar queries bypass FAISS semantic search entirely. Semantic similarity is poor for date-based queries ("tomorrow" doesn't embed close to "Flag Day 14 June 2026"). Instead:
- Queries containing calendar/event/meeting/appointment/schedule/tomorrow/today/this week/next week → pull all calendar events from NodeStore directly (deduplicated by `file_path`)
- Time-relative terms (tomorrow, today, this week) → pre-filter to the matching date window
- Relative terms (tomorrow → "Sunday 14 June 2026") are rewritten to absolute dates before passing to LLM
- Today's date is injected into the system prompt for calendar queries

### Calendar event creation
- Backend: `_is_calendar_action()` in `query/engine.py` detects intent → emits `{"type": "action", "action": "create_event", "payload": {...}}` SSE event
- iOS: `QueryViewModel.ask()` parses action SSE → sets `vm.pendingCalendarPayload` → `.onChange` requests calendar access → `.sheet(isPresented:)` presents `CalendarEditorSheet` (`UIViewControllerRepresentable`)
- `CreateEventPayload` is in `QueryResponse.swift` (not `CalendarModels.swift`) — required by `@Observable` macro visibility
- LLM sometimes omits timezone in `start` field (e.g. `"2026-06-14T12:00:00"`). `CreateEventPayload` decoder falls back to `DateFormatter` with `"yyyy-MM-dd'T'HH:mm:ss"` treating it as local time

### NodeStore write bug (fixed)
`apply_source_diff()` initially only wrote to FAISS, not NodeStore. Calendar events would be in the FAISS index but retrieval always returned empty because `_retrieve()` discards results where `nodestore.get_content(nid)` is nil. Fixed by adding `nodestore.add()` inside `apply_source_diff()`.

## Test Commands

```bash
# Python tests
cd packages/solidrag && source .venv/bin/activate && python -m pytest tests/ -v

# Test query via Tailscale (what iOS hits)
KEY=$(python3 -c "import json; print(json.load(open('/Users/aakashranga/.sol/config.json'))['daemon_api_key'])")
curl -s -N -X POST http://$(tailscale ip -4):8765/api/query \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"question":"What calendar events do I have tomorrow?"}'

# Force immediate calendar index
sol index-calendar

# Check NodeStore has calendar content
~/.sol/venv/bin/python -c "
from solidrag.index.nodestore import NodeStore
from solidrag.config import SolidRagConfig
from daemon.config import load_config
import pathlib
cfg = load_config()
sc = SolidRagConfig(source_dirs=[], ollama_base_url=cfg.ollama_base_url, ollama_model=cfg.ollama_model)
ns = NodeStore(pathlib.Path(sc.persist_dir) / 'nodestore.json'); ns.load()
cal = set(ns.get_file_path(n) for n in ns.all_node_ids() if (ns.get_file_path(n) or '').startswith('calendar:'))
print(f'Unique calendar events in NodeStore: {len(cal)}')
"
```

## iOS Build Notes

- `EventKit.framework` and `EventKitUI.framework` are **linked but not embedded** — system frameworks must never be in the Embed Frameworks build phase or the build will fail with "did not contain an Info.plist"
- `NSCalendarsFullAccessUsageDescription` is required on iOS 17+ alongside the legacy `NSCalendarsUsageDescription`
- `CreateEventPayload` must be in a file that's guaranteed to compile before `QueryView.swift` uses it in an `@Observable` property — it lives in `QueryResponse.swift` for this reason
- `EKEventEditViewDelegate` callback arrives on the main thread; `nonisolated(unsafe)` on the closure property in `CalendarEditorSheet.Coordinator` is correct and safe
