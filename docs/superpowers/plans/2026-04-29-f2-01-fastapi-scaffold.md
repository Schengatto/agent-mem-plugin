# F2-01 FastAPI Scaffold — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a fully-bootable FastAPI skeleton with expanded config, core Pydantic schemas, service/router stubs, and a working `/health` endpoint — so F2-02 (auth middleware) can immediately mount on a running app.

**Architecture:** `main.py` wires a FastAPI app with asyncpg + Redis pool in its lifespan context, imports 7 routers (1 real, 6 stubs returning 501), and exposes `/health`. Config expands from the current Alembic-only minimal to the full production settings set. Schemas define data contracts used across all F2+ tasks. Services are empty class stubs with `pass` bodies.

**Tech Stack:** FastAPI 0.136, asyncpg 0.31, redis-py 5.2 (async), Pydantic 2.13, pydantic-settings 2.7, structlog 24, tiktoken 0.8, pytest 8, pytest-asyncio 0.23, httpx 0.28 (TestClient).

---

## File Map

| Path | Action | Responsibility |
|---|---|---|
| `api/requirements.in` | CREATE | Source-of-truth for pip-compile (F12) |
| `api/requirements.txt` | MODIFY | Full dep list, expanded from Sprint 1 subset |
| `api/Dockerfile` | MODIFY | Remove `--require-hashes` + `requirements-hashes.txt` ref |
| `api/static/.gitkeep` | CREATE | Placeholder so Dockerfile `COPY static/` doesn't fail |
| `api/app/config.py` | MODIFY | Expand from 3 fields to full settings set |
| `api/app/main.py` | CREATE | FastAPI app, lifespan, middleware, router wiring |
| `api/app/dependencies.py` | CREATE | `get_db`, `get_redis`, `get_cfg`, stub guards |
| `api/app/routers/__init__.py` | CREATE | Empty package marker |
| `api/app/routers/health.py` | CREATE | `GET /health` — only real endpoint this task |
| `api/app/routers/observations.py` | CREATE | Stub — `GET /observations/ping` → 501 |
| `api/app/routers/search.py` | CREATE | Stub — `GET /search/ping` → 501 |
| `api/app/routers/manifest.py` | CREATE | Stub — `GET /manifest/ping` → 501 |
| `api/app/routers/vocab.py` | CREATE | Stub — `GET /vocab/ping` → 501 |
| `api/app/routers/sessions.py` | CREATE | Stub — `GET /sessions/ping` → 501 |
| `api/app/routers/mcp.py` | CREATE | Stub — `GET /mcp/ping` → 501 |
| `api/app/services/__init__.py` | CREATE | Empty package marker |
| `api/app/services/memory.py` | CREATE | Stub class `MemoryService` |
| `api/app/services/distillation.py` | CREATE | Stub class `DistillationService` |
| `api/app/services/extraction.py` | CREATE | Stub class `ExtractionService` |
| `api/app/services/compression.py` | CREATE | Stub class `CompressionService` |
| `api/app/services/vocab.py` | CREATE | Stub class `VocabService` |
| `api/app/schemas/__init__.py` | CREATE | Empty package marker |
| `api/app/schemas/observation.py` | CREATE | `ObsType`, `ObsCreate`, `ObsFull`, `ObsCompact` |
| `api/app/schemas/search.py` | CREATE | `SearchRequest`, `SearchResult`, `SearchResponse` |
| `api/app/schemas/manifest.py` | CREATE | `ManifestEntry`, `ManifestResponse`, `ManifestDeltaResponse` |
| `api/app/schemas/vocab.py` | CREATE | `VocabEntry`, `VocabLookupResponse`, `VocabUpsertRequest` |
| `api/tests/__init__.py` | CREATE | Empty package marker |
| `api/tests/conftest.py` | CREATE | Patched FastAPI TestClient fixture |
| `api/tests/test_config.py` | CREATE | Config loading + `database_url_asyncpg` property |
| `api/tests/test_schemas.py` | CREATE | Pydantic validation for all schema files |
| `api/tests/test_health.py` | CREATE | `GET /health` → 200, stubs → 501 |

---

## Task 1: Test infrastructure setup

**Files:**
- Create: `api/tests/__init__.py`
- Create: `api/tests/conftest.py`
- Create: `api/pytest.ini`

- [ ] **Step 1.1: Create `api/tests/__init__.py`**

```python
```
(empty file)

- [ ] **Step 1.2: Create `api/pytest.ini`**

```ini
[pytest]
testpaths = tests
asyncio_mode = auto
```

- [ ] **Step 1.3: Create `api/tests/conftest.py`**

This fixture patches asyncpg and Redis so tests don't need real connections. `asyncpg.create_pool` is a coroutine (must use `AsyncMock`). `Redis.from_url` is a regular classmethod that returns a client synchronously (no `await`).

