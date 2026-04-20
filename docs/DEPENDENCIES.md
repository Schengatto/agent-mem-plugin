# Dipendenze & Scelte Tecnologiche — ADR

> Verifica versioni ogni 3 mesi. Aggiornare data di ultimo check.
> Single source of truth per versioning. `ARCHITECTURE.md` e i file concreti
> (`Dockerfile`, `docker-compose.yml`, `requirements.txt`) derivano da qui.

**Ultimo check:** 20 aprile 2026

---

## Stack Attuale (aprile 2026)

### Server-side

| Componente | Versione | Ultima release | Perché |
|-----------|---------|-----------------|--------|
| **Python** | **3.14.4** | 7 apr 2026 | free-threading ufficiale (benefit embed/distill worker multi-thread), t-strings, compression.zstd module, supporto LTS 24 mesi |
| **FastAPI** | **0.136.0** | 16 apr 2026 | Starlette 1.0+, SSE streaming, strict Content-Type JSON check — ancora default per AI/LLM backend |
| **Pydantic** | **2.13.1** | 15 apr 2026 | Python 3.14 support, polymorphic serialization fix, bug fix |
| **Uvicorn** | **0.32.x** | — | ASGI server, `[standard]` per uvloop+httptools |
| **asyncpg** | **0.31.0** | 24 nov 2025 | Python 3.14 wheels (anche free-threaded cp314t), massima performance vs psycopg |
| **SQLAlchemy 2** | **2.0.x** | — | Non usato direttamente; Alembic dipende da 2.x per le migration |
| **Alembic** | **1.14.x** | — | Schema migrations, standard de facto |
| **PostgreSQL** | **18.3** | 26 feb 2026 | I/O subsystem nuovo (+3× perf read), `uuidv7()` nativo (sortable session token), virtual generated columns, pg_stat_io esteso |
| **pgvector** | **0.8.2** | 2026 | **obbligatorio**: fix CVE-2026-3172 (buffer overflow parallel HNSW build). Iterative scan modes (relaxed_order) danno 95-99% quality a ~1/3 latenza |
| **Redis** | **8.6** | feb 2026 | Bloom/Cuckoo filter **built-in** (rimuove `pybloom-live` server-side), vector ops AArch64, TLS cert auto auth, +30 perf improvements |
| **Ollama** | latest | continuo | Modello runner, `OLLAMA_MAX_LOADED_MODELS=1` per single-inference RAM |
| **Caddy** | **2.x** | — | Reverse proxy auto-TLS, plugin `caddy-ratelimit` via xcaddy |
| **Argon2-cffi** | **23.x** | — | argon2id per password + recovery codes |
| **pyotp** | **2.x** | — | TOTP RFC 6238 |
| **webauthn (py)** | **2.7.1** | 11 feb 2026 | FIDO2/passkey, supporta Touch ID, Face ID, YubiKey, Windows Hello |
| **cryptography** | **43.x** | — | AES-GCM per cifratura TOTP secret, HKDF derivation |
| **itsdangerous** | **2.x** | — | Session cookie signing |
| **structlog** | **24.x** | — | Logging JSON strutturato |
| **httpx** | **0.28.x** | — | HTTP client async (SSRF `safe_fetch` wrapper) |
| **rapidfuzz** | **3.x** | — | Levenshtein fuzzy matching vocab lookup |
| **tiktoken** | **0.8.x** | — | `cl100k_base` encoding Anthropic-compatible |
| **sentence-transformers** | **3.x** | — | Cross-encoder rerank (opzionale) |
| **zeroconf** | **0.135.x** | — | mDNS broadcaster (`_memorymesh._tcp.local`) |
| **fastapi-limiter** | latest | — | Rate limiting DI-based Redis-backed (sostituisce slowapi, vedi ADR-003) |
| **google-genai** | **1.x** | 2026 | Gemini SDK ufficiale. Pydantic schema-native, streaming, structured output, implicit caching. Sostituisce google-generativeai (legacy). |
| **anthropic** | **0.40.x** | — | Claude SDK, opt-in (MEMORYMESH_LLM_PROVIDER=anthropic) |
| **openai** | **1.60.x** | — | OpenAI SDK, opt-in (MEMORYMESH_LLM_PROVIDER=openai) |
| **ollama** | **0.4.x** | — | Client Python Ollama, opt-in (Profile B/C) |

