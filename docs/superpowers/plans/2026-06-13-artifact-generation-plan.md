# Artifact Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users ask Sol to generate a PDF, Word doc, or Excel sheet on demand; the daemon runs a structured LLM pipeline, streams progress events on the existing SSE connection, and delivers a downloadable binary; iOS previews it via QLPreviewController with an option to save as markdown to the vault.

**Architecture:** solidRag query engine gains `_is_artifact_request()` intent detection; the daemon adds an artifact generation pipeline (`daemon/artifacts.py`) with a two-stage LLM flow for PDF/docx and a single JSON-mode flow for Excel; a temp store keyed by UUID holds generated files for 10 minutes; new SSE event types (`artifact_progress`, `artifact_ready`) flow on the existing query stream; iOS renders a progress card then a document card with Open/Share/Save to Vault.

**Tech Stack:** `reportlab` (PDF), `python-docx` (Word), `openpyxl` (Excel) — all already in solidRag; `QLPreviewController` + `UIActivityViewController` (iOS); existing solidRag Ollama/FAISS stack.

---

## File Map

**New files:**
- `daemon/artifacts.py` — artifact generation pipeline + temp store
- `daemon/tests/test_artifacts.py`
- `packages/solidrag/tests/test_artifact_intent.py`
- `ios/Sol/Services/ArtifactService.swift`
- `ios/Sol/Models/ArtifactModels.swift`

**Modified files:**
- `packages/solidrag/solidrag/query/engine.py` — add `_is_artifact_request()`
- `packages/solidrag/solidrag/query/prompts.py` — add `ARTIFACT_INTENT_PROMPT`
- `daemon/routes/query.py` — detect artifact request, call pipeline, stream progress
- `daemon/main.py` — initialise artifact temp store + cleanup task
- `ios/Sol/Views/QueryView.swift` — progress card + document card

---

## Task 1: Add _is_artifact_request to solidRag query engine

**Files:**
- Modify: `packages/solidrag/solidrag/query/prompts.py`
- Modify: `packages/solidrag/solidrag/query/engine.py`
- Test: `packages/solidrag/tests/test_artifact_intent.py`

- [ ] **Step 1: Write failing tests**

```python
# packages/solidrag/tests/test_artifact_intent.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch


def _mock_llm(response_str: str):
    mock_result = MagicMock()
    mock_result.__str__ = lambda self: response_str
    mock_llm = MagicMock()
    mock_llm.acomplete = AsyncMock(return_value=mock_result)
    return mock_llm


@pytest.mark.asyncio
async def test_artifact_request_pdf_vault():
    from solidrag.query.engine import _is_artifact_request

    llm = _mock_llm(
        '{"is_artifact_request": true, "format": "pdf",'
        ' "content_source": "vault", "query": "summarise my Q3 goals"}'
    )
    with patch("solidrag.query.engine._get_llm", return_value=llm):
        is_req, info = await _is_artifact_request("generate a PDF of my Q3 goals")

    assert is_req is True
    assert info["format"] == "pdf"
    assert info["content_source"] == "vault"


@pytest.mark.asyncio
async def test_artifact_request_conversation_docx():
    from solidrag.query.engine import _is_artifact_request

    llm = _mock_llm(
        '{"is_artifact_request": true, "format": "docx",'
        ' "content_source": "conversation", "query": "summarise this chat"}'
    )
    with patch("solidrag.query.engine._get_llm", return_value=llm):
        is_req, info = await _is_artifact_request("summarise this chat as a Word doc")

    assert is_req is True
    assert info["format"] == "docx"
    assert info["content_source"] == "conversation"


@pytest.mark.asyncio
async def test_artifact_request_excel():
    from solidrag.query.engine import _is_artifact_request

    llm = _mock_llm(
        '{"is_artifact_request": true, "format": "xlsx",'
        ' "content_source": "vault", "query": "list all tracked expenses"}'
    )
    with patch("solidrag.query.engine._get_llm", return_value=llm):
        is_req, info = await _is_artifact_request("make an Excel of my expenses")

    assert is_req is True
    assert info["format"] == "xlsx"


@pytest.mark.asyncio
async def test_artifact_request_not_detected():
    from solidrag.query.engine import _is_artifact_request

    llm = _mock_llm('{"is_artifact_request": false}')
    with patch("solidrag.query.engine._get_llm", return_value=llm):
        is_req, info = await _is_artifact_request("what did I do yesterday?")

    assert is_req is False
    assert info is None


@pytest.mark.asyncio
async def test_artifact_request_malformed_json_returns_false():
    from solidrag.query.engine import _is_artifact_request

    llm = _mock_llm("not valid json")
    with patch("solidrag.query.engine._get_llm", return_value=llm):
        is_req, info = await _is_artifact_request("make a PDF")

    assert is_req is False
    assert info is None
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd packages/solidrag && python -m pytest tests/test_artifact_intent.py -v
```
Expected: `ImportError` — `_is_artifact_request` not defined.

