import threading
import pytest
from unittest.mock import patch, MagicMock
from pathlib import Path

from daemon.rag import query, VaultWatcher, build_index


def test_query_returns_empty_message_when_no_notes():
    mock_index = MagicMock()
    mock_engine = MagicMock()
    mock_response = MagicMock()
    mock_response.__str__ = lambda self: ""
    mock_response.source_nodes = []
    mock_engine.query.return_value = mock_response
    with patch("daemon.rag.RetrieverQueryEngine") as MockEngine:
        MockEngine.from_args.return_value = mock_engine
        mock_index.as_retriever.return_value = MagicMock()
        answer, sources = query(mock_index, "What did I write about Python?")
    assert "don't have notes" in answer
    assert sources == []


def test_query_returns_none_index_message():
    answer, sources = query(None, "anything")
    assert "not ready" in answer.lower()
    assert sources == []


def test_query_extracts_sources():
    mock_index = MagicMock()
    mock_engine = MagicMock()
    mock_node = MagicMock()
    mock_node.metadata = {"file_path": "/vault/Notes/2026-06-11T10-00-00-text.md"}
    mock_node.get_content.return_value = "# My Note\nSome content"
    mock_response = MagicMock()
    mock_response.__str__ = lambda self: "Here is a real answer."
    mock_response.source_nodes = [mock_node]
    mock_engine.query.return_value = mock_response
    with patch("daemon.rag.RetrieverQueryEngine") as MockEngine:
        MockEngine.from_args.return_value = mock_engine
        mock_index.as_retriever.return_value = MagicMock()
        answer, sources = query(mock_index, "Tell me about my note")
    assert answer == "Here is a real answer."
    assert len(sources) == 1
    assert sources[0]["title"] == "My Note"
    assert "2026-06-11T10-00-00-text.md" in sources[0]["file"]


def test_vault_watcher_triggers_callback_on_mtime_change(tmp_path):
    (tmp_path / "note.md").write_text("# Test")

    callback_called = threading.Event()
    received_index = []

    def on_ready(idx):
        received_index.append(idx)
        callback_called.set()

    with patch("daemon.rag.build_index") as mock_build:
        mock_build.return_value = MagicMock()
        watcher = VaultWatcher(
            vault_path=str(tmp_path),
            ollama_base_url="http://localhost:11434",
            ollama_model="phi3.5",
            on_index_ready=on_ready,
            poll_interval=1,
        )
        watcher.start()
        callback_called.wait(timeout=5)
        watcher.stop()

    assert callback_called.is_set()
    assert len(received_index) >= 1


def test_query_skips_node_with_no_file_path():
    """Nodes missing file_path and file_name metadata are excluded from sources."""
    mock_index = MagicMock()
    mock_engine = MagicMock()
    mock_node = MagicMock()
    mock_node.metadata = {}
    mock_node.get_content.return_value = "Some content"
    mock_response = MagicMock()
    mock_response.__str__ = lambda self: "An answer."
    mock_response.source_nodes = [mock_node]
    mock_engine.query.return_value = mock_response
    with patch("daemon.rag.RetrieverQueryEngine") as MockEngine:
        MockEngine.from_args.return_value = mock_engine
        mock_index.as_retriever.return_value = MagicMock()
        answer, sources = query(mock_index, "Tell me something")
    assert answer == "An answer."
    assert sources == []


def test_query_uses_filename_fallback_for_title():
    """When no H1 heading, title is derived from filename."""
    mock_index = MagicMock()
    mock_engine = MagicMock()
    mock_node = MagicMock()
    mock_node.metadata = {"file_path": "/vault/Notes/my-project-notes.md"}
    mock_node.get_content.return_value = "No heading here, just text."
    mock_response = MagicMock()
    mock_response.__str__ = lambda self: "Answer."
    mock_response.source_nodes = [mock_node]
    mock_engine.query.return_value = mock_response
    with patch("daemon.rag.RetrieverQueryEngine") as MockEngine:
        MockEngine.from_args.return_value = mock_engine
        mock_index.as_retriever.return_value = MagicMock()
        answer, sources = query(mock_index, "project notes")
    assert sources[0]["title"] == "my project notes"
    assert sources[0]["file"] == "Notes/my-project-notes.md"


def test_vault_watcher_no_callback_if_no_change(tmp_path):
    """VaultWatcher should not call callback a second time if vault mtime hasn't changed."""
    (tmp_path / "note.md").write_text("# Stable")

    call_count = []
    first_call = threading.Event()

    def on_ready(idx):
        call_count.append(1)
        first_call.set()

    with patch("daemon.rag.build_index") as mock_build:
        mock_build.return_value = MagicMock()
        watcher = VaultWatcher(
            vault_path=str(tmp_path),
            ollama_base_url="http://localhost:11434",
            ollama_model="phi3.5",
            on_index_ready=on_ready,
            poll_interval=1,
        )
        watcher.start()
        # Wait for first callback
        first_call.wait(timeout=5)
        # Wait two more poll cycles to check no spurious second call
        import time
        time.sleep(2.5)
        watcher.stop()

    # Only one call should have occurred since mtime did not change
    assert len(call_count) == 1


def test_build_index_empty_vault(tmp_path):
    """build_index returns an index without error when vault has no .md files."""
    with patch("daemon.rag._configure_settings"), \
         patch("daemon.rag.faiss") as mock_faiss, \
         patch("daemon.rag.FaissVectorStore") as mock_store, \
         patch("daemon.rag.StorageContext") as mock_ctx, \
         patch("daemon.rag.VectorStoreIndex") as mock_vi:
        mock_faiss.IndexFlatL2.return_value = MagicMock()
        mock_store.return_value = MagicMock()
        mock_ctx.from_defaults.return_value = MagicMock()
        mock_vi.return_value = MagicMock()
        result = build_index(str(tmp_path), "http://localhost:11434", "phi3.5")
    mock_vi.assert_called_once()
    assert result is not None
