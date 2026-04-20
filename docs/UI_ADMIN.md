# UI Admin — Specifica Completa

> Leggi questo file prima di lavorare sui task F10-*.
> Complementare ad `API_SPEC.md §Admin Plane` e `ARCHITECTURE.md §Admin Plane`.

## Obiettivo

UI web locale (LAN) per consultare e gestire le memorie MemoryMesh. Accesso
ristretto a un unico admin con password + MFA obbligatorio (TOTP + opzionale
WebAuthn). Serve due casi d'uso:

1. **Consultazione**: esplorare cosa il sistema ha memorizzato, cercare, auditare.
2. **Manutenzione**: eliminare memorie stale, aggiornare vocab, cambiare settings
   operative (retention, threshold, CRON distillazione).

Non è usata in-sessione dagli agenti (quello è MCP). È uno strumento operativo
umano.

---

## Stack

```
Nuxt 4 (Vue 3 + Vite)                # framework
├── @nuxt/ui                          # component library + Tailwind integrato
├── @pinia/nuxt                       # state management
├── @vueuse/nuxt                      # utility composables
├── @simplewebauthn/browser           # WebAuthn client API
├── zxcvbn-ts                         # password strength al setup
└── qrcode.vue                        # rendering QR TOTP enrollment

Modalità: SSR disabilitato, build statico (`nuxt generate`)
  → output .output/public/ copiato in api/app/static/
  → FastAPI serve /static/* + /admin/* API

Nessun backend Nuxt/Nitro runtime. Solo HTML+JS statici + chiamate fetch.
```

**Perché SPA statica e non SSR:**
- Un solo processo server (FastAPI). Niente Node runtime extra in produzione.
- Auth è 100% API-based — nessun bisogno di SSR per SEO o pre-render.
- Una sola immagine Docker (no Nuxt container separato).
- Aggiornamenti indipendenti: rebuild SPA e rideploya solo lo statico.

---

## Struttura File (monorepo esistente)

```
ui/                                # NUOVO workspace nel repo
├── package.json
├── nuxt.config.ts
├── app.vue
├── app/
│   ├── layouts/
│   │   ├── default.vue             # layout post-login (sidebar + header)
│   │   └── auth.vue                # layout login/setup (centered card)
│   ├── middleware/
│   │   ├── auth.ts                 # redirect a /login se no session
│   │   └── mfa-fresh.ts            # redirect a /reauth se destructive op
│   ├── pages/
│   │   ├── setup.vue               # bootstrap (solo se admin assente)
│   │   ├── login.vue               # password + TOTP/WebAuthn
│   │   ├── reauth.vue              # re-prompt MFA per op destructive
│   │   ├── index.vue               # dashboard: stats + attività recente
│   │   ├── memories/
│   │   │   ├── index.vue           # list + filter + bulk action
│   │   │   └── [id].vue            # detail + edit
│   │   ├── vocab/
│   │   │   ├── index.vue           # list vocab + shortcode map
│   │   │   └── [id].vue            # edit
│   │   ├── sessions/
│   │   │   ├── index.vue           # lista sessioni
│   │   │   └── [id].vue            # detail + tool_sequence + metrics
│   │   ├── settings.vue            # form KV editabili whitelisted
│   │   ├── audit.vue               # log filtrabile
│   │   └── account/
│   │       ├── totp.vue            # ri-enroll TOTP (con MFA fresh)
│   │       ├── passkeys.vue        # registra/rimuovi WebAuthn
│   │       └── devices.vue         # pair new device + list + revoke (Fase 11)
│   ├── composables/
│   │   ├── useApi.ts               # wrapper fetch con CSRF + session cookie
│   │   ├── useAuth.ts              # login/logout/session state
│   │   ├── useMfaFresh.ts          # trigger re-prompt MFA quando serve
│   │   └── useWebAuthn.ts          # register/assert WebAuthn
│   ├── stores/
│   │   ├── auth.ts                 # Pinia: user, session, csrf
│   │   ├── memories.ts             # cache + filters
│   │   └── settings.ts
│   └── utils/
│       ├── csrf.ts                 # helper header X-CSRF-Token
│       └── format.ts               # format date, bytes, token counts
└── tests/
    └── e2e/                        # Playwright contro server dev
```

