# Rich Media & File Ingestion — Design Spec

**Date:** 2026-06-13
**Status:** Approved
**Scope:** Group A of the Sol feature expansion — images, PDFs, Excel, Word/Google Docs ingestion + the solidRag library extraction

---

## Overview

This spec covers two major changes:

1. **solidRag** — extract Sol's RAG pipeline into a portable, source-agnostic Python library living at `packages/solidrag/` in the Sol monorepo.
2. **Rich media & file ingestion** — allow iOS users to attach images to notes and upload standalone files (PDF, Excel, Word) directly to the Obsidian vault, with all content indexed for RAG.

---

## 1. solidRag Library

### Purpose

solidRag is a source-agnostic RAG library. It has no knowledge of Obsidian, Sol, or FastAPI. It takes source directories and a configuration object, and exposes a queryable FAISS-backed index. Sol installs it as a local editable package. Future projects can install it from git or PyPI.

### Package layout

```
Sol/
  packages/
    solidrag/
      pyproject.toml
      solidrag/
        __init__.py              # public API surface
        config.py                # SolidRagConfig dataclass
        extractors/
          base.py                # Extractor protocol (ABC)
          registry.py            # ExtractorRegistry
          markdown.py            # MarkdownExtractor
          pdf.py                 # PDFExtractor (pypdf)
          excel.py               # ExcelExtractor (openpyxl)
          docx.py                # DocxExtractor → markdown text (no file written)
          image.py               # ImageExtractor (llava, batch only)
        index/
          builder.py             # build_index(), incremental rebuild logic
          watcher.py             # SourceWatcher (replaces VaultWatcher)
          scheduler.py           # ResourceAwareScheduler for heavy extractors
          manifest.py            # IndexManifest — tracks filepath → (mtime, node_ids)
        query/
          engine.py              # query_stream_async(), intent routing
          prompts.py             # prompt builders (direct + RAG)
```

### Public API

```python
from solidrag import SolidRagConfig, build_index, SourceWatcher, query_stream_async
from solidrag.extractors import ExtractorRegistry
from solidrag.index.scheduler import ResourceAwareScheduler
```

### Extractor protocol

Every extractor implements:

```python
class Extractor(Protocol):
    supported_extensions: frozenset[str]
    def extract(self, path: Path) -> list[TextNode]: ...
```

The `ExtractorRegistry` maps file extensions to extractors. `build_index()` walks source directories, delegates each file to the correct extractor, collects `TextNode` objects, and builds (or incrementally updates) the FAISS index. Future source types — Calendar, Email — implement the same protocol and register themselves with no changes to the core build path.

### SolidRagConfig

```python
@dataclass
class SolidRagConfig:
    source_dirs: list[Path]         # dirs to crawl (vault root, uploads/, attachments/)
    ollama_base_url: str
    ollama_model: str
    embed_model: str                # default: nomic-embed-text
    vision_model: str               # default: llava
    persist_dir: Path               # where FAISS index + manifest live
    image_batch_interval_s: int     # default: 3600
```

Sol constructs this from `~/.sol/config.json` and passes it in. The library never reads Sol config directly.

### Incremental reindexing

`build_index()` maintains an `IndexManifest` at `~/.sol/index/manifest.json`:

```json
{
  "uploads/pdf/26-13-06-14-30/report.pdf": {
    "mtime": 1749823800.0,
    "node_ids": ["abc123", "def456"]
  }
}
```

On each SourceWatcher trigger, the manifest is diffed against the filesystem:

- **New file**: extract → insert nodes → add to manifest
- **Modified file**: delete old node IDs from FAISS → re-extract → insert new nodes → update manifest
- **Deleted file**: delete node IDs from FAISS → remove from manifest

The underlying FAISS index switches from `IndexFlatL2` to `IndexIDMap2(IndexFlatL2)` to support per-vector deletion by ID.

Full rebuilds only occur on first boot or if the manifest is missing or corrupt.

### Concurrency model

