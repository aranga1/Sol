# Obsidian Graph View & Daemon-Assisted Relationship Building

_Report date: 2026-06-15_

---

## Part A — How Obsidian's Graph View Works

### What creates edges

Obsidian's graph is a **link graph**, not a semantic graph. An edge between Note A and Note B exists if and only if:

1. **`[[wikilink]]` in note body** — `[[Note B]]` in Note A's content creates a directed edge A → B. This is the primary mechanism and the one Obsidian was designed around.
2. **`[[wikilink]]` in frontmatter** — links in YAML frontmatter (e.g. `related: [[Note B]]`) also create edges.
3. **Unresolved links** — `[[Note that doesn't exist yet]]` still renders as a node (grey dot) with an edge. Obsidian tracks links to non-existent files.

**What does NOT create edges:**
- Shared tags — tags group notes visually (you can filter by tag in the graph) but do not draw edges between notes that share a tag.
- Folder co-location — two notes in `ideas/ai/` have no graph relationship unless they link to each other.
- Keyword overlap — no amount of shared vocabulary creates an edge. This is the core reason Sol's graph is sparse: the iOS app creates notes but never writes `[[wikilinks]]` between them.
- YAML `tags:` frontmatter — same as above, tags filter, they don't connect.

### Global graph vs. local graph

| | Global graph | Local graph |
|---|---|---|
| Scope | All notes in the vault | Notes within N hops of the currently open note |
| Access | Left sidebar icon or Ctrl+G | "Open local graph" in note toolbar |
| Use | See vault topology | Explore a note's neighbourhood |

The global graph is what the user sees when they open Graph View. With Sol's current notes (no wikilinks), it shows isolated dots — every note is an orphan.

### Backlinks

A **backlink** is a reverse reference: if Note A contains `[[Note B]]`, then Note B has a backlink from Note A. Obsidian shows backlinks in the right sidebar under "Backlinks." High-backlink notes become visual hubs in the graph (larger dot, many edges). Without any `[[wikilinks]]`, there are zero backlinks in the entire vault.

### Orphan notes

An orphan note has no incoming or outgoing wikilinks — it appears as a disconnected dot in the graph. In a typical manually-maintained Obsidian vault, 20–40% of notes are orphans (Obsidian Forum data, community surveys 2022–2024). In Sol's vault, where all notes are created programmatically by the iOS app without wikilink insertion, **nearly 100% of notes are orphans** by construction. The graph view is essentially useless until links are added.

---

## Part B — Daemon-Assisted Relationship Builder

### The core problem

Sol's notes never contain `[[wikilinks]]` because the iOS app creates standalone notes. The only way to get edges in the graph is to post-process notes and insert `[[wikilink]]` references. This is safe because Obsidian treats a `## Related` section at the bottom of a note as canonical link source — it shows in backlinks and the graph.

### Approach options

#### Option 1 — NLP entity extraction (spaCy/NLTK)
Extract named entities (people, places, organisations, concepts) from each note. Notes sharing ≥1 named entity get linked.

- **Pros:** Fast, deterministic, no LLM calls, works offline
- **Cons:** spaCy model (~40MB) is a new dependency; entity matching is brittle (fails on personal names, project codenames, domain-specific terms not in the model); produces false positives ("Apple" the company vs. "apple" the fruit)
- **Quality:** Low-medium. Good for proper nouns, poor for conceptual relationships ("this note about productivity habits relates to this note about morning routines")

#### Option 2 — LLM-based (Ollama, already running)
For each unlinked note, send its content + a list of candidate note titles to the LLM. Ask: "Which of these notes is this note meaningfully related to?"

- **Pros:** Highest quality; understands semantic relationships, personal context, implicit connections; uses infrastructure already in place
- **Cons:** Slow (one LLM call per note × number of notes = expensive on first run); requires the Ollama model to be available; non-deterministic
- **Quality:** High — but only if the model context is large enough to hold candidate titles. With 768-dim embeddings and Qwen2.5:3b, context is ~4k tokens; you'd need to pre-filter candidates before sending to LLM.

#### Option 3 — FAISS similarity threshold (recommended starting point)
Sol already has a 768-dim `IndexFlatL2` FAISS index over all notes. For each note, run `faiss_index.search(note_vector, k=10)` and link notes where L2 distance is below a threshold.

