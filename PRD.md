# Sol — Product Requirements Document

**Version:** 1.1  
**Date:** 2026-06-11  
**Author:** Aakash Ranga

---

## 1. Problem Statement

Ideas and thoughts are scattered across multiple apps (Apple Notes, Notion, email, voice memos) with no single place to query, connect, or revisit them. Existing "second brain" tools either require cloud infrastructure (privacy/cost concerns), lack fast mobile capture, or don't support natural-language querying of personal notes.

**Who it's for:** A single user (personal tool, not commercial) who wants a unified, private knowledge vault accessible from their iPhone at any time — for both quick capture and retrospective querying.

---

## 2. Success Metrics

| Metric | Target |
|--------|--------|
| Time from thought to saved note (voice) | < 15 seconds end-to-end |
| Time from thought to saved note (text) | < 10 seconds end-to-end |
| Query response time (Q&A over vault) | < 10 seconds for answer + sources |
| Daemon uptime after MacBook reboot | Auto-restarts, reachable within 60 seconds |
| Voice transcription accuracy | Comparable to Apple Dictation on clear speech |
| Setup time (fresh macOS install to working system) | < 30 minutes including model download |
| iOS app installable without App Store or Xcode connection | Yes (GitHub Releases OTA) |

---

## 3. Functional Requirements

### 3.1 Setup & Installation

**US-01 — Automated macOS setup**
> As a user, I want to run a single shell script that installs and configures everything, so I don't need to manually configure tools.

**Acceptance Criteria:**
- `install.sh` runs on macOS 13+ without requiring any pre-installed tools beyond a network connection
- Installs: Homebrew (if missing), Obsidian, Tailscale, Ollama, Python 3.12
- Pulls `phi3.5` Ollama model with visible progress
- Creates the Obsidian vault at the iCloud-synced path
- Writes all config files with generated API keys
- Installs the daemon as a launchd service (auto-start on login, auto-restart on crash)
- The only manual steps are: (a) Tailscale auth key paste or browser sign-in, (b) enabling the Local REST API plugin in Obsidian

**US-02 — Tailscale connectivity setup**
> As a user, I want Tailscale to be configured by the install script so my phone can reach my Mac from anywhere.

**Acceptance Criteria:**
- Script accepts a pre-auth key via prompt to fully skip browser flow
- Falls back to `tailscale up` browser flow if no key is provided
- After auth, script captures `tailscale ip -4` automatically
- Tailscale IP is encoded in the QR code

**US-03 — QR code handshake**
> As a first-time user, I want the install script to produce a QR code containing my Mac's connection info so I can connect the iPhone app without typing anything.

**Acceptance Criteria:**
- QR code encodes JSON: `{"host": "<tailscale-ip>", "port": 8765, "apiKey": "<daemon-key>"}`
- QR is printed as ASCII art in the terminal
- QR is also saved as `~/.sol/sol-connect.png`
- Scanning the QR in the Sol iOS app completes the connection setup

---

### 3.2 Backend Daemon

**US-04 — Note submission**
> As a user, I want notes sent from my iPhone to appear as markdown files in my Obsidian vault.

**Acceptance Criteria:**
- `POST /api/note` accepts `{content: string, title?: string, tags?: string[], source: "voice" | "text"}`
- Filename format: `YYYY-MM-DDTHH-MM-SS-<source>.md` (e.g. `2026-06-11T14-32-05-voice.md`)  
  Timestamp is ISO 8601 in UTC with colons replaced by hyphens for filesystem compatibility; `source` is either `voice` or `text`
- Creates the file in `Vault/Notes/` with YAML frontmatter containing `tags`, `created`, and `source`
- Returns `{file_path: string}` on success
- Requires valid `X-API-Key` header; returns 401 otherwise
- Timestamp-based names make collisions effectively impossible; no deduplication logic needed

**US-05 — Vault health check**
> As a user, I want the iOS app to show whether the daemon is reachable.

**Acceptance Criteria:**
- `GET /api/health` returns `{status: "ok", vault_note_count: number}` within 1 second
- No auth required (allows the app to probe without credentials)
- Returns 503 if Obsidian REST API is unreachable

**US-06 — Natural language Q&A over vault**
> As a user, I want to ask questions about my notes and get answers that cite the specific notes used.

**Acceptance Criteria:**
- `POST /api/query` accepts `{question: string}`
- Returns `{answer: string, sources: [{file: string, title: string}]}`
- Answer is synthesized from the top-3 most relevant note chunks
- Sources list is non-empty when relevant notes exist
- Returns a graceful "I don't have notes about that yet" when nothing relevant is found
- Requires valid `X-API-Key` header

**US-07 — Vault indexing**
> As a user, I want the Q&A to reflect my latest notes without manual re-indexing.