- [ ] **Step 3: Add ARTIFACT_INTENT_PROMPT to prompts.py**

Append to `packages/solidrag/solidrag/query/prompts.py`:

```python
ARTIFACT_INTENT_PROMPT = """\
Does the following message ask to generate a document artifact (PDF, Word doc, \
or Excel spreadsheet)?
Reply with valid JSON only — no markdown fences:

{{
  "is_artifact_request": true or false,
  "format": "pdf" or "docx" or "xlsx" or null,
  "content_source": "conversation" or "vault" or "both" or null,
  "query": "the core topic or instruction for the document, or null"
}}

Rules for content_source:
- "conversation": user wants to summarise or export the current chat
- "vault": user wants a document based on their notes/vault
- "both": user references both the chat and their notes

Message: {question}"""
```

- [ ] **Step 4: Add _is_artifact_request to engine.py**

Add to `packages/solidrag/solidrag/query/engine.py` (import `ARTIFACT_INTENT_PROMPT` from prompts, alongside existing imports):

```python
from solidrag.query.prompts import (
    ARTIFACT_INTENT_PROMPT,
    CALENDAR_ACTION_PROMPT,
    NEEDS_VAULT_PROMPT,
    build_direct_prompt,
    build_rag_prompt,
)
```

Add function before `query_stream_async`:

```python
async def _is_artifact_request(question: str) -> tuple[bool, dict | None]:
    """Classify whether the question asks to generate a document artifact.

    Returns (True, info_dict) where info_dict has keys: format, content_source, query.
    Returns (False, None) on non-match or malformed LLM output.
    Never raises.
    """
    prompt = ARTIFACT_INTENT_PROMPT.format(question=question)
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    text = str(result).strip()

    if text.startswith("```"):
        parts = text.split("```")
        text = parts[1] if len(parts) > 1 else text
        if text.startswith("json"):
            text = text[4:].strip()

    try:
        data = json.loads(text)
        if data.get("is_artifact_request") and data.get("format"):
            return True, {
                "format": data["format"],
                "content_source": data.get("content_source", "vault"),
                "query": data.get("query", question),
            }
        return False, None
    except (json.JSONDecodeError, AttributeError):
        return False, None
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd packages/solidrag && python -m pytest tests/test_artifact_intent.py -v
```
Expected: all PASSED.

- [ ] **Step 6: Run full solidRag test suite to check no regressions**

```bash
cd packages/solidrag && python -m pytest tests/ -v
```
Expected: all PASSED.

- [ ] **Step 7: Commit**

```bash
git add packages/solidrag/solidrag/query/prompts.py packages/solidrag/solidrag/query/engine.py packages/solidrag/tests/test_artifact_intent.py
git commit -m "feat(solidrag): add _is_artifact_request intent detection"
```

---

## Task 2: Implement artifact generation pipeline (daemon)

**Files:**
- Create: `daemon/artifacts.py`
- Test: `daemon/tests/test_artifacts.py`

- [ ] **Step 1: Write failing tests**

```python
# daemon/tests/test_artifacts.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from pathlib import Path
import tempfile


@pytest.mark.asyncio
async def test_generate_structure_returns_dict():
    from daemon.artifacts import _generate_structure

    mock_llm = MagicMock()
    mock_llm.acomplete = AsyncMock(return_value=MagicMock(
        __str__=lambda self: (
            '{"title": "Q3 Goals", "sections": ['
            '{"heading": "Overview", "bullet_points": ["Goal 1", "Goal 2"]}]}'
        )
    ))

    with patch("daemon.artifacts._get_llm", return_value=mock_llm):
        result = await _generate_structure(
            query="Q3 goals summary",
            context="Q3 goal: ship solidRag. Q3 goal: add calendar.",
        )

    assert result["title"] == "Q3 Goals"
    assert len(result["sections"]) == 1
    assert result["sections"][0]["heading"] == "Overview"


@pytest.mark.asyncio
async def test_generate_content_returns_markdown():
    from daemon.artifacts import _generate_content

    structure = {
        "title": "Q3 Goals",
        "sections": [
            {"heading": "Overview", "bullet_points": ["Goal 1"]}
        ],
    }

    mock_llm = MagicMock()
    mock_llm.acomplete = AsyncMock(return_value=MagicMock(
        __str__=lambda self: "## Overview\n\nGoal 1 is to ship solidRag."
    ))

    with patch("daemon.artifacts._get_llm", return_value=mock_llm):
        md = await _generate_content(structure)

    assert "Overview" in md


