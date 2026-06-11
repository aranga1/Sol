import importlib
import json

import pytest
from unittest.mock import AsyncMock, patch
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
    monkeypatch.setenv("ALYSHA_CONFIG", str(config_file))
    # Patch at the source so the reload picks up the mock
    with patch("daemon.obsidian_client.ObsidianClient") as MockClient:
        instance = MockClient.return_value
        instance.health = AsyncMock(return_value=True)
        instance.note_count = AsyncMock(return_value=5)
        instance.close = AsyncMock()
        import daemon.main as dm
        importlib.reload(dm)
        with TestClient(dm.app) as c:
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
    monkeypatch.setenv("ALYSHA_CONFIG", str(config_file))
    with patch("daemon.obsidian_client.ObsidianClient") as MockClient:
        instance = MockClient.return_value
        instance.health = AsyncMock(return_value=False)
        instance.close = AsyncMock()
        import daemon.main as dm
        importlib.reload(dm)
        with TestClient(dm.app) as c:
            resp = c.get("/api/health")
            assert resp.status_code == 503
            assert resp.json()["status"] == "degraded"
