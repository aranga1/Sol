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
    mock_watcher = MagicMock()
    mock_watcher.start = MagicMock()
    mock_watcher.stop = MagicMock()
    mock_scheduler = MagicMock()
    mock_scheduler.start = MagicMock()
    mock_scheduler.stop = MagicMock()
    mock_llama_idx = MagicMock()
    with patch("daemon.main.ObsidianClient") as MockObs, \
         patch("daemon.main.build_index", return_value=(mock_faiss_idx, mock_manifest)), \
         patch("daemon.main.configure_settings"), \
         patch("daemon.main.default_registry", return_value=MagicMock()), \
         patch("daemon.main.SourceWatcher", return_value=mock_watcher), \
         patch("daemon.main.ResourceAwareScheduler", return_value=mock_scheduler), \
         patch("daemon.main.FaissVectorStore", return_value=MagicMock()), \
         patch("daemon.main.StorageContext"), \
         patch("daemon.main.VectorStoreIndex", return_value=mock_llama_idx):
        inst = MockObs.return_value
        inst.health = AsyncMock(return_value=True)
        inst.note_count = AsyncMock(return_value=5)
        inst.close = AsyncMock()
        from daemon.main import app
        with TestClient(app) as c:
            yield c


async def _mock_stream(*_args, **_kwargs):
    """Async generator that mimics query_stream_async SSE events."""
    yield {"type": "token", "content": "The answer."}
    yield {"type": "sources", "sources": [{"file": "Notes/test.md", "title": "Test Note"}]}
    yield {"type": "done"}


def test_query_streams_tokens_and_sources(client):
    with patch("daemon.routes.query.query_stream_async", side_effect=_mock_stream):
        resp = client.post(
            "/api/query",
            json={"question": "What did I write?"},
            headers={"X-API-Key": "testkey123"},
        )
    assert resp.status_code == 200
    lines = [ln for ln in resp.text.splitlines() if ln.startswith("data:")]
    events = [json.loads(ln[len("data: "):]) for ln in lines]
    token_events = [e for e in events if e["type"] == "token"]
    source_events = [e for e in events if e["type"] == "sources"]
    done_events = [e for e in events if e["type"] == "done"]
    assert any("The answer." in e["content"] for e in token_events)
    assert len(source_events) == 1
    assert source_events[0]["sources"][0]["title"] == "Test Note"
    assert len(done_events) == 1


def test_query_empty_question_returns_422(client):
    resp = client.post(
        "/api/query",
        json={"question": ""},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 422


def test_query_missing_key_returns_401(client):
    resp = client.post("/api/query", json={"question": "anything"})
    assert resp.status_code == 401


def test_query_index_not_ready_returns_503(client):
    from daemon.main import app
    app.state.vault_index_llama = None
    resp = client.post(
        "/api/query",
        json={"question": "test"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 503