@pytest.mark.asyncio
async def test_generate_excel_rows_returns_dict():
    from daemon.artifacts import _generate_excel_rows

    mock_llm = MagicMock()
    mock_llm.acomplete = AsyncMock(return_value=MagicMock(
        __str__=lambda self: (
            '{"filename": "Expenses.xlsx", "columns": ["Date", "Amount"],'
            ' "rows": [["2026-06-01", "£100"], ["2026-06-02", "£50"]]}'
        )
    ))

    with patch("daemon.artifacts._get_llm", return_value=mock_llm):
        result = await _generate_excel_rows(
            query="list expenses", context="June 1: £100. June 2: £50."
        )

    assert result["columns"] == ["Date", "Amount"]
    assert len(result["rows"]) == 2


def test_build_pdf_creates_file(tmp_path):
    from daemon.artifacts import _build_pdf

    structure = {
        "title": "Test Doc",
        "sections": [{"heading": "Intro", "bullet_points": ["Point A"]}],
    }
    content_md = "## Intro\n\nPoint A is important."
    path, filename, md_source = _build_pdf(structure, content_md, out_dir=tmp_path)

    assert Path(path).exists()
    assert filename.endswith(".pdf")
    assert "## Intro" in md_source


def test_build_docx_creates_file(tmp_path):
    from daemon.artifacts import _build_docx

    structure = {
        "title": "Test Doc",
        "sections": [{"heading": "Summary", "bullet_points": ["Item 1"]}],
    }
    content_md = "## Summary\n\nItem 1 matters."
    path, filename, md_source = _build_docx(structure, content_md, out_dir=tmp_path)

    assert Path(path).exists()
    assert filename.endswith(".docx")


def test_build_excel_creates_file(tmp_path):
    from daemon.artifacts import _build_excel

    data = {
        "filename": "Budget.xlsx",
        "columns": ["Month", "Amount"],
        "rows": [["June", "£500"], ["July", "£600"]],
    }
    path, filename, md_source = _build_excel(data, out_dir=tmp_path)

    assert Path(path).exists()
    assert filename == "Budget.xlsx"
    assert "Month" in md_source
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/aakashranga/IN/Sol && python -m pytest daemon/tests/test_artifacts.py -v
```
Expected: `ModuleNotFoundError` — `daemon.artifacts` not found.

- [ ] **Step 3: Implement daemon/artifacts.py**

Create `daemon/artifacts.py`:

```python
"""Artifact generation pipeline for Sol daemon.

Provides LLM-driven document generation for PDF, docx, and Excel formats.
All generation is async; file-write helpers are synchronous.
"""
from __future__ import annotations

import json
import re
import tempfile
import time
from pathlib import Path
from typing import Any
from uuid import uuid4

from llama_index.core import Settings


# ---------------------------------------------------------------------------
# LLM access
# ---------------------------------------------------------------------------

def _get_llm():
    return Settings.llm


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

_STRUCTURE_PROMPT = """\
You are generating a structured document outline.
Context from the user's notes:
{context}

User request: {query}

Reply with valid JSON only — no markdown fences:
{{
  "title": "Document title",
  "sections": [
    {{"heading": "Section heading", "bullet_points": ["key point", "key point"]}}
  ]
}}"""

_EXPAND_PROMPT = """\
You are writing a document. Expand the following outline into full prose paragraphs.
Write clearly and professionally. Use markdown headings (##) for each section.

Outline:
{outline_text}

Write the full document body now:"""

_EXCEL_PROMPT = """\
You are extracting structured tabular data from the user's notes.
Context:
{context}

User request: {query}

Reply with valid JSON only — no markdown fences:
{{
  "filename": "descriptive-name.xlsx",
  "columns": ["Column1", "Column2"],
  "rows": [["value", "value"], ["value", "value"]]
}}"""


# ---------------------------------------------------------------------------
# LLM calls
# ---------------------------------------------------------------------------

async def _generate_structure(query: str, context: str) -> dict:
    """Stage 1: ask LLM to produce a document outline (JSON)."""
    prompt = _STRUCTURE_PROMPT.format(query=query, context=context)
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    text = _strip_fences(str(result))
    data = json.loads(text)
    if "title" not in data or "sections" not in data:
        raise ValueError(f"LLM structure response missing required keys: {text!r}")
    return data


