"""Secret retrieval with a short-lived in-memory cache.

Design decisions (see docs/security-summary.md, "Secrets management"):

* In AWS (``APP_ENV=aws``) secrets are fetched from AWS Secrets Manager using
  the ECS *task role*. They are never injected as environment variables, never
  written to disk, and never logged. A Secrets Manager resource policy makes
  the task role the ONLY principal allowed to read the values.
* Values are cached in memory for ``SECRET_CACHE_TTL_SECONDS`` (default 300s).
  A rotated secret is therefore picked up within 5 minutes without a restart.
* If a refresh fails but a previously fetched value exists, the stale value is
  served and an error is logged (alarm: SecretRefreshFailures). This keeps the
  service up during a transient Secrets Manager / VPC-endpoint problem.
* Client API key rotation uses Secrets Manager's built-in version stages: the
  app accepts both ``AWSCURRENT`` and ``AWSPREVIOUS``. Writing a new value
  automatically demotes the old one to AWSPREVIOUS, so callers have an overlap
  window; the operator later removes AWSPREVIOUS to fully revoke it. Operators
  never need (or have) permission to read a value. See scripts/rotate-client-key.sh.
* Environment-variable fallback exists ONLY for ``APP_ENV=local`` so that
  developers can run the container on a laptop. It is refused in AWS.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from dataclasses import dataclass

from app.config import Settings

log = logging.getLogger(__name__)

MIN_CLIENT_KEY_LENGTH = 32


class SecretUnavailableError(RuntimeError):
    """Raised when a secret cannot be obtained and no cached value exists."""


@dataclass
class _CacheEntry:
    value: str | None  # None = this version stage does not exist (e.g. no AWSPREVIOUS yet)
    fetched_at: float


class SecretStore:
    def __init__(self, settings: Settings, client=None) -> None:
        self._settings = settings
        self._ttl = settings.secret_cache_ttl_seconds
        self._cache: dict[tuple[str, str], _CacheEntry] = {}
        self._lock = threading.Lock()
        self._client = client

    # -- public API -------------------------------------------------------
    def llm_api_key(self) -> str:
        if not self._settings.is_aws:
            return self._local("LLM_API_KEY")
        value = self._get(self._settings.llm_api_key_secret_id, "AWSCURRENT")
        if not value:
            raise SecretUnavailableError("LLM API key secret has no value (run scripts/set-secrets.sh)")
        return value

    def client_api_keys(self) -> list[str]:
        """All currently valid client keys: AWSCURRENT plus AWSPREVIOUS if present."""
        if not self._settings.is_aws:
            raw = self._local("CLIENT_API_KEYS")
            keys = [k.strip() for k in raw.split(",")]
        else:
            current = self._get(self._settings.client_api_key_secret_id, "AWSCURRENT")
            if not current:
                raise SecretUnavailableError("client API key secret has no value (run scripts/set-secrets.sh)")
            previous = self._get(self._settings.client_api_key_secret_id, "AWSPREVIOUS", optional=True)
            keys = [current, previous or ""]
        return [k.strip() for k in keys if k and len(k.strip()) >= MIN_CLIENT_KEY_LENGTH]

    def health_check(self) -> bool:
        try:
            self.llm_api_key()
            return bool(self.client_api_keys())
        except SecretUnavailableError:
            return False

    # -- internals --------------------------------------------------------
    def _local(self, env_name: str) -> str:
        value = os.getenv(env_name, "")
        if not value:
            raise SecretUnavailableError(f"{env_name} not set (local mode)")
        return value

    def _boto_client(self):
        if self._client is None:
            import boto3  # lazy: local/mock mode has no AWS dependency at import time

            self._client = boto3.client("secretsmanager", region_name=self._settings.aws_region)
        return self._client

    def _get(self, secret_id: str, stage: str, optional: bool = False) -> str | None:
        if not secret_id:
            raise SecretUnavailableError("secret id not configured")
        key = (secret_id, stage)
        now = time.monotonic()
        with self._lock:
            entry = self._cache.get(key)
            if entry and now - entry.fetched_at < self._ttl:
                return entry.value
        client = self._boto_client()
        try:
            resp = client.get_secret_value(SecretId=secret_id, VersionStage=stage)
            value: str | None = resp.get("SecretString") or None
        except client.exceptions.ResourceNotFoundException:
            # Secret exists but has no version with this stage (e.g. never set, or no AWSPREVIOUS yet).
            value = None
        except Exception as exc:
            if entry is not None:
                log.error("secret_refresh_failed_serving_cached", extra={"stage": stage, "error": type(exc).__name__})
                return entry.value
            if optional:
                log.error("secret_refresh_failed_serving_cached", extra={"stage": stage, "error": type(exc).__name__})
                return None
            raise SecretUnavailableError(f"cannot read secret ({type(exc).__name__})") from exc
        with self._lock:
            self._cache[key] = _CacheEntry(value=value, fetched_at=now)
        return value
