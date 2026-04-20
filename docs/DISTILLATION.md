# Agente Distillatore — Specifica Completa

> Leggi questo file prima di lavorare sui task F5-01..F5-09.

## Ruolo e Importanza

L'agente distillatore impedisce la degradazione della memoria nel tempo.
Senza di lui, dopo settimane: migliaia di `observation` ridondanti,
manifest fuori budget, search rumorosa. È il componente più complesso del progetto.

**Provider LLM**: configurabile via `MEMORYMESH_LLM_PROVIDER` (vedi ADR-014, 015).
Default: `gemini` (Gemini 2.5 Flash). Opt-in: `ollama` (Qwen3.5-9B), `openai`, `anthropic`.

**Quando gira**: CRON 03:00 UTC. Lock Redis per evitare run concorrenti.

**Durata**:
- Profile A (Gemini Flash): **2-10 min** per corpus 1000 obs (API I/O + DB)
- Profile C (Ollama Qwen): 5-30 min per corpus 1000 obs (CPU-bound)

**Costo tipico per run**:
- Gemini 2.5 Flash: ~$0.02-0.05 per run notturno
- Ollama Qwen locale: $0 (+ elettricità)

**Budget guardrail**: ogni chiamata LLM passa per `check_and_reserve(tokens)`
contro `MEMORYMESH_LLM_DAILY_TOKEN_CAP` (default 500k). Se superato → skip
operation + audit + alert admin (ADR-016).

---

## Pipeline Completa

```
CRON 03:00 → distillation_worker.py

Per ogni progetto attivo (obs nelle ultime 48h):
  ├─ Acquisisci Redis lock (TTL 2h)
  ├─ Step 1: PRUNE              → 0 token
  ├─ Step 2: FIND CLUSTERS      → 0 token (pgvector)
  ├─ Step 3: MERGE              → ~200-500 token/cluster (Qwen3)
  ├─ Step 4: TIGHTEN            → ~300 token/entry (Qwen3)
  ├─ Step 5: DECAY SCORES       → 0 token
  ├─ Step 6: VOCAB EXTRACT      → ~500 token/batch (Qwen3)
  ├─ Step 7: TIGHTEN CAPPED     → ~200 token/entry (Qwen3) ← NUOVO (Strategia 17)
  ├─ Step 8: SHORTCODE ASSIGN   → 0 token                   ← NUOVO (Strategia 12)
  ├─ Step 9: FINGERPRINT AGG    → 0 token                   ← NUOVO (Strategia 16)
  ├─ Step 10: REBUILD MANIFEST  → 0 token (root + branch, is_root, scope)
  ├─ Step 11: REBUILD BLOOM     → 0 token                   ← NUOVO (Strategia 10)
  └─ Rilascia Redis lock
```

---

## LlmCallback Protocol + Adapter (ADR-015)

Ogni step LLM in questa pipeline NON chiama direttamente Gemini/Ollama/ecc.
Usa l'astrazione `LlmCallback` iniettata via DI.

```python
# api/app/services/llm.py
from typing import Protocol
from pydantic import BaseModel
from datetime import date
from redis.asyncio import Redis

class LlmResponse(BaseModel):
    content: str
    input_tokens: int
    output_tokens: int
    cached_tokens: int = 0      # implicit caching hits (Gemini, Anthropic)
    model: str
    latency_ms: int

class LlmCallback(Protocol):
    async def complete(
        self,
        system: str,
        user: str,
        max_tokens: int = 2000,
        response_schema: type[BaseModel] | None = None,
    ) -> LlmResponse: ...

    @property
    def model(self) -> str: ...

    @property
    def provider_name(self) -> str: ...


class BudgetExceeded(Exception): ...

async def check_and_reserve(redis: Redis, tokens: int, cap: int) -> None:
    today = date.today().isoformat()
    key = f"llm:budget:{today}"
    new_total = await redis.incrby(key, tokens)
    if new_total == tokens:
        await redis.expire(key, 86400 * 2)
    if new_total > cap:
        await redis.decrby(key, tokens)   # rollback reserve
        raise BudgetExceeded(f"daily cap {cap} exceeded (currently {new_total})")


class BudgetedLlm:
    """Wrapper che applica budget cap + audit + retry a qualunque LlmCallback."""

    def __init__(self, inner: LlmCallback, redis: Redis, db, cap: int):
        self.inner = inner
        self.redis = redis
        self.db = db
        self.cap = cap

    async def complete(self, system: str, user: str, purpose: str,
                        project_id: UUID | None = None,
                        session_id: UUID | None = None,
                        max_tokens: int = 2000,
                        response_schema: type[BaseModel] | None = None,
                        ) -> LlmResponse | None:
        # Stima pre-call (tiktoken su prompt; per output usa max_tokens)
        estimated = count_tokens(system) + count_tokens(user) + max_tokens

        try:
            await check_and_reserve(self.redis, estimated, self.cap)
        except BudgetExceeded:
            logger.warning("llm_budget_exceeded", purpose=purpose, estimated=estimated)
            await audit_log("llm_budget_exceeded", details={"purpose": purpose})
            await notify_admin_ntfy(f"LLM budget exceeded on {purpose}")
            return None   # caller gestisce None come skip

        t0 = time.monotonic()
        try:
            result = await self.inner.complete(system=system, user=user,
                                                max_tokens=max_tokens,
                                                response_schema=response_schema)
            success = True
            error_class = None
        except Exception as e:
            success = False
            error_class = type(e).__name__
            result = None

        latency_ms = int((time.monotonic() - t0) * 1000)

        # Riconcilia budget (tokens estimated → actual)
        if result:
            actual = result.input_tokens + result.output_tokens
            delta = actual - estimated
            if delta != 0:
                await self.redis.incrby(f"llm:budget:{date.today().isoformat()}", delta)

        # Audit row (llm_api_calls)
        await self.db.execute("""
            INSERT INTO llm_api_calls (provider, model, purpose, project_id, session_id,
              input_tokens, output_tokens, cached_tokens, cost_microcents, latency_ms,
              success, error_class, budget_day)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
        """, self.inner.provider_name, self.inner.model, purpose,
             project_id, session_id,
             result.input_tokens if result else 0,
             result.output_tokens if result else 0,
             result.cached_tokens if result else 0,
             _compute_cost_microcents(self.inner, result) if result else 0,
             latency_ms, success, error_class, date.today())

        if not success:
            raise   # re-raise per caller

        return result
```

