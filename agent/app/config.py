"""Runtime configuration.

Every value here is NON-SECRET configuration read from environment variables
set in the ECS task definition. Secret values (API keys) are never read from
the environment in AWS; they are fetched at runtime from AWS Secrets Manager
by ``app.secrets``. See docs/security-summary.md.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _int(name: str, default: int) -> int:
    raw = os.getenv(name)
    return int(raw) if raw else default


@dataclass(frozen=True)
class Settings:
    # "aws" in the customer environment, "local" for laptops / CI.
    app_env: str = field(default_factory=lambda: os.getenv("APP_ENV", "local"))
    service_name: str = field(default_factory=lambda: os.getenv("SERVICE_NAME", "support-agent"))
    aws_region: str = field(default_factory=lambda: os.getenv("AWS_REGION", "us-east-1"))

    # LLM
    llm_provider: str = field(default_factory=lambda: os.getenv("LLM_PROVIDER", "anthropic"))  # anthropic | mock
    llm_model: str = field(default_factory=lambda: os.getenv("LLM_MODEL", "claude-sonnet-5-5"))
    llm_max_tokens: int = field(default_factory=lambda: _int("LLM_MAX_TOKENS", 1024))
    llm_timeout_seconds: int = field(default_factory=lambda: _int("LLM_TIMEOUT_SECONDS", 30))
    max_tool_iterations: int = field(default_factory=lambda: _int("MAX_TOOL_ITERATIONS", 5))
    max_input_chars: int = field(default_factory=lambda: _int("MAX_INPUT_CHARS", 4000))
    max_concurrent_requests: int = field(default_factory=lambda: _int("MAX_CONCURRENT_REQUESTS", 20))

    # Secrets Manager secret NAMES or ARNs (not values).
    llm_api_key_secret_id: str = field(default_factory=lambda: os.getenv("LLM_API_KEY_SECRET_ID", ""))
    client_api_key_secret_id: str = field(default_factory=lambda: os.getenv("CLIENT_API_KEY_SECRET_ID", ""))
    secret_cache_ttl_seconds: int = field(default_factory=lambda: _int("SECRET_CACHE_TTL_SECONDS", 300))

    # Data
    tickets_backend: str = field(default_factory=lambda: os.getenv("TICKETS_BACKEND", "memory"))  # dynamodb | memory
    tickets_table_name: str = field(default_factory=lambda: os.getenv("TICKETS_TABLE_NAME", ""))

    # Observability
    metrics_namespace: str = field(default_factory=lambda: os.getenv("METRICS_NAMESPACE", "AIAgent"))
    log_level: str = field(default_factory=lambda: os.getenv("LOG_LEVEL", "INFO"))
    # Prompt/response bodies may contain customer PII. Off by default.
    log_conversation_content: bool = field(default_factory=lambda: _bool("LOG_CONVERSATION_CONTENT", False))

    @property
    def is_aws(self) -> bool:
        return self.app_env == "aws"


settings = Settings()
