import json
import os
import pytest
from pathlib import Path

from daemon.config import Config, load_config

VALID_CONFIG = {
    "vault_path": "/Users/test/vault",
    "daemon_port": 8765,
    "obsidian_api_key": "obs-key-abc123",
    "obsidian_port": 27124,
    "daemon_api_key": "daemon-key-xyz789",
    "ollama_model": "llama3.2",
    "ollama_base_url": "http://localhost:11434",
}


def test_load_config_all_fields(tmp_path, monkeypatch):
    """load_config returns a Config with every field populated correctly."""
    config_file = tmp_path / "config.json"
    config_file.write_text(json.dumps(VALID_CONFIG))

    monkeypatch.setenv("ALYSHA_CONFIG", str(config_file))

    cfg = load_config()

    assert isinstance(cfg, Config)
    assert cfg.vault_path == VALID_CONFIG["vault_path"]
    assert cfg.daemon_port == VALID_CONFIG["daemon_port"]
    assert cfg.obsidian_api_key == VALID_CONFIG["obsidian_api_key"]
    assert cfg.obsidian_port == VALID_CONFIG["obsidian_port"]
    assert cfg.daemon_api_key == VALID_CONFIG["daemon_api_key"]
    assert cfg.ollama_model == VALID_CONFIG["ollama_model"]
    assert cfg.ollama_base_url == VALID_CONFIG["ollama_base_url"]


def test_load_config_missing_file(tmp_path, monkeypatch):
    """load_config raises SystemExit when the config file does not exist."""
    missing = tmp_path / "nonexistent.json"
    monkeypatch.setenv("ALYSHA_CONFIG", str(missing))

    with pytest.raises(SystemExit) as exc_info:
        load_config()

    assert str(missing) in str(exc_info.value)


def test_load_config_invalid_fields(tmp_path, monkeypatch):
    """load_config raises SystemExit when required fields are missing."""
    bad_config = {"vault_path": "/some/path"}  # missing all other required fields
    config_file = tmp_path / "config.json"
    config_file.write_text(json.dumps(bad_config))

    monkeypatch.setenv("ALYSHA_CONFIG", str(config_file))

    with pytest.raises(SystemExit) as exc_info:
        load_config()

    assert "Invalid config" in str(exc_info.value)
