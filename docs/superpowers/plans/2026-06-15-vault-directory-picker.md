# Vault Directory Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users route notes into any nested Obsidian vault folder from the iOS note composer. A collapsible folder picker panel (mirroring the tag section) fetches live directory structure from the daemon and persists recently used paths in UserDefaults.

**Architecture:** Daemon gains `folder` param on `POST /api/note` and a new `GET /api/vault/directories` endpoint reading from Obsidian's file list. iOS gains `FolderPickerSection.swift` (standalone view component) wired into `NoteComposerView`. `Note.swift` and `APIClient.swift` get minimal additions.

**Tech Stack:** Python (FastAPI, ObsidianClient), Swift 6, SwiftUI, `UserDefaults`

**GitHub issue:** #89
**Branch:** `feat/vault-directory-picker`
**PR target:** `main`

---

## Pre-flight

- [ ] Ensure main is up to date (merge previous PRs first):
```bash
git checkout main && git pull
git checkout -b feat/vault-directory-picker
```

---

## Task 1: `ObsidianClient.list_directories()` — test first

**Files:**
- Modify: `daemon/obsidian_client.py`
- Modify: `daemon/tests/test_obsidian_client.py`

- [ ] **Step 1: Write failing test**

Open `daemon/tests/test_obsidian_client.py` and add at the bottom:

```python
import pytest
from unittest.mock import AsyncMock, MagicMock, patch


@pytest.mark.asyncio
async def test_list_directories_extracts_unique_parents():
    from daemon.obsidian_client import ObsidianClient

    client = ObsidianClient(
        base_url="http://localhost:27124",
        api_key="testkey",
    )

    mock_resp = MagicMock()
    mock_resp.is_success = True
    mock_resp.json.return_value = {
        "files": [
            "Notes/hello.md",
            "ideas/ai/note1.md",
            "ideas/startup.md",
            "reminders/daily.md",
            "root-file.md",          # no parent dir — skip
        ]
    }

    with patch.object(client._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        dirs = await client.list_directories()

    assert "Notes" in dirs
    assert "ideas" in dirs
    assert "ideas/ai" in dirs
    assert "reminders" in dirs
    assert "root-file.md" not in dirs
    assert dirs == sorted(dirs)  # must be sorted


@pytest.mark.asyncio
async def test_list_directories_returns_empty_on_error():
    from daemon.obsidian_client import ObsidianClient

    client = ObsidianClient(base_url="http://localhost:27124", api_key="testkey")

    with patch.object(client._client, "get", new_callable=AsyncMock, side_effect=Exception("network")):
        dirs = await client.list_directories()

    assert dirs == []
```

