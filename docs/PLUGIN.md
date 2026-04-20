# Plugin — Specifica Completa (Claude Code + Codex)

> Leggi questo file prima di lavorare sui task F7a-* (Claude Code) e F7b-* (Codex).
> Per i dettagli specifici dell'adapter Codex vedi anche `CODEX.md`.

## Scope di Questo Documento

Questo file copre:
1. La **struttura monorepo** con core + adapters
2. L'**adapter Claude Code** in dettaglio (hook, installer)
3. I contratti fra core e adapter

Per l'**adapter Codex** (CLI prep/capture, AGENTS.md injection, transcript
parsing, shell wrapper, differenze operative) → `CODEX.md`.

## Regola Assoluta

**Il plugin non blocca MAI l'agente.**
Ogni HTTP call: timeout 3s hard. Su qualsiasi errore: silent fail + buffer.
Claude Code e Codex funzionano normalmente con o senza MemoryMesh raggiungibile.

---

## Hook Map

| Hook | Trigger | Azione | Blocking? | Token iniettati |
|------|---------|--------|-----------|-----------------|
| `SessionStart` | Inizio sessione | prefisso cache-stable (vocab+root) + branch scope + bloom+fingerprint prefetch | No (<200ms) | ~950 (1° turno) / ~365 (successivi) |
| `UserPromptSubmit` | Prima di ogni prompt | tiktoken estimate, trigger compress, manifest delta (se any) | No | 0 o ~30-80 (delta) |
| `PostToolUse` | Dopo ogni tool | scope detection + tiktoken capping + POST obs + fingerprint predict next | No | 0 |
| `Stop` | Claude interrompe | flush buffer pending (max 2s) | Sì (max 2s) | 0 |
| `SessionEnd` | Fine sessione | telemetry flush + fingerprint feedback + close + extract trigger | No | 0-2K Qwen3 |

---

## Struttura File (monorepo multi-agent)

```
plugin/
├── package.json                    # workspaces: core, adapters/*, cli
├── packages/
│   ├── core/                       # @memorymesh/core
│   │   ├── package.json
│   │   └── src/
│   │       ├── index.ts            # barrel exports
│   │       ├── config.ts           # env vars, validazione agent-agnostic
│   │       ├── client.ts           # HTTP + timeout 3s + silent fail
│   │       ├── buffer.ts           # offline jsonl buffer
│   │       ├── compressor.ts       # stima token tiktoken, trigger compress
│   │       ├── manifest-cache.ts   # cache locale ETag (root + branch)
│   │       ├── bloom.ts            # bloom filter vocab (Strategia 10)
│   │       ├── fingerprint.ts      # predict + feedback (Strategia 16)
│   │       ├── telemetry.ts        # token metrics (Strategia 18)
│   │       ├── scope.ts            # derivazione scope (Strategia 9)
│   │       ├── batch-cache.ts      # batch detail cache per prefetch
│   │       ├── prefix.ts           # serializzazione cache-stable (Strategia 8)
│   │       ├── delta.ts            # manifest delta consumer (Strategia 11)
│   │       └── tiktoken-shim.ts    # wrapper js-tiktoken cl100k_base
│   │
│   ├── adapter-claude-code/        # @memorymesh/adapter-claude-code
│   │   ├── package.json            # dep: @memorymesh/core
│   │   └── src/
│   │       ├── index.ts
│   │       ├── installer.ts        # scrive ~/.claude/settings.json + skill
│   │       └── hooks/
│   │           ├── session-start.ts
│   │           ├── user-prompt-submit.ts
│   │           ├── post-tool-use.ts
│   │           ├── stop.ts
│   │           └── session-end.ts
│   │
│   ├── adapter-codex/              # @memorymesh/adapter-codex
│   │   ├── package.json            # dep: @memorymesh/core
│   │   └── src/
│   │       ├── index.ts
│   │       ├── installer.ts        # scrive ~/.codex/config.toml (MCP server)
│   │       ├── cli-prep.ts         # memorymesh codex-prep
│   │       ├── cli-capture.ts      # memorymesh codex-capture
│   │       ├── agents-md.ts        # merge idempotente marker @memorymesh
│   │       ├── transcript.ts       # parser ~/.codex/sessions/*.json
│   │       └── wrapper.sh.tpl      # template shell wrapper
│   │
│   └── cli/                        # @memorymesh/cli (binario unificato)
│       ├── package.json            # dep: tutti gli adapter
│       └── src/
│           └── index.ts            # memorymesh install|migrate|prep|capture|flush
│
└── tests/
    ├── core/                       # unit test agent-agnostic
    ├── adapter-claude-code/        # integration test hook mocked
    └── adapter-codex/              # integration test con ~/.codex mock
```

**Principio**: il core **non importa mai** nulla da adapter. Gli adapter
importano da core. Dipendenza unidirezionale.

La versione del core segue semver; adapter hanno dipendenza flessibile
(`"@memorymesh/core": "^1.0.0"`) così un fix al core raggiunge entrambi gli
adapter senza re-release esplicito.

---

## session-start.ts (cache-aware, cwd scope)

