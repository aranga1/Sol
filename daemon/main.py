from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.routing import APIRouter

from daemon.config import load_config


# Empty router — routes will be added in future issues
router = APIRouter()


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.config = load_config()
    print(f"Alysha daemon running on port {app.state.config.daemon_port}")
    yield


app = FastAPI(lifespan=lifespan)


@app.middleware("http")
async def api_key_middleware(request: Request, call_next):
    if request.url.path == "/api/health" and request.method == "GET":
        return await call_next(request)

    api_key = request.headers.get("X-API-Key")
    if not api_key or api_key != request.app.state.config.daemon_api_key:
        return JSONResponse(status_code=401, content={"detail": "Unauthorized"})

    return await call_next(request)


@app.get("/api/health")
async def health():
    return {"status": "ok"}


app.include_router(router)


if __name__ == "__main__":
    import uvicorn

    cfg = load_config()
    uvicorn.run(app, host="127.0.0.1", port=cfg.daemon_port)
