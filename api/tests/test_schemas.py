# api/tests/test_schemas.py
"""TDD tests for core Pydantic schemas.

These tests import Pydantic models only — no Settings or FastAPI app involved.
"""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError


# ---------------------------------------------------------------------------
# ObsCreate
# ---------------------------------------------------------------------------


class TestObsCreate:
    def test_valid_defaults(self):
        from app.schemas.observation import ObsCreate, ObsType

        obs = ObsCreate(content="hello world")
        assert obs.type == ObsType.observation
        assert obs.tags == []
        assert obs.scope == []
        assert obs.token_estimate is None
        assert obs.expires_at is None
        assert obs.metadata is None

    def test_extra_fields_forbidden(self):
        from app.schemas.observation import ObsCreate

        with pytest.raises(ValidationError):
            ObsCreate(content="test", unknown_field="value")

    def test_content_min_length_enforced(self):
        from app.schemas.observation import ObsCreate

        with pytest.raises(ValidationError):
            ObsCreate(content="")

    def test_content_max_length_enforced(self):
        from app.schemas.observation import ObsCreate

        with pytest.raises(ValidationError):
            ObsCreate(content="x" * 20_001)

    def test_type_defaults_to_observation(self):
        from app.schemas.observation import ObsCreate, ObsType

        obs = ObsCreate(content="some content")
        assert obs.type == ObsType.observation

    def test_type_explicit(self):
        from app.schemas.observation import ObsCreate, ObsType

        obs = ObsCreate(content="a directive", type=ObsType.directive)
        assert obs.type == ObsType.directive

    def test_full_creation(self):
        from app.schemas.observation import ObsCreate, ObsType

        obs = ObsCreate(
            type=ObsType.context,
            content="Some context content",
            tags=["tag1", "tag2"],
            scope=["project:foo"],
            token_estimate=42,
            expires_at=datetime(2030, 1, 1, tzinfo=timezone.utc),
            metadata={"key": "value"},
        )
        assert obs.content == "Some context content"
        assert obs.tags == ["tag1", "tag2"]
        assert obs.token_estimate == 42


# ---------------------------------------------------------------------------
# SearchRequest
# ---------------------------------------------------------------------------


class TestSearchRequest:
    def _project_id(self) -> UUID:
        return uuid4()

    def test_valid_creation(self):
        from app.schemas.search import SearchRequest

        req = SearchRequest(q="find something", project_id=self._project_id())
        assert req.limit == 5
        assert req.mode == "hybrid"
        assert req.expand is False
        assert req.scope == []

    def test_extra_fields_forbidden(self):
        from app.schemas.search import SearchRequest

        with pytest.raises(ValidationError):
            SearchRequest(q="query", project_id=self._project_id(), bogus="x")

    def test_limit_ge_1_enforced(self):
        from app.schemas.search import SearchRequest

        with pytest.raises(ValidationError):
            SearchRequest(q="query", project_id=self._project_id(), limit=0)

    def test_limit_le_20_enforced(self):
        from app.schemas.search import SearchRequest

        with pytest.raises(ValidationError):
            SearchRequest(q="query", project_id=self._project_id(), limit=21)

    def test_q_min_length_enforced(self):
        from app.schemas.search import SearchRequest

        with pytest.raises(ValidationError):
            SearchRequest(q="", project_id=self._project_id())

    def test_mode_literal_validation(self):
        from app.schemas.search import SearchRequest

        with pytest.raises(ValidationError):
            SearchRequest(q="query", project_id=self._project_id(), mode="fulltext")

    def test_mode_valid_values(self):
        from app.schemas.search import SearchRequest

        pid = self._project_id()
        for mode in ("bm25", "vector", "hybrid"):
            req = SearchRequest(q="query", project_id=pid, mode=mode)
            assert req.mode == mode


# ---------------------------------------------------------------------------
# VocabUpsertRequest
# ---------------------------------------------------------------------------


class TestVocabUpsertRequest:
    def test_valid_creation(self):
        from app.schemas.vocab import VocabUpsertRequest

        req = VocabUpsertRequest(
            term="JWT",
            category="abbreviation",
            definition="JSON Web Token",
        )
        assert req.term == "JWT"
        assert req.detail is None
        assert req.metadata is None

    def test_extra_fields_forbidden(self):
        from app.schemas.vocab import VocabUpsertRequest

        with pytest.raises(ValidationError):
            VocabUpsertRequest(
                term="JWT",
                category="abbreviation",
                definition="JSON Web Token",
                unknown="x",
            )

    def test_definition_max_length_enforced(self):
        from app.schemas.vocab import VocabUpsertRequest

        with pytest.raises(ValidationError):
            VocabUpsertRequest(
                term="JWT",
                category="abbreviation",
                definition="x" * 81,
            )

    def test_term_min_length_enforced(self):
        from app.schemas.vocab import VocabUpsertRequest

        with pytest.raises(ValidationError):
            VocabUpsertRequest(
                term="",
                category="entity",
                definition="some definition",
            )

    def test_all_categories_accepted(self):
        from app.schemas.vocab import VocabUpsertRequest

        for cat in ("entity", "convention", "decision", "abbreviation", "pattern"):
            req = VocabUpsertRequest(
                term="T", category=cat, definition="def"
            )
            assert req.category == cat


