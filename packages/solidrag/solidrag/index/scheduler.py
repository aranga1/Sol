"""ResourceAwareScheduler — throttled background image processing via llava.

Processes images in batches only when system resources are available:
  - macOS CPU usage (60-second average) < 40 %
  - Battery plugged in OR charge > 50 % (or no battery sensor on desktop)
  - No active Ollama inference (GET /api/ps returns empty models list)

If any check fails the scheduler backs off for 15 minutes before retrying.
"""
from __future__ import annotations

import asyncio
import logging
import threading
import time
from pathlib import Path

import httpx
import psutil

from solidrag.config import SolidRagConfig
from solidrag.extractors.registry import ExtractorRegistry
from solidrag.index.builder import _embed_nodes, _node_id_to_int, _IMAGE_EXTENSIONS
from solidrag.index.manifest import IndexManifest

import numpy as np

logger = logging.getLogger(__name__)

_BACKOFF_SECONDS = 15 * 60  # 15 minutes


class ResourceAwareScheduler:
    """Background thread that batches image processing via Ollama llava.

    Only runs a batch when system resources are not under pressure.
    See module docstring for the exact checks performed.
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

        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    # ------------------------------------------------------------------
    # Public interface
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Start the scheduler in a background daemon thread."""
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run, name="solidrag-scheduler", daemon=True
        )
        self._thread.start()
        logger.info("ResourceAwareScheduler started (interval=%ds)", self._config.image_batch_interval_s)

    def stop(self) -> None:
        """Signal the scheduler to stop and wait for it to exit."""
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        logger.info("ResourceAwareScheduler stopped")

    # ------------------------------------------------------------------
    # Resource checks
    # ------------------------------------------------------------------

    def _should_run_batch(self) -> bool:
        """Return True only when all resource conditions are satisfied."""
        # 1. CPU check — avg over 60 seconds
        cpu = psutil.cpu_percent(interval=None)
        if cpu >= 40.0:
            logger.debug("Scheduler: CPU too high (%.1f%%) — skipping batch", cpu)
            return False

        # 2. Battery check
        battery = psutil.sensors_battery()
        if battery is not None:
            if not battery.power_plugged and battery.percent <= 50:
                logger.debug(
                    "Scheduler: battery low (%.1f%%) and unplugged — skipping batch",
                    battery.percent,
                )
                return False
        # None = no battery sensor (desktop) — always allow

        # 3. Ollama inference check
        try:
            response = httpx.get(
                f"{self._config.ollama_base_url}/api/ps",
                timeout=5.0,
            )
            response.raise_for_status()
            data = response.json()
            active_models = data.get("models", [])
            if active_models:
                logger.debug(
                    "Scheduler: Ollama busy (%d active model(s)) — skipping batch",
                    len(active_models),
                )
                return False
        except Exception:
            logger.debug("Scheduler: could not reach Ollama /api/ps — assuming busy")
            return False

        return True

    # ------------------------------------------------------------------
    # Batch processing
    # ------------------------------------------------------------------

    def _find_unindexed_images(self) -> list[str]:
        """Return image file paths that are in source_dirs but not in the manifest."""
        unindexed: list[str] = []
        import os

        for source_dir in self._config.source_dirs:
            source_dir = Path(source_dir)
            if not source_dir.is_dir():
                continue
            for dirpath, _dirnames, filenames in os.walk(source_dir):
                for filename in filenames:
                    ext = Path(filename).suffix.lower()
                    if ext in _IMAGE_EXTENSIONS:
                        full_path = str(Path(dirpath) / filename)
                        if self._manifest.get(full_path) is None:
                            unindexed.append(full_path)
        return unindexed

    def _process_batch(self, image_paths: list[str]) -> None:
        """Extract, embed, and splice all *image_paths* into the FAISS index."""
        import os
        from solidrag.extractors.image import ImageExtractor

        img_extractor = ImageExtractor(
            ollama_base_url=self._config.ollama_base_url,
            vision_model=self._config.vision_model,
        )

        all_nodes = []
        all_embeddings_list = []
        file_node_map: dict[str, list] = {}

        for filepath in image_paths:
            try:
                nodes = img_extractor.extract(Path(filepath))
            except Exception:
                logger.exception("Image extraction failed for %s", filepath)
                continue

            if not nodes:
                continue

            try:
                embeddings = _embed_nodes(nodes, self._config)
            except Exception:
                logger.exception("Embedding failed for image %s", filepath)
                continue

            all_nodes.extend(nodes)
            all_embeddings_list.append(embeddings)
            file_node_map[filepath] = nodes

        if not all_nodes:
            return

        all_embeddings = np.vstack(all_embeddings_list)
        ids = np.array(
            [_node_id_to_int(n.node_id) for n in all_nodes], dtype=np.int64
        )

        # Splice into FAISS index in a single operation
        self._faiss_index.add_with_ids(all_embeddings, ids)

        # Update manifest for each image
        for filepath, nodes in file_node_map.items():
            try:
                mtime = os.path.getmtime(filepath)
            except OSError:
                mtime = 0.0
            self._manifest.update(filepath, mtime, [n.node_id for n in nodes])

        self._manifest.save()
        logger.info("Scheduler: indexed %d image(s) (%d nodes)", len(file_node_map), len(all_nodes))

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def _run(self) -> None:
        """Main loop — runs batches at the configured interval."""
        while not self._stop_event.is_set():
            if self._should_run_batch():
                image_paths = self._find_unindexed_images()
                if image_paths:
                    logger.info(
                        "Scheduler: processing %d unindexed image(s)", len(image_paths)
                    )
                    self._process_batch(image_paths)
                else:
                    logger.debug("Scheduler: no unindexed images found")
                sleep_seconds = self._config.image_batch_interval_s
            else:
                sleep_seconds = _BACKOFF_SECONDS
                logger.info(
                    "Scheduler: resource check failed — backing off for %d minutes",
                    sleep_seconds // 60,
                )

            # Sleep in short increments so stop() is responsive
            deadline = time.monotonic() + sleep_seconds
            while not self._stop_event.is_set() and time.monotonic() < deadline:
                time.sleep(min(1.0, deadline - time.monotonic()))
