"""Upload routes — ingest files and images into the Obsidian vault."""
from __future__ import annotations

import tempfile
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, File, HTTPException, Request, UploadFile

from solidrag.extractors.docx import DocxExtractor

router = APIRouter()


def _timestamp_dir() -> str:
    """Return ``YY-DD-MM-HH-MM`` timestamp string used for upload sub-directories."""
    now = datetime.now()
    return now.strftime("%y-%d-%m-%H-%M")


@router.post("/api/upload/file")
async def upload_file(request: Request, file: UploadFile = File(...)):
    """Ingest a document file into the vault.

    Routing by extension:
    - ``.pdf``         → ``uploads/pdf/YY-DD-MM-HH-MM/<filename>`` (binary, via Obsidian)
    - ``.xlsx``/``.xls`` → ``uploads/excel/YY-DD-MM-HH-MM/<filename>`` (binary, via Obsidian)
    - ``.docx``/``.doc`` → extract to markdown, write as ``<stem>.md`` at vault root
    - anything else   → 415 Unsupported Media Type

    Returns ``{"file_path": "<vault-relative path>"}`` on success.
    """
    obsidian = request.app.state.obsidian
    ext = Path(file.filename).suffix.lower()
    data = await file.read()

    if ext == ".pdf":
        ts = _timestamp_dir()
        vault_path = f"uploads/pdf/{ts}/{file.filename}"
        await obsidian.put_file(vault_path, data)
        return {"file_path": vault_path}

    if ext in (".xlsx", ".xls"):
        ts = _timestamp_dir()
        vault_path = f"uploads/excel/{ts}/{file.filename}"
        await obsidian.put_file(vault_path, data)
        return {"file_path": vault_path}

    if ext in (".docx", ".doc"):
        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
            tmp.write(data)
            tmp_path = Path(tmp.name)
        try:
            extractor = DocxExtractor()
            nodes = extractor.extract(tmp_path)
        except Exception as exc:
            raise HTTPException(
                status_code=422, detail=f"Failed to parse document: {exc}"
            ) from exc
        finally:
            tmp_path.unlink(missing_ok=True)

        md_text = "\n\n".join(n.text for n in nodes)
        md_filename = Path(file.filename).stem + ".md"
        await obsidian.put_file(md_filename, md_text.encode())
        return {"file_path": md_filename}

    raise HTTPException(
        status_code=415, detail=f"Unsupported file type: {ext}"
    )


@router.post("/api/upload/image")
async def upload_image(request: Request, file: UploadFile = File(...)):
    """Write an image file to ``attachments/<filename>`` via the Obsidian REST API.

    Returns ``{"embed": "![[filename]]"}`` so the caller can paste the Obsidian
    embed syntax directly into a note.
    """
    obsidian = request.app.state.obsidian
    data = await file.read()
    vault_path = f"attachments/{file.filename}"
    await obsidian.put_file(vault_path, data)
    return {"embed": f"![[{file.filename}]]"}