---

## Flusso Auth

### Primo Setup (bootstrap)

```
1. Admin apre http://mm.local/admin/
   → Nuxt SPA load
   → chiama GET /admin/me
   → 401 "setup_required" (admin_users vuota)
   → redirect a /setup

2. /setup.vue
   → form username + password (con zxcvbn strength meter)
   → POST /admin/setup
   → risposta: totp_secret + provisioning URI + recovery codes
   → mostra QR code (qrcode.vue) + codici recupero
   → utente scansiona con app authenticator
   → input TOTP code per verifica
   → POST /admin/setup/verify-totp
   → redirect a /login

3. /login.vue
   → login normale (vedi sotto)
```

### Login Normale

```
1. Password step
   → form username + password
   → POST /admin/login  (step 1)
   → risposta: { mfa_required:true, mfa_session, methods:["totp","webauthn"] }
   → mostra selector del metodo (se passkey registrata disponibile)

2a. TOTP
   → input 6 cifre
   → POST /admin/login { mfa_session, method:"totp", totp_code }
   → response 200 → cookie set automaticamente, csrf_token ricevuto
   → redirect a / (dashboard)

2b. WebAuthn
   → POST /admin/webauthn/assertion-options { mfa_session } → challenge
   → navigator.credentials.get(publicKey) → assertion
   → POST /admin/login { mfa_session, method:"webauthn", assertion }
   → response 200 → stesso flow
```

### Re-prompt MFA per Destructive

```
Utente clicca "Delete observation #184" in /memories/184
  → composable useMfaFresh.require()
  → controlla useAuth().mfaFreshUntil
  → se già fresh (entro 5 min): procedi
  → se scaduto: overlay modal con TOTP input
    → POST /admin/reauth { method:"totp", code:"..." }
    → response 200 → aggiorna mfaFreshUntil, chiudi modal, procedi
    → response 401 → error + mantieni modal aperto
```

---

## Pagine in Dettaglio

### `/` — Dashboard

Widget:
- **Counts**: observation, vocab_terms, shortcode_active per tipo (da /admin/stats)
- **Token efficiency**: cache_hit_rate 7gg, tokens saved, distribuzione mode search
- **Attività recente**: ultime 10 righe di audit log
- **Health**: stato DB/Redis/Ollama/reranker da /health

### `/memories`

Tabella paginata, 50/pagina. Colonne:
`id`, `type`, `project`, `content` (truncato), `scope`, `score`, `access_count`,
`last_used_at`, `created_at`, `age`.

Filtri (URL query params, stato persistente):
- project multi-select
- type multi-select (identity/directive/context/bookmark/observation)
- scope_prefix testuale
- q free text (BM25 via /admin/memories?q=...)
- range data
- has_expiration (yes/no/any)
- is_distilled_into_something (yes/no/any)
- min access_count

Bulk actions: seleziona N → "Delete", "Set expiration", "Bump score". Richiedono MFA fresh.

Azioni per riga: view detail, edit, delete, timeline (chiama /api/v1/timeline).

### `/memories/[id]`

- Full content (markdown renderizzato se Markdown, monospace se codice)
- Form edit inline: type, content, tags, expires_at, relevance_score (slider)
- Metadata (JSON viewer)
- Embedding status (computed/pending/failed)
- Merged_from links (se distilled_into)
- Tasto "Delete" + "Timeline"

### `/vocab`

Tabella. Colonne: `term`, `shortcode`, `category`, `definition`, `usage_count`,
`confidence`, `source`, `updated_at`.

Filtri: project, category, source (manual/auto), has_shortcode.

Mappa shortcode visibile in pannello laterale (es. `$AS → AuthService`).

Azioni: edit, delete, "Rebuild shortcodes" (bottone admin, MFA fresh).

### `/vocab/[id]`

Form edit: category, definition (max 80 chars con counter), detail (textarea),
metadata JSON. Il `term` è readonly con hint "per rinominare: delete e crea nuovo".

### `/sessions`

Lista sessioni più recenti. Colonne: id, project, started_at, duration,
obs_count, has_summary, compressed_at.