### Gemini Adapter (default)

```python
# api/app/services/llm_gemini.py
from google import genai
from google.genai import types

class GeminiLlmAdapter:
    def __init__(self, api_key: str, model: str = "gemini-2.5-flash"):
        self.client = genai.Client(api_key=api_key)
        self._model = model

    @property
    def model(self) -> str: return self._model

    @property
    def provider_name(self) -> str: return "gemini"

    async def complete(self, system: str, user: str, max_tokens: int = 2000,
                        response_schema=None) -> LlmResponse:
        config = types.GenerateContentConfig(
            system_instruction=system,
            max_output_tokens=max_tokens,
            temperature=0.1,
        )
        if response_schema:
            config.response_mime_type = "application/json"
            config.response_schema = response_schema

        t0 = time.monotonic()
        res = await self.client.aio.models.generate_content(
            model=self._model,
            contents=user,
            config=config,
        )
        latency_ms = int((time.monotonic() - t0) * 1000)

        # Usage metadata (Gemini 2.5+ include cached_content_token_count)
        um = res.usage_metadata
        return LlmResponse(
            content=res.text,
            input_tokens=um.prompt_token_count,
            output_tokens=um.candidates_token_count,
            cached_tokens=getattr(um, 'cached_content_token_count', 0) or 0,
            model=self._model,
            latency_ms=latency_ms,
        )
```

**Nota implicit caching Gemini 2.5+**: se il prompt ha un prefisso stabile
(il nostro system prompt + vocab manifest + obs root — Strategia 8!) di
≥ 1024 token per Flash o ≥ 2048 per Pro, Gemini automaticamente usa la
cache. `cached_token_count` riflette quanti erano cache-hit (= fatturati a
1/10 o giù di lì). Il nostro design cache-aware è compatibile con entrambe
le piattaforme (Anthropic per Claude Code + Gemini per distillation).

### Ollama Adapter

```python
# api/app/services/llm_ollama.py
import ollama

class OllamaLlmAdapter:
    def __init__(self, url: str, model: str = "qwen3.5:9b"):
        self.client = ollama.AsyncClient(host=url)
        self._model = model

    @property
    def model(self) -> str: return self._model

    @property
    def provider_name(self) -> str: return "ollama"

    async def complete(self, system: str, user: str, max_tokens: int = 2000,
                        response_schema=None) -> LlmResponse:
        options = {"num_predict": max_tokens, "temperature": 0.1}
        if response_schema:
            # Ollama: format=json mode + validation post-hoc con Pydantic
            format_arg = response_schema.model_json_schema()
        else:
            format_arg = None

        t0 = time.monotonic()
        res = await self.client.chat(
            model=self._model,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            format=format_arg,
            options=options,
        )
        latency_ms = int((time.monotonic() - t0) * 1000)

        return LlmResponse(
            content=res["message"]["content"],
            input_tokens=res.get("prompt_eval_count", 0),
            output_tokens=res.get("eval_count", 0),
            cached_tokens=0,   # Ollama non riporta cache; siamo local comunque
            model=self._model,
            latency_ms=latency_ms,
        )
```

### OpenAI / Anthropic Adapter

