# Artifact Generation — Design Spec

**Date:** 2026-06-13
**Status:** Approved
**Scope:** Group E of the Sol feature expansion — user-initiated PDF, Word, and Excel generation from vault content or conversation history

---

## Overview

When the user explicitly asks Sol to generate a document ("make a PDF of my Q3 goals", "summarise this chat as a Word doc", "export my expenses as Excel"), the daemon runs a structured LLM pipeline to produce the artifact, streams progress back to iOS, and delivers the binary file for preview and optional vault save. No proactive offering — the user always initiates.

---

## 1. Intent detection

### _is_artifact_request()

A new pre-classification step in `solidrag/query/engine.py`, running alongside `_needs_vault()` and `_is_calendar_action()`.

Single structured LLM call with Ollama JSON mode:

```python
async def _is_artifact_request(question: str, history: list[dict]) -> tuple[bool, dict | None]
```

Returns:

```json
{
  "is_artifact_request": true,
  "format": "pdf",
  "content_source": "conversation",
  "query": "summarize this chat"
}
```

**`format`**: one of `"pdf"`, `"docx"`, `"xlsx"`

**`content_source`**:
- `"conversation"` — conversation history is primary source, vault retrieval skipped
- `"vault"` — vault RAG only, conversation context included if relevant
- `"both"` — vault RAG primary, conversation history also provided to LLM

When `is_artifact_request` is true, the normal streaming text response is replaced entirely by the artifact progress stream. The LLM does not produce a chat reply alongside the artifact.

### SSE event types

Three new event types added to the existing stream:

```json
{"type": "artifact_progress", "stage": "generating_content"}
{"type": "artifact_progress", "stage": "building_file"}
{
  "type": "artifact_ready",
  "artifact_id": "uuid",
  "format": "pdf",
  "filename": "Q3-Summary.pdf",
  "markdown_source": "# Q3 Goals Summary\n\n## Overview\n..."
}
```

`markdown_source` is included in `artifact_ready` so iOS can save to vault without a second request.

---

## 2. Daemon: artifact generation pipeline

### New route file: daemon/routes/artifacts.py

**`POST /api/artifact/generate`**

Request body:
```json
{
  "format": "pdf",
  "content_source": "conversation",
  "query": "summarize this chat",
  "conversation_history": [...]
}
```

The artifact request arrives as a normal query message on `POST /api/query` (the existing SSE endpoint). When `_is_artifact_request()` returns true, the query handler calls the generation pipeline directly and emits progress events on the same SSE connection — no second HTTP connection, no separate polling. `POST /api/artifact/generate` is an internal helper called by the query handler, not called directly by iOS.

**`GET /api/artifact/download/{artifact_id}`**

Returns the binary file with correct `Content-Type` and `Content-Disposition: attachment; filename="..."`.

Files are held in a temp store: `app.state.artifact_store: dict[str, ArtifactEntry]` where `ArtifactEntry` holds the file path and a creation timestamp. A background cleanup task deletes entries older than 10 minutes.

No new dependencies — `reportlab`, `python-docx`, and `openpyxl` are already solidRag dependencies from Group A.

---

### PDF and docx pipeline (two-stage)

**Stage 1 — Structure generation** (JSON mode):

LLM produces a document outline from the content source (vault nodes, conversation history, or both):

```json
{
  "title": "Q3 Goals Summary",
  "sections": [
    {"heading": "Overview",    "bullet_points": ["..."]},
    {"heading": "Key Results", "bullet_points": ["..."]}
  ]
}
```

`artifact_progress: generating_content` emitted at this stage.

**Stage 2 — Content expansion:**

LLM expands each section into full prose using the outline as scaffold. Output is clean markdown. Daemon converts to target format:

- **PDF** → `reportlab` renders title, headings, and body paragraphs
- **docx** → `python-docx` maps headings/paragraphs to Word styles

`artifact_progress: building_file` emitted during conversion.

---

### Excel pipeline (single-stage)

One JSON-mode LLM call produces rows and columns directly:

```json
{
  "filename": "Expenses-2026.xlsx",
  "columns": ["Date", "Category", "Amount", "Notes"],
  "rows": [
    ["2026-05-12", "Travel", "£240", "Flight to London"],
    ["2026-05-19", "Software", "£15", "Notion subscription"]
  ]
}
```

`openpyxl` writes this to `.xlsx` — header row bolded, columns auto-width.

`artifact_progress: generating_content` and `artifact_progress: building_file` emitted in sequence.

---

### Markdown source generation

For all formats, the daemon produces and stores a clean markdown version of the document content alongside the binary file. This is included in the `artifact_ready` event as `markdown_source`. For Excel, markdown source is a formatted table.

---

