# GraphRAG, Ruflo, and LLM Routing — Research Report
*Generated 2026-06-15*

---

## Part A — GraphRAG: Ruflo's Approach vs Sol's Current RAG

### What Sol Does Today

Sol's retrieval is a flat vector pipeline:

1. **Embed** the user's question with Ollama (`nomic-embed-text` or similar)
2. **Search** a FAISS `IndexIDMap2` for the top-K nearest neighbours
3. **Fetch** content from `NodeStore` (a flat JSON map of node_id → text)
4. **Generate** via Ollama with the retrieved chunks as context

The intent router (`_needs_vault_async`) is a binary gate: the LLM classifies the question as "needs vault" or "direct answer." If vault is needed, all retrieved chunks are concatenated into a single flat context block and handed to the LLM.

**Structural gap:** each retrieved chunk is an island. Sol knows "chunk X scored 0.82" but has no idea that chunk X lives inside a document that is conceptually linked to chunk Y, or that both mention the same entity. Multi-hop questions ("what did I write about RAG *after* my WWDC notes?") fail because the vector index has no edges, only distances.

---

### What GraphRAG Is

GraphRAG augments vector search with a **property graph** layer. Instead of treating documents as bags of chunks, it:

1. **Extracts entities** (people, projects, concepts, dates, tools) and **relations** (A mentions B, A was created before B, A depends on B) from every chunk at index time
2. **Builds a knowledge graph** where nodes are entities and edges are named relations
3. **Detects communities** (clusters of densely connected nodes — e.g., all your AI reading notes form a community; your calendar events and project notes form another)
4. **Retrieves at query time** via two modes:
   - *Local search*: find entity matches, traverse the graph to their neighbours, pull the associated chunks — answers specific factual questions
   - *Global search*: summarise entire communities relevant to the query — answers broad "give me an overview" questions that flat RAG fails at entirely

The key win: a multi-hop question like "what are the themes connecting my WWDC notes and my AI reading list?" can be answered by following entity edges (both mention `transformer`, `attention`, `Apple`) rather than hoping those chunks happen to be semantically similar at the embedding level.

---

### How Ruflo Implements It

Ruflo provides GraphRAG across three layered plugins:

#### ruflo-knowledge-graph
- **Entity extraction**: extracts `class`, `function`, `module`, `concept`, `type`, `config` entities from source files and documentation. For Sol this would be concepts, tools, people, dates, project names from markdown notes.
- **Relation mapping**: builds typed causal edges (`imports`, `extends`, `depends-on`, `mentions`, `created-before`) stored in AgentDB's causal-edge table
- **Pathfinder traversal**: given a seed entity, expands outward by edge weight × semantic similarity, prunes paths below threshold 0.3, returns top-K paths. This is the "local search" equivalent.

#### ruflo-ruvector (Graph RAG via ruvector@0.2.25)
- Wraps a Rust-native HNSW index for sub-millisecond ANN search (150×–12,500× faster than brute force)
- Provides `hooks graph-cluster` for **spectral/Louvain graph clustering** — this is the community detection step
- **Hyperbolic projection** (Poincaré disk): embeds the graph in hyperbolic space, which better preserves hierarchical structure than flat Euclidean embeddings. Useful for note hierarchies (project → sub-task → daily log)
- **Adaptive LoRA embeddings**: domain-specific fine-tuning of the embedding model at the graph level without full retraining — the graph teaches the embedder what dimensions matter for your notes

#### ruflo-graph-intelligence
- **PageRank on the knowledge graph** to surface the most important entities in a community (not just the most recently edited)
- **Delta updates**: the graph is updated incrementally as documents change, not rebuilt from scratch
- **Complexity-aware execution** (ADR-123): routes simple queries to fast HNSW lookup, complex multi-hop queries to full graph traversal — analogous to Sol's `_needs_vault_async` gate but with a third path for graph traversal