Simili. Standard SDK Python:
- `openai.AsyncOpenAI(api_key=...).responses.create(model=..., input=..., text={"format":...})`
- `anthropic.AsyncAnthropic(api_key=...).messages.create(model=..., system=..., messages=..., tools=[schema_tool])`

Anthropic supporta explicit prompt caching (`cache_control: ephemeral`) —
l'adapter lo applica al system message per beneficiare dell'implicit prefix.

### Factory DI (usage negli step distillation)

```python
def get_llm_callback(settings: Settings, redis: Redis, db) -> BudgetedLlm:
    match settings.llm_provider:
        case "gemini":    inner = GeminiLlmAdapter(settings.gemini_api_key, settings.llm_model)
        case "ollama":    inner = OllamaLlmAdapter(settings.ollama_url, settings.llm_model)
        case "openai":    inner = OpenAiLlmAdapter(settings.openai_api_key, settings.llm_model)
        case "anthropic": inner = AnthropicLlmAdapter(settings.anthropic_api_key, settings.llm_model)
        case _: raise ValueError(f"unknown provider: {settings.llm_provider}")
    return BudgetedLlm(inner, redis, db, settings.llm_daily_token_cap)

# Uso negli step — identico indipendente dal provider
async def merge_cluster(cluster, llm: BudgetedLlm):
    result = await llm.complete(
        system="Sei un assistente che consolida ricordi...",
        user=MERGE_PROMPT.format(...),
        purpose="distill_merge",
        project_id=...,
        max_tokens=300,
        response_schema=MergeOutput,
    )
    if result is None:
        return None   # budget exceeded, skip
    # result.content è già validato come JSON matching MergeOutput (se response_schema)
    ...
```

---

## Step 1 — PRUNE

```python
async def prune(project_id: UUID) -> int:
    # Elimina expired
    r1 = await db.execute("""
        DELETE FROM observations
        WHERE project_id=$1 AND expires_at IS NOT NULL
          AND expires_at < now() AND distilled_into IS NULL
    """, project_id)

    # Elimina con score troppo basso (irrecuperabili dal decay)
    r2 = await db.execute("""
        DELETE FROM observations
        WHERE project_id=$1 AND relevance_score < 0.05
          AND type = 'observation' AND distilled_into IS NULL
    """, project_id)

    return r1.rowcount + r2.rowcount
```

---

## Step 2 — FIND MERGE CANDIDATES

```python
async def find_merge_candidates(
    project_id: UUID,
    threshold: float = 0.92
) -> list[list[int]]:
    # Coppie con similarity > threshold, stesso tipo, stesso progetto
    pairs = await db.fetch("""
        SELECT a.id AS id_a, b.id AS id_b,
               1 - (a.embedding <=> b.embedding) AS sim
        FROM observations a
        JOIN observations b ON a.id < b.id
        WHERE a.project_id=$1 AND b.project_id=$1
          AND a.type = b.type
          AND a.distilled_into IS NULL AND b.distilled_into IS NULL
          AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL
          AND 1 - (a.embedding <=> b.embedding) > $2
        ORDER BY sim DESC
    """, project_id, threshold)

    # Union-find per cluster transitivi
    parent = {}
    def find(x):
        parent.setdefault(x, x)
        if parent[x] != x: parent[x] = find(parent[x])
        return parent[x]
    def union(x, y):
        parent[find(x)] = find(y)

    for p in pairs:
        union(p['id_a'], p['id_b'])

    clusters = {}
    for p in pairs:
        root = find(p['id_a'])
        clusters.setdefault(root, set()).update([p['id_a'], p['id_b']])

    return [list(c) for c in clusters.values() if len(c) >= 2]
```

---

## Step 3 — MERGE CLUSTERS

```python
MERGE_PROMPT = """\
Hai {n} osservazioni sullo stesso concetto. Estraile in UNA sola memory concisa.

Osservazioni:
{obs_text}

Rispondi SOLO con JSON valido:
{{"type":"directive|context|identity|bookmark","content":"max 150 parole","tags":[],"expires_at":null}}

Regole tipo:
- directive = regola comportamentale confermata
- context   = stato corrente o decisione recente
- identity  = preferenza permanente utente
- bookmark  = reference/link esterno
- expires_at = data ISO se temporaneo, null se permanente"""

async def merge_cluster(cluster: list[int], llm: LlmCallback) -> int | None:
    rows = await db.fetch(
        "SELECT id, type, content FROM observations WHERE id=ANY($1)", cluster
    )
    obs_text = "\n---\n".join(f"[{r['type']}] {r['content']}" for r in rows)

    try:
        raw = await llm(
            system="Sei un assistente che consolida ricordi in fatti durevoli.",
            messages=[{"role":"user", "content": MERGE_PROMPT.format(
                n=len(cluster), obs_text=obs_text
            )}],
            max_tokens=300
        )
        data = parse_json_strict(raw)
        validated = MergeOutput(**data)  # Pydantic
    except Exception as e:
        logger.warning("merge_parse_failed", cluster=cluster, error=str(e))
        return None

    new_id = await create_observation(
        project_id=rows[0]['project_id'],
        **validated.dict(),
        metadata={"merged_from": cluster, "distilled_at": utcnow()}
    )
    await db.execute(
        "UPDATE observations SET distilled_into=$1 WHERE id=ANY($2)",
        new_id, cluster
    )
    return new_id
```

