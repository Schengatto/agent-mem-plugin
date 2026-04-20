# API Specification — MemoryMesh

Base URL: `http://minipc.local` (LAN) — configurabile in `MEMORYMESH_URL`
Auth: header `X-API-Key: mm_prod_xxx` su tutti gli endpoint tranne `/health`

---

## Observations

### POST /api/v1/observations → 202
```json
// Request
{ "project":"my-app", "session_id":"uuid", "type":"observation",
  "content":"Write auth.ts — JWT RS256 implementato",
  "scope":["api","services"],      // NUOVO: path gerarchico (Strategia 9)
  "token_estimate":42,               // NUOVO: tiktoken client-side (Strategia 17)
  "tags":["auth"], "expires_at":null, "metadata":{"tool":"Write","file":"auth.ts"} }

// Response 202 (immediato, embedding asincrono)
// Se server ha applicato capping (Strategia 17), lo segnala:
{ "id":4821, "status":"accepted", "embedding_status":"queued",
  "capped":false, "stored_tokens":42 }
```
**type validi:** `identity` `directive` `context` `bookmark` `observation`

**Campi nuovi:**
- `scope`: array path dal project root, derivato dal file/cwd (es. `["api","routers"]`).
  `[]` o omesso = scope root/globale.
- `token_estimate`: conteggio tiktoken cl100k_base, usato server-side per validazione
  `MAX_OBS_TOKENS` (default 200). Se eccede, il server tronca e accoda tightening.

### POST /api/v1/observations/batch → 200
```json
// Request  { "ids":[12,45,89] }
// Response
{ "observations":[
    { "id":12, "type":"directive", "content":"Mai mock DB in test...",
      "tags":["testing"], "metadata":null, "created_at":"...", "expires_at":null }
]}
```

### DELETE /api/v1/observations/{id} → 204

---

## Manifest

### GET /api/v1/manifest → 200 / 304
```
Query: project=my-app&budget=3000&lang=it
       &scope_prefix=/api/routers     ← NUOVO: filtra branch (Strategia 9)
       &root_only=true                ← NUOVO: solo entries cache-stable
Headers: If-None-Match: "abc123"      ← ETag differenziale (Strategia 1)
```
```json
// 200 root_only=true (cache-stable, sort deterministico per priority,id)
{ "project":"my-app", "total":18, "included":18,
  "token_estimate":520, "truncated":false, "scope":"/", "is_root_set":true,
  "entries":[
    { "id":8,  "type":"directive", "one_liner":"Mai mock DB in test",                   "priority":1 },
    { "id":12, "type":"identity",  "one_liner":"Senior dev, TypeScript strict, Neovim", "priority":0 }
    // NIENTE age_hours qui — invalida cache
  ]
}
// Header: ETag: "abc123"  (stabile, cambia solo dopo distillazione root)

// 200 con scope_prefix=/api/routers (branch volatile, age_hours incluso)
{ "project":"my-app", "total":7, "included":7,
  "token_estimate":310, "scope":"/api/routers", "is_root_set":false,
  "entries":[
    { "id":91, "type":"context",     "one_liner":"PG16 migration — in corso", "age_hours":6 },
    { "id":184,"type":"observation", "one_liner":"Write routers/manifest.py",  "age_hours":2 }
  ]
}
// Header: ETag: "scope-/api/routers-rev17"

// 304 se ETag corrisponde → plugin usa cache locale
```

One-liner max chars per tipo: identity/directive=80, context=40, bookmark=35, observation=20.

### GET /api/v1/agents-md → 200 / 304 (Codex / generic agents)
```
Query: project=my-app
       &scope_prefix=/api/routers     ← opzionale, branch da includere
       &include_branch=true           ← default true
       &format=markdown               ← markdown | text (default markdown)
Headers: If-None-Match: "agents-md-rev42"
```
```
HTTP/1.1 200 OK
Content-Type: text/markdown; charset=utf-8
ETag: "agents-md-rev42"
X-MemoryMesh-Cache-Stable-Bytes: 1840
X-MemoryMesh-Volatile-Bytes: 720

<!-- @memorymesh:begin cache-stable -->
## Vocabolario (28 termini, 18 con shortcode)
[entity] $AS|AuthService=api/services/auth.py·JWT·deps:$UR,Redis
...

## Contesto Root (18 memorie)
- [identity] Senior dev, TypeScript strict, Neovim (#12)
- [directive] Mai mock DB in test (#8)
...
<!-- @memorymesh:end cache-stable -->

<!-- @memorymesh:begin volatile -->
## Contesto Scope: api/routers (7 memorie)
- [context] PG16 migration — in corso (#91, 6h fa)
...
<!-- @memorymesh:end volatile -->
```
Differenza con `/manifest`: questo endpoint restituisce **Markdown formattato
pronto per AGENTS.md di Codex**, già concatenando vocab + manifest root + branch.
I marker `<!-- @memorymesh:begin/end -->` permettono al CLI `codex-prep` di
ri-iniettare in modo idempotente (sostituisce solo la sezione fra i marker).

