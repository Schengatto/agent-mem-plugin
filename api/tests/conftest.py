from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client():
    """FastAPI TestClient with asyncpg and Redis connections patched out.

    /health doesn't touch DB or Redis, so no real infrastructure needed here.
    F2-08 will add testcontainers for routes that do need real DB/Redis.
    """
    mock_pool = MagicMock()
    mock_pool.close = AsyncMock()
    mock_redis = MagicMock()
    mock_redis.aclose = AsyncMock()

    with (
        patch("asyncpg.create_pool", new_callable=AsyncMock, return_value=mock_pool),
        patch("app.main.Redis") as mock_redis_class,
    ):
        mock_redis_class.from_url.return_value = mock_redis
        # Deferred import so patches are in place before app loads lifespan
        from app.main import app

        with TestClient(app, raise_server_exceptions=True) as c:
            yield c
