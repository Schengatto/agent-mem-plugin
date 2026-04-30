from __future__ import annotations

import os
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.auth import generate_api_key
from app.config import get_settings


# ── helpers ──────────────────────────────────────────────────────────────────

def _make_obs_row(obs_id: int = 42) -> dict:
    return {
        "id": obs_id,
        "type": "observation",
        "content": "test content",
        "tags": ["tag1"],
        "scope": ["project/src"],
        "token_estimate": 10,
        "metadata": None,
        "project_id": None,
        "created_at": datetime(2026, 4, 30, 10, 0, 0, tzinfo=timezone.utc),
        "expires_at": None,
    }


# ── fixture ───────────────────────────────────────────────────────────────────

@pytest.fixture()
def obs_client():
    """TestClient with auth + observation CRUD mocked.

    Yields (client, raw_key, auth_row, mock_conn, mock_redis).
    Tests that need specific DB behaviour reconfigure mock_conn methods.
    """
    raw_key, key_hash = generate_api_key()
    device_id = uuid4()
    user_id = uuid4()
    auth_row = {"id": device_id, "user_id": user_id, "device_label": "test-device"}

    async def default_fetchrow(query, *args):
        if "device_keys" in query:
            return auth_row if (args and args[0] == key_hash) else None
        return None

    mock_conn = MagicMock()
    mock_conn.fetchrow = AsyncMock(side_effect=default_fetchrow)
    mock_conn.fetchval = AsyncMock(return_value=42)
    mock_conn.fetch = AsyncMock(return_value=[])
    mock_conn.execute = AsyncMock(return_value="DELETE 1")

    acquire_cm = MagicMock()
    acquire_cm.__aenter__ = AsyncMock(return_value=mock_conn)
    acquire_cm.__aexit__ = AsyncMock(return_value=False)

    mock_pool = MagicMock()
    mock_pool.close = AsyncMock()
    mock_pool.acquire = MagicMock(return_value=acquire_cm)

    mock_redis = MagicMock()
    mock_redis.aclose = AsyncMock()
    mock_redis.xadd = AsyncMock(return_value="1-0")

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
                yield c, raw_key, auth_row, mock_conn, mock_redis
    finally:
        if _had_key:
            os.environ["SECRET_KEY"] = _prev_key  # type: ignore[assignment]
        else:
            os.environ.pop("SECRET_KEY", None)
        get_settings.cache_clear()


# ── POST /api/v1/observations ─────────────────────────────────────────────────

class TestPostObservation:
    def test_returns_202(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={"content": "hello world"},
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 202

    def test_response_has_id_and_status_accepted(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={"content": "hello world"},
            headers={"X-API-Key": raw_key},
        )
        body = resp.json()
        assert body["id"] == 42
        assert body["status"] == "accepted"

    def test_publishes_to_embed_jobs_stream(self, obs_client):
        c, raw_key, _, _, mock_redis = obs_client
        c.post(
            "/api/v1/observations",
            json={"content": "embed me"},
            headers={"X-API-Key": raw_key},
        )
        mock_redis.xadd.assert_called_once()
        stream_name, fields = mock_redis.xadd.call_args[0]
        assert stream_name == "embed_jobs"
        assert "obs_id" in fields

    def test_scope_and_token_estimate_accepted(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={
                "content": "scoped content",
                "scope": ["project/src", "project/api"],
                "token_estimate": 42,
            },
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 202

    def test_all_obs_types_accepted(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        for obs_type in ("identity", "directive", "context", "bookmark", "observation"):
            resp = c.post(
                "/api/v1/observations",
                json={"content": "typed content", "type": obs_type},
                headers={"X-API-Key": raw_key},
            )
            assert resp.status_code == 202, f"type={obs_type} failed"

    def test_missing_content_returns_422(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={},
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 422

    def test_content_too_long_returns_422(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={"content": "x" * 20_001},
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 422

    def test_invalid_type_returns_422(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={"content": "typed content", "type": "invalid_type"},
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 422

    def test_extra_fields_rejected(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={"content": "hello", "unknown_field": "boom"},
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 422

    def test_unauthenticated_returns_401(self, obs_client):
        c, _, _, _, _ = obs_client
        resp = c.post("/api/v1/observations", json={"content": "hello"})
        assert resp.status_code == 401

    def test_invalid_key_returns_403(self, obs_client):
        c, _, _, _, _ = obs_client
        resp = c.post(
            "/api/v1/observations",
            json={"content": "hello"},
            headers={"X-API-Key": "bad-key"},
        )
        assert resp.status_code == 403


# ── GET /api/v1/observations/{obs_id} ────────────────────────────────────────

class TestGetObservation:
    def test_returns_200_with_obs_full(self, obs_client):
        c, raw_key, auth_row, mock_conn, _ = obs_client
        obs_row = _make_obs_row(42)

        async def fetchrow(query, *args):
            if "device_keys" in query:
                return auth_row
            if "observations" in query:
                return obs_row if (args and args[0] == 42) else None
            return None

        mock_conn.fetchrow = AsyncMock(side_effect=fetchrow)

        resp = c.get("/api/v1/observations/42", headers={"X-API-Key": raw_key})
        assert resp.status_code == 200
        body = resp.json()
        assert body["id"] == 42
        assert body["content"] == "test content"
        assert body["type"] == "observation"
        assert body["tags"] == ["tag1"]
        assert body["scope"] == ["project/src"]
        assert body["token_estimate"] == 10

    def test_not_found_returns_404(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        # default fetchrow returns None for observations queries
        resp = c.get("/api/v1/observations/999", headers={"X-API-Key": raw_key})
        assert resp.status_code == 404

    def test_invalid_obs_id_returns_422(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.get("/api/v1/observations/not-an-int", headers={"X-API-Key": raw_key})
        assert resp.status_code == 422


# ── GET /api/v1/observations?ids=... ─────────────────────────────────────────

class TestGetObservationsBatch:
    def test_returns_observations_for_ids(self, obs_client):
        c, raw_key, _, mock_conn, _ = obs_client
        mock_conn.fetch = AsyncMock(return_value=[_make_obs_row(42)])

        resp = c.get(
            "/api/v1/observations",
            params={"ids": [42]},
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert len(body) == 1
        assert body[0]["id"] == 42

    def test_empty_ids_returns_empty_list(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        resp = c.get("/api/v1/observations", headers={"X-API-Key": raw_key})
        assert resp.status_code == 200
        assert resp.json() == []

    def test_multiple_ids(self, obs_client):
        c, raw_key, _, mock_conn, _ = obs_client
        mock_conn.fetch = AsyncMock(return_value=[_make_obs_row(1), _make_obs_row(2)])

        resp = c.get(
            "/api/v1/observations",
            params={"ids": [1, 2]},
            headers={"X-API-Key": raw_key},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert len(body) == 2
        assert {item["id"] for item in body} == {1, 2}


# ── DELETE /api/v1/observations/{obs_id} ─────────────────────────────────────

class TestDeleteObservation:
    def test_returns_204(self, obs_client):
        c, raw_key, _, _, _ = obs_client
        # default execute returns "DELETE 1"
        resp = c.delete("/api/v1/observations/42", headers={"X-API-Key": raw_key})
        assert resp.status_code == 204

    def test_not_found_returns_404(self, obs_client):
        c, raw_key, _, mock_conn, _ = obs_client
        mock_conn.execute = AsyncMock(return_value="DELETE 0")

        resp = c.delete("/api/v1/observations/999", headers={"X-API-Key": raw_key})
        assert resp.status_code == 404
