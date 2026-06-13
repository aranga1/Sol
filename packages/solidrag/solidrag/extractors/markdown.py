"""MarkdownExtractor — semantic chunking with neighbor overlap.

Ported from daemon/rag.py. Splits on headings and HRs, sub-splits long
sections on blank lines, then adds a 3-sentence context window from the
adjacent chunks so the LLM always has orientation context.
"""
from __future__ import annotations

import re
from pathlib import Path

from llama_index.core.schema import TextNode

_CHUNK_MAX_CHARS = 1400
_OVERLAP_SENTENCES = 3


def _split_sentences(text: str) -> list[str]:
    return re.split(r"(?<=[.!?])\s+", text.strip())


def _semantic_chunks(text: str) -> list[str]:
    """Return a list of overlapping semantic chunks from *text*."""
    sections = re.split(r"\n(?=#{1,3} |\-\-\-)", text.strip())
    raw: list[str] = []
    for section in sections:
        if len(section) <= _CHUNK_MAX_CHARS:
            if s := section.strip():
                raw.append(s)
        else:
            paragraphs = re.split(r"\n{2,}", section)
            current = ""
            for para in paragraphs:
                para = para.strip()
                if not para:
                    continue
                if len(current) + len(para) + 2 <= _CHUNK_MAX_CHARS:
                    current = (current + "\n\n" + para).strip()
                else:
                    if current:
                        raw.append(current)
                    current = para
            if current:
                raw.append(current)

    if len(raw) <= 1:
        return raw

    # Add neighbor overlap (3-sentence tail of previous, 3-sentence head of next)
    def tail(t: str) -> str:
        return " ".join(_split_sentences(t)[-_OVERLAP_SENTENCES:])

    def head(t: str) -> str:
        return " ".join(_split_sentences(t)[:_OVERLAP_SENTENCES])

    result: list[str] = []
    for i, chunk in enumerate(raw):
        parts: list[str] = []
        if i > 0 and (ctx := tail(raw[i - 1])):
            parts.append(f"[context: …{ctx}]")
        parts.append(chunk)
        if i < len(raw) - 1 and (ctx := head(raw[i + 1])):
            parts.append(f"[context: {ctx}…]")
        result.append("\n".join(parts))
    return result


class MarkdownExtractor:
    """Extract semantic chunks from a Markdown file as TextNodes."""

    supported_extensions: frozenset[str] = frozenset({".md"})

    def extract(self, path: Path) -> list[TextNode]:
        text = path.read_text(encoding="utf-8", errors="ignore")
        meta = {"file_path": str(path), "file_name": path.name}
        nodes: list[TextNode] = []
        for chunk in _semantic_chunks(text):
            node = TextNode(text=chunk, metadata=meta)
            node.excluded_llm_metadata_keys = list(meta.keys())
            nodes.append(node)
        return nodes
