from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from daemon.config import DEFAULT_SYSTEM_PROMPT, save_system_prompt

router = APIRouter()


class SystemPromptResponse(BaseModel):
    system_prompt: str
    default_system_prompt: str


class SystemPromptUpdate(BaseModel):
    system_prompt: str


@router.get("/api/config", response_model=SystemPromptResponse)
async def get_config(request: Request):
    return SystemPromptResponse(
        system_prompt=request.app.state.config.system_prompt,
        default_system_prompt=DEFAULT_SYSTEM_PROMPT,
    )


@router.patch("/api/config", response_model=SystemPromptResponse)
async def update_config(request: Request, body: SystemPromptUpdate):
    prompt = body.system_prompt.strip()
    if not prompt:
        return JSONResponse(status_code=400, content={"detail": "system_prompt cannot be empty"})

    save_system_prompt(prompt)
    request.app.state.config.system_prompt = prompt

    return SystemPromptResponse(
        system_prompt=prompt,
        default_system_prompt=DEFAULT_SYSTEM_PROMPT,
    )