Il prefisso cache-stable è racchiuso nei suoi marker e collocato **per primo**
così che il prompt caching di OpenAI lo veda come prefix stabile.

### GET /api/v1/manifest/delta → 200 (Strategia 11)
```
Query: project=my-app&scope=/api/routers&since_etag=scope-/api/routers-rev17
```
```json
// 200 — delta dal turno precedente (sequenza N → N+1)
{ "changed":true, "etag":"scope-/api/routers-rev18",
  "added":[
    { "id":204, "type":"observation", "one_liner":"Edit routers/search.py", "age_hours":0 }
  ],
  "removed_ids":[],
  "approx_tokens":35
}

// 200 nessun delta
{ "changed":false, "etag":"scope-/api/routers-rev17" }
```
Il plugin accumula i delta come "tail" fuori dal prefisso cache-stable.
Se la somma `approx_tokens` accumulati > 30% del branch, plugin forza full refresh.

---

## Search

### GET /api/v1/search → 200
```
Query: q=jwt+auth&project=my-app&type=directive&type=context&limit=5
       &mode=hybrid                  ← NUOVO: bm25 | vector | hybrid (default)
       &scope=/api                   ← NUOVO: filtra observations per scope
       &rerank=true                  ← NUOVO: cross-encoder rerank top-20→top-5
```
```json
{ "results":[
    { "id":8,  "type":"directive",  "one_liner":"Mai mock DB in test",        "score":0.847 },
    { "id":34, "type":"observation","one_liner":"Write auth.ts JWT",           "score":0.821 }
  ],
  "cached":false, "latency_ms":42,
  "mode_used":"bm25",                 // NUOVO: quale modalità ha effettivamente risposto
  "rerank_applied":true,              // NUOVO
  "candidates_considered":40          // NUOVO: dimensione del pool prima di top-K
}
```

**mode:**
- `bm25`: solo PostgreSQL FTS, zero Ollama. Best per nomi entity, identifier esatti.
- `vector`: solo pgvector HNSW, sempre embedding query. Best per query semantiche libere.
- `hybrid` (default): BM25 prelude. Se top BM25 score > `BM25_SKIP_THRESHOLD` (0.3),
  short-circuit. Altrimenti vector + RRF merge. Default risparmia ~60% Ollama call.

**rerank:** se `true` e `SEARCH_RERANK_ENABLED=true` server-side,
applica cross-encoder `bge-reranker-base` a top-20 → top-5. Aggiunge ~50ms latenza.

**Default limit=5.** Usa `expand=true` per fino a 20 risultati.
**MAI full content** — usa `/observations/batch` per quello.

### GET /api/v1/timeline → 200
```
Query: obs_id=34&window_sessions=3
```
```json
{ "anchor":34,
  "before":[{ "id":31, "type":"observation", "one_liner":"Setup middleware chain", "age_hours":4 }],
  "after": [{ "id":37, "type":"observation", "one_liner":"Test auth — 12/12 pass", "age_hours":1 }] }
```

---

## Vocabolario

### GET /api/v1/vocab/lookup → 200 / 404
```
Query: term=AuthService&project=my-app
```
```json
{ "term":"AuthService", "category":"entity",
  "definition":"Gestisce autenticazione JWT RS256",
  "detail":"api/services/auth.py · deps:UserRepo,RedisCache · test:tests/test_auth.py",
  "metadata":{"path":"api/services/auth.py","deps":["UserRepo","RedisCache"]},
  "confidence":1.0, "usage_count":12 }
```
Lookup cascade: esatto → fuzzy (soglia 80) → semantico.

### GET /api/v1/vocab/search → 200
```
Query: q=auth+service&project=my-app&category=entity&limit=5
```
```json
{ "results":[
    { "term":"AuthService", "category":"entity", "definition":"...", "score":0.92 }
  ] }
```

### POST /api/v1/vocab → 201
```json
// Request
{ "project":"my-app", "term":"RefreshService", "category":"entity",
  "definition":"Gestisce JWT refresh token",
  "detail":"api/services/refresh.py · deps:Redis",
  "metadata":{"path":"api/services/refresh.py"} }
// source='manual', confidence=1.0 automaticamente
```

