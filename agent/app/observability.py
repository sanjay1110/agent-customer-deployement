"""Structured JSON logging.

Every log line is a single JSON object written to stdout. ECS ships stdout to
CloudWatch Logs (awslogs driver). CloudWatch *metric filters* defined in
Terraform (infra/modules/secure-agent-platform/monitoring.tf) turn specific
events into metrics, for example ``event=llm_call`` becomes
``LLMLatencyMs`` / ``LLMInputTokens`` / ``LLMOutputTokens``.

The event names and fields below are therefore a CONTRACT with the monitoring
configuration. If you rename one, update monitoring.tf too
(docs/monitoring.md lists the contract).
"""

from __future__ import annotations

import contextvars
import json
import logging
import sys
import time

request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")

_STD_ATTRS = set(logging.LogRecord("x", 0, "x", 0, "x", None, None).__dict__.keys()) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str) -> None:
        super().__init__()
        self._service = service

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "service": self._service,
            "event": record.getMessage(),
            "request_id": request_id_var.get(),
            "logger": record.name,
        }
        for key, value in record.__dict__.items():
            if key not in _STD_ATTRS and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(service: str, level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())
    # Quiet chatty libraries; their DEBUG output can include request bodies.
    for noisy in ("botocore", "boto3", "urllib3", "httpx", "anthropic"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").disabled = True  # replaced by our request_completed event
