# Calendar Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read iCloud Calendar events into the RAG index and let the agent create calendar events from natural language via iOS's native EKEventEditViewController.

**Architecture:** solidRag gains a `SourceExtractor` protocol and `IndexDiff` dataclass for non-file sources; `CalendarExtractor` polls macOS EventKit every 60s via PyObjC; the query engine adds `_is_calendar_action()` to detect creation intent and emit a structured `create_event` SSE action; iOS `CalendarService` presents `EKEventEditViewController` pre-populated from the payload.

**Tech Stack:** PyObjC (`pyobjc-framework-EventKit`), EventKit (macOS + iOS), SwiftUI, `EKEventEditViewController`, existing solidRag FAISS + Ollama stack.

---

## File Map

**New files:**
- `packages/solidrag/solidrag/extractors/calendar.py` — `CalendarExtractor` (SourceExtractor)
- `packages/solidrag/solidrag/index/calendar_watcher.py` — 60s poll loop
- `packages/solidrag/tests/test_calendar_extractor.py`
- `packages/solidrag/tests/test_calendar_watcher.py`
- `packages/solidrag/tests/test_calendar_action.py`
- `ios/Sol/Services/CalendarService.swift`
- `ios/Sol/Models/CalendarModels.swift`

**Modified files:**
- `packages/solidrag/solidrag/extractors/base.py` — add `SourceExtractor`, `IndexDiff`
- `packages/solidrag/solidrag/index/manifest.py` — add source namespace methods
- `packages/solidrag/solidrag/index/builder.py` — add `apply_source_diff()`
- `packages/solidrag/solidrag/query/engine.py` — add `_is_calendar_action()`, update `query_stream_async`
- `packages/solidrag/solidrag/__init__.py` — export `CalendarWatcher`
- `packages/solidrag/pyproject.toml` — add `pyobjc-framework-EventKit`
- `daemon/main.py` — start/stop `CalendarWatcher`
- `ios/Sol/Views/QueryView.swift` — handle `create_event` action SSE event

---

## Task 1: Add SourceExtractor protocol and IndexDiff to solidRag

**Files:**
- Modify: `packages/solidrag/solidrag/extractors/base.py`
- Test: `packages/solidrag/tests/test_calendar_extractor.py` (create, will grow across tasks)

- [ ] **Step 1: Write the failing test**

```python
# packages/solidrag/tests/test_calendar_extractor.py
from solidrag.extractors.base import IndexDiff, SourceExtractor
from llama_index.core.schema import TextNode


def test_index_diff_defaults():
    diff = IndexDiff()
    assert diff.to_add == []
    assert diff.to_update == []
    assert diff.to_delete == []


def test_index_diff_populated():
    node = TextNode(text="Event: Meeting")
    diff = IndexDiff(to_add=[node], to_delete=["old-id"])
    assert len(diff.to_add) == 1
    assert diff.to_delete == ["old-id"]


def test_source_extractor_protocol_structural():
    """Any class with source_id and sync() satisfies the protocol."""

    class FakeSource:
        source_id = "test"

        def sync(self, manifest):
            return IndexDiff()

    assert isinstance(FakeSource(), SourceExtractor)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py -v
```
Expected: `ImportError` — `IndexDiff` and `SourceExtractor` not defined yet.

- [ ] **Step 3: Add IndexDiff and SourceExtractor to base.py**

Append to `packages/solidrag/solidrag/extractors/base.py`:

```python
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:
    from llama_index.core.schema import TextNode
    from solidrag.index.manifest import IndexManifest


@runtime_checkable
class Extractor(Protocol):
    supported_extensions: frozenset[str]

    def extract(self, path: Path) -> "list[TextNode]": ...


@dataclass
class IndexDiff:
    """Describes changes to apply to the FAISS index from a SourceExtractor sync."""

    to_add: "list[TextNode]" = field(default_factory=list)
    to_update: "list[tuple[list[str], list[TextNode]]]" = field(default_factory=list)
    to_delete: list[str] = field(default_factory=list)


@runtime_checkable
class SourceExtractor(Protocol):
    """Protocol for non-file-based RAG sources (calendar, email, etc.)."""

    source_id: str

    def sync(self, manifest: "IndexManifest") -> IndexDiff: ...
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py -v
```
Expected: 3 PASSED.

- [ ] **Step 5: Commit**

```bash
git add packages/solidrag/solidrag/extractors/base.py packages/solidrag/tests/test_calendar_extractor.py
git commit -m "feat(solidrag): add SourceExtractor protocol and IndexDiff dataclass"
```

---

## Task 2: Extend IndexManifest with source namespace support

**Files:**
- Modify: `packages/solidrag/solidrag/index/manifest.py`
- Test: `packages/solidrag/tests/test_calendar_extractor.py`

- [ ] **Step 1: Write failing tests**

Append to `packages/solidrag/tests/test_calendar_extractor.py`:

```python
from solidrag.index.manifest import IndexManifest
import tempfile, pathlib


def _tmp_manifest() -> IndexManifest:
    tmp = pathlib.Path(tempfile.mkdtemp()) / "manifest.json"
    m = IndexManifest(tmp)
    m.load()
    return m


def test_source_namespace_get_empty():
    m = _tmp_manifest()
    assert m.get_source("calendar", "evt-1") is None


def test_source_namespace_update_and_get():
    m = _tmp_manifest()
    m.update_source("calendar", "evt-1", mtime=1000.0, node_ids=["n1", "n2"])
    entry = m.get_source("calendar", "evt-1")
    assert entry is not None
    assert entry.mtime == 1000.0
    assert entry.node_ids == ["n1", "n2"]


def test_source_namespace_remove():
    m = _tmp_manifest()
    m.update_source("calendar", "evt-1", mtime=1000.0, node_ids=["n1"])
    m.remove_source("calendar", "evt-1")
    assert m.get_source("calendar", "evt-1") is None


def test_source_namespace_all_keys():
    m = _tmp_manifest()
    m.update_source("calendar", "evt-1", mtime=1.0, node_ids=[])
    m.update_source("calendar", "evt-2", mtime=2.0, node_ids=[])
    assert m.all_source_keys("calendar") == {"evt-1", "evt-2"}


def test_source_namespace_persists_across_load(tmp_path):
    path = tmp_path / "manifest.json"
    m = IndexManifest(path)
    m.load()
    m.update_source("calendar", "evt-1", mtime=42.0, node_ids=["x"])
    m.save()

    m2 = IndexManifest(path)
    m2.load()
    entry = m2.get_source("calendar", "evt-1")
    assert entry is not None
    assert entry.mtime == 42.0
    assert entry.node_ids == ["x"]
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py::test_source_namespace_get_empty -v
```
Expected: `AttributeError` — `IndexManifest` has no `get_source`.

