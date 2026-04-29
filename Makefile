# MemoryMesh — Makefile
#
# Per help: `make` oppure `make help`

SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: help

# ─── Config ────────────────────────────────────────────────────────────────
COMPOSE := docker compose
COMPOSE_PROD := docker compose -f docker-compose.yml -f docker-compose.prod.yml

# Carica .env se esiste (utile per target che non passano da compose)
-include .env
export

# Detect profile (lan default)
PROFILE ?= lan

# ═══════════════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════════════

help: ## Mostra questo help
	@echo ""
	@echo "MemoryMesh — Makefile targets"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Profile attuale: $(MEMORYMESH_DEPLOYMENT)"
	@echo ""

# ═══════════════════════════════════════════════════════════════════════════
# SETUP & RUN
# ═══════════════════════════════════════════════════════════════════════════

.PHONY: secrets-gen
secrets-gen: ## Genera secret robusti per .env (da copiare manualmente)
	@echo "# Copia questi valori nel tuo .env"
	@echo ""
	@echo "SECRET_KEY=$$(openssl rand -hex 32)"
	@echo "PG_ADMIN_PASSWORD=$$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
	@echo "PG_MM_API_PASSWORD=$$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
	@echo "PG_MM_WORKER_PASSWORD=$$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
	@echo "PG_MM_ADMIN_PASSWORD=$$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
	@echo "REDIS_PASSWORD=$$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"

.PHONY: up
up: .env ## Avvia tutto lo stack (LAN default)
	@$(COMPOSE) --profile lan up -d
	@echo ""
	@echo "✓ Stack avviato. Attendere health check (~60s al primo avvio)."
	@echo "  Status:  make ps"
	@echo "  Logs:    make logs"
	@echo "  Admin UI: http://$(MEMORYMESH_HOSTNAME)/admin/"

.PHONY: up-prod
up-prod: .env ## Avvia stack in modalità PROD (vpn/public, richiede MEMORYMESH_HOSTNAME e ADMIN_EMAIL)
	@test -n "$(MEMORYMESH_HOSTNAME)" || (echo "ERROR: MEMORYMESH_HOSTNAME non settato"; exit 1)
	@test -n "$(ADMIN_EMAIL)" || (echo "ERROR: ADMIN_EMAIL non settato"; exit 1)
	@$(COMPOSE_PROD) up -d
	@echo ""
	@echo "✓ Stack PROD avviato su https://$(MEMORYMESH_HOSTNAME)/"

.PHONY: down
down: ## Spegne lo stack (volumi preservati)
	@$(COMPOSE) down

.PHONY: down-prod
down-prod: ## Spegne lo stack PROD
	@$(COMPOSE_PROD) down

.PHONY: restart
restart: down up ## Restart completo

.PHONY: restart-api
restart-api: ## Restart solo api + worker (utile dopo cambio codice)
	@$(COMPOSE) restart api embed-worker distillation-worker

.PHONY: compose-check
compose-check: ## Valida docker-compose (syntax + servizi + healthcheck)
	@bash scripts/test-compose.sh

.PHONY: postgres-check
postgres-check: ## Smoke test postgres+pgvector (boot, extensions, ruoli, grants)
	@bash scripts/test-postgres.sh

.PHONY: redis-check
redis-check: ## Smoke test Redis Streams (XGROUP CREATE, XADD, XREADGROUP, XACK, DLQ)
	@bash scripts/test-redis-streams.sh

.PHONY: ollama-check
ollama-check: ## Smoke test Ollama (profile opt-in, env hardening, ollama list, dry-run pull)
	@bash scripts/test-ollama.sh

.PHONY: caddy-check
caddy-check: ## Smoke test Caddy (validate LAN+prod, routing, security headers)
	@bash scripts/test-caddy.sh

.PHONY: mdns-check
mdns-check: ## Smoke test mDNS broadcaster (avahi XML + Python zeroconf roundtrip)
	@bash scripts/test-mdns.sh