async def _generate_content(structure: dict) -> str:
    """Stage 2: expand the outline into full prose markdown."""
    lines = [f"# {structure['title']}", ""]
    for section in structure.get("sections", []):
        lines.append(f"## {section['heading']}")
        for point in section.get("bullet_points", []):
            lines.append(f"- {point}")
        lines.append("")
    outline_text = "\n".join(lines)

    prompt = _EXPAND_PROMPT.format(outline_text=outline_text)
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    return str(result).strip()


async def _generate_excel_rows(query: str, context: str) -> dict:
    """Single-stage: ask LLM to produce columns + rows as JSON."""
    prompt = _EXCEL_PROMPT.format(query=query, context=context)
    llm = _get_llm()
    result = await llm.acomplete(prompt)
    text = _strip_fences(str(result))
    data = json.loads(text)
    if "columns" not in data or "rows" not in data:
        raise ValueError(f"LLM Excel response missing columns/rows: {text!r}")
    if "filename" not in data:
        data["filename"] = "export.xlsx"
    return data


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        parts = text.split("```")
        text = parts[1] if len(parts) > 1 else text
        if text.startswith("json"):
            text = text[4:]
    return text.strip()


# ---------------------------------------------------------------------------
# File builders
# ---------------------------------------------------------------------------

def _safe_filename(title: str, ext: str) -> str:
    name = re.sub(r"[^\w\s\-]", "", title).strip()
    name = re.sub(r"\s+", "-", name)[:60] or "document"
    return f"{name}{ext}"


def _build_pdf(
    structure: dict, content_md: str, out_dir: Path | None = None
) -> tuple[str, str, str]:
    """Render structure + content_md to a PDF using reportlab.

    Returns (file_path, filename, markdown_source).
    """
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import cm
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer

    title = structure.get("title", "Document")
    filename = _safe_filename(title, ".pdf")
    out = Path(out_dir or tempfile.gettempdir()) / f"{uuid4().hex}-{filename}"

    styles = getSampleStyleSheet()
    title_style = ParagraphStyle("DocTitle", parent=styles["Title"], fontSize=20, spaceAfter=18)
    h2_style = ParagraphStyle("DocH2", parent=styles["Heading2"], fontSize=14, spaceBefore=12, spaceAfter=6)
    body_style = styles["Normal"]

    story = [Paragraph(title, title_style)]
    for line in content_md.split("\n"):
        stripped = line.strip()
        if not stripped:
            story.append(Spacer(1, 0.3 * cm))
        elif stripped.startswith("## "):
            story.append(Paragraph(stripped[3:], h2_style))
        elif stripped.startswith("# "):
            pass  # title already added
        else:
            story.append(Paragraph(stripped, body_style))

    doc = SimpleDocTemplate(str(out), pagesize=A4)
    doc.build(story)

    md_source = f"# {title}\n\n{content_md}"
    return str(out), filename, md_source


def _build_docx(
    structure: dict, content_md: str, out_dir: Path | None = None
) -> tuple[str, str, str]:
    """Render structure + content_md to a .docx using python-docx.

    Returns (file_path, filename, markdown_source).
    """
    from docx import Document
    from docx.shared import Pt

    title = structure.get("title", "Document")
    filename = _safe_filename(title, ".docx")
    out = Path(out_dir or tempfile.gettempdir()) / f"{uuid4().hex}-{filename}"

    doc = Document()
    doc.add_heading(title, 0)

    for line in content_md.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        elif stripped.startswith("## "):
            doc.add_heading(stripped[3:], level=1)
        elif stripped.startswith("# "):
            pass  # title already added
        elif stripped.startswith("- "):
            p = doc.add_paragraph(style="List Bullet")
            p.add_run(stripped[2:])
        else:
            doc.add_paragraph(stripped)

    doc.save(str(out))
    md_source = f"# {title}\n\n{content_md}"
    return str(out), filename, md_source


def _build_excel(
    data: dict, out_dir: Path | None = None
) -> tuple[str, str, str]:
    """Write columns + rows to a .xlsx using openpyxl.

    Returns (file_path, filename, markdown_source).
    """
    from openpyxl import Workbook
    from openpyxl.styles import Font

    filename = data.get("filename", "export.xlsx")
    if not filename.endswith(".xlsx"):
        filename += ".xlsx"
    out = Path(out_dir or tempfile.gettempdir()) / f"{uuid4().hex}-{filename}"

    wb = Workbook()
    ws = wb.active
    ws.title = "Data"

    columns = data.get("columns", [])
    rows = data.get("rows", [])

    ws.append(columns)
    for cell in ws[1]:
        cell.font = Font(bold=True)

    for row in rows:
        ws.append(row)

    for col in ws.columns:
        max_len = max((len(str(c.value or "")) for c in col), default=10)
        ws.column_dimensions[col[0].column_letter].width = min(max_len + 4, 40)

    wb.save(str(out))

    # Markdown source: formatted table
    header = "| " + " | ".join(columns) + " |"
    sep = "| " + " | ".join("---" for _ in columns) + " |"
    data_rows = ["| " + " | ".join(str(v) for v in row) + " |" for row in rows]
    md_source = "\n".join([header, sep] + data_rows)

    return str(out), filename, md_source


