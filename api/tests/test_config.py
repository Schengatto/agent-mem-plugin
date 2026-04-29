# api/tests/test_config.py
from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.config import Settings


def _minimal(overrides: dict | None = None) -> Settings:
    """Create Settings with only required fields."""
    base = {
        "DATABASE_URL": "postgresql+psycopg://u:p@localhost/db",
        "SECRET_KEY": "test-secret-key",
        "REDIS_URL": "redis://localhost:6379/0",
    }
    if overrides:
        base.update(overrides)
    return Settings(**{k: v for k, v in base.items()})


def test_settings_required_fields_present():
    s = _minimal()
    assert s.database_url.startswith("postgresql+psycopg://")
    assert s.secret_key == "test-secret-key"
    assert s.redis_url == "redis://localhost:6379/0"


def test_settings_defaults():
    s = _minimal()
    assert s.search_default_limit == 5
    assert s.search_max_limit == 20
    assert s.max_obs_tokens == 200
    assert s.deployment == "lan"
    assert s.memorymesh_llm_provider == "gemini"
    assert s.memorymesh_embed_provider == "gemini"
    assert s.memorymesh_llm_daily_token_cap == 500_000


def test_database_url_asyncpg_strips_driver_prefix():
    s = _minimal({"DATABASE_URL": "postgresql+psycopg://user:pass@localhost:5432/memorymesh"})
    assert s.database_url_asyncpg == "postgresql://user:pass@localhost:5432/memorymesh"


def test_database_url_asyncpg_unchanged_if_already_plain():
    s = _minimal({"DATABASE_URL": "postgresql://user:pass@localhost:5432/memorymesh"})
    assert s.database_url_asyncpg == "postgresql://user:pass@localhost:5432/memorymesh"


def test_secret_key_has_no_default():
    """SECRET_KEY must be explicitly provided — no default allowed."""
    with pytest.raises((ValidationError, Exception)):
        Settings(
            DATABASE_URL="postgresql+psycopg://u:p@localhost/db",
            REDIS_URL="redis://localhost:6379/0",
        )


def test_deployment_rejects_invalid_value():
    with pytest.raises(ValidationError):
        _minimal({"MEMORYMESH_DEPLOYMENT": "cloud"})