## 3. iOS changes

### QueryView changes

The SSE parser handles three new event types:

**`artifact_progress`** → renders a **progress card** inline in the conversation thread. Shows format icon (PDF/Word/Excel), filename, and a spinner with stage label:
- `generating_content` → "Generating content…"
- `building_file` → "Building file…"

The progress card occupies the space where a text response would normally appear — artifact requests produce no chat text.

**`artifact_ready`** → spinner resolves to a **document card** showing:
- Format icon + filename + file size
- **Open** button → downloads from `GET /api/artifact/download/{artifact_id}`, saves to a local temp URL, presents `QLPreviewController` full-screen. Handles PDF, docx, and xlsx natively (iOS 13+).
- **Share** button → downloads file, presents `UIActivityViewController` (AirDrop, Files, email, etc.)
- **Save to Vault** button at the bottom of the card → sends `markdown_source` from the `artifact_ready` payload directly to `POST /api/note`. Brief toast: "Saved to vault." No second network request needed.

### New service: ArtifactService.swift

Lives alongside `APIClient.swift` and `UploadService.swift`:

```swift
class ArtifactService {
    static let shared = ArtifactService()

    func generate(
        format: ArtifactFormat,
        contentSource: ContentSource,
        query: String,
        history: [Message]
    ) async throws -> String                    // returns artifact_id

    func download(artifactId: String) async throws -> URL   // local temp file URL

    func saveToVault(markdownSource: String, title: String) async throws
}

enum ArtifactFormat: String, Decodable { case pdf, docx, xlsx }
enum ContentSource: String, Decodable  { case conversation, vault, both }
```

`APIClient.swift` is not modified.

---

## 4. Data flows

### User-initiated vault artifact

```
User: "generate a PDF of my Q3 goals"
  → _is_artifact_request() → {format: pdf, content_source: vault}
  → vault RAG retrieval (Q3 goals notes)
  → Stage 1: LLM → document outline JSON
  → SSE: artifact_progress {stage: generating_content}
  → Stage 2: LLM → markdown prose
  → reportlab → Q3-Goals.pdf written to temp store
  → SSE: artifact_progress {stage: building_file}
  → SSE: artifact_ready {artifact_id, format, filename, markdown_source}
iOS: progress card → document card
User taps Open → QLPreviewController shows PDF
User taps Save to Vault → POST /api/note with markdown_source → toast "Saved to vault"
```

### Conversation summary as docx

```
User: "summarise this chat as a Word doc"
  → _is_artifact_request() → {format: docx, content_source: conversation}
  → vault retrieval skipped
  → Stage 1: LLM uses conversation_history → outline JSON
  → SSE: artifact_progress {stage: generating_content}
  → Stage 2: LLM expands outline → markdown
  → python-docx → Chat-Summary.docx written to temp store
  → SSE: artifact_progress {stage: building_file}
  → SSE: artifact_ready {artifact_id, format, filename, markdown_source}
iOS: document card with Open / Share / Save to Vault
```

### Excel from vault

```
User: "make an Excel of all my tracked expenses"
  → _is_artifact_request() → {format: xlsx, content_source: vault}
  → vault RAG retrieval (expense notes)
  → Single-stage: LLM → JSON {columns, rows}
  → SSE: artifact_progress {stage: generating_content}
  → openpyxl → Expenses.xlsx written to temp store
  → SSE: artifact_progress {stage: building_file}
  → SSE: artifact_ready {artifact_id, format, filename, markdown_source}
iOS: document card
```

---

## 5. Error handling

| Failure | Behaviour |
|---|---|
| LLM produces malformed JSON (structure stage) | Retry once; if still malformed, SSE error event, iOS shows "Generation failed" on progress card |
| File conversion error (reportlab / python-docx / openpyxl) | SSE error event, iOS shows "Generation failed" |
| Download fails on iOS | iOS shows retry button on document card |
| Artifact TTL expired before download | 404 from download endpoint, iOS shows "File expired — regenerate" |
| Save to Vault fails | iOS shows error alert, user retries manually |

---

## 6. Performance

| Stage | Expected duration |
|---|---|
| Intent detection | ~1s |
| Stage 1 (structure LLM call) | ~3-5s |
| Stage 2 (content LLM call) | ~5-15s depending on document length |
| File conversion | < 1s |
| Total (PDF/docx) | ~10-20s |
| Excel (single stage) | ~5-10s |

Progress events keep iOS informed throughout — the user sees activity from the first second.

---

## 7. Out of scope

- Proactive artifact offering (user always initiates)
- Editing artifacts after generation
- Artifact history / re-download after TTL expiry
- Custom templates or branding for generated documents
- Streaming document content token-by-token (full generation before file write)
