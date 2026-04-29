# F2-01 — FastAPI Scaffold Design

**Data:** 2026-04-29
**Task:** F2-01 (TASKS.md Fase 2)
**Effort:** S (2-4h) · Sonnet
**Dipende da:** F1-02 (Docker Compose)
**Approccio scelto:** Working skeleton (B) — container si avvia, `/health` risponde 200, ogni router ha un ping stub.

---

## Obiettivo

Creare la struttura FastAPI completa (`main.py`, `config.py` espanso, `dependencies.py`, routers/, services/, schemas/) partendo dallo stato attuale di `api/app/` (che contiene solo `config.py` Alembic-only, `db/`, `queue/`, `mdns.py`).

Al termine di F2-01:
- `docker compose up api` avvia senza errori
- `GET /health` → 200 `{"status":"ok","version":"0.1.0"}`
- Ogni router restituisce 501 su `/ping` (stub funzionante, non implementato)
- F2-02 (auth middleware) può operare su un'app già avviata

---

## File tree — delta rispetto allo stato attuale

```
api/
├── requirements.in              # NUOVO — source of truth per pip-compile (F12)
├── requirements.txt             # ESPANSO — tutte le deps F2 (no hash per ora)
├── Dockerfile                   # MODIFICATO — no --require-hashes (TODO F12)
└── app/
    ├── main.py                  # NUOVO
    ├── config.py                # ESPANSO — da Alembic-only a full settings
    ├── dependencies.py          # NUOVO
    ├── routers/
    │   ├── __init__.py          # NUOVO
    │   ├── health.py            # NUOVO — GET /health
    │   ├── observations.py      # NUOVO stub
    │   ├── search.py            # NUOVO stub
    │   ├── manifest.py          # NUOVO stub
    │   ├── vocab.py             # NUOVO stub
    │   ├── sessions.py          # NUOVO stub
    │   └── mcp.py               # NUOVO stub
    ├── services/
    │   ├── __init__.py          # NUOVO
    │   ├── memory.py            # NUOVO stub
    │   ├── distillation.py      # NUOVO stub
    │   ├── extraction.py        # NUOVO stub
    │   ├── compression.py       # NUOVO stub
    │   └── vocab.py             # NUOVO stub
    └── schemas/
        ├── __init__.py          # NUOVO
        ├── observation.py       # NUOVO — ObsCreate, ObsFull, ObsCompact, ObsType
        ├── search.py            # NUOVO — SearchRequest, SearchResult, SearchResponse
        ├── manifest.py          # NUOVO — ManifestEntry, ManifestResponse, ManifestDeltaResponse
        └── vocab.py             # NUOVO — VocabEntry, VocabLookupResponse, VocabUpsertRequest
```

File invariati: `db/__init__.py`, `queue/schemas.py`, `queue/streams.py`, `mdns.py`, `alembic/`, `alembic.ini`, `init-db.sql`, `init-roles.sh`.

---

## Sezione 1 — `main.py`

```python
from contextlib import asynccontextmanager
import asyncpg
from redis.asyncio import Redis
from fastapi import FastAPI
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware

from app.config import get_settings
from app.routers import health, observations, search, manifest, vocab, sessions, mcp

@asynccontextmanager
async def lifespan(app: FastAPI):
    s = get_settings()   # inside lifespan — avoids SECRET_KEY required at import time
    app.state.db_pool = await asyncpg.create_pool(
        s.database_url_asyncpg, min_size=2, max_size=10
    )
    app.state.redis = Redis.from_url(s.redis_url, decode_responses=True)  # sync ctor in redis-py 5.x
    yield
    await app.state.db_pool.close()
    await app.state.redis.aclose()

app = FastAPI(
    title="MemoryMesh API",
    version="0.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

app.add_middleware(GZipMiddleware, minimum_size=1000)
# TrustedHostMiddleware: stub, da attivare in F2-11 con profile detection
# app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)

app.include_router(health.router)
app.include_router(observations.router, prefix="/api/v1")
app.include_router(search.router,       prefix="/api/v1")
app.include_router(manifest.router,     prefix="/api/v1")
app.include_router(vocab.router,        prefix="/api/v1")
app.include_router(sessions.router,     prefix="/api/v1")
app.include_router(mcp.router,          prefix="/mcp")
```

