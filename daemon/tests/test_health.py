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
def config_file(tmp_path):
    p = tmp_path / "config.json"
    p.write_text(json.dumps(VALID_CONFIG))
    return p


@pytest.fixture
def client(config_file, monkeypatch):
    monkeypatch.setenv("SOL_CONFIG", str(config_file))
    mock_watcher = MagicMock()
    mock_watcher.start = MagicMock()
    mock_watcher.stop = MagicMock()
    mock_scheduler = MagicMock()
    mock_scheduler.start = MagicMock()
    mock_scheduler.stop = MagicMock()
    with patch("daemon.main.build_index", return_value=(MagicMock(), MagicMock())), \
         patch("daemon.main.configure_settings"), \
         patch("daemon.main.default_registry", return_value=MagicMock()), \
         patch("daemon.main.SourceWatcher", return_value=mock_watcher), \
         patch("daemon.main.ResourceAwareScheduler", return_value=mock_scheduler), \
         patch("daemon.main.FaissVectorStore", return_value=MagicMock()), \
         patch("daemon.main.StorageContext"), \
         patch("daemon.main.VectorStoreIndex", return_value=MagicMock()), \
         patch("daemon.main.ObsidianClient") as MockClient:
        instance = MockClient.return_value
        instance.health = AsyncMock(return_value=True)
        instance.note_count = AsyncMock(return_value=5)
        instance.close = AsyncMock()
        from daemon.main import app
        with TestClient(app) as c:
            yield c


def test_health_ok(client):
    resp = client.get("/api/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["vault_note_count"] == 5


def test_health_no_auth_required(client):
    # Health should work without X-API-Key header
    resp = client.get("/api/health")
    assert resp.status_code != 401


def test_health_degraded_when_obsidian_down(config_file, monkeypatch):
    monkeypatch.setenv("SOL_CONFIG", str(config_file))
    mock_watcher = MagicMock()
    mock_watcher.start = MagicMock()
    mock_watcher.stop = MagicMock()
    mock_scheduler = MagicMock()
    mock_scheduler.start = MagicMock()
    mock_scheduler.stop = MagicMock()
    with patch("daemon.main.build_index", return_value=(MagicMock(), MagicMock())), \
         patch("daemon.main.configure_settings"), \
         patch("daemon.main.default_registry", return_value=MagicMock()), \
         patch("daemon.main.SourceWatcher", return_value=mock_watcher), \
         patch("daemon.main.ResourceAwareScheduler", return_value=mock_scheduler), \
         patch("daemon.main.FaissVectorStore", return_value=MagicMock()), \
         patch("daemon.main.StorageContext"), \
         patch("daemon.main.VectorStoreIndex", return_value=MagicMock()), \
         patch("daemon.main.ObsidianClient") as MockClient:
        instance = MockClient.return_value
        instance.health = AsyncMock(return_value=False)
        instance.close = AsyncMock()
        from daemon.main import app
        with TestClient(app) as c:
            resp = c.get("/api/health")
            # Health route returns 200 with status="degraded" when Obsidian is down
            assert resp.status_code == 200
            assert resp.json()["status"] == "degraded"
