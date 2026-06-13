"""solidrag.extractors — Extractor protocol and registry."""
from solidrag.extractors.base import Extractor
from solidrag.extractors.registry import ExtractorRegistry

__all__ = ["Extractor", "ExtractorRegistry"]