---

## Step 4 — TIGHTEN

```python
TIGHTEN_PROMPT = """\
Riscrivi questa memory più concisa. Preserva TUTTI i fatti. Elimina ripetizioni.
Massimo 100 parole. Rispondi SOLO con il testo riscritto, nessun prefisso.

Memory:
{content}"""

async def tighten(obs_id: int, llm: LlmCallback) -> bool:
    row = await db.fetchrow("SELECT content FROM observations WHERE id=$1", obs_id)
    if not row or len(row['content'].split()) < settings.tighten_min_words:
        return False
    try:
        result = await llm(
            system="Sintetizza testi preservando i fatti.",
            messages=[{"role":"user","content": TIGHTEN_PROMPT.format(content=row['content'])}],
            max_tokens=200
        )
        result = result.strip()
        if not result or len(result) < 20: return False
        await db.execute(
            "UPDATE observations SET content=$1, last_tightened=now() WHERE id=$2",
            result, obs_id
        )
        await queue_reembed(obs_id)  # rigenera embedding per contenuto nuovo
        return True
    except Exception as e:
        logger.warning("tighten_failed", obs_id=obs_id, error=str(e))
        return False
```

---

## Step 5 — DECAY SCORES

```python
async def decay_scores(project_id: UUID) -> None:
    # observation: decay rapido (×0.85 ogni 14 giorni)
    await db.execute("""
        UPDATE observations SET relevance_score = relevance_score * $1
        WHERE project_id=$2 AND type='observation'
          AND created_at < now() - interval '14 days'
          AND distilled_into IS NULL
    """, settings.decay_observation_factor, project_id)

    # context/bookmark: decay lento (×0.97 ogni settimana)
    await db.execute("""
        UPDATE observations SET relevance_score = relevance_score * $1
        WHERE project_id=$2 AND type IN ('context','bookmark')
          AND created_at < now() - interval '7 days'
          AND distilled_into IS NULL
    """, settings.decay_context_factor, project_id)
    # identity e directive: nessun decay
```

---

## Step 6 — VOCAB EXTRACTION (NUOVO)

```python
VOCAB_EXTRACT_PROMPT = """\
Analizza queste osservazioni recenti di un progetto software.
Estrai termini tecnici SPECIFICI di questo progetto.

Osservazioni:
{obs_text}

Estrai SOLO: nomi di file/classi/servizi specifici del progetto,
convenzioni adottate, decisioni con motivazione, abbreviazioni usate ripetutamente.
NON estrarre: librerie standard, framework noti, termini generici.

Rispondi SOLO con JSON array (anche vuoto []):
[{{"term":"...","category":"entity|convention|decision|abbreviation|pattern",
  "definition":"max 80 chars","detail":"opzionale","confidence":0.7}}]
Massimo 10 termini."""

async def extract_vocab_from_observations(
    project_id: UUID,
    llm: LlmCallback
) -> int:
    # Prendi obs delle ultime 48h non ancora usate per vocab extraction
    rows = await db.fetch("""
        SELECT content, type FROM observations
        WHERE project_id=$1 AND distilled_into IS NULL
          AND created_at > now() - interval '48 hours'
          AND type = 'observation'
        ORDER BY created_at DESC LIMIT 50
    """, project_id)

    if not rows: return 0

    obs_text = "\n".join(f"- {r['content']}" for r in rows)

    try:
        raw = await llm(
            system="Sei un assistente che identifica termini tecnici di progetto.",
            messages=[{"role":"user","content": VOCAB_EXTRACT_PROMPT.format(obs_text=obs_text)}],
            max_tokens=600
        )
        entries = parse_json_array(raw)  # lista di dict
    except Exception as e:
        logger.warning("vocab_extract_failed", error=str(e))
        return 0

    saved = 0
    for entry in entries[:10]:
        try:
            v = VocabExtractOutput(**entry)
            # Non sovrascrivere entry manuali
            existing = await db.fetchrow(
                "SELECT source, confidence FROM vocab_entries WHERE project_id=$1 AND term=$2",
                project_id, v.term
            )
            if existing and existing['source'] == 'manual':
                continue  # skip — non toccare entry manuali
            await db.execute("""
                INSERT INTO vocab_entries (project_id, term, category, definition, detail, source, confidence)
                VALUES ($1,$2,$3,$4,$5,'auto',$6)
                ON CONFLICT (project_id, term) DO UPDATE
                  SET definition=EXCLUDED.definition,
                      detail=EXCLUDED.detail,
                      confidence=EXCLUDED.confidence,
                      updated_at=now()
                  WHERE vocab_entries.source != 'manual'
            """, project_id, v.term, v.category, v.definition, v.detail, v.confidence)
            saved += 1
        except Exception:
            continue

    return saved
```

