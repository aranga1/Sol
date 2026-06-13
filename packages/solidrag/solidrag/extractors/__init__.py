"""solidrag.extractors — Extractor protocol, registry, and concrete extractors."""
from solidrag.extractors.base import Extractor
from solidrag.extractors.registry import ExtractorRegistry
from solidrag.extractors.markdown import MarkdownExtractor
from solidrag.extractors.pdf import PDFExtractor
from solidrag.extractors.excel import ExcelExtractor
from solidrag.extractors.docx import DocxExtractor
from solidrag.extractors.image import ImageExtractor


def default_registry(
    ollama_base_url: str = "http://localhost:11434",
    vision_model: str = "llava",
) -> ExtractorRegistry:
    """Return an ExtractorRegistry pre-loaded with all built-in extractors.

    Args:
        ollama_base_url: Base URL of the Ollama server (for ImageExtractor).
        vision_model:    Ollama vision model name (default: ``"llava"``).

    Returns:
        A fully configured :class:`ExtractorRegistry`.
    """
    reg = ExtractorRegistry()
    reg.register(MarkdownExtractor())
    reg.register(PDFExtractor())
    reg.register(ExcelExtractor())
    reg.register(DocxExtractor())
    reg.register(ImageExtractor(ollama_base_url, vision_model))
    return reg


__all__ = [
    "Extractor",
    "ExtractorRegistry",
    "MarkdownExtractor",
    "PDFExtractor",
    "ExcelExtractor",
    "DocxExtractor",
    "ImageExtractor",
    "default_registry",
]
