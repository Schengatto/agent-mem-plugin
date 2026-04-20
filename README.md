# MemoryMesh

Sistema di memoria persistente condivisa per agenti AI (Claude Code, Codex,
e qualunque client MCP-compatible). Self-hosted, Docker, LAN-first.
Drop-in replacement MCP-compatible di `claude-mem`, con architettura
agent-agnostic, UI admin con MFA, e ottimizzazione aggressiva dei token
(target −85% vs baseline senza memoria).

> **Status:** pre-alpha. Sprint 1 in corso (infrastruttura). Vedi
> [`docs/TASKS.md`](docs/TASKS.md) per lo stato avanzamento.

## Quickstart

```bash
git clone https://github.com/schengatto/memorymesh.git
cd memorymesh
cp .env.example .env
make secrets-gen >> .env   # genera secret robusti, poi edita .env
make up                    # avvia lo stack completo (postgres, redis, api, caddy)
open http://mm.local/admin # setup admin: crea password + TOTP
```

Onboarding di un nuovo device (Claude Code o Codex) in ~30 secondi:

```bash
/plugin marketplace add github:schengatto/memorymesh-marketplace
/plugin install memorymesh
# il plugin scopre il server via mDNS, chiede il PIN dall'admin UI, pair fatto
```

Dettagli: [`docs/INSTALL.md`](docs/INSTALL.md).

## Documentazione

L'entry point per Claude Code è [`CLAUDE.md`](CLAUDE.md). I file di contesto
vivono sotto [`docs/`](docs/):

| Area | File |
|------|------|
| Piano & milestone | [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md), [`docs/TASKS.md`](docs/TASKS.md) |
| Architettura & schema DB | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| API | [`docs/API_SPEC.md`](docs/API_SPEC.md) |
| Plugin Claude Code | [`docs/PLUGIN.md`](docs/PLUGIN.md) |
| Adapter Codex | [`docs/CODEX.md`](docs/CODEX.md) |
| UI Admin | [`docs/UI_ADMIN.md`](docs/UI_ADMIN.md) |
| Security | [`docs/SECURITY.md`](docs/SECURITY.md) |
| Token optimization | [`docs/TOKEN_OPT.md`](docs/TOKEN_OPT.md) |
| Install end-user | [`docs/INSTALL.md`](docs/INSTALL.md) |
| Convenzioni codice | [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) |
| Dipendenze & ADR | [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md) |

## Stack

Python 3.14 · FastAPI · PostgreSQL 18 + pgvector · Redis 8 · Nuxt 4 ·
Caddy · Docker Compose. LLM/embed provider-agnostic (default Gemini, opt-in
Ollama per profile privacy-strict). Vedi
[`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md) per ADR e versioni.

## Licenza

[Apache License 2.0](LICENSE).
