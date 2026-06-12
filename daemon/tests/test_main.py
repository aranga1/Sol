import json
import os
import pytest
from pathlib import Path
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
    from daemon.main import app
    with TestClient(app) as c:
        yield c


def test_health_no_auth_returns_200(client):
    response = client.get("/api/health")
    # Health route is exempt from auth middleware
    assert response.status_code != 401


def test_protected_route_no_key_returns_401(client):
    response = client.post("/api/note", json={})
    assert response.status_code == 401


def test_protected_route_wrong_key_returns_401(client):
    response = client.post("/api/note", json={}, headers={"X-API-Key": "wrongkey"})
    assert response.status_code == 401