### LLM / Embedding (multi-provider, vedi ADR-014, 015)

**Default (Profile A, cloud)**:

| Provider | Modello | Costo | Note |
|----------|---------|-------|------|
| **Gemini** | `gemini-2.5-flash` | $0.30/M in + $2.50/M out | 1M context, implicit caching automatic 2.5+, structured output Pydantic-native |
| **Gemini** (embed) | `text-embedding-004` | $0.025/M token | 768d, batch support |

**Alternative (opt-in)**:

| Provider | Modello | Costo | Quando |
|----------|---------|-------|--------|
| Ollama | `qwen3.5:9b` Q4_K_M | $0 | Profile C (privacy-strict), richiede 5.5GB RAM picco |
| Ollama | `nomic-embed-text-v2-moe` | $0 | Profile B/C, multilingue 100 lingue, MoE sparse, Matryoshka 256-768d |
| OpenAI | `gpt-5-mini` / `gpt-4.1` | $0.15-1/M in | opt-in |
| Anthropic | `claude-haiku-4-5` | $0.80/M in | opt-in |

**Reranker — sempre locale** (ADR-006):

| Modello | Note |
|---------|------|
| `jinaai/jina-reranker-v2-base-multilingual` | 15× più veloce di bge-reranker-v2-m3, 100 lingue, sentence-transformers CPU, ~350MB RAM |

### Plugin TypeScript

| Componente | Versione | Perché |
|-----------|---------|--------|
| **Node.js** | **22 LTS** | Necessario per supportare plugin Claude Code + Nuxt 4 build |
| **TypeScript** | **5.6.x** | Stable branch |
| **Vitest** | **2.x** | Unit test framework moderno |
| **js-tiktoken** | **1.x** | Port tiktoken per plugin, cl100k_base |
| **bloom-filters** | **3.x** | Libreria client bloom (lato plugin) |
| **multicast-dns** | **7.x** | mDNS discovery client |
| **keytar** | **7.x** | OS keyring (libsecret/Keychain/CredentialManager) per API key storage |

### UI Admin (Nuxt)

| Componente | Versione | Perché |
|-----------|---------|--------|
| **Nuxt** | **4.4.2** | stable mar 2026, vue-router v5, typed useFetch factories, accessibility announcer, smart payload |
| **Vue** | **3.5.x** | framework reactive core |
| **Vite** | **5.x** | build tool integrato Nuxt |
| **@nuxt/ui** | **3.x** | component library + Tailwind integrato |
| **Pinia** | **2.x** | state management Vue 3 official |
| **@vueuse/nuxt** | **11.x** | utility composables |
| **@simplewebauthn/browser** | **11.x** | WebAuthn client API wrapper |
| **isomorphic-dompurify** | **2.x** | XSS sanitization (rendering markdown user content) |
| **markdown-it** | **14.x** | markdown rendering seguito da DOMPurify |
| **zxcvbn-ts** | **3.x** | password strength meter al setup admin |
| **qrcode.vue** | **3.x** | render QR TOTP + pair PIN |

### Container Base Images

| Image | Tag/Digest | Perché |
|-------|-----------|--------|
| `python:3.14.4-slim` | pin by digest | latest stable Python, slim ~50MB, ufficiale |
| `pgvector/pgvector:pg18` | pin by digest | PG 18 + pgvector 0.8.2, immagine maintained |
| `redis:8.6-alpine` | pin by digest | Redis 8.6 OSS, Alpine per footprint minimale |
| `ollama/ollama:latest` | pin by digest al build | binari statici, AArch64 + x86_64 |
| `caddy:2-alpine` | pin by digest (ultimo 2.x) | auto-TLS, Alpine footprint |

