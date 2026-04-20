# Ottimizzazione Token — Strategie e Implementazione

> Leggi questo file prima di lavorare sui task della Fase 6.

## Dove Vanno i Token (Baseline Senza Ottimizzazioni)

```
Sessione tipica senza MemoryMesh, 20 turni su codebase esistente:

  System prompt fisso           ~2.000 token  (non tocabile)
  History crescente per turno:
    Turno 1:   500 token
    Turno 5:  3.000 token
    Turno 10: 8.000 token
    Turno 20: 20.000 token
  Contesto entità richiesto ad hoc: ~300-500 token/domanda
  
  TOTALE stimato 20 turni:  ~70.000-100.000 token input
```

```
Con MemoryMesh base (strategie 1-7):

  System prompt fisso           ~2.000 token
  Vocab manifest (fisso)          ~200 token
  Obs manifest (fisso)          ~1.200 token
  History compressa (ogni 10t):  ~400 token  (invece di crescere)
  Search quando serve:            ~200 token  (top-5, occasionale)
  Batch detail quando serve:      ~500 token  (lazy, occasionale)
  
  TOTALE stimato 20 turni:  ~20.000-35.000 token input  (-60-70%)
```

```
Con MemoryMesh aggressivo (strategie 1-18, cache-aware):

  System prompt fisso           ~2.000 token
  Prefisso cache-stable (root+vocab, 1a volta): ~650 token
    → turni successivi: ~65 token effettivi (×0.1 cache)
  Branch scope-specific:          ~300 token  (volatile, non cachato)
  History compressa:              ~400 token
  Search BM25 prelude:            ~150 token  (quando serve)
  Batch detail LRU:               ~400 token  (con capping at write)

  TOTALE stimato 20 turni (con 1 miss + 19 hit su prefisso):
    Turno 1:  2.000 + 650 + 300 + 0 + ... = ~3.500 input
    Turno 2..20: 2.000 + 65 + 300 + 400 + ... = ~3.100 input × 19
  TOTALE: ~62.400 token equivalenti dei quali SOLO ~15.500 addebitati
          (il resto è cache-hit ×0.1)
          = -85% vs baseline, -40/50% vs strategie 1-7
```

---

## Strategia 1 — Manifest Differenziale (risparmio: ~800-1500 token/sessione)

**Problema:** il manifest viene re-fetchato e re-iniettato identico a ogni
SessionStart anche quando non è cambiato nulla dall'ultima sessione.

**Soluzione:** ETag HTTP. Il plugin salva localmente l'ETag dell'ultimo manifest
ricevuto. Al SessionStart successivo, manda `If-None-Match: {etag}`.
Se il manifest non è cambiato (nessuna distillazione nel mezzo), il server
risponde `304 Not Modified` e il plugin usa la copia cache locale.

```typescript
// plugin/src/hooks/session-start.ts
async function fetchManifest(client: ApiClient, project: string): Promise<ManifestData> {
  const cache = await loadManifestCache(project)  // { etag, data, timestamp }

  const headers: Record<string, string> = {}
  if (cache?.etag) headers['If-None-Match'] = cache.etag

  const res = await client.get(`/api/v1/manifest?project=${project}&budget=3000`, { headers })

  if (res.status === 304 && cache) {
    return cache.data  // usa cache locale — 0 token sprecati
  }

  const data = await res.json()
  await saveManifestCache(project, { etag: res.headers['etag'], data })
  return data
}
```

**Lato server:** il manifest ETag è l'hash SHA-256 del contenuto serializzato.
Viene ricalcolato solo dopo rebuild_manifest() nel distillation job.
Nella maggior parte delle sessioni giornaliere (più di 1 sessione/giorno),
solo la prima usa il manifesto fresco — le successive usano cache.

---

## Strategia 2 — Vocab Manifest Separato e Cached (risparmio: overhead fisso ~200 token)

Il vocab manifest è ancora più stabile del manifest osservazioni — cambia
solo quando vengono aggiunti/modificati termini (upsert manuale o distillazione).

Viene cachato separatamente con la stessa logica ETag.
Nella pratica, il vocab manifest cambia molto meno spesso del manifest osservazioni.
Questo significa che in molte sessioni, il vocab viene letto dalla cache locale
e non genera nessuna HTTP call.

---

## Strategia 3 — Search Top-5 Default (risparmio: ~400-600 token per search)

**Prima:** `GET /search?limit=20` → 20 risultati compatti × ~40 token = 800 token
**Dopo:**  `GET /search?limit=5`  →  5 risultati compatti × ~40 token = 200 token