- [ ] **Step 2: Run — expect AttributeError (method doesn't exist)**

```bash
cd /Users/aakashranga/IN/Sol
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/test_obsidian_client.py -v -k "list_directories"
```

Expected: `AttributeError: 'ObsidianClient' object has no attribute 'list_directories'`

- [ ] **Step 3: Add `list_directories` to `ObsidianClient`**

In `daemon/obsidian_client.py`, add after `note_count()`:

```python
async def list_directories(self) -> list[str]:
    """GET /vault/ — return sorted unique directory paths derived from file list."""
    try:
        resp = await self._client.get("/vault/")
        if not resp.is_success:
            return []
        files = resp.json().get("files", [])
        dirs: set[str] = set()
        for f in files:
            parts = str(f).split("/")
            # Only emit ancestor paths (not the filename itself)
            for i in range(1, len(parts)):
                dirs.add("/".join(parts[:i]))
        return sorted(dirs)
    except Exception:
        return []
```

- [ ] **Step 4: Run — expect pass**

```bash
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/test_obsidian_client.py -v -k "list_directories"
```

Expected: `2 passed`

- [ ] **Step 5: Commit**

```bash
git add daemon/obsidian_client.py daemon/tests/test_obsidian_client.py
git commit -m "feat: add ObsidianClient.list_directories() with tests"
```

---

## Task 2: `GET /api/vault/directories` route — test first

**Files:**
- Modify: `daemon/routes/notes.py`
- Modify: `daemon/tests/test_notes.py`

- [ ] **Step 1: Write failing test**

Add to `daemon/tests/test_notes.py` (after existing tests):

```python
def test_list_vault_directories_returns_sorted_list(client):
    from daemon.main import app
    obsidian = app.state.obsidian
    obsidian.list_directories = AsyncMock(return_value=["ideas", "ideas/ai", "Notes", "reminders"])

    resp = client.get("/api/vault/directories", headers={"X-API-Key": "testkey123"})

    assert resp.status_code == 200
    data = resp.json()
    assert "directories" in data
    assert data["directories"] == ["ideas", "ideas/ai", "Notes", "reminders"]


def test_list_vault_directories_requires_api_key(client):
    resp = client.get("/api/vault/directories")
    assert resp.status_code == 401


def test_list_vault_directories_returns_empty_on_obsidian_error(client):
    from daemon.main import app
    obsidian = app.state.obsidian
    obsidian.list_directories = AsyncMock(return_value=[])

    resp = client.get("/api/vault/directories", headers={"X-API-Key": "testkey123"})
    assert resp.status_code == 200
    assert resp.json() == {"directories": []}
```

- [ ] **Step 2: Run — expect 404 (route not defined)**

```bash
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/test_notes.py -v -k "directories"
```

Expected: `assert resp.status_code == 200` fails with `404`.

- [ ] **Step 3: Add route to `daemon/routes/notes.py`**

Add after the `create_note` route (keep it in the same router file since it's vault-related):

```python
@router.get("/api/vault/directories")
async def list_vault_directories(request: Request):
    """Return sorted unique directory paths from the Obsidian vault."""
    obsidian = request.app.state.obsidian
    directories = await obsidian.list_directories()
    return {"directories": directories}
```

- [ ] **Step 4: Run — expect pass**

```bash
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/test_notes.py -v -k "directories"
```

Expected: `3 passed`

- [ ] **Step 5: Run full daemon test suite to check no regressions**

```bash
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/ -v
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add daemon/routes/notes.py daemon/tests/test_notes.py
git commit -m "feat: add GET /api/vault/directories endpoint with tests"
```

---

## Task 3: `folder` param on `POST /api/note` — test first

**Files:**
- Modify: `daemon/routes/notes.py`
- Modify: `daemon/obsidian_client.py`
- Modify: `daemon/tests/test_notes.py`

- [ ] **Step 1: Write failing tests**

Add to `daemon/tests/test_notes.py`:

```python
def test_create_note_with_custom_folder(client):
    from daemon.main import app
    obsidian = app.state.obsidian
    obsidian.create_note = AsyncMock(return_value="ideas/ai/My Note.md")

    resp = client.post(
        "/api/note",
        json={"content": "AI thought", "source": "text", "title": "My Note", "folder": "ideas/ai"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 201
    # Verify obsidian client was called with the folder
    call_kwargs = obsidian.create_note.call_args
    assert call_kwargs.kwargs.get("folder") == "ideas/ai" or (
        len(call_kwargs.args) >= 3 and call_kwargs.args[2] == "ideas/ai"
    )


def test_create_note_defaults_to_notes_folder(client):
    from daemon.main import app
    obsidian = app.state.obsidian
    obsidian.create_note = AsyncMock(return_value="Notes/2026-06-15T10-00-00-text.md")

    resp = client.post(
        "/api/note",
        json={"content": "Default folder", "source": "text"},
        headers={"X-API-Key": "testkey123"},
    )
    assert resp.status_code == 201
    call_kwargs = obsidian.create_note.call_args
    folder_arg = call_kwargs.kwargs.get("folder") or (
        call_kwargs.args[2] if len(call_kwargs.args) >= 3 else "Notes"
    )
    assert folder_arg == "Notes"
```

- [ ] **Step 2: Run — expect failure**

```bash
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/test_notes.py -v -k "folder"
```

Expected: `AssertionError` on folder kwarg check (field doesn't exist yet).

- [ ] **Step 3: Add `folder` to `NoteRequest` in `daemon/routes/notes.py`**

In `NoteRequest`, add the optional `folder` field:

```python
class NoteRequest(BaseModel):
    content: str
    title: Optional[str] = None
    tags: Optional[List[str]] = None
    source: Literal["voice", "text"]
    folder: Optional[str] = "Notes"

    @field_validator("content")
    @classmethod
    def content_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("content cannot be empty")
        return v
```

- [ ] **Step 4: Pass `folder` to `obsidian.create_note` in `create_note` route**

In the `create_note` route handler, change:
```python
file_path = await obsidian.create_note(filename, note_content)
```
to:
```python
folder = body.folder or "Notes"
file_path = await obsidian.create_note(filename, note_content, folder=folder)
```

- [ ] **Step 5: Update `ObsidianClient.create_note` signature**

In `daemon/obsidian_client.py`, change:
```python
async def create_note(self, filename: str, content: str) -> str:
    """PUT /vault/Notes/<filename> — returns the file path."""
    resp = await self._client.put(
        f"/vault/Notes/{filename}",
        content=content.encode(),
        headers={"Content-Type": "text/markdown"},
    )
    if not resp.is_success:
        raise ObsidianError(resp.text, resp.status_code)
    return f"Notes/{filename}"
```
to:
```python
async def create_note(self, filename: str, content: str, folder: str = "Notes") -> str:
    """PUT /vault/{folder}/{filename} — returns the file path."""
    vault_path = f"{folder}/{filename}"
    resp = await self._client.put(
        f"/vault/{vault_path}",
        content=content.encode(),
        headers={"Content-Type": "text/markdown"},
    )
    if not resp.is_success:
        raise ObsidianError(resp.text, resp.status_code)
    return vault_path
```

- [ ] **Step 6: Run all daemon tests**

```bash
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/ -v
```

Expected: all pass (including the two new folder tests and all pre-existing note tests).

- [ ] **Step 7: Commit**

```bash
git add daemon/routes/notes.py daemon/obsidian_client.py daemon/tests/test_notes.py
git commit -m "feat: add folder param to POST /api/note, update ObsidianClient"
```

---

## Task 4: iOS model + APIClient updates

**Files:**
- Modify: `ios/Sol/Models/Note.swift`
- Modify: `ios/Sol/Services/APIClient.swift`

- [ ] **Step 1: Add `folder` to `NoteRequest` in `Note.swift`**

Change `ios/Sol/Models/Note.swift`:

```swift
import Foundation

enum NoteSource: String, Codable {
    case voice, text
}

struct NoteRequest: Codable {
    let content: String
    let title: String?
    let tags: [String]?
    let source: NoteSource
    let folder: String?
}

struct NoteResponse: Codable {
    let filePath: String

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }
}
```

- [ ] **Step 2: Add `fetchDirectories()` to `APIClient.swift`**

In `ios/Sol/Services/APIClient.swift`, add after `fetchTags()`:

```swift
func fetchDirectories() async throws -> [String] {
    let req = try makeRequest("/api/vault/directories")
    let (data, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw SolAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    struct Resp: Decodable { let directories: [String] }
    do {
        return try JSONDecoder().decode(Resp.self, from: data).directories
    } catch {
        throw SolAPIError.decodingError(error)
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
cd /Users/aakashranga/IN/Sol/ios && xcodegen generate
xcodebuild build \
  -project Sol.xcodeproj -scheme Sol \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/Sol/Models/Note.swift ios/Sol/Services/APIClient.swift
git commit -m "feat: add folder to NoteRequest model and fetchDirectories to APIClient"
```

---

## Task 5: `FolderPickerSection.swift`

**Files:**
- Create: `ios/Sol/Views/FolderPickerSection.swift`

- [ ] **Step 1: Create `FolderPickerSection.swift`**

```swift
import SwiftUI

private let recentFoldersKey = "sol.recentFolders"
private let maxRecents = 10

struct FolderPickerSection: View {
    @Binding var selectedFolder: String?

    @State private var isExpanded = false
    @State private var searchText = ""
    @State private var fetchedDirectories: [String] = []
    @State private var isFetching = false
    @FocusState private var fieldFocused: Bool

    private let client = APIClient.shared

    // Merged + deduplicated suggestions filtered by search text
    private var suggestions: [String] {
        let recents = (UserDefaults.standard.array(forKey: recentFoldersKey) as? [String]) ?? []
        var all = Array(OrderedSet(recents + fetchedDirectories))
        if !searchText.isEmpty {
            all = all.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
        return all
    }

    // True when typed text is a novel path not in suggestions
    private var canCreate: Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !suggestions.contains(where: { $0.lowercased() == trimmed.lowercased() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            // ── Collapsed / chip row ──────────────────────────────────────────
            HStack(spacing: 0) {
                Button {
                    isExpanded.toggle()
                    if isExpanded {
                        fieldFocused = true
                        Task { await fetchDirectories() }
                    } else {
                        searchText = ""
                        fieldFocused = false
                    }
                } label: {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(isExpanded ? DS.terracotta : DS.inkFaint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let folder = selectedFolder {
                    // Chip
                    HStack(spacing: 4) {
                        Text(folder)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.terracottaDark)
                        Button {
                            selectedFolder = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(DS.inkLight)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(DS.terracotta.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.terracotta.opacity(0.22), lineWidth: 1))
                } else if !isExpanded {
                    Text("Add to folder…")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.inkFaint)
                }
            }
            .frame(height: 44)

            // ── Expanded search + suggestions ─────────────────────────────────
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()

                    // Search field
                    HStack(spacing: 10) {
                        Image(systemName: isFetching ? "arrow.clockwise" : "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.inkFaint)
                        TextField("Search or type a path…", text: $searchText)
                            .font(.system(size: 15))
                            .foregroundStyle(DS.inkDark)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                if canCreate {
                                    selectFolder(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                                } else if let first = suggestions.first {
                                    selectFolder(first)
                                }
                            }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(DS.inkFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)

                    Divider()

                    // Suggestions list
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // Create new path row
                            if canCreate {
                                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                folderRow(
                                    label: "Create \"\(trimmed)\"",
                                    icon: "plus.circle.fill",
                                    tinted: true,
                                    indent: 0
                                ) { selectFolder(trimmed) }
                                Divider()
                            }

                            // Existing paths
                            ForEach(suggestions, id: \.self) { path in
                                let depth = path.components(separatedBy: "/").count - 1
                                folderRow(
                                    label: path,
                                    icon: "folder",
                                    tinted: false,
                                    indent: depth
                                ) { selectFolder(path) }
                                Divider()
                            }

                            if suggestions.isEmpty && !canCreate && !isFetching {
                                Text("No folders yet — type a path to create one")
                                    .font(.system(size: 14))
                                    .foregroundStyle(DS.inkFaint)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }

    // MARK: Row builder

    private func folderRow(
        label: String,
        icon: String,
        tinted: Bool,
        indent: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if indent > 0 {
                    Spacer().frame(width: CGFloat(indent) * 14)
                }
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tinted ? DS.terracotta : DS.inkFaint)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(tinted ? DS.terracotta : DS.inkDark)
                Spacer()
                if selectedFolder == label {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.terracotta)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func selectFolder(_ path: String) {
        selectedFolder = path
        isExpanded = false
        searchText = ""
        fieldFocused = false
        saveToRecents(path)
    }

    private func saveToRecents(_ path: String) {
        var recents = (UserDefaults.standard.array(forKey: recentFoldersKey) as? [String]) ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > maxRecents { recents = Array(recents.prefix(maxRecents)) }
        UserDefaults.standard.set(recents, forKey: recentFoldersKey)
    }

    private func fetchDirectories() async {
        isFetching = true
        defer { isFetching = false }
        if let dirs = try? await client.fetchDirectories() {
            fetchedDirectories = dirs
        }
    }
}

// Minimal ordered-set helper to keep insertion order from recents + deduplicate
private struct OrderedSet<T: Hashable>: Sequence {
    private var array: [T] = []
    private var set: Set<T> = []

    init(_ elements: some Sequence<T>) {
        for e in elements where set.insert(e).inserted { array.append(e) }
    }

    func makeIterator() -> Array<T>.Iterator { array.makeIterator() }
}
```

- [ ] **Step 2: Build and verify**

```bash
cd /Users/aakashranga/IN/Sol/ios && xcodegen generate
xcodebuild build \
  -project Sol.xcodeproj -scheme Sol \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/Sol/Views/FolderPickerSection.swift
git commit -m "feat: add FolderPickerSection with live daemon suggestions and UserDefaults recents"
```

---

## Task 6: Wire into `NoteComposerView` + update note submission

**Files:**
- Modify: `ios/Sol/Views/NoteComposerView.swift`

- [ ] **Step 1: Add `selectedFolder` state to `NoteComposerView`**

Find the `@State` declarations at the top of `NoteComposerView` (around line 17) and add:

```swift
@State private var selectedFolder: String? = nil
```

- [ ] **Step 2: Add `folderSection` computed property**

Add after the closing brace of `tagSection`:

```swift
// ── Folder section ────────────────────────────────────────────────────
private var folderSection: some View {
    FolderPickerSection(selectedFolder: $selectedFolder)
}
```

- [ ] **Step 3: Add `folderSection` to the view body**

Find where `tagSection` is placed in the body (look for `tagSection` in the VStack). Add `folderSection` immediately after it:

```swift
tagSection
folderSection
```

- [ ] **Step 4: Pass `folder` when submitting the note**

Find where `NoteRequest` is constructed in `NoteComposerView` (look for `NoteRequest(`). Update it to include the folder:

```swift
let noteRequest = NoteRequest(
    content: finalContent,
    title: title.isEmpty ? nil : title,
    tags: selectedTags.isEmpty ? nil : selectedTags,
    source: mode == .voice ? .voice : .text,
    folder: selectedFolder
)
```

- [ ] **Step 5: Update `UserDefaults` on successful save**

After the successful note submission (where a success toast or dismissal fires), add:

```swift
// selectedFolder is already saved to recents inside FolderPickerSection.selectFolder()
// No extra action needed here.
```

(The `saveToRecents` call happens inside `FolderPickerSection` when the user selects a path, so it's already handled.)

- [ ] **Step 6: Build and verify**

```bash
cd /Users/aakashranga/IN/Sol/ios && xcodegen generate
xcodebuild build \
  -project Sol.xcodeproj -scheme Sol \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Run all tests**

```bash
# Daemon tests
cd /Users/aakashranga/IN/Sol
PYTHONPATH=. ~/.sol/venv/bin/python -m pytest daemon/tests/ -v

# iOS tests
cd ios
xcodebuild test \
  -project Sol.xcodeproj -scheme SolTests \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test Suite|passed|failed"
```

Expected: all pass.

- [ ] **Step 8: Install updated daemon and restart**

```bash
~/.sol/venv/bin/pip install -e /Users/aakashranga/IN/Sol/packages/solidrag/.
sol restart
curl -s -H "X-API-Key: $(python3 -c "import json; print(json.load(open('/Users/aakashranga/.sol/config.json'))['daemon_api_key'])")" \
  http://localhost:8765/api/vault/directories
```

Expected: JSON response with `{"directories": [...]}` listing your vault's folder structure.

- [ ] **Step 9: Commit and push**

```bash
git add ios/Sol/Views/NoteComposerView.swift
git commit -m "feat: wire FolderPickerSection into NoteComposerView, pass folder on submit"
git push -u origin feat/vault-directory-picker
```

---

## Task 7: Open PR

- [ ] **Step 1: Create PR**

```bash
gh pr create \
  --title "feat: iOS vault directory picker in NoteComposerView" \
  --base main \
  --body "$(cat <<'EOF'
## Summary
- New collapsible folder picker panel in note composer (below tags, same design pattern)
- Live directory list from new `GET /api/vault/directories` daemon endpoint
- Recently used folders persisted in UserDefaults (up to 10)
- Supports nested paths (e.g. `ideas/ai`); type any path to create it
- `POST /api/note` now accepts optional `folder` param (defaults to `Notes`)
- Obsidian creates intermediate directories automatically on write

## Test plan
- [ ] All daemon pytest tests pass
- [ ] iOS simulator build passes
- [ ] Create a note with folder `ideas/ai` → appears at that path in Obsidian
- [ ] No folder selected → note lands in `Notes/` as before
- [ ] Folder used last session appears in recents dropdown
- [ ] CI daemon-tests, ios-build, ios-tests all pass

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Verify CI passes, then merge**

```bash
gh pr checks --watch
gh pr merge --squash
git checkout main && git pull
```
