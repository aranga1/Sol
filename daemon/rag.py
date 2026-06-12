"""
RAG engine for Sol daemon.

Design decisions:
- Semantic chunking: split on Obsidian headings/paragraphs (not fixed chars)
  so each chunk represents a coherent thought. Neighboring chunks share a
  3-sentence context window at each boundary, improving recall for queries
  that span section boundaries.
- FAISS index persisted to ~/.sol/index/ and loaded on startup; rebuilt
  only when vault content changes (VaultWatcher compares mtime).
- LLM streaming: query_stream_async() is an async generator that yields
  token events then a sources event, enabling low-latency first-byte delivery.
- Intent routing: _needs_vault() pre-classifies each question; general
  knowledge questions skip retrieval entirely to avoid vault noise.
"""
from __future__ import annotations

import asyncio
import json
import re
import threading
import time
from pathlib import Path
from typing import AsyncGenerator, Callable

import faiss
from llama_index.core import (
    Settings,
    StorageContext,
    VectorStoreIndex,
    load_index_from_storage,
)
from llama_index.core.schema import TextNode
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.llms.ollama import Ollama
from llama_index.vector_stores.faiss import FaissVectorStore

from daemon.config import DEFAULT_SYSTEM_PROMPT

# ── Constants ─────────────────────────────────────────────────────────────────
_EMBED_DIM = 768          # nomic-embed-text output dimension
_CHUNK_MAX_CHARS = 1400   # soft cap per semantic chunk
_OVERLAP_SENTENCES = 3    # sentences shared with neighbouring chunk
_PERSIST_DIR = Path.home() / ".sol" / "index"


# ── Settings ──────────────────────────────────────────────────────────────────
def _configure_settings(ollama_base_url: str, ollama_model: str) -> None:
    Settings.llm = Ollama(
        model=ollama_model,
        base_url=ollama_base_url,
        request_timeout=300.0,
        keep_alive=-1,      # keep model loaded between requests (no reload delay)
    )
    Settings.embed_model = OllamaEmbedding(
        model_name="nomic-embed-text",
        base_url=ollama_base_url,
        request_timeout=60.0,
    )


# ── Semantic chunking ─────────────────────────────────────────────────────────
def _split_sentences(text: str) -> list[str]:
    """Rough sentence tokeniser for context overlap."""
    parts = re.split(r"(?<=[.!?])\s+", text.strip())
    return [p for p in parts if p]


def _semantic_chunks(text: str) -> list[str]:
    """
    Split a markdown note into semantic chunks, preserving context at boundaries.

    Strategy:
    1. Primary split on Obsidian headings (# / ## / ###) and horizontal rules.
    2. If a section exceeds _CHUNK_MAX_CHARS, split further on blank lines (paragraphs).
    3. Each chunk gets the last _OVERLAP_SENTENCES of its predecessor prepended
       as a bracketed context hint, and the first _OVERLAP_SENTENCES of its
       successor appended. These markers are visible to both the embedding model
       (improving cross-boundary recall) and the LLM (which sees them as context,
       not primary content).
    """
    # Step 1: split on headings / HR
    sections = re.split(r"\n(?=#{1,3} |\-\-\-)", text.strip())

    # Step 2: sub-split long sections on blank lines
    raw: list[str] = []
    for section in sections:
        if len(section) <= _CHUNK_MAX_CHARS:
            s = section.strip()
            if s:
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

    # Step 3: add neighbor context overlap
    def tail(t: str) -> str:
        return " ".join(_split_sentences(t)[-_OVERLAP_SENTENCES:])

    def head(t: str) -> str:
        return " ".join(_split_sentences(t)[:_OVERLAP_SENTENCES])

    result = []
    for i, chunk in enumerate(raw):
        parts: list[str] = []
        if i > 0 and (ctx := tail(raw[i - 1])):
            parts.append(f"[context: …{ctx}]")
        parts.append(chunk)
        if i < len(raw) - 1 and (ctx := head(raw[i + 1])):
            parts.append(f"[context: {ctx}…]")
        result.append("\n".join(parts))

    return result


def _make_nodes(text: str, md_file: Path) -> list[TextNode]:
    meta = {"file_path": str(md_file), "file_name": md_file.name}
    nodes = []
    for chunk in _semantic_chunks(text):
        node = TextNode(text=chunk, metadata=meta)
        # Keep metadata out of the LLM context window (prevents path leakage)
        node.excluded_llm_metadata_keys = list(meta.keys())
        nodes.append(node)
    return nodes