#### ruflo-rag-memory (SmartRetrieval, ADR-090)
- 5-phase retrieval pipeline: query expansion → multi-query fan-out + RRF → recency boost → MMR diversity → session round-robin
- **Reciprocal Rank Fusion (RRF)**: merges results from multiple query variants, reducing sensitivity to exact phrasing
- **MMR (Maximal Marginal Relevance)**: reranks results for diversity, preventing the LLM context from being flooded with near-duplicate chunks
- **Recency boost**: exponential decay from `created` timestamps in frontmatter — Sol's notes already have this in YAML, it just isn't used at retrieval time

---

### Specific Improvements for Sol

| Gap in Sol today | GraphRAG fix | Effort |
|---|---|---|
| Multi-hop questions fail silently | Entity graph + pathfinder traversal | High |
| Duplicate chunks fill context | MMR diversity reranking | Low |
| Phrasing sensitivity (exact words matter) | RRF over query variants | Low |
| "Give me an overview of topic X" returns fragments | Community detection + global search | High |
| FAISS brute-force is O(n) | HNSW index (sublinear) | Medium |
| Calendar bypass is hand-coded | Date entities become graph nodes, time edges handled generically | Medium |
| `created` frontmatter unused at retrieval | Recency boost | Low |

**Quick wins (low effort, high impact):**
1. **MMR reranking** — after FAISS search, rerank the top-20 for diversity before selecting top-5. Eliminates the "same paragraph, three times" problem. Can be added to `_retrieve()` in ~30 lines using numpy cosine similarity between result vectors.
2. **RRF over query variants** — generate 2–3 paraphrases of the question with a cheap Ollama call, run three FAISS searches, merge with RRF. Adds one LLM call per query but dramatically reduces phrasing sensitivity.
3. **Recency boost** — weight FAISS scores by `exp(-days_since_created / 90)` using the `created` field already in frontmatter. Sol's NodeStore could carry this metadata.

**Medium effort:**
4. **HNSW replacement** — replace FAISS `IndexIDMap2` with an HNSW index (available in faiss-cpu as `IndexHNSWFlat`). Same API, 10–100× faster at scale. No architecture change.
5. **Query expansion** — ruflo-rag-memory's template-based variant generation (no LLM call needed, just prepend "summarise:", "what is:", "list notes about:", etc.).