Filtri: project, compressed (yes/no), ha_errori_distillazione.

### `/sessions/[id]`

- Metadata sessione
- `tool_sequence` come badge chain (Edit → Bash → Read → …)
- `token_metrics`: grafico a barre (tokens per categoria)
- Observation create in sessione (link a /memories/[id])
- Summary se compressed, con diff tokens_before/after
- Tasto "Force compress" (MFA fresh)

### `/settings`

Grid di card, una per setting whitelistata. Ogni card:
- key (readonly, es. `retention.observation_days`)
- description
- value editabile (type-aware: number/string/bool/json)
- tasto "Save" (chiama PUT /admin/settings/{key}, MFA fresh)
- last updated

**Settings esposte alla UI (whitelist lato server):**
```
retention.observation_days          (int, default 180)
retention.context_days              (int, default 365)
distillation.cron                   (string, default "0 3 * * *")
distillation.merge_threshold        (float 0..1, default 0.92)
distillation.decay_observation_factor (float, default 0.85)
distillation.decay_context_factor   (float, default 0.97)
search.rerank_enabled               (bool, default true)
search.bm25_skip_threshold          (float 0..1, default 0.3)
token.max_obs_tokens                (int, default 200)
token.compress_threshold            (int, default 8000)
vocab.shortcode_threshold           (int, default 10)
vocab.extract_enabled               (bool, default true)
manifest.default_budget             (int, default 3000)
fingerprint.min_sessions            (int, default 3)
fingerprint.min_confidence          (float, default 0.6)
```

**Settings NON esposte alla UI** (modificabili solo via .env/deploy): DATABASE_URL,
SECRET_KEY, REDIS_URL, OLLAMA_URL, admin TOTP secret.

### `/audit`

Tabella paginata, sort desc per default. Colonne: timestamp, action, target,
admin, success, ip.

Filtri: action prefix, from/to date, success only, target_type.

Export CSV (solo per audit log di >30 giorni) via POST /admin/audit/export.

### `/account/totp`

- Status attuale: enrolled / not
- Re-enroll button (genera nuovo secret, richiede MFA fresh col vecchio)
- Recovery codes: rigenera (invalida i precedenti, MFA fresh)

### `/account/passkeys`

- Lista passkey registrate (label, last_used_at, transports)
- Tasto "Aggiungi nuova passkey" → flow WebAuthn registration
- Tasto "Remove" per ogni (MFA fresh)

### `/account/devices` (Zero-Touch Onboarding)

Due sezioni:

**A) Device registrati** — tabella con colonne:
- `device_label` (es. "MacBook Enrico")
- `hostname`
- `os_info` (compatto: "macOS arm64")
- `agent_kinds` come badge (`claude-code`, `codex`)
- `created_at` (relative: "3 giorni fa")
- `last_seen_at` (relative: "5 min fa", colorato: verde <24h, grigio >7gg)
- Azioni: **Rename** (modal, MFA fresh), **Revoke** (MFA fresh, conferma testuale "Scrivi il nome del device per confermare")

**B) Pair nuovo device** — card con tasto `[+ Pair new device]`:

Al click apre modal:
```
┌─────────────────────────────────────────────────┐
│  Pair new device                            [×] │
├─────────────────────────────────────────────────┤
│  Label hint (opzionale):  [PC ufficio_______]  │
│  Project default (opt.):  [my-app (dropdown)▼] │
│                                                 │
│  [Generate PIN]                                │
└─────────────────────────────────────────────────┘
```

Dopo click su Generate PIN:
```
┌─────────────────────────────────────────────────┐
│  PIN attivo per 4:58                        [×] │
├─────────────────────────────────────────────────┤
│                                                 │
│              ┌──────────────┐                  │
│              │              │                  │
│              │  QR code     │                  │
│              │              │                  │
│              └──────────────┘                  │
│                                                 │
│           PIN: 1 2 3 4 5 6                     │
│                                                 │
│  Incolla il PIN nel plugin Claude Code.        │
│  Oppure scansiona il QR con la app mobile.     │
│                                                 │
│  [Cancel]                       [New PIN]       │
└─────────────────────────────────────────────────┘
```