# ── Index build & persistence ─────────────────────────────────────────────────
def build_index(
    vault_path: str,
    ollama_base_url: str,
    ollama_model: str,
    force_rebuild: bool = False,
) -> VectorStoreIndex:
    """
    Build (or load from cache) a FAISS vector index for the vault.

    On first run the index is built from scratch and persisted to
    ~/.sol/index/. Subsequent startups load from cache (< 1s vs 30s+
    for a full rebuild). force_rebuild=True skips the cache — used by
    VaultWatcher when vault content changes.
    """
    _configure_settings(ollama_base_url, ollama_model)
    path = Path(vault_path)
    faiss_path = _PERSIST_DIR / "faiss.index"

    if not force_rebuild and _PERSIST_DIR.exists() and faiss_path.exists():
        try:
            faiss_idx = faiss.read_index(str(faiss_path))
            vector_store = FaissVectorStore(faiss_index=faiss_idx)
            storage_ctx = StorageContext.from_defaults(
                persist_dir=str(_PERSIST_DIR),
                vector_store=vector_store,
            )
            index = load_index_from_storage(storage_ctx)
            print(f"[RAG] Loaded index from cache ({faiss_idx.ntotal} vectors)")
            return index
        except Exception as e:
            print(f"[RAG] Cache load failed ({e}), rebuilding")

    print("[RAG] Building index from vault…")
    nodes: list[TextNode] = []
    for md_file in path.rglob("*.md"):
        try:
            text = md_file.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        nodes.extend(_make_nodes(text, md_file))

    faiss_idx = faiss.IndexFlatL2(_EMBED_DIM)
    vector_store = FaissVectorStore(faiss_index=faiss_idx)
    storage_ctx = StorageContext.from_defaults(vector_store=vector_store)

    if not nodes:
        return VectorStoreIndex([], storage_context=storage_ctx)

    index = VectorStoreIndex(nodes, storage_context=storage_ctx, show_progress=False)

    # Persist to disk
    _PERSIST_DIR.mkdir(parents=True, exist_ok=True)
    storage_ctx.persist(persist_dir=str(_PERSIST_DIR))
    faiss.write_index(faiss_idx, str(faiss_path))
    print(f"[RAG] Index persisted ({faiss_idx.ntotal} vectors → {_PERSIST_DIR})")

    return index


# ── Intent routing ────────────────────────────────────────────────────────────
_NEEDS_VAULT_PROMPT = """\
Does answering the following question require searching the user's personal \
notes or vault?
Answer YES if the question is about the user's own memories, notes, people \
they know, events in their life, or anything found only in personal records.
Answer NO if the question can be answered from general knowledge alone \
(greetings, questions about the assistant, general facts, math).
Reply with exactly one word: YES or NO.

Question: {question}
Answer:"""


async def _needs_vault_async(question: str) -> bool:
    prompt = _NEEDS_VAULT_PROMPT.format(question=question)
    result = await Settings.llm.acomplete(prompt)
    return str(result).strip().upper().startswith("Y")


# ── Prompt builders ───────────────────────────────────────────────────────────
_DIRECT_SYSTEM = (
    "You are Sol, a personal second-brain assistant. "
    "Answer the user's question conversationally. "
    "Do not reference any notes or documents."
)


def _build_direct_prompt(question: str, history: list[dict] | None) -> str:
    history_text = ""
    if history:
        history_text = (
            "\n".join(
                f"{'User' if m['role'] == 'user' else 'Sol'}: {m['content']}"
                for m in history
            )
            + "\n\n"
        )
    return f"{_DIRECT_SYSTEM}\n\n{history_text}User: {question}\nSol:"


def _build_rag_prompt(
    system_prompt: str,
    context_str: str,
    question: str,
    history: list[dict] | None,
) -> str:
    """Inline RAG prompt so we can stream via llm.astream_complete directly."""
    history_section = ""
    if history:
        history_text = "\n".join(
            f"{'User' if m['role'] == 'user' else 'Sol'}: {m['content']}"
            for m in history
        )
        history_section = (
            f"\n\nPrevious conversation "
            f"(for context only — do NOT treat as notes):\n{history_text}"
        )

    return (
        f"{system_prompt}{history_section}\n\n"
        f"Relevant notes:\n{context_str}\n\n"
        f"Question: {question}\n"
        f"Answer:"
    )


# ── Source extraction ─────────────────────────────────────────────────────────
def _extract_relevant_sources(nodes: list, max_sources: int = 5) -> list[dict]:
    """
    Deduplicate by file, filter to within 0.25 L2 distance of the best match,
    cap at max_sources. Returns [{"file": "...", "title": "..."}].
    """
    if not nodes:
        return []

    best_per_file: dict[str, tuple] = {}
    for node in nodes:
        fp = node.metadata.get("file_path", "") or node.metadata.get("file_name", "")
        if not fp:
            continue
        rel = Path(fp).name
        score = node.score if node.score is not None else 999.0
        if rel not in best_per_file or score < best_per_file[rel][1]:
            best_per_file[rel] = (node, score)

    if not best_per_file:
        return []

    ranked = sorted(best_per_file.values(), key=lambda x: x[1])
    best_score = ranked[0][1]
    relevant = [(n, s) for n, s in ranked if s <= best_score + 0.25][:max_sources]

    sources = []
    for node, _ in relevant:
        fp = node.metadata.get("file_path", "") or node.metadata.get("file_name", "")
        rel = Path(fp).name
        title = rel.replace(".md", "").replace("-", " ").replace("_", " ")
        try:
            for line in node.get_content().split("\n"):
                if line.startswith("# "):
                    title = line[2:].strip()
                    break
        except Exception:
            pass
        sources.append({"file": f"Notes/{rel}", "title": title})

    return sources