### GET /api/v1/vocab/manifest → 200 / 304
```
Query: project=my-app&limit=50
Headers: If-None-Match: "vocab-abc123"
```
```json
// 200 — shortcode binding attivo (Strategia 12), sort deterministico per term
{ "manifest_text":"[entity] $AS|AuthService=api/services/auth.py·JWT·deps:$UR,Redis\n[entity] $UR|UserRepo=api/repositories/user.py·Repository\n[conv] test_*=pytest+testcontainers,mai mock DB\n...",
  "term_count":28, "shortcode_count":18, "token_estimate":145 }
// Header: ETag: "vocab-abc123"

// 304 se ETag invariato
```
Ordering stabile: term ASC (case-insensitive). Cambia solo dopo vocab_upsert o
reassignment shortcode (distillazione). Prefisso cache-stable lato plugin.

### GET /api/v1/vocab/bloom → 200 (Strategia 10)
```
Query: project=my-app
Headers: If-None-Match: "bloom-xyz"
```
```json
{ "project":"my-app",
  "filter_bytes":"BASE64...",       // serializzazione bloom-filters compatibile lato TS
  "size":12288,                      // bit count
  "hashes":4,
  "items":142,                       // termini inseriti
  "false_positive_rate":0.01,
  "version":"1.0" }
// Header: ETag: "bloom-xyz"
```
Dimensione tipica: ~10-20 KB per 1000 termini. Il plugin scarica e salva in
`~/.memorymesh/vocab.bloom`, re-sync se `If-None-Match` risponde 200 (update
bloom server-side avviene a ogni vocab_upsert, asincrono).

---

## Sessions

### POST /api/v1/sessions → 201
```json
{ "project":"my-app" }
// → { "session_id":"uuid", "started_at":"..." }
```

### POST /api/v1/sessions/{id}/close → 200
```json
// → { "obs_count":14, "duration_minutes":47 }
```

### POST /api/v1/sessions/{id}/compress → 202
```json
// Request
{ "messages":[{"role":"user","content":"..."},{"role":"assistant","content":"..."},...],
  "project":"my-app" }

// Response 202
{ "summary_obs_id":4892, "tokens_before":12400, "tokens_after":420, "tokens_saved":11980 }
```
Compressione asincrona — Qwen3 locale. Il summary è disponibile dal turno successivo.

---

## Extract

### POST /api/v1/extract → 202
```json
// Request
{ "project":"my-app",
  "messages":[{"role":"user","content":"Non usare mai mock per il DB"},
              {"role":"assistant","content":"Capito, DB reale sempre"}] }

// Response 202
{ "status":"queued", "job_id":"extract_abc123" }
```

---

## Fingerprint Predict (Strategia 16)

### GET /api/v1/fingerprint/predict → 200
```
Query: project=my-app&pattern=SessionStart&scope=/api/routers
```
```json
{ "pattern":"SessionStart",
  "confidence":0.74,
  "predicted_ids":[8, 12, 91],         // observation probabilmente richieste
  "predicted_terms":["AuthService","UserRepo","manifest"],  // vocab termini
  "ttl_seconds":300,                    // cache suggerita lato plugin
  "miss":false }
```
Se `miss=true` (no pattern con confidence >= 0.6 trovato): ritorna `predicted_ids:[]`.
Il plugin chiama questo endpoint fire-and-forget al SessionStart e dopo ogni
tool call significativo; pre-carica in batch_cache locale in background.

### POST /api/v1/fingerprint/feedback → 202
```json
// Request — plugin segnala hit/miss al fingerprint
{ "pattern":"SessionStart",
  "requested_ids":[8, 91],              // cosa Claude effettivamente ha richiesto
  "predicted_ids":[8, 12, 91] }
// Response 202 → aggiorna hit_count/miss_count in query_fingerprints
{ "status":"accepted" }
```

---

## Metriche Sessione (Strategia 18)

### POST /api/v1/metrics/session → 202
```json
// Request — plugin invia al SessionEnd
{ "session_id":"uuid",
  "project":"my-app",
  "tokens_manifest_root":520,
  "tokens_manifest_branch":310,
  "tokens_vocab":145,
  "tokens_search":420,
  "tokens_batch_detail":850,
  "tokens_history_saved":12400,
  "cache_hits_bytes":14200,
  "cache_misses_bytes":1840,
  "turns_total":17 }
// Response 202
{ "status":"accepted", "id":9182 }
```
Inserisce in tabella `token_metrics`. Aggregato in `/stats` per 7/30 giorni.