Countdown live (setInterval 1s). Quando raggiunge 0:00 chiama DELETE del PIN.
Ogni 2 secondi polling di `/admin/pair/pending` — quando il PIN scompare dalla
lista pending, il modal mostra:

```
┌─────────────────────────────────────────────────┐
│  ✓ Device paired!                           [×] │
│                                                 │
│    MacBook Enrico (macOS arm64)                │
│    appena registrato                            │
│                                                 │
│                    [Done]                       │
└─────────────────────────────────────────────────┘
```

**QR payload**: `memorymesh://pair?url=https://mm.local&pin=123456`.
Un'app mobile (fuori scope per il MVP) potrebbe leggerlo e completare il pair
automaticamente; per il plugin CLI l'utente guarda il PIN e lo digita.

**Policy pending**:
- Massimo 3 PIN attivi simultaneamente per admin (evita spam)
- Ogni generazione richiede MFA fresh
- La generazione scrive audit entry `pair.create` con label_hint
- Il consumo (da `/api/v1/pair`) scrive audit entry `pair.consume` con device_id
- La revoca (DELETE device) scrive `device.revoke`

---

## Composables Chiave

### `useApi.ts`

```typescript
export const useApi = () => {
  const auth = useAuthStore()

  async function apiFetch<T>(path: string, opts: FetchOptions = {}): Promise<T> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      ...(opts.headers ?? {})
    }
    // CSRF obbligatorio per mutanti
    if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(opts.method ?? 'GET')) {
      headers['X-CSRF-Token'] = auth.csrfToken
    }

    const res = await $fetch.raw<T>(path, {
      baseURL: '/',   // same-origin, cookie inviato automaticamente
      credentials: 'include',
      ...opts,
      headers
    })

    // Gestione 401/403 centralizzata
    if (res.status === 401) {
      auth.clear()
      await navigateTo('/login')
      throw new Error('unauthorized')
    }
    if (res.status === 403 && res._data?.error === 'mfa_required') {
      const ok = await useMfaFresh().require()
      if (ok) return apiFetch<T>(path, opts)   // retry dopo re-auth
      throw new Error('mfa_denied')
    }

    return res._data as T
  }

  return { apiFetch }
}
```

### `useWebAuthn.ts`

```typescript
import { startRegistration, startAuthentication } from '@simplewebauthn/browser'

export const useWebAuthn = () => {
  const { apiFetch } = useApi()

  async function registerPasskey(label: string) {
    const options = await apiFetch<PublicKeyCredentialCreationOptionsJSON>(
      '/admin/webauthn/registration-options', { method: 'POST' }
    )
    const credential = await startRegistration(options)
    return apiFetch('/admin/webauthn/registration-verify', {
      method: 'POST',
      body: { credential, label }
    })
  }

  async function assertLogin(mfaSession: string) {
    const options = await apiFetch<PublicKeyCredentialRequestOptionsJSON>(
      '/admin/webauthn/assertion-options',
      { method: 'POST', body: { mfa_session: mfaSession } }
    )
    const assertion = await startAuthentication(options)
    return apiFetch('/admin/login', {
      method: 'POST',
      body: { mfa_session: mfaSession, method: 'webauthn', assertion }
    })
  }

  return { registerPasskey, assertLogin }
}
```

---

## Build & Deploy

### Dev loop

```bash
# Terminal 1: API FastAPI
make up   # docker compose con FastAPI in watch

# Terminal 2: Nuxt dev
cd ui && pnpm dev  # http://localhost:3000
# Proxy configurato in nuxt.config.ts: /admin/* → http://localhost:8000
```

### Production build

```bash
cd ui
pnpm install
pnpm generate      # → .output/public/
rm -rf ../api/app/static
cp -r .output/public ../api/app/static
```

Il `Makefile` include:
```
ui-build:
	cd ui && pnpm install && pnpm generate
	rm -rf api/app/static && cp -r ui/.output/public api/app/static

build: ui-build
	docker compose build
```

### FastAPI routing