- [ ] **Step 3: Add source namespace methods to IndexManifest**

Add to `packages/solidrag/solidrag/index/manifest.py`, after the existing `all_paths` method:

```python
    # ------------------------------------------------------------------
    # Source namespace (non-file sources: calendar, email, etc.)
    # ------------------------------------------------------------------

    def get_source(self, source_id: str, key: str) -> ManifestEntry | None:
        """Return the entry for *key* within *source_id* namespace, or None."""
        return self._sources.get(source_id, {}).get(key)

    def update_source(
        self, source_id: str, key: str, mtime: float, node_ids: list[str]
    ) -> None:
        """Insert or replace *key* within *source_id* namespace."""
        if source_id not in self._sources:
            self._sources[source_id] = {}
        self._sources[source_id][key] = ManifestEntry(
            mtime=mtime, node_ids=list(node_ids)
        )

    def remove_source(self, source_id: str, key: str) -> None:
        """Remove *key* from *source_id* namespace (no-op if absent)."""
        if source_id in self._sources:
            self._sources[source_id].pop(key, None)

    def all_source_keys(self, source_id: str) -> set[str]:
        """Return all keys tracked under *source_id*."""
        return set(self._sources.get(source_id, {}).keys())
```

Also update `__init__` to initialise `_sources`, and update `load`/`save` to persist it:

```python
    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._entries: dict[str, ManifestEntry] = {}
        self._sources: dict[str, dict[str, ManifestEntry]] = {}

    def load(self) -> None:
        if not self._path.exists():
            self._entries = {}
            self._sources = {}
            return
        try:
            raw = self._path.read_text(encoding="utf-8")
            data: dict = json.loads(raw)
            self._entries = {
                filepath: ManifestEntry(
                    mtime=float(entry["mtime"]),
                    node_ids=list(entry.get("node_ids", [])),
                )
                for filepath, entry in data.get("files", data).items()
                if isinstance(entry, dict) and "mtime" in entry
            }
            raw_sources = data.get("sources", {})
            self._sources = {
                source_id: {
                    key: ManifestEntry(
                        mtime=float(e["mtime"]),
                        node_ids=list(e.get("node_ids", [])),
                    )
                    for key, e in entries.items()
                }
                for source_id, entries in raw_sources.items()
            }
        except (json.JSONDecodeError, KeyError, ValueError, TypeError):
            self._entries = {}
            self._sources = {}

    def save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "files": {
                filepath: {"mtime": entry.mtime, "node_ids": entry.node_ids}
                for filepath, entry in self._entries.items()
            },
            "sources": {
                source_id: {
                    key: {"mtime": e.mtime, "node_ids": e.node_ids}
                    for key, e in entries.items()
                }
                for source_id, entries in self._sources.items()
            },
        }
        tmp_fd, tmp_name = tempfile.mkstemp(dir=self._path.parent, suffix=".tmp")
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as fh:
                json.dump(data, fh, indent=2)
            os.replace(tmp_name, self._path)
        except Exception:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py -v
```
Expected: all PASSED.

- [ ] **Step 5: Confirm existing manifest tests still pass**

```bash
cd packages/solidrag && python -m pytest tests/test_index.py -v
```
Expected: all PASSED (the `files` key in the new JSON format is backwards-compatible with the flat structure via the `data.get("files", data)` fallback).

- [ ] **Step 6: Commit**

```bash
git add packages/solidrag/solidrag/index/manifest.py packages/solidrag/tests/test_calendar_extractor.py
git commit -m "feat(solidrag): add source namespace to IndexManifest for non-file sources"
```

---

## Task 3: Add apply_source_diff() to builder

**Files:**
- Modify: `packages/solidrag/solidrag/index/builder.py`
- Test: `packages/solidrag/tests/test_calendar_extractor.py`

- [ ] **Step 1: Write failing test**

Append to `packages/solidrag/tests/test_calendar_extractor.py`:

