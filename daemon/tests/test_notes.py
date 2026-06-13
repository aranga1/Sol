import json
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from fastapi.testclient import TestClient

VALID_CONFIG = {
    "vault_path": "/tmp/vault",
    "daemon_port": 8765,
    "obsidian_api_key": "obskey",
    "obsidian_port": 27124,
    "daemon_api_key": "testkey123",
    "ollama_model": "phi3.5",
    "ollama_base_url": "http://localhost:11434",
}


@pytest.fixture
def client(tmp_path, monkeypatch):
    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps(VALID_CONFIG))
    monkeypatch.setenv("SOL_CONFIG", str(cfg))
    mock_faiss_idx = MagicMock()
    mock_manifest = MagicMock()
    mock_nodestore = MagicMock()
    mock_watcher = MagicMock()
    mock_watcher.start = MagicMock()
    mock_watcher.stop = MagicMock()
    mock_scheduler = MagicMock()
    mock_scheduler.start = MagicMock()
    mock_scheduler.stop = MagicMock()
    with patch("daemon.main.ObsidianClient") as MockObs, \
         patch("daemon.main.build_index", return_value=(mock_faiss_idx, mock_manifest, mock_nodestore)), \
         patch("daemon.main.configure_settings"), \
         patch("daemon.main.default_registry", return_value=MagicMock()), \
         patch("daemon.main.SourceWatcher", return_value=mock_watcher), \
         patch("daemon.main.ResourceAwareScheduler", return_value=mock_scheduler):
        inst = MockObs.return_value
        inst.health = AsyncMock(return_value=True)
        inst.note_count = AsyncMock(return_value=0)
        inst.create_note = AsyncMock(return_value="Notes/2026-06-11T10-00-00-text.md")
        inst.close = AsyncMock()
        from daemon.main import app
        with TestClient(app) as c:
            yield c


def test_create_text_note(client):
    resp = client.post(
        "/api/note",
        json={"content": "My thought", "source": "text"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 201
    assert "file_path" in resp.json()


def test_create_voice_note_with_title_and_tags(client):
    resp = client.post(
        "/api/note",
        json={
            "content": "Transcribed text",
            "title": "Meeting notes",
            "tags": ["work"],
            "source": "voice",
        },
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 201


def test_empty_content_returns_422(client):
    resp = client.post(
        "/api/note",
        json={"content": "   ", "source": "text"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 422


def test_invalid_source_returns_422(client):
    resp = client.post(
        "/api/note",
        json={"content": "hello", "source": "invalid"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 422


def test_missing_api_key_returns_401(client):
    resp = client.post("/api/note", json={"content": "hello", "source": "text"})
    assert resp.status_code == 401


def test_filename_format_includes_timestamp_and_source(client):
    import re

    resp = client.post(
        "/api/note",
        json={"content": "test", "source": "voice"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 201
    # The mock returns a fixed path; just confirm the call was made
    from daemon.main import app

    obsidian = app.state.obsidian
    filename_arg = obsidian.create_note.call_args[0][0]
    assert filename_arg.endswith("-voice.md")
    assert re.match(
        r"\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-voice\.md", filename_arg
    )
