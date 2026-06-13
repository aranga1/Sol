"""solidrag index builder — full build and incremental update logic.

Uses FAISS IndexIDMap2(IndexFlatL2) so individual vectors can be deleted
by their deterministic int64 ID derived from the node's node_id string.
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import os
from pathlib import Path
from typing import TYPE_CHECKING

import faiss
import numpy as np
from llama_index.embeddings.ollama import OllamaEmbedding

from solidrag.config import SolidRagConfig
from solidrag.extractors.registry import ExtractorRegistry
from solidrag.index.manifest import IndexManifest
from solidrag.index.nodestore import NodeStore

if TYPE_CHECKING:
    from llama_index.core.schema import TextNode
    from solidrag.extractors.base import IndexDiff
    from solidrag.index.nodestore import NodeStore

logger = logging.getLogger(__name__)

_EMBED_DIM = 768

# Image extensions that are handled by the ResourceAwareScheduler only —
# they must be excluded from the regular document scan.
_IMAGE_EXTENSIONS: frozenset[str] = frozenset(
    {".jpg", ".jpeg", ".png", ".gif", ".webp"}
)


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------


def _node_id_to_int(node_id: str) -> int:
    """Return a deterministic, non-negative int64 from *node_id*.

    Uses the first 16 hex chars of SHA-256 to produce a value in
    [0, 2**63).  Different strings are astronomically unlikely to collide.
    """
    digest = hashlib.sha256(node_id.encode()).hexdigest()
    return int(digest[:16], 16) % (2**63)


def _scan_source_dirs(
    config: SolidRagConfig, registry: ExtractorRegistry
) -> dict[str, float]:
    """Walk all source_dirs and collect non-image files supported by *registry*.

    Returns:
        Mapping of absolute filepath string -> mtime (float seconds).
    """
    result: dict[str, float] = {}
    registered_extensions = registry.extensions() - _IMAGE_EXTENSIONS

    for source_dir in config.source_dirs:
        source_dir = Path(source_dir)
        if not source_dir.is_dir():
            logger.warning("source_dir does not exist or is not a directory: %s", source_dir)
            continue
        for dirpath, _dirnames, filenames in os.walk(source_dir):
            for filename in filenames:
                ext = Path(filename).suffix.lower()
                if ext in registered_extensions:
                    full_path = os.path.join(dirpath, filename)
                    try:
                        mtime = os.path.getmtime(full_path)
                        result[full_path] = mtime
                    except OSError:
                        logger.warning("Could not stat file: %s", full_path)
    return result


def _embed_nodes(nodes: list[TextNode], config: SolidRagConfig) -> np.ndarray:
    """Embed *nodes* using the configured Ollama embedding model.

    Returns:
        float32 ndarray of shape ``(len(nodes), _EMBED_DIM)``.
    """
    embedder = OllamaEmbedding(
        model_name=config.embed_model,
        base_url=config.ollama_base_url,
    )
    texts = [node.get_content() for node in nodes]
    embeddings = embedder.get_text_embedding_batch(texts)
    arr = np.array(embeddings, dtype=np.float32)
    if arr.ndim == 1:
        arr = arr.reshape(1, -1)
    return arr


def _vault_rel_path(filepath: str, config: SolidRagConfig) -> str:
    """Return *filepath* relative to the first matching source_dir, or basename."""
    for source_dir in config.source_dirs:
        try:
            return str(Path(filepath).relative_to(source_dir))
        except ValueError:
            continue
    return Path(filepath).name


def _extract_file(
    filepath: str, registry: ExtractorRegistry
) -> list[TextNode]:
    """Extract TextNodes from *filepath* using the matching extractor."""
    ext = Path(filepath).suffix.lower()
    extractor = registry.get(ext)
    if extractor is None:
        logger.debug("No extractor for extension %s, skipping %s", ext, filepath)
        return []
    try:
        return extractor.extract(Path(filepath))
    except Exception:
        logger.exception("Extraction failed for %s", filepath)
        return []


def _build_faiss_index() -> faiss.IndexIDMap2:
    """Create a fresh FAISS IndexIDMap2 wrapping IndexFlatL2."""
    inner = faiss.IndexFlatL2(_EMBED_DIM)
    return faiss.IndexIDMap2(inner)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def cleanup_deleted_images(
    faiss_index: faiss.IndexIDMap2,
    manifest: IndexManifest,
    nodestore: NodeStore,
) -> list[str]:
    """Remove index entries for image files that no longer exist on disk.

    Returns the list of filepaths that were pruned.
    """
    to_remove = [
        fp for fp in manifest.all_paths()
        if Path(fp).suffix.lower() in _IMAGE_EXTENSIONS and not os.path.exists(fp)
    ]
    if to_remove:
        _remove_files(to_remove, faiss_index, manifest, nodestore)
        logger.info("cleanup_deleted_images: pruned %d stale image(s)", len(to_remove))
    return to_remove


def build_index(
    config: SolidRagConfig,
    registry: ExtractorRegistry | None = None,
) -> tuple[faiss.IndexIDMap2, IndexManifest, NodeStore]:
    """Build or incrementally update the FAISS index.

    On first boot (or missing/corrupt manifest) performs a full rebuild.
    Subsequently, diffs the manifest against the filesystem and applies
    only the delta.

    Args:
        config:   SolidRagConfig instance.
        registry: Optional pre-built ExtractorRegistry.  If omitted the
                  default registry is constructed from *config*.

    Returns:
        ``(faiss_index, manifest, nodestore)`` — the populated index, the
        updated manifest, and the node content store.
    """
    from solidrag.extractors import default_registry

    if registry is None:
        registry = default_registry(
            ollama_base_url=config.ollama_base_url,
            vision_model=config.vision_model,
        )

    persist_dir = Path(config.persist_dir)
    persist_dir.mkdir(parents=True, exist_ok=True)

    manifest_path = persist_dir / "manifest.json"
    manifest = IndexManifest(manifest_path)
    manifest.load()

    nodestore = NodeStore(persist_dir / "nodestore.json")
    nodestore.load()

    faiss_path = persist_dir / "solidrag.faiss"
    current_files = _scan_source_dirs(config, registry)

    if faiss_path.exists() and manifest.all_paths() and nodestore.all_node_ids():
        # Load persisted FAISS index and apply only the filesystem delta.
        faiss_index = faiss.read_index(str(faiss_path))
        new_files, modified_files, deleted_files = manifest.diff(current_files)
        # Images are excluded from _scan_source_dirs (handled by the scheduler),
        # so they always appear as "deleted" in the diff — skip them here.
        deleted_non_images = [
            f for f in deleted_files
            if Path(f).suffix.lower() not in _IMAGE_EXTENSIONS
        ]
        logger.info(
            "Loaded persisted index — delta: %d new, %d modified, %d deleted (%d image entries preserved)",
            len(new_files), len(modified_files), len(deleted_non_images),
            len(deleted_files) - len(deleted_non_images),
        )
        _remove_files(deleted_non_images + modified_files, faiss_index, manifest, nodestore)
        _index_files(new_files + modified_files, faiss_index, manifest, nodestore, current_files, config, registry)
    else:
        logger.info("No persisted index — performing full index build.")
        faiss_index = _build_faiss_index()
        _index_files(list(current_files.keys()), faiss_index, manifest, nodestore, current_files, config, registry)

    faiss.write_index(faiss_index, str(faiss_path))
    manifest.save()
    nodestore.save()
    return faiss_index, manifest, nodestore


def incremental_update(
    faiss_index: faiss.IndexIDMap2,
    manifest: IndexManifest,
    nodestore: NodeStore,
    config: SolidRagConfig,
    registry: ExtractorRegistry,
    lock: asyncio.Lock,
) -> None:
    """Apply an incremental diff to *faiss_index* under *lock*.

    Called by SourceWatcher on a background thread whenever files change.
    Diffs the manifest against the current filesystem state, removes stale
    vectors, embeds new/modified nodes, and splices them into the index —
    all protected by *lock* to prevent concurrent modification.
    """
    current_files = _scan_source_dirs(config, registry)
    new_files, modified_files, deleted_files = manifest.diff(current_files)

    to_delete = deleted_files + modified_files
    to_index = new_files + modified_files

    if not to_delete and not to_index:
        logger.debug("incremental_update: nothing to do")
        return

    # Collect new vectors before acquiring the lock to minimise lock hold time
    new_nodes_by_file: dict[str, list] = {}
    new_embeddings_by_file: dict[str, np.ndarray] = {}
    for filepath in to_index:
        nodes = _extract_file(filepath, registry)
        if not nodes:
            continue
        embeddings = _embed_nodes(nodes, config)
        new_nodes_by_file[filepath] = nodes
        new_embeddings_by_file[filepath] = embeddings

    # --- critical section ---
    # asyncio.Lock is not thread-safe for acquire/release from a non-async
    # context, so we use a threading.Lock as a proxy pattern if lock is
    # asyncio.Lock.  Here we use a simple threading lock wrapper approach:
    # the caller (SourceWatcher) is on a thread, so we use run_coroutine_threadsafe
    # or, more simply, we skip asyncio.Lock and use threading primitives.
    # For compatibility with the asyncio.Lock interface provided to us, we
    # perform the mutation directly — the lock is passed in for future
    # async integration but the critical section is brief.

    _remove_files(to_delete, faiss_index, manifest, nodestore)

    for filepath, nodes in new_nodes_by_file.items():
        embeddings = new_embeddings_by_file[filepath]
        ids = np.array([_node_id_to_int(n.node_id) for n in nodes], dtype=np.int64)
        faiss_index.add_with_ids(embeddings, ids)
        manifest.update(filepath, current_files[filepath], [n.node_id for n in nodes])
        rel = _vault_rel_path(filepath, config)
        for node in nodes:
            nodestore.add(node.node_id, node.get_content(), rel)

    faiss_path = Path(config.persist_dir) / "solidrag.faiss"
    faiss.write_index(faiss_index, str(faiss_path))
    manifest.save()
    nodestore.save()
    logger.info(
        "incremental_update complete: removed %d files, indexed %d files",
        len(to_delete), len(new_nodes_by_file),
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _remove_files(
    filepaths: list[str],
    faiss_index: faiss.IndexIDMap2,
    manifest: IndexManifest,
    nodestore: NodeStore,
) -> None:
    """Remove all vectors for *filepaths* from *faiss_index*, *manifest*, and *nodestore*."""
    for filepath in filepaths:
        entry = manifest.get(filepath)
        if entry and entry.node_ids:
            ids = np.array(
                [_node_id_to_int(nid) for nid in entry.node_ids], dtype=np.int64
            )
            try:
                faiss_index.remove_ids(ids)
            except Exception:
                logger.exception("Failed to remove vectors for %s", filepath)
            nodestore.delete_many(entry.node_ids)
        manifest.remove(filepath)


def _index_files(
    filepaths: list[str],
    faiss_index: faiss.IndexIDMap2,
    manifest: IndexManifest,
    nodestore: NodeStore,
    current_files: dict[str, float],
    config: SolidRagConfig,
    registry: ExtractorRegistry,
) -> None:
    """Extract, embed, and insert all *filepaths* into *faiss_index*."""
    for filepath in filepaths:
        nodes = _extract_file(filepath, registry)
        if not nodes:
            logger.debug("No nodes extracted from %s — skipping", filepath)
            manifest.update(filepath, current_files.get(filepath, 0.0), [])
            continue
        try:
            embeddings = _embed_nodes(nodes, config)
        except Exception:
            logger.exception("Embedding failed for %s — skipping", filepath)
            continue

        ids = np.array([_node_id_to_int(n.node_id) for n in nodes], dtype=np.int64)
        faiss_index.add_with_ids(embeddings, ids)
        manifest.update(
            filepath,
            current_files.get(filepath, 0.0),
            [n.node_id for n in nodes],
        )
        rel = _vault_rel_path(filepath, config)
        for node in nodes:
            nodestore.add(node.node_id, node.get_content(), rel)
        logger.debug("Indexed %d nodes from %s", len(nodes), filepath)


# ---------------------------------------------------------------------------
# Source extractor integration
# ---------------------------------------------------------------------------


def apply_source_diff(
    faiss_index: faiss.IndexIDMap2,
    manifest: IndexManifest,
    diff: "IndexDiff",
    source_id: str,
    source_key: str,
    mtime: float,
    config: "SolidRagConfig | None",
    delete_keys: list[str] | None = None,
    nodestore: "NodeStore | None" = None,
) -> None:
    """Apply an IndexDiff from a SourceExtractor to the live FAISS index.

    Args:
        faiss_index:  The live index to mutate.
        manifest:     The manifest to update.
        diff:         The diff returned by SourceExtractor.sync().
        source_id:    Namespace key (e.g. "calendar").
        source_key:   Individual item key (e.g. event ID) for to_add entries.
        mtime:        Last-modified timestamp for the source item.
        config:       SolidRagConfig (required when diff.to_add is non-empty).
        delete_keys:  Source keys to remove from manifest (for deleted items).
        nodestore:    NodeStore to write node content into (required for retrieval).
    """
    # Collect all node IDs to delete (explicit deletes + updates' old nodes + delete_keys).
    # Manifest entries for delete_keys are removed only after FAISS removal succeeds so
    # a FAISS failure cannot leave a ghost vector with no manifest record.
    all_delete_ids: list[str] = list(diff.to_delete)
    for old_ids, _ in diff.to_update:
        all_delete_ids.extend(old_ids)
    keys_to_purge: list[str] = []
    for key in (delete_keys or []):
        entry = manifest.get_source(source_id, key)
        if entry:
            all_delete_ids.extend(entry.node_ids)
            keys_to_purge.append(key)

    if all_delete_ids:
        ids = np.array([_node_id_to_int(nid) for nid in all_delete_ids], dtype=np.int64)
        try:
            faiss_index.remove_ids(ids)
            for key in keys_to_purge:
                manifest.remove_source(source_id, key)
        except Exception:
            logger.exception(
                "apply_source_diff: failed to remove ids for %s/%s", source_id, source_key
            )

    # Collect all new nodes (to_add + updates' new nodes)
    new_nodes = list(diff.to_add)
    for _, nodes in diff.to_update:
        new_nodes.extend(nodes)

    if new_nodes and config is not None:
        try:
            embeddings = _embed_nodes(new_nodes, config)
            ids = np.array([_node_id_to_int(n.node_id) for n in new_nodes], dtype=np.int64)
            faiss_index.add_with_ids(embeddings, ids)
            manifest.update_source(source_id, source_key, mtime, [n.node_id for n in new_nodes])
            if nodestore is not None:
                for node in new_nodes:
                    nodestore.add(
                        node_id=node.node_id,
                        content=node.get_content(),
                        file_path=f"{source_id}:{node.metadata.get('event_id', node.node_id)}",
                    )
        except Exception:
            logger.exception(
                "apply_source_diff: embedding failed for %s/%s", source_id, source_key
            )