```python
# api/app/main.py
from fastapi.staticfiles import StaticFiles

app.mount("/static", StaticFiles(directory="app/static/_nuxt"), name="nuxt-assets")

@app.get("/admin/", include_in_schema=False)
@app.get("/admin/{path:path}", include_in_schema=False)
async def serve_ui(path: str = ""):
    # Serve index.html per ogni route /admin/* → SPA client-side routing
    return FileResponse("app/static/index.html")
```

---

## Test E2E (F10-12)

Playwright contro stack completo (FastAPI + PG + Redis, senza Ollama/Qwen mockati).

1. **Setup flow**: prima visita `/admin/` → redirect `/setup` → completa flow → TOTP verificato → redirect a login.
2. **Login password + TOTP**: password corretta → step TOTP → code corretto → dashboard.
3. **Rate limit /admin/login**: 6 tentativi in 1 minuto → 429.
4. **Session expiry**: dopo 8h inattività → richiesta protetta ritorna 401, redirect a login.
5. **CSRF**: PATCH senza X-CSRF-Token → 403.
6. **MFA fresh flow**: DELETE observation → modal TOTP → code corretto → procedi. Code sbagliato → mantieni modal.
7. **WebAuthn register**: da `/account/passkeys` → simulatore virtual-authenticator Playwright → credential registrata.
8. **WebAuthn login**: con credential simulata in session store → login senza TOTP.
9. **Memories filter**: filtro per `type=directive` → solo directive in tabella.
10. **Memories edit**: cambia content, submit → GET /admin/memories/{id} riflette il cambio. Audit entry presente.
11. **Settings whitelist**: tentare PUT `/admin/settings/SECRET_KEY` → 403.
12. **Audit log**: dopo login + delete + settings change → 3 entry in `/audit`.
13. **Cross-tab logout**: logout in tab 1 → tab 2 ricarica → redirect /login.
14. **Setup idempotente**: seconda POST `/admin/setup` (anche con stesso payload) → 409.
15. **Pair flow end-to-end**: admin genera PIN → terminale simulato chiama `/api/v1/pair` con PIN corretto → entry in `/account/devices` appare, modal si chiude automaticamente.
16. **PIN scaduto**: admin genera PIN → aspetta 6 min → POST /pair → 410.
17. **PIN one-shot**: due POST /pair con stesso PIN valido → primo 201, secondo 410.
18. **PIN rate limit**: 11 tentativi falliti da stesso IP in 1min → 429.
19. **Device revoke**: admin revoca device → chiamata con quella api_key torna 401.

---

## Sicurezza — Checklist Implementazione

### Password

- [ ] argon2id (argon2-cffi) con parametri `memory_cost=65536, time_cost=3, parallelism=4`
- [ ] Minimo 12 caratteri, zxcvbn score >= 3 al setup (lato client E server)
- [ ] Constant-time compare per password check (argon2 integrato)
- [ ] Failed login counter per IP (Redis) — non per username (previene enumeration)

### TOTP

- [ ] Secret da `pyotp.random_base32()` (160-bit)
- [ ] Cifrato at-rest con AES-GCM, key derivata da SECRET_KEY via HKDF
- [ ] Window ±1 step (±30s), non di più
- [ ] Provisioning URI include `issuer=MemoryMesh` e hostname per app authenticator
- [ ] Recovery codes: 10 × 8 char alfanumerico, SHA-256 hash in DB, usage_once

### WebAuthn

- [ ] `rp.id` = hostname del server (es. `mm.local`)
- [ ] `userVerification=required` (richiede PIN/biometria)
- [ ] Challenge random 32 bytes per request, TTL 5min in Redis
- [ ] `sign_count` validazione anti-replay (reject se <= stored)
- [ ] Supporto `residentKey` (discoverable) per UX senza username

### Session Cookie

- [ ] `httpOnly`, `Secure` (solo HTTPS in prod), `SameSite=Strict`
- [ ] Valore: UUID v4 + HMAC signed con SECRET_KEY (itsdangerous)
- [ ] TTL 8h sliding. Inactivity timeout automatico.
- [ ] Rotazione session_token dopo login MFA (prevent session fixation)

### CSRF