### GET /api/v1/metrics/session/{id} → 200
Restituisce la row singola. Utile per debug regressioni.

---

## Pairing & Device Management (Zero-Touch Onboarding)

### POST /api/v1/pair → 201 / 401 / 410 / 429
**No auth** (auth emergerà DAL PIN stesso). Rate limit STRICTER: 10 req/min per IP.
```json
// Request — plugin consuma un PIN mostrato dalla UI admin
{ "pin":"123456",
  "device_name":"MacBook Enrico",     // editabile dall'utente al pair
  "hostname":"enrico-mbp.local",       // $(hostname)
  "os_info":"Darwin 24.0.0 arm64",
  "agent_kind":"claude-code" }         // claude-code | codex | generic-mcp

// Response 201 — PIN valido, API key generata
{ "api_key":"mm_prod_abcd1234...",     // plaintext, mostrato una volta sola
  "device_id":"uuid",
  "user_id":"uuid",
  "server_name":"MemoryMesh on mm.local",
  "project_hint":"my-app",              // opzionale, se admin ha specificato project_slug
  "default_project_id":"uuid"           // progetto di default dell'utente
}

// Response 410 — PIN scaduto o già consumato
{ "error":"pin_expired_or_consumed" }

// Response 401 — PIN sbagliato
{ "error":"invalid_pin", "attempts_remaining":7 }

// Response 429 — troppi tentativi PIN da questo IP
{ "error":"too_many_attempts", "retry_after":900 }
```

Il PIN è **one-shot**: dopo un consumo riuscito `consumed_at` è settato e un
secondo POST con lo stesso PIN ritorna 410. Se fallito 10 volte da uno stesso IP
in 15 minuti → 429 con backoff.

### GET /api/v1/projects?slug=X → 200 / 404
**Auth: `X-API-Key` (la key appena ottenuta dal pair).**
```
Query: slug=my-app
```
```json
// 200 — progetto esiste
{ "id":"uuid", "slug":"my-app", "is_team":false, "git_remote":"github.com/.../my-app",
  "created_at":"..." }

// 404 — non esiste
{ "error":"project_not_found" }
```
Usato dall'installer per auto-detection: plugin deriva `slug` da git remote,
chiama questo, se 404 può creare via POST /api/v1/projects.

### POST /api/v1/projects — già esistente, esteso
```json
// Request ora accetta git_remote opzionale per duplicate detection
{ "slug":"my-saas-app", "is_team":false, "git_remote":"github.com/schengatto/my-saas-app" }
// Response 201 o 409 se slug già esistente per l'user
```

### GET /api/v1/mdns-info → 200
**Auth: `X-API-Key`.** Diagnostica per plugin che vuole verificare che il server
raggiunto via mDNS sia davvero MemoryMesh.
```json
{ "service":"memorymesh", "version":"1.0.0",
  "base_url":"http://mm.local",
  "features":["vocab","scope","shortcode","rerank"] }
```

---

## Admin — Pairing

### POST /admin/pair/create → 201 (richiede MFA fresh)
```json
// Request — admin genera un PIN per pair nuovo device
{ "label_hint":"PC ufficio",           // opzionale, default ''
  "project_slug":"my-app",              // opzionale, forza project al consume
  "ttl_seconds":300 }                   // default 300 (5 min), max 900

// Response 201
{ "pair_id":"uuid",
  "pin":"123456",                        // mostrato UNA volta all'admin
  "expires_at":"2026-04-20T10:05:00Z",
  "qr_payload":"memorymesh://pair?url=http://mm.local&pin=123456" }
```
Il PIN plaintext vive solo in Redis (TTL 5min). In DB viene salvato solo
`pin_hash` + metadata per audit.

### GET /admin/pair/pending → 200
Lista PIN attivi (non scaduti, non consumati). Usato dall'UI per mostrare
timer countdown "Pair in attesa: PIN 123456, scade fra 3:42".
```json
{ "pending":[
    { "pair_id":"uuid", "label_hint":"PC ufficio", "expires_at":"...",
      "seconds_remaining":222 }
  ]}
```

### DELETE /admin/pair/{pair_id} → 204 (richiede MFA fresh)
Revoca un PIN prima della scadenza (es. generato per errore).

---

## Admin — Devices

### GET /admin/devices → 200
```
Query: include_revoked=false (default), agent_kind=claude-code
```
```json
{ "items":[
    { "id":"uuid", "device_label":"MacBook Enrico", "hostname":"enrico-mbp.local",
      "os_info":"Darwin 24.0.0 arm64", "agent_kinds":["claude-code","codex"],
      "created_at":"...", "last_seen_at":"...", "last_seen_ip":"192.168.1.42",
      "revoked_at":null }
  ]}
```