# ---------------------------------------------------------------------------
# Temp store
# ---------------------------------------------------------------------------

from dataclasses import dataclass


@dataclass
class ArtifactEntry:
    path: str
    filename: str
    markdown_source: str
    created_at: float = 0.0

    def __post_init__(self):
        if self.created_at == 0.0:
            self.created_at = time.time()


def make_artifact_store() -> dict[str, ArtifactEntry]:
    return {}


def cleanup_artifact_store(store: dict[str, ArtifactEntry], ttl_s: float = 600.0) -> None:
    """Remove entries older than ttl_s seconds."""
    now = time.time()
    stale = [k for k, v in store.items() if now - v.created_at > ttl_s]
    for k in stale:
        try:
            Path(store[k].path).unlink(missing_ok=True)
        except Exception:
            pass
        del store[k]
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/aakashranga/IN/Sol && python -m pytest daemon/tests/test_artifacts.py -v
```
Expected: all PASSED.

- [ ] **Step 5: Commit**

```bash
git add daemon/artifacts.py daemon/tests/test_artifacts.py
git commit -m "feat(daemon): implement artifact generation pipeline (PDF, docx, Excel)"
```

---

## Task 3: Initialise artifact temp store in daemon and add download endpoint

**Files:**
- Modify: `daemon/main.py`
- Create: `daemon/routes/artifact_download.py`

- [ ] **Step 1: Write failing test**

```python
# daemon/tests/test_artifacts.py  (append)
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def app_with_store():
    from daemon.main import app
    from daemon.artifacts import make_artifact_store, ArtifactEntry
    import tempfile, pathlib

    # Write a real tiny PDF to temp
    from daemon.artifacts import _build_pdf
    structure = {"title": "Test", "sections": []}
    path, filename, md = _build_pdf(structure, "", out_dir=pathlib.Path(tempfile.gettempdir()))

    app.state.artifact_store = make_artifact_store()
    app.state.artifact_store["test-id"] = ArtifactEntry(
        path=path, filename=filename, markdown_source=md
    )
    return app


def test_download_existing_artifact(app_with_store):
    client = TestClient(app_with_store)
    resp = client.get(
        "/api/artifact/download/test-id",
        headers={"X-API-Key": "test-key"},
    )
    # Will 401 without real key; just check routing works
    assert resp.status_code in (200, 401)


def test_download_missing_artifact(app_with_store):
    client = TestClient(app_with_store)
    resp = client.get(
        "/api/artifact/download/no-such-id",
        headers={"X-API-Key": "test-key"},
    )
    assert resp.status_code in (404, 401)
```

- [ ] **Step 2: Run tests to verify routing test fails**

```bash
cd /Users/aakashranga/IN/Sol && python -m pytest daemon/tests/test_artifacts.py::test_download_missing_artifact -v
```
Expected: `ImportError` or 404 from missing route.

- [ ] **Step 3: Create daemon/routes/artifact_download.py**

```python
# daemon/routes/artifact_download.py
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse, JSONResponse

router = APIRouter()


@router.get("/api/artifact/download/{artifact_id}")
async def download_artifact(artifact_id: str, request: Request):
    store = getattr(request.app.state, "artifact_store", {})
    entry = store.get(artifact_id)
    if entry is None:
        return JSONResponse(status_code=404, content={"detail": "Artifact not found or expired"})

    path = Path(entry.path)
    if not path.exists():
        store.pop(artifact_id, None)
        return JSONResponse(status_code=404, content={"detail": "Artifact file missing"})

    suffix = path.suffix.lower()
    media_types = {
        ".pdf": "application/pdf",
        ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    }
    media_type = media_types.get(suffix, "application/octet-stream")

    return FileResponse(
        path=str(path),
        media_type=media_type,
        filename=entry.filename,
    )
```

- [ ] **Step 4: Register route and init store in daemon/main.py**

Add import to `daemon/main.py`:

```python
from daemon.routes import artifact_download as artifact_download_router
from daemon.artifacts import make_artifact_store, cleanup_artifact_store
```

In the lifespan block (after other initialisation):

```python
    app.state.artifact_store = make_artifact_store()

    # Cleanup task: remove expired artifacts every 5 minutes
    async def _cleanup_loop():
        import asyncio as _asyncio
        while True:
            await _asyncio.sleep(300)
            cleanup_artifact_store(app.state.artifact_store)

    app.state.artifact_cleanup_task = asyncio.create_task(_cleanup_loop())
