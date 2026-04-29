# Task Breakdown — MemoryMesh

> Aggiorna lo stato a ogni sessione: `[ ]` → `[~]` → `[x]`.
> Carica questo file all'inizio di ogni sessione per sapere dove sei.

## Legenda

| Simbolo | Significato |
|---------|-------------|
| `[ ]` | Da fare |
| `[~]` | In corso |
| `[x]` | Completato |
| `[!]` | Bloccato — aggiungi nota |

**Effort:** XS<2h · S=2-4h · M=4-8h · L=1-2gg · XL=2-4gg
**Modello:** Opus=architettura/logica/security · Sonnet=scaffolding/config/test

---

## Fase 1 — Infrastruttura e Database
> Stack Docker funzionante, schema DB applicato, Ollama pronto.
> Prerequisito: Docker + Compose v2 sul mini PC.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F1-01 | Repo, Makefile, .env.example, README quickstart, CI skeleton, pre-commit gitleaks | S | Sonnet | — | `[x]` |
| F1-02 | Docker Compose completo (tutti i servizi, health check) | M | Sonnet | F1-01 | `[x]` |
| F1-03 | PostgreSQL + pgvector (image, init.sql, config) | S | Sonnet | F1-02 | `[x]` |
| F1-04 | Schema DB completo + Alembic (obs, manifest, vocab, sessions, token_metrics, query_fingerprints, project_manifest_meta) incluse colonne scope/last_used_at/access_count/token_estimate/shortcode/is_root/scope_path e tabella opzionale manifest_entries_accessed (se MEMORYMESH_FP_LOGGING=true) | L | **Opus** | F1-03 | `[x]` |
| F1-05 | Redis Streams (embed_jobs, distill_jobs, consumer groups) | S | Sonnet | F1-02 | `[x]` |
| F1-06 | Ollama (MAX_LOADED_MODELS=1, KEEP_ALIVE=5m, pull script) | S | Sonnet | F1-02 | `[x]` |
| F1-07 | Caddy config (LAN http + HTTPS opzionale) | S | Sonnet | F1-02 | `[x]` |
| F1-08 | Backup pg_dump schedulato + smoke test bash | S | Sonnet | F1-06 | `[x]` |
| F1-09 | mDNS broadcaster (zeroconf, annuncia `_memorymesh._tcp.local`, docker-compose host network o avahi sidecar) | M | **Opus** | F1-02 | `[x]` |

**DoD Fase 1:** `make up` OK, smoke test passa, psql raggiungibile da secondo PC LAN, Ollama risponde.

**Note critiche:**
- F1-04: schema definitivo — ogni errore qui crea debito. Include `vocab_entries` con tutti gli indici. Indice HNSW `m=16, ef_construction=64`. Partial index `WHERE distilled_into IS NULL`. One-liner adattivi per tipo (vedi ARCHITECTURE §2). Nuove colonne: `observations.scope TEXT[]`, `observations.last_used_at`, `observations.access_count`, `observations.token_estimate`; `manifest_entries.scope_path`, `manifest_entries.is_root`; `vocab_entries.shortcode` (UNIQUE). Nuove tabelle: `query_fingerprints`, `token_metrics`. Indici GIN su `scope`, B-tree composito su `(is_root, scope_path)`, indice LRU su `(last_used_at DESC, access_count DESC)`.
- F1-06: script init pull `nomic-embed-text` + `qwen3:8b` solo se non già presenti. Opzionale `BAAI/bge-reranker-base` via sentence-transformers cache dir (per Strategia 15).

---

## Fase 2 — API Core e Autenticazione
> FastAPI funzionante, auth, CRUD observations, manifest token-efficiente.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F2-01 | Struttura FastAPI (routers, services, schemas, config) | S | Sonnet | F1-02 | `[x]` |
| F2-02 | Auth API Key (middleware SHA-256, 401/403, key generation) | M | **Opus** | F2-01 | `[ ]` |
| F2-03 | CRUD observations tipizzate (POST 202, batch fetch, DELETE) | M | **Opus** | F2-02, F1-04 | `[ ]` |
| F2-04 | Gestione utenti e progetti (is_team, parent_id, enforcement) | M | **Opus** | F2-02 | `[ ]` |
| F2-05 | GET /manifest (budget token, one-liner adattivi, ETag) con scope_prefix + root_only + serializzazione deterministica cache-stable | M | **Opus** | F2-03 | `[ ]` |
| F2-05b | GET /manifest/delta (since_etag, added/removed) per session-level delta encoding | M | **Opus** | F2-05 | `[ ]` |
| F2-05c | GET /agents-md (Markdown formattato cache-stable + volatile con marker, ETag) per Codex e altri agent non-hook | M | **Opus** | F2-05, F4-03 | `[ ]` |
| F2-06 | GET /stats e GET /health (DB, Redis, Ollama, queue depth, token_efficiency dettagliato) | S | Sonnet | F2-03 | `[ ]` |
| F2-06b | POST /metrics/session + GET /metrics/session/{id} (Strategia 18) | S | Sonnet | F2-06 | `[ ]` |
| F2-07 | Rate limiting slowapi per-user via Redis | S | Sonnet | F2-02 | `[ ]` |
| F2-07b | Capping at write in POST /observations (tiktoken, MAX_OBS_TOKENS, enqueue tighten job) | M | **Opus** | F2-03 | `[ ]` |
| F2-08 | Test API (pytest + testcontainers, auth, type validation, scope, capping, delta) | L | Sonnet | F2-07b | `[ ]` |
| F2-09 | POST /api/v1/pair (validazione PIN da Redis, one-shot, rate limit per IP, genera api_key + device_keys row, audit) | L | **Opus** | F2-03, F10-01 | `[ ]` |
| F2-10 | GET /api/v1/mdns-info + GET /api/v1/projects?slug= (auto-detection support) + POST /api/v1/projects esteso git_remote | S | Sonnet | F2-04 | `[ ]` |
| F2-11 | Security headers middleware (CSP, HSTS, X-Frame-Options, ecc.) + profile detection (MEMORYMESH_DEPLOYMENT) | M | **Opus** | F2-01 | `[ ]` |
| F2-12 | Payload size limits (Caddy + Pydantic), global exception handler (no stack trace leak) | S | **Opus** | F2-01 | `[ ]` |
| F2-13 | Rate limit middleware slowapi per endpoint + Caddy global limit + fail2ban jail config | M | **Opus** | F2-07 | `[ ]` |
| F2-14 | SSRF egress blocklist (httpx wrapper `safe_fetch` con RFC1918 block + resolver check + no-follow-redirect) | S | **Opus** | F2-03 | `[ ]` |
| F2-14b | Ollama client hardening: timeout 60s, no-follow-redirect, validate response schema Pydantic, abort on unexpected URL in response content (indirect SSRF defense) | S | **Opus** | F2-14 | `[ ]` |
| F2-15 | DB users separati (mm_api/mm_worker/mm_admin con GRANT distinti) + Row-Level Security policies | M | **Opus** | F1-04 | `[ ]` |
| F2-16 | Secret scrubbing at capture (pattern + entropy detection, applicato in POST /observations lato server come defense in depth) | M | **Opus** | F2-03 | `[ ]` |
| F2-17 | Prompt injection detection (pattern dangerous + obs quarantine, non-root manifest fino a admin review) | M | **Opus** | F2-03, F2-16 | `[ ]` |
| F2-18 | API key rotation flow (POST /device/rotate-key, header X-MemoryMesh-Rotate-Available, grace period 7gg) | M | **Opus** | F2-09 | `[ ]` |
| F2-19 | Budget cap atomic Redis INCRBY, BudgetedLlm wrapper, llm_api_calls audit table, pricing table, notify_admin_ntfy integration, `/admin/llm-usage` endpoint (daily+monthly stats) | L | **Opus** | F5-01, F1-04 | `[ ]` |
| F2-20 | Secret scrubbing fail-closed pre-cloud LLM (integrazione BudgetedLlm + ValueError su system prompt tainted) | S | **Opus** | F2-19, F2-16 | `[ ]` |

