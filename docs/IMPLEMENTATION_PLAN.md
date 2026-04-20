# MemoryMesh — Analisi Tecnica e Piano di Implementazione

> Documento di riferimento per pianificazione e review. Per breakdown di dettaglio
> vedi `TASKS.md`. Per decisioni tecnologiche vedi `DEPENDENCIES.md`. Per threat
> model e hardening vedi `SECURITY.md`.

**Versione:** 1.0 · **Data:** aprile 2026 · **Target rilascio:** Q4 2026

---

## TL;DR

MemoryMesh è un sistema di memoria persistente condivisa per agenti AI (Claude
Code + Codex day-1), che sostituisce `claude-mem` come drop-in MCP-compatible.
Gira su home server in Docker, accessibile via LAN o internet (Tailscale/Cloudflare
Tunnel). Ottimizza aggressivamente il consumo token (-85% vs baseline senza memoria).
Include UI admin Nuxt 4 con MFA (TOTP + WebAuthn). LLM default via Gemini 2.5
Flash, con opt-in Ollama locale per privacy-strict. Onboarding device in 30 secondi
via PIN pairing + mDNS discovery.

**MVP completo:** 59-74 giorni di lavoro single-dev (135 task). **MVP minimale
funzionante:** 18-22 giorni (73 task core F1-F7a senza UI/distribuzione).

**Stack:** Python 3.14 + FastAPI + PostgreSQL 18 + Redis 8 + Nuxt 4 + Gemini API.
**Deployment:** Docker Compose. **RAM server:** da 2.75 GB (profile A) a 9.15 GB
picco (profile C).

---

# Parte 1 — Analisi Tecnica

## 1.1 Contesto e Problema

### Il problema

Claude Code (e agenti analoghi come Codex) perdono completamente il contesto fra
sessioni. Ogni volta che apri una nuova sessione su un progetto:
- l'agente non sa cosa hai deciso ieri
- non conosce il vocabolario specifico del tuo progetto
- deve reimparare convenzioni, pattern, preferenze
- ripaga token per riempire il contesto da zero

Soluzioni esistenti (claude-mem, lostcat, Letta) hanno limitazioni:
- **claude-mem**: single-user, single-device, SQLite locale, poco scalabile
- **Letta**: complesso, overkill per uso single-user/famiglia
- **mnemonic / generici**: non ottimizzano specificamente per i token cost

### La soluzione

MemoryMesh è un servizio self-hosted che:
1. **Cattura automaticamente** ogni Edit/Write/Bash/WebFetch dell'agente (via hook
   nativi Claude Code + transcript post-session Codex)
2. **Distilla** periodicamente memorie ridondanti in fatti durevoli (via LLM)
3. **Inietta** un prefisso cache-stable all'inizio di ogni sessione (vocab + contesto
   root), sfruttando prompt caching nativo di Anthropic/OpenAI
4. **Espone MCP tools** per search/retrieve on-demand
5. **Condivide** tutto fra device e fra agenti (Claude Code + Codex + qualunque
   MCP-capable)

### Tre obiettivi non negoziabili

1. **Condivisione seamless** fra sessioni, device, agenti (zero attrito per utente)
2. **Minimizzazione token** aggressiva (target -85% vs baseline senza memoria)
3. **Core agent-agnostic**: aggiungere nuovo agente (Cursor, Windsurf) = scrivere
   adapter ~200 righe, mai toccare server o core library

## 1.2 Architettura One-Pager

```
┌────────────────────────── DEVICE UTENTE ────────────────────────────┐
│                                                                      │
│  Claude Code / Codex / Cursor / …                                    │
│        │                                                              │
│        ├──▶ hooks native (Claude Code) ──▶ @memorymesh/adapter-cc   │
│        ├──▶ CLI prep/capture (Codex)   ──▶ @memorymesh/adapter-codex│
│        └──▶ MCP tools (any)            ──▶ HTTP /mcp/*              │
│                                                                      │
│              ↕ @memorymesh/core (agent-agnostic)                    │
│              ↕ device.json 0600 (api_key, project, url)             │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ HTTPS (profile vpn/public) o HTTP (lan)
                               │ mDNS _memorymesh._tcp.local            
                               ▼
┌────────────────────────── SERVER DOCKER ────────────────────────────┐
│                                                                      │
│  Caddy (reverse proxy, TLS auto, rate limit)                        │
│      │                                                               │
│      ├─── /admin/*  ── FastAPI admin plane (cookie+MFA)             │
│      │                       │                                        │
│      │                       └── SPA Nuxt 4 statica (/static/)      │
│      │                                                                │
│      ├─── /api/v1/* ── FastAPI data plane (X-API-Key)               │
│      │                       │                                        │
│      │                       ├── manifest (scope-aware, delta)       │
│      │                       ├── search (BM25+vector+rerank)         │
│      │                       ├── observations (capture, batch)       │
│      │                       ├── vocab (lookup, upsert, bloom)       │
│      │                       ├── pair (PIN zero-touch onboarding)    │
│      │                       └── metrics/session (telemetry)         │
│      │                                                                │
│      └─── /mcp/*    ── MCP tools (compat claude-mem)                │
│                                                                       │
│  FastAPI workers:                                                    │
│      ├── embedding-worker    → EmbedCallback (Gemini default)        │
│      └── distillation-worker → LlmCallback (Gemini default)          │
│                                    + CRON 03:00                      │
│                                                                       │
│  PostgreSQL 18 + pgvector 0.8.2                                      │
│      ├── observations (scope, access_count, embedding)               │
│      ├── manifest_entries (is_root, scope_path)                      │
│      ├── vocab_entries (shortcode)                                   │
│      ├── sessions, device_keys, admin_*, llm_api_calls, ...          │
│      └── RLS multi-user isolation                                    │
│                                                                       │
│  Redis 8 (bloom nativo, queue, cache, rate limit, budget counter)    │
│                                                                       │
│  [opt profile=ollama] Ollama (nomic-embed-text-v2-moe, qwen3.5:9b)   │
│                                                                       │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ HTTPS
                               ▼
                     ┌──── Gemini API ─────┐
                     │ 2.5 Flash (LLM)     │
                     │ text-embedding-004  │
                     └─────────────────────┘
```