```python
import numpy as np
import faiss
from unittest.mock import patch, MagicMock
from solidrag.index.builder import apply_source_diff, _node_id_to_int
from solidrag.extractors.base import IndexDiff


def _make_index() -> faiss.IndexIDMap2:
    inner = faiss.IndexFlatL2(768)
    return faiss.IndexIDMap2(inner)


def test_apply_source_diff_adds_nodes(tmp_path):
    faiss_index = _make_index()
    manifest_path = tmp_path / "manifest.json"
    from solidrag.index.manifest import IndexManifest
    manifest = IndexManifest(manifest_path)
    manifest.load()

    node = MagicMock()
    node.node_id = "test-node-1"
    node.get_content.return_value = "Event: Meeting"

    diff = IndexDiff(to_add=[node])

    embedding = np.random.rand(768).astype(np.float32)
    with patch("solidrag.index.builder._embed_nodes", return_value=embedding.reshape(1, -1)):
        from solidrag.config import SolidRagConfig
        config = SolidRagConfig(
            source_dirs=[], ollama_base_url="http://localhost:11434", ollama_model="qwen2.5:3b"
        )
        apply_source_diff(faiss_index, manifest, diff, "calendar", "evt-1", mtime=1.0, config=config)

    assert faiss_index.ntotal == 1
    assert manifest.get_source("calendar", "evt-1") is not None


def test_apply_source_diff_deletes_nodes(tmp_path):
    faiss_index = _make_index()
    manifest_path = tmp_path / "manifest.json"
    from solidrag.index.manifest import IndexManifest
    manifest = IndexManifest(manifest_path)
    manifest.load()

    # Pre-populate a node
    node_id = "test-node-del"
    vec = np.random.rand(768).astype(np.float32).reshape(1, -1)
    int_id = np.array([_node_id_to_int(node_id)], dtype=np.int64)
    faiss_index.add_with_ids(vec, int_id)
    manifest.update_source("calendar", "evt-del", mtime=1.0, node_ids=[node_id])

    diff = IndexDiff(to_delete=[node_id])
    apply_source_diff(faiss_index, manifest, diff, "calendar", "evt-del", mtime=1.0,
                      config=None, delete_keys=["evt-del"])

    assert faiss_index.ntotal == 0
    assert manifest.get_source("calendar", "evt-del") is None
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py::test_apply_source_diff_adds_nodes -v
```
Expected: `ImportError` — `apply_source_diff` not defined.

- [ ] **Step 3: Add apply_source_diff to builder.py**

Append to `packages/solidrag/solidrag/index/builder.py`:

```python
def apply_source_diff(
    faiss_index: faiss.IndexIDMap2,
    manifest: IndexManifest,
    diff: "IndexDiff",
    source_id: str,
    source_key: str,
    mtime: float,
    config: "SolidRagConfig | None",
    delete_keys: list[str] | None = None,
) -> None:
    """Apply an IndexDiff from a SourceExtractor to the live FAISS index.

    Args:
        faiss_index:  The live index to mutate.
        manifest:     The manifest to update.
        diff:         The diff returned by SourceExtractor.sync().
        source_id:    Namespace key (e.g. "calendar").
        source_key:   Individual item key (e.g. event ID) for to_add entries.
        mtime:        Last-modified timestamp for the source item.
        config:       SolidRagConfig (required when diff.to_add is non-empty).
        delete_keys:  Source keys to remove from manifest (for deleted items).
    """
    from solidrag.extractors.base import IndexDiff

    # Remove deleted nodes
    all_delete_ids: list[str] = list(diff.to_delete)
    for old_ids, _ in diff.to_update:
        all_delete_ids.extend(old_ids)
    for key in (delete_keys or []):
        entry = manifest.get_source(source_id, key)
        if entry:
            all_delete_ids.extend(entry.node_ids)
            manifest.remove_source(source_id, key)

    if all_delete_ids:
        ids = np.array([_node_id_to_int(nid) for nid in all_delete_ids], dtype=np.int64)
        try:
            faiss_index.remove_ids(ids)
        except Exception:
            logger.exception("apply_source_diff: failed to remove ids for %s/%s", source_id, source_key)

    # Add new nodes
    new_nodes = list(diff.to_add)
    for _, nodes in diff.to_update:
        new_nodes.extend(nodes)

    if new_nodes and config is not None:
        try:
            embeddings = _embed_nodes(new_nodes, config)
            ids = np.array([_node_id_to_int(n.node_id) for n in new_nodes], dtype=np.int64)
            faiss_index.add_with_ids(embeddings, ids)
            manifest.update_source(source_id, source_key, mtime, [n.node_id for n in new_nodes])
        except Exception:
            logger.exception("apply_source_diff: embedding failed for %s/%s", source_id, source_key)
```

Add `from __future__ import annotations` to the top import block if not already present, and add `"IndexDiff"` and `"SolidRagConfig"` to `TYPE_CHECKING` imports.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py -v
```
Expected: all PASSED.

- [ ] **Step 5: Commit**

```bash
git add packages/solidrag/solidrag/index/builder.py packages/solidrag/tests/test_calendar_extractor.py
git commit -m "feat(solidrag): add apply_source_diff() for SourceExtractor integration"
```

---

## Task 4: Implement CalendarExtractor

**Files:**
- Create: `packages/solidrag/solidrag/extractors/calendar.py`
- Test: `packages/solidrag/tests/test_calendar_extractor.py`

- [ ] **Step 1: Write failing tests**

Append to `packages/solidrag/tests/test_calendar_extractor.py`:

```python
from unittest.mock import MagicMock, patch, PropertyMock
from solidrag.extractors.calendar import CalendarExtractor, _format_event


def _make_mock_event(
    event_id="evt-1",
    title="Team Standup",
    start_ts=1749823800.0,
    end_ts=1749827400.0,
    location="Zoom",
    notes="Daily sync",
    attendee_names=("Alice", "Bob"),
    last_modified_ts=1749823000.0,
):
    event = MagicMock()
    event.eventIdentifier.return_value = event_id
    event.title.return_value = title
    start = MagicMock()
    start.timeIntervalSince1970.return_value = start_ts
    end = MagicMock()
    end.timeIntervalSince1970.return_value = end_ts
    event.startDate.return_value = start
    event.endDate.return_value = end
    event.location.return_value = location
    event.notes.return_value = notes
    attendees = []
    for name in attendee_names:
        a = MagicMock()
        a.name.return_value = name
        attendees.append(a)
    event.attendees.return_value = attendees
    lm = MagicMock()
    lm.timeIntervalSince1970.return_value = last_modified_ts
    event.lastModifiedDate.return_value = lm
    return event


def test_format_event_includes_title():
    event = _make_mock_event(title="Budget Review")
    text = _format_event(event)
    assert "Budget Review" in text


