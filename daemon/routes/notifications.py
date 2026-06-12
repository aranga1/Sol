import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()

_NOTIFICATIONS_FILE = Path.home() / ".sol/notifications.json"
_lock = threading.Lock()


def _load() -> list[dict]:
    if not _NOTIFICATIONS_FILE.exists():
        return []
    try:
        return json.loads(_NOTIFICATIONS_FILE.read_text())
    except Exception:
        return []


def _save(notifications: list[dict]) -> None:
    _NOTIFICATIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
    _NOTIFICATIONS_FILE.write_text(json.dumps(notifications, indent=2))


class NotifyRequest(BaseModel):
    title: str
    body: str
    type: str = "info"  # info | warning | update


@router.post("/api/notify", status_code=201)
async def create_notification(payload: NotifyRequest):
    with _lock:
        notifications = _load()
        notifications.append({
            "id": str(uuid4()),
            "title": payload.title,
            "body": payload.body,
            "type": payload.type,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "read": False,
        })
        _save(notifications)
    return {"ok": True}


@router.get("/api/notifications")
async def get_notifications():
    with _lock:
        notifications = _load()
        unread = [n for n in notifications if not n["read"]]
        for n in notifications:
            n["read"] = True
        _save(notifications)
    return {"notifications": unread}
