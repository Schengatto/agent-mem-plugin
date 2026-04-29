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


@pytest.fixture()
def authed_client():
    """TestClient with properly mocked DB pool and a pre-generated API key.

    Yields (client, raw_key, fake_row). Pass raw_key in X-API-Key for valid
    auth. Pass any other string to trigger a 403 (fetchrow returns None for
    unknown hashes).
    """
    from uuid import uuid4

    from app.auth import generate_api_key, hash_api_key

    raw_key, key_hash = generate_api_key()
    fake_row = {
        "id": uuid4(),
        "user_id": uuid4(),
        "device_label": "test-device",
    }

    async def _fetchrow(query, h):
        return fake_row if h == key_hash else None

    mock_conn = MagicMock()
    mock_conn.fetchrow = AsyncMock(side_effect=_fetchrow)

    acquire_cm = MagicMock()
    acquire_cm.__aenter__ = AsyncMock(return_value=mock_conn)
    acquire_cm.__aexit__ = AsyncMock(return_value=False)

    mock_pool = MagicMock()
    mock_pool.close = AsyncMock()
    mock_pool.acquire = MagicMock(return_value=acquire_cm)

    mock_redis = MagicMock()
    mock_redis.aclose = AsyncMock()

    _had_key = "SECRET_KEY" in os.environ
    _prev_key = os.environ.get("SECRET_KEY")
    os.environ["SECRET_KEY"] = "test-secret-for-pytest"
    try:
        with (
            patch("asyncpg.create_pool", new_callable=AsyncMock, return_value=mock_pool),
            patch("app.main.Redis") as mock_redis_class,
        ):
            mock_redis_class.from_url.return_value = mock_redis
            from app.main import app

            with TestClient(app, raise_server_exceptions=True) as c:
                yield c, raw_key, fake_row
    finally:
        if _had_key:
            os.environ["SECRET_KEY"] = _prev_key  # type: ignore[assignment]
        else:
            os.environ.pop("SECRET_KEY", None)
        get_settings.cache_clear()