**Acceptance Criteria:**
- Vault is fully indexed on daemon startup
- Background thread polls vault directory mtime every 60 seconds; triggers a full re-index on any change
- Full re-index is intentional: vault is personal-use only, capped at ~10,000 files total, so incremental complexity is not warranted
- New notes are queryable within 2 minutes of being written to disk

---

### 3.3 iOS App — Sol

**US-08 — Onboarding via QR scan**
> As a first-time user, I want to connect the app to my Mac by scanning the QR code.

**Acceptance Criteria:**
- On first launch (no Keychain credentials), app shows full-screen QR scanner
- Scans QR, parses JSON, validates fields, stores in Keychain
- Navigates to HomeView on success
- Shows error + retry prompt if QR payload is invalid

**US-09 — Text note capture**
> As a user, I want to quickly type a note and send it to my vault.

**Acceptance Criteria:**
- Tapping the pencil button opens TextNoteView
- Large multiline text editor is focused automatically
- Optional title field above the text area
- "Send" button posts to `POST /api/note` with `source: "text"`
- Success: shows a brief toast notification and dismisses the view
- Failure: shows inline error with retry option; draft is preserved

**US-10 — Voice note capture**
> As a user, I want to record a voice note that is transcribed on-device and sent to my vault — with the ability to review and edit before sending.

**Acceptance Criteria:**
- Tapping the mic button opens VoiceNoteView
- Hold-to-record button starts/stops AVAudioRecorder at 44.1kHz mono
- On release, WhisperKit (`whisperkit-base-en`) transcribes audio on-device
- Transcription result appears in an editable text field — user can correct mistakes before sending
- Audio file is discarded after transcription; only the final (possibly edited) text is stored
- "Send" button posts the transcript to `POST /api/note` with `source: "voice"`
- Transcription completes within 5 seconds for a 30-second recording on iPhone 12+

**US-11 — WhisperKit model download**
> As a first-time user, I want the voice model to be downloaded automatically on first use.

**Acceptance Criteria:**
- On first open of VoiceNoteView, app checks for `whisperkit-base-en` in local cache
- If not present, shows a download progress screen (~147MB)
- Model is cached in the app's Documents directory and persists across launches
- Download proceeds over WiFi by default; user can allow cellular in app settings

**US-12 — Query interface**
> As a user, I want to ask questions about my notes from my iPhone and see which notes were used to answer.

**Acceptance Criteria:**
- Search/query bar on HomeView opens QueryView on submit
- QueryView shows the question at top, synthesized answer below, source list at bottom
- Each source row shows the note title and is tappable
- Tapping a source opens `obsidian://open?vault=Sol&file=<encoded_path>` (opens Obsidian iOS)
- Loading spinner shown while awaiting response
- Error state shown if request fails

**US-13 — Daemon reachability indicator**
> As a user, I want to know at a glance whether my Mac is reachable.

**Acceptance Criteria:**
- HomeView shows a status indicator (green dot = reachable, red = unreachable)
- App pings `GET /api/health` on foreground resume and every 30 seconds while active
- Status updates within 5 seconds of connectivity changing

**US-14 — Home screen widget**
> As a user, I want a home screen widget for instant access to voice or text capture.

**Acceptance Criteria:**
- Medium-size WidgetKit widget with two tappable areas: "Voice" and "Text"
- Tapping "Voice" deep-links to `sol://voice` (opens app directly in VoiceNoteView)
- Tapping "Text" deep-links to `sol://text` (opens app directly in TextNoteView)
- Widget contains no dynamic data and makes no network requests (pure launch shortcut)
- Widget is available for the user to add from the iOS widget gallery

---

### 3.4 Vault Sync (iCloud)

**US-15 — iCloud vault sync to Obsidian iOS**
> As a user, I want notes I send from the Sol app to also appear in Obsidian on my iPhone.

**Acceptance Criteria:**
- Vault is created at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Sol/` by the install script
- Obsidian iOS detects the vault via "Open vault from iCloud"
- Notes synced to iCloud appear in Obsidian iOS within ~30 seconds on WiFi
- Source note deep links from QueryView open the correct note in Obsidian iOS

---

### 3.5 GitHub Actions iOS Distribution

**US-16 — CI-built iOS distribution**
> As a developer/user, I want the iOS app to be buildable and distributable via GitHub Actions so I can install it on my phone from a GitHub Release without connecting to Xcode.

**Acceptance Criteria:**
- GitHub Actions workflow triggers on push to `main` and on `workflow_dispatch`
- Workflow builds, archives, and exports an ad-hoc signed IPA
- IPA, `manifest.plist`, and `install.html` are uploaded to GitHub Releases
- Opening `install.html` in iPhone Safari triggers `itms-services://` OTA install
- Required secrets: `APPLE_CERT_BASE64`, `APPLE_CERT_PASSWORD`, `APPLE_PROVISIONING_PROFILE`, `APPLE_TEAM_ID`
- Build succeeds without a connected device
- User will be walked through one-time secrets setup when Phase 7 begins