- **Pros:** Zero new dependencies; uses the existing index that's already built and maintained; fast (milliseconds per note); fully offline; consistent with how Sol already does retrieval
- **Cons:** L2 distance doesn't map intuitively to "meaningful relationship"; threshold tuning required; may miss conceptual links that aren't lexically similar
- **Quality:** Medium-high for notes on related topics; lower for notes where the relationship is thematic rather than textual

#### Option 4 — Hybrid: FAISS pre-filters, LLM confirms (best long-term option)
FAISS finds top-10 candidates per note in milliseconds. LLM (single call per note with 10 candidates) decides which to actually link. LLM context is tiny (one note + 10 candidate titles + snippets).

- **Pros:** Best quality at manageable cost; LLM only runs on a small candidate set; dramatically cheaper than Option 2 naive approach
- **Cons:** Still requires LLM calls; first-run cost scales linearly with vault size; LLM must be running (ResourceAwareScheduler already handles this)

### Implementation sketch

**Where it lives:**
- New module: `solidrag/index/linker.py` — `RelationshipLinker` class
- New daemon route: `POST /api/link-notes` — trigger on-demand
- Integrated into `ResourceAwareScheduler` — runs after a full re-index, respects CPU/battery guards

**What it modifies:**
Each note gets a `## Related` section appended (or updated if already present):
```markdown
## Related
- [[ideas/ai/transformer-architectures]]
- [[notes/2026-05-12-llm-context-windows]]
```
The section is always at the end of the file, always under the exact heading `## Related`, so it can be idempotently rewritten on subsequent runs.

**How often:**
- Triggered after `build_index()` completes (i.e., whenever the watcher detects new/modified files)
- Minimum interval: 30 minutes (same as scheduler backoff)
- Only processes notes modified since the last linker run (tracked via a `linker_manifest.json` similar to `IndexManifest`)

**Noise avoidance:**
- Minimum candidate count: only link if ≥2 meaningful candidates found (avoids weak single-link connections)
- L2 distance cap: empirically, L2 < 0.4 on 768-dim normalised vectors corresponds to strong topical similarity with `nomic-embed-text` or similar models; tune per-vault
- Maximum links per note: cap at 5 to avoid spammy `## Related` sections
- Self-exclusion: a note never links to itself
- Minimum note length: notes under ~100 words excluded (too little signal)

### Risks

1. **Unintended edits to user notes.** The linker modifies vault files. If a user is mid-edit in Obsidian when the linker runs, Obsidian will detect an external change and show a "file modified externally" prompt. Mitigation: use Obsidian's Local REST API (`PUT /vault/{path}`) rather than direct filesystem writes — the REST API is Obsidian-aware and handles this more gracefully. Alternatively, use a lock file and skip notes currently open in Obsidian.

2. **LLM cost at scale.** A vault with 500 notes using Option 2 naively = 500 LLM calls on first run. At ~3s per call = 25 minutes blocking. Mitigation: run in background (already the plan), process incrementally (only new/modified notes), use FAISS pre-filtering to keep LLM input tiny.

3. **Vault watcher interference.** `SourceWatcher` watches for `.md` file changes to trigger re-indexing. If the linker writes to note files, it triggers the watcher, which triggers re-indexing, which triggers the linker again — an infinite loop. Mitigation: linker writes must be excluded from watcher triggers. Either use a separate file flag (`linker_modifying = True`) that watcher checks before re-indexing, or track which files were modified by the linker and skip them in the next watcher cycle.

4. **False positives degrading vault quality.** A spurious `[[wikilink]]` in `## Related` is more visible and permanent than a bad retrieval result. Users may not notice or bother removing them. Mitigation: conservative threshold on first rollout; add a `sol unlink-notes` CLI command for manual cleanup.

### Recommendation

**Start with Option 3 (FAISS threshold alone).** Reasons:
- Zero new dependencies — uses the index Sol already builds and maintains
- Implementation is ~50 lines: iterate nodestore, search FAISS, write `## Related` if results below threshold
- Results are immediately visible in Obsidian's graph view (transforms orphan dots into a connected graph)
- Provides a baseline to evaluate quality before adding LLM confirmation overhead

Once the linker is live and you can visually inspect the graph quality, add Option 4 (LLM confirmation) as a second pass for high-value notes (long notes, frequently queried notes, notes with many FAISS candidates).

The L2 threshold for `IndexFlatL2` at 768 dimensions requires empirical tuning. Suggested starting point: link if L2 distance < 50.0 (unnormalised), which corresponds roughly to notes discussing the same subject area. Run `sol status` equivalent on the linker to report how many links were added and manually inspect a sample of 10–20 linked pairs before enabling it vault-wide.
