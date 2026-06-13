"""SolidRagConfig — library-wide configuration dataclass."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class SolidRagConfig:
    """Configuration for the solidRag library.

    source_dirs: directories to watch / ingest.
    ollama_base_url: base URL of the local Ollama server.
    ollama_model: primary chat/completion model name.
    embed_model: Ollama embedding model name (default: nomic-embed-text).
    vision_model: Ollama vision model for image captioning (default: llava).
    persist_dir: path where the FAISS index and metadata are stored.
    image_batch_interval_s: how often (seconds) to process image batches.
    """

    source_dirs: list[Path]
    ollama_base_url: str
    ollama_model: str
    embed_model: str = "nomic-embed-text"
    vision_model: str = "llava"
    persist_dir: Path = field(default_factory=lambda: Path.home() / ".sol" / "index")
    image_batch_interval_s: int = 3600