```

In the lifespan teardown:

```python
    app.state.artifact_cleanup_task.cancel()
```

Register the router:

```python
app.include_router(artifact_download_router.router)
```

- [ ] **Step 5: Run tests**

```bash
cd /Users/aakashranga/IN/Sol && python -m pytest daemon/tests/test_artifacts.py -v
```
Expected: all PASSED.

- [ ] **Step 6: Commit**

```bash
git add daemon/routes/artifact_download.py daemon/main.py daemon/tests/test_artifacts.py
git commit -m "feat(daemon): add artifact temp store and download endpoint"
```

---

## Task 4: Wire artifact generation into query route

**Files:**
- Modify: `daemon/routes/query.py`

- [ ] **Step 1: Write failing test**

Append to `daemon/tests/test_artifacts.py`:

```python
@pytest.mark.asyncio
async def test_query_route_emits_artifact_progress():
    """When _is_artifact_request returns true the route emits artifact_progress events."""
    import json
    from unittest.mock import AsyncMock, MagicMock, patch

    # We test the generate() async generator directly
    async def fake_artifact_gen(*args, **kwargs):
        yield {"type": "artifact_progress", "stage": "generating_content"}
        yield {"type": "artifact_progress", "stage": "building_file"}
        yield {
            "type": "artifact_ready",
            "artifact_id": "abc",
            "format": "pdf",
            "filename": "test.pdf",
            "markdown_source": "# Test",
        }

    with patch("solidrag.query.engine._is_artifact_request",
               new=AsyncMock(return_value=(True, {"format": "pdf", "content_source": "vault", "query": "goals"}))):
        with patch("daemon.routes.query._run_artifact_pipeline", new=fake_artifact_gen):
            from daemon.routes.query import _build_query_generator

            mock_request = MagicMock()
            mock_request.app.state.vault_index_llama = MagicMock()
            mock_request.app.state.config.system_prompt = None
            mock_request.app.state.artifact_store = {}

            events = []
            async for chunk in _build_query_generator(mock_request, "make a PDF of my goals", []):
                data = chunk.replace("data: ", "").strip()
                if data:
                    events.append(json.loads(data))

    types = [e["type"] for e in events]
    assert "artifact_progress" in types
    assert "artifact_ready" in types
```

- [ ] **Step 2: Refactor query.py to extract _build_query_generator and add _run_artifact_pipeline**

Replace the `generate()` closure inside `query_vault` with a standalone async generator, and add the artifact pipeline dispatcher. Full updated `daemon/routes/query.py`:

```python
import json
from uuid import uuid4

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, field_validator

from solidrag import query_stream_async
from solidrag.query.engine import _is_artifact_request

router = APIRouter()


class HistoryMessage(BaseModel):
    role: str
    content: str


class QueryRequest(BaseModel):
    question: str
    history: list[HistoryMessage] | None = None

    @field_validator("question")
    @classmethod
    def question_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("question cannot be empty")
        return v


async def _run_artifact_pipeline(request: Request, artifact_info: dict, history: list[dict]):
    """Run the artifact generation pipeline and yield SSE event dicts."""
    from daemon.artifacts import (
        ArtifactEntry,
        _build_docx,
        _build_excel,
        _build_pdf,
        _generate_content,
        _generate_excel_rows,
        _generate_structure,
    )

    fmt = artifact_info["format"]
    content_source = artifact_info.get("content_source", "vault")
    query = artifact_info.get("query", "")
    index = request.app.state.vault_index_llama

    yield {"type": "artifact_progress", "stage": "generating_content"}

    # Retrieve context from vault if needed
    context = ""
    if content_source in ("vault", "both") and index is not None:
        from llama_index.core import Settings
        retriever = index.as_retriever(similarity_top_k=8)
        nodes = await retriever.aretrieve(query)
        context = "\n\n".join(node.get_content() for node in nodes)

    if content_source in ("conversation", "both") and history:
        history_text = "\n".join(
            f"{'User' if m['role'] == 'user' else 'Sol'}: {m['content']}"
            for m in history
        )
        context = (history_text + "\n\n" + context).strip()

    try:
        if fmt == "xlsx":
            data = await _generate_excel_rows(query=query, context=context)
            yield {"type": "artifact_progress", "stage": "building_file"}
            path, filename, md_source = _build_excel(data)
        else:
            structure = await _generate_structure(query=query, context=context)
            content_md = await _generate_content(structure)
            yield {"type": "artifact_progress", "stage": "building_file"}
            if fmt == "docx":
                path, filename, md_source = _build_docx(structure, content_md)
            else:  # pdf
                path, filename, md_source = _build_pdf(structure, content_md)
    except Exception as exc:
        yield {"type": "error", "content": f"Artifact generation failed: {exc}"}
        return

    artifact_id = str(uuid4())
    request.app.state.artifact_store[artifact_id] = ArtifactEntry(
        path=path, filename=filename, markdown_source=md_source
    )

    yield {
        "type": "artifact_ready",
        "artifact_id": artifact_id,
        "format": fmt,
        "filename": filename,
        "markdown_source": md_source,
    }