---

## Decisioni Architetturali (ADR)

### ADR-001: FastAPI vs Litestar → FastAPI

**Context:** Litestar claims 2× performance via msgspec serialization (~12× faster than Pydantic V2).

**Decision:** Restare su FastAPI.

**Rationale:**
- Ecosistema AI/LLM è FastAPI-first (LangChain, instructor, OpenAI SDK examples)
- Tutto il design (webauthn, pydantic-settings, OpenAPI auto-gen, Starlette middleware) è già scritto assumendo FastAPI
- Differenza performance reale in scenari DB-bound è <5% (i/O bound, non CPU bound)
- FastAPI 0.136.0 con Starlette 1.0+ ha streaming SSE maturo
- Developer productivity > server cost al target deployment (home server)

**Trade-off:** Rinunciamo a ~2× throughput teorico su alcuni endpoint. Accettabile.

### ADR-002: PostgreSQL vs SQLite+sqlite-vec → PostgreSQL 18

**Context:** SQLite + sqlite-vec sarebbe molto più semplice (no container DB separato).

**Decision:** PostgreSQL 18.

**Rationale:**
- Multi-user famiglia con concurrent write da più device
- Row-Level Security (RLS) è requisito sicurezza (SQLite non lo supporta)
- `uuidv7()` nativo (PG 18) per session token ordinabili
- Virtual generated columns possono ottimizzare token_estimate
- pgvector 0.8.2 ha HNSW iterative scan (relaxed_order) che è superiore a sqlite-vec per qualità/performance tradeoff
- DB separato = restore/backup più granulare, user separation DB-level (mm_api/mm_worker/mm_admin) impossibile con SQLite

**Trade-off:** +1 container, +300MB RAM. Accettabile.

### ADR-003: slowapi → fastapi-limiter

**Context:** slowapi è più maturo ma decoratore-based, fastapi-limiter è Redis-native con dependency injection.

**Decision:** Passare a **fastapi-limiter**.

**Rationale:**
- API Multi-worker (2 uvicorn workers default): slowapi ha stato in-memory → rate limit NON condiviso fra worker. Bug di sicurezza per brute force defense.
- fastapi-limiter usa Redis come backend → rate limit globale cluster-wide, correttamente condiviso
- Dependency injection stile FastAPI è più pulito di decoratori
- Token Bucket / Sliding Window supportati nativi
- Compatibile con distributed deployment (se un giorno serve)

**Migration impact:** aggiornare F2-13 task (rate limit middleware), sostituire import slowapi con fastapi_limiter.

### ADR-004: pybloom-live server-side → Redis 8 BF built-in

**Context:** Redis 8 ha Bloom filter built-in come data type nativo (comandi `BF.RESERVE`, `BF.ADD`, `BF.MEXISTS`, `BF.LOADCHUNK`).

**Decision:** Usare Redis 8 BF server-side. `pybloom-live` rimosso da requirements.txt.

**Rationale:**
- Zero dipendenza Python aggiuntiva
- Implementazione C di Redis (più veloce di Python)
- Serializzazione per export al client (`/vocab/bloom` endpoint) via `BF.SCANDUMP` / `BF.LOADCHUNK` — formato standard
- Rebuild atomico senza lock applicativo (Redis single-thread)

**Migration impact:** F5-06b (bloom rebuild step) semplificato — niente più serializzazione Python-side.

### ADR-005: Python 3.12 → Python 3.14

**Context:** 3.14 ha free-threading ufficiale (no-GIL), t-strings, compression.zstd.

**Decision:** Python 3.14.4.

