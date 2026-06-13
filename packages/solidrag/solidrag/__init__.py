"""solidrag — portable, source-agnostic RAG library.

Public API
----------
SolidRagConfig       Configuration dataclass.
ExtractorRegistry    Maps file extensions to Extractor implementations.
build_index          (stub) Build a FAISS-backed LlamaIndex from source dirs.
SourceWatcher        (stub) Watch source dirs and incrementally update the index.
query_stream_async   (stub) Stream query results from the index.
"""
from __future__ import annotations

from solidrag.config import SolidRagConfig
from solidrag.extractors.registry import ExtractorRegistry

__all__ = [
    "SolidRagConfig",
    "ExtractorRegistry",
    "build_index",
    "SourceWatcher",
    "query_stream_async",
]


# ---------------------------------------------------------------------------
# Stubs — these will be fleshed out in later issues.
# ---------------------------------------------------------------------------

def build_index(*args, **kwargs):  # type: ignore[return]
    """Build a FAISS-backed LlamaIndex from configured source directories.

    Not yet implemented — will be added in a later issue.
    """
    raise NotImplementedError("build_index is not implemented yet")


class SourceWatcher:
    """Watch source directories and incrementally update the index.

    Not yet implemented — will be added in a later issue.
    """

    def __init__(self, *args, **kwargs) -> None:
        raise NotImplementedError("SourceWatcher is not implemented yet")


async def query_stream_async(*args, **kwargs):  # type: ignore[return]
    """Async generator that streams query results from the index.

    Not yet implemented — will be added in a later issue.
    """
    raise NotImplementedError("query_stream_async is not implemented yet")
    # make mypy happy with an unreachable yield so this is typed as an async generator
    yield  # pragma: no cover