```typescript
export async function onSessionStart(cwd: string): Promise<string | null> {
  const cfg = loadConfig()
  if (!cfg.enabled) return null

  const client = new ApiClient(cfg)

  // 0. Scope detection da cwd (Strategia 9) — zero HTTP
  const scope = deriveScopeFromCwd(cwd, cfg.projectRoot)  // es. '/api/routers'

  // 1. Flush buffer + async prefetch (non bloccanti)
  new OfflineBuffer().flushInBackground(client)
  VocabBloom.syncInBackground(client, cfg.project)
  Fingerprint.predictInBackground(client, cfg.project, 'SessionStart', scope)

  // 2. Skip manifest per sessioni molto brevi (Strategia 6)
  const state = await loadSessionState()
  const shouldInject = state.avgTurnsPerSession >= 3 || state.totalSessions < 5
  if (!shouldInject) {
    await incrementSessionCounter(state)
    return null
  }

  // 3. Costruzione prefisso cache-stable (Strategia 8)
  //    Ordine FISSO: vocab → obs root. Modifiche invalidano la cache Anthropic.
  const prefix = await buildCacheStablePrefix(client, cfg)

  // 4. Branch scope-specific (volatile, non cachato)
  const branch = await fetchManifestBranch(client, cfg, scope)

  // 5. Aggiorna counter
  await incrementSessionCounter(state)

  // 6. Telemetry init
  const telemetry = TokenTelemetry.forSession()
  telemetry.recordInject('manifest_root',   tiktoken(prefix.rootManifest))
  telemetry.recordInject('vocab',            tiktoken(prefix.vocab))
  telemetry.recordInject('manifest_branch',  tiktoken(branch ?? ''))

  // 7. Composizione finale con separatore cache boundary
  const cacheStable = `${prefix.vocab}\n\n${prefix.rootManifest}`
  const volatile    = branch ? `\n\n## ─── volatile ───\n\n${branch}` : ''
  return cacheStable + volatile
}

async function buildCacheStablePrefix(
  client: ApiClient,
  cfg: Config
): Promise<{ vocab: string; rootManifest: string }> {
  // Entrambi caricati via ETag differenziale — cache locale se 304
  const [vocab, root] = await Promise.all([
    fetchVocabManifest(client, cfg.project),           // serializzazione stabile (sort)
    fetchManifestRoot(client, cfg.project)             // is_root=true, priority+id sort
  ])
  return {
    vocab: vocab ?? '',
    rootManifest: root ?? ''
  }
}

async function fetchManifestRoot(client: ApiClient, project: string): Promise<string | null> {
  const cache = await ManifestCache.load(`${project}:root`)
  const headers = cache?.etag ? { 'If-None-Match': cache.etag } : {}
  try {
    const res = await client.getWithHeaders(
      `/api/v1/manifest?project=${project}&root_only=true`, headers
    )
    if (res.status === 304 && cache) return formatManifestRoot(cache.data)
    const data = await res.json()
    await ManifestCache.save(`${project}:root`, { etag: res.headers['etag'] ?? '', data })
    return formatManifestRoot(data)
  } catch {
    return cache ? formatManifestRoot(cache.data) : null
  }
}

async function fetchManifestBranch(
  client: ApiClient, cfg: Config, scope: string
): Promise<string | null> {
  if (scope === '/' || !scope) return null  // root coperto dal prefisso
  const cacheKey = `${cfg.project}:branch:${scope}`
  const cache = await ManifestCache.load(cacheKey)
  const headers = cache?.etag ? { 'If-None-Match': cache.etag } : {}
  try {
    const res = await client.getWithHeaders(
      `/api/v1/manifest?project=${cfg.project}&scope_prefix=${encodeURIComponent(scope)}`,
      headers
    )
    if (res.status === 304 && cache) return formatManifestBranch(cache.data, scope)
    const data = await res.json()
    await ManifestCache.save(cacheKey, { etag: res.headers['etag'] ?? '', data })
    return formatManifestBranch(data, scope)
  } catch {
    return cache ? formatManifestBranch(cache.data, scope) : null
  }
}

function formatManifestRoot(data: ManifestResponse): string {
  // CACHE-STABLE: niente age_hours, niente timestamp. Solo priority+id+one_liner.
  // Ordering server-side è già deterministico (priority, obs_id).
  const lines = [`## Contesto Root (${data.included} memorie)`]
  for (const e of data.entries) {
    lines.push(`- [${e.type}] ${e.one_liner} (#${e.id})`)
  }
  return lines.join('\n')
}

function formatManifestBranch(data: ManifestResponse, scope: string): string {
  // VOLATILE: age_hours incluso
  const lines = [`## Contesto Scope: ${scope.slice(1)} (${data.included} memorie)`]
  for (const e of data.entries) {
    const age = e.age_hours < 24 ? `${e.age_hours}h` : `${Math.round(e.age_hours/24)}gg`
    lines.push(`- [${e.type}] ${e.one_liner} (#${e.id}, ${age} fa)`)
  }
  return lines.join('\n')
}
```

---

## user-prompt-submit.ts (compression + delta refresh)

```typescript
export async function onUserPromptSubmit(
  messages: Message[],
  sessionId: string,
  cwd: string
): Promise<string | null> {
  const cfg = loadConfig()
  if (!cfg.enabled) return null

  const compressor = await Compressor.getInstance()
  const client = new ApiClient(cfg)

  // 1. Stima token precisa con tiktoken (non chars/4)
  const estimatedTokens = compressor.estimateTokensTiktoken(messages)

  // 2. Trigger compressione se soglia (Strategia 5, già esistente)
  if (estimatedTokens > cfg.compressThresholdTokens) {
    client.postSilent(`/api/v1/sessions/${sessionId}/compress`,
      { messages, project: cfg.project })
    .then((res: any) => compressor.setSummaryId(res?.data?.summary_obs_id))
  }

  // 3. Manifest delta refresh per scope corrente (Strategia 11)
  //    Iniezione aggiuntiva SOLO se ci sono delta, e SOLO in coda (non cache-stable)
  const scope = deriveScopeFromCwd(cwd, cfg.projectRoot)
  const delta = await ManifestDelta.fetchIfAny(client, cfg.project, scope)
  if (!delta || !delta.changed) return null

  // Inietta SOLO il delta in coda, fuori dal prefisso cache-stable
  return formatDelta(delta)
}

