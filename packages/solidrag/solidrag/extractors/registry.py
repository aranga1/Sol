"""ExtractorRegistry — maps file extensions to Extractor instances."""
from __future__ import annotations

from solidrag.extractors.base import Extractor


class ExtractorRegistry:
    """Central registry that maps file extensions to Extractor implementations.

    Usage::

        registry = ExtractorRegistry()
        registry.register(PdfExtractor())
        extractor = registry.get(".pdf")   # returns the PdfExtractor instance
        all_exts = registry.extensions()   # frozenset of every registered extension
    """

    def __init__(self) -> None:
        self._mapping: dict[str, Extractor] = {}

    def register(self, extractor: Extractor) -> None:
        """Register an extractor for all its supported extensions.

        If an extension was already mapped to a different extractor, the new
        one takes precedence (last-write wins).
        """
        for ext in extractor.supported_extensions:
            self._mapping[ext] = extractor

    def get(self, extension: str) -> Extractor | None:
        """Return the extractor for *extension*, or None if none is registered."""
        return self._mapping.get(extension)

    def extensions(self) -> frozenset[str]:
        """Return a frozenset of every extension currently registered."""
        return frozenset(self._mapping.keys())
