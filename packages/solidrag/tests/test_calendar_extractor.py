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


# ---------------------------------------------------------------------------
# Task 4: CalendarExtractor tests
# ---------------------------------------------------------------------------

from unittest.mock import MagicMock
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
