"""Tests for daemon/routes/uploads.py — file and image upload endpoints."""
import io
import json
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from fastapi import FastAPI
from fastapi.testclient import TestClient

from daemon.routes import uploads as uploads_router

VALID_CONFIG = {
    "vault_path": "/tmp/vault",
    "daemon_port": 8765,
    "obsidian_api_key": "obskey",
    "obsidian_port": 27124,
    "daemon_api_key": "testkey123",
    "ollama_model": "phi3.5",
    "ollama_base_url": "http://localhost:11434",
}


def _make_app() -> tuple[FastAPI, AsyncMock]:
    """Build a minimal FastAPI app with the uploads router and a mock obsidian client."""
    app = FastAPI()
    app.include_router(uploads_router.router)

    mock_obsidian = AsyncMock()
    mock_obsidian.put_file = AsyncMock(return_value=None)

    @app.on_event("startup")
    async def _setup_state():
        app.state.obsidian = mock_obsidian

    return app, mock_obsidian


@pytest.fixture
def app_and_obsidian():
    return _make_app()


@pytest.fixture
def client(app_and_obsidian):
    app, mock_obs = app_and_obsidian
    with TestClient(app) as c:
        yield c, mock_obs


# ---------------------------------------------------------------------------
# POST /api/upload/file — PDF
# ---------------------------------------------------------------------------

def test_upload_pdf_calls_put_file_with_correct_path(client):
    c, mock_obs = client
    pdf_data = b"%PDF-1.4 fake pdf content"

    with patch("daemon.routes.uploads._timestamp_dir", return_value="26-01-06-12-00"):
        resp = c.post(
            "/api/upload/file",
            files={"file": ("report.pdf", io.BytesIO(pdf_data), "application/pdf")},
        )

    assert resp.status_code == 200
    data = resp.json()
    assert data["file_path"] == "uploads/pdf/26-01-06-12-00/report.pdf"
    mock_obs.put_file.assert_awaited_once_with(
        "uploads/pdf/26-01-06-12-00/report.pdf", pdf_data
    )


# ---------------------------------------------------------------------------
# POST /api/upload/file — XLSX
# ---------------------------------------------------------------------------

def test_upload_xlsx_calls_put_file_with_excel_path(client):
    c, mock_obs = client
    xlsx_data = b"PK\x03\x04 fake xlsx content"

    with patch("daemon.routes.uploads._timestamp_dir", return_value="26-01-06-09-30"):
        resp = c.post(
            "/api/upload/file",
            files={"file": ("data.xlsx", io.BytesIO(xlsx_data), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")},
        )

    assert resp.status_code == 200
    data = resp.json()
    assert data["file_path"] == "uploads/excel/26-01-06-09-30/data.xlsx"
    mock_obs.put_file.assert_awaited_once_with(
        "uploads/excel/26-01-06-09-30/data.xlsx", xlsx_data
    )


def test_upload_xls_uses_excel_prefix(client):
    """Old-format .xls files should also go to uploads/excel/."""
    c, mock_obs = client
    xls_data = b"\xd0\xcf\x11\xe0 fake xls content"

    with patch("daemon.routes.uploads._timestamp_dir", return_value="26-02-06-10-00"):
        resp = c.post(
            "/api/upload/file",
            files={"file": ("legacy.xls", io.BytesIO(xls_data), "application/vnd.ms-excel")},
        )

    assert resp.status_code == 200
    assert resp.json()["file_path"].startswith("uploads/excel/")


# ---------------------------------------------------------------------------
# POST /api/upload/file — DOCX
# ---------------------------------------------------------------------------

def test_upload_docx_extracts_markdown_and_writes_md_note(client):
    """DocxExtractor is called; result is written as <stem>.md to vault root."""
    c, mock_obs = client
    docx_data = b"PK\x03\x04 fake docx bytes"

    mock_node = MagicMock()
    mock_node.text = "# My Doc\n\nSome paragraph text."

    with patch("daemon.routes.uploads.DocxExtractor") as MockExtractor:
        instance = MockExtractor.return_value
        instance.extract.return_value = [mock_node]

        resp = c.post(
            "/api/upload/file",
            files={"file": ("notes.docx", io.BytesIO(docx_data), "application/vnd.openxmlformats-officedocument.wordprocessingml.document")},
        )

    assert resp.status_code == 200
    data = resp.json()
    assert data["file_path"] == "notes.md"

    # put_file should be called with the .md filename and the encoded markdown
    mock_obs.put_file.assert_awaited_once()
    call_args = mock_obs.put_file.call_args
    assert call_args[0][0] == "notes.md"
    written_bytes = call_args[0][1]
    assert b"My Doc" in written_bytes


def test_upload_docx_extraction_failure_returns_422(client):
    """If DocxExtractor raises, the endpoint returns 422 Unprocessable Entity."""
    c, mock_obs = client
    docx_data = b"corrupt bytes"

    with patch("daemon.routes.uploads.DocxExtractor") as MockExtractor:
        instance = MockExtractor.return_value
        instance.extract.side_effect = Exception("parse error")

        resp = c.post(
            "/api/upload/file",
            files={"file": ("bad.docx", io.BytesIO(docx_data), "application/vnd.openxmlformats-officedocument.wordprocessingml.document")},
        )

    assert resp.status_code == 422
    assert "Failed to parse" in resp.json()["detail"]


# ---------------------------------------------------------------------------
# POST /api/upload/image
# ---------------------------------------------------------------------------

def test_upload_image_writes_to_attachments_and_returns_embed(client):
    c, mock_obs = client
    png_data = b"\x89PNG\r\n\x1a\n fake png"

    resp = c.post(
        "/api/upload/image",
        files={"file": ("screenshot.png", io.BytesIO(png_data), "image/png")},
    )

    assert resp.status_code == 200
    data = resp.json()
    assert data["embed"] == "![[screenshot.png]]"
    mock_obs.put_file.assert_awaited_once_with(
        "attachments/screenshot.png", png_data
    )


def test_upload_image_uses_original_filename_in_embed(client):
    c, mock_obs = client
    jpg_data = b"\xff\xd8\xff fake jpg"

    resp = c.post(
        "/api/upload/image",
        files={"file": ("diagram.jpg", io.BytesIO(jpg_data), "image/jpeg")},
    )

    assert resp.status_code == 200
    assert resp.json()["embed"] == "![[diagram.jpg]]"


# ---------------------------------------------------------------------------
# Unsupported extension
# ---------------------------------------------------------------------------

def test_upload_unsupported_extension_returns_415(client):
    c, mock_obs = client

    resp = c.post(
        "/api/upload/file",
        files={"file": ("script.py", io.BytesIO(b"print('hi')"), "text/x-python")},
    )

    assert resp.status_code == 415
    assert "Unsupported file type" in resp.json()["detail"]
