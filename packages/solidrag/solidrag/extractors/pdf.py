"""PDFExtractor — one TextNode per non-empty page using pypdf."""
from __future__ import annotations

from pathlib import Path

from llama_index.core.schema import TextNode


class PDFExtractor:
    """Extract text from a PDF file, one TextNode per non-empty page."""

    supported_extensions: frozenset[str] = frozenset({".pdf"})

    def extract(self, path: Path) -> list[TextNode]:
        from pypdf import PdfReader

        reader = PdfReader(str(path))
        base_meta = {"file_path": str(path), "file_name": path.name}
        nodes: list[TextNode] = []

        for page_num, page in enumerate(reader.pages, start=1):
            text = page.extract_text() or ""
            text = text.strip()
            if not text:
                continue
            meta = {**base_meta, "page_number": page_num}
            node = TextNode(text=text, metadata=meta)
            node.excluded_llm_metadata_keys = list(base_meta.keys())
            nodes.append(node)

        return nodes
