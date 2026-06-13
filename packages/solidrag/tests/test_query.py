"""Tests for solidrag.query — prompts and engine.

All llama-index / Ollama calls are mocked. No real network calls are made.
"""
from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run(coro):
    """Run a coroutine in a fresh event loop (compatible with pytest-asyncio)."""
    return asyncio.get_event_loop().run_until_complete(coro)


async def _collect(gen):
    """Collect all items from an async generator into a list."""
    items = []
    async for item in gen:
        items.append(item)
    return items


# ---------------------------------------------------------------------------
# Prompt tests
# ---------------------------------------------------------------------------

class TestBuildDirectPromptNoHistory:
    def test_format_contains_question(self):
        from solidrag.query.prompts import build_direct_prompt, DIRECT_SYSTEM

        result = build_direct_prompt("What is 2+2?", None)
        assert "What is 2+2?" in result
        assert DIRECT_SYSTEM in result

    def test_format_ends_with_sol_prompt(self):
        from solidrag.query.prompts import build_direct_prompt

        result = build_direct_prompt("Hello", None)
        assert result.endswith("Sol:")

    def test_no_history_section_when_history_none(self):
        from solidrag.query.prompts import build_direct_prompt

        result = build_direct_prompt("Hello", None)
        # There should be no User:/Sol: conversation lines before the final question
        lines = result.splitlines()
        # Count lines that start with "User:" — only the final one should exist
        user_lines = [l for l in lines if l.startswith("User:")]
        assert len(user_lines) == 1


class TestBuildDirectPromptWithHistory:
    def test_history_included_in_output(self):
        from solidrag.query.prompts import build_direct_prompt

        history = [
            {"role": "user", "content": "Hi there"},
            {"role": "assistant", "content": "Hello!"},
        ]
        result = build_direct_prompt("How are you?", history)
        assert "Hi there" in result
        assert "Hello!" in result

    def test_history_roles_labeled(self):
        from solidrag.query.prompts import build_direct_prompt

        history = [
            {"role": "user", "content": "Test message"},
            {"role": "assistant", "content": "Test reply"},
        ]
        result = build_direct_prompt("Next question?", history)
        assert "User: Test message" in result
        assert "Sol: Test reply" in result

    def test_history_precedes_final_question(self):
        from solidrag.query.prompts import build_direct_prompt

        history = [{"role": "user", "content": "Earlier question"}]
        result = build_direct_prompt("Final question", history)
        pos_history = result.find("Earlier question")
        pos_question = result.find("Final question")
        assert pos_history < pos_question


class TestBuildRagPrompt:
    def test_context_str_in_output(self):
        from solidrag.query.prompts import build_rag_prompt

        result = build_rag_prompt(
            system_prompt="You are a helpful assistant.",
            context_str="This is the retrieved context.",
            question="What did I write about cats?",
            history=None,
        )
        assert "This is the retrieved context." in result

    def test_system_prompt_used(self):
        from solidrag.query.prompts import build_rag_prompt

        custom_system = "You are a custom assistant for testing."
        result = build_rag_prompt(
            system_prompt=custom_system,
            context_str="some context",
            question="test question",
            history=None,
        )
        assert custom_system in result

    def test_question_in_output(self):
        from solidrag.query.prompts import build_rag_prompt

        result = build_rag_prompt(
            system_prompt="System.",
            context_str="Context.",
            question="My specific question?",
            history=None,
        )
        assert "My specific question?" in result

    def test_history_included_when_provided(self):
        from solidrag.query.prompts import build_rag_prompt

        history = [
            {"role": "user", "content": "Earlier msg"},
            {"role": "assistant", "content": "Earlier reply"},
        ]
        result = build_rag_prompt(
            system_prompt="Sys.",
            context_str="Ctx.",
            question="New Q?",
            history=history,
        )
        assert "Earlier msg" in result
        assert "Earlier reply" in result

    def test_ends_with_answer_prompt(self):
        from solidrag.query.prompts import build_rag_prompt

        result = build_rag_prompt("Sys.", "Ctx.", "Q?", None)
        assert result.strip().endswith("Answer:")


# ---------------------------------------------------------------------------
# Engine tests — _needs_vault_async
# ---------------------------------------------------------------------------

class TestNeedsVaultYes:
    def test_returns_true_on_yes_response(self):
        from solidrag.query import engine as eng

        mock_result = MagicMock()
        mock_result.__str__ = lambda self: "YES"

        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)

        with patch.object(eng, "_get_llm", return_value=mock_llm):
            result = _run(eng._needs_vault_async("What did I write about my trip?"))

        assert result is True

    def test_returns_true_on_yes_with_whitespace(self):
        from solidrag.query import engine as eng

        mock_result = MagicMock()
        mock_result.__str__ = lambda self: "  yes  "

        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)

        with patch.object(eng, "_get_llm", return_value=mock_llm):
            result = _run(eng._needs_vault_async("Tell me about my notes"))

        assert result is True


