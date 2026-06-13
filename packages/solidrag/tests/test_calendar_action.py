import pytest
from unittest.mock import AsyncMock, MagicMock, patch


@pytest.mark.asyncio
async def test_is_calendar_action_detected():
    from solidrag.query.engine import _is_calendar_action

    mock_result = MagicMock()
    mock_result.__str__ = lambda self: (
        '{"is_calendar_action": true, "event": {"title": "Call with John",'
        ' "start": "2026-06-14T15:00:00", "duration_minutes": 30, "notes": ""}}'
    )

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)
        mock_llm_fn.return_value = mock_llm

        is_action, payload = await _is_calendar_action("schedule a call with John tomorrow at 3pm")

    assert is_action is True
    assert payload["title"] == "Call with John"
    assert payload["duration_minutes"] == 30


@pytest.mark.asyncio
async def test_is_calendar_action_not_detected():
    from solidrag.query.engine import _is_calendar_action

    mock_result = MagicMock()
    mock_result.__str__ = lambda self: '{"is_calendar_action": false, "event": null}'

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)
        mock_llm_fn.return_value = mock_llm

        is_action, payload = await _is_calendar_action("what is the capital of France?")

    assert is_action is False
    assert payload is None


@pytest.mark.asyncio
async def test_is_calendar_action_malformed_json_returns_false():
    from solidrag.query.engine import _is_calendar_action

    mock_result = MagicMock()
    mock_result.__str__ = lambda self: "not json at all"

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = AsyncMock(return_value=mock_result)
        mock_llm_fn.return_value = mock_llm

        is_action, payload = await _is_calendar_action("book a meeting")

    assert is_action is False
    assert payload is None


@pytest.mark.asyncio
async def test_query_stream_emits_create_event_action():
    from solidrag.query.engine import query_stream_async
    from solidrag.index.nodestore import NodeStore
    import faiss
    import numpy as np

    inner = faiss.IndexFlatL2(768)
    mock_index = faiss.IndexIDMap2(inner)

    import tempfile, pathlib
    tmp = pathlib.Path(tempfile.mkdtemp()) / "ns.json"
    nodestore = NodeStore(tmp)
    nodestore.load()

    calendar_json = (
        '{"is_calendar_action": true, "event": {"title": "Dentist",'
        ' "start": "2026-06-15T10:00:00", "duration_minutes": 60, "notes": ""}}'
    )

    async def fake_acomplete(prompt):
        result = MagicMock()
        if "CREATE" in prompt or "calendar" in prompt.lower() or "CREATE" in prompt.upper():
            result.__str__ = lambda self: calendar_json
        else:
            result.__str__ = lambda self: "NO"
        return result

    async def fake_astream_complete(prompt):
        async def _gen():
            chunk = MagicMock()
            chunk.delta = "Sure, I'll set that up."
            yield chunk
        return _gen()

    with patch("solidrag.query.engine._get_llm") as mock_llm_fn:
        mock_llm = MagicMock()
        mock_llm.acomplete = fake_acomplete
        mock_llm.astream_complete = fake_astream_complete
        mock_llm_fn.return_value = mock_llm

        events = []
        async for event in query_stream_async(mock_index, nodestore, "book a dentist appointment next Monday at 10am"):
            events.append(event)

    types = [e["type"] for e in events]
    assert "action" in types
    action_event = next(e for e in events if e["type"] == "action")
    assert action_event["action"] == "create_event"
    assert action_event["payload"]["title"] == "Dentist"