function formatDelta(delta: DeltaResponse): string {
  const lines = ['## Aggiornamenti recenti (branch)']
  for (const e of delta.added) {
    lines.push(`[NEW] - [${e.type}] ${e.one_liner} (#${e.id})`)
  }
  if (delta.removed_ids.length > 0) {
    lines.push(`[REMOVED] ${delta.removed_ids.map(i => `#${i}`).join(', ')}`)
  }
  return lines.join('\n')
}
```

---

## post-tool-use.ts (scope + tiktoken + fingerprint feedback)

```typescript
export async function onPostToolUse(
  tool: string,
  input: unknown,
  output: unknown,
  sessionId: string,
  cwd: string
): Promise<void> {
  const cfg = loadConfig()
  if (!cfg.enabled) return

  const content = buildContent(tool, input, output)
  if (!content) return

  // Strategia 9: scope derivato dal file_path del tool o cwd fallback
  const scope = deriveScopeFromToolInput(tool, input, cwd, cfg.projectRoot)

  // Strategia 17: pre-capping lato plugin (evita round-trip se troppo grande)
  let finalContent = content
  const tokens = tiktoken(content)
  if (tokens > cfg.maxObsTokens) {
    // tronca lato client per evitare di spedire kB inutili
    finalContent = truncToTokens(content, Math.floor(cfg.maxObsTokens * 0.9)) + '...[capped]'
  }

  const payload: ObsPayload = {
    project: cfg.project,
    session_id: sessionId,
    type: 'observation',
    content: finalContent,
    scope,                       // NUOVO
    token_estimate: tiktoken(finalContent),  // NUOVO
    metadata: { tool, original_tokens: tokens > cfg.maxObsTokens ? tokens : undefined }
  }

  // Fire & forget con timeout 3s hard
  const client = new ApiClient(cfg)
  await client.postObservationSilent(payload)  // never throws

  // Append tool alla session sequence (per fingerprint aggregation server-side)
  SessionToolSequence.append(sessionId, tool)

  // Fingerprint predict per prossimo step (fire&forget, warm batch_cache)
  Fingerprint.predictInBackground(client, cfg.project,
    SessionToolSequence.patternOf(sessionId), scope.join('/'))
}

function buildContent(tool: string, input: unknown, output: unknown): string | null {
  const i = input as Record<string, unknown>
  const o = output as Record<string, unknown>

  switch (tool) {
    case 'Write':
    case 'Edit':
      return `${tool}: ${i.file_path} — ${trunc(String(o.result ?? ''), 100)}`
    case 'Bash':
      return `Bash: ${trunc(String(i.command ?? ''), 60)} — ${trunc(String(o.stdout ?? ''), 80)}`
    case 'WebFetch':
      return `Fetch: ${i.url}`
    default:
      return null  // Read, Glob, ecc. non salvare
  }
}

function deriveScopeFromToolInput(
  tool: string, input: unknown, cwd: string, projectRoot: string
): string[] {
  const i = input as Record<string, unknown>
  const filePath = (i?.file_path as string) ?? cwd
  return deriveScope(filePath, projectRoot)
}
```

---

## session-end.ts (telemetry + fingerprint feedback)

```typescript
const SESSION_COUNTER_PATH = path.join(os.homedir(), '.memorymesh', 'session_counter')

export async function onSessionEnd(
  messages: Message[],
  sessionId: string,
  requestHeaders: Record<string, string>  // da runtime per cache hit/miss
): Promise<void> {
  const cfg = loadConfig()
  if (!cfg.enabled) return

  const client = new ApiClient(cfg)

  // 1. Telemetry flush (Strategia 18)
  const telemetry = TokenTelemetry.forSession()
  telemetry.recordCacheMetrics(requestHeaders)
  telemetry.setTurns(messages.length)
  telemetry.flushBackground(sessionId, cfg.project, client)

  // 2. Fingerprint feedback (Strategia 16) — cosa è stato effettivamente richiesto
  const requested = BatchCache.getRequestedIds(sessionId)
  const predicted = Fingerprint.getPredictedIds(sessionId)
  if (predicted.length > 0) {
    client.postSilent('/api/v1/fingerprint/feedback', {
      pattern: 'SessionStart',
      requested_ids: requested,
      predicted_ids: predicted
    })
  }

  // 3. Chiudi sessione + tool_sequence
  client.postSilent(`/api/v1/sessions/${sessionId}/close`, {
    tool_sequence: SessionToolSequence.export(sessionId)
  })

  // 4. Aggiorna media turni (per skip manifest)
  await updateAvgTurns(messages.length)

  // 5. Extract ogni N sessioni
  const count = await readAndIncrement(SESSION_COUNTER_PATH)
  if (count % cfg.extractEveryN === 0 && messages.length > 5) {
    client.postSilent('/api/v1/extract', {
      project: cfg.project,
      messages: messages.slice(-50)
    })
  }

  // 6. Cleanup in-memory session state
  SessionToolSequence.clear(sessionId)
  BatchCache.clear(sessionId)
  TokenTelemetry.reset()
}
```

---

## bloom.ts (Strategia 10)

```typescript
import { BloomFilter } from 'bloom-filters'

const BLOOM_PATH = path.join(os.homedir(), '.memorymesh', 'vocab.bloom')
const BLOOM_META_PATH = path.join(os.homedir(), '.memorymesh', 'vocab.bloom.meta')
const SYNC_TTL_MS = 3600_000  // 1 ora

export class VocabBloom {
  private static instance: VocabBloom | null = null
  private filter: BloomFilter | null = null
  private loadedAt: number = 0
  private etag: string = ''

  static async get(): Promise<VocabBloom> {
    if (!this.instance) {
      this.instance = new VocabBloom()
      await this.instance.loadFromDisk()
    }
    return this.instance
  }

  static syncInBackground(client: ApiClient, project: string): void {
    VocabBloom.get().then(b => b.sync(client, project)).catch(() => {})
  }

  async sync(client: ApiClient, project: string): Promise<void> {
    if (Date.now() - this.loadedAt < SYNC_TTL_MS) return
    const headers = this.etag ? { 'If-None-Match': this.etag } : {}
    try {
      const res = await client.getWithHeaders(`/api/v1/vocab/bloom?project=${project}`, headers)
      if (res.status === 304) { this.loadedAt = Date.now(); return }
      const body = await res.json()
      this.filter = BloomFilter.fromJSON({
        size: body.size, nbHashes: body.hashes, filter: body.filter_bytes
      })
      this.etag = res.headers['etag'] ?? ''
      this.loadedAt = Date.now()
      await this.persist(body)
    } catch { /* silent — continua a usare cache */ }
  }

  mightContain(term: string): boolean {
    if (!this.filter) return true   // fail-open: assumi presenza
    return this.filter.has(term.toLowerCase())
  }

  private async loadFromDisk(): Promise<void> { /* legge BLOOM_PATH se esiste */ }
  private async persist(data: any): Promise<void> { /* scrive BLOOM_PATH + meta */ }
}
```

---

## fingerprint.ts (Strategia 16)

```typescript
const FINGERPRINT_TTL_MS = 300_000  // 5 min

interface Prediction {
  pattern: string; confidence: number
  predicted_ids: number[]; predicted_terms: string[]
  fetchedAt: number
}

export class Fingerprint {
  private static cache: Map<string, Prediction> = new Map()
  private static perSession: Map<string, number[]> = new Map()

  static predictInBackground(
    client: ApiClient, project: string, pattern: string, scope: string
  ): void {
    const key = `${project}:${pattern}:${scope}`
    const cached = this.cache.get(key)
    if (cached && Date.now() - cached.fetchedAt < FINGERPRINT_TTL_MS) return

    client.get(`/api/v1/fingerprint/predict?project=${project}&pattern=${encodeURIComponent(pattern)}&scope=${encodeURIComponent(scope)}`)
      .then((res: any) => {
        const data = res.data
        if (data.confidence < 0.6) return  // non pre-caricare se non fiducioso
        this.cache.set(key, { ...data, fetchedAt: Date.now() })
        // Pre-carica in batch_cache in background
        if (data.predicted_ids.length > 0) {
          BatchCache.prewarm(client, project, data.predicted_ids)
        }
      })
      .catch(() => {})
  }

  static getPredictedIds(sessionId: string): number[] {
    return this.perSession.get(sessionId) ?? []
  }
}
```

---

## telemetry.ts (Strategia 18)

```typescript
interface TokenCounters {
  manifest_root: number; manifest_branch: number; vocab: number
  search: number; batch_detail: number; history_saved: number
  cache_hits_bytes: number; cache_misses_bytes: number; turns: number
}

export class TokenTelemetry {
  private static session: TokenTelemetry | null = null
  private counters: TokenCounters = {
    manifest_root: 0, manifest_branch: 0, vocab: 0,
    search: 0, batch_detail: 0, history_saved: 0,
    cache_hits_bytes: 0, cache_misses_bytes: 0, turns: 0
  }

  static forSession(): TokenTelemetry {
    if (!this.session) this.session = new TokenTelemetry()
    return this.session
  }
  static reset() { this.session = null }

  recordInject(kind: keyof TokenCounters, tokens: number) {
    this.counters[kind] += tokens
  }

  recordCacheMetrics(headers: Record<string, string>) {
    // Headers esposti da runtime — nomi esatti da confermare in F7-11
    this.counters.cache_hits_bytes += parseInt(headers['x-cache-read-input-tokens'] ?? '0')
    this.counters.cache_misses_bytes += parseInt(headers['x-cache-creation-input-tokens'] ?? '0')
  }

  setTurns(n: number) { this.counters.turns = n }

  flushBackground(sessionId: string, project: string, client: ApiClient) {
    client.postSilent('/api/v1/metrics/session', {
      session_id: sessionId, project,
      tokens_manifest_root: this.counters.manifest_root,
      tokens_manifest_branch: this.counters.manifest_branch,
      tokens_vocab: this.counters.vocab,
      tokens_search: this.counters.search,
      tokens_batch_detail: this.counters.batch_detail,
      tokens_history_saved: this.counters.history_saved,
      cache_hits_bytes: this.counters.cache_hits_bytes,
      cache_misses_bytes: this.counters.cache_misses_bytes,
      turns_total: this.counters.turns
    })
  }
}
```

---

## scope.ts (Strategia 9)

```typescript
/** Deriva scope array da file path relativo al project root.
 *  '/abs/project/api/routers/search.py' → ['api','routers']
 *  Ignora il nome file, tiene solo directory. */
export function deriveScope(filePath: string, projectRoot: string): string[] {
  const rel = path.relative(projectRoot, filePath)
  if (!rel || rel.startsWith('..')) return []
  const parts = rel.split(path.sep).filter(Boolean)
  return parts.slice(0, -1)
}

export function deriveScopeFromCwd(cwd: string, projectRoot: string): string {
  const scope = deriveScope(cwd + path.sep + '_sentinel', projectRoot)
  return scope.length === 0 ? '/' : '/' + scope.join('/')
}
```

---

## prefix.ts (Strategia 8) — serializzazione cache-stable

```typescript
/** Garantisce output byte-per-byte identico dato lo stesso input.
 *  Il server dovrebbe già restituire dati sortati; questa è difesa in profondità. */
export function serializeRootManifest(entries: ManifestEntry[]): string {
  const sorted = [...entries].sort((a, b) =>
    (a.priority - b.priority) || (a.id - b.id)
  )
  const lines = [`## Contesto Root (${sorted.length} memorie)`]
  for (const e of sorted) {
    // Encoding NFC + separatori fissi. NIENTE age_hours, score, timestamp.
    lines.push(`- [${e.type}] ${normalize(e.one_liner)} (#${e.id})`)
  }
  return lines.join('\n')
}

export function serializeVocabPrefix(entries: VocabEntry[]): string {
  const sorted = [...entries].sort((a, b) =>
    a.term.toLowerCase().localeCompare(b.term.toLowerCase())
  )
  const lines = [`## Vocabolario (${sorted.length} termini)`]
  for (const e of sorted) {
    const sc = e.shortcode ? `${e.shortcode}|` : ''
    lines.push(`[${e.category}] ${sc}${e.term}=${normalize(e.definition)}`)
  }
  return lines.join('\n')
}

function normalize(s: string): string {
  return s.normalize('NFC').replace(/\r\n/g, '\n').trim()
}
```

---

## compressor.ts (aggiornato con tiktoken)

```typescript
import { Tiktoken, getEncoding } from 'js-tiktoken'

const encoder: Tiktoken = getEncoding('cl100k_base')

export class Compressor {
  // ... stato esistente ...

  /** Conta token EFFETTIVI con tiktoken cl100k_base, non approssimazione chars/4. */
  estimateTokensTiktoken(messages: Message[]): number {
    return messages.reduce((sum, m) => sum + encoder.encode(m.content).length, 0)
  }

  // metodo legacy per retrocompatibilità
  estimateTokens(messages: Message[]): number {
    return this.estimateTokensTiktoken(messages)
  }
}

export function tiktoken(text: string): number {
  return encoder.encode(text).length
}

export function truncToTokens(text: string, maxTokens: number): string {
  const tokens = encoder.encode(text)
  if (tokens.length <= maxTokens) return text
  return encoder.decode(tokens.slice(0, maxTokens))
}
```

---

## client.ts

```typescript
export class ApiClient {
  constructor(private cfg: Config) {}

  async getWithHeaders(path: string, headers: Record<string, string>) {
    return this.fetchTimeout(`${this.cfg.url}${path}`, { method: 'GET', headers })
  }

  async postObservationSilent(payload: ObsPayload): Promise<void> {
    try {
      await this.fetchTimeout(`${this.cfg.url}/api/v1/observations`, {
        method: 'POST',
        body: JSON.stringify(payload),
        headers: { 'Content-Type': 'application/json' }
      })
    } catch {
      await new OfflineBuffer().push(payload).catch(() => {})
    }
  }

  postSilent(path: string, body: unknown): void {
    // Completamente fire & forget, nessun await
    this.fetchTimeout(`${this.cfg.url}${path}`, {
      method: 'POST',
      body: JSON.stringify(body),
      headers: { 'Content-Type': 'application/json' }
    }).catch(() => {})
  }

  private async fetchTimeout(url: string, options: RequestInit): Promise<Response> {
    const ctrl = new AbortController()
    const t = setTimeout(() => ctrl.abort(), this.cfg.timeoutMs)
    try {
      return await fetch(url, {
        ...options,
        signal: ctrl.signal,
        headers: { ...options.headers, 'X-API-Key': this.cfg.apiKey }
      })
    } finally {
      clearTimeout(t)
    }
  }
}
```

---

## config.ts

```typescript
export interface Config {
  url: string                    // MEMORYMESH_URL
  apiKey: string                 // MEMORYMESH_API_KEY
  project: string                // MEMORYMESH_PROJECT
  teamProject?: string           // MEMORYMESH_TEAM_PROJECT
  projectRoot: string            // MEMORYMESH_PROJECT_ROOT (default cwd)
  manifestBudget: number         // MEMORYMESH_MANIFEST_BUDGET (default 3000)
  extractEveryN: number          // MEMORYMESH_EXTRACT_EVERY_N (default 5)
  timeoutMs: number              // MEMORYMESH_TIMEOUT_MS (default 3000)
  compressThresholdTokens: number// MEMORYMESH_COMPRESS_THRESHOLD (default 8000)
  maxObsTokens: number           // MEMORYMESH_MAX_OBS_TOKENS (default 200)
  bloomSyncTtlMs: number         // MEMORYMESH_BLOOM_TTL_MS (default 3600000)
  fingerprintTtlMs: number       // MEMORYMESH_FINGERPRINT_TTL_MS (default 300000)
  fingerprintMinConfidence: number  // MEMORYMESH_FP_MIN_CONF (default 0.6)
  deltaRefreshEnabled: boolean   // MEMORYMESH_DELTA_ENABLED (default true)
  rerankRequest: boolean         // MEMORYMESH_SEARCH_RERANK (default true)
  telemetryEnabled: boolean      // MEMORYMESH_TELEMETRY (default true)
  enabled: boolean               // MEMORYMESH_ENABLED (default true)
}

export function loadConfig(): Config {
  const url = process.env.MEMORYMESH_URL
  if (!url) throw new Error('MEMORYMESH_URL non configurato — esegui: npx memorymesh install')
  return {
    url: url.replace(/\/$/, ''),
    apiKey: process.env.MEMORYMESH_API_KEY ?? '',
    project: process.env.MEMORYMESH_PROJECT ?? 'default',
    teamProject: process.env.MEMORYMESH_TEAM_PROJECT,
    projectRoot: process.env.MEMORYMESH_PROJECT_ROOT ?? process.cwd(),
    manifestBudget: parseInt(process.env.MEMORYMESH_MANIFEST_BUDGET ?? '3000'),
    extractEveryN: parseInt(process.env.MEMORYMESH_EXTRACT_EVERY_N ?? '5'),
    timeoutMs: parseInt(process.env.MEMORYMESH_TIMEOUT_MS ?? '3000'),
    compressThresholdTokens: parseInt(process.env.MEMORYMESH_COMPRESS_THRESHOLD ?? '8000'),
    maxObsTokens: parseInt(process.env.MEMORYMESH_MAX_OBS_TOKENS ?? '200'),
    bloomSyncTtlMs: parseInt(process.env.MEMORYMESH_BLOOM_TTL_MS ?? '3600000'),
    fingerprintTtlMs: parseInt(process.env.MEMORYMESH_FINGERPRINT_TTL_MS ?? '300000'),
    fingerprintMinConfidence: parseFloat(process.env.MEMORYMESH_FP_MIN_CONF ?? '0.6'),
    deltaRefreshEnabled: process.env.MEMORYMESH_DELTA_ENABLED !== 'false',
    rerankRequest: process.env.MEMORYMESH_SEARCH_RERANK !== 'false',
    telemetryEnabled: process.env.MEMORYMESH_TELEMETRY !== 'false',
    enabled: process.env.MEMORYMESH_ENABLED !== 'false',
  }
}
```

---

## Claude Code Plugin Manifest

L'adapter Claude Code è distribuito come **plugin Claude Code nativo** tramite
marketplace. Cartella attesa: `plugin/packages/adapter-claude-code/.claude-plugin/`.

### `.claude-plugin/plugin.json`

```json
{
  "name": "memorymesh",
  "version": "1.0.0",
  "description": "Persistent shared memory for AI agents. Cache-aware, token-optimized.",
  "author": "Enrico Schintu <schintu.enrico@gmail.com>",
  "repository": "https://github.com/schengatto/memorymesh",
  "license": "MIT",

  "hooks": {
    "SessionStart":      "./hooks/session-start.js",
    "UserPromptSubmit":  "./hooks/user-prompt-submit.js",
    "PostToolUse":       "./hooks/post-tool-use.js",
    "Stop":              "./hooks/stop.js",
    "SessionEnd":        "./hooks/session-end.js"
  },

  "mcpServers": {
    "memorymesh": {
      "type": "http",
      "url": "${MEMORYMESH_URL}/mcp",
      "headers": { "X-API-Key": "${MEMORYMESH_API_KEY}" }
    }
  },

  "skills": ["./skills/vocab"],

  "commands": [
    "./commands/mm-search.md",
    "./commands/mm-vocab.md",
    "./commands/mm-stats.md",
    "./commands/mm-distill.md",
    "./commands/mm-compact.md",
    "./commands/mm-pair.md"
  ],

  "postInstall": {
    "script": "./scripts/post-install.js",
    "description": "Rileva server LAN via mDNS, guida pairing con PIN, detect progetto da git remote"
  },

  "requires": {
    "claudeCode": ">=1.0.0",
    "node": ">=18"
  }
}
```

`${MEMORYMESH_URL}` e `${MEMORYMESH_API_KEY}` sono risolti da Claude Code
dall'environment. L'installer post-install li scrive in `~/.memorymesh/device.json`
e aggiunge un loader nei hook per iniettare le env var al runtime.

### `.claude-plugin/marketplace.json` (nel repo marketplace dedicato)

Repo separato: `github.com/schengatto/memorymesh-marketplace`.

```json
{
  "name": "schengatto",
  "owner": { "name": "Enrico Schintu", "url": "https://github.com/schengatto" },
  "plugins": [
    {
      "name": "memorymesh",
      "source": "github:schengatto/memorymesh/plugin/packages/adapter-claude-code",
      "version": "1.0.0",
      "description": "Persistent shared memory — cache-aware, token-optimized, multi-agent",
      "keywords": ["memory", "context", "mcp", "cache", "token-optimization"]
    }
  ]
}
```

Install lato utente (2 comandi):

```
/plugin marketplace add github:schengatto/memorymesh-marketplace
/plugin install memorymesh
```

---

## Slash Commands Inclusi

File in `.claude-plugin/commands/`, uno per comando. Ogni file è Markdown con
front-matter opzionale.

### `/mm-search <query>`
File `mm-search.md`:
```markdown
---
description: Cerca nelle memorie MemoryMesh con hybrid search (BM25 + vector + rerank)
argument-hint: <query>
---
Usa mcp__memorymesh__search con q="$ARGUMENTS" limit=5 mode=hybrid.
Restituisci i risultati in formato compatto.
```

### `/mm-vocab [term]`
Dump del vocabolario corrente o lookup di un termine specifico.

### `/mm-stats`
Mostra statistiche token efficiency della sessione corrente (da telemetry).

### `/mm-distill`
Trigger manuale della distillazione (utile in dev/debug). Richiede admin.

### `/mm-compact`
Forza compressione history della sessione corrente.

### `/mm-pair`
Avvia il flow di pairing (utile se l'utente vuole ri-autenticare un device
esistente o aggiungerne uno nuovo senza reinstallare il plugin).

---

## Installazione Zero-Touch (post-install del plugin)

Il file `scripts/post-install.js` viene eseguito dal plugin loader di Claude Code
subito dopo `/plugin install memorymesh`. Flow:

```typescript
export async function postInstall(): Promise<void> {
  console.log('🧠 MemoryMesh — zero-touch setup')

  // 1. Se già esiste device.json valido → nulla da fare
  const existing = await loadDeviceConfig()
  if (existing && await testConnection(existing)) {
    console.log('✓ Già configurato. Server raggiungibile.')
    return
  }

  // 2. Scoperta server via mDNS (_memorymesh._tcp.local)
  console.log('🔎 Ricerca server MemoryMesh sulla LAN...')
  const discovered = await mDNSDiscover('_memorymesh._tcp.local', { timeout: 3000 })

  let serverUrl: string
  if (discovered.length === 1) {
    serverUrl = discovered[0].url
    console.log(`✓ Trovato: ${discovered[0].host} (${serverUrl})`)
  } else if (discovered.length > 1) {
    serverUrl = await promptChoice('Più server trovati, scegli:', discovered.map(d => d.url))
  } else {
    serverUrl = await prompt('URL server MemoryMesh (es. http://mm.local): ')
  }

  // 3. Verifica è davvero MemoryMesh
  const info = await fetch(`${serverUrl}/api/v1/mdns-info`, { headers: {} })
  if (!info.ok || (await info.json()).service !== 'memorymesh') {
    throw new Error('Il server non risponde come MemoryMesh.')
  }

  // 4. Richiesta PIN all'utente (ottenuto dall'admin UI)
  console.log(`\nApri ${serverUrl}/admin/ → Account → Devices → Pair new device`)
  console.log('Copia il PIN 6 cifre e incollalo qui sotto.\n')
  const pin = await prompt('PIN: ')
  const deviceName = await prompt(`Nome device [default: ${os.hostname()}]: `) || os.hostname()

  // 5. Pair con il server
  console.log('Pair in corso...')
  const pairRes = await fetch(`${serverUrl}/api/v1/pair`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      pin, device_name: deviceName,
      hostname: os.hostname(), os_info: `${os.platform()} ${os.release()} ${os.arch()}`,
      agent_kind: 'claude-code'
    })
  })
  if (!pairRes.ok) {
    const err = await pairRes.json()
    throw new Error(`Pair fallito: ${err.error}`)
  }
  const { api_key, user_id, project_hint } = await pairRes.json()

  // 6. Auto-detect progetto da git remote
  let project = project_hint
  try {
    const gitRemote = (await exec('git remote get-url origin')).trim()
    const slug = gitRemote.split('/').pop()?.replace(/\.git$/, '')
    if (slug) {
      const existing = await fetch(`${serverUrl}/api/v1/projects?slug=${slug}`,
        { headers: { 'X-API-Key': api_key } })
      if (existing.ok) {
        project = slug
        console.log(`✓ Progetto auto-rilevato da git remote: ${slug}`)
      } else {
        const create = await promptYN(`Progetto '${slug}' non esiste. Crearlo? [Y/n]`)
        if (create) {
          await fetch(`${serverUrl}/api/v1/projects`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-API-Key': api_key },
            body: JSON.stringify({ slug, git_remote: gitRemote })
          })
          project = slug
        }
      }
    }
  } catch { /* no git, usa default */ }
  if (!project) {
    project = await prompt('Nome progetto (default: basename cwd): ') || path.basename(process.cwd())
  }

  // 7. Scrivi device.json
  await fs.mkdir(path.join(os.homedir(), '.memorymesh'), { recursive: true })
  await fs.writeFile(
    path.join(os.homedir(), '.memorymesh', 'device.json'),
    JSON.stringify({ url: serverUrl, api_key, user_id, project, device_name: deviceName }, null, 2),
    { mode: 0o600 }
  )

  console.log(`\n✅ MemoryMesh configurato. Progetto: ${project}. Usa Claude Code normalmente.`)
}
```

**Tempo totale utente**: lettura PIN dall'admin UI + 2 prompt (PIN + nome device).
In media **~30 secondi**. Tutto il resto (URL server, project, API key) è
auto-derivato.

### Supply Chain Security

Il plugin è distribuito tramite marketplace Claude Code su GitHub. Il threat
model considera attacchi lungo tutta la catena:

**Release signing** (sigstore + GPG):
```yaml
# .github/workflows/release.yml
- name: Sign release with sigstore
  uses: sigstore/gh-action-sigstore-python@v2.1
  with:
    inputs: ./dist/*.tgz

- name: Sign git tag with GPG
  run: git tag -s v${{ inputs.version }} -m "Release v${{ inputs.version }}"
```

Ogni tag `v*` è firmato GPG dall'owner. GitHub mostra badge "Verified".
Ogni artefatto ha firma sigstore verificabile offline.

**Checksum pubblicati in marketplace.json:**
```json
{
  "plugins": [{
    "name": "memorymesh",
    "version": "1.0.0",
    "source": "github:schengatto/memorymesh#v1.0.0",
    "commit_sha": "abc123def456...",
    "checksum_sha256": "sha256:7a8b9c...",
    "sigstore_bundle": "https://github.com/schengatto/memorymesh/releases/download/v1.0.0/memorymesh-1.0.0.tgz.sigstore"
  }]
}
```

**Post-install verification** (`scripts/post-install.js`):
```typescript
import { createHash } from 'crypto'

async function verifyIntegrity(): Promise<void> {
  const manifest = await loadMarketplaceEntry()
  const pluginDir = await getPluginInstallPath()
  const archiveHash = await sha256File(path.join(pluginDir, '.archive.tgz'))
  if (archiveHash !== manifest.checksum_sha256) {
    throw new Error(
      `Checksum mismatch for memorymesh@${manifest.version}. ` +
      `Expected ${manifest.checksum_sha256}, got ${archiveHash}. ` +
      `Plugin may have been tampered with. Refusing to install.`
    )
  }
  // Bonus: verifica firma sigstore se cosign CLI disponibile
  if (await hasCommand('cosign')) {
    await execChecked(`cosign verify-blob --bundle ${manifest.sigstore_bundle} ...`)
  }
}
```

**SBOM** (Software Bill of Materials):
```bash
npx @cyclonedx/cyclonedx-npm --output-file sbom.cyclonedx.json
```
Pubblicata come release asset. Permette scan automatico di CVE sui pacchetti
embedded.

**Dependabot** + `npm audit --production` in CI: block merge su HIGH+/CRITICAL.

### API Key Storage

Tre tier di storage, selezione automatica al primo run:

```typescript
// plugin/packages/core/src/secret-store.ts
import keytar from 'keytar'   // OS keyring: libsecret | Keychain | Credential Manager

const SERVICE = 'com.memorymesh.device'

export class SecretStore {
  static async tryKeyring(): Promise<SecretStore | null> {
    try {
      await keytar.setPassword(SERVICE, 'test', 'x')
      await keytar.deletePassword(SERVICE, 'test')
      return new SecretStore('keyring')
    } catch {
      return null   // keyring non disponibile (server headless, WSL sine keyring, ecc.)
    }
  }

  static async init(): Promise<SecretStore> {
    return (await SecretStore.tryKeyring()) ?? new SecretStore('file')
  }

  async setApiKey(key: string): Promise<void> {
    if (this.mode === 'keyring') {
      await keytar.setPassword(SERVICE, 'api_key', key)
    } else {
      // Fallback file 0600 in ~/.memorymesh/device.json
      await saveDeviceConfig({ ...(await loadDeviceConfig()), api_key: key })
    }
  }

  async getApiKey(): Promise<string | null> {
    if (this.mode === 'keyring') {
      return await keytar.getPassword(SERVICE, 'api_key')
    }
    return (await loadDeviceConfig())?.api_key ?? null
  }
}
```

Preferenza: **keyring** (keytar). Fallback: file 0600 se keyring non disponibile
(es. dev container senza libsecret, server headless).

L'installer post-install pone la domanda: "Usare il keyring OS? (più sicuro) [Y/n]"
solo se keyring disponibile; altrimenti usa file direttamente con warning.

### API Key Rotation

Ogni device_key ha `created_at`. Dopo 90 giorni, le risposte del server
includono header `X-MemoryMesh-Rotate-Available: true`.

Il plugin al vedere questo header:

```typescript
// plugin/packages/core/src/client.ts
async function afterResponse(res: Response) {
  if (res.headers.get('X-MemoryMesh-Rotate-Available') === 'true') {
    // Fire & forget, non blocca la request corrente
    rotateApiKeyInBackground().catch(() => {})
  }
}

async function rotateApiKeyInBackground(): Promise<void> {
  const res = await apiClient.post('/api/v1/device/rotate-key', {})
  if (!res.ok) return
  const { new_api_key, grace_period_seconds } = await res.json()
  await SecretStore.get().setApiKey(new_api_key)
  logger.info('api_key_rotated', grace=grace_period_seconds)
  // La vecchia key resta valida 7 giorni (altri device di questo user
  // possono aver bisogno di tempo per aggiornarsi)
}
```

Se rotation fallisce: la vecchia key resta valida fino a 90gg + 7gg grace,
poi il server la invalida automatic → plugin riceve 401 → entra in pair mode.

### Installazione Manuale Alternativa (per CI, server headless)

```bash
# Pair senza marketplace, utile per automazione
MEMORYMESH_URL=http://mm.local \
MEMORYMESH_PAIR_PIN=123456 \
  npx @memorymesh/cli install --for claude-code --non-interactive --project my-app
```

Utile per:
- Provisioning via Ansible/script
- Dev container (il PIN è ephemeral, l'API key resta in container)
- CI (raramente, ma comodo per test E2E)

---

## Test E2E Richiesti (F7-11)

1. **Manifest differenziale:** due SessionStart consecutive → seconda usa cache (304)
2. **Vocab iniettato:** SessionStart include sezione vocabolario nel system prompt
3. **PostToolUse cattura:** Edit su file → observation appare in DB entro 5s
4. **Offline buffer:** server spento → 5 tool use → server acceso → SessionStart flush
5. **Nessun blocco:** server con delay 5s → tool use si completa entro 4s (timeout)
6. **Compressione:** sessione 25 turni → compressor attivato → summary_obs_id impostato
7. **Extract:** dopo N sessioni → POST /extract chiamato con ultimi messaggi
8. **Compatibilità MCP:** mcp__memorymesh__search, get_observations, timeline funzionano
9. **Skill vocab:** mcp__memorymesh__vocab_lookup, vocab_upsert funzionano
10. **Migrazione:** `npx memorymesh migrate --from ~/.claude-mem/memory.db` importa correttamente
11. **Prompt caching stabile:** 2a SessionStart → prefisso byte-per-byte identico
    (confronto hash). Se cambia: log dettagliato del diff.
12. **Scope routing:** cwd dentro `api/routers` → branch contiene SOLO obs con scope
    contenente `api`. cwd root → branch vuoto, solo root iniettato.
13. **Delta manifest:** durante sessione attiva, creazione nuova obs stesso scope →
    al prossimo UserPromptSubmit il delta viene iniettato in coda (non nel prefisso).
14. **Bloom filter vocab:** lookup di termine inesistente → 0 HTTP call (bloom filter
    dice `mightContain=false`).
15. **Tiktoken accuracy:** stima token per messaggio di 500 char deve essere entro ±10%
    del conteggio reale API.
16. **Observation capping:** PostToolUse con content 5KB → plugin tronca a ~180 token +
    marker `[capped]` prima di POST.
17. **Fingerprint prefetch:** SessionStart → entro 500ms batch_cache contiene predicted_ids.
18. **Telemetry flush:** SessionEnd invia POST `/metrics/session` con tutti i counter.
19. **Cache hit rate:** loop 10 sessioni identiche → `avg_hit_rate >= 0.7` in `/stats`.