class TestNeedsVaultNo:
    def test_returns_false_on_no_response(self):
        from solidrag.query import engine as eng

        mock_result = MagicMock()
        mock_result.__str__ = lambda self: "NO"

        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)

        with patch.object(eng, "_get_llm", return_value=mock_llm):
            result = _run(eng._needs_vault_async("What is the capital of France?"))

        assert result is False

    def test_returns_false_on_empty_response(self):
        from solidrag.query import engine as eng

        mock_result = MagicMock()
        mock_result.__str__ = lambda self: ""

        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)

        with patch.object(eng, "_get_llm", return_value=mock_llm):
            result = _run(eng._needs_vault_async("Hello"))

        assert result is False


# ---------------------------------------------------------------------------
# Engine tests — _extract_relevant_sources
# ---------------------------------------------------------------------------

def _make_node(file_path: str, score: float, content: str = "some text") -> MagicMock:
    """Create a mock node with the given file_path, score, and content."""
    node = MagicMock()
    node.metadata = {"file_path": file_path}
    node.score = score
    node.get_content.return_value = content
    return node


class TestExtractSourcesDedup:
    def test_two_nodes_same_file_one_kept(self):
        from solidrag.query.engine import _extract_relevant_sources

        nodes = [
            _make_node("/vault/notes.md", 0.1),
            _make_node("/vault/notes.md", 0.2),  # same file, worse score
        ]
        sources = _run(_extract_relevant_sources(nodes))
        # Only one entry per file
        files = [s["file"] for s in sources]
        assert len([f for f in files if "notes.md" in f]) == 1

    def test_best_score_per_file_kept(self):
        from solidrag.query.engine import _extract_relevant_sources

        nodes = [
            _make_node("/vault/notes.md", 0.5),
            _make_node("/vault/notes.md", 0.1),  # better score (lower L2)
        ]
        sources = _run(_extract_relevant_sources(nodes))
        # Should keep the node — just verifying it doesn't crash and returns 1 entry
        assert len(sources) == 1

    def test_different_files_kept_separately(self):
        from solidrag.query.engine import _extract_relevant_sources

        nodes = [
            _make_node("/vault/a.md", 0.1),
            _make_node("/vault/b.md", 0.15),
        ]
        sources = _run(_extract_relevant_sources(nodes))
        assert len(sources) == 2


class TestExtractSourcesScoreFilter:
    def test_node_outside_threshold_excluded(self):
        from solidrag.query.engine import _extract_relevant_sources

        nodes = [
            _make_node("/vault/best.md", 0.1),
            _make_node("/vault/far.md", 0.4),   # 0.1 + 0.25 = 0.35 threshold, 0.4 > 0.35
        ]
        sources = _run(_extract_relevant_sources(nodes))
        files = [s["file"] for s in sources]
        assert any("best.md" in f for f in files)
        assert not any("far.md" in f for f in files)

    def test_node_within_threshold_included(self):
        from solidrag.query.engine import _extract_relevant_sources

        nodes = [
            _make_node("/vault/best.md", 0.1),
            _make_node("/vault/close.md", 0.3),   # 0.1 + 0.25 = 0.35, 0.3 <= 0.35
        ]
        sources = _run(_extract_relevant_sources(nodes))
        assert len(sources) == 2

    def test_empty_nodes_returns_empty(self):
        from solidrag.query.engine import _extract_relevant_sources

        sources = _run(_extract_relevant_sources([]))
        assert sources == []

    def test_max_sources_cap_respected(self):
        from solidrag.query.engine import _extract_relevant_sources

        # Create 10 nodes with similar scores (all within threshold)
        nodes = [_make_node(f"/vault/note_{i}.md", 0.1 + i * 0.01) for i in range(10)]
        sources = _run(_extract_relevant_sources(nodes, max_sources=3))
        assert len(sources) <= 3


# ---------------------------------------------------------------------------
# Engine tests — query_stream_async
# ---------------------------------------------------------------------------

class TestQueryStreamIndexNone:
    def test_yields_not_ready_token(self):
        from solidrag.query.engine import query_stream_async

        events = _run(_collect(query_stream_async(None, "test question")))
        token_events = [e for e in events if e["type"] == "token"]
        assert len(token_events) >= 1
        combined = "".join(e["content"] for e in token_events)
        assert "not ready" in combined.lower() or "Index" in combined

    def test_yields_empty_sources_and_done(self):
        from solidrag.query.engine import query_stream_async

        events = _run(_collect(query_stream_async(None, "test question")))
        sources_events = [e for e in events if e["type"] == "sources"]
        done_events = [e for e in events if e["type"] == "done"]
        assert len(sources_events) == 1
        assert sources_events[0]["sources"] == []
        assert len(done_events) == 1


