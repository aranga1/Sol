"""solidRag query engine — intent routing, streaming, and source extraction."""
from __future__ import annotations

import hashlib
import logging
from pathlib import Path
from typing import TYPE_CHECKING, AsyncGenerator

import numpy as np
from llama_index.core import Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.llms.ollama import Ollama

from solidrag.config import SolidRagConfig
from solidrag.index.nodestore import NodeStore
from solidrag.query.prompts import (
    NEEDS_VAULT_PROMPT,
    build_direct_prompt,
    build_rag_prompt,
)

if TYPE_CHECKING:
    import faiss

logger = logging.getLogger(__name__)

_llm_instance: Ollama | None = None


def configure_settings(config: SolidRagConfig) -> None:
    global _llm_instance
    _llm_instance = Ollama(
        model=config.ollama_model,
        base_url=config.ollama_base_url,
        request_timeout=300.0,
        keep_alive=-1,
    )
    Settings.llm = _llm_instance
    Settings.embed_model = OllamaEmbedding(
        model_name=config.embed_model,
        base_url=config.ollama_base_url,
        request_timeout=60.0,
    )


def _get_llm() -> Ollama:
    if _llm_instance is not None:
        return _llm_instance
    return Settings.llm


def _node_id_to_int(node_id: str) -> int:
    digest = hashlib.sha256(node_id.encode()).hexdigest()
    return int(digest[:16], 16) % (2**63)


async def _needs_vault_async(question: str) -> bool:
    prompt = NEEDS_VAULT_PROMPT.format(question=question)
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    return str(result).strip().upper().startswith("Y")


async def _retrieve(
    faiss_index: "faiss.IndexIDMap2",
    nodestore: NodeStore,
    question: str,
    top_k: int,
) -> list[dict]:
    """Embed *question*, search FAISS, return list of {content, file_path, score}."""
    embed_model = Settings.embed_model
    q_vec = await embed_model.aget_query_embedding(question)
    q_arr = np.array([q_vec], dtype=np.float32)

    # Build reverse map: int64 FAISS id → node_id string
    int_to_nid: dict[int, str] = {
        _node_id_to_int(nid): nid for nid in nodestore.all_node_ids()
    }

    distances, ids = faiss_index.search(q_arr, top_k)

    results = []
    for dist, raw_id in zip(distances[0], ids[0]):
        int_id = int(raw_id)
        if int_id == -1:
            continue
        nid = int_to_nid.get(int_id)
        if nid is None:
            continue
        content = nodestore.get_content(nid)
        if not content:
            continue
        results.append({
            "content": content,
            "file_path": nodestore.get_file_path(nid) or "",
            "score": float(dist),
        })

    return results


def _extract_sources(results: list[dict], max_sources: int = 5) -> list[dict]:
    """Deduplicate and rank source references from retrieval results."""
    if not results:
        return []

    # file_path is vault-relative (e.g. "Notes/foo.md" or "uploads/pdf/.../bar.pdf")
    best_per_file: dict[str, tuple[dict, float]] = {}
    for r in results:
        fp = r["file_path"]
        if not fp:
            continue
        score = r["score"]
        if fp not in best_per_file or score < best_per_file[fp][1]:
            best_per_file[fp] = (r, score)

    if not best_per_file:
        return []

    ranked = sorted(best_per_file.values(), key=lambda x: x[1])
    best_score = ranked[0][1]
    relevant = [(r, s) for r, s in ranked if s <= best_score + 0.25][:max_sources]

    sources = []
    for r, _ in relevant:
        fp = r["file_path"]
        name = Path(fp).name
        title = name.replace(".md", "").replace(".pdf", "").replace("-", " ").replace("_", " ")
        for line in r["content"].split("\n"):
            if line.startswith("# "):
                title = line[2:].strip()
                break
        sources.append({"file": fp, "title": title})

    return sources


async def query_stream_async(
    faiss_index: "faiss.IndexIDMap2 | None",
    nodestore: NodeStore | None,
    question: str,
    history: list[dict] | None = None,
    top_k: int = 8,
    system_prompt: str | None = None,
) -> AsyncGenerator[dict, None]:
    """Stream query results as an async generator.

    Yields event dicts:
      {"type": "token",   "content": "<string>"}
      {"type": "sources", "sources": [...]}
      {"type": "done"}
    """
    if faiss_index is None or nodestore is None:
        yield {"type": "token", "content": "Index not ready — try again in a moment."}
        yield {"type": "sources", "sources": []}
        yield {"type": "done"}
        return

    needs_vault = await _needs_vault_async(question)

    if not needs_vault:
        prompt = build_direct_prompt(question, history)
        llm = _get_llm()
        async for chunk in await llm.astream_complete(prompt):
            if chunk.delta:
                yield {"type": "token", "content": chunk.delta}
        yield {"type": "sources", "sources": []}
        yield {"type": "done"}
        return

    results = await _retrieve(faiss_index, nodestore, question, top_k)
    sources = _extract_sources(results)

    context_str = "\n\n---\n\n".join(r["content"] for r in results)

    _default_system = (
        "You are Sol, a personal second-brain assistant. "
        "Answer the user's question using the relevant notes and documents provided. "
        "Cite specific details from the content where helpful."
    )

    prompt = build_rag_prompt(
        system_prompt or _default_system,
        context_str,
        question,
        history,
    )

    llm = _get_llm()
    async for chunk in await llm.astream_complete(prompt):
        if chunk.delta:
            yield {"type": "token", "content": chunk.delta}

    yield {"type": "sources", "sources": sources}
    yield {"type": "done"}
