"""Extractor protocol — structural interface every extractor must satisfy."""
from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:
    from llama_index.core.schema import TextNode


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