**High effort (proper GraphRAG):**
6. **Entity extraction pipeline** — at index time, after chunking, run an Ollama extraction prompt to pull entities and relations from each chunk. Store in a NetworkX graph (already in Sol's `.venv` — `networkx` is installed). Persist as a JSON adjacency list alongside the FAISS index.
7. **Pathfinder retrieval** — at query time, extract entities from the question, look them up in the graph, traverse edges, pull associated node IDs from FAISS, merge with standard vector results.
8. **Community detection** — run Louvain (via `networkx.community.louvain_communities()`) over the entity graph at index time. Store community labels per entity. Use for global "overview" queries.

### Recommended Migration Path

**Phase 1 (1–2 days):** Add MMR reranking and recency boost to `_retrieve()`. Zero new dependencies. Immediate retrieval quality improvement.

**Phase 2 (3–5 days):** Replace FAISS index with HNSW. Add query expansion (template-based, no LLM). Add RRF merge.

**Phase 3 (1–2 weeks):** Entity extraction at index time using a structured Ollama prompt. Store entity→node_id mapping. Add pathfinder traversal for multi-hop queries. This is where Sol gets GraphRAG.

**Phase 4 (future):** Community detection, global search, adaptive embeddings.

---

## Part B — Agentic Swarms and LLM Routing

### 1. How Ruflo's Agentic Swarms Work

Ruflo's swarm model is a meta-harness layered on top of Claude Code's native multi-agent tools (`Task`, `SendMessage`, `TaskCreate/Update/Get`). The key concepts:

**Topology types:**
- `hierarchical`: a coordinator agent spawns and directs specialised worker agents. Workers report back; coordinator synthesises. Best for structured build tasks (coordinator → backend-engineer + frontend-engineer + qa-engineer).
- `mesh`: agents communicate peer-to-peer via `SendMessage`. Better for exploratory tasks where no single agent knows the right decomposition upfront.
- `hierarchical-mesh`: a queen coordinator plus peer communication between workers. Best for large teams (10+ agents).
- `ring` / `star` / `adaptive`: niche topologies for pipeline-style or broadcast tasks.

**Coordination primitives:**
- `Task` tool: spawn a subagent with a directive. `run_in_background: true` for parallelism. `name:` for addressability (other agents can `SendMessage` to it).
- `SendMessage`: inter-agent communication. Used for status updates, partial results, blockers.
- `TaskCreate/Update/Get`: shared task tracker as a blackboard — agents write progress, coordinator reads state without polling.
- `Monitor`: stream events from a background process — swarm watch, CI status, test runner output.
- `EnterWorktree/ExitWorktree`: each agent works in an isolated git worktree to avoid file conflicts.

**Consensus strategies:** Byzantine, Raft, Gossip, CRDT, Quorum. For a coding swarm with tight coordination, Raft (leader maintains authoritative state) prevents agents from diverging on shared files.

**Anti-drift defaults (from ruflo-swarm ADR):**
```
topology: hierarchical
maxAgents: 6–8
strategy: specialized
consensus: raft
memory: hybrid (SQLite + AgentDB)
```

**Self-learning:** ruflo-intelligence tracks which agent + strategy combinations succeeded, stores patterns in AgentDB, and pre-routes future similar tasks to the same configuration. Over time the swarm gets faster at tasks it has seen before.

---

### 2. Could Ruflo Replace or Augment Claude Code for Sol Development?

**Short answer:** augment, not replace. Ruflo is a harness on top of Claude Code, not an alternative. The value is structured parallel execution and cross-session learning — not different code generation ability.

**Where a ruflo-style swarm helps Sol development:**

| Task | Swarm benefit | Example |
|---|---|---|
| Implementing a multi-tier feature (daemon + iOS) | Parallel agents on independent layers | backend-engineer in worktree A, frontend-engineer in worktree B, coordinator merges PRs |
| Running QA after each build | Background qa-engineer agent monitors CI output, files issues automatically | ruflo-testgen + ruflo-browser |
| Cross-session learning | Patterns from "how we structure routes in daemon/" remembered and applied to new routes without re-explaining | ruflo-intelligence stores `pattern-daemon-route` in AgentDB |
| Code review on PRs | Spawn review-engineer agent on PR diff, post inline comments via `gh api` | ruflo-jujutsu for git diff analysis |
| Documentation | ruflo-docs agent triggered on file changes, auto-updates CLAUDE.md, README | hooks-based, no manual trigger needed |

**Where it adds friction:**
- For single-file bug fixes, swarm overhead (spawn, coordinate, merge) outweighs the benefit. Just use Claude Code directly.
- Worktree management becomes complex if features span daemon + iOS + CLI simultaneously.
- The learning loop requires several executions before it pays off.

**Practical recommendation:** adopt the swarm pattern for multi-issue sprints (like this one — 3 independent features). A coordinator agent creates issues, dispatches one worker per feature into a worktree, monitors CI, merges PRs when green. For single-feature work, plain Claude Code is faster.

---

### 3. LLM Router: Route Away from Claude, Route Toward Ollama

#### The Problem

Every query to Sol's daemon currently hits Ollama (the local model). The proposal is inverted: the question is whether to route *away from Claude Code* (the paid subscription the user uses for development), not away from Ollama. The target is a router that classifies requests and serves as many as possible locally, escalating only complex reasoning to Claude.

#### Request Classification

Three tiers:

**Tier 1 — Local Ollama only**
- Simple factual recall ("what did I name that project?")
- Calendar lookups (already bypasses FAISS — also bypass Ollama, serve direct from NodeStore)
- Short note creation / transcription
- Tag suggestions
- Health checks, status queries

Signals: question length < 40 tokens, no reasoning words ("why", "compare", "explain", "should I"), answer expected in < 2 sentences, intent classification confidence > 0.9

**Tier 2 — Ollama with RAG (current behaviour)**
- Knowledge synthesis across multiple notes
- Follow-up questions in a conversation
- Summarisation of a document
- Anything calendar-adjacent that needs narrative

Signals: `_needs_vault_async` returns True, conversation history present, question involves synthesis

**Tier 3 — Escalate to Claude API**
- Complex multi-step reasoning ("help me design the architecture for X")
- Code generation
- Anything the local model fails on (detected by confidence score or output quality heuristics)
- Requests where the user explicitly asks for "best answer" or the local model produces a refusal

Signals: question > 100 tokens with reasoning intent, code blocks expected in response, local model returns `"I don't know"` or `"I'm not sure"`, user prefixes with `!` or `/advanced`

#### Router Architecture

```
User query
    │
    ▼
ClassifierFast (regex + token count, <1ms)
    │
    ├── Tier 1 → NodeStore direct / Ollama tiny model
    │
    ├── Tier 2 → Ollama + FAISS (current path)
    │
    └── Tier 3 → Claude API (claude-haiku-4-5 for speed/cost, 
                              escalate to claude-sonnet-4-6 if needed)
                              with fallback → Ollama if API unavailable
```

**ClassifierFast (no LLM):**
```python
def classify_tier(question: str, history: list[dict]) -> int:
    tokens = question.split()
    has_reasoning = any(w in question.lower() for w in 
        ["why", "compare", "explain", "design", "should", "how would", "best way"])
    has_code = "```" in question or any(w in question.lower() for w in 
        ["function", "code", "implement", "write a", "debug"])
    
    if len(tokens) < 15 and not has_reasoning and not history:
        return 1  # fast local
    if has_code or len(tokens) > 80:
        return 3  # Claude
    return 2  # standard Ollama+RAG
