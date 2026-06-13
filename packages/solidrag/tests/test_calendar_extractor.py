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
