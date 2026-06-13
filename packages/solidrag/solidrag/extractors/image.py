"""ImageExtractor — describe images via the Ollama vision API (llava).

Sends the image as a base64-encoded payload to POST /api/generate on the
configured Ollama server and stores the model's description as a TextNode.
"""
from __future__ import annotations

import base64
from pathlib import Path

from llama_index.core.schema import TextNode


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

        image_bytes = path.read_bytes()
        b64_image = base64.b64encode(image_bytes).decode()

        url = f"{self.ollama_base_url}/api/generate"
        payload = {
            "model": self.vision_model,
            "prompt": "Describe this image in detail.",
            "images": [b64_image],
            "stream": False,
        }
        response = httpx.post(url, json=payload, timeout=60.0)
        response.raise_for_status()
        description = response.json().get("response", "").strip()

        meta = {"file_path": str(path), "file_name": path.name}
        node = TextNode(text=description, metadata=meta)
        node.excluded_llm_metadata_keys = list(meta.keys())
        return [node]