---

## Step 7 — TIGHTEN CAPPED (Strategia 17)

```python
async def tighten_capped_observations(project_id: UUID, llm: LlmCallback) -> int:
    """Rielabora observation che al write hanno superato MAX_OBS_TOKENS
    e sono state troncate con marker '[capped]'. Restituisce versione
    densa e informativa.
    """
    rows = await db.fetch("""
        SELECT id, content, metadata FROM observations
        WHERE project_id=$1
          AND content LIKE '%[capped]%'
          AND last_tightened IS NULL
          AND metadata ? 'full_content'
        LIMIT 50
    """, project_id)

    done = 0
    for row in rows:
        full = row['metadata'].get('full_content', '')
        if not full: continue
        try:
            dense = await llm(
                system="Comprimi senza perdere fatti. Output: massimo 150 token.",
                messages=[{"role":"user", "content":
                    f"Riscrivi concisa questa osservazione (max 150 token):\n{full}"}],
                max_tokens=200
            )
            new_tokens = count_tiktoken(dense)
            await db.execute("""
                UPDATE observations
                SET content=$1, last_tightened=now(), token_estimate=$2,
                    metadata=metadata - 'full_content'
                WHERE id=$3
            """, dense.strip(), new_tokens, row['id'])
            await queue_reembed(row['id'])
            done += 1
        except Exception as e:
            logger.warning("tighten_capped_failed", obs_id=row['id'], error=str(e))
    return done
```

---

## Step 8 — SHORTCODE ASSIGN (Strategia 12)

```python
async def assign_shortcodes(project_id: UUID) -> int:
    """Assegna shortcode ai termini con usage_count alto ma senza shortcode.
    Assegnazione stabile — mai revocata, per preservare cache-stability del manifest.
    """
    threshold = settings.shortcode_threshold  # default 10

    candidates = await db.fetch("""
        SELECT id, term FROM vocab_entries
        WHERE project_id=$1 AND shortcode IS NULL AND usage_count >= $2
        ORDER BY usage_count DESC LIMIT 50
    """, project_id, threshold)

    used_codes = set(r['shortcode'] for r in await db.fetch(
        "SELECT shortcode FROM vocab_entries WHERE project_id=$1 AND shortcode IS NOT NULL",
        project_id
    ))

    assigned = 0
    for c in candidates:
        code = _generate_code(c['term'], used_codes)
        if not code: continue
        used_codes.add(f"${code}")
        await db.execute(
            "UPDATE vocab_entries SET shortcode=$1, updated_at=now() WHERE id=$2",
            f"${code}", c['id']
        )
        assigned += 1

    # Pulisci shortcode orfani (term eliminato) — rari ma possibili
    await db.execute("""
        DELETE FROM vocab_entries
        WHERE project_id=$1 AND shortcode IS NOT NULL AND term IS NULL
    """, project_id)

    return assigned


def _generate_code(term: str, used: set[str]) -> str | None:
    """Collision-free 2-4 char code. Deterministico."""
    import re
    parts = re.findall(r'[A-Z]+[a-z]*|[a-z]+', term)
    if not parts: return None
    base = ''.join(p[0].upper() for p in parts if p)
    if f"${base}" not in used: return base
    if len(parts) >= 2:
        alt = parts[0][:2].upper() + parts[1][:1].upper()
        if f"${alt}" not in used: return alt
    for i in range(2, 10):
        n = f"{base}{i}"
        if f"${n}" not in used: return n
    return None
```

---

## Step 9 — FINGERPRINT AGGREGATION (Strategia 16)