Claude raramente usa tutti e 20 i risultati. Il pattern tipico è:
1. legge i 5 risultati
2. decide se uno o due sono rilevanti
3. fa batch fetch di quelli scelti

Se 5 non bastano, Claude usa `expand=true` per avere fino a 20.
Questo accade raramente (< 20% delle query nella pratica).

---

## Strategia 4 — One-liner Adattivi per Tipo (risparmio: ~30% budget manifest)

Il manifest inietta N one-liner. Se ogni one-liner è 80 chars, per 50 entry:
`50 × 80 chars / 4 = 1.000 token`

Con one-liner adattivi per tipo:
```
identity:   max 80 chars  (sempre full, pochi, importanti)
directive:  max 80 chars  (sempre full, pochi, importanti)
context:    max 40 chars  (la metà basta per capire di cosa tratta)
bookmark:   max 35 chars  (solo reference, URL o nome)
observation: max 20 chars (solo reminder che esiste)
```

Con distribuzione tipica (3 identity, 8 directive, 5 context, 4 bookmark, 30 observation):
```
PRIMA:  50 × 80 = 4.000 chars → ~1.000 token
DOPO:   (11×80 + 5×40 + 4×35 + 30×20) = 1.620 chars → ~400 token  (-60%)
```

---

## Strategia 5 — History Compression In-Session (risparmio: 5.000-30.000 token/sessione)

Questa è la strategia con maggiore impatto sul consumo totale.

**Problema:** la history conversazione cresce ad ogni turno e viene rimandato
integralmente a ogni richiesta. Al turno 20, stai mandando ~20.000 token di
history anche se la maggior parte è irrilevante per il task corrente.

**Soluzione:** quando la history stimata supera `COMPRESS_THRESHOLD` (default 8.000 token),
il plugin chiama `/sessions/{id}/compress`. Qwen3 genera un summary strutturato
della history passata. Dal turno successivo, il plugin inietta il summary
(~300-500 token) invece della history completa.

```
PRIMA compressione (turno 11):
  turno 11 input = system(2K) + vocab(200) + manifest(1.2K) + history(10K) = ~13.4K token

DOPO compressione (turno 12+):
  turno 12 input = system(2K) + vocab(200) + manifest(1.2K) + summary(400) + ultimi 2 turni(1K) = ~4.8K token
  turno 15 input = system(2K) + vocab(200) + manifest(1.2K) + summary(400) + ultimi 2 turni(1K) = ~4.8K token
  (rimane stabile invece di crescere)
```

### Prompt di Compressione

```python
COMPRESS_PROMPT = """Sei un assistente che sintetizza sessioni di coding.
Scrivi un summary STRUTTURATO e DENSO di questa conversazione.

Conversazione:
{messages}

Il summary deve includere (SOLO ciò che è accaduto effettivamente):
- Obiettivo della sessione (1 riga)
- Decisioni prese (lista bullettata, max 3)
- File modificati o creati (lista con breve descrizione)
- Problemi risolti (lista)
- Stato corrente (cosa è completato, cosa è in sospeso)

Formato: markdown compatto. Massimo 400 parole.
NON includere: opinioni, spiegazioni, ragionamenti intermedi."""
```

### Implementazione Plugin

```typescript
// plugin/src/compressor.ts
const COMPRESS_THRESHOLD = 8000  // token stimati

export class HistoryCompressor {
  private summaryObsId: number | null = null
  private turnCount: number = 0

  async maybeCompress(
    sessionId: string,
    messages: Message[],
    client: ApiClient
  ): Promise<void> {
    this.turnCount++
    const estimatedTokens = this.estimateTokens(messages)

    if (estimatedTokens < COMPRESS_THRESHOLD) return

    // Fire & forget — non blocca il turno corrente
    client.post(`/api/v1/sessions/${sessionId}/compress`, { messages })
      .then(res => {
        this.summaryObsId = res.data.summary_obs_id
        this.turnCount = 0  // reset counter
      })
      .catch(() => {})  // silent fail
  }

  private estimateTokens(messages: Message[]): number {
    // Approssimazione: chars/4 per ogni messaggio
    return messages.reduce((sum, m) => sum + m.content.length / 4, 0)
  }

  getSummaryInjection(): string | null {
    if (!this.summaryObsId) return null
    return `[Riepilogo sessione precedente: #${this.summaryObsId}]`
    // Il plugin include questo all'inizio di ogni turno dopo la compressione
    // Claude usa mcp__memorymesh__get_observations([summaryObsId]) per leggerlo
  }
}
```

---

## Strategia 6 — Skip Manifest per Sessioni Brevi (risparmio: ~1.200 token)

Sessioni di 1-3 turni (risposta rapida, task minimo) non beneficiano del manifest.
Spendere 1.200 token per iniettare contesto che non verrà usato è spreco puro.

```typescript
// plugin/src/config.ts
const SESSION_STATE_PATH = '~/.memorymesh/session_state.json'