### PATCH /admin/devices/{id} → 200 (richiede MFA fresh)
```json
// Request — rinomina label
{ "device_label":"iMac studio" }
```

### DELETE /admin/devices/{id} → 204 (richiede MFA fresh)
**Revoca immediata dell'API key**. Il device non può più usare il server.
Non elimina la riga (audit), setta `revoked_at=now()`. Al prossimo tentativo
di uso, il plugin riceve 401 e può ri-paire.

---

## MCP Tools (Compatibilità claude-mem)

Formato risposta identico a claude-mem per drop-in replacement.

```
POST /mcp/tools/search           → { results:[{id,summary,type,score}] }
POST /mcp/tools/get_observations → { observations:[{id,content,type,...}] }
POST /mcp/tools/timeline         → { before:[...], after:[...] }
POST /mcp/tools/extract          → { status, job_id }  (NUOVO)
POST /mcp/tools/vocab_lookup     → { term, category, definition, ... }  (NUOVO)
POST /mcp/tools/vocab_upsert     → { id, term, ... }  (NUOVO)
```

---

## Utenti e Progetti

### POST /api/v1/users → 201
```json
{ "name":"Mario" }
// → { "id":"uuid", "api_key":"mm_prod_xxx" }  ← key mostrata UNA volta
```

### POST /api/v1/projects → 201
```json
{ "slug":"my-saas-app", "is_team":false }
```

---

## Stats e Health

### GET /api/v1/stats?project=X → 200
```json
{ "counts":{"identity":3,"directive":12,"context":8,"bookmark":5,"observation":1847},
  "vocab_terms":28, "shortcodes_active":18,
  "storage_mb":24.3,
  "last_distillation":"2026-04-13T03:00:00Z",
  "token_efficiency":{
    "manifest_cache_hits_today":8,
    "manifest_cache_misses_today":2,
    "avg_manifest_tokens":1180,
    "compressions_today":3,
    "avg_tokens_saved_per_compression":8400,
    "prompt_cache":{
      "avg_hit_rate_7d":0.78,
      "bytes_hit_today":142000,
      "bytes_miss_today":18400,
      "stability_streak_hours":36
    },
    "scope_routing":{
      "root_tokens_avg":520,
      "branch_tokens_avg":310,
      "branches_active":14
    },
    "search_mode_distribution":{
      "bm25_only":0.62, "hybrid":0.33, "vector_only":0.05
    },
    "rerank_enabled":true,
    "rerank_avg_latency_ms":47,
    "fingerprint_hit_rate":0.58,
    "capping_events_today":3
  }
}
```

### GET /health → 200 / 503

Due varianti in base all'autenticazione:

**Liveness (nessuna auth, solo "alive"):** minimal info, safe da esporre.
```
GET /health
→ 200 {"status":"ok"}
→ 503 {"status":"degraded"}
```

**Readiness dettagliato (richiede auth):** stato componenti interni.
```
GET /health/detail
Headers: X-API-Key: <any valid key>   (data plane)
   oppure Cookie: mm_admin_sess=...   (admin)

→ 200 { "status":"ok", "postgres":"up", "redis":"up", "ollama":"up",
        "embed_queue_depth":0, "version":"1.0.0" }
```

Il liveness è limitato a **200/min per IP** (per permettere monitoring esterno
senza essere anonymous-scannable). Caddy config restringe accesso a
`/health/detail` a IP `private_ranges` + request size < 1KB, mai ACLable da internet:

```
@health_detail path /health/detail
@public not remote_ip private_ranges
handle @health_detail {
  respond @public "Not Found" 404      # nasconde esistenza
  reverse_proxy api:8000
}
```

---

## Admin Plane (UI-facing, `/admin/*`)

**Auth:** cookie `mm_admin_sess` (httpOnly, Secure, SameSite=strict) + header
`X-CSRF-Token` su tutti i verbi mutanti (POST/PUT/PATCH/DELETE).
**NON** accettano `X-API-Key`. **NON** sono raggiungibili da plugin.
**Rate limit:** 5 req/min per IP su `/admin/login` e `/admin/setup`,
60 req/min su tutti gli altri.

