# Calendar Integration — Design Spec

**Date:** 2026-06-13
**Status:** Approved
**Scope:** Group C of the Sol feature expansion — reading calendar events into RAG, creating events via agent

---

## Overview

Two capabilities:

1. **Calendar RAG**: Mac daemon reads iCloud Calendar events via EventKit (PyObjC), indexes them into solidRag for semantic search. Rolling window: past 90 days + next 90 days.
2. **Event creation**: When the user asks Sol to schedule something, the agent parses intent and structured data, returns an action payload to the iOS app, which presents the native `EKEventEditViewController` for user confirmation before writing to EventKit.

Google Calendar is supported for free — if the user has their Google account added to macOS System Settings → Internet Accounts, those calendars appear in Calendar.app and are accessible via EventKit with no extra work.

---

## 1. solidRag: SourceExtractor protocol

A second protocol is added to solidRag alongside the existing file-based `Extractor`. This handles live data sources (calendar, and later email) that are not backed by files on disk.

### Protocol definition

```python
class SourceExtractor(Protocol):
    source_id: str          # namespace in manifest, e.g. "calendar"

    def sync(self, manifest: IndexManifest) -> IndexDiff: ...
```

### IndexDiff

```python
@dataclass
class IndexDiff:
    to_add: list[TextNode]
    to_update: list[tuple[list[str], list[TextNode]]]  # (old_node_ids, new_nodes)
    to_delete: list[str]                                # node_ids to remove from FAISS
```

The index builder applies an `IndexDiff` under the asyncio lock — same pattern as incremental file reindexing. Hold time is milliseconds.

### IndexManifest extension

The manifest is namespaced by source type to keep file and calendar entries cleanly separated:

```json
{
  "files": {
    "uploads/pdf/26-13-06-14-30/report.pdf": {
      "mtime": 1749823800.0,
      "node_ids": ["abc123"]
    }
  },
  "calendar": {
    "EKEventID-abc123": {
      "last_modified": "2026-06-13T10:00:00Z",
      "node_ids": ["xyz789"]
    }
  }
}
```

`SourceExtractor` instances are registered in the `ExtractorRegistry` alongside file-based extractors. The index builder calls `sync()` on all registered `SourceExtractor` instances independently of the file walk.

---

## 2. solidRag: CalendarExtractor

**Location:** `solidrag/extractors/calendar.py`

Implements `SourceExtractor`. On `sync()`:

1. Queries `EKEventStore` for all events in the rolling window: `now − 90 days` → `now + 90 days`
2. Diffs against the `calendar` namespace in the manifest:
   - **New event** (ID not in manifest): extract → add to `to_add`
   - **Modified event** (ID in manifest, `last_modified` changed): add old node IDs to `to_update`, re-extract
   - **Deleted event** (ID in manifest, not returned by EventStore): add node IDs to `to_delete`
3. Returns `IndexDiff`

### TextNode format per event

```
Event: Q3 Planning
Date: Monday 15 June 2026, 2:00pm – 3:00pm
Location: Zoom
Attendees: John Smith, Sarah Lee
Notes: Discuss roadmap priorities
```

Dense, embeds well with nomic-embed-text. Event ID stored in manifest metadata, not in the node text.

---

## 3. solidRag: CalendarWatcher

**Location:** `solidrag/index/calendar_watcher.py`

Runs on a background thread. Two trigger paths:

- **EventKit notification**: subscribes to `EKEventStoreChangedNotification` via PyObjC. macOS posts this on any calendar change — event created, modified, or deleted. Triggers `CalendarExtractor.sync()` immediately.
- **60s fallback poll**: regardless of notifications, syncs every 60 seconds as a safety net. Matches the cadence of the existing `SourceWatcher` for markdown files.

Both paths apply the resulting `IndexDiff` under the asyncio lock. Queries are never blocked — the lock hold is milliseconds.

macOS will prompt the user for calendar access (TCC permission) the first time `EKEventStore` is accessed. This is handled by EventKit automatically.

---

## 4. solidRag: Query engine — calendar intent detection

**Location:** `solidrag/query/engine.py`

A new pre-classification step runs alongside the existing `_needs_vault()`:

```python
async def _is_calendar_action(question: str) -> tuple[bool, dict | None]
```

Uses a single structured LLM call with Ollama's JSON mode (`format: "json"`). The prompt asks the model to determine if the user wants to create a calendar event, and if so, extract structured fields:

```json
{
  "is_calendar_action": true,
  "event": {
    "title": "Call with John",
    "start": "2026-06-14T15:00:00",
    "duration_minutes": 30,
    "notes": ""
  }
}
```

Both `_needs_vault()` and `_is_calendar_action()` can be true simultaneously — e.g. "schedule a meeting about the project we discussed" requires vault retrieval for context AND produces a calendar action. The two checks are independent and non-exclusive.

If `is_calendar_action` is true, `query_stream_async` emits a new SSE event type before `done`:

```json
{
  "type": "action",
  "action": "create_event",
  "payload": {
    "title": "Call with John",
    "start": "2026-06-14T15:00:00",
    "duration_minutes": 30,
    "notes": ""
  }
}
```

The LLM still streams a short conversational confirmation as normal tokens before the action event fires. The action is additive — the text response is always present.

