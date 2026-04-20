# Vocabolario Progetto — Specifica Completa

> Leggi questo file prima di lavorare sui task F4-01..F4-06.

## Cos'è il Vocabolario e Perché Esiste

Il vocabolario è un dizionario di termini specifici del progetto corrente.
Risolve un problema di token nascosto: Claude deve re-inferire il significato
di ogni entità (file, pattern, convenzione, decisione) a ogni sessione perché
non c'è un modo compresso per comunicarlo.

```
SENZA vocabolario — query "modifica AuthService":
  Claude deve capire da zero:
    - cos'è AuthService? dove sta?
    - quale pattern usa? quali dipendenze?
    - dove sono i test?
  Richiede: contesto esplicito nella domanda (~300-500 token extra)
  oppure: Claude sbaglia o chiede

CON vocabolario — query "modifica AuthService":
  Claude fa vocab_lookup("AuthService") → 15 token di risposta:
    entity: api/services/auth.py · JWT RS256 · deps:UserRepo,Redis · test:test_auth.py
  Nessun contesto extra necessario nella domanda
```

---

## Struttura di una Entry Vocab

```
term:        "AuthService"              ← chiave di lookup
shortcode:   "$AS"                       ← assegnato quando usage_count >= 10 (Strategia 12)
category:    "entity"                   ← tipo (vedi categorie sotto)
definition:  "Gestisce autenticazione JWT RS256"  ← max 80 chars
detail:      "api/services/auth.py · deps:$UR,RedisCache · test:tests/test_auth.py"
metadata:    { "path": "api/services/auth.py", "deps": ["UserRepo", "RedisCache"] }
source:      "manual"                   ← 'manual' | 'auto'
confidence:  1.0                        ← manual=1.0, auto=0.7
usage_count: 12                         ← incrementato da ogni lookup
```

Nota: i `detail` possono contenere shortcode di altri termini (es. `$UR` per UserRepo)
quando il distillatore rileva riferimenti incrociati. L'LLM li interpreta grazie al
mapping esplicito nel vocab manifest.

## Categorie

| Categoria | Cos'è | Esempio |
|-----------|--------|---------|
| `entity` | File, classe, service, modulo specifico del progetto | `AuthService`, `UserRepo`, `embed_jobs` |
| `convention` | Regola di naming, pattern, standard adottato | `test_*`, `*_worker.py`, `mm_` prefix |
| `decision` | Scelta architetturale con motivazione | `pgvector>qdrant`, `nomic>openai-embed` |
| `abbreviation` | Acronimo o abbreviazione usata nel progetto | `obs`, `dist`, `RRF`, `DLQ` |
| `pattern` | Pattern di design adottato con riferimento | `Repository`, `CQRS`, `Outbox` |

---

## Vocab Manifest — Formato Ultra-Compatto con Shortcode

Il manifest del vocabolario viene iniettato in SessionStart come parte del
**prefisso cache-stable** (Strategia 8). Il formato è progettato per massima
densità informativa per token consumato E per stabilità byte-per-byte fra
sessioni (essenziale per il prompt caching).

```
## Vocabolario (28 termini, 18 con shortcode)
[entity] $AS|AuthService=api/services/auth.py·JWT·deps:$UR,Redis
[entity] $DA|DistillationAgent=workers/distillation.py·CRON 03:00·Qwen3:8b
[entity] $EW|EmbeddingWorker=workers/embedding.py·consume $EJ·nomic-embed
[entity] $EJ|embed_jobs=Redis Stream·payload:{obs_id}·consumer:$EW
[entity] $UR|UserRepo=api/repositories/user.py·Repository·used_by:$AS
[conv]   mm_prod_*=formato API key, header X-API-Key
[conv]   test_*=pytest+testcontainers, mai mock DB
[conv]   *_worker.py=processo standalone, consumer Redis Stream
[dec]    nomic-embed — 768-dim, Apache 2.0, swap text-embedding-3-small se no Ollama
[dec]    pgvector>qdrant — semplicità stack, riconsiderare >500K obs
[abbr]   DLQ=dead-letter queue · vocab=vocabolario progetto
[abbr]   obs=observation · dist=distillation · RRF=Reciprocal Rank Fusion
[pattern] Repository=astrae accesso DB, in api/repositories/
```

