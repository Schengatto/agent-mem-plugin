# Architettura Tecnica — MemoryMesh

## 1. Principi Architetturali

### Token-First: Zero LLM nel Critical Path

Ogni operazione sincrona (cattura, retrieve, vocab lookup) è pura SQL.
L'LLM è usato **solo** in tre contesti asincroni, tutti fuori dal turno utente:

| Quando | Cosa fa l'LLM | Costo token | Latenza |
|--------|---------------|-------------|---------|
| CRON 03:00 | Distillazione notturna | ~5-50K in, 5-15K out | 2-10 min (cloud) / 5-30 min (locale) |
| Ogni 5 sessioni | Extract fatti durevoli | ~1-2K in, 500 out | Asincrono |
| Soglia history | Comprimi history sessione | ~500-2K in, 500 out | <3s (cloud) / ~3s (locale), turno dopo |

**Multi-provider by design** (vedi ADR-014, 015 in `DEPENDENCIES.md`):

Il layer LLM è astratto via `LlmCallback` (Python Protocol). Adapter disponibili:
- `GeminiLlmAdapter` — **default**. Gemini 2.5 Flash, $0.30/M in + $2.50/M out, implicit caching gratis sul prefisso stabile
- `OllamaLlmAdapter` — opt-in privacy-strict. Qwen3.5-9B locale, $0 ma richiede 6GB RAM extra
- `OpenAiLlmAdapter` — opzionale (opt-in)
- `AnthropicLlmAdapter` — opzionale (opt-in)

Stesso pattern per **embedding** (`EmbedCallback`):
- `GeminiEmbedAdapter` — default. `text-embedding-004`, 768d
- `OllamaEmbedAdapter` — `nomic-embed-text-v2-moe`, MoE multilingue 100 lingue, zero-cost

Switch fra provider: solo env var `MEMORYMESH_LLM_PROVIDER` e `MEMORYMESH_EMBED_PROVIDER`.
Zero codice cambia. I dati nel DB restano portabili (embedding dimension è tracked
per observation; se cambi embedding model puoi re-embed bulk via `make reembed`).

**Costi stimati** con configurazione default (Gemini 2.5 Flash):

| Scenario | Chiamate/mese | Costo stimato |
|----------|---------------|---------------|
| Home server single user, 30 sessioni/mese | ~30 distill + 50 compress + 100 extract | **< $0.80/mese** |
| Famiglia 3 device attivi | ~30 distill + 200 compress + 500 extract | **< $3/mese** |

Con `MEMORYMESH_LLM_DAILY_TOKEN_CAP=500000` (default): hard cap giornaliero
→ impossibile bill shock da bug/loop.

### Security-First Design

MemoryMesh è progettato con threat model **public-facing possibile**: il
deployment può essere LAN pura o pubblico via Cloudflare Tunnel. Il design
parte dal caso più ostile e permette downgrade via env
`MEMORYMESH_DEPLOYMENT=lan|vpn|public` (default `lan`).

**Principi** (dettaglio in `SECURITY.md`):
1. **Defense in depth** — nessun controllo è l'unica barriera
2. **Least privilege** — container non-root, DB user distinti (mm_api/mm_worker/mm_admin)
3. **Fail safe** — se auth fallisce → nega; mai assumo OK
4. **Secure by default** — ogni setting parte dal valore più sicuro
5. **Zero trust input** — Pydantic strict `extra='forbid'`, validazione ovunque
6. **Assume compromise** — rotation automatica api_key 90gg, backup crittati

