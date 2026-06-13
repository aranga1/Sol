"""DocxExtractor — convert a .docx to markdown-ish text, one TextNode.

Headings become # / ## / ### etc., normal paragraphs are left as-is,
and tables become pipe-separated rows.  The full document is returned as
a single TextNode so that downstream chunking (e.g. in the index builder)
can apply its own strategy.
"""
from __future__ import annotations

from pathlib import Path

from llama_index.core.schema import TextNode


def _heading_prefix(level: int) -> str:
    return "#" * max(1, level) + " "


def _table_to_markdown(table) -> str:
    """Convert a python-docx Table to pipe-delimited markdown."""
    lines: list[str] = []
    for row in table.rows:
        cells = [cell.text.replace("\n", " ").strip() for cell in row.cells]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


class DocxExtractor:
    """Extract text from a .docx file as a single markdown-ish TextNode."""

    supported_extensions: frozenset[str] = frozenset({".docx", ".doc"})

    def extract(self, path: Path) -> list[TextNode]:
        from docx import Document
        from docx.oxml.ns import qn
        from docx.table import Table
        from docx.text.paragraph import Paragraph

        doc = Document(str(path))
        parts: list[str] = []

        # Iterate document body elements in order to preserve layout
        for block in doc.element.body:
            tag = block.tag.split("}")[-1] if "}" in block.tag else block.tag

            if tag == "p":
                para = Paragraph(block, doc)
                style_name = para.style.name if para.style else ""
                text = para.text.strip()
                if not text:
                    continue
                if style_name.startswith("Heading"):
                    try:
                        level = int(style_name.split()[-1])
                    except (ValueError, IndexError):
                        level = 1
                    parts.append(_heading_prefix(level) + text)
                else:
                    parts.append(text)

            elif tag == "tbl":
                tbl = Table(block, doc)
                md_table = _table_to_markdown(tbl)
                if md_table.strip():
                    parts.append(md_table)

        if not parts:
            return []

        text = "\n\n".join(parts)
        meta = {"file_path": str(path), "file_name": path.name}
        node = TextNode(text=text, metadata=meta)
        node.excluded_llm_metadata_keys = list(meta.keys())
        return [node]
