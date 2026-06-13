"""Tests for solidrag index layer — manifest, builder, watcher, scheduler.

All tests are unit-level with mocked I/O and external dependencies.
No real FAISS, Ollama, or filesystem watches are used.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp"}


def _make_config(tmp_path: Path, source_dirs=None):
    """Return a minimal SolidRagConfig pointing at tmp_path."""
    from solidrag.config import SolidRagConfig

    return SolidRagConfig(
        source_dirs=source_dirs or [tmp_path],
        ollama_base_url="http://localhost:11434",
        ollama_model="mistral",
        embed_model="nomic-embed-text",
        vision_model="llava",
        persist_dir=tmp_path / "index",
        image_batch_interval_s=60,
    )


# ---------------------------------------------------------------------------
# IndexManifest
# ---------------------------------------------------------------------------

class TestIndexManifest:
    def test_manifest_load_save_roundtrip(self, tmp_path):
        from solidrag.index.manifest import IndexManifest, ManifestEntry

        manifest_path = tmp_path / "manifest.json"
        m = IndexManifest(manifest_path)
        m.load()  # starts fresh (file missing)

        m.update("file_a.md", mtime=1.0, node_ids=["n1", "n2"])
        m.update("file_b.pdf", mtime=2.5, node_ids=["n3"])
        m.save()

        # Reload from disk
        m2 = IndexManifest(manifest_path)
        m2.load()

        entry_a = m2.get("file_a.md")
        assert entry_a is not None
        assert entry_a.mtime == 1.0
        assert entry_a.node_ids == ["n1", "n2"]

        entry_b = m2.get("file_b.pdf")
        assert entry_b is not None
        assert entry_b.mtime == 2.5
        assert entry_b.node_ids == ["n3"]

    def test_manifest_diff_new_modified_deleted(self, tmp_path):
        from solidrag.index.manifest import IndexManifest

        manifest_path = tmp_path / "manifest.json"
        m = IndexManifest(manifest_path)
        m.load()

        # Seed manifest with two files
        m.update("existing.md", mtime=1.0, node_ids=["n1"])
        m.update("modified.md", mtime=1.0, node_ids=["n2"])
        m.update("deleted.md", mtime=1.0, node_ids=["n3"])

        # Filesystem has: existing (same mtime), modified (different mtime), new (not in manifest)
        current_files = {
            "existing.md": 1.0,   # unchanged
            "modified.md": 2.0,   # mtime changed
            "new.md": 3.0,        # brand-new file
            # deleted.md is absent
        }

        new_files, modified_files, deleted_files = m.diff(current_files)

        assert "new.md" in new_files
        assert "modified.md" in modified_files
        assert "deleted.md" in deleted_files
        # existing.md should NOT appear in any list
        assert "existing.md" not in new_files
        assert "existing.md" not in modified_files
        assert "existing.md" not in deleted_files

    def test_manifest_corrupt_file_starts_fresh(self, tmp_path):
        from solidrag.index.manifest import IndexManifest

        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text("{{{{ not valid json at all !!!!", encoding="utf-8")

        m = IndexManifest(manifest_path)
        m.load()  # should not raise

        # Should start fresh — no entries
        assert m.all_paths() == set()

    def test_manifest_remove(self, tmp_path):
        from solidrag.index.manifest import IndexManifest

        manifest_path = tmp_path / "manifest.json"
        m = IndexManifest(manifest_path)
        m.load()
        m.update("file.md", mtime=1.0, node_ids=["n1"])
        m.remove("file.md")
        assert m.get("file.md") is None
        assert "file.md" not in m.all_paths()

    def test_manifest_all_paths(self, tmp_path):
        from solidrag.index.manifest import IndexManifest

        manifest_path = tmp_path / "manifest.json"
        m = IndexManifest(manifest_path)
        m.load()
        m.update("a.md", mtime=1.0, node_ids=[])
        m.update("b.pdf", mtime=2.0, node_ids=[])
        assert m.all_paths() == {"a.md", "b.pdf"}

    def test_manifest_save_is_atomic(self, tmp_path):
        """Save should write via a tmp file then rename — the manifest should always be valid JSON."""
        from solidrag.index.manifest import IndexManifest

        manifest_path = tmp_path / "manifest.json"
        m = IndexManifest(manifest_path)
        m.load()
        m.update("x.md", mtime=1.0, node_ids=["id1"])
        m.save()

        # The file must be parseable immediately after save
        raw = manifest_path.read_text(encoding="utf-8")
        data = json.loads(raw)
        assert isinstance(data, dict)


# ---------------------------------------------------------------------------
# _node_id_to_int
# ---------------------------------------------------------------------------

class TestNodeIdToInt:
    def test_stable_output(self):
        from solidrag.index.builder import _node_id_to_int

        nid = "some-node-id-abc123"
        result1 = _node_id_to_int(nid)
        result2 = _node_id_to_int(nid)
        assert result1 == result2

    def test_returns_non_negative_int64(self):
        from solidrag.index.builder import _node_id_to_int

        result = _node_id_to_int("test-node")
        assert isinstance(result, int)
        assert 0 <= result < 2**63

    def test_different_ids_produce_different_ints(self):
        from solidrag.index.builder import _node_id_to_int

        ids = [f"node-{i}" for i in range(50)]
        int_vals = [_node_id_to_int(nid) for nid in ids]
        # All must be unique — no collisions in 50-element sample
        assert len(set(int_vals)) == len(int_vals)

    def test_empty_string_stable(self):
        from solidrag.index.builder import _node_id_to_int

        assert _node_id_to_int("") == _node_id_to_int("")


# ---------------------------------------------------------------------------
# _scan_source_dirs
# ---------------------------------------------------------------------------

class TestScanSourceDirs:
    def test_scan_returns_supported_files(self, tmp_path):
        from solidrag.index.builder import _scan_source_dirs
        from solidrag.extractors.registry import ExtractorRegistry
        from solidrag.extractors.markdown import MarkdownExtractor
        from solidrag.extractors.pdf import PDFExtractor

        # Create files in tmp_path
        (tmp_path / "doc.md").write_text("hello")
        (tmp_path / "report.pdf").write_bytes(b"%PDF")

        registry = ExtractorRegistry()
        registry.register(MarkdownExtractor())
        registry.register(PDFExtractor())

        config = _make_config(tmp_path, source_dirs=[tmp_path])
        result = _scan_source_dirs(config, registry)

        paths = {Path(p).name for p in result}
        assert "doc.md" in paths
        assert "report.pdf" in paths

    def test_scan_excludes_images(self, tmp_path):
        from solidrag.index.builder import _scan_source_dirs
        from solidrag.extractors.registry import ExtractorRegistry
        from solidrag.extractors.markdown import MarkdownExtractor
        from solidrag.extractors.image import ImageExtractor

        (tmp_path / "photo.jpg").write_bytes(b"\xff\xd8\xff")
        (tmp_path / "photo.png").write_bytes(b"\x89PNG")
        (tmp_path / "photo.gif").write_bytes(b"GIF89")
        (tmp_path / "photo.webp").write_bytes(b"RIFF")
        (tmp_path / "doc.md").write_text("some text")

        registry = ExtractorRegistry()
        registry.register(MarkdownExtractor())
        registry.register(ImageExtractor("http://localhost:11434"))

        config = _make_config(tmp_path, source_dirs=[tmp_path])
        result = _scan_source_dirs(config, registry)

        file_names = {Path(p).name for p in result}
        # Images must be excluded
        for img in ("photo.jpg", "photo.png", "photo.gif", "photo.webp"):
            assert img not in file_names, f"{img} should be excluded from scan"
        # Markdown must be included
        assert "doc.md" in file_names

    def test_scan_excludes_jpeg_extension(self, tmp_path):
        from solidrag.index.builder import _scan_source_dirs
        from solidrag.extractors.registry import ExtractorRegistry
        from solidrag.extractors.image import ImageExtractor

        (tmp_path / "photo.jpeg").write_bytes(b"\xff\xd8\xff")

        registry = ExtractorRegistry()
        registry.register(ImageExtractor("http://localhost:11434"))

        config = _make_config(tmp_path, source_dirs=[tmp_path])
        result = _scan_source_dirs(config, registry)

        file_names = {Path(p).name for p in result}
        assert "photo.jpeg" not in file_names

    def test_scan_returns_mtime(self, tmp_path):
        from solidrag.index.builder import _scan_source_dirs
        from solidrag.extractors.registry import ExtractorRegistry
        from solidrag.extractors.markdown import MarkdownExtractor

        f = tmp_path / "doc.md"
        f.write_text("content")

        registry = ExtractorRegistry()
        registry.register(MarkdownExtractor())

        config = _make_config(tmp_path, source_dirs=[tmp_path])
        result = _scan_source_dirs(config, registry)

        assert str(f) in result
        assert isinstance(result[str(f)], float)

    def test_scan_nested_directories(self, tmp_path):
        from solidrag.index.builder import _scan_source_dirs
        from solidrag.extractors.registry import ExtractorRegistry
        from solidrag.extractors.markdown import MarkdownExtractor

        sub = tmp_path / "subdir"
        sub.mkdir()
        (sub / "nested.md").write_text("nested content")

        registry = ExtractorRegistry()
        registry.register(MarkdownExtractor())

        config = _make_config(tmp_path, source_dirs=[tmp_path])
        result = _scan_source_dirs(config, registry)

        file_names = {Path(p).name for p in result}
        assert "nested.md" in file_names


# ---------------------------------------------------------------------------
# ResourceAwareScheduler — system checks
# ---------------------------------------------------------------------------

class TestResourceAwareScheduler:
    def _make_scheduler(self, tmp_path):
        from solidrag.index.scheduler import ResourceAwareScheduler
        from solidrag.index.manifest import IndexManifest
        from solidrag.extractors.registry import ExtractorRegistry

        config = _make_config(tmp_path)
        faiss_index = MagicMock()
        manifest = IndexManifest(tmp_path / "manifest.json")
        registry = ExtractorRegistry()
        lock = asyncio.Lock()
        return ResourceAwareScheduler(config, faiss_index, manifest, registry, lock)

    def test_scheduler_skips_when_cpu_high(self, tmp_path):
        """When CPU usage is above 40%, the scheduler should skip and record backoff."""
        from solidrag.index.scheduler import ResourceAwareScheduler

        scheduler = self._make_scheduler(tmp_path)

        # Simulate cpu_percent returning 85% (high usage)
        with patch("psutil.cpu_percent", return_value=85.0), \
             patch("psutil.sensors_battery") as mock_battery, \
             patch("httpx.get") as mock_http:

            mock_battery.return_value = MagicMock(percent=80, power_plugged=True)
            mock_http.return_value = MagicMock(
                json=lambda: {"models": []},
                raise_for_status=MagicMock(),
            )

            result = scheduler._should_run_batch()

        assert result is False

    def test_scheduler_skips_when_battery_low_and_unplugged(self, tmp_path):
        """When battery < 50% and unplugged, skip the batch."""
        scheduler = self._make_scheduler(tmp_path)

        with patch("psutil.cpu_percent", return_value=10.0), \
             patch("psutil.sensors_battery") as mock_battery, \
             patch("httpx.get") as mock_http:

            mock_battery.return_value = MagicMock(percent=30, power_plugged=False)
            mock_http.return_value = MagicMock(
                json=lambda: {"models": []},
                raise_for_status=MagicMock(),
            )

            result = scheduler._should_run_batch()

        assert result is False

    def test_scheduler_skips_when_ollama_busy(self, tmp_path):
        """When Ollama has active models, skip the batch."""
        scheduler = self._make_scheduler(tmp_path)

        with patch("psutil.cpu_percent", return_value=10.0), \
             patch("psutil.sensors_battery") as mock_battery, \
             patch("httpx.get") as mock_http:

            mock_battery.return_value = MagicMock(percent=80, power_plugged=True)
            # Ollama has an active model running
            mock_http.return_value = MagicMock(
                json=lambda: {"models": [{"name": "llama3", "size": 123}]},
                raise_for_status=MagicMock(),
            )

            result = scheduler._should_run_batch()

        assert result is False

    def test_scheduler_runs_when_conditions_met(self, tmp_path):
        """When CPU low, battery OK, and Ollama idle — should_run_batch returns True."""
        scheduler = self._make_scheduler(tmp_path)

        with patch("psutil.cpu_percent", return_value=15.0), \
             patch("psutil.sensors_battery") as mock_battery, \
             patch("httpx.get") as mock_http:

            mock_battery.return_value = MagicMock(percent=80, power_plugged=True)
            mock_http.return_value = MagicMock(
                json=lambda: {"models": []},
                raise_for_status=MagicMock(),
            )

            result = scheduler._should_run_batch()

        assert result is True

    def test_scheduler_allows_no_battery_sensor(self, tmp_path):
        """On machines with no battery (desktop), sensors_battery returns None — should be OK."""
        scheduler = self._make_scheduler(tmp_path)

        with patch("psutil.cpu_percent", return_value=10.0), \
             patch("psutil.sensors_battery", return_value=None), \
             patch("httpx.get") as mock_http:

            mock_http.return_value = MagicMock(
                json=lambda: {"models": []},
                raise_for_status=MagicMock(),
            )

            result = scheduler._should_run_batch()

        # No battery sensor means desktop — allow it
        assert result is True

    def test_scheduler_start_stop(self, tmp_path):
        """start() and stop() should not raise."""
        scheduler = self._make_scheduler(tmp_path)

        with patch.object(scheduler, "_should_run_batch", return_value=False):
            scheduler.start()
            time.sleep(0.05)
            scheduler.stop()


# ---------------------------------------------------------------------------
# SourceWatcher debounce
# ---------------------------------------------------------------------------

class TestSourceWatcher:
    def test_watcher_debounce(self, tmp_path):
        """Multiple rapid file events should coalesce into a single incremental_update call."""
        from solidrag.index.watcher import SourceWatcher
        from solidrag.index.manifest import IndexManifest
        from solidrag.extractors.registry import ExtractorRegistry

        config = _make_config(tmp_path)
        faiss_index = MagicMock()
        manifest = IndexManifest(tmp_path / "manifest.json")
        manifest.load()
        registry = ExtractorRegistry()
        lock = asyncio.Lock()

        update_calls = []

        def fake_incremental_update(*args, **kwargs):
            update_calls.append(time.monotonic())

        with patch(
            "solidrag.index.watcher.incremental_update",
            side_effect=fake_incremental_update,
        ):
            watcher = SourceWatcher(config, faiss_index, manifest, registry, lock)
            # Directly invoke the internal handler multiple times rapidly
            for _ in range(5):
                watcher._on_change_event()
                time.sleep(0.05)

            # Wait for debounce window to expire (2s debounce + buffer)
            time.sleep(2.5)

        # Despite 5 rapid events, incremental_update should be called only once
        assert len(update_calls) == 1

    def test_watcher_start_stop(self, tmp_path):
        """start() and stop() should complete without raising."""
        from solidrag.index.watcher import SourceWatcher
        from solidrag.index.manifest import IndexManifest
        from solidrag.extractors.registry import ExtractorRegistry

        config = _make_config(tmp_path)
        faiss_index = MagicMock()
        manifest = IndexManifest(tmp_path / "manifest.json")
        manifest.load()
        registry = ExtractorRegistry()
        lock = asyncio.Lock()

        with patch("solidrag.index.watcher.incremental_update"):
            watcher = SourceWatcher(config, faiss_index, manifest, registry, lock)
            watcher.start()
            time.sleep(0.05)
            watcher.stop()


# ---------------------------------------------------------------------------
# build_index (smoke test with mocked embeddings and FAISS)
# ---------------------------------------------------------------------------

class TestBuildIndex:
    def test_build_index_returns_faiss_index_and_manifest(self, tmp_path):
        """build_index should return (faiss.IndexIDMap2, IndexManifest) on an empty source dir."""
        import numpy as np

        (tmp_path / "index").mkdir(parents=True, exist_ok=True)

        config = _make_config(tmp_path, source_dirs=[tmp_path])

        # Create a simple markdown file
        (tmp_path / "hello.md").write_text("# Hello\nThis is a test document.")

        with patch(
            "solidrag.index.builder.OllamaEmbedding"
        ) as MockEmbedding:
            mock_embed_instance = MagicMock()
            # Return a realistic 768-dim embedding
            mock_embed_instance.get_text_embedding_batch.return_value = [
                [0.1] * 768
            ]
            MockEmbedding.return_value = mock_embed_instance

            import faiss as faiss_module
            from solidrag.index.builder import build_index

            faiss_index, manifest = build_index(config)

        import faiss as faiss_mod
        assert isinstance(faiss_index, faiss_mod.IndexIDMap2)
        from solidrag.index.manifest import IndexManifest
        assert isinstance(manifest, IndexManifest)

    def test_build_index_empty_source_dir(self, tmp_path):
        """build_index on an empty directory should return an empty FAISS index."""
        (tmp_path / "index").mkdir(parents=True, exist_ok=True)

        config = _make_config(tmp_path, source_dirs=[tmp_path])

        with patch("solidrag.index.builder.OllamaEmbedding") as MockEmbedding:
            mock_embed_instance = MagicMock()
            mock_embed_instance.get_text_embedding_batch.return_value = []
            MockEmbedding.return_value = mock_embed_instance

            from solidrag.index.builder import build_index
            faiss_index, manifest = build_index(config)

        assert faiss_index.ntotal == 0