```python
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
```

---

## Task 2: Expand `requirements.txt` and create `requirements.in`

**Files:**
- Modify: `api/requirements.txt`
- Create: `api/requirements.in`

- [ ] **Step 2.1: Replace `api/requirements.txt` with the full F2 set**

```
# MemoryMesh API — runtime + dev dependencies
# Sprint 2 (F2-01): full FastAPI stack added.
#
# Hash pinning (--require-hashes) is deferred to F12 (Security Hardening).
# To regenerate: docker run --rm -v $(pwd):/w -w /w python:3.14.4-slim \
#   pip install pip-tools && pip-compile --generate-hashes requirements.in
#
# See docs/DEPENDENCIES.md for ADR on each version choice.

# ─── Web framework ────────────────────────────────────────────────────────────
fastapi==0.136.*
uvicorn[standard]==0.32.*

# ─── Validation / config ──────────────────────────────────────────────────────
pydantic==2.13.*
pydantic-settings==2.7.*

# ─── Database ─────────────────────────────────────────────────────────────────
asyncpg==0.31.*            # async PG driver (FastAPI/workers)
pgvector==0.3.*            # vector type support for asyncpg
sqlalchemy==2.0.*          # metadata + Alembic MigrationContext
alembic==1.14.*            # schema migrations
psycopg[binary]==3.2.*     # sync driver used only by Alembic

# ─── Redis ────────────────────────────────────────────────────────────────────
redis==5.2.*               # redis-py with asyncio support

# ─── HTTP client ──────────────────────────────────────────────────────────────
httpx==0.28.*              # safe_fetch (F2-14) + TestClient

# ─── Logging ──────────────────────────────────────────────────────────────────
structlog==24.*

# ─── Token estimation ─────────────────────────────────────────────────────────
tiktoken==0.8.*            # cl100k_base encoder (Strategies 17, 18)

# ─── mDNS broadcaster (F1-09) ─────────────────────────────────────────────────
zeroconf==0.135.*

# ─── Test dependencies (used via: docker compose run --rm api pytest tests/) ──
pytest==8.*
pytest-asyncio==0.23.*
anyio[trio]==4.*           # required by pytest-asyncio backend
```

- [ ] **Step 2.2: Create `api/requirements.in`**

This is the human-maintained input file for `pip-compile --generate-hashes` (run in F12):

```
fastapi==0.136.*
uvicorn[standard]==0.32.*
pydantic==2.13.*
pydantic-settings==2.7.*
asyncpg==0.31.*
pgvector==0.3.*
sqlalchemy==2.0.*
alembic==1.14.*
psycopg[binary]==3.2.*
redis==5.2.*
httpx==0.28.*
structlog==24.*
tiktoken==0.8.*
zeroconf==0.135.*
pytest==8.*
pytest-asyncio==0.23.*
anyio[trio]==4.*
```

---

## Task 3: Fix `Dockerfile` and create `api/static/.gitkeep`

**Files:**
- Modify: `api/Dockerfile`
- Create: `api/static/.gitkeep`

- [ ] **Step 3.1: Create `api/static/.gitkeep`**

```
```
(empty file — the Dockerfile does `COPY --chown=mm:mm static/ ./app/static/`; without this dir the build fails)

- [ ] **Step 3.2: Modify `api/Dockerfile` Stage 1 — remove `--require-hashes`**

Find these lines in Stage 1:

```dockerfile
# Copy solo requirements per maximizzare docker layer cache
COPY requirements.txt requirements-hashes.txt ./

# Install con --require-hashes per supply chain integrity.
# requirements-hashes.txt è generato via `pip-compile --generate-hashes requirements.in`
RUN pip install --user --require-hashes -r requirements-hashes.txt
```

Replace with:

```dockerfile
# Copy solo requirements per maximizzare docker layer cache
COPY requirements.txt ./

# TODO F12: switch to --require-hashes -r requirements-hashes.txt
# To generate: docker run --rm -v $(pwd):/w -w /w python:3.14.4-slim \
#   sh -c "pip install pip-tools && pip-compile --generate-hashes requirements.in"
RUN pip install --user -r requirements.txt
```

---

## Task 4: Expand `config.py` (TDD)

**Files:**
- Modify: `api/app/config.py`
- Create: `api/tests/test_config.py`

- [ ] **Step 4.1: Write the failing tests**

```python
# api/tests/test_config.py
from __future__ import annotations

import os

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
```

- [ ] **Step 4.2: Run tests — expect failures**

```bash
cd api && python -m pytest tests/test_config.py -v
```

Expected: most tests fail with `ImportError` or `ValidationError` because config.py doesn't have these fields yet.

