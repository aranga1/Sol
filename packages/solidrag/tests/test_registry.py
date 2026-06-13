"""Tests for ExtractorRegistry."""
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from solidrag.extractors.registry import ExtractorRegistry


def make_extractor(exts: frozenset[str]):
    """Create a minimal mock extractor with the given extensions."""
    ext = MagicMock()
    ext.supported_extensions = exts
    ext.extract.return_value = []
    return ext


def test_register_and_get():
    registry = ExtractorRegistry()
    extractor = make_extractor(frozenset({".pdf", ".PDF"}))
    registry.register(extractor)

    result = registry.get(".pdf")
    assert result is extractor


def test_get_returns_none_for_unknown_extension():
    registry = ExtractorRegistry()
    assert registry.get(".xyz") is None


def test_get_returns_none_on_empty_registry():
    registry = ExtractorRegistry()
    assert registry.get(".pdf") is None


def test_extensions_returns_all_registered():
    registry = ExtractorRegistry()
    ext_a = make_extractor(frozenset({".pdf"}))
    ext_b = make_extractor(frozenset({".docx", ".doc"}))
    registry.register(ext_a)
    registry.register(ext_b)

    assert registry.extensions() == frozenset({".pdf", ".docx", ".doc"})


def test_extensions_empty_registry():
    registry = ExtractorRegistry()
    assert registry.extensions() == frozenset()


def test_register_multiple_extractors_different_exts():
    registry = ExtractorRegistry()
    pdf_ext = make_extractor(frozenset({".pdf"}))
    xlsx_ext = make_extractor(frozenset({".xlsx"}))
    docx_ext = make_extractor(frozenset({".docx"}))

    for e in (pdf_ext, xlsx_ext, docx_ext):
        registry.register(e)

    assert registry.get(".pdf") is pdf_ext
    assert registry.get(".xlsx") is xlsx_ext
    assert registry.get(".docx") is docx_ext


def test_register_overwrites_existing_extension():
    """When two extractors cover the same extension, last registered wins."""
    registry = ExtractorRegistry()
    first = make_extractor(frozenset({".pdf"}))
    second = make_extractor(frozenset({".pdf"}))

    registry.register(first)
    registry.register(second)

    assert registry.get(".pdf") is second


def test_extensions_returns_frozenset():
    registry = ExtractorRegistry()
    result = registry.extensions()
    assert isinstance(result, frozenset)
