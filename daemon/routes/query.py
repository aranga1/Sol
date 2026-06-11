from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, field_validator

from daemon.rag import query as rag_query

router = APIRouter()


class QueryRequest(BaseModel):
    question: str

    @field_validator("question")
    @classmethod
    def question_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("question cannot be empty")
        return v


class SourceItem(BaseModel):
    file: str
    title: str


class QueryResponse(BaseModel):
    answer: str
    sources: list[SourceItem]


@router.post("/api/query", response_model=QueryResponse)
async def query_vault(request: Request, body: QueryRequest):
    index = getattr(request.app.state, "vault_index", None)
    if index is None:
        return JSONResponse(status_code=503, content={"detail": "Index not ready yet"})

    answer, sources = rag_query(index, body.question)
    return QueryResponse(
        answer=answer,
        sources=[SourceItem(file=s["file"], title=s["title"]) for s in sources],
    )
