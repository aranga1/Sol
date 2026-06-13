"""CalendarWatcher — polls CalendarExtractor every N seconds and applies diffs.

Runs on a background daemon thread. Calls CalendarExtractor.sync() on each
tick and invokes on_diff_ready only when the diff is non-empty.
"""
from __future__ import annotations

import logging
import threading
from typing import Callable, TYPE_CHECKING

from solidrag.extractors.calendar import CalendarExtractor
from solidrag.extractors.base import IndexDiff

if TYPE_CHECKING:
    from solidrag.index.manifest import IndexManifest

logger = logging.getLogger(__name__)


class CalendarWatcher:
    """Background thread that polls EKEventStore and emits IndexDiff on change.

    Args:
        manifest:      The shared IndexManifest (mutated by CalendarExtractor.sync).
        on_diff_ready: Callback invoked with an IndexDiff when changes detected.
        poll_interval: Seconds between polls (default 60).
        _extractor:    Injectable CalendarExtractor (for tests).
    """

    def __init__(
        self,
        manifest: IndexManifest,
        on_diff_ready: Callable[[IndexDiff], None],
        poll_interval: int = 60,
        _extractor: CalendarExtractor | None = None,
    ) -> None:
        self._manifest = manifest
        self._on_diff_ready = on_diff_ready
        self._poll_interval = poll_interval
        self._extractor = _extractor or CalendarExtractor()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        logger.info("CalendarWatcher started (interval=%ds)", self._poll_interval)

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        logger.info("CalendarWatcher stopped")

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                diff = self._extractor.sync(self._manifest)
                if diff.to_add or diff.to_update or diff.to_delete:
                    self._on_diff_ready(diff)
            except Exception:
                logger.exception("CalendarWatcher: sync error")
            self._stop_event.wait(self._poll_interval)
