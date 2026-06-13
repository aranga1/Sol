"""IndexManifest — tracks which files have been indexed and their vector IDs.

Stores per-file mtime and node_ids so incremental updates can detect
new, modified, and deleted files without re-scanning the full FAISS index.
Writes are atomic via a tmp file + rename to prevent corruption on crash.
"""
from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class ManifestEntry:
    """Metadata for a single indexed file."""

    mtime: float
    node_ids: list[str] = field(default_factory=list)


class IndexManifest:
    """Persistent manifest mapping file paths to their index metadata.

    The manifest is a JSON file stored at *path*.  All mutations are
    in-memory; call :meth:`save` to persist.
    """

    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._entries: dict[str, ManifestEntry] = {}
        self._sources: dict[str, dict[str, ManifestEntry]] = {}

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def load(self) -> None:
        """Load manifest from disk.

        If the file is missing or contains invalid JSON, the manifest
        starts fresh (empty).  This is the recovery path for corruption.

        Supports both the legacy flat format (filepath -> entry dict) and
        the new structured format with ``files`` and ``sources`` keys.
        """
        if not self._path.exists():
            self._entries = {}
            self._sources = {}
            return

        try:
            raw = self._path.read_text(encoding="utf-8")
            data: dict = json.loads(raw)
            self._entries = {
                filepath: ManifestEntry(
                    mtime=float(entry["mtime"]),
                    node_ids=list(entry.get("node_ids", [])),
                )
                for filepath, entry in data.get("files", data).items()
                if isinstance(entry, dict) and "mtime" in entry
            }
            raw_sources = data.get("sources", {})
            self._sources = {
                source_id: {
                    key: ManifestEntry(
                        mtime=float(e["mtime"]),
                        node_ids=list(e.get("node_ids", [])),
                    )
                    for key, e in entries.items()
                }
                for source_id, entries in raw_sources.items()
            }
        except (json.JSONDecodeError, KeyError, ValueError, TypeError):
            # Corrupt manifest — start fresh
            self._entries = {}
            self._sources = {}

    def save(self) -> None:
        """Atomically persist the manifest to disk.

        Writes to a temporary file in the same directory then renames it
        so the manifest is never partially written.

        The on-disk format uses ``files`` and ``sources`` top-level keys.
        Legacy flat manifests are upgraded automatically on the next save.
        """
        self._path.parent.mkdir(parents=True, exist_ok=True)

        data = {
            "files": {
                filepath: {"mtime": entry.mtime, "node_ids": entry.node_ids}
                for filepath, entry in self._entries.items()
            },
            "sources": {
                source_id: {
                    key: {"mtime": e.mtime, "node_ids": e.node_ids}
                    for key, e in entries.items()
                }
                for source_id, entries in self._sources.items()
            },
        }

        tmp_fd, tmp_name = tempfile.mkstemp(
            dir=self._path.parent, suffix=".tmp"
        )
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as fh:
                json.dump(data, fh, indent=2)
            os.replace(tmp_name, self._path)
        except Exception:
            # Clean up the temp file if anything went wrong
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise

    # ------------------------------------------------------------------
    # Query / mutation
    # ------------------------------------------------------------------

    def get(self, filepath: str) -> ManifestEntry | None:
        """Return the entry for *filepath*, or None if not tracked."""
        return self._entries.get(filepath)

    def update(self, filepath: str, mtime: float, node_ids: list[str]) -> None:
        """Insert or replace the entry for *filepath*."""
        self._entries[filepath] = ManifestEntry(mtime=mtime, node_ids=list(node_ids))

    def remove(self, filepath: str) -> None:
        """Remove the entry for *filepath* (no-op if absent)."""
        self._entries.pop(filepath, None)

    def all_paths(self) -> set[str]:
        """Return the set of all tracked file paths."""
        return set(self._entries.keys())

    # ------------------------------------------------------------------
    # Source namespace — for non-file sources (e.g. calendar events)
    # ------------------------------------------------------------------

    def get_source(self, source_id: str, key: str) -> ManifestEntry | None:
        """Return the entry for *key* within *source_id*, or None if absent."""
        return self._sources.get(source_id, {}).get(key)

    def update_source(self, source_id: str, key: str, mtime: float, node_ids: list[str]) -> None:
        """Insert or replace the entry for *key* within *source_id*."""
        if source_id not in self._sources:
            self._sources[source_id] = {}
        self._sources[source_id][key] = ManifestEntry(mtime=mtime, node_ids=list(node_ids))

    def remove_source(self, source_id: str, key: str) -> None:
        """Remove the entry for *key* within *source_id* (no-op if absent)."""
        if source_id in self._sources:
            self._sources[source_id].pop(key, None)
            if not self._sources[source_id]:
                del self._sources[source_id]

    def all_source_keys(self, source_id: str) -> set[str]:
        """Return the set of all tracked keys for *source_id*."""
        return set(self._sources.get(source_id, {}).keys())

    # ------------------------------------------------------------------
    # Diff
    # ------------------------------------------------------------------

    def diff(
        self, current_files: dict[str, float]
    ) -> tuple[list[str], list[str], list[str]]:
        """Compare *current_files* against the manifest.

        Args:
            current_files: Mapping of filepath -> current mtime from the
                filesystem scan.

        Returns:
            A 3-tuple ``(new_files, modified_files, deleted_files)`` where:

            * ``new_files``      — paths in *current_files* not in the manifest.
            * ``modified_files`` — paths in both but with a changed mtime.
            * ``deleted_files``  — paths in the manifest absent from *current_files*.
        """
        manifest_paths = self.all_paths()
        current_paths = set(current_files.keys())

        new_files = sorted(current_paths - manifest_paths)
        deleted_files = sorted(manifest_paths - current_paths)
        modified_files = sorted(
            p
            for p in current_paths & manifest_paths
            if current_files[p] != self._entries[p].mtime
        )

        return new_files, modified_files, deleted_files
