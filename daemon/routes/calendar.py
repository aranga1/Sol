import time

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

router = APIRouter()


@router.post("/api/index-calendar")
async def index_calendar(request: Request):
    """Trigger an immediate CalendarExtractor sync and apply the diff to the live index."""
    watcher = getattr(request.app.state, "calendar_watcher", None)
    if watcher is None:
        return JSONResponse({"error": "CalendarWatcher not initialised"}, status_code=503)

    try:
        diff = watcher._extractor.sync(request.app.state.index_manifest)
    except Exception as exc:
        return JSONResponse({"error": f"CalendarExtractor.sync failed: {exc}"}, status_code=500)

    added = len(diff.to_add)
    updated = len(diff.to_update)
    deleted = len(diff.to_delete)

    if not (added or updated or deleted):
        return {"added": 0, "updated": 0, "deleted": 0, "message": "Index already up to date"}

    from solidrag.index.builder import apply_source_diff, _node_id_to_int
    from solidrag.extractors.base import IndexDiff
    import numpy as np

    async with request.app.state.index_lock:
        fi = request.app.state.vault_index
        manifest = request.app.state.index_manifest
        nodestore = request.app.state.vault_nodestore
        config = request.app.state.solidrag_config
        if fi is None:
            return JSONResponse({"error": "FAISS index not ready"}, status_code=503)

        now = time.time()
        for node in diff.to_add:
            apply_source_diff(
                fi, manifest, IndexDiff(to_add=[node]),
                source_id="calendar",
                source_key=node.metadata.get("event_id", node.node_id),
                mtime=now, config=config, nodestore=nodestore,
            )
        for old_ids, new_nodes in diff.to_update:
            apply_source_diff(
                fi, manifest, IndexDiff(to_update=[(old_ids, new_nodes)]),
                source_id="calendar",
                source_key=new_nodes[0].metadata.get("event_id", new_nodes[0].node_id) if new_nodes else "unknown",
                mtime=now, config=config, nodestore=nodestore,
            )
        if diff.to_delete:
            ids = np.array([_node_id_to_int(nid) for nid in diff.to_delete], dtype=np.int64)
            try:
                fi.remove_ids(ids)
            except Exception as exc:
                return JSONResponse({"error": f"FAISS remove failed: {exc}"}, status_code=500)
        nodestore.save()
        manifest.save()

    return {"added": added, "updated": updated, "deleted": deleted}