# ── Streaming query (main public API) ─────────────────────────────────────────
async def query_stream_async(
    index: VectorStoreIndex,
    question: str,
    history: list[dict] | None = None,
    top_k: int = 8,
    system_prompt: str | None = None,
) -> AsyncGenerator[dict, None]:
    """
    Async generator yielding SSE event dicts:
      {"type": "token",   "content": "<token_string>"}
      {"type": "sources", "sources": [{"file": ..., "title": ...}]}
      {"type": "done"}

    Retrieval happens first (fast, < 1s), then tokens stream from the LLM.
    First byte typically arrives in < 2s on Apple Silicon with a loaded model.
    """
    if index is None:
        yield {"type": "token", "content": "Index not ready — try again in a moment."}
        yield {"type": "sources", "sources": []}
        yield {"type": "done"}
        return

    # ── Intent routing ────────────────────────────────────────────────────────
    needs_vault = await _needs_vault_async(question)

    if not needs_vault:
        prompt = _build_direct_prompt(question, history)
        async for chunk in await Settings.llm.astream_complete(prompt):
            if chunk.delta:
                yield {"type": "token", "content": chunk.delta}
        yield {"type": "sources", "sources": []}
        yield {"type": "done"}
        return

    # ── RAG path: retrieve → stream ───────────────────────────────────────────
    retriever = index.as_retriever(similarity_top_k=top_k)
    nodes = await retriever.aretrieve(question)
    sources = _extract_relevant_sources(nodes)

    context_parts = [node.get_content() for node in nodes]
    context_str = "\n\n---\n\n".join(context_parts)

    prompt = _build_rag_prompt(
        system_prompt or DEFAULT_SYSTEM_PROMPT,
        context_str,
        question,
        history,
    )

    async for chunk in await Settings.llm.astream_complete(prompt):
        if chunk.delta:
            yield {"type": "token", "content": chunk.delta}

    yield {"type": "sources", "sources": sources}
    yield {"type": "done"}


# ── Legacy sync query (kept for internal/test use) ────────────────────────────
def query(
    index: VectorStoreIndex,
    question: str,
    history: list[dict] | None = None,
    top_k: int = 8,
    system_prompt: str | None = None,
) -> tuple[str, list[dict]]:
    """Blocking wrapper around query_stream_async. Use only for offline tests."""
    answer_parts: list[str] = []
    sources: list[dict] = []

    async def _run():
        async for event in query_stream_async(index, question, history, top_k, system_prompt):
            if event["type"] == "token":
                answer_parts.append(event["content"])
            elif event["type"] == "sources":
                sources.extend(event["sources"])

    asyncio.run(_run())
    return "".join(answer_parts) or "I don't have notes about that yet.", sources


# ── Vault watcher ─────────────────────────────────────────────────────────────
class VaultWatcher:
    """Background thread: polls vault mtime, triggers forced re-index on change."""

    def __init__(
        self,
        vault_path: str,
        ollama_base_url: str,
        ollama_model: str,
        on_index_ready: Callable[[VectorStoreIndex], None],
        poll_interval: int = 60,
    ):
        self.vault_path = vault_path
        self.ollama_base_url = ollama_base_url
        self.ollama_model = ollama_model
        self.on_index_ready = on_index_ready
        self.poll_interval = poll_interval
        self._last_mtime: float = 0.0
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()

    def _get_vault_mtime(self) -> float:
        try:
            return max(p.stat().st_mtime for p in Path(self.vault_path).rglob("*.md"))
        except ValueError:
            return 0.0

    def _run(self):
        while not self._stop_event.is_set():
            try:
                mtime = self._get_vault_mtime()
                if mtime != self._last_mtime:
                    self._last_mtime = mtime
                    new_index = build_index(
                        self.vault_path,
                        self.ollama_base_url,
                        self.ollama_model,
                        force_rebuild=True,  # vault changed → skip cache
                    )
                    self.on_index_ready(new_index)
            except Exception as e:
                print(f"[VaultWatcher] Error during re-index: {e}")
            self._stop_event.wait(self.poll_interval)

    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()
