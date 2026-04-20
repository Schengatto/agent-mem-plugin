#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# MemoryMesh — init-roles.sh
# ═══════════════════════════════════════════════════════════════════════════
#
# Eseguito PRIMA di init-db.sql (ordine alfabetico in
# /docker-entrypoint-initdb.d/). Crea i 4 DB user applicativi con password
# dalle env var del container (MM_API_PASSWORD, MM_WORKER_PASSWORD,
# MM_ADMIN_PASSWORD settate dal docker-compose.yml; mm_retention non ha password).
#
# Approccio: le variabili psql (`:'var'`) non vengono sostituite all'interno
# di dollar-quoted strings ($roles$...$roles$), quindi NON si può usare
# `:'mm_api_password'` dentro EXECUTE format(...). Usiamo invece sostituzione
# bash con quote-escape SQL (raddoppio dell'apice singolo) prima di passare
# il comando a psql. ON_ERROR_STOP=1 garantisce il fail-fast.
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Validazione env (fail-fast con messaggio chiaro)
: "${MM_API_PASSWORD:?ERROR: MM_API_PASSWORD non settato nel container}"
: "${MM_WORKER_PASSWORD:?ERROR: MM_WORKER_PASSWORD non settato nel container}"
: "${MM_ADMIN_PASSWORD:?ERROR: MM_ADMIN_PASSWORD non settato nel container}"

echo "══════════════════════════════════════════════════════"
echo "MemoryMesh: creating DB roles"
echo "══════════════════════════════════════════════════════"

# Escape SQL literal: raddoppia l'apice singolo (RFC SQL-92).
sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

API_PASS_Q="$(sql_quote "$MM_API_PASSWORD")"
WORKER_PASS_Q="$(sql_quote "$MM_WORKER_PASSWORD")"
ADMIN_PASS_Q="$(sql_quote "$MM_ADMIN_PASSWORD")"

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
-- ─── mm_api (data plane operativo) ──────────────────────────────────
DO \$roles\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_api') THEN
        EXECUTE 'CREATE ROLE mm_api WITH LOGIN PASSWORD ''${API_PASS_Q}''';
    ELSE
        EXECUTE 'ALTER ROLE mm_api WITH LOGIN PASSWORD ''${API_PASS_Q}''';
    END IF;
END
\$roles\$;

-- ─── mm_worker (embedding + distillation workers) ───────────────────
DO \$roles\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_worker') THEN
        EXECUTE 'CREATE ROLE mm_worker WITH LOGIN PASSWORD ''${WORKER_PASS_Q}''';
    ELSE
        EXECUTE 'ALTER ROLE mm_worker WITH LOGIN PASSWORD ''${WORKER_PASS_Q}''';
    END IF;
END
\$roles\$;

-- ─── mm_admin (admin plane) ─────────────────────────────────────────
DO \$roles\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_admin') THEN
        EXECUTE 'CREATE ROLE mm_admin WITH LOGIN PASSWORD ''${ADMIN_PASS_Q}''';
    ELSE
        EXECUTE 'ALTER ROLE mm_admin WITH LOGIN PASSWORD ''${ADMIN_PASS_Q}''';
    END IF;
END
\$roles\$;

-- ─── mm_retention (job audit retention, no password login) ─────────
DO \$roles\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_retention') THEN
        CREATE ROLE mm_retention WITH LOGIN PASSWORD NULL;
    END IF;
END
\$roles\$;

\echo '  ✓ Roles ready: mm_api, mm_worker, mm_admin, mm_retention'
SQL

echo "══════════════════════════════════════════════════════"
echo "MemoryMesh: roles created, continuing with init-db.sql"
echo "══════════════════════════════════════════════════════"
