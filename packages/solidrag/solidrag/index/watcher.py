"""SourceWatcher — watchdog-based background watcher for source directories.

Watches *.md, *.pdf, *.xlsx (and other non-image registered extensions).
Debounces rapid file-system events into a single incremental_update call
with a 2-second coalescing window.
"""
from __future__ import annotations

import asyncio
import logging
import threading
from pathlib import Path

from watchdog.events import FileSystemEventHandler, FileSystemEvent
from watchdog.observers import Observer

from solidrag.config import SolidRagConfig
from solidrag.extractors.registry import ExtractorRegistry
from solidrag.index.builder import incremental_update
from solidrag.index.manifest import IndexManifest

logger = logging.getLogger(__name__)

# Image extensions are handled by the scheduler; ignore them in the watcher.
_IMAGE_EXTENSIONS: frozenset[str] = frozenset(
    {".jpg", ".jpeg", ".png", ".gif", ".webp"}
)

_DEBOUNCE_SECONDS = 2.0


class _DebounceHandler(FileSystemEventHandler):
    """Watchdog event handler that debounces events into a single callback."""

    def __init__(self, watcher: "SourceWatcher") -> None:
        super().__init__()
        self._watcher = watcher

    def on_any_event(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        src = getattr(event, "src_path", "")
        ext = Path(src).suffix.lower()
        if ext in _IMAGE_EXTENSIONS:
            return
        self._watcher._on_change_event()


class SourceWatcher:
    """Background file-system watcher that triggers incremental index updates.

    Uses watchdog's :class:`Observer` to monitor *config.source_dirs* for
    changes to non-image files.  Rapid saves are coalesced via a 2-second
    debounce timer so that ``incremental_update`` is called at most once per
    burst of activity.
    """

    def __init__(
        self,
        config: SolidRagConfig,
        faiss_index,
        manifest: IndexManifest,
        registry: ExtractorRegistry,
        lock: asyncio.Lock,
    ) -> None:
        self._config = config
        self._faiss_index = faiss_index
        self._manifest = manifest
        self._registry = registry
        self._lock = lock

        self._observer = Observer()
        self._handler = _DebounceHandler(self)

        # Debounce state
        self._debounce_timer: threading.Timer | None = None
        self._debounce_lock = threading.Lock()

    # ------------------------------------------------------------------
    # Public interface
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Start the watchdog observer in a background daemon thread."""
        for source_dir in self._config.source_dirs:
            source_dir = Path(source_dir)
            if source_dir.is_dir():
                self._observer.schedule(self._handler, str(source_dir), recursive=True)
            else:
                logger.warning("SourceWatcher: directory does not exist: %s", source_dir)

        self._observer.start()
        logger.info("SourceWatcher started, watching %d directories", len(self._config.source_dirs))

    def stop(self) -> None:
        """Stop the watchdog observer and cancel any pending debounce timer."""
        with self._debounce_lock:
            if self._debounce_timer is not None:
                self._debounce_timer.cancel()
                self._debounce_timer = None

        self._observer.stop()
        self._observer.join()
        logger.info("SourceWatcher stopped")

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _on_change_event(self) -> None:
        """Called on any relevant filesystem event; arms or resets the debounce timer."""
        with self._debounce_lock:
            if self._debounce_timer is not None:
                self._debounce_timer.cancel()
            self._debounce_timer = threading.Timer(
                _DEBOUNCE_SECONDS, self._fire_update
            )
            self._debounce_timer.daemon = True
            self._debounce_timer.start()

    def _fire_update(self) -> None:
        """Debounce timer expired — run incremental_update."""
        with self._debounce_lock:
            self._debounce_timer = None

        logger.debug("SourceWatcher debounce expired — running incremental_update")
        try:
            incremental_update(
                self._faiss_index,
                self._manifest,
                self._config,
                self._registry,
                self._lock,
            )
        except Exception:
            logger.exception("incremental_update raised an unhandled exception")