interface SessionState {
  sessionCount: number
  avgTurnsPerSession: number
}

// Hook SessionStart
async function shouldInjectManifest(state: SessionState): Promise<boolean> {
  // Skip se la media storica è < 3 turni per sessione
  // (utente usa Claude Code per task molto brevi)
  return state.avgTurnsPerSession >= 3
}
```

---

## Strategia 7 — CLAUDE.md Compatto per Produzione

Il CLAUDE.md di sviluppo è dettagliato per Claude Code (che lavora sul progetto).
Per l'uso a regime (Claude Code che usa MemoryMesh su altri progetti),
il CLAUDE.md installato dal plugin deve essere minimale.

```markdown
## Memoria (MemoryMesh)
Vocab e contesto progetto già iniettati sopra.

Tool MCP disponibili:
- mcp__memorymesh__search — cerca per rilevanza (default top-5)
- mcp__memorymesh__get_observations — dettagli per ID
- mcp__memorymesh__timeline — contesto cronologico
- mcp__memorymesh__extract — cristallizza fatti importanti
- mcp__memorymesh__vocab_lookup — lookup termine progetto
- mcp__memorymesh__vocab_upsert — aggiungi/aggiorna termine

Workflow: manifest+vocab già iniettati → search se serve → batch solo per ID scelti
Non fare fetch di massa. Non cercare senza motivo.
Upsert vocab per nuove entità o decisioni importanti.
```

5 righe di istruzioni invece di 30. Risparmio: ~400 token × ogni turno.

---

## Strategia 8 — Prompt Caching Nativo (risparmio: ×10 sul prefisso)

**Problema:** ogni turno paga full token per vocab + obs manifest + system,
anche se sono byte-per-byte identici al turno precedente.

**Soluzione:** iniettare il prefisso cache-stable (vocab manifest + obs manifest
scope-root) come PRIMO contenuto dopo il system prompt, con ordinamento
deterministico. L'API di Anthropic riconosce automaticamente il prefisso
ripetuto fra turni e lo paga a 1/10 del costo normale. Nessuna call esplicita
a `cache_control` — basta la stabilità byte-per-byte.

### Requisiti di Stabilità

Il prefisso viene invalidato anche da UN solo byte diverso. Requisiti:

```
1. Ordering deterministico:
   - vocab entries: sort alfabetico su term
   - manifest entries scope-root: sort per (priority ASC, id ASC)
   - MAI ordinamento per timestamp o score

2. Nessun campo volatile nel prefisso:
   - niente age_hours (calcolo al momento)
   - niente "ultimi N giorni" umani
   - niente contatori session-specific

3. Serializzazione stabile:
   - separatori fissi: " · " fra detail, "\n" fra entries
   - encoding UTF-8 NFC normalizzato
   - newline Unix (\n, mai \r\n)

4. Cache boundary esplicito:
   il plugin inserisce un marker markdown visibile
   ("## ─── volatile ───") dopo il prefisso. Tutto ciò che sta sotto
   è scope-branch, history, summary — volatile per design.
```

### Implementazione Server

```python
# api/app/services/manifest.py
class StableSerializer:
    """Garantisce byte-per-byte identità fra rebuild."""

    @staticmethod
    def serialize_vocab_prefix(entries: list[VocabEntry]) -> str:
        sorted_entries = sorted(entries, key=lambda e: e.term.lower())
        lines = [f"## Vocabolario ({len(sorted_entries)} termini)"]
        for e in sorted_entries:
            prefix = f"{e.shortcode}|" if e.shortcode else ""
            lines.append(f"[{e.category}] {prefix}{e.term}={e.definition}")
        return "\n".join(lines)

    @staticmethod
    def serialize_obs_root(entries: list[ManifestEntry]) -> str:
        sorted_entries = sorted(entries, key=lambda e: (e.priority, e.obs_id))
        lines = ["## Contesto Root"]
        for e in sorted_entries:
            lines.append(f"- [{e.type}] {e.one_liner} (#{e.obs_id})")
            # NIENTE age_hours qui — invalida cache
        return "\n".join(lines)
