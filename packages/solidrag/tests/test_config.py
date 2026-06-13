"""Tests for SolidRagConfig dataclass."""
from pathlib import Path

import pytest

from solidrag.config import SolidRagConfig


def test_required_fields_only():
    cfg = SolidRagConfig(
        source_dirs=[Path("/tmp/notes")],
        ollama_base_url="http://localhost:11434",
        ollama_model="llama3",
    )
    assert cfg.source_dirs == [Path("/tmp/notes")]
    assert cfg.ollama_base_url == "http://localhost:11434"
    assert cfg.ollama_model == "llama3"


def test_defaults():
    cfg = SolidRagConfig(
        source_dirs=[],
        ollama_base_url="http://localhost:11434",
        ollama_model="llama3",
    )
    assert cfg.embed_model == "nomic-embed-text"
    assert cfg.vision_model == "llava"
    assert cfg.persist_dir == Path.home() / ".sol" / "index"
    assert cfg.image_batch_interval_s == 3600


def test_custom_overrides():
    persist = Path("/custom/index")
    cfg = SolidRagConfig(
        source_dirs=[Path("/a"), Path("/b")],
        ollama_base_url="http://remote:11434",
        ollama_model="mistral",
        embed_model="mxbai-embed-large",
        vision_model="bakllava",
        persist_dir=persist,
        image_batch_interval_s=600,
    )
    assert len(cfg.source_dirs) == 2
    assert cfg.embed_model == "mxbai-embed-large"
    assert cfg.vision_model == "bakllava"
    assert cfg.persist_dir == persist
    assert cfg.image_batch_interval_s == 600


def test_persist_dir_is_independent_per_instance():
    """Each instance should get its own default persist_dir object."""
    cfg1 = SolidRagConfig(source_dirs=[], ollama_base_url="http://localhost:11434", ollama_model="a")
    cfg2 = SolidRagConfig(source_dirs=[], ollama_base_url="http://localhost:11434", ollama_model="b")
    # They should be equal in value but not the same object (mutable default safety).
    assert cfg1.persist_dir == cfg2.persist_dir
    assert cfg1.persist_dir is not cfg2.persist_dir


def test_source_dirs_accepts_multiple_paths():
    dirs = [Path("/a"), Path("/b"), Path("/c")]
    cfg = SolidRagConfig(source_dirs=dirs, ollama_base_url="http://localhost:11434", ollama_model="llama3")
    assert cfg.source_dirs == dirs