```

**Cost impact:** Tier 1 queries (probably 30–40% of typical usage: "what's on my calendar", "add a note", "what did I call X") become free. Tier 3 queries (probably 5–15%: complex reasoning, code help) use Claude API at pay-per-token rates. Net result: Claude Code subscription used only for development work, not for routine note queries.

**Fallback chain:**
```
Tier 3 request
    → Try Claude API (haiku first, sonnet if haiku refuses/truncates)
    → If API timeout (>10s) or rate limit → fall back to Tier 2 (Ollama)
    → If Ollama timeout → return cached last response or apologise
```

#### ruflo-ruvllm Integration

ruflo-ruvllm's `hooks_route` tool implements exactly this pattern (HNSW-based routing over ≤11 hot patterns). For Sol, the patterns would be the tier classification rules. The integration path:
1. Install `ruflo-ruvllm` as a Claude Code plugin
2. Register routing rules as HNSW patterns (each rule is a vector: embedding of example questions for that tier)
3. `hooks_route` classifies at query time using HNSW lookup (<0.05ms)
4. Replace `_needs_vault_async` binary gate with the three-tier router

The ruflo HNSW router is a better fit than a regex classifier for ambiguous cases — it learns from examples rather than hand-coded heuristics.

#### Latency Budget

| Tier | Expected latency | Why |
|---|---|---|
| Tier 1 (NodeStore direct) | 5–20ms | No LLM call, just JSON lookup |
| Tier 2 (Ollama + FAISS) | 2–15s | Current behaviour, local model |
| Tier 3 (Claude haiku) | 1–3s | Network + fast model |
| Tier 3 (Claude sonnet) | 3–8s | Network + capable model |

Counterintuitively, Tier 3 Claude calls may be *faster* than Tier 2 Ollama calls on complex questions, because the local model is constrained by Mac hardware while Claude runs on Anthropic infrastructure.

---

## Summary Recommendations

| Priority | Action | Effort | Impact |
|---|---|---|---|
| 1 | MMR reranking in `_retrieve()` | 1 day | Immediate RAG quality lift |
| 2 | Three-tier LLM router | 2 days | Cost reduction + faster simple queries |
| 3 | RRF query expansion | 1 day | Phrasing robustness |
| 4 | HNSW index swap | 1 day | Scale headroom |
| 5 | Entity extraction + graph | 1–2 weeks | Multi-hop reasoning, GraphRAG |
| 6 | Ruflo swarm for sprints | Ongoing | Parallel feature development |