# ---------------------------------------------------------------------------
# VocabEntry
# ---------------------------------------------------------------------------


class TestVocabEntry:
    def test_valid_creation(self):
        from app.schemas.vocab import VocabEntry

        entry = VocabEntry(
            id=1,
            term="JWT",
            shortcode="jwt",
            category="abbreviation",
            definition="JSON Web Token",
            detail="Used for auth",
            usage_count=5,
            confidence=0.9,
        )
        assert entry.id == 1
        assert entry.shortcode == "jwt"

    def test_category_literal_invalid(self):
        from app.schemas.vocab import VocabEntry

        with pytest.raises(ValidationError):
            VocabEntry(
                id=1,
                term="JWT",
                shortcode=None,
                category="unknown_category",
                definition="JSON Web Token",
                detail=None,
                usage_count=0,
                confidence=0.0,
            )

    def test_shortcode_optional(self):
        from app.schemas.vocab import VocabEntry

        entry = VocabEntry(
            id=2,
            term="Convention",
            shortcode=None,
            category="convention",
            definition="A naming rule",
            detail=None,
            usage_count=1,
            confidence=0.8,
        )
        assert entry.shortcode is None


# ---------------------------------------------------------------------------
# ManifestResponse
# ---------------------------------------------------------------------------


class TestManifestResponse:
    def test_valid_construction(self):
        from app.schemas.manifest import ManifestEntry, ManifestResponse
        from app.schemas.observation import ObsType

        entries = [
            ManifestEntry(
                id=1,
                obs_id=10,
                type=ObsType.identity,
                one_liner="User is Alice",
                priority=100,
                scope_path="global",
                is_root=True,
            ),
            ManifestEntry(
                id=2,
                obs_id=11,
                type=ObsType.directive,
                one_liner="Never do X",
                priority=90,
                scope_path="project:foo",
                is_root=False,
            ),
        ]
        resp = ManifestResponse(entries=entries, etag="abc123", token_estimate=150)
        assert len(resp.entries) == 2
        assert resp.etag == "abc123"
        assert resp.token_estimate == 150

    def test_empty_entries(self):
        from app.schemas.manifest import ManifestResponse

        resp = ManifestResponse(entries=[], etag="0", token_estimate=0)
        assert resp.entries == []

    def test_delta_response(self):
        from app.schemas.manifest import ManifestDeltaResponse, ManifestEntry
        from app.schemas.observation import ObsType

        added = [
            ManifestEntry(
                id=3,
                obs_id=30,
                type=ObsType.context,
                one_liner="New context",
                priority=50,
                scope_path="project:bar",
                is_root=False,
            )
        ]
        delta = ManifestDeltaResponse(
            added=added,
            removed=[10, 11],
            etag="xyz",
            full_refresh_required=False,
        )
        assert len(delta.added) == 1
        assert delta.removed == [10, 11]
        assert delta.full_refresh_required is False


# ---------------------------------------------------------------------------
# ObsFull
# ---------------------------------------------------------------------------


class TestObsFull:
    def test_valid_construction_all_fields(self):
        from app.schemas.observation import ObsFull, ObsType

        obs = ObsFull(
            id=42,
            type=ObsType.bookmark,
            content="https://example.com",
            tags=["web", "bookmark"],
            scope=["project:x"],
            token_estimate=10,
            metadata={"url": "https://example.com"},
            created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
            expires_at=None,
        )
        assert obs.id == 42
        assert obs.type == ObsType.bookmark
        assert obs.token_estimate == 10
        assert obs.expires_at is None

    def test_optional_fields_can_be_none(self):
        from app.schemas.observation import ObsFull, ObsType

        obs = ObsFull(
            id=1,
            type=ObsType.observation,
            content="plain obs",
            tags=[],
            scope=[],
            token_estimate=None,
            metadata=None,
            created_at=datetime(2026, 4, 1, tzinfo=timezone.utc),
            expires_at=None,
        )
        assert obs.token_estimate is None
        assert obs.metadata is None
