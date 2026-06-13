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