### Data plane vs Admin plane

Due superfici HTTP separate con auth differenti:

| Piano | Path | Auth | Consumer | Rate limit |
|-------|------|------|----------|-----------|
| Data plane | `/api/v1/*`, `/mcp/*` | `X-API-Key` (device_keys) | Plugin/adapter | 1000/min project |
| Admin plane | `/admin/*` | Cookie session + CSRF, MFA per destructive | SPA Nuxt | 5/min `/admin/login` |

## 1.3 Scelte Tecnologiche Chiave

Ogni scelta ha un ADR formalizzato in `DEPENDENCIES.md`. Tabella riepilogativa:

| Componente | Scelta | Alternativa valutata | ADR |
|-----------|--------|---------------------|-----|
| Web framework | **FastAPI 0.136** | Litestar (+2× perf) | ADR-001 (ecosystem AI) |
| Database | **PostgreSQL 18** | SQLite+sqlite-vec (più semplice) | ADR-002 (RLS, multi-user, uuidv7) |
| Rate limiting | **fastapi-limiter** | slowapi | ADR-003 (multi-worker Redis-native) |
| Bloom filter | **Redis 8 nativo** | pybloom-live | ADR-004 (zero deps, C-impl) |
| Runtime | **Python 3.14.4** | 3.12 | ADR-005 (free-threading) |
| Reranker | **jina-reranker-v2-base-multilingual** | bge-reranker-v2-m3 | ADR-006 (15× speed) |
| Embed model | **nomic-embed-text-v2-moe** | nomic v1 | ADR-007 (multilingue + Matryoshka) |
| LLM locale (opt-in) | **Qwen3.5-9B** | Llama 3.3, Gemma 3 | ADR-008 |
| Caddy rate-limit | **xcaddy custom build + mholt/caddy-ratelimit** | nginx / haproxy | ADR-009 |
| Container base | **python:3.14.4-slim** | distroless/chainguard | ADR-010 (debug friction) |
| Scheduler | **APScheduler in-process** | ofelia / cron container | ADR-011 (F12 review) |
| Admin SPA mode | **Nuxt 4 static generate** | SvelteKit, SSR | ADR-012 (single-container simplicity) |
| WebAuthn lib | **py_webauthn (Duo Labs) 2.7** | python-fido2 | ADR-013 (high-level API) |
| LLM default | **Gemini 2.5 Flash** | Ollama Qwen local | ADR-014 (RAM, qualità, cost) |
| LLM/Embed pattern | **Protocol provider-agnostic** | Hardcoded singolo provider | ADR-015 |
| Cost guardrail | **Hard daily token cap** | Circuit breaker / monitoring only | ADR-016 (anti bill shock) |

### Strategie token-first (18 documentate in TOKEN_OPT.md)

Impatto combinato: **-85% token input** vs sessione Claude Code senza MemoryMesh.

Le 5 più impattanti:
1. **Prompt caching nativo** (×10 su prefisso, Strategia 8) — ~10-15k token/sessione
2. **History compression** (Strategia 5) — 5-30k token/sessione lunghe
3. **Manifest gerarchico scope-based** (Strategia 9) — 400-800 token
4. **Manifest differenziale ETag** (Strategia 1) — 800-1.5k token
5. **Vocab shortcode binding** (Strategia 12) — -30/40% vocab manifest

## 1.4 Constraint e Non-Goals

### Constraint

- **Self-hosted obbligatorio**: no SaaS offering, nessun servizio centralizzato di Anthropic
- **Target hardware flessibile**: da RPi 5 4GB a mini PC 16GB (con profile C)
- **Docker-only deployment**: nessun install nativo supportato
- **LAN-first, internet optional**: profile=lan default, vpn/public opt-in
- **Single admin by design**: multi-admin = major version bump futura
- **Italiano + multilingue**: vocab/distillation supportano lingue multiple (modelli MoE)
- **Budget cloud <$5/mese**: default Gemini Flash con cap hard

### Non-Goals esplicitamente

- **Not an LLM gateway**: MemoryMesh non proxia chiamate dell'agente all'LLM. L'agente parla direttamente con Anthropic/OpenAI, MemoryMesh inietta solo contesto.
- **Not a vector DB marketplace**: una sola strategia vectore (pgvector HNSW), non pluggable con Qdrant/Milvus/Pinecone.
- **Not a prompt manager**: non salviamo prompt templates utente. Salviamo *observation* del lavoro agente.
- **Not a telemetry backend**: collectiamo metriche minime per anomaly detection, non siamo Prometheus/Datadog.
- **Non supportiamo GPU locale**: se vuoi GPU, usa un servizio cloud.
- **Non è un orchestratore agenti**: non lanciamo agenti, li serviamo memory.

