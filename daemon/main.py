from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from daemon.config import load_config
from daemon.obsidian_client import ObsidianClient
from daemon.rag import build_index, VaultWatcher
from daemon.routes import health as health_router
from daemon.routes import notes as notes_router
from daemon.routes import query as query_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.config = load_config()
    app.state.obsidian = ObsidianClient(
        base_url=f"https://localhost:{app.state.config.obsidian_port}",
        api_key=app.state.config.obsidian_api_key,
    )
    print(f"Alysha daemon running on port {app.state.config.daemon_port}")

    vault_path = app.state.config.vault_path
    ollama_base = app.state.config.ollama_base_url
    ollama_model = app.state.config.ollama_model

    app.state.vault_index = None  # will be set once built

    def on_index_ready(new_index):
        app.state.vault_index = new_index

    # Build initial index (blocking — runs before first request)
    try:
        app.state.vault_index = build_index(vault_path, ollama_base, ollama_model)
    except Exception as e:
        print(f"[startup] Initial index build failed: {e}")

    # Start background watcher
    watcher = VaultWatcher(vault_path, ollama_base, ollama_model, on_index_ready)
    watcher.start()
    app.state.vault_watcher = watcher

    yield

    # Teardown
    await app.state.obsidian.close()
    app.state.vault_watcher.stop()


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


if __name__ == "__main__":
    import uvicorn

    cfg = load_config()
    uvicorn.run(app, host="127.0.0.1", port=cfg.daemon_port)
