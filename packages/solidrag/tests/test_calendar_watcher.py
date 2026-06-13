import time
from unittest.mock import MagicMock
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