### POST /admin/setup → 201 (bootstrap una sola volta)
```
Accessibile SOLO se admin_users è vuota. Dopo il primo setup: 403 permanente.
```
```json
// Request
{ "username":"enrico", "password":"<strong_password>" }

// Response 201
{ "admin_id":"uuid", "totp_secret":"JBSWY3DPEHPK3PXP",
  "totp_provisioning_uri":"otpauth://totp/MemoryMesh:enrico?secret=...&issuer=MemoryMesh",
  "recovery_codes":["12ab-34cd","ef56-7890", ...],  // 10 codici, mostrati UNA VOLTA
  "next":"verify_totp" }
```
Il client mostra il QR + i recovery code. L'admin scansiona, conferma col
prossimo endpoint.

### POST /admin/setup/verify-totp → 200
```json
// Request  { "admin_id":"uuid", "totp_code":"123456" }
// Response 200 { "status":"verified", "next":"login" }
// Response 401 { "error":"invalid_totp" }
```
Marca `totp_verified=true`. Da questo punto il login richiede il 2FA.

### POST /admin/login → 200 / 401 / 429
```json
// Request — step 1: password
{ "username":"enrico", "password":"..." }
// Response 200 → richiede secondo fattore
{ "mfa_required":true, "mfa_session":"ephemeral_token_5min",
  "methods":["totp","webauthn"] }
// Response 401 { "error":"invalid_credentials" }  (generico, non distingue user/pass)
```
```json
// Request — step 2a: TOTP
{ "mfa_session":"...", "method":"totp", "totp_code":"123456" }
// Response 200 — Set-Cookie: mm_admin_sess=...; HttpOnly; Secure; SameSite=Strict
{ "admin":{"username":"enrico"}, "csrf_token":"...", "expires_at":"..." }

// Request — step 2b: WebAuthn (dopo GET /webauthn/assertion-options)
{ "mfa_session":"...", "method":"webauthn", "assertion": {...} }
// Response 200 — stessa forma
```
Session TTL default **8h sliding**. Dopo 8h di inattività: revoca automatica.

### POST /admin/webauthn/registration-options → 200
```
Cookie session required. Restituisce le challenge options per registrare
una nuova passkey (in aggiunta al TOTP, sempre presente).
```
```json
{ "publicKey":{
    "challenge":"<base64url>", "rp":{"name":"MemoryMesh","id":"mm.local"},
    "user":{"id":"...","name":"enrico","displayName":"enrico"},
    "pubKeyCredParams":[{"type":"public-key","alg":-7},{"alg":-257,"type":"public-key"}],
    "authenticatorSelection":{"userVerification":"required"}
  }}
```

### POST /admin/webauthn/registration-verify → 201
```json
// Request
{ "credential":{...}, "label":"YubiKey 5C blu" }
// Response 201
{ "credential_id":"uuid", "label":"YubiKey 5C blu" }
```

### POST /admin/webauthn/assertion-options → 200
```json
// Request — per login senza TOTP
{ "mfa_session":"..." }
// Response — challenge opzioni per WebAuthn get()
{ "publicKey":{"challenge":"...", "allowCredentials":[{...}], "userVerification":"required"}}
```

### POST /admin/logout → 204
Revoca la sessione (`revoked_at=now()`). Cookie invalidato.

### GET /admin/me → 200
```json
{ "username":"enrico",
  "totp_enrolled":true,
  "webauthn_credentials":[{"id":"uuid","label":"YubiKey 5C blu","last_used_at":"..."}],
  "session_expires_at":"...",
  "mfa_fresh_until":"..." }
```

### POST /admin/reauth → 200
```
Re-prompt MFA prima di operazioni destructive. Estende mfa_fresh_until di 5 min.
```
```json
// Request { "method":"totp", "code":"123456" }
// Response 200 { "mfa_fresh_until":"..." }
```

---

## Admin — Gestione Memorie (readonly + edit)

### GET /admin/memories → 200
```
Query: project=my-app&type=directive&scope_prefix=/api&q=auth&page=1&per_page=50
       &include_distilled=false   ← default false
```
```json
{ "total":147, "page":1, "per_page":50,
  "items":[
    { "id":8, "project":"my-app", "type":"directive",
      "content":"Mai mock DB in test", "scope":[],
      "tags":["testing"], "relevance_score":1.0,
      "access_count":23, "token_estimate":8,
      "created_at":"...", "last_used_at":"...",
      "distilled_into":null, "shortcode_refs":["$AS","$UR"] }
  ] }
```

### GET /admin/memories/{id} → 200
Full detail incluso content completo, metadata, embedding_status, merged_from.

### PATCH /admin/memories/{id} → 200 (richiede MFA fresh)
```json
// Request — campi editabili: type, content, tags, expires_at, relevance_score
{ "type":"directive", "content":"Nuovo contenuto", "tags":[...] }
```
Invalida cache search + accoda re-embedding. Scrive audit entry.

