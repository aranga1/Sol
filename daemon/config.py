import json, os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Config:
    vault_path: str
    daemon_port: int
    obsidian_api_key: str
    obsidian_port: int
    daemon_api_key: str
    ollama_model: str
    ollama_base_url: str


def load_config() -> Config:
    path = Path(os.environ.get("ALYSHA_CONFIG", Path.home() / ".alysha" / "config.json"))
    if not path.exists():
        raise SystemExit(f"Config not found: {path}. Run the setup script first.")
    with open(path) as f:
        data = json.load(f)
    try:
        return Config(**data)
    except TypeError as e:
        raise SystemExit(f"Invalid config at {path}: {e}")