Costo totale: ~145 token per 28 termini (18 con shortcode) — **-30% vs senza shortcode**.

**Sort: term ASC (case-insensitive).** Deterministico, indipendente da usage_count
o timestamp: requisito per cache-stability.

Il cambio di ordering rispetto al design originale (confidence DESC, usage_count DESC)
è deliberato: il prompt caching paga 10% token per prefix hit, ma invalida al
minimo cambio. Un reordering per usage_count invaliderebbe la cache quasi ogni
sessione. L'ordering alfabetico è stabile per definizione.

---

## Shortcode Binding (Strategia 12)

### Cos'è

Ogni termine con `usage_count >= SHORTCODE_THRESHOLD` (default 10) riceve
uno **shortcode univoco nel progetto**: 2-4 caratteri preceduti da `$`.
Esempi: `$AS` (AuthService), `$UR` (UserRepo), `$DA` (DistillationAgent).

Nel vocab manifest, il termine appare una volta con espansione inline:
`$AS|AuthService=...`. Nei `detail` di altre entry il termine è sostituito
dal suo shortcode: `deps:$UR` invece di `deps:UserRepo`.

### Algoritmo di Generazione

```python
def generate_code(term: str, used: set[str]) -> str | None:
    """Genera shortcode deterministico e collision-free."""
    # Fase 1: iniziali da PascalCase o snake_case
    # "AuthService" → "AS", "user_repo" → "UR", "DLQ" → "DLQ"
    parts = re.findall(r'[A-Z]+[a-z]*|[a-z]+', term)
    if not parts: return None
    base = ''.join(p[0].upper() for p in parts)

    # Fase 2: collision resolution
    if f"${base}" not in used: return base
    # Retry con 2 lettere da ogni parte
    if len(parts) >= 2:
        alt = parts[0][:2].upper() + parts[1][:1].upper()
        if f"${alt}" not in used: return alt
    # Suffisso numerico
    for i in range(2, 10):
        numbered = f"{base}{i}"
        if f"${numbered}" not in used: return numbered
    return None  # skip — troppe collisioni
```

### Quando Viene Assegnato

Solo durante la distillazione notturna (Step 8 — SHORTCODE ASSIGN).
Non viene mai assegnato al volo: la stabilità è più importante della
reattività. Termini nuovi entrano nel manifest senza shortcode fino al
prossimo passaggio del distillatore.

### Retrocompatibilità LLM

L'LLM capisce lo shortcode grazie all'espansione inline nel vocab manifest:
vedendo `$AS|AuthService=...` una volta, riconosce `$AS` nelle occorrenze
successive. Non serve training o fine-tuning.

Test empirico: Claude Sonnet 4.6 risponde correttamente a richieste su `$AS`
senza esplicita espansione quando il mapping è presente nel manifest.

### Threshold e Riassegnazione

- `SHORTCODE_THRESHOLD` default 10. Sotto questa soglia: termine scritto full.
- Se un termine sale/scende sopra/sotto la soglia, **lo shortcode non viene mai
  revocato**. Questo mantiene la stabilità del prefisso.
- Shortcode orfani (term eliminato) vengono rimossi al prossimo rebuild manifest.

### Calcolo Risparmio Tipico

Dataset osservato su `memorymesh-dev` dopo 3 settimane di uso:
- 28 termini, 18 con shortcode
- detail medio contiene 1.4 riferimenti incrociati
- senza shortcode: 145 token → 215 token (+48%)
- con shortcode: 145 token (baseline)