## 1.5 Profili di Deployment

Tre profili configurabili via 2 env var (`MEMORYMESH_LLM_PROVIDER` + `MEMORYMESH_EMBED_PROVIDER`):

| Profile | LLM | Embed | Cloud flow | RAM server | Target hardware |
|---------|-----|-------|-----------|-----------|-----------------|
| **A (default)** | Gemini | Gemini | Observation → Google | ~2.75 GB | RPi 5 4GB / NAS / VM $6 |
| **B (ibrido)** | Gemini | Ollama | Solo LLM → Google | ~3.65 GB | RPi 5 8GB / mini PC |
| **C (privacy-strict)** | Ollama Qwen3.5 | Ollama | Zero cloud | ~3.65 GB baseline / ~9.15 GB picco | mini PC 16GB |

Tre profili di esposizione (via `MEMORYMESH_DEPLOYMENT=lan|vpn|public`):

| Deployment | TLS | HSTS | Rate limit | Raggiungibile da |
|-----------|-----|------|-----------|------------------|
| `lan` | opt | – | 1000/min IP | LAN privata |
| `vpn` | req (auto-cert) | – | 500/min IP | LAN + Tailscale/WireGuard |
| `public` | req (Let's Encrypt) | 1y preload | 300/min IP + fail2ban | Internet |

**Matrice combinata**: 3 LLM profiles × 3 deployment profiles = 9 configurazioni
supportate day-1. Selezionate solo via env, zero codice cambia.

## 1.6 Risk Assessment

| Rischio | Probabilità | Impatto | Mitigazione |
|---------|:-----------:|:-------:|-------------|
| Performance distillation notturna degrada con corpus > 10k obs | Media | Medio | Fase 9 tuning + batch processing + progressive cap |
| Gemini API outage prolungato | Bassa | Alto | Fallback designed: `MEMORYMESH_LLM_PROVIDER=ollama` runtime switch |
| Prompt cache invalidation accidentale (regression) | Media | Alto | Test E2E cache stability in F7a-11, alert < 0.5 hit rate |
| Observation poisoning via agent compromesso | Bassa | Alto | Secret scrubbing + prompt injection sanitization + quarantine |
| Bill shock cloud LLM da bug | Bassa | Alto | **Hard daily cap 500k token** (ADR-016), atomic Redis INCRBY |
| Dipendenza marketplace GitHub down | Bassa | Medio | Fallback: `npm install @memorymesh/cli` install manuale |
| Breaking change in Claude Code plugin API | Media | Alto | Adapter thin (300 righe), core agent-agnostic → fix in 1 giorno |
| Admin lockout (perde TOTP + recovery codes) | Bassa | Critico | CLI recovery `memorymesh admin reset-totp --with-recovery-code` |
| Multi-user isolation bug (cross-user data leak) | Bassa | Critico | RLS DB + test E2E + 3 utenti DB separati (mm_api/worker/admin) |
| Dependency supply chain compromise | Bassa | Critico | Signed releases, SBOM, CI security scan, lockfile pinning |
| Python 3.14 free-threading wheel gap per dep C | Media | Medio | CI `pip install --only-binary :all:`, fallback 3.13 |

## 1.7 Acceptance Criteria MVP

Il MVP è rilasciabile quando **tutti** questi criteri passano:

### Funzionali

- [ ] Plugin Claude Code installabile in 2 comandi via marketplace GitHub
- [ ] Onboarding nuovo device via PIN pairing + mDNS in < 45 secondi
- [ ] Manifest + vocab iniettati automaticamente a SessionStart
- [ ] Tool use Claude Code catturati e salvati come observations entro 5s
- [ ] Search via `/mm-search <query>` restituisce top-5 rilevanti in < 200ms
- [ ] Distillazione notturna compresse observations ridondanti (verificato corpus test 200 obs)
- [ ] Vocab auto-estratto e shortcode assegnati per termini con usage_count ≥ 10
- [ ] Codex funziona con stesso pairing (AGENTS.md injection + transcript capture)
- [ ] Cross-agent: observation creata da Claude Code appare in sessione Codex successiva
- [ ] Admin UI accessibile su `/admin/`, setup bootstrap + login TOTP funzionanti
- [ ] Admin può vedere/editare/eliminare memories, vocab, settings, audit log
- [ ] Fallback offline: plugin continua a funzionare se server down (buffer jsonl)

### Non-funzionali

- [ ] Sessione 20 turni consuma **< 30% token** vs baseline senza MemoryMesh
- [ ] Prompt cache hit rate **≥ 0.7** dopo 3 sessioni ripetute (test F7a-11)
- [ ] Latenza SessionStart end-to-end **< 200ms** con ETag cache hit
- [ ] Latenza search top-5 LAN **< 100ms**
- [ ] Plugin non blocca mai Claude Code: timeout hard 3s verificato
- [ ] Test E2E Playwright 19 scenari UI + 11 plugin + 11 Codex passano
- [ ] `trivy image` su memorymesh/api:latest → 0 HIGH/CRITICAL
- [ ] `pip-audit` + `npm audit` → 0 HIGH+
- [ ] CI security pipeline blocca merge su vulnerability HIGH+
- [ ] Backup `make backup` produce file cifrato (age)
- [ ] SSL Labs su profile public → grade **A+**
- [ ] Server gira su RPi 5 4GB profile A per ≥ 72h senza restart

### Documentazione

- [ ] INSTALL.md testato da utente fresco senza background MemoryMesh: flow funziona end-to-end
- [ ] README GitHub con quickstart 5 righe + link a INSTALL.md
- [ ] SECURITY.md con threat model + disclosure policy
- [ ] Tutti i 17 ADR in DEPENDENCIES.md documentati
- [ ] OpenAPI spec auto-generata da FastAPI, completa per ogni endpoint

---

# Parte 2 — Piano di Implementazione

## 2.1 Approccio

**Iterativo, sprint-based, value-first.** Ogni sprint di 3-5 giorni produce
un deliverable utilizzabile o un blocco di fondamenta necessarie per i prossimi.

**Principi:**
- **Incremental value**: dopo ogni milestone il sistema è ancora funzionante (non "tutto o niente")
- **Test-first per security-critical**: auth, crypto, budget cap — test prima di codice
- **Opus per architettura, Sonnet per scaffolding**: assignment modello in TASKS.md
- **Single-dev friendly**: l'ordine task permette lavoro sequenziale senza dependency lock
- **Parallelizzabile a 2 dev**: F7a + F7b + F10 possono andare in parallelo dopo F5

**Regola `/compact`:** usare compact Claude Code dopo ogni task in fasi dense (F3, F5, F6, F7, F10) per contenere context window.

## 2.2 Overview Fasi

Vedi `TASKS.md` per breakdown dettagliato. Sintesi:

| Fase | Descrizione | Task | Effort | Prevalente | Valore consegnato |
|------|-------------|-----:|-------:|------------|-------------------|
| F1 | Infrastruttura + schema DB | 9 | 4-5 gg | Sonnet + 1 Opus | Stack Docker up, DB vuoto |
| F2 | API core + security middleware | 20 | 7-9 gg | Opus + Sonnet | Observations CRUD + auth + rate limit |
| F3 | Embedding + ricerca ibrida | 10 | 5-6 gg | Opus + Sonnet | Search funzionante BM25/vector/rerank |
| F4 | Vocabolario + shortcode + bloom | 7 | 3-4 gg | Opus + Sonnet | Vocab CRUD + manifest injection |
| F5 | Distillation pipeline + LlmCallback multi-provider | 13 | 7-9 gg | Opus intensivo | Corpus che si auto-distilla notturnamente |
| F6 | History compression + prefix builder + delta | 8 | 4-5 gg | Opus + Sonnet | Sessioni lunghe senza token explosion |
| F7a | Plugin Claude Code (monorepo + adapter) | 15 | 6-7 gg | Opus + Sonnet | Plugin installabile con hook |
| F7b | Adapter Codex (CLI prep/capture) | 9 | 4-5 gg | Opus + Sonnet | Codex funziona con stessa memoria |
| F8 | Funzionalità avanzate (opzionale) | 5 | 3-4 gg | Sonnet | Dashboard, export, Tailscale |
| F9 | Predictive loop (post 2 settimane uso) | 7 | 4-5 gg | Opus + Sonnet | Fingerprint prefetch, tuning reale |
| F10 | UI Admin Nuxt 4 + MFA + devices | 24 | 11-14 gg | Opus + Sonnet | Admin web |
| F11 | Distribuzione (marketplace + CI release) | 8 | 2-3 gg | Sonnet | One-click install |
| F12 | Security hardening + audit + pen-test | 17 | 8-10 gg | Opus intensivo | Prod-ready public |

**Totali per scope target:**

| Scope | Fasi | Effort | Task |
|-------|------|-------:|-----:|
| MVP minimale (solo Claude Code, no UI) | F1-F7a | 34-42 gg | 77 |
| MVP + Codex | F1-F7b | 38-47 gg | 86 |
| MVP + Codex + UI + distribuzione | F1-F7b + F10 + F11 | 51-64 gg | 118 |
| **MVP completo prod-ready (raccomandato)** | F1-F7b + F10 + F11 + F12 | **59-74 gg** | **135** |
| Everything | F1-F12 + F8 + F9 | 66-84 gg | 147 |

## 2.3 Critical Path

Dipendenze hard (ordine obbligato):

```
F1-04 (schema DB)
    │
    ├─▶ F2-01 (FastAPI scaffold)
    │       │
    │       ├─▶ F2-02 (auth API key) ──▶ F2-03 (CRUD obs) ──▶ [resto F2]
    │       │                                   │
    │       │                                   └─▶ F3 (embed + search)
    │       │                                           │
    │       │                                           └─▶ F4 (vocab)
    │       │                                                   │
    │       │                                                   └─▶ F5 (distill)
    │       │                                                           │
    │       │                                                           └─▶ F6 (compress)
    │       │
    │       └─▶ F10-01 (admin schema)  (parallelo)
    │
    └─▶ F1-09 (mDNS broadcaster)  (indipendente)
                                                                        
Dopo F5 + F6:                                                          
    │                                                                  
    ├─▶ F7a (plugin Claude Code)  ─────┐                              
    ├─▶ F7b (adapter Codex)       ──┐  │  parallelizzabili             
    └─▶ F10 (UI admin)             ┘  │                                
                                      │                                
F11 (distribution) dopo F7a + F10     │                                
F12 (security hardening) dopo F7a+b + F10 + F11                        
```

**Critical path assoluto** (single-dev, no parallelizzazione):
`F1-01 → F1-04 → F2-03 → F2-05 → F3-04 → F3-06 → F4-03 → F5-04 → F5-06 → F6-04 → F7a-04 → F7a-11 → F11-02 → F12-13`

Lunghezza critical path: ~34-42 giorni (coincide con MVP minimale).

**Parallelizzabile con 2 dev dopo F6:**
- Dev 1: F7a + F11 (plugin + distribuzione)
- Dev 2: F10 (UI admin)
- Entrambi: F12 (security, ognuno su subset)

Con 2 dev, il MVP prod-ready cala a **~38-48 giorni**.

## 2.4 Milestone — Early Value Delivery

### Milestone 0 — "Hello Docker" (fine Sprint 1, ~5gg)

**Consegna:** Stack Docker up, DB schema creato, FastAPI risponde a `/health`.

- F1-01..F1-09 completi
- `make up` funziona, `curl http://mm.local/health` → 200
- DB ha schema vuoto ma completo (50 tabelle, indici, RLS policies, mm_api/worker/admin users)
- mDNS broadcaster annuncia `_memorymesh._tcp.local`

**Value:** zero per utente, ma fondamenta verificate. Base per tutti gli sprint seguenti.

### Milestone 1 — "API funzionante senza agente" (fine Sprint 2-3, ~12gg)

**Consegna:** Data plane API completa, testabile via curl + Swagger.

- F2-01..F2-20 completi (incluso security headers, payload limits, rate limits, secret scrub, budget cap wiring)
- F3-01..F3-08 completi (search ibrido + rerank funzionante)
- F4-01..F4-06 completi (vocab + bloom)
- Test API: pytest + testcontainers passa al 100%
- OpenAPI spec auto-generata

**Value:** sviluppatore terzo può usare MemoryMesh come servizio REST anche senza plugin. **MVP utilizzabile via curl.**

### Milestone 2 — "Distillation + compression" (fine Sprint 4-5, ~22gg)

**Consegna:** Corpus si auto-mantiene.

- F5-01..F5-09 completi (LlmCallback multi-provider + Gemini adapter + distillation pipeline)
- F6-01..F6-08 completi (history compression + prefix builder cache-stable + delta)
- Test distillation: corpus 200 obs → riduzione verificata, idempotenza OK
- Gemini API integration validated (budget cap + audit trail)

**Value:** corpus cresce e si comprime da solo. LLM features complete.

### Milestone 3 — "Plugin Claude Code" (fine Sprint 6-7, ~30gg)

**Consegna:** Claude Code con memoria.

- F7a-01..F7a-11 completi (plugin installabile + hook + slash commands)
- F11-01..F11-04 completi (marketplace repo + CI release)
- Test E2E Claude Code passa 19 scenari

**Value:** **utilizzatore finale beneficia**. Dimostrabile. Feedback reale possibile.

### Milestone 4 — "Codex + UI admin" (fine Sprint 8-10, ~45gg)

**Consegna:** Multi-agent + gestione visuale.

- F7b-01..F7b-09 completi (Codex adapter)
- F10-01..F10-21 completi (Nuxt SPA admin + MFA + devices)
- Test E2E Codex + UI passano

**Value:** utilizzatore può amministrare memory visualmente, pair nuovi device via QR, auditare.

### Milestone 5 — "Prod-ready" (fine Sprint 11-13, ~60-74gg)

**Consegna:** Rilasciabile pubblicamente.

- F11-05..F11-08 completi (README, docs, troubleshooting)
- F12-01..F12-17 completi (hardening, pen-test, signed releases)
- SSL Labs A+, trivy clean, SBOM pubblicata
- Documentazione INSTALL.md verificata su PC fresh

**Value:** public release. GitHub pubblico, annuncio, onboarding esterni possibile.

### (Post-release) Milestone 6 — "Optimize from data" (3+ mesi dopo release)

**Consegna:** Fase 9 predictive loop con dati reali.

- F9-01..F9-07 completi
- Fingerprint prefetch con corpus storico
- Tuning fine threshold

## 2.5 Sprint Breakdown (single-dev, 5gg/sprint)

```
Sprint 1 (gg 1-5):    "Infrastructure"
  ├─ Setup repo, CI skeleton, Makefile, secret scanning pre-commit hook
  ├─ Docker Compose base (postgres, redis, api stub, caddy)
  ├─ Schema DB completo + Alembic init
  ├─ init-roles.sh + init-db.sql applicabili
  └─ mDNS broadcaster zeroconf
  MILESTONE 0 ✓
  
Sprint 2 (gg 6-10):   "API Core Part 1"
  ├─ FastAPI scaffold (routers, services, schemas)
  ├─ Auth middleware API key
  ├─ CRUD observations (scope + token_estimate + capping)
  ├─ GET /manifest (root + branch + delta) con ETag
  ├─ Security headers + rate limit middleware + payload limits
  └─ Global exception handler
  
Sprint 3 (gg 11-15):  "API Core Part 2 + Embedding"
  ├─ Router /pair + /agents-md + /mdns-info
  ├─ Users + projects CRUD
  ├─ Rate limit + Budget cap middleware
  ├─ /metrics/session + /stats
  ├─ SSRF safe_fetch
  ├─ Secret scrubbing service
  └─ Embedding worker (EmbedCallback + Gemini adapter)
  MILESTONE 1 ✓
  
Sprint 4 (gg 16-20):  "Search + Vocab"
  ├─ Vector search pgvector + scope filter
  ├─ FTS + BM25 prelude + RRF
  ├─ Cross-encoder rerank (jina-reranker-v2)
  ├─ /search top-5 + LRU update
  ├─ MCP endpoints
  ├─ Vocab CRUD + bloom (Redis 8 nativo)
  └─ /vocab/manifest cache-stable
  
Sprint 5 (gg 21-27):  "Distillation + Compression"  ← Opus intensivo
  ├─ LlmCallback Protocol + BudgetedLlm + Gemini/Ollama/OpenAI/Anthropic adapters
  ├─ Pipeline distillation (prune → merge → tighten → decay → vocab → tighten_capped
  │   → shortcode → fingerprint agg → rebuild_manifest → rebuild_bloom)
  ├─ APScheduler CRON 03:00
  ├─ POST /sessions/{id}/compress
  └─ Test distillation su corpus 200 obs
  MILESTONE 2 ✓
  
Sprint 6 (gg 28-32):  "Compression + Prefix + Plugin Foundation"
  ├─ Manifest prefix builder cache-stable deterministic
  ├─ Delta consumer lato plugin
  ├─ Monorepo TypeScript setup (core + adapters + cli)
  ├─ @memorymesh/core base (client, buffer, scope, tiktoken)
  └─ bloom.ts + fingerprint.ts + telemetry.ts
  
Sprint 7 (gg 33-38):  "Plugin Claude Code"
  ├─ plugin.json manifest + slash commands (/mm-search, /mm-vocab, ecc.)
  ├─ Post-install script zero-touch (mDNS + PIN + git detect)
  ├─ Hook SessionStart cache-aware + UserPromptSubmit + PostToolUse
  ├─ Hook SessionEnd + telemetry flush + fingerprint feedback
  ├─ Installer + CLI memorymesh (install, migrate, flush)
  └─ Test E2E Claude Code (19 scenari)
  MILESTONE 3 ✓
  
Sprint 8 (gg 39-43):  "Codex Adapter"
  ├─ Analisi formato Codex (config.toml, sessions/*.json)
  ├─ Transcript parser + agents-md merge idempotente
  ├─ CLI memorymesh codex-prep (scope + /agents-md + INJECT.md)
  ├─ CLI memorymesh codex-capture (transcript → observations + metrics)
  ├─ Installer Codex + shell wrapper cx
  └─ Test E2E Codex + cross-agent consistency
  
Sprint 9 (gg 44-48):  "UI Admin Part 1 (backend + auth)"
  ├─ Router /admin/setup (bootstrap + TOTP + recovery codes argon2)
  ├─ Router /admin/login (step password + step TOTP/WebAuthn) + rate limit
  ├─ Router /admin/webauthn/* (register + assert, sign_count anti-replay)
  ├─ Session middleware (cookie httpOnly signed + CSRF double-submit)
  ├─ /admin/me + /admin/logout + /admin/reauth (MFA fresh window)
  └─ Audit middleware
  
Sprint 10 (gg 49-53): "UI Admin Part 2 (features)"
  ├─ Router /admin/memories (GET list + PATCH + DELETE + bulk-delete)
  ├─ Router /admin/vocab (CRUD + rebuild-shortcodes)
  ├─ Router /admin/sessions + /admin/settings (whitelist) + /admin/audit + export CSV
  ├─ Router /admin/pair/create + /admin/devices
  └─ Router /admin/stats + /admin/llm-usage
  
Sprint 11 (gg 54-58): "UI Admin Part 3 (Nuxt SPA)"
  ├─ Nuxt 4 setup + composables useApi/useAuth/useMfaFresh/useWebAuthn
  ├─ Pagine /setup /login /reauth con QR + recovery codes
  ├─ Pagina /memories (tabella + filter + bulk) + /memories/[id] edit
  ├─ Pagine /vocab /sessions /settings /audit /account/*
  ├─ Dashboard home + build pipeline (nuxi generate → api/app/static)
  └─ Test E2E Playwright (19 scenari + 5 pair flow)
  MILESTONE 4 ✓
  
Sprint 12 (gg 59-63): "Distribution + Security Part 1"
  ├─ Repo memorymesh-marketplace con marketplace.json
  ├─ GitHub Actions release coreografato (tag → build → sign → marketplace update → smoke test)
  ├─ CLI @memorymesh/cli publish npm
  ├─ README GitHub + quickstart
  ├─ Container hardening (read_only + cap_drop + seccomp + mem/pids limit)
  └─ Dockerfile multi-stage + pip --require-hashes
  
Sprint 13 (gg 64-68): "Security Part 2 + Pen-test"
  ├─ CI security pipeline (pip-audit + npm audit + trivy + gitleaks)
  ├─ Signed releases (sigstore + GPG) + SBOM CycloneDX
  ├─ Recovery codes argon2 refactor + HKDF key derivation per purpose
  ├─ Backup encryption age + restore test
  ├─ Audit log append-only + retention job
  ├─ Timing attack defense + session hijack detection
  └─ Caddy TLS per profile + fail2ban jails
  
Sprint 14 (gg 69-74): "Pen-test + Polish + Release"
  ├─ Pen-test checklist execution (17 scenari SECURITY.md)
  ├─ OWASP Top 10 mapping documentato
  ├─ Prometheus + Alertmanager + runbook incident response
  ├─ Security disclosure policy + email/GPG pubblico
  ├─ INSTALL.md verification su PC fresh
  ├─ Documentazione finale
  └─ Release v1.0.0
  MILESTONE 5 ✓ 🚀
```

**Timeline totale MVP prod-ready (single-dev, realistic):** 14 sprint = 70 giorni
lavorativi ≈ 14 settimane ≈ **3.5 mesi**.

### Scenario Ottimistico vs Pessimistico

| Scenario | Effort | Assunzioni |
|----------|-------:|------------|
| Ottimistico | 59 gg | Zero blocker, dipendenze stabili, test passano al primo shot |
| Realistico | 74 gg | 20% overhead debug/rework, 1 sprint perso su blocker tech |
| Pessimistico | 95 gg | Major regression in F5/F7, cambio design durante implementazione |

Buffer raccomandato: **+15%** sul realistico = 85 giorni (~4 mesi).

## 2.6 Parallelizzazione

### Single-dev (default)

Sequenza critical path come da §2.5. Stima 70-85 giorni.

### Team 2 dev

**Dopo Sprint 5 (fine F6)**, split:

```
Sprint 6+:  
  Dev A: F7a (plugin Claude Code) → F7b (Codex) → F11 (distribuzione)
  Dev B: F10 (UI admin backend + frontend)

Sprint 13+:
  Dev A + Dev B insieme: F12 (security hardening, review pen-test)
```

Riduzione: ~35% → **45-55 giorni**.

### Team 3 dev

**Dopo Sprint 5**, split:

```
Dev A: F7a (plugin Claude Code) + F11
Dev B: F7b (adapter Codex)
Dev C: F10 (UI admin)
All: F12 (security)
```

Riduzione: ~50% → **35-45 giorni**.

**Caveat:** più di 3 dev non accelera oltre — critical path F1→F2→F3→F4→F5 è sequenziale (schema DB + API core). Team size > 3 va dopo F5.

## 2.7 Quality Gates per Milestone

Ogni milestone **non è completo** finché questi gate non passano:

### Gate M0 (Infrastructure)
- [ ] `docker compose config` validate senza errori
- [ ] `make up` termina healthy per tutti i servizi
- [ ] Schema DB applicato via `make migrate`
- [ ] `curl http://mm.local/health` → 200
- [ ] mDNS visibile: `dns-sd -B _memorymesh._tcp`

### Gate M1 (API Core)
- [ ] OpenAPI spec completa (`curl /openapi.json` > 5000 righe)
- [ ] pytest API suite passa 100%
- [ ] Rate limit testato manualmente con bombardier/k6
- [ ] `trivy image` → 0 CRITICAL
- [ ] Secret scanning repo → clean

### Gate M2 (LLM integration)
- [ ] Corpus test 200 obs → distillation riduce di ≥ 30%
- [ ] Budget cap trigger testato (inject 1M token → skip)
- [ ] Secret scrubbing testato con observation fake-contaminata
- [ ] Provider switch verificato: `MEMORYMESH_LLM_PROVIDER=ollama` → distillation ancora funziona

### Gate M3 (Plugin Claude Code)
- [ ] Test E2E 19 scenari passa
- [ ] Prompt cache hit rate ≥ 0.5 dopo 3 sessioni identiche
- [ ] Plugin non blocca Claude Code (timeout 3s verificato)
- [ ] Offline buffer verificato (server down → 5 tool use → server up → flush)

### Gate M4 (UI + Codex)
- [ ] Playwright 19 scenari UI passa
- [ ] Test E2E Codex 11 scenari passa
- [ ] Cross-agent: observation CC visibile in Codex successivo
- [ ] WebAuthn testato con virtual authenticator
- [ ] Pair flow end-to-end < 45 secondi verificato

### Gate M5 (Prod-ready)
- [ ] Pen-test checklist 17 scenari passa
- [ ] SSL Labs A+ su profile public
- [ ] SBOM pubblicata, signed release verificabile con `cosign verify-blob`
- [ ] fail2ban jail verificato (5 fail login → ban 1h)
- [ ] Backup restore test su staging
- [ ] INSTALL.md verificato su Ubuntu fresh + macOS + Windows WSL

## 2.8 Rollback Strategy

Ogni fase produce artefatti versionati + DB migration reversibile.

**Rollback per milestone:**

- **M0 → pre-M0**: `make down && docker volume rm memorymesh_pg_data` (nuke)
- **M1 → M0**: `alembic downgrade -1` + redeploy immagine tag precedente
- **M2 → M1**: stessa (Alembic reversible). Se distillation già triggered: resta stato DB consistente (observation new con metadata distilled; no schema change).
- **M3 → M2**: plugin rollback via `/plugin install memorymesh@1.0.0` (versione precedente in marketplace). Server resta invariato.
- **M4 → M3**: UI rollback → rimuovo `api/app/static/` e ricarico versione precedente. Admin API rollback via Alembic downgrade.
- **M5 → M4**: Caddy config profile=public rollback a vpn/lan. Revoca release firmata dal marketplace.

**Regola Alembic:** ogni migration **deve avere `downgrade()` testato**. CI check
automatico: `alembic upgrade head && alembic downgrade base && alembic upgrade head`.

## 2.9 Assumption e Dipendenze Esterne

### Dipendenze esterne critiche

| Dipendenza | Provider | Rischio | Fallback |
|------------|----------|---------|----------|
| Gemini API | Google | Outage/policy change | Runtime switch a Ollama locale |
| GitHub (plugin marketplace) | GitHub | Down/account ban | Manual install via npm |
| Let's Encrypt (TLS cert) | ISRG | Rate limit / outage | Caddy auto-retry + internal CA fallback |
| Docker Hub (base images) | Docker | Pull rate limit (100 unauth / 6h) | Cache locale registry / Harbor |
| npm + PyPI | Community | Supply chain compromise | Signed releases + `--require-hashes` + SBOM |

### Assumption sull'utente target

- Ha Docker installato e funzionante
- Sa cos'è un'API key e come proteggerla
- È disposto a spendere <$5/mese (profile A) o ha hardware 16GB (profile C)
- Ha dimestichezza con terminale per setup iniziale (~10 min)
- Ha o può creare un account Google Cloud (free tier) per Gemini API

### Assumption tecniche

- Python 3.14 wheel disponibili per tutte le deps al momento dell'implementazione
- Claude Code plugin API stabile nella versione target (v1.0+)
- Codex transcript format ragionevolmente stabile (parsing difensivo previsto)
- pgvector 0.8.2 release-stable (CVE-2026-3172 già fixato)

## 2.10 Sprint-by-Sprint Deliverable Checklist

Ogni sprint chiude con:

- [ ] Tutti i task in `[x]` completato in TASKS.md
- [ ] Test della fase passano (unit + integration dove applicabile)
- [ ] Documentazione aggiornata (se cambio API o schema)
- [ ] Audit security (se tocca auth/crypto/endpoint)
- [ ] Commit firmati, push su branch feature
- [ ] PR aperta con checklist quality gate
- [ ] Review (auto-review se single-dev: rilettura a distanza di 1 giorno)
- [ ] Merge in main + tag se rilascio
- [ ] Retrospettiva 15 min: cosa ha funzionato, cosa no, adjust prossimo sprint

---

## Appendice A — Decision Log (da mantenere)

File suggerito: `docs/DECISIONS.md` (o commit message espliciti in repo).
Ogni decisione architetturale significativa presa durante l'implementazione va
loggata con:
- Data
- Context (cosa si stava facendo)
- Decisione presa
- Alternative considerate
- Impatto su altre fasi

Esempio: "2026-05-03 — Sprint 4: deciso di saltare BM25 prelude per MVP, usando
solo hybrid RRF. Motivo: calibrazione BM25_SKIP_THRESHOLD richiede corpus reale
non disponibile pre-M3. Promosso a Fase 9 (tuning)."

## Appendice B — Riferimento Rapido ai File

| File | Letture da fare | Quando |
|------|----------------|--------|
| `CLAUDE.md` | Entry point, regole operative | Ogni sessione |
| `IMPLEMENTATION_PLAN.md` | Piano + analisi | Inizio + milestone |
| `ARCHITECTURE.md` | Schema DB + flussi | Prima di ogni task tecnico |
| `TASKS.md` | Breakdown task, update `[~]`/`[x]` | Ogni sessione |
| `API_SPEC.md` | Endpoint quando lavori su API o plugin | F2, F3, F7, F10 |
| `DEPENDENCIES.md` | ADR + versioni | Prima di scegliere libreria |
| `SECURITY.md` | Threat model + hardening | F2 (auth), F5 (cloud LLM), F10 (admin), F12 |
| `CONVENTIONS.md` | Pattern codice | Prima di PR |
| `TOKEN_OPT.md` | 18 strategie token | F3, F5, F6, F7a |
| `VOCAB.md` | Vocab + shortcode | F4 |
| `DISTILLATION.md` | Pipeline LLM | F5, F6 |
| `PLUGIN.md` | Plugin monorepo + adapter CC | F7a |
| `CODEX.md` | Adapter Codex | F7b |
| `UI_ADMIN.md` | Pagine + flow MFA | F10 |
| `INSTALL.md` | UX end-user | F11, validation M5 |
| `TESTING.md` | Test strategy | Ogni fase |

---

## Appendice C — Open Questions (da risolvere durante implementazione)

1. **Calibrazione BM25_SKIP_THRESHOLD**: il valore 0.3 è stimato. Richiede tuning
   su corpus reale (F9-06).
2. **Seccomp profile**: il profile base è blocklist. Allowlist più stretta
   (F12-01+) richiede test approfonditi per identificare tutti i syscall usati.
3. **Codex transcript format**: esatto schema JSON sessions/*.json va verificato
   durante F7b-01. Parsing difensivo previsto.
4. **Pricing table LLM**: le $/M token sono aggiornate a aprile 2026. Review
   trimestrale prevista.
5. **Rerank vs no-rerank precision@5**: target 0.75 con rerank vs 0.65 senza.
   Da validare con corpus reale in F3-08.
6. **Embed dimension**: default 768 (text-embedding-004 / nomic v2). Valutare
   Matryoshka 512d per risparmio storage se nomic scelto (F9 tuning).

---

**Prossima azione:** review e approvazione di questo documento. Poi avvio Sprint 1
con task F1-01 (setup repo + Makefile + CI skeleton).
