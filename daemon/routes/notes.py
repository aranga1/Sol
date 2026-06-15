from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import List, Literal, Optional
from fastapi import APIRouter, Request
from pydantic import BaseModel, field_validator

router = APIRouter()


class NoteRequest(BaseModel):
    content: str
    title: Optional[str] = None
    tags: Optional[List[str]] = None
    source: Literal["voice", "text"]
    folder: str = "Notes"

    @field_validator("content")
    @classmethod
    def content_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("content cannot be empty")
        return v

    @field_validator("folder")
    @classmethod
    def folder_default_if_empty(cls, v: str) -> str:
        return v.strip() if v.strip() else "Notes"


class NoteResponse(BaseModel):
    file_path: str


@router.post("/api/note", response_model=NoteResponse, status_code=201)
async def create_note(request: Request, body: NoteRequest):
    config = request.app.state.config
    obsidian = request.app.state.obsidian

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S")
    if body.title:
        # Sanitize for filesystem: strip special chars, collapse whitespace, keep spaces
        safe = re.sub(r"[^\w\s\-]", "", body.title).strip()
        safe = re.sub(r"\s+", " ", safe)
        filename = f"{safe}.md"
    else:
        filename = f"{ts}-{body.source}.md"

    # Build YAML frontmatter
    tags_yaml = ""
    if body.tags:
        tags_yaml = "\ntags:\n" + "".join(f"  - {t}\n" for t in body.tags)

    frontmatter = (
        f"---\n"
        f"created: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
        f"source: {body.source}"
        f"{tags_yaml}\n"
        f"---\n\n"
    )

    # Title is already the filename — don't repeat it as a # heading inside the note
    note_content = frontmatter + body.content

    file_path = await obsidian.create_note(filename, note_content, folder=body.folder)
    return NoteResponse(file_path=file_path)


@router.get("/api/vault/directories")
async def get_vault_directories(request: Request) -> dict:
    """Return sorted unique vault directory paths from the Obsidian vault."""
    dirs = await request.app.state.obsidian.list_directories()
    return {"directories": dirs}