```python
async def aggregate_fingerprints(project_id: UUID) -> int:
    """Aggrega sessions.tool_sequence + accessi observation in pattern predittivi.
    Salvato in query_fingerprints per prefetch lato plugin.

    Sorgente accessed_ids — due opzioni:
    A) Fallback (default): observations.last_used_at within session window
       (richiede update last_used_at su batch_fetch e search — già fatto)
    B) Avanzato (opt-in MEMORYMESH_FP_LOGGING=true): tabella dedicata
       manifest_entries_accessed(session_id, obs_id, ts) scritta dai router
       observations/batch e search. Più precisa ma overhead di scrittura.
    """
    # Pattern = prime 3 tool del tool_sequence (la "firma" di inizio sessione)
    if settings.fp_logging_enabled:
        # Opzione B
        sessions = await db.fetch("""
            SELECT s.id, s.tool_sequence,
                   ARRAY(SELECT obs_id FROM manifest_entries_accessed
                         WHERE session_id=s.id) AS accessed_ids
            FROM sessions s
            WHERE s.project_id=$1 AND s.closed_at > now() - interval '30 days'
              AND array_length(s.tool_sequence, 1) >= 3
        """, project_id)
    else:
        # Opzione A — fallback su last_used_at
        sessions = await db.fetch("""
            SELECT s.id, s.tool_sequence,
                   ARRAY(SELECT id FROM observations
                         WHERE project_id=$1
                           AND last_used_at BETWEEN s.started_at AND COALESCE(s.closed_at, now())
                         ORDER BY last_used_at DESC LIMIT 20) AS accessed_ids
            FROM sessions s
            WHERE s.project_id=$1 AND s.closed_at > now() - interval '30 days'
              AND array_length(s.tool_sequence, 1) >= 3
        """, project_id, project_id)

    patterns = {}  # pattern_str → {hits: int, accessed_ids: list[int]}
    for s in sessions:
        signature = " → ".join(s['tool_sequence'][:3])
        p = patterns.setdefault(signature, {"sessions": 0, "ids": []})
        p["sessions"] += 1
        p["ids"].extend(s['accessed_ids'] or [])

    saved = 0
    for sig, data in patterns.items():
        if data["sessions"] < 3: continue  # soglia minima
        # Top-N obs_id più frequenti in questo pattern
        from collections import Counter
        top_ids = [i for i,_ in Counter(data["ids"]).most_common(10)]
        confidence = min(1.0, data["sessions"] / 10.0)  # 10+ hit = 1.0

        await db.execute("""
            INSERT INTO query_fingerprints
              (project_id, trigger_pattern, predicted_ids, confidence, updated_at)
            VALUES ($1, $2, $3, $4, now())
            ON CONFLICT (project_id, trigger_pattern) DO UPDATE
              SET predicted_ids = EXCLUDED.predicted_ids,
                  confidence    = EXCLUDED.confidence,
                  updated_at    = now()
        """, project_id, sig, top_ids, confidence)
        saved += 1

    return saved
```

Nota: `manifest_entries_accessed` è una tabella di log scritta dai batch_fetch
e search, non inclusa nel core schema (solo se `MEMORYMESH_FP_LOGGING=true`).
Alternativa più leggera: usare `observations.last_used_at` aggiornato al fetch
e considerare solo obs con `last_used_at within session window`.

---

## Step 10 — REBUILD MANIFEST (aggiornato: is_root + scope)

```python
ONE_LINER_MAX = {
    'identity': 80, 'directive': 80,
    'context': 40, 'bookmark': 35, 'observation': 20
}

# Soglie per is_root (Strategia 9)
ROOT_RELEVANCE_THRESHOLD = 0.85
ROOT_ACCESS_COUNT_THRESHOLD = 50

async def rebuild_manifest(project_id: UUID) -> int:
    await db.execute(
        "DELETE FROM manifest_entries WHERE project_id=$1", project_id
    )
    rows = await db.fetch("""
        SELECT id, type, content, scope, relevance_score, access_count, last_used_at
        FROM observations
        WHERE project_id=$1 AND distilled_into IS NULL
          AND (expires_at IS NULL OR expires_at > now())
          -- LRU eviction (Strategia 13)
          AND NOT (last_used_at < now() - interval '60 days' AND access_count < 2)
        ORDER BY
          CASE type WHEN 'identity' THEN 0 WHEN 'directive' THEN 1
            WHEN 'context' THEN 2 WHEN 'bookmark' THEN 3 ELSE 4 END,
          relevance_score DESC, created_at DESC
    """, project_id)

    entries = []
    for row in rows:
        max_chars = ONE_LINER_MAX.get(row['type'], 40)
        first_line = row['content'].strip().split('\n')[0]
        one_liner = first_line[:max_chars]
        if len(first_line) > max_chars:
            one_liner = one_liner[:-3] + '...'

        priority = {'identity':0,'directive':1,'context':2,'bookmark':3}.get(row['type'], 4)

        # is_root (Strategia 9 + 13)
        is_root = (
            row['type'] in ('identity', 'directive')
            or (row['access_count'] or 0) > ROOT_ACCESS_COUNT_THRESHOLD
            or (row['type'] == 'context' and (not row['scope'] or row['scope'] == [])
                and (row['relevance_score'] or 0) > ROOT_RELEVANCE_THRESHOLD)
        )

        scope_path = '/' + '/'.join(row['scope'] or [])

        entries.append((
            project_id, row['id'], one_liner, row['type'],
            priority, scope_path, is_root
        ))

    await db.executemany("""
        INSERT INTO manifest_entries
          (project_id, obs_id, one_liner, type, priority, scope_path, is_root)
        VALUES ($1,$2,$3,$4,$5,$6,$7)
    """, entries)

    # Calcola ETag del root set per cache invalidation predicibile
    root_entries = [e for e in entries if e[6]]  # is_root=true
    root_etag = hashlib.sha256(
        "\n".join(f"{e[1]}|{e[3]}|{e[2]}" for e in sorted(root_entries, key=lambda x: (x[4], x[1])))
        .encode('utf-8')
    ).hexdigest()[:16]
    await db.execute("""
        INSERT INTO project_manifest_meta (project_id, root_etag, updated_at)
        VALUES ($1, $2, now())
        ON CONFLICT (project_id) DO UPDATE SET root_etag=$2, updated_at=now()
    """, project_id, root_etag)

    return len(entries)
```

