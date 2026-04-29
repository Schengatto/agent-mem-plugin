from __future__ import annotations

import hashlib


class TestHashApiKey:
    def test_hash_matches_sha256(self):
        from app.auth import hash_api_key

        raw = "test-key-value"
        assert hash_api_key(raw) == hashlib.sha256(raw.encode()).hexdigest()

    def test_hash_output_is_64_char_hex(self):
        from app.auth import hash_api_key

        result = hash_api_key("anything")
        assert len(result) == 64
        assert all(c in "0123456789abcdef" for c in result)

    def test_hash_is_deterministic(self):
        from app.auth import hash_api_key

        assert hash_api_key("key") == hash_api_key("key")


class TestGenerateApiKey:
    def test_format(self):
        from app.auth import generate_api_key

        raw, key_hash = generate_api_key()
        assert isinstance(raw, str) and len(raw) > 0
        assert len(key_hash) == 64

    def test_unique(self):
        from app.auth import generate_api_key

        _, h1 = generate_api_key()
        _, h2 = generate_api_key()
        assert h1 != h2

    def test_hash_matches_raw(self):
        from app.auth import generate_api_key, hash_api_key

        raw, key_hash = generate_api_key()
        assert hash_api_key(raw) == key_hash


class TestAuthUser:
    def test_construction(self):
        from uuid import uuid4

        from app.schemas.auth import AuthUser

        uid = uuid4()
        did = uuid4()
        user = AuthUser(user_id=uid, device_id=did, device_label="laptop")
        assert user.user_id == uid
        assert user.device_id == did
        assert user.device_label == "laptop"

    def test_uuid_fields_are_uuid_type(self):
        from uuid import UUID, uuid4

        from app.schemas.auth import AuthUser

        user = AuthUser(user_id=uuid4(), device_id=uuid4(), device_label="x")
        assert isinstance(user.user_id, UUID)
        assert isinstance(user.device_id, UUID)


class TestAuthMiddleware:
    def test_missing_key_returns_401(self, client):
        resp = client.get("/api/v1/observations/ping")
        assert resp.status_code == 401
        assert resp.json()["detail"] == "authentication_required"

    def test_bad_key_returns_403(self, authed_client):
        c, _, _ = authed_client
        resp = c.get("/api/v1/observations/ping", headers={"X-API-Key": "totally-wrong"})
        assert resp.status_code == 403
        assert resp.json()["detail"] == "invalid_or_revoked_key"

    def test_valid_key_passes_through(self, authed_client):
        c, raw_key, _ = authed_client
        resp = c.get("/api/v1/observations/ping", headers={"X-API-Key": raw_key})
        assert resp.status_code == 501  # stub returns 501, but auth succeeded

    def test_revoked_key_returns_403(self, authed_client):
        # A revoked key's hash is excluded by `revoked_at IS NULL` in the SQL query,
        # so fetchrow returns None — same outcome as a completely unknown key.
        c, _, _ = authed_client
        resp = c.get("/api/v1/observations/ping", headers={"X-API-Key": "revoked-key-value"})
        assert resp.status_code == 403
        assert resp.json()["detail"] == "invalid_or_revoked_key"

    def test_health_no_auth_required(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