**Rationale:**
- Free-threading (PEP 703) è **experimental ma usabile**: embed worker e distillation worker beneficiano molto (parallelizzano embedding batch senza GIL)
- LTS: supporto per ~24 mesi dal release
- asyncpg 0.31 ha wheels cp314 + cp314t (free-threaded) già disponibili
- Pydantic 2.13 supporta 3.14

**Trade-off:** pre-built wheels più limitati di 3.12. Mitigazione: `pip install --only-binary :all:` per verificare copertura prima del merge.

### ADR-006: bge-reranker-base → jina-reranker-v2-base-multilingual

**Context:** Jina reranker v2 è 15× più veloce di bge-reranker-v2-m3 a parità di qualità.

**Decision:** jina-reranker-v2-base-multilingual.

**Rationale:**
- Home server CPU-only: 15× speedup cambia da "opzionale" a "sempre-on"
- Supporto 100 lingue (familiare/team multilingue)
- Funziona via sentence-transformers (nostro stack already)
- Licenza Apache 2.0 (OK self-host)

**Trade-off:** modello nuovo, meno testato in production reale. Mitigazione: flag `SEARCH_RERANK_ENABLED=false` disattivabile se regressione.

### ADR-007: nomic-embed-text v1 → nomic-embed-text-v2-moe

**Context:** v2-moe è multilingue (100 lingue), MoE sparse (efficiente), Matryoshka embedding (dimensione flessibile).

**Decision:** nomic-embed-text-v2-moe.

**Rationale:**
- Italiano è lingua primaria del target user
- Matryoshka: possiamo troncare a 512d invece di 768d per risparmiare storage senza re-embedding (test empirico richiesto)
- MoE: attiva solo parte della rete → latenza comparable
- Task instruction prefix (`search_query:` / `search_document:`) deve essere gestito nel wrapper Ollama

**Migration impact:** F3-01 (embedding worker) deve inserire prefix task-specific. Documentato in CONVENTIONS.md.

### ADR-008: Qwen3:8b → Qwen3.5-9B

**Context:** Qwen3.5 rilasciato 16 feb 2026. Hybrid architecture Gated Delta Networks + sparse MoE.

**Decision:** Qwen3.5-9B (quantizzato Q4_K_M).

**Rationale:**
- Qwen3.5-9B performance ≈ Qwen2.5-14B-Base → più intelligenza a parità RAM
- MoE sparse: attiva solo expert rilevanti → ~5.5GB picco RAM anche per 9B params
- Qwen3-8B-Base già testato per distillation task (JSON output, structured extraction)
- Fallback a Qwen3-8B se 9B troppo lento

**Migration impact:** `OLLAMA_DISTILL_MODEL=qwen3.5:9b` in .env.example.

### ADR-009: Caddy 2 rate limit → xcaddy custom build

**Context:** Caddy stock non include `caddy-ratelimit` plugin.

**Decision:** Custom Dockerfile per Caddy con xcaddy + `mholt/caddy-ratelimit`.

**Rationale:**
- Rate limiting edge-level è più efficiente di app-level (FastAPI middleware)
- caddy-ratelimit supporta distributed state via storage Caddy
- Plugin OSS ben maintained (stesso autore Matt Holt)

**Migration impact:** aggiungere `Dockerfile.caddy` nel repo, `docker-compose.yml` build Caddy custom.

### ADR-010: distroless vs python:slim → python:slim (per ora)

**Context:** distroless/chainguard images sono più sicure (no shell, no package manager, minima attack surface).

**Decision:** python:3.14.4-slim per ora. Distroless considerato per Fase 12+.

**Rationale:**
- Debug più semplice con slim (puoi `docker exec -it sh`)
- Build tool friction minore (pip install normale)
- Trade-off sicurezza: slim ha apt + bash, attacker con RCE può eseguire shell. Mitigato da cap_drop ALL + seccomp + read-only FS
- Distroless avrebbe +0.5gg complessità (multi-stage con distroless runtime, debugging su staging separato)

