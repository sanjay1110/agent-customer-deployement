"""HTTP API for the support agent.

Endpoints
  GET  /health    liveness; no dependencies (used by the ALB and container health check)
  GET  /ready     readiness; verifies secrets are readable (used by smoke tests / runbook)
  POST /v1/chat   {"message": "..."}  -> {"answer": ..., "request_id": ...}   (requires X-API-Key)
"""

from __future__ import annotations

import hmac
import logging
import threading
import time
import uuid

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.agent import LLMError, SupportAgent, build_llm
from app.config import Settings
from app.config import settings as default_settings
from app.observability import configure_logging, request_id_var
from app.secrets import SecretStore, SecretUnavailableError
from app.tools import KnowledgeBase, ToolRunner, build_ticket_store

log = logging.getLogger("app")


class ChatRequest(BaseModel):
    message: str = Field(min_length=1)


class ChatResponse(BaseModel):
    answer: str
    request_id: str
    tool_calls: list[str]


def create_app(
    settings: Settings = default_settings, secrets: SecretStore | None = None, llm=None, ticket_store=None
) -> FastAPI:
    configure_logging(settings.service_name, settings.log_level)
    secrets = secrets or SecretStore(settings)
    agent = SupportAgent(
        settings,
        llm or build_llm(settings, secrets),
        ToolRunner(KnowledgeBase(), ticket_store or build_ticket_store(settings)),
    )
    capacity = threading.BoundedSemaphore(settings.max_concurrent_requests)

    app = FastAPI(title="Support Agent", version="1.0.0", docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def request_context(request: Request, call_next):
        rid = request.headers.get("x-request-id") or uuid.uuid4().hex
        rid = rid[:64]
        token = request_id_var.set(rid)
        started = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            response.headers["x-request-id"] = rid
            return response
        finally:
            if request.url.path != "/health":  # don't flood logs with ALB health checks
                log.info(
                    "request_completed",
                    extra={
                        "method": request.method,
                        "path": request.url.path,
                        "status": status,
                        "latency_ms": round((time.perf_counter() - started) * 1000),
                    },
                )
            request_id_var.reset(token)

    def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
        if not x_api_key:
            log.warning("auth_failed", extra={"reason": "missing_key"})
            raise HTTPException(status_code=401, detail="missing X-API-Key")
        try:
            valid = secrets.client_api_keys()
        except SecretUnavailableError as exc:
            log.error("auth_unavailable")
            raise HTTPException(status_code=503, detail="service temporarily unavailable") from exc
        if not any(hmac.compare_digest(x_api_key.encode(), k.encode()) for k in valid):
            log.warning("auth_failed", extra={"reason": "invalid_key"})
            raise HTTPException(status_code=401, detail="invalid X-API-Key")

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/ready")
    def ready():
        if not secrets.health_check():
            return JSONResponse(status_code=503, content={"status": "not_ready", "reason": "secrets_unavailable"})
        return {"status": "ready"}

    @app.post("/v1/chat", response_model=ChatResponse, dependencies=[Depends(require_api_key)])
    def chat(body: ChatRequest):
        if len(body.message) > settings.max_input_chars:
            raise HTTPException(status_code=413, detail=f"message exceeds {settings.max_input_chars} characters")
        if not capacity.acquire(blocking=False):
            log.warning("capacity_exceeded", extra={"limit": settings.max_concurrent_requests})
            raise HTTPException(status_code=429, detail="too many concurrent requests; retry shortly")
        try:
            if settings.log_conversation_content:
                log.info("conversation_input", extra={"content": body.message})
            result = agent.run(body.message)
        except LLMError as exc:
            raise HTTPException(status_code=502, detail="the AI model is temporarily unavailable") from exc
        except SecretUnavailableError as exc:
            raise HTTPException(status_code=503, detail="service temporarily unavailable") from exc
        finally:
            capacity.release()
        log.info(
            "chat_completed",
            extra={
                "tool_calls": result.tool_calls,
                "input_tokens": result.input_tokens,
                "output_tokens": result.output_tokens,
            },
        )
        return ChatResponse(answer=result.answer, request_id=request_id_var.get(), tool_calls=result.tool_calls)

    return app


app = create_app()