class TestQueryStreamDirectPath:
    def test_direct_path_no_retrieval(self):
        """When _needs_vault returns False, the retriever is never called."""
        from solidrag.query import engine as eng

        mock_chunk = MagicMock()
        mock_chunk.delta = "Hello world"

        mock_llm = MagicMock()
        mock_llm.astream_complete = AsyncMock(
            return_value=_async_iter([mock_chunk])
        )

        mock_index = MagicMock()
        mock_index.as_retriever = MagicMock()

        with (
            patch.object(eng, "_needs_vault_async", new=AsyncMock(return_value=False)),
            patch.object(eng, "_get_llm", return_value=mock_llm),
        ):
            events = _run(_collect(eng.query_stream_async(mock_index, "What is 2+2?")))

        # Retriever should not have been called
        mock_index.as_retriever.assert_not_called()

        # Should have token events and empty sources
        token_events = [e for e in events if e["type"] == "token"]
        sources_events = [e for e in events if e["type"] == "sources"]
        assert len(token_events) >= 1
        assert sources_events[0]["sources"] == []

    def test_direct_path_yields_done(self):
        from solidrag.query import engine as eng

        mock_chunk = MagicMock()
        mock_chunk.delta = "answer"

        mock_llm = MagicMock()
        mock_llm.astream_complete = AsyncMock(
            return_value=_async_iter([mock_chunk])
        )

        mock_index = MagicMock()

        with (
            patch.object(eng, "_needs_vault_async", new=AsyncMock(return_value=False)),
            patch.object(eng, "_get_llm", return_value=mock_llm),
        ):
            events = _run(_collect(eng.query_stream_async(mock_index, "Hi")))

        done_events = [e for e in events if e["type"] == "done"]
        assert len(done_events) == 1


class TestQueryStreamRagPath:
    def test_rag_path_yields_sources(self):
        """When _needs_vault returns True, sources are returned from retrieved nodes."""
        from solidrag.query import engine as eng

        mock_chunk = MagicMock()
        mock_chunk.delta = "Based on your notes"

        mock_llm = MagicMock()
        mock_llm.astream_complete = AsyncMock(
            return_value=_async_iter([mock_chunk])
        )

        mock_node = _make_node("/vault/diary.md", 0.1, "Some diary content")

        mock_retriever = MagicMock()
        mock_retriever.aretrieve = AsyncMock(return_value=[mock_node])

        mock_index = MagicMock()
        mock_index.as_retriever.return_value = mock_retriever

        with (
            patch.object(eng, "_needs_vault_async", new=AsyncMock(return_value=True)),
            patch.object(eng, "_get_llm", return_value=mock_llm),
        ):
            events = _run(_collect(eng.query_stream_async(
                mock_index,
                "What did I write in my diary?",
            )))

        sources_events = [e for e in events if e["type"] == "sources"]
        assert len(sources_events) == 1
        # Sources should include the diary file
        sources = sources_events[0]["sources"]
        assert len(sources) >= 1
        assert any("diary.md" in s["file"] for s in sources)

    def test_rag_path_calls_retriever(self):
        from solidrag.query import engine as eng

        mock_chunk = MagicMock()
        mock_chunk.delta = "answer"

        mock_llm = MagicMock()
        mock_llm.astream_complete = AsyncMock(
            return_value=_async_iter([mock_chunk])
        )

        mock_node = _make_node("/vault/notes.md", 0.1, "Notes content")
        mock_retriever = MagicMock()
        mock_retriever.aretrieve = AsyncMock(return_value=[mock_node])

        mock_index = MagicMock()
        mock_index.as_retriever.return_value = mock_retriever

        with (
            patch.object(eng, "_needs_vault_async", new=AsyncMock(return_value=True)),
            patch.object(eng, "_get_llm", return_value=mock_llm),
        ):
            _run(_collect(eng.query_stream_async(mock_index, "What are my notes?")))

        mock_index.as_retriever.assert_called_once()
        mock_retriever.aretrieve.assert_called_once()

    def test_rag_path_yields_done(self):
        from solidrag.query import engine as eng

        mock_chunk = MagicMock()
        mock_chunk.delta = "response"

        mock_llm = MagicMock()
        mock_llm.astream_complete = AsyncMock(
            return_value=_async_iter([mock_chunk])
        )

        mock_node = _make_node("/vault/n.md", 0.05, "content")
        mock_retriever = MagicMock()
        mock_retriever.aretrieve = AsyncMock(return_value=[mock_node])

        mock_index = MagicMock()
        mock_index.as_retriever.return_value = mock_retriever

        with (
            patch.object(eng, "_needs_vault_async", new=AsyncMock(return_value=True)),
            patch.object(eng, "_get_llm", return_value=mock_llm),
        ):
            events = _run(_collect(eng.query_stream_async(mock_index, "Q?")))

        done_events = [e for e in events if e["type"] == "done"]
        assert len(done_events) == 1


# ---------------------------------------------------------------------------
# Helpers for async iteration mocking
# ---------------------------------------------------------------------------

async def _async_iter(items):
    """Yield items one by one as an async iterable."""
    for item in items:
        yield item