Dominante: i riferimenti incrociati nei detail. Un termine come `UserRepo`
referenziato in 4 altre entry passa da `4 × 10 token = 40 token` a
`4 × 3 token = 12 token`.

---

## Lookup Cascade

Quando Claude chiama `vocab_lookup(term)`, il sistema cerca in tre modi:

```python
async def lookup(project_id: UUID, term: str) -> VocabEntry | None:

    # 1. Match esatto (O(1) da index)
    result = await db.fetchrow(
        "SELECT * FROM vocab_entries WHERE project_id=$1 AND LOWER(term)=LOWER($2)",
        project_id, term
    )
    if result:
        await increment_usage(result['id'])
        return VocabEntry(**result)

    # 2. Fuzzy match (rapidfuzz, soglia 80)
    candidates = await db.fetch(
        "SELECT * FROM vocab_entries WHERE project_id=$1", project_id
    )
    best = max(candidates, key=lambda r: fuzz.ratio(term.lower(), r['term'].lower()),
               default=None)
    if best and fuzz.ratio(term.lower(), best['term'].lower()) >= 80:
        await increment_usage(best['id'])
        return VocabEntry(**best)

    # 3. Ricerca semantica (pgvector, se embedding disponibile)
    # Solo per termini con embedding pre-calcolato (colonna opzionale)
    # Threshold: cosine_similarity > 0.85
    # (implementare in F4-02 se si vuole, altrimenti solo 1+2)

    return None
```

---

## Auto-Extraction nel Distillation Job

Qwen3 analizza le observation degli ultimi 2 giorni ed estrae automaticamente
termini tecnici specifici del progetto.

```python
VOCAB_EXTRACT_PROMPT = """Analizza queste osservazioni di un progetto software
ed estrai termini tecnici SPECIFICI di questo progetto che meritano una entry
nel vocabolario.

Osservazioni (ultime 48h):
{observations_text}

Estrai SOLO termini che sono:
- nomi di file, classi, service, moduli specifici del progetto (NON librerie standard)
- convenzioni di naming adottate esplicitamente nel progetto
- decisioni architetturali con motivazione
- abbreviazioni usate ripetutamente nelle osservazioni

NON estrarre:
- termini di librerie/framework standard (FastAPI, Redis, PostgreSQL, ecc.)
- termini generici (test, service, worker senza specificità)
- qualcosa già ovviamente nel vocabolario standard Python/TS

Rispondi SOLO con JSON array (anche vuoto []):
[{
  "term": "NomeTermine",
  "category": "entity|convention|decision|abbreviation|pattern",
  "definition": "descrizione specifica max 80 chars",
  "detail": "info aggiuntiva opzionale (path, deps, ecc.)",
  "confidence": 0.7
}]

Massimo 10 termini per run."""
```

**Regole auto-extraction:**
- `source = 'auto'`, `confidence = 0.7`
- Non sovrascrive mai entry `source = 'manual'`
- Se un termine auto esiste già con confidence < soglia, aggiorna solo `definition`
- Termini estratti automaticamente non appaiono nel manifest se `confidence < 0.5`

---

## La Skill Lato Claude Code

Il file skill viene installato in `~/.claude/memorymesh-vocab.md` e incluso
nel system prompt da Claude Code automaticamente.