---

## 4. Non-Functional Requirements

### Privacy & Security
- All data stays on-device or on the user's own hardware; no third-party cloud services receive note content
- Tailscale P2P encrypted tunnel; daemon API key required for all write/query endpoints
- API key stored in iOS Keychain (not UserDefaults)
- Daemon config file (`~/.sol/config.json`) has mode 600 (owner-read-only)
- No analytics, crash reporting, or telemetry in the daemon or iOS app

### Performance
- Voice transcription (30s audio): < 5 seconds on iPhone 12+
- Note submission round-trip: < 3 seconds on home WiFi, < 6 seconds on LTE via Tailscale
- Q&A response: < 10 seconds for a vault of up to 10,000 notes
- Daemon cold start (after reboot): < 15 seconds to health endpoint responding

### Reliability
- Daemon auto-restarts via `launchd` `KeepAlive=true`
- iOS app preserves draft text if send fails (no data loss on error)
- Full vault re-index runs in a background thread and does not block note submission

### Compatibility
- macOS 13 Ventura or later
- iOS 17 or later
- iPhone 12 or newer (Neural Engine required for WhisperKit performance)
- Obsidian 1.5+
- Tailscale free tier (personal use, single device)

### Accessibility
- iOS app supports Dynamic Type (text scales with system font size setting)
- All interactive elements have accessibility labels for VoiceOver
- Voice note flow is fully usable without needing to read the transcription before sending

---

## 5. Technical Constraints

| Layer | Decision | Rationale |
|-------|----------|-----------|
| No cloud servers | All compute on user's MacBook | Core requirement |
| Connectivity | Tailscale P2P VPN | Only non-cloud option for remote access; pre-auth key enables full automation |
| Vault sync | iCloud (native Obsidian iOS support) | Free, zero-config, no paid Obsidian Sync subscription needed |
| Obsidian integration | Local REST API community plugin (port 27124) | Only stable programmatic interface to Obsidian |
| Daemon | Python 3.12 + FastAPI + uvicorn | Lightweight, async, well-supported LlamaIndex integration |
| LLM | Ollama `phi3.5` (3.8B) — switchable | Best RAG performance at small size; model choice will be revisited based on real-world performance testing; Ollama model name is a config value |
| RAG | LlamaIndex VectorStoreIndex + FAISS (local), full re-index | Simpler than incremental; vault is personal-use, ≤10,000 files |
| iOS voice-to-text | WhisperKit `whisperkit-base-en`; audio discarded post-transcription | On-device, Neural Engine, v1.0 production-ready; no audio stored |
| Filenames | `YYYY-MM-DDTHH-MM-SS-<source>.md` (UTC) | Timestamp-based avoids collisions; `source` tag (voice/text) aids vault browsing |
| iOS framework | SwiftUI + Swift 6 | Native performance, WidgetKit compatibility |
| iOS distribution | Ad-hoc IPA via GitHub Actions + GitHub Releases OTA | User has paid Apple Developer account |

---

## 6. Out of Scope (v1)

- **Source connectors** — Apple Notes, Notion, and email sync are explicitly deferred
- **Multi-user or multi-vault support** — single user, single vault only
- **Note editing in Sol iOS** — the app is capture-only; editing happens in Obsidian
- **Note browsing/search in Sol iOS** — browsing is deferred to Obsidian iOS via iCloud
- **Android app** — iOS only
- **Web interface** — no browser UI for the daemon
- **Obsidian plugin development** — uses existing community plugin; no custom plugin built
- **Streaming Q&A responses** — full response returned at once (no token streaming in v1)
- **Note deletion or editing via API** — append-only from the mobile app
- **Cloud backup of vault** — iCloud is the only sync mechanism; no additional backup
- **Audio file storage** — voice recordings are transcribed and discarded; only text is stored
- **Incremental vault indexing** — full re-index only (adequate for personal-scale vaults)

---

## 7. Open Questions

All questions from v1.0 have been resolved:

| # | Question | Resolution |
|---|----------|------------|
| Q1 | Filename scheme for notes | **Timestamp + source identifier** — `YYYY-MM-DDTHH-MM-SS-voice.md` / `...-text.md` |
| Q2 | Store voice audio alongside transcript? | **No** — transcript only; audio discarded after WhisperKit transcription |
| Q3 | LLM model choice / fallback for slow Macs | **phi3.5 for now** — model is a config value; user will evaluate performance and may switch |
| Q4 | Incremental vs full vault re-index | **Full re-index** — vault ≤10,000 files, personal use; simplicity wins |
| Q5 | GitHub Actions signing setup | **User will add secrets** — walk-through provided at Phase 7 start |

*No open questions remain. This PRD is ready for `/prd-to-tix`.*