**Note:**
- `database_url_asyncpg` è una property derivata in `config.py` che converte il formato `postgresql+psycopg://...` (usato da Alembic/SQLAlchemy) in `postgresql://...` (usato da asyncpg).
- I middleware security (HSTS, CSP, X-Frame-Options, rate limit) arrivano in F2-11/F2-13 — qui solo GZip e TrustedHost stub.
- Il lifespan gestisce solo pool e redis. Il mDNS broadcaster (`mdns.py`) resta avviato dal Compose command separato (già funzionante da F1-09).

---

## Sezione 2 — `config.py` espanso

Mantiene compatibilità con il codice Alembic esistente (alias `DATABASE_URL`, `DATABASE_ADMIN_URL`, `FP_LOGGING_ENABLED`). Aggiunge:

```python
class Settings(BaseSettings):
    # -- esistente (Alembic-compat) --
    database_url: str           # alias DATABASE_URL (psycopg format per Alembic)
    database_admin_url: str | None
    fp_logging_enabled: bool

    # -- FastAPI / runtime --
    redis_url: str              # alias REDIS_URL, default "redis://redis:6379/0"
    secret_key: str             # alias SECRET_KEY, no default (obbligatorio)
    ollama_url: str             # alias OLLAMA_URL, default "http://ollama:11434"
    deployment: Literal["lan","vpn","public"] = "lan"

    # -- Manifest / token budget --
    manifest_default_budget: int = 3000
    search_default_limit: int = 5
    search_max_limit: int = 20
    search_cache_ttl: int = 300

    # -- Distillation thresholds --
    merge_similarity_threshold: float = 0.92
    decay_observation_factor: float = 0.85
    decay_context_factor: float = 0.97
    tighten_min_words: int = 150
    compress_threshold_tokens: int = 8000
    vocab_extract_enabled: bool = True

    # -- Token-first (Strategie 8-18) --
    max_obs_tokens: int = 200
    shortcode_threshold: int = 10
    root_relevance_threshold: float = 0.85
    root_access_count_threshold: int = 50
    lru_eviction_days: int = 60
    bm25_skip_threshold: float = 0.3
    search_rerank_enabled: bool = True
    fingerprint_min_sessions: int = 3

    # -- LLM provider --
    memorymesh_llm_provider: Literal["gemini","ollama","openai","anthropic"] = "gemini"
    memorymesh_embed_provider: Literal["gemini","ollama"] = "gemini"
    memorymesh_llm_daily_token_cap: int = 500_000

    # -- derived --
    @property
    def database_url_asyncpg(self) -> str:
        """asyncpg usa 'postgresql://' invece di 'postgresql+psycopg://'."""
        return self.database_url.replace("postgresql+psycopg://", "postgresql://")
```

`get_settings()` resta un singleton (cached via `functools.lru_cache`).

---

## Sezione 3 — `dependencies.py`

```python
from fastapi import Request, Depends
from redis.asyncio import Redis
import asyncpg

from app.config import Settings, get_settings

async def get_db(request: Request) -> asyncpg.Connection:
    async with request.app.state.db_pool.acquire() as conn:
        yield conn

async def get_redis(request: Request) -> Redis:
    return request.app.state.redis

def get_cfg(settings: Settings = Depends(get_settings)) -> Settings:
    return settings
```

`get_current_user` e `get_project` sono definiti come stub che sollevano `NotImplementedError` — saranno implementati in F2-02 (auth) e F2-04 (progetti).

---

## Sezione 4 — Router stubs

Ogni file router segue lo stesso pattern:

```python
# routers/observations.py
from fastapi import APIRouter
router = APIRouter(tags=["observations"])

@router.get("/ping")
async def ping():
    # stub — implementato in F2-03
    from fastapi import HTTPException
    raise HTTPException(501, "not implemented")
```

**`routers/health.py`** è l'unica eccezione — implementazione completa:

```python
from fastapi import APIRouter
from app.config import get_settings

router = APIRouter(tags=["health"])

@router.get("/health")
async def health():
    s = get_settings()
    return {"status": "ok", "version": "0.1.0", "deployment": s.deployment}
```

(Il deep check DB/Redis/Ollama arriva in F2-06.)

---

## Sezione 5 — Schemas core

