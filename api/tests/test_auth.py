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
