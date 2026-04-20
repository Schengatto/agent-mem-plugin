# Strategia di Test — MemoryMesh

## Principi

1. **Nessuna chiamata a API esterne** — Ollama, OpenAI sempre mockati
2. **DB reale** — testcontainers-python per PostgreSQL con pgvector
3. **Redis in-memory** — fakeredis nei test unitari, testcontainer per integrazione
4. **Plugin TS** — server HTTP mock locale, nessun server reale

---

## Python — conftest.py

```python
import pytest
import asyncpg
from testcontainers.postgres import PostgresContainer

@pytest.fixture(scope="session")
async def db_conn():
    with PostgresContainer("pgvector/pgvector:pg16") as pg:
        conn = await asyncpg.connect(pg.get_connection_url())
        await conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        await apply_migrations(conn)
        yield conn
        await conn.close()

@pytest.fixture
async def db(db_conn):
    async with db_conn.transaction() as tx:
        yield db_conn
        await tx.rollback()

@pytest.fixture
def mock_ollama(respx_mock):
    respx_mock.post("http://ollama:11434/api/embeddings").mock(
        return_value=httpx.Response(200, json={"embedding": [0.1]*768})
    )
    return respx_mock

@pytest.fixture
def mock_llm():
    async def fake(system, messages, max_tokens):
        return '{"type":"directive","content":"Test directive","tags":[],"expires_at":null}'
    return fake

@pytest.fixture
def mock_llm_vocab():
    async def fake(system, messages, max_tokens):
        return '[{"term":"TestService","category":"entity","definition":"Test service","confidence":0.7}]'
    return fake
```

---

## Test Chiave per Fase

### Fase 2 — Manifest con ETag
```python
async def test_manifest_etag_304(client, db, auth):
    # Prima request → 200 con ETag
    r1 = await client.get("/api/v1/manifest?project=test", headers=auth)
    assert r1.status_code == 200
    etag = r1.headers['etag']

    # Seconda request con ETag → 304
    r2 = await client.get("/api/v1/manifest?project=test",
                          headers={**auth, 'If-None-Match': etag})
    assert r2.status_code == 304

async def test_manifest_one_liner_adaptive(client, db, auth):
    """One-liner rispetta max chars per tipo."""
    await insert_obs(db, type='observation', content='x'*100)  # 100 chars
    r = await client.get("/api/v1/manifest?project=test", headers=auth)
    obs_entry = next(e for e in r.json()['entries'] if e['type']=='observation')
    assert len(obs_entry['one_liner']) <= 20  # max 20 per observation
```

### Fase 3 — Search Top-5 e MAI Full Content
```python
async def test_search_default_limit_5(client, db, auth, mock_ollama):
    await insert_many_obs(db, count=20)
    r = await client.get("/api/v1/search?q=test&project=test", headers=auth)
    assert len(r.json()['results']) <= 5

async def test_search_no_full_content(client, db, auth, mock_ollama):
    r = await client.get("/api/v1/search?q=test&project=test", headers=auth)
    for result in r.json()['results']:
        assert 'content' not in result
        assert 'one_liner' in result

async def test_search_type_filter(client, db, auth, mock_ollama):
    await insert_obs(db, type='directive', content='Test rule')
    await insert_obs(db, type='observation', content='Test obs')
    r = await client.get("/api/v1/search?q=test&project=test&type=directive", headers=auth)
    assert all(res['type'] == 'directive' for res in r.json()['results'])
```

### Fase 4 — Vocabolario
```python
async def test_vocab_lookup_exact(client, db, auth):
    await insert_vocab(db, term='AuthService', category='entity', definition='JWT service')
    r = await client.get("/api/v1/vocab/lookup?term=AuthService&project=test", headers=auth)
    assert r.status_code == 200
    assert r.json()['term'] == 'AuthService'

async def test_vocab_lookup_fuzzy(client, db, auth):
    """Fuzzy match: 'AuthServ' trova 'AuthService'."""
    await insert_vocab(db, term='AuthService', definition='JWT service')
    r = await client.get("/api/v1/vocab/lookup?term=AuthServ&project=test", headers=auth)
    assert r.status_code == 200
    assert r.json()['term'] == 'AuthService'

async def test_vocab_manifest_compact(client, db, auth):
    """Manifest vocab sotto 250 token per 25 termini."""
    await insert_many_vocab(db, count=25)
    r = await client.get("/api/v1/vocab/manifest?project=test", headers=auth)
    assert r.json()['token_estimate'] <= 250

async def test_vocab_manual_not_overwritten_by_auto(db):
    """Entry manuale non viene sovrascritta dall'auto-extraction."""
    await insert_vocab(db, term='X', source='manual', confidence=1.0, definition='manual def')
    await upsert_vocab_auto(db, term='X', definition='auto def')  # simula distillazione
    row = await db.fetchrow("SELECT source, definition FROM vocab_entries WHERE term='X'")
    assert row['source'] == 'manual'
    assert row['definition'] == 'manual def'
```