def test_format_event_includes_attendees():
    event = _make_mock_event(attendee_names=("Alice", "Bob"))
    text = _format_event(event)
    assert "Alice" in text
    assert "Bob" in text


def test_format_event_includes_location():
    event = _make_mock_event(location="Room 4B")
    text = _format_event(event)
    assert "Room 4B" in text


def test_format_event_no_location_when_none():
    event = _make_mock_event(location=None)
    text = _format_event(event)
    assert "Location" not in text


def test_sync_detects_new_event(tmp_path):
    manifest_path = tmp_path / "manifest.json"
    from solidrag.index.manifest import IndexManifest
    manifest = IndexManifest(manifest_path)
    manifest.load()

    mock_event = _make_mock_event()

    extractor = CalendarExtractor.__new__(CalendarExtractor)
    extractor._authorized = True
    extractor._store = MagicMock()
    extractor._fetch_events = MagicMock(return_value=[mock_event])

    diff = extractor.sync(manifest)
    assert len(diff.to_add) == 1
    assert "Team Standup" in diff.to_add[0].get_content()


def test_sync_detects_deleted_event(tmp_path):
    manifest_path = tmp_path / "manifest.json"
    from solidrag.index.manifest import IndexManifest
    manifest = IndexManifest(manifest_path)
    manifest.load()
    manifest.update_source("calendar", "evt-gone", mtime=1.0, node_ids=["old-node"])

    extractor = CalendarExtractor.__new__(CalendarExtractor)
    extractor._authorized = True
    extractor._fetch_events = MagicMock(return_value=[])

    diff = extractor.sync(manifest)
    assert "old-node" in diff.to_delete


def test_sync_detects_modified_event(tmp_path):
    manifest_path = tmp_path / "manifest.json"
    from solidrag.index.manifest import IndexManifest
    manifest = IndexManifest(manifest_path)
    manifest.load()
    manifest.update_source("calendar", "evt-1", mtime=999.0, node_ids=["old-node"])

    mock_event = _make_mock_event(last_modified_ts=1000.0)
    extractor = CalendarExtractor.__new__(CalendarExtractor)
    extractor._authorized = True
    extractor._fetch_events = MagicMock(return_value=[mock_event])

    diff = extractor.sync(manifest)
    assert len(diff.to_update) == 1
    old_ids, new_nodes = diff.to_update[0]
    assert "old-node" in old_ids
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py::test_format_event_includes_title -v
```
Expected: `ModuleNotFoundError` — `solidrag.extractors.calendar` not found.

- [ ] **Step 3: Implement CalendarExtractor**

Create `packages/solidrag/solidrag/extractors/calendar.py`:

```python
"""CalendarExtractor — reads macOS iCloud Calendar events via PyObjC EventKit.

Implements the SourceExtractor protocol. Polls EKEventStore for events in a
rolling 90-day window (past and future). Returns an IndexDiff describing new,
modified, and deleted events relative to the IndexManifest.
"""
from __future__ import annotations

import logging
import threading
from datetime import datetime
from typing import TYPE_CHECKING

from llama_index.core.schema import TextNode

from solidrag.extractors.base import IndexDiff

if TYPE_CHECKING:
    from solidrag.index.manifest import IndexManifest

logger = logging.getLogger(__name__)

_90_DAYS_S: float = 90 * 24 * 3600.0


def _format_event(event) -> str:
    """Format an EKEvent-like object into a dense, embeddable text block."""
    title = event.title() or "Untitled"

    start_ts = event.startDate().timeIntervalSince1970()
    end_ts = event.endDate().timeIntervalSince1970()
    start_dt = datetime.fromtimestamp(start_ts)
    end_dt = datetime.fromtimestamp(end_ts)

    date_str = start_dt.strftime("%A %d %B %Y")
    time_str = (
        f"{start_dt.strftime('%I:%M%p').lstrip('0')} – "
        f"{end_dt.strftime('%I:%M%p').lstrip('0')}"
    )

    parts = [f"Event: {title}", f"Date: {date_str}, {time_str}"]

    if location := event.location():
        parts.append(f"Location: {location}")

    if attendees := event.attendees():
        names = [a.name() for a in attendees if a.name()]
        if names:
            parts.append(f"Attendees: {', '.join(names)}")

    if notes := event.notes():
        stripped = notes.strip()
        if stripped:
            parts.append(f"Notes: {stripped}")

    return "\n".join(parts)


