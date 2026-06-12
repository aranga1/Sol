import json, os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_SYSTEM_PROMPT = (
    "You are a personal assistant helping the user recall information from their own notes.\n"
    "Below are excerpts from the user's notes:\n"
    "---------------------\n"
    "{context_str}\n"
    "---------------------\n"
    "Rules:\n"
    "1. Answer using ONLY the note excerpts above.\n"
    "2. If a name, word, or topic appears anywhere in the excerpts — even once — report it. "
    "Do NOT say it is absent if it appears in the text.\n"
    "3. Quote or paraphrase the relevant lines directly.\n"
    "4. If the excerpts genuinely contain nothing relevant, say so briefly.\n"
    "5. Do not invent facts.\n"
    "Question: {query_str}\n"
    "Answer:"
)


@dataclass
class Config:
    vault_path: str
    daemon_port: int
    obsidian_api_key: str
    obsidian_port: int
    daemon_api_key: str
    ollama_model: str
    ollama_base_url: str
    system_prompt: str = field(default=DEFAULT_SYSTEM_PROMPT)


_config_path: Path | None = None


def get_config_path() -> Path:
    global _config_path
    if _config_path is None:
        _config_path = Path(os.environ.get("ALYSHA_CONFIG", Path.home() / ".alysha" / "config.json"))
    return _config_path


def load_config() -> Config:
    path = get_config_path()
    if not path.exists():
        raise SystemExit(f"Config not found: {path}. Run the setup script first.")
    with open(path) as f:
        data = json.load(f)
    known = {f.name for f in Config.__dataclass_fields__.values()}
    filtered = {k: v for k, v in data.items() if k in known}
    try:
        return Config(**filtered)
    except TypeError as e:
        raise SystemExit(f"Invalid config at {path}: {e}")


def save_system_prompt(prompt: str) -> None:
    path = get_config_path()
    with open(path) as f:
        data = json.load(f)
    data["system_prompt"] = prompt
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