---

## Step 11 — REBUILD BLOOM (Strategia 10, via Redis 8 BF nativo — ADR-004)

Redis 8 ha bloom filter come data type nativo. `pybloom-live` NON è più
una dipendenza del server (rimossa da requirements.txt). I comandi `BF.*`
sono implementati in C dentro Redis → performance superiore + zero overhead
di serializzazione Python-side.

```python
async def rebuild_vocab_bloom(project_id: UUID) -> dict:
    """Ricostruisce il bloom filter del vocabolario in Redis 8 nativo.
    Atomico: drop key vecchia + BF.RESERVE + BF.MADD in TRANSACTION."""
    terms = await db.fetch_column(
        "SELECT LOWER(term) FROM vocab_entries WHERE project_id=$1", project_id
    )
    if not terms:
        return {"items": 0, "size": 0}

    key = f"vocab:bloom:{project_id}"
    capacity = max(1000, len(terms) * 2)

    # Atomic rebuild in pipeline (drop + reserve + madd)
    async with redis.pipeline(transaction=True) as pipe:
        pipe.delete(key)
        pipe.execute_command("BF.RESERVE", key, "0.01", capacity, "EXPANSION", "2")
        # MADD in batch di 500 per evitare comandi troppo lunghi
        for i in range(0, len(terms), 500):
            batch = terms[i:i+500]
            pipe.execute_command("BF.MADD", key, *batch)
        await pipe.execute()

    # Calcola ETag per cache invalidation lato plugin
    info = await redis.execute_command("BF.INFO", key)
    # BF.INFO ritorna array alternato k/v: [b'Capacity', 2000, b'Size', 12345, ...]
    info_dict = dict(zip(info[::2], info[1::2]))

    etag = hashlib.sha256(
        f"{project_id}:{len(terms)}:{info_dict.get(b'Size', 0)}".encode()
    ).hexdigest()[:16]

    # Salva metadata separato per ETag check rapido (senza BF.INFO)
    await redis.hset(
        f"vocab:bloom:meta:{project_id}",
        mapping={"etag": etag, "items": len(terms), "fpr": 0.01}
    )

    return {"items": len(terms), "size": int(info_dict.get(b'Size', 0)), "etag": etag}
```

**Export per plugin** (endpoint `/api/v1/vocab/bloom`):

```python
async def export_vocab_bloom(project_id: UUID) -> dict:
    """BF.SCANDUMP per export incrementale. Il plugin ricostruisce
    l'oggetto Bloom con lib TypeScript bloom-filters (BF.LOADCHUNK compatibile)."""
    key = f"vocab:bloom:{project_id}"
    meta = await redis.hgetall(f"vocab:bloom:meta:{project_id}")
    if not meta:
        raise HTTPException(404, "bloom_not_initialized")

    chunks = []
    iter_pos = 0
    while True:
        res = await redis.execute_command("BF.SCANDUMP", key, iter_pos)
        next_iter, data = int(res[0]), res[1]
        if next_iter == 0: break
        chunks.append(base64.b64encode(data).decode())
        iter_pos = next_iter

    return {
        "chunks": chunks,
        "etag": meta[b"etag"].decode(),
        "items": int(meta[b"items"]),
        "false_positive_rate": float(meta[b"fpr"]),
        "format": "redis-bf-scandump-v1"
    }
```

**Incremental update** — al singolo `vocab_upsert`, invece di rebuild completo:

```python
async def on_vocab_upserted(project_id: UUID, term: str) -> None:
    key = f"vocab:bloom:{project_id}"
    await redis.execute_command("BF.ADD", key, term.lower())
    # ETag ruota (nuovo item aggiunto); plugin al next sync riceve fresh
    await _rotate_bloom_etag(project_id)
```

Redis `appendonly yes` + `appendfsync everysec` garantisce durability dei
comandi BF.* (perdita massima: ultimo secondo) — setting già in
`docker-compose.yml` redis service.

---