class CalendarExtractor:
    """SourceExtractor for macOS Calendar via EventKit (PyObjC).

    Authorization is requested once at init time. If the user denies access
    or PyObjC is unavailable, sync() returns an empty IndexDiff and logs a
    warning — it never raises.
    """

    source_id: str = "calendar"

    def __init__(self) -> None:
        self._store = None
        self._authorized = False
        self._init_store()

    def _init_store(self) -> None:
        try:
            import EventKit  # type: ignore[import]

            store = EventKit.EKEventStore.alloc().init()
            done = threading.Event()
            result: list[bool] = [False]

            def _callback(granted, _error):
                result[0] = bool(granted)
                done.set()

            store.requestAccessToEntityType_completion_(
                EventKit.EKEntityTypeEvent, _callback
            )
            done.wait(timeout=30)

            if result[0]:
                self._store = store
                self._authorized = True
            else:
                logger.warning("CalendarExtractor: calendar access denied by user")
        except Exception as exc:
            logger.warning("CalendarExtractor: could not initialise EventKit: %s", exc)

    def _fetch_events(self) -> list:
        import EventKit  # type: ignore[import]
        from Foundation import NSDate  # type: ignore[import]

        if not self._authorized or self._store is None:
            return []

        self._store.refreshSourcesIfNecessary()
        start = NSDate.dateWithTimeIntervalSinceNow_(-_90_DAYS_S)
        end = NSDate.dateWithTimeIntervalSinceNow_(_90_DAYS_S)
        predicate = self._store.predicateForEventsWithStartDate_endDate_calendars_(
            start, end, None
        )
        events = self._store.eventsMatchingPredicate_(predicate)
        return list(events) if events else []

    def sync(self, manifest: IndexManifest) -> IndexDiff:
        """Diff EventKit against the manifest and return an IndexDiff."""
        diff = IndexDiff()

        try:
            events = self._fetch_events()
        except Exception as exc:
            logger.warning("CalendarExtractor: fetch failed: %s", exc)
            return diff

        existing = {
            key: manifest.get_source(self.source_id, key)
            for key in manifest.all_source_keys(self.source_id)
        }
        current_ids: set[str] = set()

        for event in events:
            event_id = event.eventIdentifier()
            if not event_id:
                continue
            current_ids.add(event_id)

            lm_date = event.lastModifiedDate()
            last_modified = lm_date.timeIntervalSince1970() if lm_date else 0.0

            prev = existing.get(event_id)
            if prev is None:
                node = TextNode(
                    text=_format_event(event),
                    metadata={"source": "calendar", "event_id": event_id},
                )
                node.excluded_llm_metadata_keys = ["source", "event_id"]
                diff.to_add.append(node)
                manifest.update_source(
                    self.source_id, event_id, last_modified, [node.node_id]
                )
            elif prev.mtime != last_modified:
                node = TextNode(
                    text=_format_event(event),
                    metadata={"source": "calendar", "event_id": event_id},
                )
                node.excluded_llm_metadata_keys = ["source", "event_id"]
                diff.to_update.append((list(prev.node_ids), [node]))
                manifest.update_source(
                    self.source_id, event_id, last_modified, [node.node_id]
                )

        for event_id, entry in existing.items():
            if event_id not in current_ids:
                if entry:
                    diff.to_delete.extend(entry.node_ids)
                manifest.remove_source(self.source_id, event_id)

        return diff
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_extractor.py -v
```
Expected: all PASSED.

- [ ] **Step 5: Commit**

```bash
git add packages/solidrag/solidrag/extractors/calendar.py packages/solidrag/tests/test_calendar_extractor.py
git commit -m "feat(solidrag): implement CalendarExtractor with EventKit + IndexDiff sync"
```

---

## Task 5: Implement CalendarWatcher

**Files:**
- Create: `packages/solidrag/solidrag/index/calendar_watcher.py`
- Test: `packages/solidrag/tests/test_calendar_watcher.py`

- [ ] **Step 1: Write failing tests**

```python
# packages/solidrag/tests/test_calendar_watcher.py
import time
from unittest.mock import MagicMock, patch
from solidrag.index.calendar_watcher import CalendarWatcher
from solidrag.extractors.base import IndexDiff
from solidrag.index.manifest import IndexManifest
import tempfile, pathlib


def _tmp_manifest():
    path = pathlib.Path(tempfile.mkdtemp()) / "manifest.json"
    m = IndexManifest(path)
    m.load()
    return m


def test_calendar_watcher_calls_on_diff_when_changes(tmp_path):
    manifest = _tmp_manifest()
    calls = []

    mock_extractor = MagicMock()
    from llama_index.core.schema import TextNode
    node = TextNode(text="Event: Meeting")
    mock_extractor.sync.return_value = IndexDiff(to_add=[node])
    mock_extractor.source_id = "calendar"

    watcher = CalendarWatcher(
        manifest=manifest,
        on_diff_ready=lambda diff: calls.append(diff),
        poll_interval=0,  # fire immediately
        _extractor=mock_extractor,
    )
    watcher.start()
    time.sleep(0.1)
    watcher.stop()

    assert len(calls) >= 1
    assert len(calls[0].to_add) == 1


def test_calendar_watcher_skips_empty_diff(tmp_path):
    manifest = _tmp_manifest()
    calls = []

    mock_extractor = MagicMock()
    mock_extractor.sync.return_value = IndexDiff()
    mock_extractor.source_id = "calendar"

    watcher = CalendarWatcher(
        manifest=manifest,
        on_diff_ready=lambda diff: calls.append(diff),
        poll_interval=0,
        _extractor=mock_extractor,
    )
    watcher.start()
    time.sleep(0.1)
    watcher.stop()

    assert calls == []


def test_calendar_watcher_stops_cleanly(tmp_path):
    manifest = _tmp_manifest()
    mock_extractor = MagicMock()
    mock_extractor.sync.return_value = IndexDiff()

    watcher = CalendarWatcher(
        manifest=manifest,
        on_diff_ready=lambda _: None,
        poll_interval=60,
        _extractor=mock_extractor,
    )
    watcher.start()
    watcher.stop()
    assert not watcher._thread.is_alive()
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_watcher.py -v
```
Expected: `ModuleNotFoundError`.

- [ ] **Step 3: Implement CalendarWatcher**

Create `packages/solidrag/solidrag/index/calendar_watcher.py`:

```python
"""CalendarWatcher — polls CalendarExtractor every N seconds and applies diffs.

Runs on a background daemon thread. Calls CalendarExtractor.sync() on each
tick and invokes on_diff_ready only when the diff is non-empty.
"""
from __future__ import annotations

import logging
import threading
from typing import Callable, TYPE_CHECKING

from solidrag.extractors.calendar import CalendarExtractor
from solidrag.extractors.base import IndexDiff

if TYPE_CHECKING:
    from solidrag.index.manifest import IndexManifest

logger = logging.getLogger(__name__)