**Controlli trasversali:**
- TLS obbligatorio su profile VPN/public (Caddy + Let's Encrypt o internal CA)
- Rate limiting per endpoint (vedi SECURITY §3)
- Secret scrubbing at capture (gitleaks-like regex + entropy detection)
- Prompt injection defense su observation content
- Audit immutable (append-only + export signed)
- CSP strict con nonce per UI admin
- WebAuthn + TOTP + argon2id per admin
- PIN pairing rate-limited 10/15min per IP

**Livelli DB:** `mm_api` (operazionale), `mm_worker` (workers async),
`mm_admin` (admin plane). Row-Level Security sulle tabelle multi-user come
seconda linea di difesa contro bug applicativi.

### Zero-Touch Onboarding

Obiettivo UX: dal momento in cui l'admin ha il server attivo, ogni nuovo device
(PC dell'utente con Claude Code o Codex) completa onboarding in **~30 secondi**,
**2 comandi**, **nessun copia-incolla di URL o API key**.

```
┌─────────────── Server MemoryMesh ───────────────┐
│  FastAPI + mDNS broadcaster                     │
│    → annuncio LAN: _memorymesh._tcp.local       │
│                                                  │
│  Admin UI → /account/devices                    │
│    [Pair new device]                            │
│    → POST /admin/pair/create                    │
│    → mostra PIN 6-digit (TTL 5min in Redis)     │
└──────────────────────────────────────────────────┘
                    │
                    │ LAN
                    ▼
┌─────────────── PC utente ───────────────────────┐
│  Claude Code / Codex CLI                        │
│                                                  │
│  $ /plugin install memorymesh   (dal marketplace)│
│    ├─ Plugin esegue mDNS browse                 │
│    │  → trova "mm.local:80"                     │
│    ├─ Prompta "Enter PIN:" (o usa paste URL)    │
│    ├─ POST /api/v1/pair {pin, device_name,      │
│    │       hostname, os_info}                   │
│    │  → riceve {api_key, project_hint}          │
│    ├─ Legge git remote → project slug detection │
│    ├─ Scrive ~/.memorymesh/device.json          │
│    └─ Scrive plugin config nel runtime Claude   │
│                                                  │
│  Tempo totale: ~30 secondi                      │
└──────────────────────────────────────────────────┘
```

**Condivisione device.json fra adapter**: un singolo device.json serve
Claude Code e Codex (stesso api_key). Se l'utente installa dopo anche
`memorymesh install --for codex`, non è richiesto un secondo pairing —
l'installer Codex consuma lo stesso file, aggiunge solo config Codex-specific
(TOML config, shell wrapper).

**Fallback manuali**:
- mDNS non funziona (VLAN, mDNS bloccato): prompt "Enter server URL"
- PIN scaduto: admin rigenera, il flow riprende
- Nessun git remote: prompt "Project name?" con default = basename(cwd)
- Nessun admin UI accessibile (es. prima installazione headless): CLI fallback
  `memorymesh admin pair-create-cli` genera PIN via terminale sul server

### Admin Plane Separato

MemoryMesh espone **due superfici distinte**, isolate a livello di routing,
auth e rate limit:

```
┌──────────────────────────── FastAPI ────────────────────────────┐
│                                                                  │
│  /api/v1/*     ← DATA PLANE (agent-facing)                      │
│    - auth: X-API-Key (SHA-256)                                  │
│    - consumer: plugin Claude Code + adapter Codex               │
│    - rate limit: 1000 req/min/project                           │
│                                                                  │
│  /mcp/*        ← MCP tools (agent-facing, subset di data plane) │
│    - auth: X-API-Key                                            │
│                                                                  │
│  /admin/*      ← ADMIN PLANE (UI-facing, UMANO)                 │
│    - auth: password (argon2) + TOTP / WebAuthn                  │
│    - session: cookie httpOnly SameSite=strict + CSRF token      │
│    - consumer: SPA Nuxt servita da /static/                     │
│    - rate limit STRICTER: 5 req/min su /admin/login             │
│    - audit: ogni chiamata loggata in admin_audit_log            │
│                                                                  │
│  /static/*     ← SPA Nuxt 4 (build statica)                    │
│    - nessuna auth server-side (asset statici)                   │
│    - l'auth avviene chiamando /admin/login dopo il load         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Regole non negoziabili:**

1. `/admin/*` NON è mai raggiungibile con `X-API-Key` (API key plugin ≠ credenziali admin).
2. Endpoint data plane NON sono raggiungibili con cookie session admin (principio di privilegio minimo).
3. L'UI admin richiede **sempre** secondo fattore (TOTP obbligatorio al bootstrap, WebAuthn opzionale come upgrade).
4. Modifiche destructive (delete obs, reset vocab, change settings) richiedono **re-prompt MFA**: anche con sessione attiva, l'utente deve inserire di nuovo TOTP.
5. Single admin by design: constraint DB `CHECK` su `admin_users` limita a **una riga**. Multi-admin se/quando arriverà sarà una schema migration esplicita.

### Agent-Agnostic Core Design

MemoryMesh supporta **Claude Code e Codex al day-1** condividendo la stessa
memoria, lo stesso server, la stessa maggioranza di codice. L'unica cosa
agent-specific è il *come si consegna* il contesto all'agente e *come si
intercettano i tool use*.

```
┌─────────────────────── Server FastAPI (agent-agnostic) ───────────────┐
│  /manifest, /search, /vocab, /observations, /agents-md, MCP tools     │
└──────────┬──────────────────────────────────────────┬─────────────────┘
           │                                          │
           │                                          │
┌──────────▼────────────┐                ┌────────────▼─────────────────┐
│ plugin/core/ (shared) │                │  MCP (universal protocol)    │
│  client, bloom,       │                │  search, get_observations,   │
│  fingerprint, prefix, │                │  vocab_lookup, vocab_upsert  │
│  compressor, scope,   │                │  timeline, extract           │
│  telemetry, tiktoken  │                └────────────┬─────────────────┘
└──────┬─────────┬──────┘                             │
       │         │                              │ automatic via MCP config
┌──────▼──┐   ┌──▼──────┐                       │
│ Claude  │   │ Codex   │           ┌───────────▼──────────┐
│ Code    │   │ CLI     │           │ Any MCP-capable      │
│ adapter │   │ adapter │           │ agent (tier A only)  │
└─────────┘   └─────────┘           └──────────────────────┘
  hooks         cli-prep
  (native)      cli-capture
                AGENTS.md inject
```

**Cosa è core** (package `@memorymesh/core`, zero dipendenze agent-specific):
- HTTP client, offline buffer, retry/timeout
- Bloom filter client, fingerprint predict, batch cache
- Token telemetry, tiktoken estimator, compressor
- Prefix builder cache-stable, scope deriver, delta consumer

**Cosa è adapter Claude Code** (`@memorymesh/adapter-claude-code`):
- Hook wrapper per `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `SessionEnd`
- Parsing header `x-cache-read-input-tokens` dal runtime Claude Code
- Path Claude (`~/.claude/settings.json`, skill file)

**Cosa è adapter Codex** (`@memorymesh/adapter-codex`):
- CLI `memorymesh codex-prep` / `codex-capture`
- Gestione `AGENTS.md` (merge + file watcher per rebuild su cwd change)
- Parsing transcript `~/.codex/sessions/*.json` per capture out-of-band
- Shell wrapper per trap EXIT

Ogni adapter è **~200-300 righe**. Il 90% del codice vive in `core/`.

### Cache-Aware Design (Prompt Caching Nativo)

MemoryMesh produce ogni prompt iniettato in modo **cache-stable**: porzione
comune (vocab manifest + obs manifest scope-root) in testa, contenuto volatile
in coda, con boundary esplicito `cache_control: ephemeral`. L'API di Anthropic
paga 1/10 i token cachati sui turni successivi, purché il prefisso sia identico
byte-per-byte. Questo è il moltiplicatore più grande del risparmio.

Requisito architetturale: la serializzazione del manifest deve essere
deterministica — ordering hash-stable (non temporale), formato con
escape controllato, nessun timestamp o campo volatile nel prefisso.

### I Cinque Livelli di Retrieve

```
Prefisso cache-stable (1 volta pagato full, poi 1/10):
  0. Vocab manifest (shortcode binding)  ~150 token   ← vocab ultra-compatto
  1. Obs manifest scope-root            ~400-600 token ← indice radice

SessionStart, iniezione scope-specific (cache-warm dopo 1a sessione):
  2. Obs manifest scope-branch          ~200-400 token ← ramo cwd-relevant

On-demand (solo se Claude decide):
  3. Search top-5                       ~200 token   ← BM25→vector→rerank
  4. Batch detail                       ~300-1500    ← full content per ID
```

**Differenza chiave rispetto al design precedente:** il manifest non è più
piatto. È un albero per scope/namespace (progetto → modulo → file). Il plugin
carica solo il ramo del cwd corrente + la radice cache-stable. Target:
ridurre 800-1500 token a 550-900 token iniettati attivi, di cui ~150-250
sono cache-warm al costo di ~15-25 token effettivi post-caching.

### Strategie Token-First Architetturali

Queste otto strategie richiedono supporto schema/API e non possono essere
bolt-on. Il resto (dettaglio in TOKEN_OPT.md §8-18):

| # | Strategia | Richiede schema/API | Impatto lordo |
|---|-----------|---------------------|---------------|
| 8 | Prompt caching stabile | `cache_control` markers, ordering deterministico | ×10 riduzione su prefisso |
| 9 | Manifest gerarchico per scope | `observations.scope TEXT[]` + `manifest_entries.scope_path` | -400/800 token |
| 10 | Bloom filter vocab | `/vocab/bloom` endpoint | -1 roundtrip 70% query |
| 11 | Delta-encoding sessione | `manifest/delta` endpoint con `since_etag` | -600 token/turno post-1 |
| 12 | Vocab shortcode binding | `vocab_entries.shortcode TEXT` | -30/40% manifest vocab |
| 13 | Adaptive LRU budget | `observations.last_used_at`, `access_count` | manifest auto-dimagrisce |
| 14 | BM25 prelude | `search?mode=bm25\|vector\|hybrid` | 0 Ollama call 60% query |
| 15 | Cross-encoder rerank | worker rerank + modello locale | top-5 più denso (-40 token) |
| 16 | Session fingerprinting | `query_fingerprints` table + `/fingerprint/predict` | prefetch = 0 latenza |
| 17 | Observation capping at write | validator `MAX_OBS_TOKENS` | no drift manifest |
| 18 | Token metrics per task | `token_metrics` table, `/metrics/session` | osservabilità |

La separazione è fondamentale: i livelli 3 e 4 costano token solo se servono.
Nella maggior parte dei turni, Claude lavora solo con livelli 0-2.

---

## 2. Schema Database PostgreSQL

```sql
CREATE EXTENSION IF NOT EXISTS vector;

-- Utenti
CREATE TABLE users (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key    TEXT UNIQUE NOT NULL,  -- SHA-256 hash
  name       TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Progetti
CREATE TABLE projects (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id   UUID REFERENCES users(id) ON DELETE CASCADE,
  slug      TEXT NOT NULL,
  is_team   BOOLEAN DEFAULT false,
  parent_id UUID REFERENCES projects(id),
  git_remote TEXT,              -- es. 'github.com/schengatto/my-app', per auto-detection
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, slug)
);

-- Membership progetti team (multi-user, famiglia/team trusted)
CREATE TABLE project_members (
  project_id UUID REFERENCES projects(id) ON DELETE CASCADE,
  user_id    UUID REFERENCES users(id)    ON DELETE CASCADE,
  role       TEXT NOT NULL DEFAULT 'member',  -- 'owner' | 'member' | 'viewer'
  added_at   TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (project_id, user_id)
);
CREATE INDEX ON project_members (user_id);

-- Row-Level Security come DIFESA IN PROFONDITÀ (non sostituisce logica app)
ALTER TABLE observations ENABLE ROW LEVEL SECURITY;
CREATE POLICY observations_user_isolation ON observations
  USING (
    -- Deriva user_id dal session setting (set_config app.user_id)
    project_id IN (
      SELECT id FROM projects
      WHERE user_id = current_setting('app.user_id', true)::uuid
         OR (is_team = true AND id IN (
           SELECT project_id FROM project_members
           WHERE user_id = current_setting('app.user_id', true)::uuid
         ))
    )
  );

-- Stesse policy per vocab_entries, manifest_entries, sessions

-- Device keys (zero-touch onboarding, una API key per device paired)
CREATE TABLE device_keys (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  api_key_hash   TEXT NOT NULL UNIQUE,      -- SHA-256 dell'api key plaintext
  device_label   TEXT NOT NULL,             -- es. 'MacBook Enrico', libero
  hostname       TEXT,                      -- $(hostname) al pair
  os_info        TEXT,                      -- "Darwin 24.0.0 arm64", "Linux 6.1.0"
  agent_kinds    TEXT[] DEFAULT '{}',       -- ['claude-code', 'codex'] registrati
  created_at     TIMESTAMPTZ DEFAULT now(),
  created_via_pin UUID,                     -- FK logico a admin_pair_tokens usato
  created_ip     INET,
  last_seen_at   TIMESTAMPTZ,
  last_seen_ip   INET,
  revoked_at     TIMESTAMPTZ                -- soft delete, key non più valida
);
CREATE INDEX ON device_keys (user_id, revoked_at) WHERE revoked_at IS NULL;
CREATE INDEX ON device_keys (api_key_hash) WHERE revoked_at IS NULL;

-- Pair tokens (PIN 6-digit temporanei per onboarding)
-- Usato in storage durevole per audit; il PIN plaintext vive solo in Redis (TTL 5min)
-- PG18: uuidv7() per ordinabilità (utile per query "ultimi N PIN generati")
CREATE TABLE admin_pair_tokens (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  pin_hash     TEXT NOT NULL UNIQUE,        -- SHA-256 del PIN 6-digit
  label_hint   TEXT,                         -- label suggerita dall'admin, es. 'PC ufficio'
  project_slug TEXT,                         -- opzionale: forza project al consume
  created_by   UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ DEFAULT now(),
  expires_at   TIMESTAMPTZ NOT NULL,         -- default +5min
  consumed_at  TIMESTAMPTZ,                  -- set al primo successful pair
  consumed_by_device UUID REFERENCES device_keys(id) ON DELETE SET NULL
);
CREATE INDEX ON admin_pair_tokens (expires_at) WHERE consumed_at IS NULL;

-- Osservazioni
CREATE TABLE observations (
  id              BIGSERIAL PRIMARY KEY,
  project_id      UUID REFERENCES projects(id) ON DELETE CASCADE,
  session_id      UUID,
  type            TEXT NOT NULL DEFAULT 'observation',
  -- identity | directive | context | bookmark | observation
  content         TEXT NOT NULL,
  tags            TEXT[],
  scope           TEXT[],       -- gerarchia: es. ['api','routers','observations']
                                -- root = []. Derivato da cwd/file path al write.
  expires_at      TIMESTAMPTZ,
  relevance_score FLOAT DEFAULT 1.0,
  embedding       vector(768),
  fts_vector      tsvector GENERATED ALWAYS AS
                    (to_tsvector('italian', content)) STORED,
  distilled_into  BIGINT REFERENCES observations(id),
  last_tightened  TIMESTAMPTZ,
  last_used_at    TIMESTAMPTZ,  -- LRU tracking (batch fetch, inclusione manifest)
  access_count    INT DEFAULT 0,-- contatore utilizzi effettivi
  token_estimate  INT,          -- tiktoken cl100k_base, cached al write
  metadata        JSONB,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- Manifest osservazioni (precalcolato, entry point token-efficiente)
CREATE TABLE manifest_entries (
  id          BIGSERIAL PRIMARY KEY,
  project_id  UUID REFERENCES projects(id) ON DELETE CASCADE,
  obs_id      BIGINT REFERENCES observations(id) ON DELETE CASCADE,
  one_liner   TEXT NOT NULL,   -- max chars adattivi per tipo (vedi sotto)
  type        TEXT NOT NULL,
  priority    INT DEFAULT 0,   -- 0=identity 1=directive 2=context 3=bookmark 4=observation
  scope_path  TEXT NOT NULL DEFAULT '/',  -- '/' = root, '/api/routers' = branch
  is_root     BOOLEAN DEFAULT false,      -- true = parte del prefisso cache-stable
  updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Vocabolario progetto
CREATE TABLE vocab_entries (
  id          BIGSERIAL PRIMARY KEY,
  project_id  UUID REFERENCES projects(id) ON DELETE CASCADE,
  term        TEXT NOT NULL,
  shortcode   TEXT,                -- $AS, $UR, ... assegnato alla distillazione
                                   -- se usage_count >= SHORTCODE_THRESHOLD (default 10)
  category    TEXT NOT NULL,
  -- entity | convention | decision | abbreviation | pattern
  definition  TEXT NOT NULL,   -- max 80 chars
  detail      TEXT,            -- info aggiuntiva (path, deps, test file, ecc.)
  metadata    JSONB,           -- campi strutturati liberi
  source      TEXT DEFAULT 'auto',  -- 'auto' | 'manual'
  confidence  FLOAT DEFAULT 0.7,    -- auto=0.7, manual=1.0
  usage_count INT DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now(),
  UNIQUE(project_id, term),
  UNIQUE(project_id, shortcode)  -- shortcode unico nel progetto
);

-- Fingerprint predittivo sessioni (per prefetch)
-- Aggregato dal distillation job dalle sequence di tool call
CREATE TABLE query_fingerprints (
  id              BIGSERIAL PRIMARY KEY,
  project_id      UUID REFERENCES projects(id) ON DELETE CASCADE,
  trigger_pattern TEXT NOT NULL,   -- es. "Read:README → ls → Read:*.py"
  predicted_ids   BIGINT[],        -- observation IDs tipicamente richiesti dopo
  predicted_terms TEXT[],          -- vocab term tipicamente richiesti dopo
  hit_count       INT DEFAULT 0,
  miss_count      INT DEFAULT 0,
  confidence      FLOAT DEFAULT 0.0,  -- hit / (hit+miss), soglia 0.6 per uso
  updated_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(project_id, trigger_pattern)
);

-- ═══════════════════════════════════════════════════════════════════
-- ADMIN PLANE — separato dal data plane
-- ═══════════════════════════════════════════════════════════════════

-- Admin singolo (constraint: massimo 1 riga)
CREATE TABLE admin_users (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username        TEXT NOT NULL UNIQUE,
  password_hash   TEXT NOT NULL,          -- argon2id
  totp_secret     TEXT NOT NULL,          -- cifrato con key derivata da SECRET_KEY
  totp_verified   BOOLEAN DEFAULT false,  -- false fino a prima verifica riuscita
  recovery_codes  TEXT[],                 -- 10 codici hash SHA-256, usabili una volta
  created_at      TIMESTAMPTZ DEFAULT now(),
  last_login_at   TIMESTAMPTZ,
  last_login_ip   INET,
  CONSTRAINT single_admin CHECK (id IS NOT NULL)
);
-- Trigger che blocca INSERT se conteggio >= 1
CREATE OR REPLACE FUNCTION enforce_single_admin() RETURNS trigger AS $$
BEGIN
  IF (SELECT count(*) FROM admin_users) >= 1 THEN
    RAISE EXCEPTION 'Only one admin allowed. Use update flow.';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER single_admin_trg
  BEFORE INSERT ON admin_users
  FOR EACH ROW EXECUTE FUNCTION enforce_single_admin();

-- Credenziali WebAuthn (0..N per admin)
CREATE TABLE admin_webauthn_credentials (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id      UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  credential_id BYTEA NOT NULL UNIQUE,    -- raw credential ID dal browser
  public_key    BYTEA NOT NULL,           -- COSE encoded
  sign_count    BIGINT DEFAULT 0,         -- signature counter, anti-replay
  transports    TEXT[],                   -- usb|nfc|ble|internal|hybrid
  label         TEXT,                     -- 'YubiKey blu', 'MacBook TouchID', ...
  created_at    TIMESTAMPTZ DEFAULT now(),
  last_used_at  TIMESTAMPTZ
);
CREATE INDEX ON admin_webauthn_credentials (admin_id, last_used_at DESC);

-- Sessioni admin (cookie = session_id opaco)
-- NOTA PG18: usa uuidv7() invece di gen_random_uuid() — UUID v7 è ordinabile
-- temporalmente, migliora B-tree performance e index locality.
CREATE TABLE admin_sessions (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  admin_id     UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  session_token TEXT NOT NULL UNIQUE,     -- 256-bit random, opaco
  csrf_token   TEXT NOT NULL,             -- double-submit CSRF
  mfa_fresh_until TIMESTAMPTZ,            -- entro N min operazioni destructive OK senza re-prompt
  ip           INET NOT NULL,
  user_agent   TEXT,
  created_at   TIMESTAMPTZ DEFAULT now(),
  expires_at   TIMESTAMPTZ NOT NULL,      -- default: +8h sliding
  revoked_at   TIMESTAMPTZ
);
CREATE INDEX ON admin_sessions (admin_id, expires_at)
  WHERE revoked_at IS NULL;

-- Audit log (ogni chiamata /admin/* scrive una riga)
CREATE TABLE admin_audit_log (
  id          BIGSERIAL PRIMARY KEY,
  admin_id    UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  session_id  UUID REFERENCES admin_sessions(id) ON DELETE SET NULL,
  action      TEXT NOT NULL,      -- 'login', 'memory.delete', 'settings.update', ...
  target_type TEXT,                -- 'observation', 'vocab_entry', 'setting', ...
  target_id   TEXT,                -- FK as string (può essere UUID o int64)
  details     JSONB,               -- payload diff, reason, ecc. (NO secret)
  ip          INET,
  success     BOOLEAN NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON admin_audit_log (admin_id, created_at DESC);
CREATE INDEX ON admin_audit_log (action, created_at DESC);

-- Settings key-value (stringified JSON, tipizzati in Pydantic)
CREATE TABLE admin_settings (
  key         TEXT PRIMARY KEY,     -- es. 'retention.observation_days'
  value       JSONB NOT NULL,
  description TEXT,
  updated_at  TIMESTAMPTZ DEFAULT now(),
  updated_by  UUID REFERENCES admin_users(id) ON DELETE SET NULL
);

-- ═══════════════════════════════════════════════════════════════════

-- ETag/metadata manifest per progetto (Strategia 8 — caching root prefix)
CREATE TABLE project_manifest_meta (
  project_id      UUID PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
  root_etag       TEXT NOT NULL,        -- hash deterministico del root set
  vocab_etag      TEXT NOT NULL,        -- hash deterministico del vocab manifest
  bloom_etag      TEXT,                 -- hash del bloom filter vocab
  last_distilled  TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- LLM API calls audit (multi-provider, budget tracking)
CREATE TABLE llm_api_calls (
  id             BIGSERIAL PRIMARY KEY,
  provider       TEXT NOT NULL,         -- 'gemini' | 'ollama' | 'openai' | 'anthropic'
  model          TEXT NOT NULL,         -- 'gemini-2.5-flash' | 'qwen3.5:9b' | ...
  purpose        TEXT NOT NULL,         -- 'distill_merge' | 'distill_tighten' |
                                        -- 'distill_vocab' | 'compress_session' |
                                        -- 'extract_facts'
  project_id     UUID REFERENCES projects(id) ON DELETE SET NULL,
  session_id     UUID REFERENCES sessions(id) ON DELETE SET NULL,
  input_tokens   INT NOT NULL,
  output_tokens  INT NOT NULL,
  cached_tokens  INT DEFAULT 0,         -- token serviti da implicit cache (Gemini/Anthropic)
  cost_microcents INT,                  -- costo in 1/1000000 USD (precision > cent)
  latency_ms     INT NOT NULL,
  success        BOOLEAN NOT NULL,
  error_class    TEXT,                  -- 'timeout' | 'quota_exceeded' | 'invalid_response' | ...
  budget_day     DATE NOT NULL,         -- YYYY-MM-DD per aggregazione budget
  created_at     TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON llm_api_calls (budget_day, provider);
CREATE INDEX ON llm_api_calls (provider, model, success) WHERE success = false;
CREATE INDEX ON llm_api_calls (project_id, created_at DESC);

-- Telemetria token per sessione (Strategia 18)
CREATE TABLE token_metrics (
  id                     BIGSERIAL PRIMARY KEY,
  session_id             UUID REFERENCES sessions(id) ON DELETE CASCADE,
  project_id             UUID REFERENCES projects(id) ON DELETE CASCADE,
  tokens_manifest_root   INT DEFAULT 0,   -- prefisso cache-stable
  tokens_manifest_branch INT DEFAULT 0,   -- ramo scope-specific
  tokens_vocab           INT DEFAULT 0,
  tokens_search          INT DEFAULT 0,   -- somma sui search della sessione
  tokens_batch_detail    INT DEFAULT 0,
  tokens_history_saved   INT DEFAULT 0,   -- risparmio da compressione
  cache_hits_bytes       INT DEFAULT 0,   -- header x-cache-hit dal server Anthropic
  cache_misses_bytes     INT DEFAULT 0,
  turns_total            INT DEFAULT 0,
  created_at             TIMESTAMPTZ DEFAULT now()
);

-- Sessioni
CREATE TABLE sessions (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     UUID REFERENCES projects(id),
  scope_hint     TEXT,        -- cwd-derived, per pre-filter manifest branch
  started_at     TIMESTAMPTZ DEFAULT now(),
  closed_at      TIMESTAMPTZ,
  obs_count      INT DEFAULT 0,
  compressed_at  TIMESTAMPTZ, -- ultima compressione history in-session
  summary_obs_id BIGINT REFERENCES observations(id), -- summary salvato
  tool_sequence  TEXT[]       -- ultimi N tool names (per fingerprint aggregation)
);

-- Indici critici
CREATE INDEX ON observations
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

CREATE INDEX ON observations USING gin (fts_vector);

CREATE INDEX ON observations (project_id, type, relevance_score DESC)
  WHERE distilled_into IS NULL;

CREATE INDEX ON observations (project_id, created_at DESC)
  WHERE distilled_into IS NULL;

-- Scope-based retrieval (Strategia 9)
CREATE INDEX ON observations USING gin (scope)
  WHERE distilled_into IS NULL;

-- LRU eviction (Strategia 13)
CREATE INDEX ON observations (project_id, last_used_at DESC NULLS LAST, access_count DESC)
  WHERE distilled_into IS NULL;

CREATE INDEX ON manifest_entries (project_id, priority, updated_at DESC);

-- Scope-path lookup (Strategia 9): root + branch separati nella stessa query
CREATE INDEX ON manifest_entries (project_id, is_root, scope_path)
  INCLUDE (obs_id, one_liner, type, priority);

CREATE INDEX ON vocab_entries (project_id, category, usage_count DESC);

CREATE INDEX ON vocab_entries (project_id, shortcode)
  WHERE shortcode IS NOT NULL;

CREATE INDEX ON vocab_entries
  USING gin (to_tsvector('english', term || ' ' || definition));

-- Fingerprint lookup (Strategia 16)
CREATE INDEX ON query_fingerprints (project_id, confidence DESC)
  WHERE confidence >= 0.6;

-- Metriche (Strategia 18)
CREATE INDEX ON token_metrics (project_id, created_at DESC);
```

### One-liner Adattivi per Tipo

I one-liner nel manifest hanno lunghezza massima diversa per tipo.
Meno caratteri = meno token. Le `observation` raw non hanno bisogno di 80 chars.

| Tipo | Max chars | Motivazione |
|------|-----------|-------------|
| `identity` | 80 | Sempre iniettato, merita contesto completo |
| `directive` | 80 | Sempre iniettato, regola importante |
| `context` | 40 | One-liner breve, dettaglio via batch se serve |
| `bookmark` | 35 | Solo reference, URL o nome sistema |
| `observation` | 20 | Solo reminder che esiste, dettaglio mai necessario |

### Tipi di Memoria — Regole Comportamento

| Tipo | Decay | Inject priority | Scopo |
|------|-------|-----------------|-------|
| `identity` | Nessuno | 0 — sempre | Preferenze permanenti utente |
| `directive` | Nessuno | 1 — sempre | Regole comportamentali confermate |
| `context` | ×0.97/week | 2 — se score > 0.6 | Lavoro in corso, decisioni recenti |
| `bookmark` | ×0.95/week | 3 — se query match | Link, riferimenti esterni |
| `observation` | ×0.85/14gg | 4 — top-3 per score | Azioni operative raw |

---

## 3. Flusso Dati — SessionStart (cache-aware, token ottimizzato)

```
Plugin TypeScript — onSessionStart()
  │
  ├─ [0] Determina scope da cwd (es. '/api/routers/observations')
  │      project-root relative. Nessuna HTTP call.
  │
  ├─ [1] Flush offline buffer (fire & forget, non attende)
  │
  ├─ [2] Fingerprint predict (asincrono, fire & forget)
  │      → GET /api/v1/fingerprint/predict?project=X&scope=...
  │      → restituisce predicted_ids + predicted_terms
  │      → plugin pre-carica in batch_cache locale (ready at turn 1)
  │
  ├─ [3] Bloom filter vocab sync (solo se stale > 1h)
  │      → GET /api/v1/vocab/bloom?project=X
  │      → ~10-20 KB binary, salvato in ~/.memorymesh/vocab.bloom
  │      → consultato in memoria prima di qualunque vocab_lookup
  │
  ├─ [4] Vocab manifest con shortcode (cache-stable)
  │      → ETag check. 304 → usa cache locale.
  │      → Formato deterministico: sort alfabetico su term,
  │        shortcode espansi inline: "$AS|AuthService=..."
  │
  ├─ [5] Obs manifest ROOT (cache-stable)
  │      → GET /api/v1/manifest?project=X&scope_prefix=/&root_only=true
  │      → solo entries con is_root=true (identity, directive, top-N context)
  │      → ETag stabile (cambia solo dopo distillazione)
  │      → ~400-600 token
  │
  ├─ [6] Obs manifest BRANCH (scope-specific)
  │      → GET /api/v1/manifest?project=X&scope_prefix=/api/routers
  │      → entries matching scope[] con ANY(scope_prefix)
  │      → ~200-400 token (spesso meno)
  │      → ETag scope-specific
  │
  └─ [7] Inietta nel system prompt in ordine cache-aware:

          ┌─ PREFISSO CACHE-STABLE (cache_control: ephemeral) ──────────┐
          │ ## Vocabolario ($N termini, shortcode attivi)               │
          │ $AS|AuthService=api/services/auth.py·JWT·deps:$UR,Redis     │
          │ $UR|UserRepo=api/repositories/user.py·Repository            │
          │ [conv] test_*=pytest+testcontainers,mai mock DB             │
          │                                                              │
          │ ## Contesto Root (N memorie, sempre valido)                 │
          │ - [identity] Senior dev, TypeScript strict (#12, 30gg)      │
          │ - [directive] Mai mock DB in test (#8, 5gg)                 │
          └─────────────────────────────────────────────────────────────┘

          ## Contesto Scope: api/routers (N memorie)  ← volatile, non cachato
          - [context] Refactor manifest endpoint (#91, 6h fa)
          - [observation] Write routers/manifest.py (#184, 2h fa)

COSTO TOTALE primo turno:  ~150 (vocab) + ~500 (root) + ~300 (branch) = ~950 token
COSTO TOTALE turni successivi: ~650 token × 0.1 (cache) + ~300 = ~365 token
```

**Nota prompt caching:** il plugin NON gestisce direttamente `cache_control`.
Lo fa implicitamente piazzando il prefisso cache-stable per primo; Claude Code
(e l'API Anthropic) applica caching automatico sul prefisso stabile.
L'unico lavoro richiesto al plugin è garantire che ordering, separatori e
contenuto del prefisso siano byte-per-byte identici fra sessioni.

---

## 3bis. Flusso Dati — Codex Pre-Launch (out-of-band)

Codex non ha hook in-turn equivalenti a Claude Code. Lo split è:
- **Pre-launch** (prima che `codex` parta): un wrapper CLI prepara `AGENTS.md`
  con il prefisso cache-stable. Codex lo legge automaticamente all'avvio.
- **In-turn** (durante `codex`): MCP tool calls vanno direttamente al server
  (vocab_lookup, search, batch fetch). Nessuna iniezione nuova.
- **Post-session**: un `trap EXIT` lancia capture sul transcript salvato.

```
Shell wrapper "cx" (utente lancia 'cx <args>'):
  │
  ├─ [1] memorymesh codex-prep --cwd $PWD --project ...
  │      ├─ scope = deriveScope($PWD, projectRoot)
  │      ├─ GET /api/v1/agents-md?project=X&scope_prefix=$scope
  │      │   → restituisce Markdown già formattato cache-stable
  │      ├─ scrive .memorymesh/INJECT.md nel project root
  │      └─ aggiorna AGENTS.md inserendo "@import .memorymesh/INJECT.md"
  │         (idempotente: salta se marker già presente)
  │
  ├─ [2] codex "$@"
  │      → Codex legge AGENTS.md (incl. INJECT.md)
  │      → Prefix cache-stable presente nel system prompt
  │      → MCP tools disponibili da config /agents-md (registrato a parte)
  │
  └─ [3] memorymesh codex-capture --cwd $PWD
         ├─ legge ~/.codex/sessions/latest.json (transcript)
         ├─ estrae sequenza di tool: Edit, Bash, Write, ...
         ├─ per ogni tool significativo: POST /observations con scope dedotto
         ├─ append a tool_sequence per fingerprint
         └─ POST /metrics/session con stima token (parsing log Codex)

LATENZA percepita: codex-prep <300ms, codex-capture <1s (background, non blocca shell).
TOKEN COST: identico a Claude Code (lo stesso prefisso cache-stable).
DIFFERENZE:
  - History compression: NON in-session. Triggerata da capture solo se transcript > soglia.
    Il summary entra nella prossima sessione via INJECT.md.
  - Manifest delta: refreshato a ogni codex-prep (no intra-session delta).
  - Telemetry cache hit: parsata dai log Codex (formato OpenAI), non da header runtime.
```

**Tier di compatibilità sintetico:**

| Capability | Claude Code | Codex (CLI) | Generic MCP agent |
|-----------|:-----------:|:-----------:|:-----------------:|
| Search/vocab tools (MCP) | ✅ | ✅ | ✅ |
| Manifest+vocab inject SessionStart | ✅ hook | ✅ AGENTS.md | ❌ |
| Tool capture in-session | ✅ hook | ⚠ post-session | ❌ |
| History compression in-session | ✅ | ❌ | ❌ |
| Manifest delta intra-turn | ✅ | ❌ | ❌ |
| Prompt caching nativo | ✅ Anthropic | ⚠ OpenAI auto | dipende |
| Telemetry token | ✅ runtime header | ⚠ log parsing | ❌ |

---

## 4. Flusso Dati — Cattura (zero token LLM)

```
PostToolUse hook → Plugin TS
  │
  ├─ Costruisce content leggibile dal tool (Write/Edit/Bash/Fetch)
  ├─ Deriva scope[] dal file_path o cwd (es. 'api/routers/obs.py'
  │   → ['api','routers'])
  ├─ Stima token_estimate con tiktoken (cl100k_base, cached)
  ├─ Enforce MAX_OBS_TOKENS (default 200). Se eccede:
  │   a) tronca + aggiunge marker "...[capped]"
  │   b) o accoda job di tightening async
  ├─ POST /api/v1/observations
  │   {type:'observation', content, scope, token_estimate, metadata}
  │   → INSERT observations (testo grezzo, embedding=NULL)
  │   → XADD Redis 'embed_jobs' {obs_id}
  │   → return 202 Accepted   ← mai aspetta
  │
  └─ [async ~1-3s dopo] Embedding Worker
      → nomic-embed-text via Ollama
      → UPDATE observations SET embedding=[...768]

COSTO: 0 token LLM chat
```

---

## 4bis. Flusso Dati — Search Ibrido (BM25 → Vector → Rerank)

```
Claude chiama mcp__memorymesh__search(q="jwt refresh token", limit=5)
  │
  ├─ [1] BM25 PRELUDE (sempre primo, ~5-10ms)
  │      SELECT id, ts_rank(fts_vector, plainto_tsquery) AS score
  │      FROM observations
  │      WHERE project_id=$1 AND distilled_into IS NULL
  │        AND fts_vector @@ plainto_tsquery($2)
  │      LIMIT 40
  │
  │      SE top BM25 score > BM25_SKIP_THRESHOLD (default 0.3):
  │        → salta vector search, restituisci top-N BM25
  │        → RISPARMIO: 1 Ollama call per embedding query
  │        → stat: ~60% query su codebase match qui
  │
  ├─ [2] VECTOR SEARCH (solo se BM25 debole o mode=hybrid forzato)
  │      → Ollama embed(query) — 768-dim
  │      → pgvector HNSW sul subset pre-filtered (type, project, partial index)
  │      → top-40 candidates
  │
  ├─ [3] RRF MERGE (se hybrid)
  │      RRF(k=60) + TYPE_WEIGHT × relevance_score → top-20
  │
  ├─ [4] CROSS-ENCODER RERANK (Strategia 15, opzionale per precision)
  │      → bge-reranker-base-Q4 (CPU, ~50ms per 20 pairs)
  │      → riordina top-20 → top-5 finali
  │      → abilitabile via SEARCH_RERANK_ENABLED
  │
  ├─ [5] UPDATE last_used_at, access_count sui 5 ritornati (LRU feedback)
  │
  └─ Cache Redis 5min (key = hash(query+project+mode))

Response: 5 risultati × ~35 token = ~175 token (vs 200+ pre-rerank)
```

---

## 5. Flusso Dati — History Compression (NUOVO)

```
UserPromptSubmit hook → Plugin TS
  │
  ├─ Stima token history corrente (chars/4 approssimazione)
  │
  ├─ SE history > COMPRESS_THRESHOLD (default 8000 token):
  │   POST /api/v1/sessions/{id}/compress
  │     body: { messages: [...ultimi N], threshold: 8000 }
  │     → Qwen3 genera summary strutturato (~500-2K token locali)
  │     → salva come observation type='context'
  │     → restituisce { summary_obs_id, tokens_saved }
  │   Plugin: salva summary_obs_id localmente
  │   NOTA: il summary viene iniettato al PROSSIMO turno, non a questo
  │
  └─ SE session ha summary attivo:
      Turno corrente: inietta "[Summary sessione #ID] ..." invece di history
      RISPARMIO: 5.000-30.000 token/sessione su sessioni lunghe
```

---

## 6. Flusso Dati — Vocab Lookup (zero token LLM)

```
Claude usa mcp__memorymesh__vocab_lookup(term="AuthService")
  │
  → GET /api/v1/vocab/lookup?term=AuthService&project=X
      1. Match esatto su term (index lookup)
      2. Se no match: fuzzy su FTS (levenshtein)
      3. Se no match: ricerca semantica (embedding)
      → UPDATE vocab_entries SET usage_count += 1
      → return { term, category, definition, detail, metadata }

RISPOSTA: ~10-30 token per entry
COSTO: 0 token LLM
```

---

## 7. Flusso Dati — Distillazione Notturna

```
CRON 03:00 UTC → Distillation Worker
  │
  ├─ Per ogni progetto attivo (obs nelle ultime 48h):
  │   [Ollama carica Qwen3:8b — ~15s cold start]
  │   │
  │   ├─ PRUNE: DELETE expired + score < 0.05        (0 token)
  │   ├─ MERGE: pgvector cluster → Qwen3 merge        (~200-500 token/cluster)
  │   ├─ TIGHTEN: directive/identity verbose → Qwen3  (~300 token/entry)
  │   ├─ DECAY: UPDATE relevance_score per tipo       (0 token)
  │   ├─ VOCAB EXTRACT: observation → nuovi termini   (~500 token/batch, NUOVO)
  │   └─ REBUILD MANIFEST: manifest_entries + vocab   (0 token)
  │
  └─ [Ollama scarica Qwen3:8b — RAM liberata]

Vedi DISTILLATION.md per dettaglio completo.
```

---

## 8. Gestione RAM per Profilo di Deployment

Il footprint RAM dipende dal provider scelto per LLM e embedding. Tre profili
tipici:

### Profile A — Cloud LLM + Cloud Embedding (default, minimo)

Target device: Raspberry Pi 5 4GB / Mac Mini / NAS / VM $6-10/mese.

| Servizio | RAM |
|----------|-----|
| OS + Docker | ~1.0 GB |
| PostgreSQL | ~0.6 GB |
| Redis | ~0.3 GB |
| FastAPI (2 workers + /admin/*) | ~0.5 GB |
| Rerank worker (jina-reranker-v2) | ~0.35 GB |
| **Totale** | **~2.75 GB** |

Picco: stesso (nessun modello on-demand loaded localmente).

### Profile B — Cloud LLM + Local Embedding (Ollama opt-in embed only)

Target: mini PC 4-8GB. Privacy media (embedding locali, LLM distill in cloud).

| Servizio | RAM always-on |
|----------|---------------|
| Profile A base | ~2.75 GB |
| Ollama + nomic-embed-text-v2-moe | ~0.9 GB |
| **Totale** | **~3.65 GB** |

### Profile C — Full Local (privacy-strict)

Target: mini PC 16GB, no GPU. Come design originale, zero cloud.

| Servizio | RAM always-on | RAM picco (03:00 distill) |
|----------|---------------|---------------------------|
| Profile A base | ~2.75 GB | ~2.75 GB |
| Ollama + nomic-embed-text-v2-moe | ~0.9 GB | ~0.9 GB |
| Qwen3.5:9b Q4_K_M | **0 GB** | **~5.5 GB** |
| **Totale** | **~3.65 GB** | **~9.15 GB** |

`OLLAMA_MAX_LOADED_MODELS=1` + `OLLAMA_KEEP_ALIVE=5m`:
nomic-embed e Qwen3.5 non sono mai in RAM contemporaneamente.

### Selezione Profilo

```bash
# .env
MEMORYMESH_LLM_PROVIDER=gemini      # profile A o B
MEMORYMESH_EMBED_PROVIDER=gemini    # profile A
# oppure
MEMORYMESH_EMBED_PROVIDER=ollama    # profile B (abilita ollama container)
# oppure
MEMORYMESH_LLM_PROVIDER=ollama      # profile C full local
MEMORYMESH_EMBED_PROVIDER=ollama
```

Il compose usa profiles Docker per attivare Ollama solo se serve:
```bash
# Profile A (default, no Ollama)
docker compose up

# Profile B/C (con Ollama)
docker compose --profile ollama up
```

Il reranker (`jina-reranker-v2-base-multilingual`) gira sempre locale via
`sentence-transformers`, CPU only, sempre resident (~350MB). Disabilitabile
via `SEARCH_RERANK_ENABLED=false` (precision@5 scende da ~0.75 a ~0.65).

---

## 9. Stack e Versioni (aprile 2026)

> Vedi `DEPENDENCIES.md` per ADR + policy aggiornamento. Check trimestrale.

| Componente | Immagine / Versione | Note |
|---|---|---|
| Python | **3.14.4** (`python:3.14.4-slim`) | free-threading ufficiale, t-strings, compression.zstd |
| PostgreSQL | **18.3** (`pgvector/pgvector:pg18`) | I/O subsystem nuovo +3× perf read, `uuidv7()` nativo per session token, virtual generated columns |
| pgvector | **0.8.2** | CVE-2026-3172 fix OBBLIGATORIO, HNSW iterative scan relaxed_order |
| Redis | **8.6** (`redis:8.6-alpine`) | Bloom/Cuckoo filter **built-in** (sostituisce pybloom-live server-side), vector ops AArch64, TLS cert auto auth |
| Ollama | latest | **Opzionale** (solo se profile=B o C). `OLLAMA_MAX_LOADED_MODELS=1`, `KEEP_ALIVE=5m` |
| FastAPI | **0.136.0** | Starlette 1.0+, SSE streaming, strict Content-Type JSON |
| Caddy | 2.x (`caddy:2-alpine`) | Auto-TLS, custom build con `caddy-ratelimit` plugin via xcaddy |

**Modelli LLM/Embedding — multi-provider by design:**

LLM (distillation, compression, extract) — **default Gemini 2.5 Flash**:

| Provider | Modello | Uso | Costo tipico |
|----------|---------|-----|--------------|
| **Gemini** (default) | `gemini-2.5-flash` | distill+compress+extract | $0.30/M in + $2.50/M out, implicit caching |
| Ollama (opt-in) | `qwen3.5:9b` Q4_K_M | distill+compress+extract locale | $0, richiede 5.5GB RAM picco |
| OpenAI (opt-in) | `gpt-5-mini` o `gpt-4.1` | distill+compress+extract | $0.15-1/M in |
| Anthropic (opt-in) | `claude-haiku-4-5` | distill+compress+extract | $0.80/M in |

Embedding — **default Gemini `text-embedding-004`**:

| Provider | Modello | Note |
|----------|---------|------|
| **Gemini** (default) | `text-embedding-004` | 768d, $0.025/M tokens, batch support |
| Ollama (opt-in) | `nomic-embed-text-v2-moe` | 768d default (Matryoshka: 256-768 configurable), multilingue 100 lingue, $0, ~500MB RAM |

Reranker — **sempre locale** (alta frequenza, cost cloud prohibitive):

| Modello | Note |
|---------|------|
| `jinaai/jina-reranker-v2-base-multilingual` | 15× più veloce di bge-reranker-v2-m3, 100 lingue, sentence-transformers CPU, ~350MB RAM |

**Dipendenze Python (aprile 2026):**
```
# Web framework e core
fastapi==0.136.*           # Starlette 1.0+, SSE, strict JSON
uvicorn[standard]==0.32.*  # ASGI server
pydantic==2.13.*           # validation strict, Python 3.14 support
pydantic-settings==2.7.*   # env config
asyncpg==0.31.*            # PG async driver, wheels cp314 + cp314t (free-threaded)
pgvector==0.3.*            # client binding (server side è extension 0.8.2)
alembic==1.14.*            # migrations

# Redis e queue
redis==5.2.*               # client Python per Redis 8
httpx==0.28.*              # HTTP client async (SSRF safe_fetch wrapper)
apscheduler==3.11.*        # CRON distillation

# Rate limiting
fastapi-limiter==0.1.*     # Redis-backed DI rate limiter (sostituisce slowapi — ADR-003)
python-multipart==0.0.*    # form parsing

# Logging e validation
structlog==24.*            # JSON structured log
rapidfuzz==3.*             # fuzzy match vocab lookup

# Token & bloom (bloom server-side ora via Redis 8 nativo — ADR-004)
tiktoken==0.8.*            # cl100k_base encoding (Strategia 17, 18)
sentence-transformers==3.* # cross-encoder rerank (Strategia 15)

# Admin plane sicurezza
argon2-cffi==23.*          # password + recovery codes hashing
pyotp==2.*                 # TOTP RFC 6238
webauthn==2.7.*            # FIDO2/passkey (py_webauthn Duo Labs)
itsdangerous==2.*          # session cookie signing
cryptography==43.*         # AES-GCM TOTP at-rest, HKDF derivation

# Zero-touch onboarding
zeroconf==0.135.*          # mDNS broadcaster _memorymesh._tcp.local

# LLM providers (adapter pattern, installati tutti — runtime dispatch)
google-genai==1.*          # Gemini SDK (default provider). Supporta Pydantic schema
                           # per structured output, implicit caching automatic
anthropic==0.40.*          # Claude (opt-in via MEMORYMESH_LLM_PROVIDER=anthropic)
openai==1.60.*             # GPT (opt-in via MEMORYMESH_LLM_PROVIDER=openai)

# Solo se si usa Ollama (opt-in, profile B/C)
ollama==0.4.*              # client Python async per Ollama local
```

**Dipendenze Node (plugin + UI):**

```json
// plugin/packages/core/package.json
{
  "dependencies": {
    "typescript": "^5.6.0",
    "js-tiktoken": "^1.0.0",
    "bloom-filters": "^3.0.0",
    "multicast-dns": "^7.2.0",
    "keytar": "^7.9.0"
  }
}

// ui/package.json (Nuxt 4)
{
  "dependencies": {
    "nuxt": "^4.4.2",
    "vue": "^3.5.0",
    "@nuxt/ui": "^3.0.0",
    "@pinia/nuxt": "^0.5.0",
    "@vueuse/nuxt": "^11.0.0",
    "@simplewebauthn/browser": "^11.0.0",
    "isomorphic-dompurify": "^2.0.0",
    "markdown-it": "^14.0.0",
    "zxcvbn-ts": "^3.0.0",
    "qrcode.vue": "^3.0.0"
  }
}
```

**Nota critical security:** pgvector 0.8.2 è **obbligatorio** (fix CVE-2026-3172,
buffer overflow in parallel HNSW build). Se usi pgvector < 0.8.2 il server è
vulnerabile a data leak cross-table.

**Network config Docker per mDNS:**

mDNS richiede multicast UDP sulla LAN. Due opzioni in `docker-compose.yml`:

```yaml
# Opzione A — host network (semplice, Linux only)
services:
  api:
    network_mode: host  # vede la LAN dell'host direttamente, mDNS funziona out-of-box

# Opzione B — bridge + avahi-reflector sidecar (cross-platform)
services:
  api:
    networks: [mm_net]
  avahi:
    image: ydkn/avahi:latest
    network_mode: host
    volumes: ['/var/run/dbus:/var/run/dbus']
    environment:
      AVAHI_REFLECTOR: "yes"
```

Default nel repo: **opzione A** per semplicità (home server Linux). Opzione B
documentata in `INSTALL.md` per Docker Desktop Mac/Windows dove host network
non è disponibile.

**Dipendenze TypeScript plugin:**
```json
{ "axios": "^1.7.0", "typescript": "^5.6.0",
  "@types/node": "^22.0.0", "vitest": "^2.0.0",
  "js-tiktoken": "^1.0.0",          // stima token precisa lato plugin
  "bloom-filters": "^3.0.0"          // lettura bloom filter scaricato
}
```
