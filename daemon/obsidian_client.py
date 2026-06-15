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
        token = api_key.removeprefix("Bearer ").strip()
        self._client = httpx.AsyncClient(
            base_url=base_url,
            headers={"Authorization": f"Bearer {token}"},
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

    async def put_file(self, vault_path: str, data: bytes) -> None:
        """PUT /vault/<vault_path> — write raw bytes to the vault.

        Used for binary uploads (PDF, XLSX, images) and markdown notes.
        ``vault_path`` is relative to the vault root, e.g.
        ``"uploads/pdf/26-01-06-12-00/report.pdf"`` or ``"notes.md"``.
        """
        # Infer content-type so Obsidian REST API doesn't reject the request
        suffix = vault_path.rsplit(".", 1)[-1].lower() if "." in vault_path else ""
        _ct_map = {
            "md": "text/markdown",
            "pdf": "application/pdf",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "xls": "application/vnd.ms-excel",
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
        }
        content_type = _ct_map.get(suffix, "application/octet-stream")
        resp = await self._client.put(
            f"/vault/{vault_path}",
            content=data,
            headers={"Content-Type": content_type},
        )
        if not resp.is_success:
            raise ObsidianError(resp.text, resp.status_code)

    async def list_directories(self) -> list[str]:
        """GET /vault/ — return sorted unique parent directories in the vault.

        Parses the ``files`` list from the response and extracts the parent
        directory of each path (everything before the last ``/``).  Root-level
        files (no ``/`` in path) are skipped.  The result is deduplicated and
        sorted alphabetically.
        """
        try:
            resp = await self._client.get("/vault/")
            if not resp.is_success:
                return []
            data = resp.json()
            files = data.get("files", [])
            dirs: set[str] = set()
            for f in files:
                f = str(f)
                if "/" in f:
                    dirs.add(f.rsplit("/", 1)[0])
            return sorted(dirs)
        except Exception:
            return []

    async def close(self):
        await self._client.aclose()