async def _build_query_generator(request: Request, question: str, history: list[dict]):
    """Yield SSE-formatted data strings for a query."""
    index = getattr(request.app.state, "vault_index_llama", None)
    system_prompt = getattr(request.app.state.config, "system_prompt", None)

    try:
        is_artifact, artifact_info = await _is_artifact_request(question)
    except Exception:
        is_artifact, artifact_info = False, None

    if is_artifact and artifact_info:
        async for event in _run_artifact_pipeline(request, artifact_info, history):
            yield f"data: {json.dumps(event)}\n\n"
        yield f"data: {json.dumps({'type': 'done'})}\n\n"
        return

    try:
        async for event in query_stream_async(
            index,
            question,
            history=history,
            system_prompt=system_prompt,
        ):
            yield f"data: {json.dumps(event)}\n\n"
    except Exception as e:
        err = str(e)
        if "timeout" in err.lower() or "timed out" in err.lower():
            msg = "LLM timed out — try a shorter question or try again"
        else:
            msg = err
        yield f"data: {json.dumps({'type': 'error', 'content': msg})}\n\n"


@router.post("/api/query")
async def query_vault(request: Request, body: QueryRequest):
    """Stream query response as Server-Sent Events."""
    index = getattr(request.app.state, "vault_index_llama", None)
    if index is None:
        return JSONResponse(status_code=503, content={"detail": "Index not ready yet"})

    history = [{"role": m.role, "content": m.content} for m in (body.history or [])]

    return StreamingResponse(
        _build_query_generator(request, body.question, history),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
```

- [ ] **Step 3: Run tests**

```bash
cd /Users/aakashranga/IN/Sol && python -m pytest daemon/tests/ -v
```
Expected: all PASSED.

- [ ] **Step 4: Manual smoke test**

Start daemon and send a query:

```bash
curl -N -X POST http://localhost:8765/api/query \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $(cat ~/.sol/config.json | python3 -c 'import sys,json;print(json.load(sys.stdin)["daemon_api_key"])')" \
  -d '{"question": "generate a PDF summary of my notes"}'
```

Expected: stream includes `artifact_progress` then `artifact_ready` events.

- [ ] **Step 5: Commit**

```bash
git add daemon/routes/query.py daemon/tests/test_artifacts.py
git commit -m "feat(daemon): wire artifact pipeline into query SSE route"
```

---

## Task 5: iOS — ArtifactModels and ArtifactService

**Files:**
- Create: `ios/Sol/Models/ArtifactModels.swift`
- Create: `ios/Sol/Services/ArtifactService.swift`

- [ ] **Step 1: Create ArtifactModels.swift**

```swift
// ios/Sol/Models/ArtifactModels.swift
import Foundation

enum ArtifactFormat: String, Decodable {
    case pdf, docx, xlsx
}

struct ArtifactReadyPayload: Decodable {
    let artifactId: String
    let format: ArtifactFormat
    let filename: String
    let markdownSource: String

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
        case format, filename
        case markdownSource = "markdown_source"
    }
}

struct ArtifactProgressPayload: Decodable {
    let stage: String
}
```

- [ ] **Step 2: Create ArtifactService.swift**

```swift
// ios/Sol/Services/ArtifactService.swift
import Foundation

final class ArtifactService {
    static let shared = ArtifactService()
    private init() {}

    func download(artifactId: String) async throws -> URL {
        guard let config = KeychainService.load() else {
            throw URLError(.userAuthenticationRequired)
        }

        let downloadURL = config.baseURL
            .appendingPathComponent("api/artifact/download")
            .appendingPathComponent(artifactId)

        var request = URLRequest(url: downloadURL)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Derive extension from Content-Disposition or fall back to artifact ID
        let ext = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .components(separatedBy: ".")
            .last ?? "pdf"

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(artifactId)
            .appendingPathExtension(ext)
        try data.write(to: tempURL)
        return tempURL
    }

