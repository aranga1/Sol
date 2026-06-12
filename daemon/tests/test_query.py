import json
import pytest
from unittest.mock import AsyncMock, patch, MagicMock
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
    with patch("daemon.main.ObsidianClient") as MockObs, \
         patch("daemon.main.build_index") as mock_build, \
         patch("daemon.main.VaultWatcher") as MockWatcher:
        mock_build.return_value = MagicMock()  # mock index
        mock_watcher = MockWatcher.return_value
        mock_watcher.start = MagicMock()
        mock_watcher.stop = MagicMock()
        inst = MockObs.return_value
        inst.health = AsyncMock(return_value=True)
        inst.note_count = AsyncMock(return_value=5)
        inst.close = AsyncMock()
        from daemon.main import app
        with TestClient(app) as c:
            yield c


def test_query_returns_answer_and_sources(client):
    with patch("daemon.routes.query.rag_query") as mock_q:
        mock_q.return_value = ("The answer.", [{"file": "Notes/test.md", "title": "Test Note"}])
        resp = client.post(
            "/api/query",
            json={"question": "What did I write?"},
            headers={"X-API-Key": "testkey123"},
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data["answer"] == "The answer."
    assert len(data["sources"]) == 1
    assert data["sources"][0]["title"] == "Test Note"


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
    app.state.vault_index = None
    resp = client.post(
        "/api/query",
        json={"question": "test"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 503
