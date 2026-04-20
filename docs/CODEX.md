# Adapter Codex — Specifica Completa

> Leggi questo file prima di lavorare sui task F7b-01..F7b-09.
> Complementare a `PLUGIN.md` (struttura monorepo e adapter Claude Code).

## Perché un Adapter Dedicato

Codex (CLI OpenAI) è già MCP-capable: i tool `search`, `vocab_lookup`,
`get_observations`, ecc. funzionano automaticamente registrando il server
FastAPI come MCP server in `~/.codex/config.toml`. Questo copre il **tier A**
(retrieval on-demand).

Ciò che Codex NON ha nativamente, rispetto a Claude Code:
- Hook `SessionStart`, `UserPromptSubmit`, `PostToolUse` (impossibile l'iniezione
  proattiva di manifest + vocab turn-by-turn)
- Accesso agli header runtime per telemetria cache (deve essere parsato dai log)
- Trigger in-session per history compression

L'adapter Codex sopperisce con **due CLI out-of-band** + **injection via
AGENTS.md** (che Codex legge automaticamente all'avvio).

---

## Tier di Compatibilità

```
                       Claude Code   Codex CLI
  MCP retrieve tools       ✅            ✅          (zero work, server-side)
  Manifest+vocab inject    ✅ hook       ✅ AGENTS.md (via codex-prep)
  Tool capture             ✅ hook       ⚠ post-session (transcript parse)
  History compression      ✅ in-turn    ❌ (cross-session only)
  Delta manifest intra     ✅            ❌ (refresh per launch)
  Prompt caching           ✅ Anthropic  ⚠ OpenAI automatic
  Telemetry cache hits     ✅ header     ⚠ log parsing
```

Guadagno token atteso con Codex: **-70%** (vs -85% su Claude Code).
Le strategie architetturali (1-2, 8-15, 17-18) valgono comunque; si perde
solo quella dell'history compression in-session.

---

## Flusso Operativo

```
Utente lancia 'cx <args>'  (shell wrapper fornito dall'installer)
  │
  ├─ [PRE]  memorymesh codex-prep --cwd $PWD --project $(detect)
  │         ├─ Scope detection da cwd → ['api','routers'] → '/api/routers'
  │         ├─ GET /api/v1/agents-md?project=X&scope_prefix=/api/routers
  │         │   → riceve Markdown già formattato cache-stable
  │         │   → ETag check: se 304, legge file .memorymesh/INJECT.md locale
  │         ├─ Scrive .memorymesh/INJECT.md al project root
  │         └─ Aggiorna AGENTS.md (idempotente, vedi §AGENTS.md Merge)
  │
  ├─ [RUN]  codex "$@"
  │         → Codex legge AGENTS.md (include INJECT.md marker)
  │         → Prefisso cache-stable presente nel system prompt
  │         → MCP tools disponibili per vocab_lookup, search, ecc.
  │
  └─ [POST] memorymesh codex-capture --cwd $PWD --session-id $CODEX_SESSION_ID
            ├─ Legge ~/.codex/sessions/{id}.json (transcript)
            ├─ Estrae tool use: Edit, Write, Bash, WebFetch
            ├─ Per ciascuno: derive scope + tiktoken + capping → POST /observations
            ├─ Estrae tool_sequence per fingerprint aggregation
            ├─ Se transcript > compress threshold: POST /sessions/{id}/compress
            └─ POST /metrics/session con stima token (dai log Codex)
```

**Latenza utente percepita:**
- `codex-prep` < 300ms (ETag → cache hit tipica)
- `codex-capture` < 1s, eseguito in background con `&`, non blocca lo shell
- Prompt di Codex: invariato rispetto a setup stock

---

## AGENTS.md Merge (idempotente)

Il file `AGENTS.md` appartiene all'utente: può contenere istruzioni custom,
riferimenti a sotto-file, direttive di progetto. L'adapter **non lo
sovrascrive**: inserisce SOLO una sezione delimitata da marker.

```markdown
# AGENTS.md (esempio progetto utente)

Usa sempre TypeScript strict mode. Preferisci Vitest a Jest.

<!-- @memorymesh:begin -->
@import .memorymesh/INJECT.md
<!-- @memorymesh:end -->

## Convenzioni progetto
...
```

Algoritmo merge in `agents-md.ts`:

```typescript
const MARKER_BEGIN = '<!-- @memorymesh:begin -->'
const MARKER_END   = '<!-- @memorymesh:end -->'

export async function mergeAgentsMd(
  projectRoot: string,
  injectBlock: string
): Promise<void> {
  const file = path.join(projectRoot, 'AGENTS.md')
  let content = ''
  try { content = await fs.readFile(file, 'utf-8') } catch { /* nuovo file */ }

  const startIdx = content.indexOf(MARKER_BEGIN)
  const endIdx   = content.indexOf(MARKER_END)

  if (startIdx !== -1 && endIdx !== -1) {
    // Marker esistenti: sostituisci solo la sezione fra di loro
    const before = content.slice(0, startIdx)
    const after  = content.slice(endIdx + MARKER_END.length)
    content = `${before}${MARKER_BEGIN}\n${injectBlock}\n${MARKER_END}${after}`
  } else {
    // Nessun marker: append in coda (preservando l'esistente)
    const separator = content.endsWith('\n\n') ? '' : (content ? '\n\n' : '')
    content = `${content}${separator}${MARKER_BEGIN}\n${injectBlock}\n${MARKER_END}\n`
  }

  await fs.writeFile(file, content, 'utf-8')
}
```

**Regola:** se l'utente rimuove i marker manualmente, l'adapter ri-appende in
coda al prossimo run. Se preferisce disabilitare l'injection: `rm .memorymesh/`
o flag `MEMORYMESH_CODEX_INJECT=false`.

---

## INJECT.md Structure

File scritto dall'adapter a `.memorymesh/INJECT.md`. Letto da AGENTS.md via
`@import` (convenzione Codex) o concatenato direttamente (fallback).

```markdown
<!-- MemoryMesh auto-generated. Do not edit manually.
     Regenerated by 'memorymesh codex-prep' before each launch.
     Cache-stable prefix for OpenAI prompt caching. -->

<!-- @memorymesh:begin cache-stable -->
## Vocabolario (28 termini, 18 con shortcode)
[entity] $AS|AuthService=api/services/auth.py·JWT·deps:$UR,Redis
...

## Contesto Root (18 memorie)
- [identity] Senior dev, TypeScript strict, Neovim (#12)
...
<!-- @memorymesh:end cache-stable -->

<!-- @memorymesh:begin volatile -->
## Contesto Scope: api/routers (7 memorie)
- [context] PG16 migration — in corso (#91, 6h fa)
...
<!-- @memorymesh:end volatile -->
```

Il contenuto **è ottenuto direttamente da `GET /api/v1/agents-md`** — l'adapter
non lo riformatta, pass-through fedele (stessa regola del Claude Code adapter
con `/manifest`).

---

## Transcript Parser

Codex salva le sessioni in `~/.codex/sessions/{session_id}.json` (formato
JSON-lines di turni). Il parser estrae:

```typescript
interface CodexTurn {
  role: 'user' | 'assistant' | 'tool'
  tool_calls?: Array<{ name: string; arguments: any; result?: any }>
  usage?: { prompt_tokens: number; completion_tokens: number; cached_tokens?: number }
}

export async function parseTranscript(sessionPath: string): Promise<{
  toolEvents: ToolEvent[]
  usageTotals: UsageTotals
  sequence: string[]      // per fingerprint aggregation
}> {
  const lines = (await fs.readFile(sessionPath, 'utf-8')).trim().split('\n')
  const turns = lines.map(l => JSON.parse(l) as CodexTurn)

  const toolEvents: ToolEvent[] = []
  const sequence: string[] = []
  let promptSum = 0, completionSum = 0, cachedSum = 0

  for (const t of turns) {
    if (t.tool_calls) {
      for (const tc of t.tool_calls) {
        if (['Edit', 'Write', 'Bash', 'WebFetch'].includes(tc.name)) {
          toolEvents.push({ name: tc.name, input: tc.arguments, output: tc.result })
          sequence.push(tc.name)
        }
      }
    }
    if (t.usage) {
      promptSum += t.usage.prompt_tokens
      completionSum += t.usage.completion_tokens
      cachedSum += t.usage.cached_tokens ?? 0
    }
  }

  return {
    toolEvents,
    usageTotals: { prompt: promptSum, completion: completionSum, cached: cachedSum },
    sequence
  }
}
```

Il formato esatto dei file `~/.codex/sessions/*.json` va verificato sulla
versione corrente di Codex durante F7b-02 (potrebbe essere cambiato).

---

## Installer (`memorymesh install --for codex`)

**Device.json condiviso**: se l'utente ha già fatto pair con Claude Code
(file `~/.memorymesh/device.json` esistente e valido), l'installer Codex
**non prompta** per PIN o URL — riusa tutto. Aggiunge solo config Codex-specific.

```typescript
export async function installCodexAdapter(): Promise<void> {
  console.log('🧠 MemoryMesh — setup Codex adapter')

  // 1. Verifica Codex installato
  if (!await hasCommand('codex')) {
    throw new Error('Codex CLI non trovato. Installa da https://github.com/openai/codex')
  }

  // 2. Cerca device.json esistente (produced dal pair Claude Code o precedente)
  let device = await loadDeviceConfig()
  if (!device || !(await testConnection(device))) {
    // 2a. Prima volta o config stale — esegui pair flow
    console.log('Device non configurato, avvio pair...')
    device = await runPairFlow('codex')  // stesso flow del plugin Claude Code
  } else {
    console.log(`✓ Uso device esistente: ${device.device_name}`)
  }

  // 3. Registra MCP server in ~/.codex/config.toml (MCP tools zero-touch)
  await updateCodexTOML({
    'mcp_servers.memorymesh': {
      type: 'http',
      url: `${device.url}/mcp`,
      headers: { 'X-API-Key': device.api_key }
    }
  })

  // 4. Installa shell wrapper 'cx' in ~/.local/bin
  await installShellWrapper(device)

  // 5. Aggiorna device.json con agent_kind aggiuntivo (per telemetria server-side)
  await fetch(`${device.url}/api/v1/devices/me/agents`, {
    method: 'POST',
    headers: { 'X-API-Key': device.api_key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ add: 'codex' })
  })

  console.log('✅ Adapter Codex installato. Usa "cx" invece di "codex".')
}

async function runPairFlow(agentKind: string): Promise<DeviceConfig> {
  // Riusa esattamente lo stesso flow del plugin Claude Code post-install:
  // mDNS discovery → PIN prompt → POST /api/v1/pair → scrive device.json
  // L'unica differenza: agent_kind = 'codex' nel body del pair
  return (await import('@memorymesh/core/pair')).default({ agentKind })
}
```

Il flow completo per un utente che parte da zero con Codex:

```
$ npm install -g @memorymesh/cli
$ memorymesh install --for codex
🧠 MemoryMesh — setup Codex adapter
Device non configurato, avvio pair...
🔎 Ricerca server MemoryMesh sulla LAN...
✓ Trovato: mm.local (http://mm.local)
Apri http://mm.local/admin/ → Account → Devices → Pair new device
PIN: 123456
Nome device [default: enrico-mbp.local]:
Pair in corso...
✓ Progetto auto-rilevato da git remote: my-app
✅ Adapter Codex installato. Usa "cx" invece di "codex".

$ cx
# Codex parte con AGENTS.md già iniettato + MCP tools attivi
```

Se Claude Code era già paired: skip mDNS + PIN, fanno ~5 secondi di install.

---

## Shell Wrapper (template)

`wrapper.sh.tpl` scritto in `~/.local/bin/cx`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Project detection
PROJECT="${MEMORYMESH_PROJECT:-$(basename "$PWD")}"

# PRE-launch prep (bloccante, max 300ms con ETag)
memorymesh codex-prep --cwd "$PWD" --project "$PROJECT" 2>/dev/null || true

# Lancia Codex
codex "$@"
EXIT_CODE=$?

# POST-launch capture (non-bloccante)
(
  sleep 0.5
  LATEST=$(ls -t "$HOME/.codex/sessions/"*.json 2>/dev/null | head -1 || true)
  if [ -n "$LATEST" ]; then
    memorymesh codex-capture --cwd "$PWD" --project "$PROJECT" \
      --transcript "$LATEST" 2>/dev/null || true
  fi
) &

exit $EXIT_CODE
```

Perché non `trap EXIT`: alcune versioni di `codex` usano signal che interferiscono
con `trap`. Fork+`sleep 0.5` dà margine per il flush del transcript a disco.

---

## Config Env

```
MEMORYMESH_URL                  # già condivisa con Claude Code
MEMORYMESH_API_KEY
MEMORYMESH_PROJECT
MEMORYMESH_PROJECT_ROOT
MEMORYMESH_CODEX_INJECT=true    # default true, disabilita AGENTS.md injection
MEMORYMESH_CODEX_CAPTURE=true   # default true, disabilita transcript parse
MEMORYMESH_CODEX_CAPTURE_BG=true# default true, capture in background
```

---

## Test E2E Richiesti (F7b-09)

1. **MCP tools funzionanti**: in sessione Codex fresca, `search` restituisce
   risultati dal MemoryMesh server.
2. **AGENTS.md injection idempotente**: 3 run consecutive di `codex-prep`
   producono un AGENTS.md byte-per-byte identico.
3. **Marker preservation**: utente aggiunge commenti fuori dai marker →
   sopravvivono al re-run.
4. **ETag cache hit**: 2° `codex-prep` in < 1h → nessuna re-fetch del content
   (304). Verificato via `X-MemoryMesh-Cache-Hit` header.
5. **Scope routing**: cwd in `api/routers` → INJECT.md contiene solo observations
   con scope `api`.
6. **Transcript capture**: sessione Codex con 3 Edit → 3 observation in DB.
7. **Tool sequence**: `tool_sequence` nel DB riflette l'ordine tool del transcript.
8. **Cross-agent consistency**: observation create da Claude Code compaiono in
   Codex AGENTS.md al run successivo.
9. **Compress out-of-band**: sessione Codex con transcript > 8000 token →
   capture triggera `/sessions/{id}/compress`. Summary disponibile dalla sessione
   successiva.
10. **No block**: server spento → `cx` completa senza errori visibili all'utente.
11. **Prompt caching OpenAI**: 2° launch entro 5min → verificare `cached_tokens`
    nel `usage` del transcript > 0.

---

## Differenze Operative vs Claude Code

| Aspetto | Claude Code | Codex |
|---------|-------------|-------|
| Injection | SessionStart hook, inline | AGENTS.md file merge pre-launch |
| Capture | PostToolUse hook, real-time | Transcript parse post-session |
| Delta manifest | Intra-turn via UserPromptSubmit | Solo fra launch successivi |
| History compress trigger | UserPromptSubmit, turn-by-turn | Post-session, se transcript supera soglia |
| Cache metric source | Response header runtime | `usage.cached_tokens` da transcript |
| Telemetry flush | SessionEnd hook | `codex-capture` finale |
| Offline buffer | Plugin buffer jsonl | Shared con core (stesso file) |

---

## Limitazioni Note

- **No observation live**: un Edit fatto a metà sessione Codex non è disponibile
  per search nella stessa sessione. Disponibile dalla sessione successiva.
  Mitigazione: il transcript viene capturato comunque a fine sessione.
- **History compression reattiva, non preventiva**: in Codex la compression
  avviene DOPO la sessione, utile per la successiva, non per quella corrente.
- **Telemetria cache hit meno granulare**: `usage.cached_tokens` aggrega sull'intera
  sessione, non per-turno come su Claude Code.
- **Shortcode richiedono re-launch**: nuovi shortcode assegnati dalla distillazione
  notturna entrano in `AGENTS.md` solo al prossimo `codex-prep`. Accettabile: una
  sessione Codex dura tipicamente < 1h, il delay è minimo.