- **Text file changes** (markdown, PDF, Excel): handled by SourceWatcher on a background thread. Incremental updates are small (one or two files). Applied in-place with a short `asyncio.Lock` — hold time is milliseconds. Queries are never blocked.
- **Image batch** (llava): heavier — potentially hundreds of nodes. Nodes are built entirely in the background thread, then spliced into the live index under the lock in a single operation. Copy-on-write pattern for the node batch; the lock is only held for the splice.

### ResourceAwareScheduler

Runs the llava image batch on a background thread. Before each batch it checks:

- macOS CPU usage (via `psutil`) averaged over 60s < 40%
- Battery plugged in **or** charge > 50%
- No active Ollama inference (checked via `GET /api/ps`)

If any check fails, backs off by 15 minutes and retries. On success:

1. Load llava via Ollama (`ollama run llava`)
2. Process all unindexed images in `attachments/` (tracked via `IndexManifest`)
3. Generate `TextNode` descriptions for each image
4. Splice nodes into the live index
5. Unload model via `ollama stop llava`

Default interval: 3600s. Interval is configurable via `SolidRagConfig.image_batch_interval_s`.

---

## 2. Sol daemon changes

### Dependency removal

`daemon/rag.py` is deleted. All RAG logic moves into solidRag. The daemon imports:

```python
from solidrag import SolidRagConfig, build_index, SourceWatcher, query_stream_async
from solidrag.index.scheduler import ResourceAwareScheduler
```

### New dependencies

**daemon/pyproject.toml** gains one entry:
```
solidrag @ file:./packages/solidrag
```

**packages/solidrag/pyproject.toml** declares its own extraction dependencies:
```
pypdf
openpyxl
python-docx
```

The daemon gets extraction libraries transitively — it does not list them directly.

### daemon/main.py changes

The lifespan block constructs `SolidRagConfig` from Sol's loaded config and starts both `SourceWatcher` and `ResourceAwareScheduler`. No other structural change to the lifespan pattern.

### New route: daemon/routes/uploads.py

**`POST /api/upload/file`** — multipart file upload from iOS.

Routing logic by extension:
- `.pdf` → write to `uploads/pdf/YY-DD-MM-HH-MM/<filename>` in vault via Obsidian REST API
- `.xlsx` → write to `uploads/excel/YY-DD-MM-HH-MM/<filename>` in vault
- `.docx`, `.doc` → run `DocxExtractor.extract()` immediately → write resulting markdown as a new `.md` note to vault root. Original not retained.

Returns `{"file_path": "..."}` — same response shape as the notes endpoint.

**`POST /api/upload/image`** — multipart image upload.

Accepts image data. Writes to Obsidian `attachments/` folder via Obsidian REST API using a deterministic filename generated by the caller (timestamp-based). Returns `{"embed": "![[filename.jpg]]"}`.

### SourceWatcher

Watches `*.md`, `*.pdf`, `*.xlsx` in configured source dirs. Triggers incremental reindex on change. Images (`*.jpg`, `*.png`, etc.) are explicitly excluded — they are handled by `ResourceAwareScheduler` only, never by SourceWatcher.

---

## 3. iOS changes

### 3a — Image attachment in the note composer

`NoteComposerView` (shared by text and voice modes) gains a photo button in its composer toolbar.

**Trigger:** Tapping the photo button presents an action sheet with two options: "Photo Library" (`PhotosPicker`) or "Camera" (`UIImagePickerController`). Multiple images are supported per note.

**Optimistic upload flow:**

1. User selects image
2. App generates deterministic filename immediately: `<ISO8601-timestamp>-img.jpg`
3. App inserts `![[<filename>]]` embed string into note body immediately — user can continue writing around it
4. Background upload starts to `POST /api/upload/image` with that exact filename
5. Thumbnail strip above composer shows upload progress (spinner → checkmark on success, error indicator on failure)
6. On failure: tapping the error thumbnail retries the upload. The embed string in the note body is not removed automatically — the user controls whether to discard it.

**UI:** A horizontally scrollable thumbnail strip sits above the compose area. Each thumbnail has an ✕ button to remove the image (which also cancels a pending upload and removes the embed from the note body).