### Fase 5 — Distillazione
```python
async def test_merge_cluster(db, mock_llm):
    obs_a = await insert_obs_with_embedding(db, [0.90]*768, type='directive')
    obs_b = await insert_obs_with_embedding(db, [0.91]*768, type='directive')
    new_id = await merge_cluster([obs_a, obs_b], mock_llm)
    assert new_id is not None
    row_a = await get_obs(db, obs_a)
    assert row_a['distilled_into'] == new_id

async def test_distillation_idempotent(db, mock_llm):
    await run_distillation(db, project_id, mock_llm)
    count1 = await count_active_obs(db, project_id)
    await run_distillation(db, project_id, mock_llm)
    count2 = await count_active_obs(db, project_id)
    assert count1 == count2

async def test_vocab_extraction_in_distillation(db, mock_llm_vocab):
    await insert_obs(db, content='Modificato AuthService in api/services/auth.py')
    await run_distillation(db, project_id, mock_llm_vocab)
    vocab = await db.fetchrow(
        "SELECT * FROM vocab_entries WHERE term='TestService' AND project_id=$1", project_id
    )
    assert vocab is not None
    assert vocab['source'] == 'auto'
    assert vocab['confidence'] == 0.7
```

### Fase 6 — Compressione History
```python
async def test_compress_saves_context_obs(client, db, auth):
    messages = [{"role":"user","content":f"msg {i}"} for i in range(30)]
    r = await client.post(f"/api/v1/sessions/{session_id}/compress",
                          json={"messages":messages, "project":"test"}, headers=auth)
    assert r.status_code == 202
    summary_id = r.json()['summary_obs_id']
    obs = await get_obs(db, summary_id)
    assert obs['type'] == 'context'
    assert 'session-summary' in obs['tags']
    assert r.json()['tokens_saved'] > 0
```

### Fase 7 — Plugin (vitest)
```typescript
test('manifest differenziale usa cache su 304', async () => {
  const server = createMockServer({
    'GET /api/v1/manifest': { status: 304 }  // simula 304
  })
  const result = await fetchManifestDifferential(client, 'test', 3000)
  // Deve usare la cache locale salvata precedentemente
  expect(result).toContain('## Contesto')
  server.close()
})

test('PostToolUse non si blocca su server lento', async () => {
  const server = createSlowServer(5000)  // risponde dopo 5s
  const start = Date.now()
  await onPostToolUse('Write', { file_path: 'test.ts' }, { result: 'ok' }, 'sess1')
  expect(Date.now() - start).toBeLessThan(4000)  // timeout 3s hard
  server.close()
})

test('buffer flush al SessionStart successivo', async () => {
  // Simula server offline → 5 tool use → server online → SessionStart
  const server = createOfflineServer()
  for (let i = 0; i < 5; i++) {
    await onPostToolUse('Write', { file_path: `file${i}.ts` }, {}, 'sess1')
  }
  server.goOnline()
  await onSessionStart()
  // Verifica che il buffer sia stato svuotato
  const bufferLines = await countBufferLines()
  expect(bufferLines).toBe(0)
})
```

---

## Comandi

```bash
make test                    # tutti i test
make test-unit               # veloci (no containers)
make test-integration        # con testcontainers
cd api && pytest tests/ -v --cov=app
cd plugin && npm test
cd plugin && npm run test:watch
```

## Coverage Minima

| Componente | Target |
|---|---|
| api/services/ | 80% |
| api/routers/ | 70% |
| api/workers/ | 75% |
| plugin/hooks/ | 85% |
| plugin/client.ts | 90% |
| plugin/buffer.ts | 90% |
| plugin/compressor.ts | 80% |