- [ ] **Step 4.3: Expand `api/app/config.py`**

Replace the entire file:

```python
"""Configurazione centralizzata FastAPI + Alembic.

Espanso in F2-01 con il set completo di variabili. La configurazione Alembic
(database_url, database_admin_url, fp_logging_enabled) è mantenuta compatibile
con gli alias esistenti usati da alembic/env.py.
"""
from __future__ import annotations

import functools
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ── DB (Alembic-compat aliases) ───────────────────────────────────────
    database_url: str = Field(
        alias="DATABASE_URL",
        default="postgresql+psycopg://postgres:postgres@localhost:5432/memorymesh",
    )
    database_admin_url: str | None = Field(default=None, alias="DATABASE_ADMIN_URL")
    fp_logging_enabled: bool = Field(default=False, alias="FP_LOGGING_ENABLED")

    # ── Core runtime ──────────────────────────────────────────────────────
    redis_url: str = Field(default="redis://redis:6379/0", alias="REDIS_URL")
    secret_key: str = Field(alias="SECRET_KEY")
    ollama_url: str = Field(default="http://ollama:11434", alias="OLLAMA_URL")
    deployment: Literal["lan", "vpn", "public"] = Field(
        default="lan", alias="MEMORYMESH_DEPLOYMENT"
    )

    # ── Manifest / search ────────────────────────────────────────────────
    manifest_default_budget: int = Field(default=3000, alias="MANIFEST_DEFAULT_BUDGET")
    search_default_limit: int = Field(default=5, alias="SEARCH_DEFAULT_LIMIT")
    search_max_limit: int = Field(default=20, alias="SEARCH_MAX_LIMIT")
    search_cache_ttl: int = Field(default=300, alias="SEARCH_CACHE_TTL")

    # ── Distillation thresholds ──────────────────────────────────────────
    merge_similarity_threshold: float = Field(
        default=0.92, alias="MERGE_SIMILARITY_THRESHOLD"
    )
    decay_observation_factor: float = Field(
        default=0.85, alias="DECAY_OBSERVATION_FACTOR"
    )
    decay_context_factor: float = Field(default=0.97, alias="DECAY_CONTEXT_FACTOR")
    tighten_min_words: int = Field(default=150, alias="TIGHTEN_MIN_WORDS")
    compress_threshold_tokens: int = Field(
        default=8000, alias="COMPRESS_THRESHOLD_TOKENS"
    )
    vocab_extract_enabled: bool = Field(default=True, alias="VOCAB_EXTRACT_ENABLED")

    # ── Token-first (Strategies 8-18) ────────────────────────────────────
    max_obs_tokens: int = Field(default=200, alias="MAX_OBS_TOKENS")
    shortcode_threshold: int = Field(default=10, alias="SHORTCODE_THRESHOLD")
    root_relevance_threshold: float = Field(
        default=0.85, alias="ROOT_RELEVANCE_THRESHOLD"
    )
    root_access_count_threshold: int = Field(
        default=50, alias="ROOT_ACCESS_COUNT_THRESHOLD"
    )
    lru_eviction_days: int = Field(default=60, alias="LRU_EVICTION_DAYS")
    bm25_skip_threshold: float = Field(default=0.3, alias="BM25_SKIP_THRESHOLD")
    search_rerank_enabled: bool = Field(default=True, alias="SEARCH_RERANK_ENABLED")
    fingerprint_min_sessions: int = Field(
        default=3, alias="FINGERPRINT_MIN_SESSIONS"
    )

    # ── LLM / Embed providers ────────────────────────────────────────────
    memorymesh_llm_provider: Literal["gemini", "ollama", "openai", "anthropic"] = Field(
        default="gemini", alias="MEMORYMESH_LLM_PROVIDER"
    )
    memorymesh_embed_provider: Literal["gemini", "ollama"] = Field(
        default="gemini", alias="MEMORYMESH_EMBED_PROVIDER"
    )
    memorymesh_llm_daily_token_cap: int = Field(
        default=500_000, alias="MEMORYMESH_LLM_DAILY_TOKEN_CAP"
    )

    # ── Derived (not from env) ────────────────────────────────────────────
    @property
    def database_url_asyncpg(self) -> str:
        """asyncpg uses 'postgresql://' — strip the SQLAlchemy driver prefix."""
        return self.database_url.replace("postgresql+psycopg://", "postgresql://")


@functools.lru_cache
def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 4.4: Run tests — expect all pass**

```bash
cd api && python -m pytest tests/test_config.py -v
```

Expected output:
```
tests/test_config.py::test_settings_required_fields_present PASSED
tests/test_config.py::test_settings_defaults PASSED
tests/test_config.py::test_database_url_asyncpg_strips_driver_prefix PASSED
tests/test_config.py::test_database_url_asyncpg_unchanged_if_already_plain PASSED
tests/test_config.py::test_secret_key_has_no_default PASSED
tests/test_config.py::test_deployment_rejects_invalid_value PASSED
6 passed in 0.XXs
```

- [ ] **Step 4.5: Commit**

```bash
git add api/tests/__init__.py api/tests/conftest.py api/pytest.ini \
        api/requirements.txt api/requirements.in \
        api/Dockerfile api/static/.gitkeep \
        api/app/config.py api/tests/test_config.py
