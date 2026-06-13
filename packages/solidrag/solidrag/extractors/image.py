"""ImageExtractor — describe images via the Ollama vision API.

Resizes large images before encoding so the vision model's context window
is not consumed by pixel tokens, then sends to POST /api/generate.
"""
from __future__ import annotations

import base64
import io
from pathlib import Path

from llama_index.core.schema import TextNode

# Vision models work well at this resolution; larger images eat context tokens.
_MAX_SIDE = 1024


def _resize_image_bytes(raw: bytes, max_side: int = _MAX_SIDE) -> bytes:
    """Return JPEG bytes with the longest side capped at *max_side*."""
    try:
        from PIL import Image
        img = Image.open(io.BytesIO(raw)).convert("RGB")
        w, h = img.size
        if max(w, h) > max_side:
            scale = max_side / max(w, h)
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        return buf.getvalue()
    except Exception:
        return raw  # fall back to original if PIL unavailable or fails


class ImageExtractor:
    """Extract an image description by calling an Ollama vision model."""

    supported_extensions: frozenset[str] = frozenset(
        {".jpg", ".jpeg", ".png", ".gif", ".webp"}
    )

    def __init__(
        self,
        ollama_base_url: str,
        vision_model: str = "llava",
    ) -> None:
        self.ollama_base_url = ollama_base_url.rstrip("/")
        self.vision_model = vision_model

    def extract(self, path: Path) -> list[TextNode]:
        import httpx

        image_bytes = _resize_image_bytes(path.read_bytes())
        b64_image = base64.b64encode(image_bytes).decode()

        url = f"{self.ollama_base_url}/api/generate"
        payload = {
            "model": self.vision_model,
            "prompt": (
                "Describe this image in detail. "
                "If it contains text, transcribe all visible text exactly as it appears."
            ),
            "images": [b64_image],
            "stream": False,
            "options": {"num_ctx": 8192, "num_predict": 1024},
        }
        response = httpx.post(url, json=payload, timeout=120.0)
        response.raise_for_status()
        description = response.json().get("response", "").strip()

        meta = {"file_path": str(path), "file_name": path.name}
        node = TextNode(text=description, metadata=meta)
        node.excluded_llm_metadata_keys = list(meta.keys())
        return [node]
