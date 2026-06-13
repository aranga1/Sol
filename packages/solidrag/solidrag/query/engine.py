"""solidRag query engine — intent routing, streaming, and source extraction."""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from datetime import date as _date
from pathlib import Path
from typing import TYPE_CHECKING, AsyncGenerator

import numpy as np
from llama_index.core import Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.llms.ollama import Ollama

from solidrag.config import SolidRagConfig
from solidrag.index.nodestore import NodeStore
from solidrag.query.prompts import (
    CALENDAR_ACTION_PROMPT,
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


async def _needs_vault_async(question: str, history: list[dict] | None) -> bool:
    history_text = ""
    if history:
        lines = [
            f"{'User' if m['role'] == 'user' else 'Sol'}: {m['content']}"
            for m in history[-4:]  # last 2 turns is enough context
        ]
        history_text = "\n".join(lines)
    prompt = NEEDS_VAULT_PROMPT.format(question=question, history=history_text or "(none)")
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
    import re as _re
    from datetime import datetime as _dt

    if not results:
        return []

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
        content = r["content"]

        if fp.startswith("calendar:"):
            # Extract event title from "Event: <title>" line
            title = "Calendar Event"
            for line in content.split("\n"):
                if line.startswith("Event: "):
                    title = line[len("Event: "):].strip()
                    break

            # Build calshow: URL — CFAbsoluteTime = unix_ts - 978307200
            url = "calshow://"
            m = _re.search(r"Date: \w+ (\d+) (\w+) (\d{4})", content)
            if m:
                try:
                    event_date = _dt.strptime(
                        f"{m.group(1)} {m.group(2)} {m.group(3)}", "%d %B %Y"
                    )
                    cf_ts = int(event_date.timestamp()) - 978307200
                    url = f"calshow:{cf_ts}"
                except Exception:
                    pass

            sources.append({"file": fp, "title": title, "source_type": "calendar", "url": url})
        else:
            # Obsidian note / PDF / image
            name = Path(fp).name
            title = name.replace(".md", "").replace(".pdf", "").replace("-", " ").replace("_", " ")
            for line in content.split("\n"):
                if line.startswith("# "):
                    title = line[2:].strip()
                    break
            sources.append({"file": fp, "title": title, "source_type": "note", "url": None})

    return sources


async def _is_calendar_action(question: str) -> tuple[bool, dict | None]:
    """Classify whether the question is a calendar event creation request.

    Returns (True, event_dict) if detected, (False, None) otherwise.
    Never raises — malformed LLM output returns (False, None).
    """
    prompt = CALENDAR_ACTION_PROMPT.format(
        today=_date.today().isoformat(),
        question=question,
    )
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    text = str(result).strip()

    # Strip markdown fences if the model wrapped the JSON
    if text.startswith("```"):
        parts = text.split("```")
        text = parts[1] if len(parts) > 1 else text
        if text.startswith("json"):
            text = text[4:].strip()

    try:
        data = json.loads(text)
        if data.get("is_calendar_action") and isinstance(data.get("event"), dict):
            return True, data["event"]
        return False, None
    except (json.JSONDecodeError, AttributeError):
        return False, None


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

    # Run intent checks concurrently
    needs_vault_task = asyncio.create_task(_needs_vault_async(question, history))
    calendar_task = asyncio.create_task(_is_calendar_action(question))
    needs_vault = await needs_vault_task
    is_calendar, event_payload = await calendar_task

    # For calendar/time queries: inject today's date AND pull all calendar events
    # directly (bypassing FAISS) since date-based queries don't match semantically.
    _CALENDAR_TERMS = {"calendar", "event", "meeting", "appointment", "schedule",
                       "tomorrow", "today", "next week", "this week"}
    is_calendar_query = any(t in question.lower() for t in _CALENDAR_TERMS)
    retrieval_question = question
    if is_calendar_query:
        today_str = _date.today().strftime("%A %d %B %Y")
        retrieval_question = f"{question} [Today is {today_str}]"

    if not needs_vault:
        prompt = build_direct_prompt(question, history)
        llm = _get_llm()
        async for chunk in await llm.astream_complete(prompt):
            if chunk.delta:
                yield {"type": "token", "content": chunk.delta}
        yield {"type": "sources", "sources": []}
        if is_calendar and event_payload:
            yield {
                "type": "action",
                "action": "create_event",
                "payload": event_payload,
            }
        yield {"type": "done"}
        return

    # Calendar queries: retrieve calendar events directly from NodeStore (bypass FAISS)
    # and pre-filter by date so the small LLM doesn't need to do date math.
    if is_calendar_query:
        import re as _re
        from datetime import timedelta as _td

        today = _date.today()
        q_lower = question.lower()
        if "tomorrow" in q_lower:
            target_dates = {today + _td(days=1)}
            retrieval_question = question.replace("tomorrow", (today + _td(days=1)).strftime("%A %d %B %Y"))
        elif "today" in q_lower:
            target_dates = {today}
            retrieval_question = question.replace("today", today.strftime("%A %d %B %Y"))
        elif "this week" in q_lower:
            start = today - _td(days=today.weekday())
            target_dates = {start + _td(days=i) for i in range(7)}
        elif "next week" in q_lower:
            start = today + _td(days=7 - today.weekday())
            target_dates = {start + _td(days=i) for i in range(7)}
        else:
            target_dates = None  # no filter — return all

        def _event_date(content: str) -> "_date | None":
            m = _re.search(r"Date: \w+ (\d+) (\w+) (\d{4})", content)
            if m:
                try:
                    from datetime import datetime as _dt
                    return _dt.strptime(f"{m.group(1)} {m.group(2)} {m.group(3)}", "%d %B %Y").date()
                except Exception:
                    pass
            return None

        seen_fps: set[str] = set()
        cal_results: list[dict] = []
        for nid in nodestore.all_node_ids():
            fp = nodestore.get_file_path(nid) or ""
            if fp.startswith("calendar:") and fp not in seen_fps:
                content = nodestore.get_content(nid)
                if content:
                    if target_dates is None or _event_date(content) in target_dates:
                        cal_results.append({"content": content, "file_path": fp, "score": 0.0})
                    seen_fps.add(fp)

        note_results = await _retrieve(faiss_index, nodestore, retrieval_question, top_k)
        note_results = [r for r in note_results if not r["file_path"].startswith("calendar:")]
        results = cal_results + note_results[:max(0, top_k - len(cal_results))]
    else:
        results = await _retrieve(faiss_index, nodestore, retrieval_question, top_k)
    sources = _extract_sources(results)

    context_str = "\n\n---\n\n".join(r["content"] for r in results)

    from datetime import timedelta as _td2
    if is_calendar_query:
        today_str = _date.today().strftime("%A %d %B %Y")
        tomorrow_str = (_date.today() + _td2(days=1)).strftime("%A %d %B %Y")
        today_context = (
            f" Today is {today_str}. Tomorrow is {tomorrow_str}."
            " Answer only from the calendar events provided in the context."
        )
    else:
        today_context = ""
    _default_system = (
        "You are Sol, a personal second-brain assistant. "
        "Answer the user's question using the relevant notes, documents, and image descriptions provided. "
        "Image contents have been extracted by a vision model and stored as text descriptions — "
        "treat those descriptions as the ground truth about what is in the image. "
        f"Cite specific details from the content where helpful.{today_context}"
    )

    prompt = build_rag_prompt(
        system_prompt or _default_system,
        context_str,
        retrieval_question,  # use date-resolved question for LLM too
        history,
    )

    llm = _get_llm()
    async for chunk in await llm.astream_complete(prompt):
        if chunk.delta:
            yield {"type": "token", "content": chunk.delta}

    yield {"type": "sources", "sources": sources}

    if is_calendar and event_payload:
        yield {
            "type": "action",
            "action": "create_event",
            "payload": event_payload,
        }

    yield {"type": "done"}