git commit -m "feat(F2-01): expand config, requirements, fix Dockerfile, test infra"
```

---

## Task 5: Core schemas (TDD)

**Files:**
- Create: `api/app/schemas/__init__.py`
- Create: `api/app/schemas/observation.py`
- Create: `api/app/schemas/search.py`
- Create: `api/app/schemas/manifest.py`
- Create: `api/app/schemas/vocab.py`
- Create: `api/tests/test_schemas.py`

- [ ] **Step 5.1: Write the failing tests**

```python
# api/tests/test_schemas.py
from __future__ import annotations

from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.schemas.observation import ObsCompact, ObsCreate, ObsFull, ObsType
from app.schemas.manifest import ManifestDeltaResponse, ManifestEntry, ManifestResponse
from app.schemas.search import SearchRequest, SearchResponse, SearchResult
from app.schemas.vocab import VocabEntry, VocabLookupResponse, VocabUpsertRequest


# ── ObsCreate ──────────────────────────────────────────────────────────────────

def test_obs_create_minimal():
    obs = ObsCreate(content="hello world")
    assert obs.type == ObsType.observation
    assert obs.scope == []
    assert obs.tags == []
    assert obs.metadata is None


def test_obs_create_with_type_enum():
    obs = ObsCreate(content="directive text", type="directive")
    assert obs.type == ObsType.directive


def test_obs_create_rejects_empty_content():
    with pytest.raises(ValidationError):
        ObsCreate(content="")


def test_obs_create_rejects_extra_fields():
    with pytest.raises(ValidationError):
        ObsCreate(content="ok", unknown_field="x")


def test_obs_create_rejects_invalid_type():
    with pytest.raises(ValidationError):
        ObsCreate(content="ok", type="bogus")


# ── ObsCompact — must never carry full content ────────────────────────────────

def test_obs_compact_has_no_content_field():
    """ObsCompact is used in /search and /manifest — full content must never leak."""
    assert "content" not in ObsCompact.model_fields


def test_obs_compact_instantiation():
    c = ObsCompact(id=1, type=ObsType.context, one_liner="did X")
    assert c.score is None
    assert c.age_hours is None


# ── ObsFull ────────────────────────────────────────────────────────────────────

def test_obs_full_has_content():
    assert "content" in ObsFull.model_fields


# ── SearchRequest ──────────────────────────────────────────────────────────────

def test_search_request_defaults():
    req = SearchRequest(q="test query", project_id=uuid4())
    assert req.limit == 5
    assert req.mode == "hybrid"
    assert req.expand is False
    assert req.scope == []


def test_search_request_rejects_empty_query():
    with pytest.raises(ValidationError):
        SearchRequest(q="", project_id=uuid4())


def test_search_request_limit_max():
    with pytest.raises(ValidationError):
        SearchRequest(q="test", project_id=uuid4(), limit=21)


def test_search_request_rejects_invalid_mode():
    with pytest.raises(ValidationError):
        SearchRequest(q="test", project_id=uuid4(), mode="fulltext")


# ── ManifestEntry ──────────────────────────────────────────────────────────────

def test_manifest_entry_fields():
    entry = ManifestEntry(
        id=1, obs_id=10, type=ObsType.directive,
        one_liner="use tests", priority=1,
        scope_path="/api/routers", is_root=False,
    )
    assert entry.scope_path == "/api/routers"


def test_manifest_delta_full_refresh_flag():
    delta = ManifestDeltaResponse(added=[], removed=[], etag="abc123", full_refresh_required=True)
    assert delta.full_refresh_required is True


# ── VocabUpsertRequest ─────────────────────────────────────────────────────────

def test_vocab_upsert_definition_max_80_chars():
    with pytest.raises(ValidationError):
        VocabUpsertRequest(
            term="MyService",
            category="entity",
            definition="x" * 81,
        )


def test_vocab_upsert_valid():
    req = VocabUpsertRequest(
        term="AuthService",
        category="entity",
        definition="Handles JWT auth",
    )
    assert req.detail is None
    assert req.metadata is None


def test_vocab_upsert_rejects_invalid_category():
    with pytest.raises(ValidationError):
        VocabUpsertRequest(term="X", category="unknown", definition="def")