class CalendarWatcher:
    """Background thread that polls EKEventStore and emits IndexDiff on change.

    Args:
        manifest:      The shared IndexManifest (mutated by CalendarExtractor.sync).
        on_diff_ready: Callback invoked with an IndexDiff when changes detected.
        poll_interval: Seconds between polls (default 60).
        _extractor:    Injectable CalendarExtractor (for tests).
    """

    def __init__(
        self,
        manifest: IndexManifest,
        on_diff_ready: Callable[[IndexDiff], None],
        poll_interval: int = 60,
        _extractor: CalendarExtractor | None = None,
    ) -> None:
        self._manifest = manifest
        self._on_diff_ready = on_diff_ready
        self._poll_interval = poll_interval
        self._extractor = _extractor or CalendarExtractor()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        logger.info("CalendarWatcher started (interval=%ds)", self._poll_interval)

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        logger.info("CalendarWatcher stopped")

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                diff = self._extractor.sync(self._manifest)
                if diff.to_add or diff.to_update or diff.to_delete:
                    self._on_diff_ready(diff)
            except Exception:
                logger.exception("CalendarWatcher: sync error")
            self._stop_event.wait(self._poll_interval)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_watcher.py -v
```
Expected: all PASSED.

- [ ] **Step 5: Commit**

```bash
git add packages/solidrag/solidrag/index/calendar_watcher.py packages/solidrag/tests/test_calendar_watcher.py
git commit -m "feat(solidrag): implement CalendarWatcher background poll thread"
```

---

## Task 6: Add _is_calendar_action to query engine

**Files:**
- Modify: `packages/solidrag/solidrag/query/engine.py`
- Modify: `packages/solidrag/solidrag/query/prompts.py`
- Test: `packages/solidrag/tests/test_calendar_action.py`

- [ ] **Step 1: Write failing tests**

```python
# packages/solidrag/tests/test_calendar_action.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch


@pytest.mark.asyncio
async def test_is_calendar_action_detected():
    from solidrag.query.engine import _is_calendar_action

    mock_result = MagicMock()
    mock_result.__str__ = lambda self: (
        '{"is_calendar_action": true, "event": {"title": "Call with John",'
        ' "start": "2026-06-14T15:00:00", "duration_minutes": 30, "notes": ""}}'
    )

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)
        mock_llm_fn.return_value = mock_llm

        is_action, payload = await _is_calendar_action("schedule a call with John tomorrow at 3pm")

    assert is_action is True
    assert payload["title"] == "Call with John"
    assert payload["duration_minutes"] == 30


@pytest.mark.asyncio
async def test_is_calendar_action_not_detected():
    from solidrag.query.engine import _is_calendar_action

    mock_result = MagicMock()
    mock_result.__str__ = lambda self: '{"is_calendar_action": false, "event": null}'

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)
        mock_llm_fn.return_value = mock_llm

        is_action, payload = await _is_calendar_action("what is the capital of France?")

    assert is_action is False
    assert payload is None


@pytest.mark.asyncio
async def test_is_calendar_action_malformed_json_returns_false():
    from solidrag.query.engine import _is_calendar_action

    mock_result = MagicMock()
    mock_result.__str__ = lambda self: "not json at all"

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)
        mock_llm_fn.return_value = mock_llm

        is_action, payload = await _is_calendar_action("book a meeting")

    assert is_action is False
    assert payload is None


@pytest.mark.asyncio
async def test_query_stream_emits_create_event_action():
    from solidrag.query.engine import query_stream_async

    mock_index = MagicMock()

    calendar_json = (
        '{"is_calendar_action": true, "event": {"title": "Dentist",'
        ' "start": "2026-06-15T10:00:00", "duration_minutes": 60, "notes": ""}}'
    )
    vault_json = "NO"

    call_count = [0]

    async def fake_acomplete(prompt):
        call_count[0] += 1
        result = MagicMock()
        if "CREATE" in prompt or "calendar" in prompt.lower():
            result.__str__ = lambda self: calendar_json
        else:
            result.__str__ = lambda self: vault_json
        return result

    async def fake_astream_complete(prompt):
        async def _gen():
            chunk = MagicMock()
            chunk.delta = "Sure, I'll set that up."
            yield chunk
        return _gen()

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = fake_acomplete
        mock_llm.astream_complete = fake_astream_complete
        mock_llm_fn.return_value = mock_llm

        events = []
        async for event in query_stream_async(mock_index, "book a dentist appointment next Monday at 10am"):
            events.append(event)

    types = [e["type"] for e in events]
    assert "action" in types
    action_event = next(e for e in events if e["type"] == "action")
    assert action_event["action"] == "create_event"
    assert action_event["payload"]["title"] == "Dentist"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_action.py -v
```
Expected: `ImportError` — `_is_calendar_action` not defined.

- [ ] **Step 3: Add CALENDAR_ACTION_PROMPT to prompts.py**

Append to `packages/solidrag/solidrag/query/prompts.py`:

```python
CALENDAR_ACTION_PROMPT = """\
Does the following message ask to CREATE a new calendar event, meeting, \
appointment, or reminder?
Today's date is {today}.
If yes, extract the event details. Default duration to 60 minutes if not specified.
Reply with valid JSON only — no markdown fences:

{{
  "is_calendar_action": true or false,
  "event": {{
    "title": "string or null",
    "start": "ISO8601 datetime string or null",
    "duration_minutes": number or null,
    "notes": "string or null"
  }}
}}

Message: {question}"""
```

- [ ] **Step 4: Add _is_calendar_action and update query_stream_async in engine.py**

Add this function to `packages/solidrag/solidrag/query/engine.py` (before `query_stream_async`):

```python
import json
from datetime import date as _date

from solidrag.query.prompts import CALENDAR_ACTION_PROMPT


async def _is_calendar_action(question: str) -> tuple[bool, dict | None]:
    """Classify whether the question is a calendar event creation request.

    Returns (True, event_dict) if detected, (False, None) otherwise.
    Never raises — malformed LLM output returns (False, None).
    """
    prompt = CALENDAR_ACTION_PROMPT.format(
        today=_date.today().isoformat(),
        question=question,
    )
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    text = str(result).strip()

    # Strip markdown fences if the model wrapped the JSON
    if text.startswith("```"):
        parts = text.split("```")
        text = parts[1] if len(parts) > 1 else text
        if text.startswith("json"):
            text = text[4:].strip()

    try:
        data = json.loads(text)
        if data.get("is_calendar_action") and isinstance(data.get("event"), dict):
            return True, data["event"]
        return False, None
    except (json.JSONDecodeError, AttributeError):
        return False, None
