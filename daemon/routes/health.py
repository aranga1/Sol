from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

router = APIRouter()


@router.get("/api/health")
async def health(request: Request):
    obsidian = request.app.state.obsidian
    try:
        is_up = await obsidian.health()
    except Exception:
        is_up = False
    if not is_up:
        return JSONResponse(
            status_code=200,
            content={"status": "degraded", "vault_note_count": 0},
        )
    try:
        count = await obsidian.note_count()
    except Exception:
        count = 0
    return {"status": "ok", "vault_note_count": count}