def test_vocab_lookup_not_found():
    resp = VocabLookupResponse(found=False, entry=None, match_type=None)
    assert resp.found is False
```

- [ ] **Step 5.2: Run tests — expect ImportError**

```bash
cd api && python -m pytest tests/test_schemas.py -v
```

Expected: `ImportError: No module named 'app.schemas.observation'` (files don't exist yet)

- [ ] **Step 5.3: Create `api/app/schemas/__init__.py`**

```python
```
(empty)

- [ ] **Step 5.4: Create `api/app/schemas/observation.py`**

```python
from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class ObsType(str, Enum):
    identity = "identity"
    directive = "directive"
    context = "context"
    bookmark = "bookmark"
    observation = "observation"


class ObsCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: ObsType = ObsType.observation
    content: str = Field(min_length=1, max_length=20_000)
    tags: list[str] = Field(default_factory=list)
    scope: list[str] = Field(default_factory=list)
    token_estimate: int | None = None
    expires_at: datetime | None = None
    metadata: dict | None = None


class ObsCompact(BaseModel):
    """Used in /search and /manifest responses — never includes full content."""

    id: int
    type: ObsType
    one_liner: str
    score: float | None = None
    age_hours: int | None = None


class ObsFull(BaseModel):
    """Used only in /observations/batch — includes full content."""

    id: int
    type: ObsType
    content: str
    tags: list[str]
    scope: list[str]
    token_estimate: int | None
    metadata: dict | None
    created_at: datetime
    expires_at: datetime | None
```

- [ ] **Step 5.5: Create `api/app/schemas/search.py`**

```python
from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.observation import ObsType


class SearchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    q: str = Field(min_length=1, max_length=500)
    project_id: UUID
    scope: list[str] = Field(default_factory=list)
    limit: int = Field(default=5, ge=1, le=20)
    mode: Literal["bm25", "vector", "hybrid"] = "hybrid"
    expand: bool = False


class SearchResult(BaseModel):
    id: int
    type: ObsType
    one_liner: str
    score: float
    mode_used: str
    rerank_applied: bool


class SearchResponse(BaseModel):
    results: list[SearchResult]
    total_ms: int
```

- [ ] **Step 5.6: Create `api/app/schemas/manifest.py`**

```python
from __future__ import annotations

from pydantic import BaseModel

from app.schemas.observation import ObsType


class ManifestEntry(BaseModel):
    id: int
    obs_id: int
    type: ObsType
    one_liner: str
    priority: int
    scope_path: str
    is_root: bool


class ManifestResponse(BaseModel):
    entries: list[ManifestEntry]
    etag: str
    token_estimate: int


class ManifestDeltaResponse(BaseModel):
    added: list[ManifestEntry]
    removed: list[int]  # obs_ids removed since since_etag
    etag: str
    full_refresh_required: bool
```

- [ ] **Step 5.7: Create `api/app/schemas/vocab.py`**

```python
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

VocabCategory = Literal["entity", "convention", "decision", "abbreviation", "pattern"]


class VocabEntry(BaseModel):
    id: int
    term: str
    shortcode: str | None
    category: VocabCategory
    definition: str = Field(max_length=80)
    detail: str | None
    usage_count: int
    confidence: float


class VocabLookupResponse(BaseModel):
    found: bool
    entry: VocabEntry | None
    match_type: Literal["exact", "fuzzy", "semantic"] | None


class VocabUpsertRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    term: str = Field(min_length=1, max_length=100)
    category: VocabCategory
    definition: str = Field(min_length=1, max_length=80)
    detail: str | None = None
    metadata: dict | None = None
```

- [ ] **Step 5.8: Run tests — expect all pass**

```bash
cd api && python -m pytest tests/test_schemas.py -v
```

Expected:
```
tests/test_schemas.py::test_obs_create_minimal PASSED
tests/test_schemas.py::test_obs_create_with_type_enum PASSED
...
21 passed in 0.XXs
```

- [ ] **Step 5.9: Commit**

```bash
git add api/app/schemas/ api/tests/test_schemas.py
git commit -m "feat(F2-01): add core Pydantic schemas with validation tests"
```

---

## Task 6: `dependencies.py` stubs

**Files:**
- Create: `api/app/dependencies.py`

No separate tests here — these are DI stubs whose full behavior is tested in F2-02 (auth) and F2-04 (projects). The guard stubs raise `NotImplementedError` to prevent accidental use before implementation.

- [ ] **Step 6.1: Create `api/app/dependencies.py`**

```python
"""FastAPI dependency injection providers.

get_db and get_redis are wired to app.state in main.py lifespan.
get_current_user and get_project are stubs — implemented in F2-02 and F2-04.
"""
from __future__ import annotations

