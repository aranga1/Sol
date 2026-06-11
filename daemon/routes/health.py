from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

router = APIRouter()


@router.get("/api/health")
async def health(request: Request):
    obsidian = request.app.state.obsidian
    is_up = await obsidian.health()
    if not is_up:
        return JSONResponse(
            status_code=503,
            content={"status": "degraded", "vault_note_count": 0},
        )
    count = await obsidian.note_count()
    return {"status": "ok", "vault_note_count": count}
