from __future__ import annotations

import hashlib
import secrets

from fastapi.security import APIKeyHeader


def hash_api_key(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


def generate_api_key() -> tuple[str, str]:
    raw = secrets.token_urlsafe(32)
    return raw, hash_api_key(raw)


api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