**Migration path:** se profile=public ha constraint compliance (es. uptime SLA), upgrade a `gcr.io/distroless/python3-debian12`. Task Fase 12 opzionale F12-18.

### ADR-011: APScheduler in-process → cron separato (da valutare Fase 12)

**Context:** APScheduler corre dentro il worker distillation. Se worker crasha, CRON muore. Nessun retry automatico.

**Decision:** APScheduler dentro distillation-worker container. **Review Fase 12**.

**Rationale attuale:**
- Semplice, zero deps extra
- Worker in docker compose ha `restart: unless-stopped`
- Cron job alternativo (container dedicato) è overkill per task singolo CRON 03:00

**Trigger per cambio:**
- Se in F9 (predictive loop) aggiungiamo più scheduled job → passare a systemd timers host-side o container ofelia

### ADR-012: Nuxt 4 SPA statica (no SSR) → conferma

**Context:** Nuxt 4 supporta SSR. Una SPA admin interna non ne ha bisogno.

**Decision:** Conferma SPA statica (`ssr: false`, `nuxi generate` → static files in FastAPI).

**Rationale:**
- Admin UI serve solo utenti autenticati post-load → SSR non aiuta SEO né first paint
- Deploy single-container più semplice
- Aggiornamenti indipendenti: ricompila SPA senza rideployare API

### ADR-014: LLM Cloud (Gemini) vs LLM Locale (Qwen3.5) → Gemini default

**Context:** Target user non ha mini-PC 16GB. Server MemoryMesh deve girare
anche su RPi 5 / NAS / VM $6/mese. Qwen3.5-9B richiede 5.5GB RAM picco,
inacceptable su questi target.

**Decision:** **Gemini 2.5 Flash come LLM default**. Qwen3.5-9B via Ollama
resta opt-in (Profile C privacy-strict).

**Rationale:**
- **Costo trascurabile**: <$1/mese per home server single user intensivo,
  <$3/mese per famiglia 3 device. Bill shock prevention via daily cap (ADR-016)
- **Qualità superiore**: Gemini 2.5 Flash > Qwen3.5-9B su benchmark MMLU, HumanEval, MGSM
- **Implicit caching gratis**: il nostro prefisso cache-stable (Strategia 8)
  viene cachato automaticamente lato Gemini → risparmi duplicati (cache
  Anthropic su Claude Code + cache Gemini su distillation)
- **1M context window**: distillation notturna può lavorare su corpus
  grandi senza chunking complex
- **Structured output Pydantic-native**: elimina parse_json_strict ad hoc,
  validation a zero-shot
- **Deployment semplificato**: server gira in ~2.75GB RAM su qualunque
  Docker host. No GPU, no Ollama container, no model downloads

**Trade-off accettati:**
- **Privacy**: observation content va a Google. **Mitigato** da secret
  scrubbing pre-send obbligatorio (CONVENTIONS.md + ADR-014b), flag
  `no_cloud_llm` per opt-out per-obs, profile Ollama disponibile.
- **Network dependency**: se Google API down, distillation skip. Mitigato
  da `OLLAMA_LLM_FALLBACK` (se configurato entrambi, fallback a Ollama)
- **Cost variable**: cap hard daily token (ADR-016) previene bill shock

**Fallback path**: utente può switchare a Ollama in qualunque momento:
```bash
# .env
MEMORYMESH_LLM_PROVIDER=ollama   # da gemini a ollama
```
Riavvio stack con `--profile ollama`. Zero migration DB richiesta.

### ADR-015: LlmCallback / EmbedCallback provider-agnostic

**Context:** Legacy design aveva Qwen3/Ollama hardcoded. Con Gemini come
default nuovo, serve astrazione pulita che renda trivial aggiungere provider.

**Decision:** Protocol Python `LlmCallback` + `EmbedCallback`, adapter
plug-in selezionato via env var al boot.

