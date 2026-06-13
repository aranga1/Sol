"""solidRag node content store — persists text content for FAISS-indexed nodes.

FAISS stores vectors, not text. NodeStore maps node_id → (content, file_path)
so the query engine can reconstruct TextNode content from FAISS search results.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path

logger = logging.getLogger(__name__)

_Entry = dict  # {"content": str, "file_path": str}


class NodeStore:
    """Persistent mapping of node_id (str UUID) → text content + source path."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._data: dict[str, _Entry] = {}

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def load(self) -> None:
        if not self._path.exists():
            return
        try:
            with open(self._path) as f:
                self._data = json.load(f)
        except Exception:
            logger.exception("Failed to load nodestore from %s — starting empty", self._path)
            self._data = {}

    def save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._path.with_suffix(".tmp")
        with open(tmp, "w") as f:
            json.dump(self._data, f)
        os.replace(tmp, self._path)

    # ------------------------------------------------------------------
    # Mutations
    # ------------------------------------------------------------------

    def add(self, node_id: str, content: str, file_path: str) -> None:
        self._data[node_id] = {"content": content, "file_path": file_path}

    def delete(self, node_id: str) -> None:
        self._data.pop(node_id, None)

    def delete_many(self, node_ids: list[str]) -> None:
        for nid in node_ids:
            self._data.pop(nid, None)

    # ------------------------------------------------------------------
    # Lookups
    # ------------------------------------------------------------------

    def get_content(self, node_id: str) -> str | None:
        entry = self._data.get(node_id)
        return entry["content"] if entry else None

    def get_file_path(self, node_id: str) -> str | None:
        entry = self._data.get(node_id)
        return entry["file_path"] if entry else None

    def all_node_ids(self) -> list[str]:
        return list(self._data.keys())

    def __len__(self) -> int:
        return len(self._data)
