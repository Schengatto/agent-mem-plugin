from __future__ import annotations

import os
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from app.config import get_settings


@pytest.fixture(autouse=True)
def clear_settings_cache():
    """Clear the lru_cache on get_settings() between tests.

    Without this, any test that calls get_settings() directly would receive
    a cached Settings instance built from a previous test's env state.
    """
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture()
def client():
    """FastAPI TestClient with asyncpg and Redis connections patched out.

    /health doesn't touch DB or Redis, so no real infrastructure needed here.
    F2-08 will add testcontainers for routes that do need real DB/Redis.

    SECRET_KEY is set for the duration of this fixture only — it must NOT leak
    into test_config.py's test_secret_key_has_no_default, which asserts that
    Settings raises ValidationError when SECRET_KEY is absent.
    """
    mock_pool = MagicMock()
    mock_pool.close = AsyncMock()
    mock_redis = MagicMock()
    mock_redis.aclose = AsyncMock()

    # Set SECRET_KEY only for the duration of this fixture.
    _had_key = "SECRET_KEY" in os.environ
    _prev_key = os.environ.get("SECRET_KEY")
    os.environ["SECRET_KEY"] = "test-secret-for-pytest"
    try:
        with (
            # main.py MUST use 'import asyncpg' (not 'from asyncpg import create_pool')
            # for this patch target to intercept the call correctly.
            patch("asyncpg.create_pool", new_callable=AsyncMock, return_value=mock_pool),
            # main.py MUST use 'from redis.asyncio import Redis' so Redis is bound
            # into app.main's namespace and this patch target is valid.
            patch("app.main.Redis") as mock_redis_class,
        ):
            mock_redis_class.from_url.return_value = mock_redis
            # Deferred import so patches are in place before app loads lifespan
            from app.main import app

            with TestClient(app, raise_server_exceptions=True) as c:
                yield c
    finally:
        if _had_key:
            os.environ["SECRET_KEY"] = _prev_key  # type: ignore[assignment]
        else:
            os.environ.pop("SECRET_KEY", None)
        get_settings.cache_clear()