**DoD Fase 2:** tutti gli endpoint rispondono correttamente, test passa, manifest con ETag funzionante.

**Note critiche:**
- F2-02: API key raw mostrata UNA sola volta, salva solo SHA-256.
- F2-03: POST risponde 202 SUBITO, pubblica job Redis prima di rispondere. Accetta `scope[]` e `token_estimate` nel body.
- F2-05: ETag = hash(serializzazione deterministica). Root ETag stabile cambia solo dopo distillazione root. Branch ETag scope-specific. Ordering: `ORDER BY priority, id` per root (cache-stable, no timestamp); branch accetta `age_hours`. One-liner max chars: identity/directive=80, context=40, bookmark=35, observation=20. Vedi CONVENTIONS §Serializzazione Cache-Stable.
- F2-05b: delta restituisce solo entries aggiunte/rimosse dalla `since_etag` in poi. Payload cap 20 entries — oltre, client forza full refresh.
- F2-07b: valida `token_estimate` lato server con tiktoken (non fidarsi del client). Se eccede `MAX_OBS_TOKENS`: tronca, salva `full_content` in metadata, pubblica `tighten_jobs`.

---

## Fase 3 — Embedding Worker e Ricerca Ibrida
> Ricerca semantica funzionante, RRF pesato, cache Redis.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F3-01 | Embedding Worker (Redis Stream consumer, retry, DLQ) usa EmbedCallback astratto (default Gemini text-embedding-004, Ollama opt-in via env). Task prefix `search_document:` per Ollama embed. | L | **Opus** | F1-05, F5-01b | `[ ]` |
| F3-02 | Ricerca vettoriale pgvector (pre-filter + partial index + scope filter) | M | **Opus** | F3-01 | `[ ]` |
| F3-03 | Ricerca FTS PostgreSQL (ts_rank, plainto_tsquery, ordering deterministico) | M | Sonnet | F2-03 | `[ ]` |
| F3-03b | BM25 Prelude service (short-circuit se score > BM25_SKIP_THRESHOLD) | S | **Opus** | F3-03 | `[ ]` |
| F3-04 | RRF merge (k=60, TYPE_WEIGHT × relevance_score) | M | **Opus** | F3-02, F3-03 | `[ ]` |
| F3-04b | Cross-encoder rerank service (bge-reranker-base, CPU, opt-out via env) | M | **Opus** | F3-04 | `[ ]` |
| F3-05 | Cache Redis search (decorator, TTL 5min, chiave include mode/rerank) | S | Sonnet | F3-04 | `[ ]` |
| F3-06 | GET /search top-5 default (mode=bm25\|vector\|hybrid, scope, rerank), GET /timeline, LRU update (last_used_at, access_count) | M | **Opus** | F3-04b, F3-05 | `[ ]` |
| F3-07 | Endpoint MCP-compatibili (/mcp/tools/* formato claude-mem) | M | Sonnet | F3-06 | `[ ]` |
| F3-08 | Test qualità (precision@5 > 0.70 hybrid, > 0.75 con rerank, latenza < 100ms LAN, BM25-only < 20ms) | M | Sonnet | F3-07 | `[ ]` |

**DoD Fase 3:** search semantica funziona, top-5 default, cache hit verificabile, MCP compat confermata.

**Note critiche:**
- F3-02: SEMPRE partial index `WHERE distilled_into IS NULL`. Fallback FTS se `embedding IS NULL`. Accetta `scope TEXT[]` per filtrare pre-ANN.
- F3-03b: BM25 prelude è il primo step nel servizio hybrid. Target: ~60% delle query short-circuit qui, 0 Ollama call. Soglia calibrabile via env.
- F3-04: `TYPE_WEIGHT = {identity:2.0, directive:1.8, context:1.2, bookmark:1.0, observation:0.8}`. Score = TYPE_WEIGHT × relevance_score / (60 + rank).
- F3-04b: caricamento modello solo se `SEARCH_RERANK_ENABLED=true`. Fallback automatico se import/init fallisce. Batching pair (query, one_liner) per evitare loop.
- F3-06: default `limit=5` (non 20). Parametro `expand=true` per avere fino a 20. Risposta compatta: `{id, type, one_liner, score}` — MAI full content. Include `mode_used`, `rerank_applied`. UPDATE `last_used_at` e `access_count += 1` sui risultati (non blocking).

---

## Fase 4 — Vocabolario Progetto
> Dizionario interno termini-specifici del progetto. Lookup zero-token.
> Leggi `docs/VOCAB.md` prima di iniziare.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F4-01 | Schema vocab_entries già in F1-04 — verifica shortcode UNIQUE e test isolato | S | Sonnet | F1-04 | `[ ]` |
| F4-02 | CRUD vocab (lookup esatto+fuzzy+semantic, upsert, delete, bloom rebuild on upsert) | M | **Opus** | F4-01 | `[ ]` |
| F4-03 | GET /vocab/manifest (serializzazione cache-stable sort term ASC, ETag, shortcode inline) | M | **Opus** | F4-02 | `[ ]` |
| F4-03b | GET /vocab/bloom (serializza bloom filter base64, ETag, Redis-backed) | S | Sonnet | F4-02 | `[ ]` |
| F4-04 | MCP tool vocab_lookup, vocab_search, vocab_upsert | M | Sonnet | F4-03 | `[ ]` |
| F4-05 | Skill file (~/.claude/memorymesh-vocab.md) + install script | S | Sonnet | F4-04 | `[ ]` |
| F4-06 | Test vocab (lookup fuzzy, manifest compatto, usage_count, shortcode collision-free, bloom roundtrip) | M | Sonnet | F4-05 | `[ ]` |

**DoD Fase 4:** vocab lookup funziona, manifest vocab < 250 token per 25 termini, skill installata.

**Note critiche:**
- F4-02: lookup cascade — esatto → fuzzy (rapidfuzz, soglia 80) → semantico (embedding). Incrementa `usage_count` a ogni lookup. `confidence=1.0` per manual, `=0.7` per auto.
- F4-03: formato ultra-compatto: `[entity] Term=def·detail` su una riga. Nessun JSON overhead. Sort: `confidence DESC, usage_count DESC`.
- F4-05: la skill istruisce Claude a usare vocab_lookup PRIMA di chiedere contesto su un termine, e vocab_upsert quando incontra nuove entità. Vedi VOCAB.md §Skill.

---

## Fase 5 — Typed Memory Engine e Agente Distillatore
> Extraction LLM, distillazione notturna, vocab auto-extraction.
> Leggi `docs/DISTILLATION.md` prima di iniziare.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F5-01 | LlmCallback + EmbedCallback Protocol (Python), LlmResponse dataclass, BudgetedLlm wrapper, factory DI da MEMORYMESH_LLM_PROVIDER env | M | **Opus** | — | `[ ]` |
| F5-01a | GeminiLlmAdapter (google-genai SDK, response_mime_type JSON, Pydantic schema, implicit caching support) | M | **Opus** | F5-01 | `[ ]` |
| F5-01b | GeminiEmbedAdapter (text-embedding-004, batch support, retry) | S | Sonnet | F5-01 | `[ ]` |
| F5-01c | OllamaLlmAdapter (opt-in, format=json mode, stesso Protocol) + OllamaEmbedAdapter | M | Sonnet | F5-01 | `[ ]` |
| F5-01d | OpenAiLlmAdapter + AnthropicLlmAdapter (opt-in, bonus) | S | Sonnet | F5-01 | `[ ]` |
| F5-02 | POST /extract (extraction structured output, validazione) | L | **Opus** | F5-01, F2-03 | `[ ]` |
| F5-03 | Find merge candidates (pgvector cluster transitivo) | M | **Opus** | F3-01 | `[ ]` |
| F5-04 | Distillation pipeline (prune→merge→tighten→decay→vocab_extract→tighten_capped→shortcode→fingerprint→manifest→bloom) | XL | **Opus** | F5-01, F5-03 | `[ ]` |
| F5-05 | Vocab auto-extraction nel distillation job (Qwen3) | M | **Opus** | F5-04, F4-02 | `[ ]` |
| F5-05b | Tighten-capped step (rielabora observation con marker `[capped]` usando full_content) | S | **Opus** | F5-04 | `[ ]` |
| F5-05c | Shortcode assign step (deterministic, collision-free, mai revocato) | S | **Opus** | F5-05 | `[ ]` |
| F5-05d | Fingerprint aggregation step (pattern dai tool_sequence, top-N accessed_ids) | M | **Opus** | F5-04 | `[ ]` |
| F5-06 | Manifest builder cache-aware (is_root determinato, scope_path, ETag root+branch separati, sort deterministico) | M | **Opus** | F5-04 | `[ ]` |
| F5-06b | Bloom filter rebuild step (Redis 8 nativo BF.RESERVE/BF.MADD in pipeline transactional, ETag in hash separato, vedi ADR-004) | S | Sonnet | F5-06 | `[ ]` |
| F5-07 | APScheduler CRON 03:00, lock Redis, log statistiche per-step | M | Sonnet | F5-06 | `[ ]` |
| F5-08 | Team memory (is_team enforcement, read/write rules) | M | **Opus** | F2-04 | `[ ]` |
| F5-09 | Test distillazione (corpus 200 obs, idempotenza, stats, is_root stability, shortcode no collision) | L | Sonnet | F5-08 | `[ ]` |

**DoD Fase 5:** `make distill` riduce corpus test, manifest aggiornato, vocab arricchito automaticamente.

**Note critiche:**
- F5-04 è il task più complesso. Dedicagli una sessione Opus separata. Pipeline idempotente.
- F5-05: Qwen3 estrae termini dalle observation degli ultimi 2gg. Salva con `confidence=0.7, source='auto'`. Non sovrascrive termini manuali (`source='manual'`).
- F5-06: one-liner adattivi per tipo (vedi ARCHITECTURE §2). ETag = hash dell'output per manifest differenziale.

---

## Fase 6 — History Compression e Token Optimization
> Riduzione token in-session. Maggiore impatto sul consumo totale.
> Leggi `docs/TOKEN_OPT.md` prima di iniziare.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F6-01 | POST /sessions/{id}/compress (Qwen3 summary strutturato) | L | **Opus** | F5-01 | `[ ]` |
| F6-02 | Stima token history nel plugin con tiktoken cl100k_base (non chars/4) | S | Sonnet | — | `[ ]` |
| F6-03 | Trigger compressione in UserPromptSubmit (soglia, async) | M | **Opus** | F6-01, F6-02 | `[ ]` |
| F6-04 | Inject summary al turno successivo (sostituisce history) | M | **Opus** | F6-03 | `[ ]` |
| F6-05 | Skip manifest per sessioni brevi (< 3 turni) | S | Sonnet | — | `[ ]` |
| F6-06 | Test compressione (verifica risparmio token, no info loss) | M | Sonnet | F6-04 | `[ ]` |
| F6-07 | Prefix builder cache-stable lato plugin (serializzazione deterministica, boundary marker, test hash stability) | M | **Opus** | F6-02 | `[ ]` |
| F6-08 | Manifest delta consumer lato plugin (accumula delta in coda, flush soglia 30% branch) | M | **Opus** | F6-07 | `[ ]` |

**DoD Fase 6:** sessione di 20 turni consuma < 50% token rispetto a senza compressione.

**Note critiche:**
- F6-01: summary type='context', content strutturato (decisioni prese, file modificati, problemi risolti). Non narrativo — compatto e denso.
- F6-03: compressione asincrona — non blocca il turno corrente. Il summary è disponibile dal turno successivo.
- F6-05: traccia contatore turni in `~/.memorymesh/session_state.json`. Skip manifest se turni < 3.

---

## Fase 7a — Plugin Claude Code
> Monorepo: core (agent-agnostic) + adapter Claude Code (hook nativi).
> Leggi `PLUGIN.md` prima di iniziare.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F7a-01 | Setup monorepo (npm workspaces, packages/core, packages/adapter-claude-code, packages/adapter-codex, packages/cli) | M | Sonnet | — | `[ ]` |
| F7a-02 | @memorymesh/core: HTTP client (timeout 3s hard, retry, silent fail) | S | Sonnet | F7a-01 | `[ ]` |
| F7a-03 | @memorymesh/core: Offline buffer (jsonl, flush auto, max 500 items) | M | **Opus** | F7a-02 | `[ ]` |
| F7a-03b | @memorymesh/core: scope.ts (deriveScope da path + cwd, test edge cases) | S | Sonnet | F7a-01 | `[ ]` |
| F7a-03c | @memorymesh/core: bloom.ts (client bloom filter, sync TTL 1h, fail-open) | M | **Opus** | F7a-02, F4-03b | `[ ]` |
| F7a-03d | @memorymesh/core: fingerprint.ts (predict + feedback + batch_cache prewarm) | M | **Opus** | F7a-02 | `[ ]` |
| F7a-03e | @memorymesh/core: telemetry.ts (TokenTelemetry singleton, flush async) | M | Sonnet | F7a-02 | `[ ]` |
| F7a-03f | @memorymesh/core: prefix.ts + delta.ts (serializzazione stabile, consumer delta) | M | **Opus** | F7a-02 | `[ ]` |
| F7a-04 | Adapter CC: Hook SessionStart cache-aware (prefix + branch scope + bloom + fingerprint prefetch + fallback cache) | L | **Opus** | F7a-02..3f | `[ ]` |
| F7a-04b | Adapter CC: parsing header runtime Claude (`x-cache-read-input-tokens`) → telemetry | S | Sonnet | F7a-03e | `[ ]` |
| F7a-05 | Adapter CC: Hook PostToolUse (scope detection, tiktoken capping, fingerprint predict next) | M | **Opus** | F7a-03, F7a-03b | `[ ]` |
| F7a-06 | Adapter CC: Hook UserPromptSubmit (stima token, trigger compress, manifest delta injection) | M | **Opus** | F7a-02, F6-02, F6-08 | `[ ]` |
| F7a-07 | Adapter CC: Extract periodico ogni N sessioni (hook SessionEnd) | M | **Opus** | F7a-02 | `[ ]` |
| F7a-08 | Adapter CC: Hook Stop + SessionEnd (telemetry flush + fingerprint feedback + close) | M | **Opus** | F7a-05, F7a-07, F7a-03e | `[ ]` |
| F7a-09 | Adapter CC: installer (~/.claude/settings.json, skill file) | S | Sonnet | F7a-04 | `[ ]` |
| F7a-10 | CLI @memorymesh/cli: install, migrate, flush (comandi shared) | M | Sonnet | F7a-09 | `[ ]` |
| F7a-11 | Test E2E Claude Code reale (tutti gli scenari PLUGIN.md, incluso pair, slash commands, mDNS discovery) | L | **Opus** | F7a-10 | `[ ]` |
| F7a-12 | `.claude-plugin/plugin.json` manifest (hooks + MCP server + skills + commands + postInstall script, requires node ≥18) | S | Sonnet | F7a-01 | `[ ]` |
| F7a-13 | Slash commands markdown in `.claude-plugin/commands/`: mm-search, mm-vocab, mm-stats, mm-distill, mm-compact, mm-pair | M | Sonnet | F7a-12 | `[ ]` |
| F7a-14 | Post-install script zero-touch (mDNS discovery + PIN prompt + pair + git remote detection + device.json write 0600 perms) | L | **Opus** | F7a-02, F7a-12, F2-09 | `[ ]` |
| F7a-15 | mDNS discovery client (core, `multicast-dns` npm, timeout 3s, multi-result handling) | S | **Opus** | F7a-02 | `[ ]` |

**DoD Fase 7a:** Claude Code con plugin: prefisso cache-stable iniettato, branch scope-specific, tool use catturati con scope+capping, search via MCP (bm25/hybrid), compressione si attiva, telemetry flushata, funziona offline. **Cache hit rate >= 0.5 dopo 3 sessioni ripetute**.

**Regola assoluta:** il plugin non blocca MAI l'agente. Ogni HTTP call: timeout 3s hard.

---

## Fase 7b — Adapter Codex
> Supporto Codex day-1 via MCP (retrieve) + CLI prep/capture (injection+capture).
> Leggi `CODEX.md` prima di iniziare.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F7b-01 | Analisi formato Codex: `~/.codex/config.toml`, `~/.codex/sessions/*.json`, convenzioni AGENTS.md | M | **Opus** | — | `[ ]` |
| F7b-02 | Transcript parser `transcript.ts` (legge JSONL sessions, estrae tool events + usage + sequence) | M | **Opus** | F7b-01 | `[ ]` |
| F7b-03 | `agents-md.ts` merge idempotente con marker `<!-- @memorymesh:begin/end -->` | M | **Opus** | F7b-01 | `[ ]` |
| F7b-04 | CLI `memorymesh codex-prep` (scope detection, GET /agents-md con ETag, scrive INJECT.md, invoca agents-md merge) | M | **Opus** | F7b-03, F2-05c | `[ ]` |
| F7b-05 | CLI `memorymesh codex-capture` (parse transcript, POST /observations per tool, POST /sessions/compress se supera soglia, POST /metrics/session) | L | **Opus** | F7b-02, F7a-03 | `[ ]` |
| F7b-06 | Installer Codex (registra MCP server in `~/.codex/config.toml`, shell wrapper `cx` in `~/.local/bin`) | M | Sonnet | F7b-04, F7b-05 | `[ ]` |
| F7b-07 | Shell wrapper template `wrapper.sh.tpl` (PRE-prep, codex, POST-capture in background) | S | Sonnet | F7b-06 | `[ ]` |
| F7b-08 | Config env Codex (MEMORYMESH_CODEX_INJECT, CAPTURE, CAPTURE_BG) + integrazione in cli install | S | Sonnet | F7b-06 | `[ ]` |
| F7b-09 | Test E2E Codex reale (tutti gli scenari CODEX.md §Test, incluso cross-agent consistency) | L | **Opus** | F7b-08 | `[ ]` |

**DoD Fase 7b:** `cx <args>` funziona come drop-in di `codex`. AGENTS.md aggiornato idempotentemente, MCP tools raggiungibili, transcript catturato a fine sessione. Observation create via Claude Code appaiono in sessione Codex e viceversa. **Token saving atteso: -70% vs baseline senza MemoryMesh** (inferiore a Claude Code per assenza in-session compression).

**Note critiche:**
- F7b-02: il formato JSON del transcript Codex potrebbe cambiare fra versioni. Parsing difensivo (try/catch per turno), fallback gracefully se schema imprevisto.
- F7b-03: l'utente può avere un AGENTS.md pre-esistente custom — mai sovrascrivere, sempre append/replace SOLO fra marker.
- F7b-05: capture è best-effort — se transcript non leggibile (permessi, rotation) silent fail + log strutturato.
- F7b-07: fork+sleep invece di `trap EXIT` perché alcune versioni Codex usano SIGTERM che confonde il trap.

---

## Dipendenze Incrociate F7a ↔ F7b

Molti task dipendono dallo stesso core. Ordine consigliato:
```
F7a-01..03f  (core library completa)
  ├─→ F7a-04..11  (adapter Claude Code)
  └─→ F7b-01..09  (adapter Codex) ← in parallelo con F7a-09..11 se capacità
```

**Reuse esplicito:** F7b-05 (codex-capture) usa `scope.ts`, `tiktoken-shim`, `client`, `buffer` da core. Se hai fatto F7a-03 prima, F7b parte leggero.

---

## Fase 8 — Funzionalità Avanzate (Opzionale)

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F8-01 | Dashboard web (memorie per tipo, search, vocab, stats, token efficiency panel) | XL | Sonnet | F2-06 | `[ ]` |
| F8-02 | Export/Import Markdown (compatibile mnemonio) | M | Sonnet | F5-06 | `[ ]` |
| F8-03 | Monitoring Prometheus + Grafana dashboard | M | Sonnet | F2-06 | `[ ]` |
| F8-04 | Tailscale sidecar o Cloudflare Tunnel (accesso remoto) | M | Sonnet | F1-07 | `[ ]` |
| F8-05 | Notifiche context in scadenza (ntfy.sh/Telegram) | S | Sonnet | F5-07 | `[ ]` |

---

## Fase 9 — Predictive & Telemetry Loop (Opzionale, dopo 2 settimane di uso)
> Strategie che richiedono dati storici per taratura (16, 13 avanzato, 18 advanced).
> Inutile lanciare prima: il corpus fingerprint non esiste ancora.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F9-01 | Tabella `manifest_entries_accessed` (opzionale, flag FP_LOGGING) | S | Sonnet | F1-04 | `[ ]` |
| F9-02 | Tuning soglia `fingerprint_min_sessions` da dati reali (notebook/analisi) | M | Sonnet | F9-01, F5-05d | `[ ]` |
| F9-03 | Adaptive LRU budget tuning (correlazione access_count vs utilità manifest) | M | **Opus** | F5-06 | `[ ]` |
| F9-04 | Dashboard token efficiency con drill-down per strategia | L | Sonnet | F8-01 | `[ ]` |
| F9-05 | Alert cache hit rate < 0.5 per 3 giorni (ntfy.sh) | S | Sonnet | F2-06b | `[ ]` |
| F9-06 | Auto-tune `BM25_SKIP_THRESHOLD` da precision@5 su corpus reale | M | **Opus** | F3-03b, F3-08 | `[ ]` |
| F9-07 | Test long-run (8 settimane, verifica che cache hit rate non degradi) | L | Sonnet | F7-11 | `[ ]` |

**DoD Fase 9:** `avg_cache_hit_rate_7d` stabile > 0.7. Fingerprint prefetch
con precision > 0.6 sul pattern SessionStart. BM25 skip rate > 50% su corpus reale.

---

## Fase 10 — UI Admin (MFA protetta)
> Interfaccia web locale per consultare memorie e gestire impostazioni.
> Leggi `UI_ADMIN.md` prima di iniziare.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F10-01 | Schema admin (admin_users con single_admin trigger, admin_webauthn_credentials, admin_sessions, admin_audit_log, admin_settings) + Alembic | M | **Opus** | F1-04 | `[ ]` |
| F10-02 | Router `/admin/setup` (bootstrap 1-shot, genera TOTP secret cifrato, recovery codes, argon2 password) | M | **Opus** | F10-01 | `[ ]` |
| F10-03 | Router `/admin/login` (step password + step TOTP, mfa_session ephemerale Redis, rate limit stricter 5/min) | L | **Opus** | F10-02 | `[ ]` |
| F10-04 | Router `/admin/webauthn/{register,assert}` (libreria webauthn, challenge Redis TTL 5min, sign_count anti-replay) | L | **Opus** | F10-03 | `[ ]` |
| F10-05 | Session middleware (cookie httpOnly signed itsdangerous, CSRF double-submit, rotation su MFA, audit middleware) | L | **Opus** | F10-03 | `[ ]` |
| F10-06 | `/admin/me`, `/admin/logout`, `/admin/reauth` (MFA fresh window 5min per destructive) | M | **Opus** | F10-05 | `[ ]` |
| F10-07 | Router `/admin/memories` (list paginata + filter project/type/scope/q, GET/PATCH/DELETE/bulk-delete con audit) | L | **Opus** | F10-05 | `[ ]` |
| F10-08 | Router `/admin/vocab` (CRUD + rebuild-shortcodes manuale) | M | Sonnet | F10-05, F4-02 | `[ ]` |
| F10-09 | Router `/admin/sessions` (list + detail + force-compress) | M | Sonnet | F10-05 | `[ ]` |
| F10-10 | Router `/admin/settings` (GET tutte whitelistate, PUT singola con validazione type-aware, audit) | M | **Opus** | F10-05 | `[ ]` |
| F10-11 | Router `/admin/audit` (GET list filtrabile + POST /export async via job Redis, GET /export/{job_id} stato polling, GET /export/{job_id}/download one-shot streaming CSV, cleanup 24h) | L | **Opus** | F10-05 | `[ ]` |
| F10-12 | Router `/admin/stats` (stats esteso admin-only: sessions_active, failed_logins_today) | S | Sonnet | F10-05, F2-06 | `[ ]` |
| F10-13 | Setup workspace Nuxt 4 (nuxt.config SPA mode, @nuxt/ui, Pinia, VueUse, @simplewebauthn/browser, Tailwind tokens) | M | Sonnet | — | `[ ]` |
| F10-14 | Composables useApi/useAuth/useMfaFresh/useWebAuthn (gestione 401/403/mfa_required centralizzata) | M | **Opus** | F10-13 | `[ ]` |
| F10-15 | Pagine auth: /setup (QR + recovery codes), /login (password+TOTP/WebAuthn), /reauth modal | M | **Opus** | F10-14 | `[ ]` |
| F10-16 | Pagina /memories (tabella filtrabile, bulk actions con MFA fresh) + /memories/[id] (edit inline) | L | **Opus** | F10-15 | `[ ]` |
| F10-17 | Pagine /vocab, /vocab/[id], /sessions, /sessions/[id] | L | Sonnet | F10-16 | `[ ]` |
| F10-18 | Pagine /settings (form type-aware), /audit (tabella filtrabile + export CSV), /account/{totp,passkeys} | M | Sonnet | F10-16 | `[ ]` |
| F10-19 | Pagina / (dashboard widget: counts, token efficiency, attività recente, health) | S | Sonnet | F10-16, F10-12 | `[ ]` |
| F10-20 | Build pipeline (`pnpm generate` → api/app/static, Makefile ui-build, FastAPI static mount + SPA fallback /admin/{path:path}) | M | Sonnet | F10-13 | `[ ]` |
| F10-21 | Test E2E Playwright (19 scenari UI_ADMIN.md §Test, incluso pair flow) | L | **Opus** | F10-20 | `[ ]` |
| F10-22 | Router `/admin/pair/create` + `/pair/pending` + DELETE, Redis PIN storage TTL 5min con hash, constraint 3 pending max per admin | M | **Opus** | F10-05 | `[ ]` |
| F10-23 | Router `/admin/devices` (GET list, PATCH rename, DELETE revoke) con audit entries | M | Sonnet | F10-05 | `[ ]` |
| F10-24 | Pagina `/account/devices` (tabella devices + modal Pair new device con PIN + QR + countdown + polling pending) | M | **Opus** | F10-14, F10-22 | `[ ]` |

**DoD Fase 10:** UI raggiungibile su `http://mm.local/admin/`. Setup → login →
dashboard funziona. Tutti i scenari E2E passano. Audit log popolato per ogni
operazione. Rate limit verificato con test reale. Cookie httpOnly + SameSite
Strict confermato via DevTools. WebAuthn registration + assertion OK su
browser reale (Chrome + Safari).

**Note critiche sicurezza:**
- F10-22: PIN 6-digit numerico. Plaintext SOLO in Redis (TTL 5min). In DB solo `pin_hash` (SHA-256) per audit. Rate limit 10 attempts/15min per IP. Max 3 PIN pending per admin (403 alla 4a create).
- F10-02: `admin_users` ha UNIQUE trigger single-admin. Il setup è 1-shot:
  una seconda POST ritorna 409 anche con stesso payload.
- F10-03: l'errore 401 login è generico (`invalid_credentials`) — non
  distinguere username/password per prevenire enumeration. Failed login counter
  per IP in Redis (TTL 15min), NON per username.
- F10-04: sign_count va validato e aggiornato ogni assertion. Se il client
  manda counter <= stored: reject + audit `webauthn_replay_suspected`.
- F10-05: session cookie = UUID v4 signed con itsdangerous. Rotazione ad ogni
  login MFA (prevent fixation). Deve essere invalidato lato server (revoked_at)
  al logout, non solo unset cookie.
- F10-07: PATCH/DELETE invalida cache search Redis per il project. Re-embedding
  accodato se content cambia.
- F10-10: whitelist settings in codice, NON leggere la lista da DB. Modifica
  al secret key via UI = impossibile by design (non esposto).
- F10-13: `nuxt.config.ts` deve impostare `ssr: false` e `nitro.preset: 'static'`
  per generare pure HTML+JS copiabili. Test: `.output/public/index.html` deve esistere.
- F10-20: il routing FastAPI per `/admin/{path:path}` deve servire SEMPRE
  `index.html` (SPA fallback), MAI `path` come file. Le chiamate `/admin/login` (API)
  sono router separati e intercettati prima del catch-all.

---

## Fase 11 — Distribuzione e Marketplace
> Pubblicazione del plugin Claude Code e del CLI Codex per onboarding zero-touch.
> Leggi `INSTALL.md` per la UX target end-user.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F11-01 | Repo dedicato `memorymesh-marketplace` con `.claude-plugin/marketplace.json` pointing al tag release di `schengatto/memorymesh` | S | Sonnet | F7a-12 | `[ ]` |
| F11-02 | GitHub Actions release coreografato: 1) workflow_dispatch su `schengatto/memorymesh` con input version; 2) crea tag v* + crea GitHub Release con artifact; 3) trigger tramite `repository_dispatch` il workflow di `schengatto/memorymesh-marketplace` che aggiorna `marketplace.json` puntando al nuovo tag; 4) job finale smoke-test: fresh clone + install plugin → pair → deve funzionare entro 5min. Sequenza atomica: se smoke-test fallisce, rollback del marketplace.json al tag precedente. | L | **Opus** | F11-01 | `[ ]` |
| F11-03 | Build pipeline `@memorymesh/cli` (binary via `pkg` o `esbuild + node`), pubblicazione su npm | M | Sonnet | F7a-10 | `[ ]` |
| F11-04 | Script `make release` (incrementa versione in tutti i package, crea tag git, pusha) | S | Sonnet | F11-02, F11-03 | `[ ]` |
| F11-05 | README principale: quickstart 5 righe + link a INSTALL.md, immagini UI, badge | S | Sonnet | — | `[ ]` |
| F11-06 | INSTALL.md già esistente — verifica flow end-to-end su un PC vergine dopo ogni release | S | Sonnet | F11-02 | `[ ]` |
| F11-07 | Repo README GitHub con sezione "Claude Code plugin marketplace" che segnala l'URL di installazione | S | Sonnet | F11-01 | `[ ]` |
| F11-08 | Documentazione troubleshooting mDNS (avahi Linux, Bonjour Windows, VLAN) in INSTALL.md | S | Sonnet | — | `[ ]` |

**DoD Fase 11:** Su un PC pulito Linux/macOS/Windows, in ordine:
1. `git clone memorymesh && cp .env.example .env && make up` funziona
2. `http://mm.local/admin` serve SPA, bootstrap setup completabile
3. PIN generato dall'admin UI
4. `/plugin marketplace add github:schengatto/memorymesh-marketplace` + `/plugin install memorymesh` → post-install trova server via mDNS, prompta PIN, device.json scritto
5. Sessione Claude Code su un progetto con git remote → progetto auto-detected, prefix iniettato
6. **Tempo totale: < 10 minuti dal clone al funzionamento.**

**Note critiche distribuzione:**
- F11-01: il repo `memorymesh-marketplace` deve essere piccolo (solo marketplace.json + README). Nessun codice. Così update marketplace = piccolo commit, revertibile.
- F11-02: il workflow release è manuale-triggered (workflow_dispatch) con input version. Evita release accidentali su push.
- F11-05: il README principale NON duplica INSTALL.md, linka. Principio DRY.

---

## Fase 12 — Security Hardening & Audit
> Completamento controlli di sicurezza, audit pre-release, pen test.
> Leggi `SECURITY.md` prima di iniziare. Molti controlli base sono già
> distribuiti nelle fasi precedenti (F2-11..18, F7a-*, F10-*); questa fase
> chiude i gap e verifica il tutto end-to-end.

| ID | Task | Effort | Modello | Dipende | Status |
|----|------|--------|---------|---------|--------|
| F12-01 | Container hardening docker-compose (read_only, non-root, cap_drop ALL, seccomp profile custom, mem/pids limit, internal network) | M | **Opus** | F1-02 | `[ ]` |
| F12-02 | Dockerfile multi-stage con `--require-hashes` pip install, user non-root UID 1000, image digest pin | S | Sonnet | F12-01 | `[ ]` |
| F12-03 | CI security pipeline: pip-audit + npm audit + trivy image scan + gitleaks + detect-secrets. Severity HIGH/CRITICAL blocca merge. | L | **Opus** | F11-02 | `[ ]` |
| F12-04 | Signed releases (sigstore/cosign + GPG tag signing) + SBOM CycloneDX pubblicata come release asset | M | **Opus** | F11-02 | `[ ]` |
| F12-05 | Recovery codes con argon2id (refactor F10-02 — NO SHA-256) | XS | **Opus** | F10-02 | `[ ]` |
| F12-06 | SECRET_KEY key derivation HKDF per purpose (session-sign, totp-encrypt, audit-hmac, backup-encrypt) | S | **Opus** | F10-01 | `[ ]` |
| F12-07 | Backup encryption age con recipient key pubblica (chiave privata solo off-server) | M | **Opus** | F1-08 | `[ ]` |
| F12-08 | Audit log append-only (REVOKE UPDATE/DELETE, retention job separato con user mm_retention) | S | **Opus** | F10-05 | `[ ]` |
| F12-09 | Timing attack defense su login/pair (argon2 verify sempre anche se user null, jitter 200-250ms deterministic) | S | **Opus** | F10-03, F2-09 | `[ ]` |
| F12-10 | Session hijack detection (IP/UA change → force MFA fresh, > 3 IP diversi in session → revoca) | M | **Opus** | F10-05 | `[ ]` |
| F12-11 | Caddy TLS config per profile (lan/vpn/public): HSTS preload su public, TLS 1.3 only su public, internal CA su vpn | M | **Opus** | F1-07 | `[ ]` |
| F12-12 | fail2ban jail config per /admin/login (5 fail/min → 1h ban) e /api/v1/pair (20 fail/15min → 1h ban) | S | Sonnet | F12-11 | `[ ]` |
| F12-13 | Pen-test checklist execution (17 scenari SECURITY.md §17) con report formalizzato | L | **Opus** | F10-21, F7a-11, F7b-09 | `[ ]` |
| F12-14 | OWASP Top 10 2021 review documentato: mapping di ogni categoria a controlli MemoryMesh | M | **Opus** | F12-13 | `[ ]` |
| F12-15 | Prometheus + Alertmanager per metriche sicurezza (failed_login_rate, api_key_anomaly, cache_hit_drop, restart_rate) | M | Sonnet | F8-03 | `[ ]` |
| F12-16 | Runbook incident response (procedure admin compromise, api_key leak, DB dump) in SECURITY.md §14 | S | Sonnet | — | `[ ]` |
| F12-17 | Security disclosure policy (SECURITY.md §14.2): email + GPG key pubblica, 90gg coordinated disclosure | XS | Sonnet | — | `[ ]` |

**DoD Fase 12:**
1. Tutti i 17 scenari pen-test SECURITY.md §17 passano
2. CI pipeline blocca PR con vuln HIGH+
3. `trivy image` su immagine prod: 0 HIGH/CRITICAL
4. SSL Labs test profile public: **A+** (A minimo accettato)
5. Recovery codes: argon2 verificato
6. Audit log append-only verificato (tentativo UPDATE → error)
7. Container runtime: `docker inspect` conferma non-root + cap_drop
8. Backup restore test: file crittato, restore richiede chiave privata
9. OWASP Top 10 2021 mapping documentato
10. Pen-test report firmato dal maintainer

**Note critiche Fase 12:**
- F12-01: seccomp profile custom è un JSON con syscall allowlist. Base: clonare default Docker + rimuovere syscall non necessari (kexec, bpf, module_load, ecc.). Testare con `--security-opt seccomp=unconfined` che l'app funziona, poi restringere gradualmente.
- F12-03: il CI **deve** fallire se `pip-audit` o `trivy` trovano HIGH+ non mitigabili. Se un CVE è false positive per MemoryMesh (es. affetta funzionalità non usata), documentare in `.trivyignore` con motivazione + data review.
- F12-04: GPG key del maintainer pubblicata in GitHub profile + nel repo. Ogni release tag firmato. `git verify-tag v1.0.0` deve passare.
- F12-07: chiave privata age MAI in repo, MAI in .env del server. Documentato in INSTALL.md §Backup.
- F12-09: il jitter deve essere deterministico (hash del username) per non introdurre side-channel via timing varianza. Vedi implementation in UI_ADMIN.md.
- F12-13: eseguito su staging identico a prod, con fuzzing tool (ffuf, burp). Report include screenshots + curl commands per ogni finding.

## Riepilogo Effort

| Fase | Descrizione | Giorni | Task | Prevalente |
|------|-------------|--------|------|------------|
| F1 | Infrastruttura e DB | 4-5 | 8 | Sonnet (1 Opus, schema esteso) |
| F2 | API Core (con manifest cache-aware, delta, capping, metrics, /agents-md) | 5-7 | 12 | Opus + Sonnet |
| F3 | Embedding, Ricerca BM25/hybrid, Rerank | 5-6 | 10 | Opus + Sonnet |
| F4 | Vocabolario + Shortcode + Bloom | 3-4 | 7 | Opus + Sonnet |
| F5 | Distillazione + Vocab + Shortcode + Fingerprint + Bloom rebuild | 6-7 | 13 | Opus intensivo |
| F6 | History Compression + Prefix builder + Delta consumer | 4-5 | 8 | Opus + Sonnet |
| F7a | Plugin Claude Code (core + adapter CC, cache-aware) | 6-7 | 15 | Opus + Sonnet |
| F7b | Adapter Codex (CLI prep/capture, AGENTS.md injection, transcript) | 4-5 | 9 | Opus + Sonnet |
| F8 | Avanzate (opz.) | 3-4 | 5 | Sonnet |
| F9 | Predictive & Telemetry Loop (post 2-settimane) | 4-5 | 7 | Opus + Sonnet |
| F10 | UI Admin (Nuxt SPA + MFA TOTP/WebAuthn + Devices/Pair) | 11-14 | 24 | Opus + Sonnet |
| F11 | Distribuzione (marketplace + CI release + README) | 2-3 | 8 | Sonnet |
| F12 | Security Hardening & Audit (container, CI scan, sign, pen-test) | 8-10 | 17 | Opus intensivo |
| **MVP F1-F7a** (solo Claude Code, no UI) | | **34-42 gg** | **77** | ~60% Opus |
| **MVP F1-F7b** (Claude Code + Codex, no UI) | | **38-47 gg** | **86** | ~60% Opus |
| **MVP + UI + Distribuzione** (F1-F7b + F10 + F11) | | **51-64 gg** | **118** | ~58% Opus |
| **MVP + UI + Distrib + Security** (F1-F7b + F10 + F11 + F12) | | **59-74 gg** | **135** | ~60% Opus |
| **Completo tutto** (F1-F12 + F8 + F9) | | **66-84 gg** | **147** | ~58% Opus |

---

## Sequenza Sessioni Consigliata

```
Settimana 1 — Fondamenta (Sonnet heavy):
  S1: F1-01..F1-03, F1-05..F1-08   (Sonnet)
  S2: F1-04                          (Opus — schema DB, prenditi il tempo)
  S3: F2-01, F2-06, F2-07           (Sonnet)
  S4: F2-02, F2-03                   (Opus)
  S5: F2-04, F2-05                   (Opus — manifest con ETag)
  S6: F2-08                          (Sonnet — test)

Settimana 2 — Search + Vocab (Opus heavy):
  S7: F3-01                          (Opus — embedding worker)
  S8: F3-02, F3-03, F3-04           (Opus — RRF)
  S9: F3-05..F3-08                   (Sonnet — cache + test)
  S10: F4-01..F4-03                  (Opus — vocab CRUD e manifest)
  S11: F4-04..F4-06                  (Sonnet — MCP tools + skill + test)

Settimana 3 — Distillazione (Opus intensivo):
  S12: F5-01, F5-02                  (Opus — LlmCallback + extract)
  S13: F5-03, F5-04                  (Opus — la sessione più densa)
  S14: F5-05                         (Opus — vocab auto-extraction)
  S15: F5-06..F5-09                  (Sonnet — scheduler + test)

Settimana 4 — Compression + Prefix + Core library:
  S16: F6-01..F6-04                  (Opus — compressione history)
  S17: F6-05..F6-08                  (Sonnet/Opus — prefix builder + delta)
  S18: F7a-01..03                    (Sonnet/Opus — monorepo + core base)
  S19: F7a-03b..03f                  (Opus — bloom, fingerprint, telemetry, prefix)

Settimana 5 — Adapter Claude Code:
  S20: F7a-04, F7a-04b               (Opus — SessionStart cache-aware + header)
  S21: F7a-05, F7a-06                (Opus — PostToolUse + UserPromptSubmit)
  S22: F7a-07..F7a-10                (Sonnet — SessionEnd + installer + CLI)
  S23: F7a-11                        (Opus — test E2E Claude Code)

Settimana 6 — Adapter Codex:
  S24: F7b-01, F7b-02                (Opus — analisi formato + transcript parser)
  S25: F7b-03, F7b-04                (Opus — agents-md merge + codex-prep)
  S26: F7b-05                        (Opus — codex-capture)
  S27: F7b-06..F7b-08                (Sonnet — installer + wrapper + config)
  S28: F7b-09                        (Opus — test E2E Codex + cross-agent)

Settimane 7-8 — UI Admin (parallelizzabile con F8/F9):
  S29: F10-01, F10-02                (Opus — schema admin + /admin/setup)
  S30: F10-03, F10-04                (Opus — login flow + WebAuthn)
  S31: F10-05, F10-06                (Opus — session middleware + reauth)
  S32: F10-07                        (Opus — /admin/memories + bulk ops)
  S33: F10-08..F10-12                (Sonnet — vocab/sessions/settings/audit/stats)
  S34: F10-13, F10-14                (Sonnet/Opus — Nuxt setup + composables)
  S35: F10-15                        (Opus — auth flow UI: setup, login, reauth)
  S36: F10-16                        (Opus — pagine memories con edit inline)
  S37: F10-17, F10-18                (Sonnet — pagine vocab/sessions/settings/audit/account)
  S38: F10-19, F10-20                (Sonnet — dashboard + build pipeline)
  S39: F10-21..F10-24                (Opus — test E2E + pair create + devices + UI pair)

Settimana 9 — Distribuzione:
  S40: F11-01, F11-02                (Sonnet — marketplace repo + CI release)
  S41: F11-03, F11-04                (Sonnet — CLI npm + make release)
  S42: F11-05..F11-08                (Sonnet — README + troubleshooting + dry-run install)
```

**Regole per ogni sessione:**
- Aggiorna `[~]` e `[x]` in questo file
- Usa `/compact` dopo ogni task in F3, F5, F6, F7a, F7b
- Una sessione = una fase logica, non mischiare fasi diverse
- Per F5: carica anche DISTILLATION.md come contesto aggiuntivo
- Per F7a: carica anche PLUGIN.md come contesto aggiuntivo
- Per F7b: carica CODEX.md + PLUGIN.md (core shared)