```python
from typing import Protocol
from pydantic import BaseModel

class LlmResponse(BaseModel):
    content: str
    input_tokens: int
    output_tokens: int
    cached_tokens: int = 0    # implicit caching hits
    model: str
    latency_ms: int

class LlmCallback(Protocol):
    """Contract per qualunque LLM provider."""
    async def complete(
        self,
        system: str,
        user: str,
        max_tokens: int = 2000,
        response_schema: type[BaseModel] | None = None,  # structured output
    ) -> LlmResponse: ...

    @property
    def model(self) -> str: ...

    @property
    def provider_name(self) -> str: ...


class EmbedCallback(Protocol):
    """Contract per qualunque embedding provider."""
    async def embed_query(self, text: str) -> list[float]: ...
    async def embed_document(self, text: str) -> list[float]: ...

    @property
    def dimension(self) -> int: ...

    @property
    def model(self) -> str: ...
```

**Adapter disponibili day-1:**
- `GeminiLlmAdapter` / `GeminiEmbedAdapter` — default
- `OllamaLlmAdapter` / `OllamaEmbedAdapter`
- `OpenAiLlmAdapter` (nessun embed, viene da altro provider)
- `AnthropicLlmAdapter` (nessun embed)

**Factory DI:**

```python
# api/app/services/llm_factory.py
def get_llm_callback(settings: Settings) -> LlmCallback:
    match settings.llm_provider:
        case "gemini":    return GeminiLlmAdapter(api_key=settings.gemini_api_key, model=settings.llm_model)
        case "ollama":    return OllamaLlmAdapter(url=settings.ollama_url, model=settings.llm_model)
        case "openai":    return OpenAiLlmAdapter(api_key=settings.openai_api_key, model=settings.llm_model)
        case "anthropic": return AnthropicLlmAdapter(api_key=settings.anthropic_api_key, model=settings.llm_model)
        case _: raise ValueError(f"unknown provider: {settings.llm_provider}")
```

**Nel distillation worker:**
```python
async def run_for_project(project_id: UUID, llm: LlmCallback = Depends(get_llm_callback)):
    ...
    merged = await llm.complete(system="...", user=merge_prompt, response_schema=MergeOutput)
    # llm.provider_name, llm.model usati per audit in llm_api_calls
```

**Trade-off:** +1 layer di astrazione. Mitigato dalla semplicità dei
Protocol (no abstract class ereditarietà complessa).

### ADR-016: Budget Cap Hard (daily token limit)

**Context:** Cloud LLM ha costo variabile. Un bug (loop, observation spam,
distillation che non termina) potrebbe generare bill shock di centinaia di
euro in poche ore.

**Decision:** Hard daily token cap globale. Quando superato: distillation/
compression/extract **skip** con audit entry + ntfy alert admin.

**Implementazione:**

```python
# api/app/services/llm_budget.py
from redis.asyncio import Redis
from datetime import date

class BudgetExceeded(Exception): ...

async def check_and_reserve(redis: Redis, tokens: int) -> None:
    """Atomic check + reserve. Raise BudgetExceeded se supera."""
    today = date.today().isoformat()
    key = f"llm:budget:{today}"
    cap = settings.llm_daily_token_cap  # default 500_000

    # INCRBY atomic; ritorna nuovo valore
    new_total = await redis.incrby(key, tokens)
    if new_total == tokens:
        await redis.expire(key, 86400 * 2)   # TTL 2 giorni per grace
    if new_total > cap:
        # Rollback (decrementa) perché NON dovrebbe essere speso
        await redis.decrby(key, tokens)
        await audit_log("llm_budget_exceeded",
                        details={"today": today, "total": new_total, "cap": cap})
        await notify_admin(f"LLM budget exceeded: {new_total}/{cap} token")
        raise BudgetExceeded(f"daily cap {cap} exceeded")
```

**Enforcement:**

