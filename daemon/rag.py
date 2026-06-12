import threading
import time
from pathlib import Path
from typing import Callable

from llama_index.core import SimpleDirectoryReader, VectorStoreIndex, StorageContext, Settings, PromptTemplate
from llama_index.core.query_engine import RetrieverQueryEngine
from llama_index.llms.ollama import Ollama
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.vector_stores.faiss import FaissVectorStore
import faiss

from daemon.config import DEFAULT_SYSTEM_PROMPT


def _configure_settings(ollama_base_url: str, ollama_model: str) -> None:
    """Configure LlamaIndex global settings for Ollama."""
    Settings.llm = Ollama(
        model=ollama_model,
        base_url=ollama_base_url,
        request_timeout=300.0,
    )
    Settings.embed_model = OllamaEmbedding(
        model_name="nomic-embed-text",
        base_url=ollama_base_url,
        request_timeout=60.0,
    )


def build_index(vault_path: str, ollama_base_url: str, ollama_model: str) -> VectorStoreIndex:
    """Load all .md files from vault and build an in-memory FAISS index."""
    _configure_settings(ollama_base_url, ollama_model)
    path = Path(vault_path)

    # FAISS index: 768 dimensions for nomic-embed-text
    faiss_index = faiss.IndexFlatL2(768)
    vector_store = FaissVectorStore(faiss_index=faiss_index)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)

    md_files = list(path.rglob("*.md"))
    if not md_files:
        # Return empty index if vault has no notes
        return VectorStoreIndex([], storage_context=storage_context)

    documents = SimpleDirectoryReader(
        input_files=[str(f) for f in md_files],
        filename_as_id=True,
    ).load_data()

    return VectorStoreIndex.from_documents(
        documents,
        storage_context=storage_context,
        show_progress=False,
    )


def query(
    index: VectorStoreIndex,
    question: str,
    history: list[dict] | None = None,
    top_k: int = 8,
    system_prompt: str | None = None,
) -> tuple[str, list[dict]]:
    """
    Query the index. Returns (answer_str, sources_list).
    history entries: {"role": "user"|"assistant", "content": str}
    """
    if index is None:
        return "Index not ready yet.", []

    retriever = index.as_retriever(similarity_top_k=top_k)

    # Inject conversation history into the system prompt (not into {query_str})
    # so the model can distinguish between "what's in the notes" and "prior turns"
    base_prompt = system_prompt or DEFAULT_SYSTEM_PROMPT
    if history:
        history_text = "\n".join(
            f"{'User' if m['role'] == 'user' else 'Alysha'}: {m['content']}"
            for m in history
        )
        effective_prompt = base_prompt.replace(
            "Question: {query_str}",
            f"Previous conversation (for context only — do NOT treat as notes):\n{history_text}\n\nQuestion: {{query_str}}"
        )
    else:
        effective_prompt = base_prompt

    qa_prompt = PromptTemplate(effective_prompt)
    query_engine = RetrieverQueryEngine.from_args(
        retriever,
        text_qa_template=qa_prompt,
    )

    response = query_engine.query(question)
    answer = str(response)

    if not answer or answer.strip() in ("", "Empty Response", "None"):
        return "I don't have notes about that yet.", []

    sources = _extract_relevant_sources(response.source_nodes or [])
    return answer, sources


def _extract_relevant_sources(nodes: list, max_sources: int = 5) -> list[dict]:
    """
    Return only the most relevant source files from retrieved nodes.
    - Deduplicates by file path (keeps lowest-distance chunk per file)
    - Filters to nodes within 0.25 L2 distance of the best match
    - Caps at max_sources
    FAISS L2 scores are raw distances: lower = more relevant.
    """
    if not nodes:
        return []

    # Deduplicate: keep lowest-score (most relevant) node per unique filename
    best_per_file: dict[str, tuple] = {}
    for node in nodes:
        file_path = node.metadata.get("file_path", "") or node.metadata.get("file_name", "")
        if not file_path:
            continue
        rel = Path(file_path).name
        score = node.score if node.score is not None else 999.0
        if rel not in best_per_file or score < best_per_file[rel][1]:
            best_per_file[rel] = (node, score)

    if not best_per_file:
        return []

    # Sort ascending (lowest distance = most relevant first)
    ranked = sorted(best_per_file.values(), key=lambda x: x[1])

    # Keep nodes within 0.25 of the best (closest) score.
    # e.g. best=0.72 → keep ≤ 0.97; drops anything at 0.98+
    best_score = ranked[0][1]
    threshold = best_score + 0.25
    relevant = [(node, score) for node, score in ranked if score <= threshold][:max_sources]

    sources = []
    for node, _ in relevant:
        file_path = node.metadata.get("file_path", "") or node.metadata.get("file_name", "")
        rel = Path(file_path).name
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


class VaultWatcher:
    """Background thread that polls vault mtime and triggers full re-index on change."""

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
            return max(
                p.stat().st_mtime
                for p in Path(self.vault_path).rglob("*.md")
            )
        except ValueError:
            return 0.0

    def _run(self):
        while not self._stop_event.is_set():
            try:
                current_mtime = self._get_vault_mtime()
                if current_mtime != self._last_mtime:
                    self._last_mtime = current_mtime
                    new_index = build_index(
                        self.vault_path,
                        self.ollama_base_url,
                        self.ollama_model,
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