### Model note

qwen2.5:3b handles binary intent classification and structured extraction reliably for clear requests. Ambiguous inputs (relative dates, missing details) may produce imprecise extractions — the `EKEventEditViewController` confirmation step is the error budget. If the user upgrades to qwen2.5:7b, intent detection improves with no architecture changes.

---

## 5. Daemon changes

### New dependency

`pyobjc-framework-EventKit` added to daemon's `pyproject.toml`.

### daemon/main.py

`CalendarWatcher` started in the lifespan block alongside `SourceWatcher` and `ResourceAwareScheduler`:

```python
calendar_watcher = CalendarWatcher(on_diff_ready=apply_index_diff)
calendar_watcher.start()
app.state.calendar_watcher = calendar_watcher
```

Teardown: `calendar_watcher.stop()` called in the lifespan cleanup.

No new HTTP routes needed for calendar reading — it feeds directly into the existing index and query path.

---

## 6. iOS changes

### New framework

`EventKit` added to the iOS target in Xcode. `NSCalendarsUsageDescription` added to `Info.plist`.

### New service: CalendarService.swift

```swift
class CalendarService {
    static let shared = CalendarService()

    func requestAccess() async -> Bool
    func presentEventEditor(payload: CreateEventPayload, from viewController: UIViewController)
}

struct CreateEventPayload: Decodable {
    let title: String
    let start: Date
    let durationMinutes: Int
    let notes: String?
}
```

Calendar access is requested lazily — only when the first `create_event` action arrives, not on app launch. This avoids a permission prompt before the user has context for why Sol needs calendar access.

### QueryView changes

The SSE stream parser gains handling for `{"type": "action", "action": "create_event"}`:

1. Decode payload into `CreateEventPayload`
2. Build `EKEvent` pre-populated: title, start, end (start + durationMinutes), notes
3. Present `EKEventEditViewController` as a sheet over QueryView
4. Handle delegate callbacks:
   - **`.saved`**: dismiss sheet. No additional UI — the LLM's conversational text already streamed before the sheet appeared. On Mac, iCloud sync triggers `CalendarWatcher` within seconds and the event is indexed.
   - **`.canceled`**: dismiss sheet. Append a brief system message to the conversation thread: *"Event not created."* — keeps the conversation log accurate.

If the user edits event details in the native editor before confirming (e.g. corrects the time), the indexed version on Mac reflects the corrected event — CalendarWatcher reads from EventKit, not from the daemon's parsed payload. Corrections flow through automatically.

---

## 7. Data flows

### Calendar event read → RAG

```
CalendarWatcher: EKEventStoreChangedNotification fires (or 60s poll)
  → CalendarExtractor.sync(manifest)
  → EKEventStore query: now−90d to now+90d
  → diff against manifest["calendar"]
  → IndexDiff { to_add: [TextNode...], to_delete: [...] }
  → apply under asyncio.Lock
  → FAISS index updated, manifest updated
User query: "when is my next meeting with Sarah?"
  → _needs_vault() → YES
  → retriever finds CalendarTextNode
  → LLM answers from context
```

### Agent creates calendar event

```
User: "schedule a call with John tomorrow at 3pm"
  → _is_calendar_action() → true
  → structured extraction: {title, start, duration}
  → LLM streams: "Sure, I've set that up for you — check the details below."
  → SSE: {"type": "action", "action": "create_event", "payload": {...}}
iOS QueryView: decode payload → build EKEvent → present EKEventEditViewController
User: reviews, optionally edits, taps Add
  → EventKit creates event on device
  → iCloud syncs to Mac
  → CalendarWatcher fires → CalendarExtractor.sync() → event indexed
  → Sol can answer questions about the new event immediately
```

---

## 8. Performance

| Component | Idle cost | Active cost |
|---|---|---|
| CalendarWatcher thread | Sleeping | Wakes on notification or 60s tick |
| CalendarExtractor.sync() | — | EventKit query + manifest diff: ~10ms |
| TextNode embedding (new event) | — | ~50ms per event via nomic-embed-text |
| asyncio.Lock hold | — | Milliseconds |

Rolling window capped at 180 days total. A typical calendar has ~500–2000 events in this window — ~6MB of FAISS vectors. No memory concern on M1 Pro.

---

## 9. Error handling

| Failure | Behaviour |
|---|---|
| Calendar TCC permission denied (Mac) | CalendarWatcher logs warning, skips sync, retries on next poll |
| Calendar TCC permission denied (iOS) | CalendarService shows system alert directing user to Settings |
| EventKit query error | Logged, sync skipped, retries on next poll |
| LLM produces malformed JSON for intent | `_is_calendar_action` returns `(false, None)`, query proceeds normally as text |
| LLM extracts wrong date/time | User corrects in EKEventEditViewController before confirming |
| User cancels event creation | "Event not created." appended to conversation thread |
| iCloud sync delay | CalendarWatcher re-indexes once sync completes — no special handling needed |

---

## 10. Out of scope

- Deleting or modifying existing calendar events via agent
- Reading attendee availability / free-busy
- Recurring event creation
- Calendar event display in the Sol iOS UI (events are searchable via Q&A, not browsable)
- Google Calendar OAuth (covered by macOS account sync for free)