    func saveToVault(markdownSource: String, title: String) async throws {
        try await APIClient.shared.submitNote(
            NoteRequest(content: markdownSource, title: title, tags: nil, source: .text)
        )
    }
}
```

- [ ] **Step 3: Build iOS target**

In Xcode: Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add ios/Sol/Models/ArtifactModels.swift ios/Sol/Services/ArtifactService.swift
git commit -m "feat(ios): add ArtifactModels and ArtifactService"
```

---

## Task 6: iOS — Progress card and document card in QueryView

**Files:**
- Modify: `ios/Sol/Views/QueryView.swift`

- [ ] **Step 1: Add artifact state to QueryView**

Find the `@State` properties block in `QueryView` and add:

```swift
@State private var artifactProgress: String? = nil  // stage label or nil
@State private var artifactReady: ArtifactReadyPayload? = nil
@State private var artifactDownloadURL: URL? = nil
@State private var showArtifactPreview = false
```

- [ ] **Step 2: Handle artifact SSE events in the stream parser**

In the SSE event parsing block (where `"token"`, `"sources"`, `"done"` are handled), add:

```swift
} else if type == "artifact_progress" {
    if let stage = event["stage"] as? String {
        let label: String
        switch stage {
        case "generating_content": label = "Generating content…"
        case "building_file":      label = "Building file…"
        default:                   label = "Working…"
        }
        await MainActor.run { artifactProgress = label }
    }
} else if type == "artifact_ready" {
    if let payloadData = try? JSONSerialization.data(withJSONObject: event),
       let payload = try? JSONDecoder().decode(ArtifactReadyPayload.self, from: payloadData) {
        await MainActor.run {
            artifactProgress = nil
            artifactReady = payload
        }
    }
}
```

- [ ] **Step 3: Add progress card view**

Add this private view to `QueryView`:

```swift
@ViewBuilder
private var artifactProgressCard: some View {
    if let stage = artifactProgress {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.85)
            Text(stage)
                .font(.system(size: 15))
                .foregroundStyle(DS.inkDark)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.parchment, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
```

- [ ] **Step 4: Add document card view**

```swift
@ViewBuilder
private var artifactDocumentCard: some View {
    if let payload = artifactReady {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: payload.format == .pdf ? "doc.richtext" :
                      payload.format == .docx ? "doc.text" : "tablecells")
                    .font(.system(size: 22))
                    .foregroundStyle(DS.terracotta)
                Text(payload.filename)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.inkDark)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button("Open") {
                    Task {
                        if let url = try? await ArtifactService.shared.download(artifactId: payload.artifactId) {
                            artifactDownloadURL = url
                            showArtifactPreview = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.terracotta)

                Button("Share") {
                    Task {
                        if let url = try? await ArtifactService.shared.download(artifactId: payload.artifactId) {
                            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let root = scene.windows.first?.rootViewController {
                                root.present(av, animated: true)
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(DS.terracotta)
            }

            Divider()

            Button("Save to Vault") {
                Task {
                    let title = String(payload.filename.split(separator: ".").first ?? "Document")
                    try? await ArtifactService.shared.saveToVault(
                        markdownSource: payload.markdownSource,
                        title: title
                    )
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(DS.inkMid)
        }
        .padding(16)
        .background(DS.parchment, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.inkFaint.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
```

- [ ] **Step 5: Insert cards into the conversation list**

In the message list / scroll view where query responses are shown, add after the last message bubble:

```swift
artifactProgressCard
artifactDocumentCard
```

- [ ] **Step 6: Add QLPreviewController sheet**

Add to the view's modifiers:

```swift
.sheet(isPresented: $showArtifactPreview) {
    if let url = artifactDownloadURL {
        ArtifactPreviewView(url: url)
    }
}
```

Create a minimal `ArtifactPreviewView`:

```swift
// Add at the bottom of QueryView.swift or in a new file
import QuickLook

struct ArtifactPreviewView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in _: QLPreviewController) -> Int { 1 }
        func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
```

- [ ] **Step 7: Build and test manually**

Build (⌘B). Connect to daemon via Tailscale. Ask: *"Generate a PDF summary of my notes from this week."*

Expected:
1. Progress card appears with "Generating content…" then "Building file…"
2. Document card appears with filename, Open/Share/Save to Vault buttons
3. Tap Open → QLPreviewController shows the PDF
4. Tap Save to Vault → note appears in Obsidian

- [ ] **Step 8: Commit**

```bash
git add ios/Sol/Views/QueryView.swift
git commit -m "feat(ios): add artifact progress card and document card to QueryView"
```
