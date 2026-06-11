from __future__ import annotations

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

    @field_validator("content")
    @classmethod
    def content_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("content cannot be empty")
        return v


class NoteResponse(BaseModel):
    file_path: str


@router.post("/api/note", response_model=NoteResponse, status_code=201)
async def create_note(request: Request, body: NoteRequest):
    config = request.app.state.config
    obsidian = request.app.state.obsidian

    # Filename: YYYY-MM-DDTHH-MM-SS-<source>.md (UTC)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S")
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

    if body.title:
        note_content = frontmatter + f"# {body.title}\n\n{body.content}"
    else:
        note_content = frontmatter + body.content

    file_path = await obsidian.create_note(filename, note_content)
    return NoteResponse(file_path=file_path)