# ═══════════════════════════════════════════════════════════════════════════
# INSPECTION
# ═══════════════════════════════════════════════════════════════════════════

.PHONY: ps
ps: ## Lista dei servizi con status
	@$(COMPOSE) ps

.PHONY: logs
logs: ## Follow logs di tutti i servizi
	@$(COMPOSE) logs -f --tail=100

.PHONY: logs-api
logs-api: ## Follow logs solo del servizio api
	@$(COMPOSE) logs -f --tail=200 api

.PHONY: logs-distill
logs-distill: ## Follow logs distillation worker
	@$(COMPOSE) logs -f --tail=200 distillation-worker

.PHONY: health
health: ## Check health di tutti i servizi
	@echo "Postgres:" && $(COMPOSE) exec -T postgres pg_isready -U $(PG_ADMIN_USER) -d memorymesh
	@echo "Redis:"    && $(COMPOSE) exec -T redis redis-cli --no-auth-warning -a $(REDIS_PASSWORD) ping
	@echo "Ollama:"   && $(COMPOSE) exec -T ollama ollama list
	@echo "API:"      && curl -sf http://localhost:$(CADDY_HTTP_PORT)/health && echo ""

# ═══════════════════════════════════════════════════════════════════════════
# DATABASE
# ═══════════════════════════════════════════════════════════════════════════

.PHONY: db-shell
db-shell: ## psql interattivo come mm_admin
	@$(COMPOSE) exec postgres psql -U mm_admin -d memorymesh

.PHONY: db-shell-super
db-shell-super: ## psql come superuser (per troubleshooting)
	@$(COMPOSE) exec postgres psql -U $(PG_ADMIN_USER) -d memorymesh

.PHONY: redis-shell
redis-shell: ## redis-cli interattivo (autenticato)
	@$(COMPOSE) exec redis redis-cli -a $(REDIS_PASSWORD)

.PHONY: migrate
migrate: ## Applica le migrazioni Alembic (via api container, mm_admin)
	@$(COMPOSE) exec -w /app -e DATABASE_ADMIN_URL=$${DATABASE_ADMIN_URL} api alembic upgrade head

.PHONY: migrate-down
migrate-down: ## Alembic downgrade (make migrate-down REV=<base|-1|0001>)
	@test -n "$(REV)" || (echo "Usage: make migrate-down REV=<base|-1|0001>"; exit 1)
	@$(COMPOSE) exec -w /app -e DATABASE_ADMIN_URL=$${DATABASE_ADMIN_URL} api alembic downgrade $(REV)

.PHONY: migrate-create
migrate-create: ## Crea una nuova migrazione (usa: make migrate-create MSG="add foo")
	@test -n "$(MSG)" || (echo "Usage: make migrate-create MSG=\"description\""; exit 1)
	@$(COMPOSE) exec -w /app api alembic revision --autogenerate -m "$(MSG)"

.PHONY: migrate-check
migrate-check: ## Alembic smoke test completo F1-04 (boot postgres, upgrade, verify, downgrade)
	@bash scripts/test-alembic.sh

.PHONY: backup
backup: ## pg_dump | gzip | age → backups/backup-YYYY-MM-DD-HHMM.sql.gz.enc (F1-08)
	@bash scripts/backup-pg.sh

.PHONY: restore
restore: ## Restore da backup cifrato (make restore BACKUP=backups/foo.sql.gz.enc)
	@test -n "$(BACKUP)" || (echo "Usage: make restore BACKUP=backups/foo.sql.gz.enc"; exit 1)
	@echo "⚠ ATTENZIONE: questo sovrascriverà il DB corrente. Continua? [y/N]"; \
	 read -r resp; test "$$resp" = "y" || exit 1
	@FILE=$(BACKUP) bash scripts/restore-pg.sh

.PHONY: backup-check
backup-check: ## Smoke test backup/restore roundtrip (pg_dump | gzip | age → encrypted → age -d | gunzip | psql)
	@bash scripts/test-backup.sh

# ═══════════════════════════════════════════════════════════════════════════
# OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════

