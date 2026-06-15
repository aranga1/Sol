import sys
import pathlib

# Allow importing from setup/sol_cli.py via the setup package
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from setup.sol_cli import _parse_sse_stream


def test_parse_sse_yields_token_event():
    lines = [b'data: {"type": "token", "content": "hello"}\n']
    events = list(_parse_sse_stream(lines))
    assert events == [{"type": "token", "content": "hello"}]


def test_parse_sse_skips_non_data_lines():
    lines = [b"event: message\n", b": keep-alive\n", b'data: {"type": "done"}\n']
    events = list(_parse_sse_stream(lines))
    assert events == [{"type": "done"}]


def test_parse_sse_skips_malformed_json():
    lines = [b"data: not-valid-json\n", b'data: {"type": "token", "content": "ok"}\n']
    events = list(_parse_sse_stream(lines))
    assert events == [{"type": "token", "content": "ok"}]


def test_parse_sse_handles_string_lines():
    """Lines may arrive as str when mocked."""
    lines = ['data: {"type": "done"}\n']
    events = list(_parse_sse_stream(lines))
    assert events == [{"type": "done"}]


def test_parse_sse_collects_full_response():
    lines = [
        b'data: {"type": "token", "content": "Hello"}\n',
        b'data: {"type": "token", "content": " world"}\n',
        b'data: {"type": "sources", "sources": [{"file": "notes/a.md", "title": "A"}]}\n',
        b'data: {"type": "done"}\n',
    ]
    events = list(_parse_sse_stream(lines))
    assert len(events) == 4
    assert events[0]["type"] == "token"
    assert events[2]["type"] == "sources"
    assert events[3]["type"] == "done"


def test_history_list_accumulates():
    """History list grows correctly across turns — pure data logic."""
    history: list[dict] = []
    history.append({"role": "user", "content": "What is WWDC?"})
    history.append({"role": "assistant", "content": "Apple's developer conference."})
    assert len(history) == 2
    assert history[0]["role"] == "user"
    assert history[1]["role"] == "assistant"


def test_history_clear_empties_list():
    history = [
        {"role": "user", "content": "hello"},
        {"role": "assistant", "content": "hi"},
    ]
    history.clear()
    assert history == []