```

Update `query_stream_async` to call `_is_calendar_action` and emit the action event. Add the `import asyncio` at the top of `engine.py` if not present, then modify `query_stream_async`:

```python
async def query_stream_async(
    index,
    question: str,
    history: list[dict] | None = None,
    top_k: int = 8,
    system_prompt: str | None = None,
) -> AsyncGenerator[dict, None]:
    if index is None:
        yield {"type": "token", "content": "Index not ready — try again in a moment."}
        yield {"type": "sources", "sources": []}
        yield {"type": "done"}
        return

    # Run intent checks concurrently
    needs_vault_task = asyncio.create_task(_needs_vault_async(question))
    calendar_task = asyncio.create_task(_is_calendar_action(question))
    needs_vault = await needs_vault_task
    is_calendar, event_payload = await calendar_task

    if not needs_vault:
        prompt = build_direct_prompt(question, history)
        llm = _get_llm()
        async for chunk in await llm.astream_complete(prompt):
            if chunk.delta:
                yield {"type": "token", "content": chunk.delta}
        yield {"type": "sources", "sources": []}
    else:
        retriever = index.as_retriever(similarity_top_k=top_k)
        nodes = await retriever.aretrieve(question)
        sources = await _extract_relevant_sources(nodes)
        context_parts = [node.get_content() for node in nodes]
        context_str = "\n\n---\n\n".join(context_parts)

        _default_system = (
            "You are Sol, a personal second-brain assistant. "
            "Answer the user's question using the relevant notes provided. "
            "Cite specific details from the notes where helpful."
        )

        prompt = build_rag_prompt(
            system_prompt or _default_system,
            context_str,
            question,
            history,
        )
        llm = _get_llm()
        async for chunk in await llm.astream_complete(prompt):
            if chunk.delta:
                yield {"type": "token", "content": chunk.delta}
        yield {"type": "sources", "sources": sources}

    if is_calendar and event_payload:
        yield {
            "type": "action",
            "action": "create_event",
            "payload": event_payload,
        }

    yield {"type": "done"}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd packages/solidrag && python -m pytest tests/test_calendar_action.py tests/test_query.py -v
```
Expected: all PASSED.

- [ ] **Step 6: Commit**

```bash
git add packages/solidrag/solidrag/query/engine.py packages/solidrag/solidrag/query/prompts.py packages/solidrag/tests/test_calendar_action.py
git commit -m "feat(solidrag): add _is_calendar_action intent detection and create_event SSE action"
```

---

## Task 7: Wire CalendarWatcher into daemon and add pyobjc dependency

**Files:**
- Modify: `packages/solidrag/pyproject.toml`
- Modify: `daemon/main.py`
- Modify: `packages/solidrag/solidrag/__init__.py`

- [ ] **Step 1: Add pyobjc-framework-EventKit to solidRag dependencies**

In `packages/solidrag/pyproject.toml`, add to `dependencies`:

```toml
"pyobjc-framework-EventKit>=10.0; sys_platform == 'darwin'",
```

- [ ] **Step 2: Export CalendarWatcher from solidrag public API**

In `packages/solidrag/solidrag/__init__.py`, add:

```python
from solidrag.index.calendar_watcher import CalendarWatcher
```

And add `"CalendarWatcher"` to `__all__`.

- [ ] **Step 3: Wire CalendarWatcher into daemon/main.py**

In `daemon/main.py`, add import:

```python
from solidrag import CalendarWatcher
from solidrag.index.builder import apply_source_diff
```

In the lifespan block, after `SourceWatcher` is started, add:

```python
    # Apply calendar diffs to the live index
    def _on_calendar_diff(diff):
        from solidrag.index.builder import apply_source_diff
        import time
        # Apply each batch of changes - to_add items keyed by their first node_id
        for node in diff.to_add:
            apply_source_diff(
                app.state.vault_index_faiss,
                app.state.manifest,
                diff.__class__(to_add=[node]),
                source_id="calendar",
                source_key=node.metadata.get("event_id", node.node_id),
                mtime=time.time(),
                config=solid_config,
            )
        # Deletions
        if diff.to_delete:
            from solidrag.index.builder import _node_id_to_int
            import numpy as np
            ids = np.array([_node_id_to_int(nid) for nid in diff.to_delete], dtype=np.int64)
            try:
                app.state.vault_index_faiss.remove_ids(ids)
            except Exception as e:
                print(f"[CalendarWatcher] remove_ids error: {e}")
        app.state.manifest.save()

    calendar_watcher = CalendarWatcher(
        manifest=app.state.manifest,
        on_diff_ready=_on_calendar_diff,
        poll_interval=60,
    )
    calendar_watcher.start()
    app.state.calendar_watcher = calendar_watcher
```

In the lifespan teardown (after `yield`), add:

```python
    app.state.calendar_watcher.stop()