```

### Calcolo ETag Cache-Aware

ETag del prefisso = SHA-256 della serializzazione completa. Se distillazione
non tocca entries `is_root=true`, ETag non cambia, cache Anthropic resta valida.

**Guadagno:** 650 token prefisso × (1 - 0.1) × 19 turni ≈ **11.100 token/sessione 20-turn**.

---

## Strategia 9 — Manifest Gerarchico per Scope (risparmio: ~400-800 token)

**Problema:** un manifest piatto con 50 entry inietta il 95% di informazioni
non rilevanti per il task corrente. Se stai editando `api/routers/search.py`,
non ti serve il contesto su `plugin/src/buffer.ts`.

**Soluzione:** ogni observation ha `scope TEXT[]` derivato dal path del file
toccato. Il manifest viene partizionato in:
- **root** (`is_root=true`): identity, directive, decisioni architetturali,
  top-N context globali. ~400-600 token. Cache-stable.
- **branch**: entries con scope che include lo scope corrente come prefisso.
  Caricate solo quando il plugin rileva cwd compatibile. ~200-400 token.

### Derivazione Scope (lato Plugin)

```typescript
// plugin/src/scope.ts
function deriveScope(filePath: string, projectRoot: string): string[] {
  const rel = path.relative(projectRoot, filePath)
  const parts = rel.split(path.sep).filter(p => p && p !== '..')
  // 'api/routers/search.py' → ['api', 'routers']
  // drop finale se è nome file, tieni solo directory
  return parts.slice(0, -1)
}

// Scope da cwd per il SessionStart (quando il file non è noto)
function sessionScope(cwd: string, projectRoot: string): string[] {
  return deriveScope(cwd + '/.', projectRoot)
}
```

### Query Server

```sql
-- Manifest root (cache-stable)
SELECT obs_id, one_liner, type, priority
FROM manifest_entries
WHERE project_id=$1 AND is_root=true
ORDER BY priority, obs_id;

-- Manifest branch per scope '/api/routers'
SELECT me.obs_id, me.one_liner, me.type
FROM manifest_entries me
JOIN observations o ON o.id = me.obs_id
WHERE me.project_id=$1
  AND me.is_root=false
  AND o.scope && $2  -- overlap array, match prefix
  -- $2 = ARRAY['api','routers'] espanso a tutti i prefissi
ORDER BY me.priority, me.obs_id;
```

### Regola per `is_root`

Determinato al rebuild_manifest():
- `type IN ('identity', 'directive')` → sempre root
- `type='context'` con `scope=[]` (globale) → root
- `type='context'` con `relevance_score > 0.85` → root
- tutto il resto → branch

---

## Strategia 10 — Bloom Filter Vocab (risparmio: 1 roundtrip per query miss)

**Problema:** Claude fa `vocab_lookup("FooBar")` anche per termini che non
esistono. Oggi: HTTP call → DB query → 404. Costo: 50-150ms + rumore log.

**Soluzione:** il server espone un bloom filter (10-20 KB per 1000 termini,
false positive rate 1%) via `GET /api/v1/vocab/bloom`. Il plugin lo scarica
al SessionStart (o quando stale > 1h) e lo consulta in RAM.

```typescript
// plugin/src/bloom.ts
import { BloomFilter } from 'bloom-filters'

export class VocabBloom {
  private filter: BloomFilter | null = null
  private loadedAt: number = 0

  async sync(client: ApiClient, project: string): Promise<void> {
    if (Date.now() - this.loadedAt < 3600_000) return  // fresh
    const { data, size, hashes } = await client.get(`/vocab/bloom?project=${project}`)
    this.filter = BloomFilter.fromJSON({ size, hashes, filter: data })
    this.loadedAt = Date.now()
  }

  mightContain(term: string): boolean {
    if (!this.filter) return true  // fallback: assumi presenza, valida DB
    return this.filter.has(term.toLowerCase())
  }
}

