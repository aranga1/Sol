"""Extractor protocol — structural interface every extractor must satisfy."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:
    from llama_index.core.schema import TextNode
    from solidrag.index.manifest import IndexManifest


@runtime_checkable
class Extractor(Protocol):
    """Structural protocol for file extractors.

    Concrete extractors declare:
        supported_extensions: frozenset[str]  — e.g. frozenset({".pdf", ".PDF"})

    And implement:
        extract(path: Path) -> list[TextNode]
    """

    supported_extensions: frozenset[str]

    def extract(self, path: Path) -> "list[TextNode]": ...


@dataclass
class IndexDiff:
    """Describes changes to apply to the FAISS index from a SourceExtractor sync."""

    to_add: "list[TextNode]" = field(default_factory=list)
    to_update: "list[tuple[list[str], list[TextNode]]]" = field(default_factory=list)
    to_delete: list[str] = field(default_factory=list)


@runtime_checkable
class SourceExtractor(Protocol):
    """Protocol for non-file-based RAG sources (calendar, email, etc.)."""

    source_id: str

    def sync(self, manifest: "IndexManifest") -> IndexDiff: ...