```

- [ ] **Step 4: Reinstall solidrag to pick up new dependency**

```bash
cd packages/solidrag && pip install -e ".[dev]"
```

- [ ] **Step 5: Start daemon and verify no startup errors**

```bash
cd /Users/aakashranga/IN/Sol && python -m uvicorn daemon.main:app --port 8765
```

Expected output includes: `CalendarWatcher started (interval=60s)` — and on first run macOS may prompt for Calendar access.

- [ ] **Step 6: Commit**

```bash
git add packages/solidrag/pyproject.toml packages/solidrag/solidrag/__init__.py daemon/main.py
git commit -m "feat(daemon): wire CalendarWatcher into lifespan and add pyobjc-framework-EventKit"
```

---

## Task 8: iOS — CalendarModels and CalendarService

**Files:**
- Create: `ios/Sol/Models/CalendarModels.swift`
- Create: `ios/Sol/Services/CalendarService.swift`

- [ ] **Step 1: Add EventKit to iOS target**

In Xcode: select the Sol target → General → Frameworks, Libraries, and Embedded Content → + → EventKit.framework.

In `ios/Sol/Info.plist`, add:

```xml
<key>NSCalendarsUsageDescription</key>
<string>Sol needs calendar access to create events on your behalf.</string>
```

- [ ] **Step 2: Create CalendarModels.swift**

```swift
// ios/Sol/Models/CalendarModels.swift
import Foundation

struct CreateEventPayload: Decodable {
    let title: String
    let start: Date
    let durationMinutes: Int
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title, start, notes
        case durationMinutes = "duration_minutes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)

        let startString = try container.decode(String.self, forKey: .start)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: startString) {
            start = date
        } else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: startString) {
                start = date
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .start, in: container,
                    debugDescription: "Cannot parse date: \(startString)"
                )
            }
        }
    }
}
```

- [ ] **Step 3: Create CalendarService.swift**

```swift
// ios/Sol/Services/CalendarService.swift
import EventKit
import EventKitUI
import UIKit

@MainActor
final class CalendarService: NSObject {
    static let shared = CalendarService()
    private let store = EKEventStore()
    private var onResult: ((Bool) -> Void)?

    func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func presentEventEditor(
        payload: CreateEventPayload,
        from viewController: UIViewController,
        onResult: @escaping (Bool) -> Void
    ) {
        self.onResult = onResult

        let event = EKEvent(eventStore: store)
        event.title = payload.title
        event.startDate = payload.start
        event.endDate = payload.start.addingTimeInterval(
            TimeInterval(payload.durationMinutes * 60)
        )
        if let notes = payload.notes, !notes.isEmpty {
            event.notes = notes
        }
        event.calendar = store.defaultCalendarForNewEvents

        let editVC = EKEventEditViewController()
        editVC.eventStore = store
        editVC.event = event
        editVC.editViewDelegate = self
        viewController.present(editVC, animated: true)
    }
}

extension CalendarService: EKEventEditViewDelegate {
    nonisolated func eventEditViewController(
        _ controller: EKEventEditViewController,
        didCompleteWith action: EKEventEditViewAction
    ) {
        let saved = action == .saved
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.onResult?(saved)
            self.onResult = nil
        }
    }
}
```

- [ ] **Step 4: Build the iOS target to verify no compile errors**

In Xcode: Product → Build (⌘B). Expected: Build Succeeded with no errors.

- [ ] **Step 5: Commit**

```bash
git add ios/Sol/Models/CalendarModels.swift ios/Sol/Services/CalendarService.swift ios/Sol/Info.plist
git commit -m "feat(ios): add CalendarModels and CalendarService with EKEventEditViewController"
```

---

## Task 9: iOS — Handle create_event action in QueryView

**Files:**
- Modify: `ios/Sol/Views/QueryView.swift`

- [ ] **Step 1: Find the SSE event handler in QueryView.swift**

Locate the section in `QueryView.swift` where SSE events are parsed — look for `"type"` key parsing and `"token"`, `"sources"`, `"done"` handling. This is in the streaming response handler.

- [ ] **Step 2: Add state for calendar action**

Add to `QueryView`'s `@State` properties:

```swift
@State private var pendingCalendarPayload: CreateEventPayload? = nil
@State private var showCalendarEditor = false
@State private var eventNotCreated = false
```

- [ ] **Step 3: Handle action event in SSE parser**

In the SSE event parsing switch/if block, add:

```swift
} else if type == "action", let action = event["action"] as? String, action == "create_event" {
    if let payloadDict = event["payload"],
       let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict),
       let payload = try? JSONDecoder().decode(CreateEventPayload.self, from: payloadData) {
        await MainActor.run {
            pendingCalendarPayload = payload
            showCalendarEditor = true
        }
    }
}
```

- [ ] **Step 4: Present EKEventEditViewController and handle result**

Add to `QueryView`'s body (or as a modifier on the root view):

```swift
.onChange(of: showCalendarEditor) { _, showing in
    guard showing, let payload = pendingCalendarPayload else { return }
    Task { @MainActor in
        let granted = await CalendarService.shared.requestAccess()
        guard granted else {
            showCalendarEditor = false
            return
        }
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        CalendarService.shared.presentEventEditor(
            payload: payload,
            from: rootVC
        ) { saved in
            showCalendarEditor = false
            pendingCalendarPayload = nil
            if !saved { eventNotCreated = true }
        }
    }
}
```

- [ ] **Step 5: Show "Event not created" message when cancelled**

In the conversation message list, show a system message when `eventNotCreated` is true:

```swift
if eventNotCreated {
    Text("Event not created.")
        .font(.system(size: 14))
        .foregroundStyle(DS.inkFaint)
        .italic()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                eventNotCreated = false
            }
        }
}
```

- [ ] **Step 6: Build and test manually**

Build (⌘B). Connect to daemon via Tailscale. Ask: *"Schedule a team sync tomorrow at 2pm for 45 minutes."*

Expected:
1. LLM streams a short confirmation text
2. iOS Calendar permission prompt appears (first run only)
3. `EKEventEditViewController` slides up pre-populated with "Team sync", correct date/time
4. Tap Add → event appears in Calendar app
5. Ask Sol: *"When is my team sync?"* → Sol answers from indexed event (may take up to 60s for watcher to index it)

- [ ] **Step 7: Commit**

```bash
git add ios/Sol/Views/QueryView.swift
git commit -m "feat(ios): handle create_event SSE action and present EKEventEditViewController"
```
