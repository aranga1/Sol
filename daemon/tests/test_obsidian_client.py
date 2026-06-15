import httpx
import pytest
import respx
from httpx import Response

from daemon.obsidian_client import ObsidianClient, ObsidianError

BASE = "http://localhost:27124"


def make_client(router: respx.MockRouter) -> ObsidianClient:
    """Create an ObsidianClient whose httpx transport is backed by *router*."""
    transport = httpx.MockTransport(router.handler)
    return ObsidianClient(BASE, "testkey", transport=transport)


@pytest.mark.asyncio
async def test_create_note_success():
    router = respx.MockRouter(assert_all_called=False)
    router.put("/vault/Notes/test.md").mock(return_value=Response(200))
    client = make_client(router)
    path = await client.create_note("test.md", "# Hello")
    assert path == "Notes/test.md"
    await client.close()


@pytest.mark.asyncio
async def test_create_note_error():
    router = respx.MockRouter(assert_all_called=False)
    router.put("/vault/Notes/bad.md").mock(return_value=Response(404, text="Not found"))
    client = make_client(router)
    with pytest.raises(ObsidianError) as exc:
        await client.create_note("bad.md", "content")
    assert exc.value.status_code == 404
    await client.close()


@pytest.mark.asyncio
async def test_health_true():
    router = respx.MockRouter(assert_all_called=False)
    router.get("/").mock(return_value=Response(200))
    client = make_client(router)
    assert await client.health() is True
    await client.close()


@pytest.mark.asyncio
async def test_health_false_on_connect_error():
    router = respx.MockRouter(assert_all_called=False)
    router.get("/").mock(side_effect=httpx.ConnectError("refused"))
    client = make_client(router)
    assert await client.health() is False
    await client.close()


@pytest.mark.asyncio
async def test_note_count():
    router = respx.MockRouter(assert_all_called=False)
    router.get("/vault/").mock(
        return_value=Response(
            200,
            json={"files": ["Notes/a.md", "Notes/b.md", "Attachments/img.png"]},
        )
    )
    client = make_client(router)
    assert await client.note_count() == 2
    await client.close()


@pytest.mark.asyncio
async def test_note_count_on_non_2xx_returns_zero():
    """note_count() must return 0 (not raise) when Obsidian returns a non-2xx."""
    router = respx.MockRouter(assert_all_called=False)
    router.get("/vault/").mock(return_value=Response(401, text="Unauthorized"))
    client = make_client(router)
    count = await client.note_count()
    await client.close()
    assert count == 0


@pytest.mark.asyncio
async def test_note_count_missing_files_key_returns_zero():
    """note_count() must return 0 when response JSON has no 'files' key."""
    router = respx.MockRouter(assert_all_called=False)
    router.get("/vault/").mock(return_value=Response(200, json={}))
    client = make_client(router)
    count = await client.note_count()
    await client.close()
    assert count == 0


@pytest.mark.asyncio
async def test_list_directories_returns_sorted_unique_paths():
    """list_directories() extracts unique parent dirs from vault file list."""
    mock_files = {
        "files": [
            "Notes/daily/2026-06-15.md",
            "Notes/daily/2026-06-14.md",
            "Notes/projects/sol.md",
            "ideas/ai-thoughts.md",
            "ideas/travel.md",
            "readme.md",  # root file — no parent dir to extract
        ]
    }
    router = respx.MockRouter(assert_all_called=False)
    router.get("/vault/").mock(return_value=Response(200, json=mock_files))
    client = make_client(router)
    dirs = await client.list_directories()
    await client.close()
    assert dirs == ["Notes/daily", "Notes/projects", "ideas"]


@pytest.mark.asyncio
async def test_list_directories_excludes_root_files():
    """Files at vault root (no slash in path) don't produce a directory entry."""
    mock_files = {"files": ["readme.md", "Notes/a.md"]}
    router = respx.MockRouter(assert_all_called=False)
    router.get("/vault/").mock(return_value=Response(200, json=mock_files))
    client = make_client(router)
    dirs = await client.list_directories()
    await client.close()
    assert dirs == ["Notes"]


@pytest.mark.asyncio
async def test_list_directories_empty_vault():
    mock_files = {"files": []}
    router = respx.MockRouter(assert_all_called=False)
    router.get("/vault/").mock(return_value=Response(200, json=mock_files))
    client = make_client(router)
    dirs = await client.list_directories()
    await client.close()
    assert dirs == []


@pytest.mark.asyncio
async def test_list_directories_deduplicates():
    """Multiple files in same dir → dir appears once."""
    mock_files = {"files": ["ideas/a.md", "ideas/b.md", "ideas/c.md"]}
    router = respx.MockRouter(assert_all_called=False)
    router.get("/vault/").mock(return_value=Response(200, json=mock_files))
    client = make_client(router)
    dirs = await client.list_directories()
    await client.close()
    assert dirs == ["ideas"]