### 3b — Standalone file upload

A new `.upload` case is added to the `CaptureMode` enum.

**ModePopup:** Gains a fourth entry: "Upload File" (icon: `arrow.up.doc.fill`). Position: above the existing three entries, consistent with the existing popup layout.

**Capture bar behaviour in `.upload` mode:**
- Middle section: "Choose a file to upload…" (non-interactive label)
- Right button: tapping opens `fileImporter` with allowed content types: PDF, Excel, Word/docx

**Upload flow:**
1. User selects file via system file picker (Files app — includes iCloud Drive, local storage, Google Drive if app installed)
2. App reads file via security-scoped resource access
3. Sends `POST /api/upload/file` (multipart)
4. Brief toast: "Saved to vault" — no blocking UI

### New service: UploadService.swift

Lives alongside `APIClient.swift`. Owns both upload endpoints:

```swift
func uploadImage(_ data: Data, filename: String) async throws -> String  // returns embed string
func uploadFile(at url: URL) async throws                                 // fire-and-forget
```

`APIClient.swift` is not modified.

---

## 4. Data flows

### Standalone file upload (PDF example)

```
iOS: user picks report.pdf
  → UploadService.uploadFile(at: url)
  → POST /api/upload/file (multipart)
Daemon: inspect extension → .pdf
  → write to uploads/pdf/26-13-06-14-30/report.pdf via Obsidian REST API
  → return {"file_path": "uploads/pdf/26-13-06-14-30/report.pdf"}
SourceWatcher: detects new file → triggers incremental reindex
  → PDFExtractor.extract(path) → TextNodes
  → insert into FAISS index, update manifest
iOS: toast "Saved to vault"
```

### Image attachment to note

```
iOS: user picks photo in NoteComposerView
  → generate filename: "2026-06-13-143201-img.jpg"
  → insert "![[2026-06-13-143201-img.jpg]]" into note body immediately
  → start background: UploadService.uploadImage(data, filename)
  → POST /api/upload/image
Daemon: write to attachments/2026-06-13-143201-img.jpg via Obsidian REST API
  → return {"embed": "![[2026-06-13-143201-img.jpg]]"}
iOS: thumbnail → checkmark
[later, in ResourceAwareScheduler batch]
Daemon: llava processes attachments/2026-06-13-143201-img.jpg
  → TextNode with image description
  → spliced into FAISS index, manifest updated
```

### Word/Google Doc upload

```
iOS: user picks document.docx
  → UploadService.uploadFile(at: url)
  → POST /api/upload/file (multipart)
Daemon: inspect extension → .docx
  → DocxExtractor.extract(path) → markdown text
  → write as "document.md" to vault root via Obsidian REST API
  → return {"file_path": "document.md"}
SourceWatcher: detects new .md file → incremental reindex
  → MarkdownExtractor.extract(path) → TextNodes
  → insert into FAISS index
iOS: toast "Saved to vault"
```

---

## 5. Vault directory structure

```
<vault>/
  attachments/          # Obsidian default — images land here
  uploads/
    pdf/
      YY-DD-MM-HH-MM/   # one subdir per upload event
        report.pdf
    excel/
      YY-DD-MM-HH-MM/
        budget.xlsx
  *.md                  # notes + docx conversions in root
```

---

## 6. Error handling

| Failure | Behaviour |
|---|---|
| Image upload fails | Thumbnail shows error indicator, embed string stays in note body, tap to retry |
| File upload fails | iOS shows error alert, user retries manually |
| DocxExtractor parse error | Daemon returns 422, iOS shows error alert, original file not written |
| llava batch fails for one image | Logged, image skipped, manifest not updated (will retry next batch) |
| SourceWatcher incremental reindex fails | Logged, full rebuild scheduled on next startup |
| Ollama not running during scheduler | Scheduler skips batch, logs warning, retries after backoff |

---

## 7. Out of scope

- Image orphan cleanup (unlinked attachments in vault)
- PDF/Excel preview in iOS app
- Editing or deleting uploaded files from iOS
- Google Drive OAuth integration (Group B — separate spec)