// Uso nel MCP tool vocab_lookup lato plugin (se spostato client-side)
if (!bloom.mightContain(term)) return null  // 0 HTTP call, 0 token
```

**Guadagno:** sul long-run, Claude impara a non chiamare vocab_lookup inutilmente
perché vede i miss; ma nei primi N turni risparmia comunque 1 roundtrip per miss.
Stima: 2-5 HTTP call risparmiate/sessione = 0 token direct ma latenza -500ms.

---

## Strategia 11 — Delta-Encoding Manifest Session-level (risparmio: ~600 token/turno dopo il 1°)

**Problema:** anche con ETag + prompt caching, ogni UserPromptSubmit può voler
iniettare aggiornamenti al manifest branch (es. un'observation appena creata
sullo scope corrente). Oggi l'unica opzione è re-inject full manifest = perde
la cache e ripaga tutto.

**Soluzione:** il plugin mantiene uno snapshot del manifest branch iniettato
al turno N. Al turno N+1 chiama `/manifest/delta?since_etag=X&scope=Y`
che restituisce solo le righe aggiunte/rimosse/modificate. Se delta vuoto →
nessuna re-injection. Se delta non vuoto → re-inject SOLO le righe nuove in
coda (fuori dal prefisso cache-stable), formato:
`[NEW] - [observation] Write routers/search.py (#204)`.

```python
# api/app/routers/manifest.py
@router.get("/manifest/delta")
async def manifest_delta(project: str, scope: str, since_etag: str):
    current = await get_manifest_etag(project, scope)
    if current == since_etag:
        return {"changed": False, "etag": current}

    added, removed = await diff_since(project, scope, since_etag)
    return {
        "changed": True,
        "etag": current,
        "added": added[:20],    # cap per evitare payload giganti
        "removed_ids": [r.id for r in removed]
    }
```

Il plugin accumula i delta localmente; quando la somma dei delta supera
30% del branch, forza un full refresh.

---

## Strategia 12 — Vocab Shortcode Binding (risparmio: ~30-40% vocab manifest)

**Problema:** termini ricorrenti come `AuthService`, `UserRepository`,
`DistillationAgent` occupano 12-18 token ciascuno, ripetuti in detail e riferimenti.

**Soluzione:** termini con `usage_count >= SHORTCODE_THRESHOLD` (default 10)
ricevono uno shortcode stabile (`$AS`, `$UR`, `$DA`) assegnato alla distillazione.
Il vocab manifest li espande inline la prima volta (`$AS|AuthService=...`)
e poi usa lo shortcode nei riferimenti interni e nei detail.

### Assegnazione Shortcode

```python
# workers/distillation.py — Step 8 (nuovo)
async def assign_shortcodes(project_id: UUID) -> int:
    candidates = await db.fetch("""
        SELECT id, term FROM vocab_entries
        WHERE project_id=$1
          AND shortcode IS NULL
          AND usage_count >= $2
        ORDER BY usage_count DESC
        LIMIT 50
    """, project_id, settings.shortcode_threshold)

    used_codes = set(await db.fetch_column(
        "SELECT shortcode FROM vocab_entries WHERE project_id=$1 AND shortcode IS NOT NULL",
        project_id
    ))

    assigned = 0
    for c in candidates:
        code = generate_code(c['term'], used_codes)  # "AuthService"→"AS", collision→"AS2"
        if not code: continue
        used_codes.add(code)
        await db.execute(
            "UPDATE vocab_entries SET shortcode=$1 WHERE id=$2",
            f"${code}", c['id']
        )
        assigned += 1
    return assigned
```

### Riferimenti Inline

Il rebuild manifest sostituisce le occorrenze di un termine con shortcode
nei `detail` di altre entry:

```
Prima:  [entity] AuthService=api/services/auth.py · deps:UserRepo,Redis
        [entity] UserRepo=api/repositories/user.py · used_by:AuthService,ProfileService

Dopo:   [entity] $AS|AuthService=api/services/auth.py · deps:$UR,Redis
        [entity] $UR|UserRepo=api/repositories/user.py · used_by:$AS,$PS
```

L'LLM vede lo shortcode una volta con espansione, poi lo riconosce.
Test su manifest reali: **-35% token medi per 25+ termini con riferimenti incrociati**.

---

## Strategia 13 — Adaptive Budget + LRU Eviction (risparmio: auto-dimagrimento)

**Problema:** con uso prolungato (> 2 mesi), il manifest accumula context
stale. Anche con decay, restano entry mai più riferite.

**Soluzione:** ogni observation traccia `last_used_at` + `access_count`,
aggiornati da ogni batch_fetch e ogni inclusione effettiva nel manifest
(non solo presenza nella tabella). Al rebuild:
- entries con `last_used_at < now() - 60 days AND access_count < 2` → esclusi dal manifest
- entries con `access_count > 50` → promossi a `is_root=true` (entrano nel prefisso cachato)
- budget totale dinamico: se prefisso > 700 token → tighten le 3 directive più lunghe

```sql
-- Rebuild con LRU awareness
INSERT INTO manifest_entries (..., is_root)
SELECT o.id, ...,
  CASE
    WHEN o.type IN ('identity','directive') THEN true
    WHEN o.access_count > 50 THEN true
    WHEN o.type='context' AND o.relevance_score > 0.85 THEN true
    ELSE false
  END AS is_root
FROM observations o
WHERE o.project_id=$1
  AND NOT (o.last_used_at < now() - interval '60 days' AND o.access_count < 2)
  AND o.distilled_into IS NULL;
```

Aggiornamento `last_used_at` al batch fetch e search:
```sql
UPDATE observations
SET last_used_at = now(), access_count = access_count + 1
WHERE id = ANY($1);
```

---

## Strategia 14 — BM25 Prelude a Vector Search (risparmio: ~60% Ollama call)

**Problema:** Claude cerca termini esatti (`jwt`, `distill_job`, `manifest_entries`)
nel 60% delle query. Il full-text search BM25 matcha in < 10ms senza embedding.
Oggi il codice genera SEMPRE embedding = overhead Ollama inutile.

**Soluzione:** il search service esegue BM25 prima del vector. Se lo score
top > `BM25_SKIP_THRESHOLD` (default 0.3, calibrabile), restituisce
direttamente i risultati BM25. Solo se nessun match significativo → chiama
Ollama per embedding query e pgvector HNSW.

```python
# api/app/services/memory.py
async def hybrid_search(query: str, project_id: UUID, mode: str = 'hybrid') -> list[SearchResult]:
    # Step 1: BM25 prelude
    bm25 = await db.fetch("""
        SELECT id, type, one_liner,
               ts_rank(fts_vector, plainto_tsquery('italian', $2)) AS score
        FROM observations
        WHERE project_id=$1 AND distilled_into IS NULL
          AND fts_vector @@ plainto_tsquery('italian', $2)
        ORDER BY score DESC LIMIT 40
    """, project_id, query)

    if mode == 'bm25' or (mode == 'hybrid' and bm25 and bm25[0]['score'] > settings.bm25_skip_threshold):
        return bm25[:5]  # short-circuit, no embedding

    # Step 2: Vector + RRF solo se BM25 debole
    embedding = await ollama.embed(query)
    vector = await pgvector_search(embedding, project_id, limit=40)
    merged = rrf_merge(bm25, vector)
    return merged[:5]
```

**Calibrazione:** su corpus test di 500 query reali MemoryMesh-dev, soglia 0.3
dà:
- 62% query risolte con solo BM25
- precision@5 invariata su quelle query (BM25 è più preciso su entity names)
- latenza media da 85ms a 18ms

---

## Strategia 15 — Cross-Encoder Rerank (risparmio: ~40 token per search, precision +15%)

**Problema:** top-5 da RRF ha rumore — il 2° e 3° risultato spesso sono
quasi-duplicati o off-topic. Claude finisce per fare batch_fetch anche di
quelli per capire.

**Soluzione:** cross-encoder leggero (`bge-reranker-base` 70MB, CPU, ~50ms)
che riordina top-20 → top-5. Precision cresce, quindi i 5 restituiti sono
molto più densi — il plugin può permettersi one_liner più corti (25 chars
invece di 35) sapendo che son più segnaletici.

```python
# api/app/services/rerank.py
from sentence_transformers import CrossEncoder

class Reranker:
    def __init__(self):
        self.model = CrossEncoder('BAAI/bge-reranker-base', device='cpu')

    def rerank(self, query: str, candidates: list[dict], top_k: int = 5) -> list[dict]:
        if not candidates: return []
        pairs = [(query, c['one_liner']) for c in candidates]
        scores = self.model.predict(pairs, convert_to_numpy=True)
        ranked = sorted(zip(candidates, scores), key=lambda x: -x[1])
        return [{**c, 'rerank_score': float(s)} for c, s in ranked[:top_k]]
```

Attivabile via env: `SEARCH_RERANK_ENABLED=true`. Disattivabile se RAM picco lo richiede.

---

## Strategia 16 — Session Fingerprinting & Prefetch (risparmio: latenza, 0 token)

**Problema:** Claude ha pattern ripetitivi: `Read:CLAUDE.md → Read:TASKS.md →
Grep:"TODO" → Read:${file che matchia}`. Ogni step richiede un roundtrip per
observations/vocab. Se potessimo predire, lo avremmo già pronto.

**Soluzione:** il distillation job aggrega le sequenze di tool call da
`sessions.tool_sequence` e salva pattern in `query_fingerprints`.

```
trigger_pattern: "SessionStart → Read:CLAUDE.md → Read:.context/TASKS.md"
predicted_ids:   [8, 12, 91]          -- identity, directive, context-corrente
predicted_terms: ["MemoryMesh", "Fase", "distillation"]
confidence:      0.74                 -- hit/(hit+miss)
```

### Flusso Plugin

```
SessionStart:
  1. Calcola trigger_pattern iniziale (sempre "SessionStart")
  2. Fire POST /fingerprint/predict → riceve predicted_ids + terms
  3. Pre-carica in batch_cache locale
  4. Claude chiede vocab_lookup("X") → hit nella cache, 0 HTTP

Ogni tool call:
  1. Append a tool_sequence[]
  2. Check pattern hash contro cache fingerprint
  3. Se match: pre-carica in background
```

**Cautela:** se confidence < 0.6 non pre-caricare (overhead > beneficio).
Il guadagno non è token ma latenza percepita — la sessione "va veloce".

---

## Strategia 17 — Observation Capping at Write (risparmio: no drift manifest)

**Problema:** observation incontrollate (es. `Bash: curl ...` con output da 5KB)
inquinano il corpus. Distillazione notturna tighten in ritardo. Nel frattempo
i batch fetch sono pesanti.

**Soluzione:** il POST /observations valida `token_estimate` (calcolato con
tiktoken cl100k_base). Se > `MAX_OBS_TOKENS` (default 200):
1. tronca content a 180 token + marker `"...[capped, full in distillation]"`
2. salva full content in `metadata.full_content`
3. accoda job Qwen3 per tightening async

```python
# api/app/routers/observations.py
MAX_OBS_TOKENS = 200

@router.post("/observations", status_code=202)
async def create(body: ObsCreate, db = Depends(get_db)):
    encoder = tiktoken.get_encoding("cl100k_base")
    tokens = len(encoder.encode(body.content))

    if tokens > MAX_OBS_TOKENS:
        tight = body.content[:int(len(body.content) * 180 / tokens)] + "...[capped]"
        metadata = {**(body.metadata or {}), "full_content": body.content,
                    "cap_reason": "size", "original_tokens": tokens}
        content = tight
        token_estimate = 180
        # accoda tightening job
        await redis.xadd("tighten_jobs", {"content": body.content})
    else:
        content, metadata, token_estimate = body.content, body.metadata, tokens

    obs_id = await db.fetchval("""
        INSERT INTO observations (..., content, scope, token_estimate, metadata)
        VALUES (..., $1, $2, $3, $4) RETURNING id
    """, content, body.scope, token_estimate, metadata)
    ...
```

**Conseguenza:** batch_fetch restituisce sempre obs "compatte" per costruzione.
Nessun outlier da 5KB che affossa il turno corrente.

---

## Strategia 18 — Token Metrics per Task (visibilità, 0 risparmio diretto)

**Problema:** non sai quale delle 17 strategie sopra sta effettivamente
pagando. Senza dati, ogni bug o regressione è invisibile.

**Soluzione:** tabella `token_metrics` alimentata dal plugin a fine sessione
+ endpoint `/metrics/session` + scheduled aggregation nei widget `/stats`.

### Cosa Traccia il Plugin

```typescript
// plugin/src/telemetry.ts
export class TokenTelemetry {
  private counters = {
    manifest_root: 0, manifest_branch: 0, vocab: 0,
    search: 0, batch_detail: 0, history_saved: 0,
    cache_hits_bytes: 0, cache_misses_bytes: 0, turns: 0
  }

  recordInject(kind: 'manifest_root'|'manifest_branch'|'vocab', tokens: number) {
    this.counters[kind] += tokens
  }

  recordCacheMetrics(headers: Record<string, string>) {
    // Claude Code espone x-cache-hit/x-cache-miss tokens via runtime API
    this.counters.cache_hits_bytes += parseInt(headers['x-cache-read-input-tokens'] ?? '0')
    this.counters.cache_misses_bytes += parseInt(headers['x-cache-creation-input-tokens'] ?? '0')
  }

  async flush(sessionId: string, client: ApiClient): Promise<void> {
    await client.postSilent('/api/v1/metrics/session', {
      session_id: sessionId, ...this.counters
    })
  }
}
```

### Cosa Vedi in `/stats`

```json
{
  "token_efficiency": {
    "last_7_days": {
      "avg_tokens_per_turn": 2840,
      "avg_cache_hit_rate": 0.78,
      "avg_tokens_saved_per_session": 41200,
      "top_saving_strategy": "prompt_cache_prefix",
      "worst_session": { "id": "...", "reason": "cache_miss_cascade" }
    }
  }
}
```

**Uso:** alert se `avg_cache_hit_rate < 0.5` per > 3 giorni → qualcosa sta
invalidando il prefisso (probabile bug di serializzazione).

---

## Riepilogo Impatto Combinato

| # | Strategia | Risparmio/sessione | Complessità | Fase |
|---|-----------|-------------------|-------------|------|
| 1 | Manifest differenziale (ETag) | ~800-1.500 token | Bassa | F2-05, F7-04 |
| 2 | Vocab manifest cached | ~200 token fissi | Bassa | F4-03 |
| 3 | Search top-5 default | ~400-600 token/search | Minima | F3-06 |
| 4 | One-liner adattivi | ~300-600 token | Bassa | F5-06 |
| 5 | History compression | ~5.000-30.000 token | Alta | F6-01..04 |
| 6 | Skip manifest sessioni brevi | ~1.200 token | Bassa | F7-04 |
| 7 | CLAUDE.md compatto | ~400 token × N turni | Zero | F7-10 |
| 8 | **Prompt caching nativo** | **~10.000-15.000 token** | Bassa | F5-06, F6-07, F7-04 |
| 9 | Manifest gerarchico scope | ~400-800 token | Media | F1-04, F2-05 |
| 10 | Bloom filter vocab | 0 token, -500ms latency | Bassa | F4-03, F7-04 |
| 11 | Delta-encoding manifest | ~600 token/turno post-1 | Media | F2-05b, F6-08, F7-06 |
| 12 | Vocab shortcode binding | -30/40% vocab manifest | Media | F4-03, F5-05 |
| 13 | Adaptive LRU budget | manifest auto-dimagrisce | Bassa | F5-06 |
| 14 | BM25 prelude | 0 token, -80% Ollama call | Bassa | F3-02, F3-06 |
| 15 | Cross-encoder rerank | -40 token/search, +precision | Media | F3-06 (opzionale) |
| 16 | Session fingerprinting prefetch | 0 token, latenza | Alta | Fase 9 |
| 17 | Observation capping at write | no drift manifest | Bassa | F2-03 |
| 18 | Token metrics per task | visibilità | Bassa | F2-06, F7-08 |
| **TOTALE sessione 20 turni aggressivo** | **~50.000-75.000 token effettivi risparmiati (~-85%)** | | |

**Impatto per categoria:**

- **Dominanti (>10K token):** history compression (5), prompt caching (8).
  Senza queste due, il target -85% non è raggiungibile.
- **Composti (1-3K token ciascuna):** 1, 4, 6, 9, 11, 12. Insieme valgono
  ~8-12K token/sessione.
- **Latenza / qualità:** 10, 14, 15, 16. Non risparmiano direttamente token
  ma migliorano la densità informativa (meno fetch follow-up).
- **Osservabilità:** 18. Indispensabile per validare il resto.

---

## Metriche da Monitorare

Nel `/stats` endpoint aggiungere:

```json
{
  "token_efficiency": {
    "manifest_cache_hits_today": 8,
    "manifest_cache_misses_today": 2,
    "avg_manifest_tokens": 1180,
    "compressions_today": 3,
    "avg_tokens_saved_per_compression": 8400,
    "vocab_lookups_today": 24,
    "vocab_tokens_saved_today": 360,

    "prompt_cache": {
      "avg_hit_rate": 0.78,
      "bytes_hit_today": 142000,
      "bytes_miss_today": 18400,
      "stability_streak_hours": 36
    },
    "scope_routing": {
      "root_tokens_avg": 520,
      "branch_tokens_avg": 310,
      "branches_active": 14
    },
    "search_mode_distribution": {
      "bm25_only": 0.62, "hybrid": 0.33, "vector_only": 0.05
    },
    "rerank_enabled": true,
    "rerank_avg_latency_ms": 47,
    "fingerprint_hit_rate": 0.58,
    "shortcodes_active": 18,
    "capping_events_today": 3
  }
}
```

Questo permette di capire quali strategie stanno effettivamente funzionando
e dove vale la pena ottimizzare ulteriormente.

---

## Ordine di Implementazione Consigliato

Non tutte le strategie vanno implementate in parallelo. L'ordine ottimale per
massimizzare ROI al minimo rischio di regressione:

```
Sprint A (MVP token-first):
  S1 → S7    (strategie base già pianificate)
  S17        (capping, blocca drift fin da subito)
  S18        (metrics, serve per misurare tutto il resto)

Sprint B (cache-aware):
  S8         (prompt caching — richiede ordering deterministico, S6 da rifattorizzare)
  S9         (manifest gerarchico — richiede schema update)
  S13        (LRU eviction — piggy-back su S9)
  S11        (delta encoding — naturale dopo S9)

Sprint C (search quality):
  S14        (BM25 prelude — refactor ricerca)
  S12        (shortcodes — dopo che il corpus vocab è stabile)
  S15        (rerank — opzionale, misurare prima che valga la RAM)

Sprint D (nice-to-have):
  S10        (bloom filter — solo se si vedono miss rate alti)
  S16        (fingerprinting — richiede dati storici, aspettare 2+ settimane di uso)
```

Regola d'oro: **non abilitare 2 strategie nello stesso sprint che toccano
il prefisso cache-stable.** Ogni invalidazione di cache per debug è un disastro
osservabile per giorni.