- [ ] Double-submit: cookie `mm_csrf` + header `X-CSRF-Token`, deve matchare
- [ ] Generato al login, ruotato al re-auth
- [ ] Verifica solo su POST/PUT/PATCH/DELETE
- [ ] GET immuni (read-only), ma endpoint come `/admin/memories/bulk-delete` usa POST per essere protetto

### Rate Limiting

- [ ] `/admin/login` e `/admin/setup`: 5 req/min per IP (slowapi)
- [ ] `/admin/reauth`: 10 req/min per session
- [ ] Tutti gli altri `/admin/*`: 60 req/min per session

### Audit

- [ ] Ogni chiamata `/admin/*` (eccetto `/admin/me` e GET readonly) → log
- [ ] `details` JSONB: diff compatto, MAI password/token/TOTP/secret
- [ ] Rotation: cron mensile esporta > 90 giorni in `/backups/audit-YYYY-MM.jsonl`, elimina da tabella

### Logging

- [ ] MAI log password (nemmeno hash al livello debug)
- [ ] MAI log TOTP code, WebAuthn assertion, session token
- [ ] IP log OK, user agent OK, action OK
- [ ] Log format structlog JSON con `event=admin_login`, `admin_id=...`, `success=true/false`

### Network

- [ ] `/admin/*` raggiungibile solo su LAN (Caddy config) o via VPN/Tailscale
- [ ] TLS obbligatorio fuori da LAN privata (Caddy auto-cert / Let's Encrypt via Cloudflare DNS)
- [ ] Option: bind Caddy admin UI su IP specifico (non 0.0.0.0) via env

### CSP Strict (nonce-based, admin UI)

```
Content-Security-Policy:
  default-src 'self';
  script-src 'self' 'nonce-{random}' 'strict-dynamic';
  style-src 'self' 'nonce-{random}';
  img-src 'self' data: blob:;
  connect-src 'self';
  font-src 'self' data:;
  frame-ancestors 'none';
  form-action 'self';
  base-uri 'self';
  object-src 'none';
  upgrade-insecure-requests;               [solo profile public]
  report-uri /admin/csp-report;
```

Implementazione FastAPI middleware:
```python
@app.middleware("http")
async def csp_middleware(request: Request, call_next):
    response = await call_next(request)
    if request.url.path.startswith("/admin/"):
        nonce = secrets.token_urlsafe(16)
        request.state.csp_nonce = nonce   # accessibile per injection in HTML
        response.headers["Content-Security-Policy"] = (
            f"default-src 'self'; "
            f"script-src 'self' 'nonce-{nonce}' 'strict-dynamic'; "
            f"style-src 'self' 'nonce-{nonce}'; "
            f"img-src 'self' data: blob:; connect-src 'self'; "
            f"frame-ancestors 'none'; form-action 'self'; base-uri 'self'; "
            f"object-src 'none'; report-uri /admin/csp-report"
        )
    return response
```

Nuxt config per injection nonce nei tag `<script>` e `<style>` del build output:
Nuxt genera automaticamente hash per gli asset; il nonce viene iniettato dal
server FastAPI nella sostituzione dell'HTML `index.html` template prima della
risposta.

### X-Frame-Options e Clickjacking

`X-Frame-Options: DENY` + CSP `frame-ancestors 'none'` doppia protezione.
Il pannello admin NON deve mai essere incorporato in iframe.

### Subresource Integrity (SRI)

Nuxt 4 configurato in `nuxt.config.ts`:
```typescript
export default defineNuxtConfig({
  app: {
    head: {
      // Nuxt auto-genera hash SRI per asset del build
    }
  },
  experimental: { payloadExtraction: true },
  nitro: {
    prerender: {
      crawlLinks: false
    }
  }
})
```

Gli asset nel `.output/public/_nuxt/` hanno nome contenente il content hash
(cache-busting). SRI non serve per risorse same-origin, ma se in futuro si
usa una CDN (unlikely) aggiungere `integrity="sha384-..."` agli script.

### XSS Prevention — Rendering Memory Content

```vue
<!-- ✗ PERICOLOSO se content user-provided -->
<div v-html="observation.content"></div>

<!-- ✓ safe: interpolazione escapa automaticamente -->
<pre class="content">{{ observation.content }}</pre>

<!-- ✓ se devi renderizzare markdown (es. observation che contiene code blocks) -->
<script setup>
import DOMPurify from 'isomorphic-dompurify'
import { marked } from 'marked'

const safeHtml = computed(() => {
  const rendered = marked.parse(props.content, {
    breaks: true,
    gfm: true,
  })
  return DOMPurify.sanitize(rendered, {
    ALLOWED_TAGS: ['p','br','strong','em','code','pre','ul','ol','li','h1','h2','h3','blockquote','a'],
    ALLOWED_ATTR: ['href','class'],
    ALLOW_DATA_ATTR: false
  })
})
</script>
<template>
  <article class="memory-content" v-html="safeHtml"/>
</template>
```

CSP nonce-based blocca comunque eventuali script iniettati anche se DOMPurify
fallisce.

### Session Hijack Detection (client-side)

Ogni GET `/admin/me` ritorna `session.ip` + `session.user_agent`. Composable
`useAuth` confronta con valori iniziali post-login:

```typescript
// composables/useAuth.ts
export const useAuth = () => {
  const initialIp = ref<string>('')
  const initialUA = ref<string>('')

  async function refresh() {
    const me = await apiFetch<MeResponse>('/admin/me')
    if (initialIp.value && me.session.ip !== initialIp.value) {
      // IP cambiato: force re-auth MFA (no revoca, solo prompt)
      await useMfaFresh().require('session_ip_changed')
    }
    if (initialUA.value && significantUAChange(me.session.user_agent, initialUA.value)) {
      await useMfaFresh().require('session_ua_changed')
    }
    initialIp.value ||= me.session.ip
    initialUA.value ||= me.session.user_agent
  }
  // Chiamato al mount principale + ogni 5 min + su visibility change
  return { refresh, ... }
}
```

Lato server, `admin_sessions` ha colonne `ip` e `user_agent` loggate al login;
se diverse oltre tolleranza → flag `mfa_fresh_until=null` (forza re-prompt).

### Form Timing Attack Prevention

Login form: sempre stessa risposta time ±50-100ms (jitter deterministico su
hash del username) per evitare username enumeration via timing:

```python
async def login(body: LoginRequest):
    start = time.monotonic()
    user = await get_admin(body.username)  # può essere None
    # SEMPRE esegui argon2 verify, anche se user è None (dummy hash)
    dummy_hash = "$argon2id$v=19$..."
    hash_to_verify = user['password_hash'] if user else dummy_hash
    valid = verify_password(body.password, hash_to_verify)

    # Jitter target: ~200ms, ± deterministic seed
    elapsed = time.monotonic() - start
    target = 0.200 + (hash(body.username) % 50) / 1000  # 200-250ms
    if elapsed < target:
        await asyncio.sleep(target - elapsed)

    if not user or not valid:
        raise HTTPException(401, {"error":"invalid_credentials"})
    ...
```

Anche se user non esiste, argon2 hash dummy viene comunque computed → timing
indistinguibile.

---

## Installer

```bash
# Primo setup (post-deploy)
make up
curl -f http://mm.local/health   # verifica API
open http://mm.local/admin/      # browser → bootstrap flow

# Dopo il setup, l'admin aggiunge ~/.memorymesh/admin.url al suo PC per shortcut
```

Non c'è CLI di setup: il flow passa interamente dalla UI (mostra QR, recovery codes).
Fallback CLI: `memorymesh admin reset-totp --confirm-with-recovery-code XXXX-YYYY`
(solo se l'admin ha perso il device authenticator).

---

## Note Operative

- **Backup include admin**: `make backup` esporta anche `admin_users`, `admin_webauthn_credentials`, `admin_audit_log`. Il restore ripristina tutto — attenzione a non restore su un server nuovo senza ruotare SECRET_KEY (invaliderebbe TOTP decryption).
- **Perdita device TOTP**: usa un recovery code per login, poi riassegna TOTP da `/account/totp`.
- **Perdita TUTTO (TOTP + recovery codes)**: solo ripristino da backup. Nessuna "password reset via email" (home server, niente mail infra, unico admin).
- **Multi-device accesso**: OK, login da PC + iPad funziona — sessioni indipendenti, audit tracciabile per IP/UA.
