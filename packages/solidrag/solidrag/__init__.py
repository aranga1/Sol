"""solidrag — portable, source-agnostic RAG library.

Public API
----------
SolidRagConfig       Configuration dataclass.
ExtractorRegistry    Maps file extensions to Extractor implementations.
build_index          Build a FAISS-backed index from source dirs.
SourceWatcher        Watch source dirs and incrementally update the index.
configure_settings   Configure llama-index Settings with Ollama models.
query_stream_async   Stream query results from the index.
"""
from __future__ import annotations

from solidrag.config import SolidRagConfig
from solidrag.extractors.registry import ExtractorRegistry
from solidrag.index.builder import build_index
from solidrag.index.nodestore import NodeStore
from solidrag.index.calendar_watcher import CalendarWatcher
from solidrag.index.watcher import SourceWatcher
from solidrag.query.engine import configure_settings, query_stream_async

__all__ = [
    "SolidRagConfig",
    "ExtractorRegistry",
    "build_index",
    "NodeStore",
    "CalendarWatcher",
    "SourceWatcher",
    "configure_settings",
    "query_stream_async",
]