### `schemas/observation.py`
```python
from enum import Enum
from pydantic import BaseModel, Field
from datetime import datetime
from uuid import UUID

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
    tags: list[str] = []
    scope: list[str] = []
    token_estimate: int | None = None
    expires_at: datetime | None = None
    metadata: dict | None = None

class ObsCompact(BaseModel):    # usato da /search, /manifest — MAI full content
    id: int
    type: ObsType
    one_liner: str
    score: float | None = None
    age_hours: int | None = None

class ObsFull(BaseModel):       # usato da /observations/batch
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

### `schemas/search.py`
```python
class SearchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    q: str = Field(min_length=1, max_length=500)
    project_id: UUID
    scope: list[str] = []
    limit: int = Field(default=5, ge=1, le=20)
    mode: Literal["bm25","vector","hybrid"] = "hybrid"
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

### `schemas/manifest.py`
```python
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
    removed: list[int]      # obs_ids
    etag: str
    full_refresh_required: bool
```

### `schemas/vocab.py`
```python
class VocabEntry(BaseModel):
    id: int
    term: str
    shortcode: str | None
    category: Literal["entity","convention","decision","abbreviation","pattern"]
    definition: str = Field(max_length=80)
    detail: str | None
    usage_count: int
    confidence: float

class VocabLookupResponse(BaseModel):
    found: bool
    entry: VocabEntry | None
    match_type: Literal["exact","fuzzy","semantic"] | None

class VocabUpsertRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    term: str = Field(min_length=1, max_length=100)
    category: Literal["entity","convention","decision","abbreviation","pattern"]
    definition: str = Field(min_length=1, max_length=80)
    detail: str | None = None
    metadata: dict | None = None
```

---

## Sezione 6 — Requirements e Dockerfile

### `requirements.in` (nuovo — source of truth)
```
fastapi==0.136.*
uvicorn[standard]==0.32.*
pydantic==2.13.*
pydantic-settings==2.7.*
asyncpg==0.31.*
pgvector==0.3.*
alembic==1.14.*
sqlalchemy==2.0.*
psycopg[binary]==3.2.*
redis==5.2.*
httpx==0.28.*
structlog==24.*
tiktoken==0.8.*
zeroconf==0.135.*
```

### `requirements.txt` — sostituisce il file Sprint 1 con il set completo.

### `Dockerfile` Stage 1 — cambio:
```dockerfile
# TODO F12: switch to: pip install --user --require-hashes -r requirements-hashes.txt
COPY requirements.txt .
RUN pip install --user -r requirements.txt
```
Stage 2 resta invariato. `COPY requirements-hashes.txt` viene rimosso dal `COPY` (il file non esiste ancora).

---

## Test scope F2-01

F2-01 non richiede test pytest (F2-08 è il task di test dedicato). La verifica è:

```bash
make up          # docker compose up --wait
curl http://localhost:8000/health   # → {"status":"ok","version":"0.1.0","deployment":"lan"}
curl http://localhost:8000/api/v1/observations/ping  # → 501
curl http://localhost:8000/docs     # → OpenAPI UI
```

---

## Decisioni prese

| Decisione | Rationale |
|---|---|
| No `--require-hashes` in Dockerfile | Su Windows non è possibile generare hash affidabili senza Docker. Hashes → F12. |
| `database_url_asyncpg` come `@property` | Evita duplicazione config, Alembic continua a leggere `DATABASE_URL` invariato. |
| `/health` senza DB check | Deep check (DB + Redis + Ollama + queue depth) è F2-06. F2-01 serve solo boot smoke test. |
| Router stubs con 501 (non 200) | 501 è semanticamente corretto ("non implementato") e distinguibile da errori reali nei log. |
| Services come classi stub con `pass` | I service vengono iniettati via DI in F2-02+; meglio classi che funzioni libere per testabilità. |
| `get_current_user` stub che lancia `NotImplementedError` | Forza F2-02 a implementarla prima di usarla — nessun "bypass accidentale". |

---

## Non incluso in F2-01

- Auth middleware → F2-02
- CRUD observations → F2-03
- Security headers (CSP, HSTS, X-Frame-Options) → F2-11
- Rate limiting → F2-07/F2-13
- Deep health check → F2-06
- Test suite pytest → F2-08
- `requirements-hashes.txt` → F12
