"""solidRag query engine — intent routing, streaming, and source extraction."""
from __future__ import annotations

from pathlib import Path
from typing import AsyncGenerator

from llama_index.core import Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.llms.ollama import Ollama

from solidrag.config import SolidRagConfig
from solidrag.query.prompts import (
    NEEDS_VAULT_PROMPT,
    build_direct_prompt,
    build_rag_prompt,
)

# Module-level LLM instance so tests can patch _get_llm without touching
# the global llama-index Settings singleton.
_llm_instance: Ollama | None = None


def configure_settings(config: SolidRagConfig) -> None:
    """Configure llama-index Settings with Ollama LLM and embedding model.

    Call this once at startup before using query_stream_async.
    """
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


def _get_llm():
    """Return the active LLM instance (Settings.llm or module-level instance)."""
    if _llm_instance is not None:
        return _llm_instance
    return Settings.llm


async def _needs_vault_async(question: str) -> bool:
    """Classify whether the question requires vault retrieval.

    Uses the LLM to perform intent routing. Returns True if the LLM responds
    with a word starting with 'Y' (YES), False otherwise.
    """
    prompt = NEEDS_VAULT_PROMPT.format(question=question)
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    return str(result).strip().upper().startswith("Y")


async def _extract_relevant_sources(
    nodes: list,
    max_sources: int = 5,
) -> list[dict]:
    """Extract and deduplicate source references from retrieved nodes.

    Strategy:
    - Deduplicate by file, keeping the node with the best (lowest) L2 score per file.
    - Filter to nodes within 0.25 of the best score.
    - Cap results at max_sources.

    Returns a list of {"file": "...", "title": "..."} dicts.
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


async def query_stream_async(
    index,
    question: str,
    history: list[dict] | None = None,
    top_k: int = 8,
    system_prompt: str | None = None,
) -> AsyncGenerator[dict, None]:
    """Stream query results from the index as an async generator.

    Yields event dicts:
      {"type": "token",   "content": "<token_string>"}
      {"type": "sources", "sources": [{"file": ..., "title": ...}]}
      {"type": "done"}

    If index is None, yields a "not ready" token followed by empty sources and done.
    Intent routing classifies the question first — general knowledge questions skip
    vault retrieval and are answered directly from the LLM.
    """
    if index is None:
        yield {"type": "token", "content": "Index not ready — try again in a moment."}
        yield {"type": "sources", "sources": []}
        yield {"type": "done"}
        return

    needs_vault = await _needs_vault_async(question)

    if not needs_vault:
        # Direct answer path — no retrieval
        prompt = build_direct_prompt(question, history)
        llm = _get_llm()
        async for chunk in await llm.astream_complete(prompt):
            if chunk.delta:
                yield {"type": "token", "content": chunk.delta}
        yield {"type": "sources", "sources": []}
        yield {"type": "done"}
        return

    # RAG path: retrieve context, build prompt, stream
    retriever = index.as_retriever(similarity_top_k=top_k)
    nodes = await retriever.aretrieve(question)
    sources = await _extract_relevant_sources(nodes)

    context_parts = [node.get_content() for node in nodes]
    context_str = "\n\n---\n\n".join(context_parts)

    _default_system = (
        "You are Sol, a personal second-brain assistant. "
        "Answer the user's question using the relevant notes provided. "
        "Cite specific details from the notes where helpful."
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
