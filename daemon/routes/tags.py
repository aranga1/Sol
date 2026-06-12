from __future__ import annotations

import re
from pathlib import Path
from fastapi import APIRouter, Request
from pydantic import BaseModel

router = APIRouter()


def _extract_tags(vault_path: Path) -> list[str]:
    tags: set[str] = set()
    for md in vault_path.rglob("*.md"):
        try:
            text = md.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        # ── Frontmatter tags ─────────────────────────────────────────────────
        if text.startswith("---"):
            end = text.find("---", 3)
            if end > 0:
                fm = text[3:end]
                # Inline list:  tags: [a, b, c]
                for m in re.findall(r"tags:\s*\[([^\]]+)\]", fm, re.IGNORECASE):
                    for t in m.split(","):
                        t = t.strip().strip("\"'")
                        if t:
                            tags.add(t)
                # Block list:
                #   tags:
                #     - a
                #     - b
                in_tags = False
                for line in fm.splitlines():
                    stripped = line.strip()
                    if re.match(r"^tags\s*:", stripped, re.IGNORECASE):
                        in_tags = True
                    elif in_tags and stripped.startswith("-"):
                        t = stripped.lstrip("-").strip().strip("\"'")
                        if t:
                            tags.add(t)
                    elif in_tags and stripped and not stripped.startswith(" "):
                        in_tags = False

        # ── Inline tags  #tagname ─────────────────────────────────────────────
        for t in re.findall(r"(?<!\S)#([A-Za-z][A-Za-z0-9_/\-]*)", text):
            tags.add(t)

    return sorted(tags, key=str.lower)


@router.get("/api/tags")
async def get_tags(request: Request) -> dict:
    """Return all unique tags found in the vault (frontmatter + inline #tags)."""
    vault_path = Path(request.app.state.config.vault_path)
    return {"tags": _extract_tags(vault_path)}


class CreateTagRequest(BaseModel):
    tag: str


@router.post("/api/tags", status_code=201)
async def create_tag(request: Request, body: CreateTagRequest) -> dict:
    """
    Persist a new tag to _tags.md in the vault root.
    Creates the file if absent; adds the tag to its frontmatter list.
    This makes the tag available in future GET /api/tags responses.
    """
    tag = body.tag.strip().lstrip("#")
    if not tag:
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=400, content={"detail": "tag cannot be empty"})

    vault_path = Path(request.app.state.config.vault_path)
    tags_file = vault_path / "_tags.md"

    # Load existing persisted tags
    existing: list[str] = []
    if tags_file.exists():
        text = tags_file.read_text(encoding="utf-8", errors="ignore")
        if text.startswith("---"):
            end = text.find("---", 3)
            if end > 0:
                fm = text[3:end]
                for m in re.findall(r"tags:\s*\[([^\]]+)\]", fm, re.IGNORECASE):
                    existing = [t.strip().strip("\"'") for t in m.split(",") if t.strip()]

    if tag in existing:
        return {"tag": tag, "created": False}

    existing.append(tag)
    tag_list = ", ".join(f'"{t}"' for t in sorted(existing))
    tags_file.write_text(
        f"---\ntags: [{tag_list}]\n---\n\n"
        "This note stores app-created tags for the Alysha knowledge graph.\n",
        encoding="utf-8",
    )

    return {"tag": tag, "created": True}
