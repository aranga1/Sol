from typing import Optional

import httpx
from dataclasses import dataclass


@dataclass
class ObsidianError(Exception):
    message: str
    status_code: int

    def __post_init__(self):
        super().__init__(self.message, self.status_code)

    def __str__(self) -> str:
        return f"ObsidianError({self.status_code}): {self.message}"


class ObsidianClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        transport: Optional[httpx.AsyncBaseTransport] = None,
    ):
        self._client = httpx.AsyncClient(
            base_url=base_url,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=10.0,
            verify=False,  # local-only, self-signed cert acceptable
            transport=transport,
        )

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

    async def health(self) -> bool:
        """GET / — returns True if Obsidian Local REST API plugin is running."""
        try:
            resp = await self._client.get("/")
            return resp.is_success
        except httpx.ConnectError:
            return False

    async def note_count(self) -> int:
        """GET /vault/ — return count of .md files in the vault."""
        try:
            resp = await self._client.get("/vault/")
            if not resp.is_success:
                return 0
            data = resp.json()
            # Response is {"files": ["Notes/foo.md", ...]}
            files = data.get("files", [])
            return sum(1 for f in files if str(f).endswith(".md"))
        except Exception:
            return 0

    async def close(self):
        await self._client.aclose()