```markdown
# memorymesh-vocab skill

## Vocabolario del Progetto
Il vocabolario del progetto corrente è già iniettato all'inizio della sessione.
Usalo come riferimento immediato per entità, convenzioni e decisioni.

## Quando Fare Lookup
Usa `mcp__memorymesh__vocab_lookup` quando:
- incontri un termine nel codice che non capisci dal contesto immediato
- stai per chiedere all'utente "cosa intendi per X?"
- stai per inferire il significato di un termine da zero

Non fare lookup per termini standard di Python/TypeScript o per framework noti.

## Quando Fare Upsert
Usa `mcp__memorymesh__vocab_upsert` quando:
- crei un nuovo file, classe o service significativo
- l'utente introduce un pattern o convenzione non ancora nel vocabolario
- viene presa una decisione architetturale con motivazione
- introduci un'abbreviazione che userete nel progetto

## Come Fare Upsert Correttamente

```
mcp__memorymesh__vocab_upsert(
  term="NomeChiaro",           # PascalCase per entity, snake per conv
  category="entity",           # entity|convention|decision|abbreviation|pattern
  definition="cosa fa, max 80 chars",
  detail="path/to/file.py · deps:X,Y · test:tests/test_x.py",
  metadata={"path": "...", "deps": [...]}  # opzionale, per entity
)
```

## Workflow Ottimale
1. SessionStart: vocab manifest già iniettato — usa direttamente
2. Durante la sessione: lookup se trovi termine non familiare
3. Fine sessione/task: upsert per nuove entità create o decisioni prese
4. NON fare lookup e upsert meccanicamente — solo quando realmente utile
```

---

## Endpoint API

### GET /api/v1/vocab/lookup
```
query params: term, project
response: { term, category, definition, detail, metadata, confidence, usage_count }
```

### GET /api/v1/vocab/search
```
query params: q, project, category (opzionale), limit (default 5)
response: { results: [{term, category, definition, score}] }
```

### POST /api/v1/vocab
```
body: { project, term, category, definition, detail?, metadata? }
source automaticamente = 'manual', confidence = 1.0
response 201: { id, term, ... }
```

### GET /api/v1/vocab/manifest
```
query params: project, limit (default 50)
headers: If-None-Match: "vocab-etag"  ← ETag per prompt caching
response 200: { manifest_text: "...", term_count: 28, shortcode_count: 18, token_estimate: 145 }
response 304: nessun body, plugin usa cache locale
```

### GET /api/v1/vocab/bloom (Strategia 10)
```
query params: project
response 200: { filter_bytes, size, hashes, items, false_positive_rate, version }
response 304: nessun body, plugin usa bloom filter locale
```
Plugin scarica e salva in `~/.memorymesh/vocab.bloom`. Consulta in RAM prima di
qualunque lookup per skippare round-trip su miss.

### MCP Tools
```
mcp__memorymesh__vocab_lookup(term, project?)
mcp__memorymesh__vocab_search(query, project?, category?)
mcp__memorymesh__vocab_upsert(term, category, definition, detail?, metadata?)
```

---

## Esempi di Vocabolario Popolato

Dopo 2 settimane di sviluppo su MemoryMesh stesso, il vocabolario
dovrebbe contenere qualcosa del genere:

```
[entity] ObsManifest=manifest_entries table·entry point token-efficiente·rebuilt nightly
[entity] VocabManifest=vocab_entries serializzato·injected at SessionStart·~200 token
[entity] EmbeddingWorker=workers/embedding.py·consume embed_jobs stream·nomic-embed-text
[entity] DistillationAgent=workers/distillation.py·CRON 03:00·Qwen3:8b on-demand
[entity] OfflineBuffer=~/.memorymesh/offline.jsonl·flush auto SessionStart
[entity] HistoryCompressor=POST /sessions/{id}/compress·Qwen3·async, turno dopo
[conv]   silent_fail=eccezioni catchate, buffer o log, MAI propagate al plugin
[conv]   fire_and_forget=timeout 3s, no await su risposta HTTP dal plugin
[dec]    manifest_differential=ETag check prima di re-fetch, risparmio 800-1500 token
[dec]    top5_default=search restituisce 5 risultati, expand=true per 20
[abbr]   obs=observation · vocab=vocabulary entry · dist=distillation run
[abbr]   RRF=Reciprocal Rank Fusion · DLQ=dead-letter queue · ETag=HTTP cache validator
[pattern] partial_index=WHERE distilled_into IS NULL su tutti gli indici observations
```