### DELETE /admin/memories/{id} → 204 (richiede MFA fresh)
Soft delete se fa parte di una catena `distilled_into` (imposta `expires_at=now()`),
hard delete altrimenti.

### POST /admin/memories/bulk-delete → 202 (richiede MFA fresh)
```json
{ "ids":[12,45,89], "reason":"cleanup stale context" }
// Response { "scheduled":3, "audit_id":"uuid" }
```
Asincrono, log in audit con reason.

---

## Admin — Vocab

### GET /admin/vocab → 200
```
Query: project=my-app&category=entity&q=auth&page=1&per_page=100
```
Ritorna lista full (incluso `detail`, `metadata`, `source`, `confidence`, `usage_count`, `shortcode`).

### PATCH /admin/vocab/{id} → 200 (richiede MFA fresh)
Edit `definition`, `detail`, `metadata`, `category`. Il `term` è immutabile
(cambierebbe lo shortcode → invaliderebbe cache). Per rinominare: delete + create.

### DELETE /admin/vocab/{id} → 204 (richiede MFA fresh)
Rimuove anche shortcode e riferimenti inline dai detail di altre entry al prossimo rebuild.

### POST /admin/vocab/rebuild-shortcodes → 202 (richiede MFA fresh)
Forza assegnazione shortcode fuori dal ciclo notturno. Utile dopo import bulk.

---

## Admin — Sessions

### GET /admin/sessions → 200
```
Query: project=my-app&has_summary=true&compressed=true&page=1
```
Lista sessioni con metadata (started, closed, obs_count, compressed_at, summary_obs_id).

### GET /admin/sessions/{id} → 200
Detail completo. Include `tool_sequence`, `token_metrics` aggregate.

### POST /admin/sessions/{id}/force-compress → 202 (MFA fresh)
Trigger compress manuale su sessione chiusa.

---

## Admin — Settings

### GET /admin/settings → 200
```json
{ "retention.observation_days":{"value":180, "description":"Auto-pruning per type=observation", "updated_at":"..."},
  "distillation.cron":{"value":"0 3 * * *", ...},
  "search.rerank_enabled":{"value":true, ...},
  "token.max_obs_tokens":{"value":200, ...},
  "vocab.shortcode_threshold":{"value":10, ...},
  ...
}
```

### PUT /admin/settings/{key} → 200 (richiede MFA fresh)
```json
// Request  { "value":365 }
// Response 200 { "key":"retention.observation_days", "value":365, "updated_at":"..." }
```
Le setting modificabili da UI sono un subset di tutte (whitelist). I secret
(DB password, SECRET_KEY, TOTP secret) **NON** sono mai esposti né modificabili da UI.

---

## Admin — Audit Log

### GET /admin/audit → 200
```
Query: action=memory.delete&from=2026-04-01&to=2026-04-20&page=1
```
```json
{ "items":[
    { "id":4821, "action":"memory.delete", "target_type":"observation", "target_id":"184",
      "details":{"type":"observation","content_preview":"Write routers/..."},
      "success":true, "ip":"192.168.1.20", "created_at":"..." }
  ]}
```

### POST /admin/audit/export → 202 (richiede MFA fresh)
```
Produce un CSV dell'audit log. Asincrono perché può coprire anni di log.
```
```json
// Request
{ "from":"2026-01-01", "to":"2026-04-20",
  "actions":["memory.delete","settings.update"],   // filtro opzionale
  "success_only":false }

// Response 202
{ "job_id":"export_abc123", "status":"queued", "estimated_rows":4820 }
```

### GET /admin/audit/export/{job_id} → 200 / 202
```
Polling dello stato job. 202 se ancora in corso, 200 con download URL una volta pronto.
```
```json
// 202
{ "job_id":"export_abc123", "status":"processing", "progress":0.45 }

// 200 (file pronto, disponibile 24h poi eliminato)
{ "job_id":"export_abc123", "status":"ready",
  "download_url":"/admin/audit/export/export_abc123/download",
  "rows_exported":4820, "size_bytes":482000,
  "expires_at":"2026-04-21T..." }
```

### GET /admin/audit/export/{job_id}/download → 200
```
Streaming CSV con Content-Disposition: attachment. One-shot: il file viene
eliminato dopo il primo download riuscito.
Content-Type: text/csv; charset=utf-8
```

---

## Admin — Stats Estesi

### GET /admin/stats → 200
Stessi campi di `/api/v1/stats` + sezione admin-only:
```json
{ "counts":{...}, "token_efficiency":{...},
  "admin":{
    "sessions_active":1, "sessions_today":3,
    "failed_logins_today":0,
    "last_distillation_errors":[]
  }}
```

