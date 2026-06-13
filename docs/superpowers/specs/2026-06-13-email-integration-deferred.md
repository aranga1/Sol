# Email Integration — Deferred

**Date:** 2026-06-13
**Status:** Deferred — design needed before implementation

---

## Summary

Email integration (Group D) has been intentionally descoped from the current feature expansion. It requires a dedicated design session before implementation can begin.

## Core constraint

Emails must **not** be indexed into the RAG vector store — the corpus is too large and grows unbounded. A different retrieval strategy is required: live lookup / search at query time rather than pre-indexed embeddings.

## Key open questions for future design session

1. **Access mechanism**: IMAP (works with Gmail, iCloud Mail, Fastmail — local protocol, no OAuth for standard servers) vs Gmail API (OAuth, richer search) vs Apple Mail database (fragile, private).

2. **Retrieval pattern**: When the agent determines a question requires email context, it performs a targeted search (by sender, subject, date range, keyword) rather than vector retrieval. The search results are injected into the LLM context for that query only — nothing is persisted to the index.

3. **Privacy model**: Emails are fetched on-demand and never written to disk beyond the query lifetime. The daemon holds email content in memory for the duration of a single query then discards it.

4. **Caching strategy**: For repeated queries about the same email thread, a short-lived in-memory cache (TTL ~5 minutes) avoids redundant IMAP fetches without persisting sensitive content.

5. **solidRag extension**: Email would implement `SourceExtractor` differently — `sync()` is replaced by an on-demand `search(query: str) -> list[TextNode]` method called at query time, not on a schedule.

## When to revisit

Start a new brainstorming session with `/brainstorm` once Groups A, C, and E are shipped and stable. Email is the most complex integration and benefits from the `SourceExtractor` patterns established by Calendar being fully tested in production first.
