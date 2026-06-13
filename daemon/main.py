import asyncio
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from daemon.config import load_config
from daemon.obsidian_client import ObsidianClient
from daemon.routes import health as health_router
from daemon.routes import notes as notes_router
from daemon.routes import query as query_router
from daemon.routes import config as config_router
from daemon.routes import notifications as notifications_router
from daemon.routes import tags as tags_router
from daemon.routes import uploads as uploads_router
from solidrag import CalendarWatcher, SolidRagConfig, SourceWatcher, build_index, configure_settings
from solidrag.index.builder import apply_source_diff, _node_id_to_int
from solidrag.extractors import default_registry
from solidrag.index.manifest import IndexManifest
from solidrag.index.nodestore import NodeStore
from solidrag.index.scheduler import ResourceAwareScheduler


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.config = load_config()
    cfg = app.state.config

    app.state.obsidian = ObsidianClient(
        base_url=f"https://localhost:{cfg.obsidian_port}",
        api_key=cfg.obsidian_api_key,
    )
    print(f"Sol daemon running on port {cfg.daemon_port}")

    source_dirs = [Path(cfg.vault_path)]
    solidrag_config = SolidRagConfig(
        source_dirs=source_dirs,
        ollama_base_url=cfg.ollama_base_url,
        ollama_model=cfg.ollama_model,
    )
    configure_settings(solidrag_config)

    registry = default_registry(
        ollama_base_url=cfg.ollama_base_url,
        vision_model=solidrag_config.vision_model,
    )

    app.state.vault_index = None
    app.state.vault_nodestore = None
    app.state.index_lock = asyncio.Lock()

    try:
        faiss_idx, manifest, nodestore = build_index(solidrag_config, registry)
        app.state.vault_index = faiss_idx
        app.state.vault_nodestore = nodestore
        app.state.index_manifest = manifest
        app.state.solidrag_config = solidrag_config
    except Exception as e:
        print(f"[startup] Initial index build failed: {e}")
        manifest = IndexManifest(solidrag_config.persist_dir / "manifest.json")
        nodestore = NodeStore(solidrag_config.persist_dir / "nodestore.json")
        app.state.index_manifest = manifest
        app.state.vault_nodestore = nodestore
        app.state.solidrag_config = solidrag_config

    watcher = SourceWatcher(
        config=solidrag_config,
        faiss_index=app.state.vault_index,
        manifest=app.state.index_manifest,
        nodestore=app.state.vault_nodestore,
        registry=registry,
        lock=app.state.index_lock,
    )
    watcher.start()
    app.state.vault_watcher = watcher

    scheduler = ResourceAwareScheduler(
        config=solidrag_config,
        faiss_index=app.state.vault_index,
        manifest=app.state.index_manifest,
        nodestore=app.state.vault_nodestore,
        registry=registry,
        lock=app.state.index_lock,
    )
    scheduler.start()
    app.state.scheduler = scheduler

    def _on_calendar_diff(diff):
        import numpy as np
        import time
        fi = app.state.vault_index
        manifest = app.state.index_manifest
        config = app.state.solidrag_config
        if fi is None:
            return
        for node in diff.to_add:
            apply_source_diff(
                fi,
                manifest,
                diff.__class__(to_add=[node]),
                source_id="calendar",
                source_key=node.metadata.get("event_id", node.node_id),
                mtime=time.time(),
                config=config,
            )
        for old_ids, new_nodes in diff.to_update:
            from solidrag.extractors.base import IndexDiff
            apply_source_diff(
                fi,
                manifest,
                IndexDiff(to_update=[(old_ids, new_nodes)]),
                source_id="calendar",
                source_key=new_nodes[0].metadata.get("event_id", new_nodes[0].node_id) if new_nodes else "unknown",
                mtime=time.time(),
                config=config,
            )
        if diff.to_delete:
            ids = np.array([_node_id_to_int(nid) for nid in diff.to_delete], dtype=np.int64)
            try:
                fi.remove_ids(ids)
            except Exception as e:
                print(f"[CalendarWatcher] remove_ids error: {e}")
        manifest.save()

    calendar_watcher = CalendarWatcher(
        manifest=app.state.index_manifest,
        on_diff_ready=_on_calendar_diff,
        poll_interval=60,
    )
    calendar_watcher.start()
    app.state.calendar_watcher = calendar_watcher

    yield

    # Teardown
    await app.state.obsidian.close()
    app.state.vault_watcher.stop()
    app.state.scheduler.stop()
    app.state.calendar_watcher.stop()


app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def api_key_middleware(request: Request, call_next):
    if request.url.path == "/api/health" and request.method == "GET":
        return await call_next(request)

    api_key = request.headers.get("X-API-Key")
    if not api_key or api_key != request.app.state.config.daemon_api_key:
        return JSONResponse(status_code=401, content={"detail": "Unauthorized"})

    return await call_next(request)


app.include_router(health_router.router)
app.include_router(notes_router.router)
app.include_router(query_router.router)
app.include_router(config_router.router)
app.include_router(notifications_router.router)
app.include_router(tags_router.router)
app.include_router(uploads_router.router)


if __name__ == "__main__":
    import uvicorn

    cfg = load_config()
    uvicorn.run(app, host="0.0.0.0", port=cfg.daemon_port)