from typing import AsyncGenerator

import asyncpg
from fastapi import Depends, Request
from redis.asyncio import Redis

from app.config import Settings, get_settings


async def get_db(request: Request) -> AsyncGenerator[asyncpg.Connection, None]:
    """Yield a connection from the asyncpg pool stored in app.state."""
    async with request.app.state.db_pool.acquire() as conn:
        yield conn


def get_redis(request: Request) -> Redis:
    """Return the Redis client stored in app.state."""
    return request.app.state.redis


def get_cfg(settings: Settings = Depends(get_settings)) -> Settings:
    return settings


async def get_current_user():
    """Stub — implemented in F2-02 (API key auth middleware)."""
    raise NotImplementedError("get_current_user not implemented until F2-02")


async def get_project():
    """Stub — implemented in F2-04 (projects CRUD)."""
    raise NotImplementedError("get_project not implemented until F2-04")
```

- [ ] **Step 6.2: Commit**

```bash
git add api/app/dependencies.py
git commit -m "feat(F2-01): add dependencies.py with get_db, get_redis stubs"
```

---

## Task 7: Service stubs

**Files:**
- Create: `api/app/services/__init__.py`
- Create: `api/app/services/memory.py`
- Create: `api/app/services/distillation.py`
- Create: `api/app/services/extraction.py`
- Create: `api/app/services/compression.py`
- Create: `api/app/services/vocab.py`

Services are class stubs. Using classes (not bare functions) so F3-F6 can inject them via DI and test them in isolation.

- [ ] **Step 7.1: Create `api/app/services/__init__.py`**

```python
```
(empty)

- [ ] **Step 7.2: Create `api/app/services/memory.py`**

```python
"""Hybrid search and manifest retrieval — implemented in F3."""
from __future__ import annotations


class MemoryService:
    """Hybrid search (BM25 → vector → rerank) and manifest assembly."""

    async def hybrid_search(self, *args, **kwargs):
        raise NotImplementedError("implemented in F3-04/F3-06")

    async def get_manifest(self, *args, **kwargs):
        raise NotImplementedError("implemented in F2-05")
```

- [ ] **Step 7.3: Create `api/app/services/distillation.py`**

```python
"""Nightly distillation pipeline — implemented in F5."""
from __future__ import annotations


class DistillationService:
    """Prune → merge → tighten → decay → vocab_extract → rebuild manifest."""

    async def run_pipeline(self, *args, **kwargs):
        raise NotImplementedError("implemented in F5-04")
```

- [ ] **Step 7.4: Create `api/app/services/extraction.py`**

```python
"""Structured fact extraction via LlmCallback — implemented in F5."""
from __future__ import annotations


class ExtractionService:
    """Extract durable facts from raw observations via LLM."""

    async def extract_from_messages(self, *args, **kwargs):
        raise NotImplementedError("implemented in F5-02")
```

- [ ] **Step 7.5: Create `api/app/services/compression.py`**

```python
"""History compression — implemented in F6."""
from __future__ import annotations


class CompressionService:
    """Compress in-session history via LlmCallback when threshold exceeded."""

    async def compress_session(self, *args, **kwargs):
        raise NotImplementedError("implemented in F6")
```

- [ ] **Step 7.6: Create `api/app/services/vocab.py`**

```python
"""Vocabulary lookup, upsert, bloom, manifest — implemented in F4."""
from __future__ import annotations


class VocabService:
    """Vocab CRUD, fuzzy lookup, bloom filter, cache-stable manifest."""

    async def lookup(self, *args, **kwargs):
        raise NotImplementedError("implemented in F4-02")

    async def upsert(self, *args, **kwargs):
        raise NotImplementedError("implemented in F4-02")

    async def get_manifest(self, *args, **kwargs):
        raise NotImplementedError("implemented in F4-03")
```

- [ ] **Step 7.7: Commit**

```bash
git add api/app/services/
git commit -m "feat(F2-01): add service stub classes (memory, distillation, extraction, compression, vocab)"
```

---

## Task 8: Router stubs + `health.py`

**Files:**
- Create: `api/app/routers/__init__.py`
- Create: `api/app/routers/health.py`
- Create: `api/app/routers/observations.py`
- Create: `api/app/routers/search.py`
- Create: `api/app/routers/manifest.py`
- Create: `api/app/routers/vocab.py`
- Create: `api/app/routers/sessions.py`
- Create: `api/app/routers/mcp.py`

- [ ] **Step 8.1: Create `api/app/routers/__init__.py`**

```python
```
(empty)

- [ ] **Step 8.2: Create `api/app/routers/health.py`**

This is the only real endpoint in F2-01:

```python
from __future__ import annotations