```python
async def do_distill_merge(cluster, llm):
    estimated = estimate_tokens(cluster)
    try:
        await check_and_reserve(redis, estimated)
    except BudgetExceeded:
        logger.warning("skip_merge_budget", cluster_size=len(cluster))
        return None   # skip questa operazione, distill continua su altre
    result = await llm.complete(...)
    # Correggi con token reale (estimated è stima; actual arriva da LlmResponse)
    delta = (result.input_tokens + result.output_tokens) - estimated
    if delta != 0:
        await redis.incrby(f"llm:budget:{date.today().isoformat()}", delta)
    ...
```

**Cap raccomandati:**
- `500_000` token/giorno — default (copre uso intenso senza margine per bug)
- `2_000_000` — per team 3-5 device attivi
- `50_000` — modalità ultra-conservativa (1 sessione Claude Code tipica)

**Alerting:**
- A 80% cap → warning log + audit entry
- A 100% cap → skip operation + ntfy admin + audit entry
- Admin UI mostra barra progress giornaliera su `/admin/stats`

### ADR-013: WebAuthn via py_webauthn (Duo Labs) → conferma

**Context:** Alternative: `python-fido2` (Yubico, CTAP low-level), `AS207960/python-webauthn`.

**Decision:** `duo-labs/py_webauthn` v2.7.1+.

**Rationale:**
- Più maturo (Duo Labs / Cisco)
- API high-level perfetta per server WebAuthn (generate/verify options)
- Supporta passkey (resident keys)
- Versione 2.7.1 (feb 2026) attualmente maintained

---

## Policy Aggiornamento

### Quando aggiornare

| Tipo | Trigger | Owner |
|------|---------|-------|
| **Patch release** (X.Y.Z-1 → X.Y.Z) | Dependabot PR auto-merge se CI pass | Bot |
| **Minor release** (X.Y → X.Y+1) | Review settimanale, merge se changelog non introduce breaking | Maintainer |
| **Major release** (X → X+1) | ADR review + migration plan + test completo | Maintainer + team review |
| **Security release** (CVE HIGH+) | Entro 48h (24h se CRITICAL) | Maintainer priority |

### Check schedule

- **Settimanale:** Dependabot alert review
- **Mensile:** `make audit-python && make audit-node && make scan-image` in CI
- **Trimestrale:** review completa di DEPENDENCIES.md + ADR, aggiornare questo file
- **Annuale:** review major version stack (Python, PG, Redis, Node)

### Rollback Plan

Ogni PR major update **deve** avere:
- Branch `rollback-<feature>` con immagine precedente taggata
- Istruzioni step-by-step in commit message
- DB migration **reversibile** (Alembic downgrade testato)
- `docker compose rollback.yml` che re-deploya tag precedente

### Come verificare "siamo aggiornati?"

```bash
# Python deps
make audit-python

# Node deps (plugin + UI)
make audit-node

# Container image CVE
make scan-image

# Check versioni dichiarate in DEPENDENCIES.md vs installate
make deps-check
```

Il target `make deps-check` (da implementare in F11) confronta versioni in
requirements.txt / package.json vs versioni massime disponibili e stampa diff.

---

## Known Limitations / Accepted Risks

1. **Python 3.14 free-threading è experimental**: alcuni package C non hanno ancora wheels cp314t. Monitoriamo via `pip install --only-binary :all:` in CI.
2. **Ollama quantization**: Q4_K_M per Qwen3.5-9B perde ~1-2% qualità rispetto FP16. Accettato per constraint home server (no GPU).
3. **jina-reranker-v2 testato su corpus < 10k entries**: qualità oltre potrebbe differire. Mitigazione: feature flag disattiva.
4. **Redis 8 Bloom filter**: dati bloom non persistenti di default. Configuriamo `appendonly yes` per AOF — ogni `BF.ADD` scrive su AOF.
5. **PostgreSQL 18 virtual generated columns**: supporto completo in migration richiede Alembic >= 1.14 (verifica ogni migration).