.PHONY: distill
distill: ## Trigger manuale della distillazione (dev/debug)
	@$(COMPOSE) exec api python -m app.cli distill --project=$${PROJECT:-default}

.PHONY: vocab-dump
vocab-dump: ## Dump del vocabolario di un progetto (VAR: PROJECT)
	@test -n "$(PROJECT)" || (echo "Usage: make vocab-dump PROJECT=my-app"; exit 1)
	@$(COMPOSE) exec api python -m app.cli vocab-dump --project=$(PROJECT)

.PHONY: ollama-pull
ollama-pull: ## Pull idempotente dei modelli Ollama (nomic-embed + Qwen3)
	@bash scripts/ollama-pull.sh

# ═══════════════════════════════════════════════════════════════════════════
# BUILD
# ═══════════════════════════════════════════════════════════════════════════

.PHONY: ui-dev
ui-dev: ## Avvia Nuxt dev server (proxy → api)
	@cd ui && pnpm install && pnpm dev

.PHONY: ui-build
ui-build: ## Build produzione SPA Nuxt e copia in api/app/static
	@cd ui && pnpm install && pnpm generate
	@rm -rf api/app/static
	@cp -r ui/.output/public api/app/static
	@echo "✓ UI build copiata in api/app/static"

.PHONY: build
build: ui-build ## Build completo (UI + container image)
	@$(COMPOSE) build --pull

.PHONY: release
release: ## Bump version + tag git (usa: make release VERSION=1.0.0)
	@test -n "$(VERSION)" || (echo "Usage: make release VERSION=1.0.0"; exit 1)
	@echo "Creating release v$(VERSION)..."
	@echo "VERSION=$(VERSION)" > .env.release
	@git tag -s "v$(VERSION)" -m "Release v$(VERSION)"
	@git push origin "v$(VERSION)"
	@echo "✓ Tag v$(VERSION) pushato. GitHub Actions procederà con build + marketplace update."

# ═══════════════════════════════════════════════════════════════════════════
# TEST
# ═══════════════════════════════════════════════════════════════════════════

.PHONY: test
test: test-api test-plugin test-ui ## Tutti i test

.PHONY: test-api
test-api: ## Test Python API (pytest + testcontainers)
	@$(COMPOSE) exec api pytest app/tests -v

.PHONY: test-plugin
test-plugin: ## Test TypeScript plugin (vitest)
	@cd plugin && pnpm test

.PHONY: test-ui
test-ui: ## Test E2E UI (Playwright)
	@cd ui && pnpm test:e2e

# ═══════════════════════════════════════════════════════════════════════════
# SECURITY
# ═══════════════════════════════════════════════════════════════════════════

.PHONY: lint-security
lint-security: audit-python audit-node scan-image scan-secrets ## Tutti gli scan security

.PHONY: audit-python
audit-python: ## pip-audit (CVE Python)
	@$(COMPOSE) exec api pip-audit --strict

.PHONY: audit-node
audit-node: ## npm audit (CVE TypeScript + UI)
	@cd plugin && pnpm audit --audit-level=high --prod
	@cd ui && pnpm audit --audit-level=high --prod

.PHONY: scan-image
scan-image: ## trivy scan image memorymesh/api
	@trivy image --severity CRITICAL,HIGH --exit-code 1 memorymesh/api:$${VERSION:-dev}

.PHONY: scan-secrets
scan-secrets: ## gitleaks scan repo per secret committati
	@gitleaks detect --source . --no-git || (echo "ERROR: secret detected in working tree"; exit 1)
	@gitleaks detect --source . || (echo "ERROR: secret detected in git history"; exit 1)

# ═══════════════════════════════════════════════════════════════════════════
# INTERNAL
# ═══════════════════════════════════════════════════════════════════════════

.env:
	@echo "ERROR: .env non trovato."
	@echo "Esegui: cp .env.example .env && make secrets-gen >> .env"
	@echo "Poi edita .env per completare i valori."
	@exit 1