from fastapi import APIRouter

from app.config import get_settings

router = APIRouter(tags=["health"])


@router.get("/health")
async def health() -> dict:
    s = get_settings()
    return {"status": "ok", "version": "0.1.0", "deployment": s.deployment}
```

- [ ] **Step 8.3: Create stub routers — all follow the same pattern**

`api/app/routers/observations.py`:
```python
from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["observations"])


@router.get("/observations/ping")
async def ping():
    raise HTTPException(status_code=501, detail="not implemented — see F2-03")
```

`api/app/routers/search.py`:
```python
from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["search"])


@router.get("/search/ping")
async def ping():
    raise HTTPException(status_code=501, detail="not implemented — see F3-06")
```

`api/app/routers/manifest.py`:
```python
from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["manifest"])


@router.get("/manifest/ping")
async def ping():
    raise HTTPException(status_code=501, detail="not implemented — see F2-05")
```

`api/app/routers/vocab.py`:
```python
from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["vocab"])


@router.get("/vocab/ping")
async def ping():
    raise HTTPException(status_code=501, detail="not implemented — see F4-02")
```

`api/app/routers/sessions.py`:
```python
from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["sessions"])


@router.get("/sessions/ping")
async def ping():
    raise HTTPException(status_code=501, detail="not implemented — see F2-06")
```

`api/app/routers/mcp.py`:
```python
from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["mcp"])


@router.get("/ping")
async def ping():
    raise HTTPException(status_code=501, detail="not implemented — see F3-07")
```

- [ ] **Step 8.4: Commit**

```bash
git add api/app/routers/
git commit -m "feat(F2-01): add router stubs (501) + health router"
```

---

## Task 9: `main.py` + `/health` test (TDD)

**Files:**
- Create: `api/app/main.py`
- Create: `api/tests/test_health.py`

- [ ] **Step 9.1: Write the failing test**

```python
# api/tests/test_health.py
from __future__ import annotations


def test_health_returns_200(client):
    response = client.get("/health")
    assert response.status_code == 200


def test_health_response_body(client):
    data = client.get("/health").json()
    assert data["status"] == "ok"
    assert data["version"] == "0.1.0"
    assert data["deployment"] == "lan"


def test_docs_endpoint_available(client):
    response = client.get("/docs")
    assert response.status_code == 200


def test_stub_routers_return_501(client):
    stub_paths = [
        "/api/v1/observations/ping",
        "/api/v1/search/ping",
        "/api/v1/manifest/ping",
        "/api/v1/vocab/ping",
        "/api/v1/sessions/ping",
        "/mcp/ping",
    ]
    for path in stub_paths:
        response = client.get(path)
        assert response.status_code == 501, (
            f"Expected 501 for {path}, got {response.status_code}"
        )


def test_unknown_route_returns_404(client):
    response = client.get("/api/v1/nonexistent")
    assert response.status_code == 404
```

- [ ] **Step 9.2: Run test — expect ImportError (no main.py yet)**

```bash
cd api && python -m pytest tests/test_health.py -v
```

Expected: `ImportError: No module named 'app.main'`

- [ ] **Step 9.3: Create `api/app/main.py`**

```python
"""FastAPI application entry point.

Lifespan manages:
  - asyncpg connection pool (db_pool stored in app.state)
  - Redis async client (redis stored in app.state)

Middleware stubs for F2-11 (security headers) and F2-13 (rate limiting) are
noted as comments — not yet active.

All routers except health return 501 until implemented in F2-03, F2-05,
F3-06, F4-02, F2-06, F3-07.
"""
from __future__ import annotations

from contextlib import asynccontextmanager
from typing import AsyncGenerator

import asyncpg
import structlog
from fastapi import FastAPI
from fastapi.middleware.gzip import GZipMiddleware
from redis.asyncio import Redis

from app.config import get_settings
from app.routers import health, manifest, mcp, observations, search, sessions, vocab

logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    settings = get_settings()
    logger.info("startup", deployment=settings.deployment)

    app.state.db_pool = await asyncpg.create_pool(
        settings.database_url_asyncpg,
        min_size=2,
        max_size=10,
    )
    # Redis.from_url is a regular classmethod — no await
    app.state.redis = Redis.from_url(settings.redis_url, decode_responses=True)

    logger.info("startup_complete")
    yield

    await app.state.db_pool.close()
    await app.state.redis.aclose()
    logger.info("shutdown_complete")