## History Compression (POST /sessions/{id}/compress)

```python
COMPRESS_PROMPT = """\
Scrivi un summary STRUTTURATO e DENSO di questa sessione di coding.

Conversazione:
{messages_text}

Include SOLO ciò che è accaduto:
- Obiettivo (1 riga)
- Decisioni prese (lista, max 3)
- File modificati/creati (con breve descrizione)
- Problemi risolti
- Stato corrente (completato vs in sospeso)

Formato: markdown compatto, max 400 parole.
NON includere ragionamenti, opinioni, testo di conversazione."""

async def compress_session(
    session_id: UUID,
    messages: list[dict],
    project_id: UUID,
    llm: LlmCallback
) -> dict:
    messages_text = "\n".join(
        f"{m['role'].upper()}: {m['content'][:200]}" for m in messages[-50:]
    )
    tokens_before = sum(len(m['content']) for m in messages) // 4

    try:
        summary = await llm(
            system="Sei un assistente che sintetizza sessioni di coding.",
            messages=[{"role":"user","content": COMPRESS_PROMPT.format(
                messages_text=messages_text
            )}],
            max_tokens=600
        )
    except Exception as e:
        logger.warning("compress_failed", session_id=session_id, error=str(e))
        return {"error": str(e)}

    obs_id = await create_observation(
        project_id=project_id,
        session_id=session_id,
        type='context',
        content=summary,
        tags=['session-summary'],
        metadata={'compressed_from_session': str(session_id),
                  'original_messages': len(messages)}
    )

    await db.execute(
        "UPDATE sessions SET compressed_at=now(), summary_obs_id=$1 WHERE id=$2",
        obs_id, session_id
    )

    tokens_after = len(summary) // 4
    return {
        "summary_obs_id": obs_id,
        "tokens_before": tokens_before,
        "tokens_after": tokens_after,
        "tokens_saved": tokens_before - tokens_after
    }
```

---

## Gestione Errori

```python
async def run_for_project(project_id: UUID, llm: LlmCallback) -> DistillStats:
    """Ogni step è indipendente — se uno fallisce, continua."""
    stats = DistillStats()

    for step_name, step_fn, *args in [
        ("prune",         prune,                           project_id),
        ("merge",         run_merge_step,                  project_id, llm),
        ("tighten",       run_tighten_step,                project_id, llm),
        ("decay",         decay_scores,                    project_id),
        ("vocab",         extract_vocab_from_observations, project_id, llm),
        ("tighten_capped",tighten_capped_observations,     project_id, llm),
        ("shortcode",     assign_shortcodes,               project_id),
        ("fingerprint",   aggregate_fingerprints,          project_id),
        ("manifest",      rebuild_manifest,                project_id),
        ("bloom",         rebuild_vocab_bloom,             project_id),
    ]:
        try:
            result = await step_fn(*args)
            setattr(stats, step_name, result)
            logger.info(f"distill_{step_name}_ok", project=project_id, result=result)
        except Exception as e:
            stats.errors.append(f"{step_name}: {e}")
            logger.error(f"distill_{step_name}_failed", project=project_id, error=str(e))

    return stats
```

---

## Configurazione (da Settings)

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `DISTILLATION_CRON` | `0 3 * * *` | Schedule notturno |
| `MERGE_SIMILARITY_THRESHOLD` | `0.92` | Soglia similarity per merge |
| `DECAY_OBSERVATION_FACTOR` | `0.85` | Decay observation ogni 14gg |
| `DECAY_CONTEXT_FACTOR` | `0.97` | Decay context/bookmark ogni settimana |
| `TIGHTEN_MIN_WORDS` | `150` | Parole minime per tightening |
| `VOCAB_EXTRACT_ENABLED` | `true` | Abilita auto-extraction vocab |
| `COMPRESS_THRESHOLD_TOKENS` | `8000` | Soglia token per compressione history |
| `MAX_OBS_TOKENS` | `200` | Capping at write (Strategia 17) |
| `SHORTCODE_THRESHOLD` | `10` | usage_count per eleggibilità shortcode (Strategia 12) |
| `ROOT_RELEVANCE_THRESHOLD` | `0.85` | Score minimo per context → is_root (Strategia 9) |
| `ROOT_ACCESS_COUNT_THRESHOLD` | `50` | access_count per promozione a root (Strategia 13) |
| `LRU_EVICTION_DAYS` | `60` | Giorni di inattività per eviction (Strategia 13) |
| `FINGERPRINT_MIN_SESSIONS` | `3` | Sessioni minime per pattern valido (Strategia 16) |
| `BM25_SKIP_THRESHOLD` | `0.3` | Score BM25 sopra il quale skippare vector search (Strategia 14) |
| `SEARCH_RERANK_ENABLED` | `true` | Abilita cross-encoder rerank (Strategia 15) |
