import json

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, field_validator

from solidrag import query_stream_async

router = APIRouter()


class HistoryMessage(BaseModel):
    role: str
    content: str


class QueryRequest(BaseModel):
    question: str
    history: list[HistoryMessage] | None = None

    @field_validator("question")
    @classmethod
    def question_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("question cannot be empty")
        return v


@router.post("/api/query")
async def query_vault(request: Request, body: QueryRequest):
    """
    Stream query response as Server-Sent Events.

    Event format (one per line, blank line separator):
      data: {"type": "token",   "content": "<string>"}
      data: {"type": "sources", "sources": [{"file": "...", "title": "..."}]}
      data: {"type": "done"}
      data: {"type": "error",   "content": "<message>"}

    Clients should treat the connection as done when they receive type=done
    or type=error. The stream ends after that event.
    """
    faiss_index = getattr(request.app.state, "vault_index", None)
    nodestore = getattr(request.app.state, "vault_nodestore", None)
    if faiss_index is None or nodestore is None:
        return JSONResponse(status_code=503, content={"detail": "Index not ready yet"})

    history = [{"role": m.role, "content": m.content} for m in (body.history or [])]
    system_prompt = getattr(request.app.state.config, "system_prompt", None)

    async def generate():
        try:
            async for event in query_stream_async(
                faiss_index,
                nodestore,
                body.question,
                history=history,
                system_prompt=system_prompt,
            ):
                yield f"data: {json.dumps(event)}\n\n"
        except Exception as e:
            err = str(e)
            if "timeout" in err.lower() or "timed out" in err.lower():
                msg = "LLM timed out — try a shorter question or try again"
            else:
                msg = err
            yield f"data: {json.dumps({'type': 'error', 'content': msg})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # disable nginx buffering if proxied
        },
    )