app = FastAPI(
    title="MemoryMesh API",
    version="0.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

# ── Middleware ─────────────────────────────────────────────────────────────────
app.add_middleware(GZipMiddleware, minimum_size=1000)
# Security headers → F2-11
# Rate limiting     → F2-13
# CORS              → not planned (api key auth, no browser access to /api/v1)

# ── Routers ───────────────────────────────────────────────────────────────────
app.include_router(health.router)                              # /health
app.include_router(observations.router, prefix="/api/v1")     # /api/v1/observations/*
app.include_router(search.router,       prefix="/api/v1")     # /api/v1/search/*
app.include_router(manifest.router,     prefix="/api/v1")     # /api/v1/manifest/*
app.include_router(vocab.router,        prefix="/api/v1")     # /api/v1/vocab/*
app.include_router(sessions.router,     prefix="/api/v1")     # /api/v1/sessions/*
app.include_router(mcp.router,          prefix="/mcp")        # /mcp/*
```

- [ ] **Step 9.4: Run tests — expect all pass**

```bash
cd api && python -m pytest tests/test_health.py -v
```

Expected:
```
tests/test_health.py::test_health_returns_200 PASSED
tests/test_health.py::test_health_response_body PASSED
tests/test_health.py::test_docs_endpoint_available PASSED
tests/test_health.py::test_stub_routers_return_501 PASSED
tests/test_health.py::test_unknown_route_returns_404 PASSED
5 passed in 0.XXs
```

- [ ] **Step 9.5: Run full test suite**

```bash
cd api && python -m pytest tests/ -v
```

Expected: all tests from test_config, test_schemas, test_health pass (≥ 32 tests total).

- [ ] **Step 9.6: Commit**

```bash
git add api/app/main.py api/tests/test_health.py
git commit -m "feat(F2-01): add main.py with lifespan, router wiring, /health endpoint"
```

---

## Task 10: Docker smoke test

**Files:** none changed — this is verification only.

- [ ] **Step 10.1: Rebuild and start stack**

```bash
# From repo root
docker compose build api
docker compose up -d api
```

Wait for healthy status (the Dockerfile HEALTHCHECK polls `/health` every 15s):

```bash
docker compose ps
```

Expected: `api` service shows `healthy`.

- [ ] **Step 10.2: Verify `/health`**

```bash
curl -s http://localhost:8000/health | python -m json.tool
```

Expected:
```json
{
    "status": "ok",
    "version": "0.1.0",
    "deployment": "lan"
}
```

- [ ] **Step 10.3: Verify OpenAPI**

```bash
curl -s http://localhost:8000/openapi.json | python -m json.tool | head -20
```

Expected: valid JSON with `"title": "MemoryMesh API"`.

- [ ] **Step 10.4: Verify stub returns 501**

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/observations/ping
```

Expected: `501`

- [ ] **Step 10.5: Commit**

```bash
git add .
git commit -m "chore(F2-01): docker smoke test verified (health 200, stubs 501)"
```

(If there are no changes after the smoke test, skip commit.)

---

## Task 11: Update TASKS.md + memory

**Files:**
- Modify: `docs/TASKS.md`

- [ ] **Step 11.1: Mark F2-01 complete in `docs/TASKS.md`**

In the Fase 2 table, change the F2-01 row Status from `[ ]` to `[x]`:

```markdown
| F2-01 | Struttura FastAPI (routers, services, schemas, config) | S | Sonnet | F1-02 | `[x]` |
```

- [ ] **Step 11.2: Commit**

```bash
git add docs/TASKS.md
git commit -m "chore(F2-01): mark task complete in TASKS.md"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| `main.py` with lifespan (asyncpg + Redis) | Task 9 |
| `config.py` expanded to full settings | Task 4 |
| `dependencies.py` with `get_db`, `get_redis` | Task 6 |
| 7 router files (1 real, 6 stubs → 501) | Task 8 |
| 5 service stub classes | Task 7 |
| 4 schema files (ObsCreate, ObsFull, ObsCompact, SearchRequest, etc.) | Task 5 |
| `requirements.txt` expanded | Task 2 |
| `requirements.in` created | Task 2 |
| Dockerfile `--require-hashes` removed (TODO F12) | Task 3 |
| `static/.gitkeep` so `COPY static/` doesn't fail | Task 3 |
| `/health` → 200 `{"status":"ok","version":"0.1.0","deployment":"lan"}` | Tasks 8, 9 |
| Smoke test via Docker | Task 10 |
| TASKS.md updated | Task 11 |

**Placeholder scan:** no TBD, no "fill in later", no "similar to Task N". All code blocks are complete.

**Type consistency:**
- `ObsType` defined in `observation.py`, imported in `search.py` and `manifest.py` ✓
- `VocabCategory` type alias defined and reused within `vocab.py` ✓
- `database_url_asyncpg` property used in `main.py` lifespan ✓
- `Redis.from_url` called without `await` (correct for redis-py 5.x asyncio) ✓
- `mock_redis_class.from_url.return_value` in conftest matches the non-async call ✓
