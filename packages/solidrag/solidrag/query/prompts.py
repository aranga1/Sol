"""Prompt templates and builders for the solidRag query engine."""
from __future__ import annotations

NEEDS_VAULT_PROMPT: str = """\
Does answering the following question require searching the user's personal \
notes, vault, or uploaded files?
Answer YES if the question is about: the user's own memories, notes, people \
they know, events in their life, uploaded documents (PDFs, letters, contracts, \
spreadsheets), images or photos they have uploaded, the contents of an image \
or attachment, specific fees, amounts, dates, or names that would only be \
found in personal records.
Answer NO only if the question can be answered entirely from general knowledge \
with no reference to the user's personal files \
(greetings, questions about the assistant itself, general facts, math).
When in doubt, answer YES.
Reply with exactly one word: YES or NO.

Conversation so far:
{history}

Question: {question}
Answer:"""

DIRECT_SYSTEM: str = (
    "You are Sol, a personal second-brain assistant. "
    "Answer the user's question conversationally. "
    "Do not reference any notes or documents."
)


def build_direct_prompt(question: str, history: list[dict] | None) -> str:
    """Build a prompt for the direct (non-RAG) answer path.

    Args:
        question: The user's current question.
        history: Optional list of prior turns, each a dict with "role" and "content".

    Returns:
        A formatted prompt string ending with "Sol:".
    """
    history_text = ""
    if history:
        history_text = (
            "\n".join(
                f"{'User' if m['role'] == 'user' else 'Sol'}: {m['content']}"
                for m in history
            )
            + "\n\n"
        )
    return f"{DIRECT_SYSTEM}\n\n{history_text}User: {question}\nSol:"


def build_rag_prompt(
    system_prompt: str,
    context_str: str,
    question: str,
    history: list[dict] | None,
) -> str:
    """Build a RAG prompt that inlines retrieved context for streaming via llm.astream_complete.

    Args:
        system_prompt: The system instructions to prepend.
        context_str: Retrieved context chunks joined by separators.
        question: The user's current question.
        history: Optional list of prior turns, each a dict with "role" and "content".

    Returns:
        A formatted prompt string ending with "Answer:".
    """
    history_section = ""
    if history:
        history_text = "\n".join(
            f"{'User' if m['role'] == 'user' else 'Sol'}: {m['content']}"
            for m in history
        )
        history_section = (
            f"\n\nPrevious conversation "
            f"(for context only — do NOT treat as notes):\n{history_text}"
        )

    return (
        f"{system_prompt}{history_section}\n\n"
        f"Relevant notes:\n{context_str}\n\n"
        f"Question: {question}\n"
        f"Answer:"
    )


CALENDAR_ACTION_PROMPT: str = """\
Does the following message ask to CREATE a new calendar event, meeting, \
appointment, or reminder?
Today's date is {today}.
If yes, extract the event details. Default duration to 60 minutes if not specified.
Reply with valid JSON only — no markdown fences:

{{
  "is_calendar_action": true or false,
  "event": {{
    "title": "string or null",
    "start": "ISO8601 datetime string or null",
    "duration_minutes": number or null,
    "notes": "string or null"
  }}
}}

Message: {question}"""