---

## Security Headers (applicati a ogni risposta)

Middleware FastAPI globale. Alcuni header si attivano solo su profile `public`.

| Header | Valore | Profile |
|--------|--------|---------|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains; preload` | public |
| `X-Content-Type-Options` | `nosniff` | all |
| `X-Frame-Options` | `DENY` | all |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | all |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` | all |
| `Content-Security-Policy` | nonce-based, vedi SECURITY §4.3 | /admin/* sempre |
| `Cross-Origin-Opener-Policy` | `same-origin` | all |
| `Cross-Origin-Resource-Policy` | `same-origin` | all |
| `Cross-Origin-Embedder-Policy` | `require-corp` | /admin/* |

Su profile `lan` senza TLS: omesso HSTS (non ha senso su HTTP).

---

## Rate Limits (riepilogo globale)

| Endpoint | Limite | Key | Note |
|----------|--------|-----|------|
| `POST /api/v1/observations` | 1000/min | project_id | baseline elevato, capture è frequente |
| `POST /api/v1/observations/batch` (read) | 500/min | device_id | anti-dump |
| `GET /api/v1/search` | 60/min | device_id | anomaly detect se > 10× baseline |
| `GET /api/v1/manifest` | 300/min | device_id | include ETag 304 |
| `POST /api/v1/sessions/{id}/compress` | 3/5min | session_id | Qwen3 costoso |
| `POST /api/v1/pair` | 10/15min | IP | anti brute-force PIN |
| `POST /api/v1/extract` | 5/min | project_id | Qwen3 costoso |
| `GET /api/v1/stats` | 30/min | device_id | |
| `POST /admin/setup` | 5/min | IP | lockout 15min dopo 10 fail |
| `POST /admin/login` | 5/min | IP | + globale 10/15min lockout |
| `POST /admin/reauth` | 10/min | session_id | |
| `POST /admin/pair/create` | 10/min | admin_id | max 3 pending |
| Tutti gli altri `/admin/*` | 60/min | session_id | |
| Tutti i `/api/v1/*` default | 120/min | device_id | |

Oltre al limite applicativo, Caddy ha un limite globale per IP (1000/min)
per bloccare scan. Profile public: 300/min per IP.

---

## Payload Size Limits

| Limite | Valore | Dove enforzato |
|--------|--------|----------------|
| Max request body | 1 MiB | Caddy (413 Payload Too Large) |
| Max single observation content | 64 KiB | Caddy + FastAPI Pydantic |
| Max header size totale | 8 KiB | Caddy |
| Max URL length | 2048 char | Caddy |
| Max multipart file | N/A (nessun upload file) | – |

Dimensione osservazione realistica: < 1 KiB. Il limite 64 KiB è per edge case
(log dump, file intero accidental). Oltre: error `obs_content_too_large` al plugin
che tronca client-side.

---

## Error Handling Generico

Il server NON espone stack trace, librerie, versioni. Global exception handler:

```python
@app.exception_handler(Exception)
async def generic_handler(request: Request, exc: Exception):
    request_id = str(uuid4())
    logger.error("unhandled", exc_info=exc, request_id=request_id, path=request.url.path)
    return JSONResponse(
        status_code=500,
        content={"error":"internal_error", "request_id": request_id},
        headers={"X-Request-ID": request_id}
    )
```

Il `request_id` è correlabile con i log (audit trail post-incident) ma non rivela nulla.

Per eccezioni previste: `HTTPException` con `{"error":"<machine_code>", "message":"<human>"}`.
Mai includere SQL, path filesystem, nomi classe interne nella risposta.

---

## Codici di Errore

| Codice | Quando |
|--------|--------|
| 202 | POST observation/extract/compress (async) |
| 304 | Manifest/vocab/bloom/agents-md non cambiato (ETag match) |
| 401 | Data plane: nessuna API key. Admin plane: nessuna sessione o credenziali invalide. |
| 403 | API key non valida / progetto non accessibile / admin session scaduta / CSRF invalido / MFA scaduto per op destructive |
| 409 | /admin/setup chiamato con admin già esistente |
| 422 | Validazione Pydantic fallita (es. type non valido, TOTP malformato) |
| 429 | Rate limit superato (stricter su /admin/login, /admin/setup, /admin/reauth) |
| 503 | DB o Redis non raggiungibili |

```json
// Formato errore standard
{ "error":"invalid_type", "message":"type 'foo' non valido. Usa: identity|directive|context|bookmark|observation", "request_id":"req_abc" }
```
