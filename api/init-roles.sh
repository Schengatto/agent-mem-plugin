#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# MemoryMesh — init-roles.sh
# ═══════════════════════════════════════════════════════════════════════════
#
# Eseguito PRIMA di init-db.sql (ordine alfabetico in
# /docker-entrypoint-initdb.d/). Crea i 3 DB user applicativi con password
# dalle env var del container (MM_API_PASSWORD, MM_WORKER_PASSWORD,
# MM_ADMIN_PASSWORD settate dal docker-compose.yml).
#
# Le password sono passate a psql via `-v` (safe, no interpolation shell-level
# nel SQL). Non finiscono nel log perché psql non loga le `\set` variables.
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Validazione env (fail-fast con messaggio chiaro)
: "${MM_API_PASSWORD:?ERROR: MM_API_PASSWORD non settato nel container}"
: "${MM_WORKER_PASSWORD:?ERROR: MM_WORKER_PASSWORD non settato nel container}"
: "${MM_ADMIN_PASSWORD:?ERROR: MM_ADMIN_PASSWORD non settato nel container}"

echo "══════════════════════════════════════════════════════"
echo "MemoryMesh: creating DB roles"
echo "══════════════════════════════════════════════════════"

psql -v ON_ERROR_STOP=1 \
     -v mm_api_password="$MM_API_PASSWORD" \
     -v mm_worker_password="$MM_WORKER_PASSWORD" \
     -v mm_admin_password="$MM_ADMIN_PASSWORD" \
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<-EOSQL

    -- ─── mm_api (data plane operativo) ──────────────────────────────────
    DO \$roles\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_api') THEN
            EXECUTE format('CREATE ROLE mm_api WITH LOGIN PASSWORD %L', :'mm_api_password');
        ELSE
            EXECUTE format('ALTER ROLE mm_api WITH LOGIN PASSWORD %L', :'mm_api_password');
        END IF;
    END \$roles\$;

    -- ─── mm_worker (embedding + distillation workers) ───────────────────
    DO \$roles\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_worker') THEN
            EXECUTE format('CREATE ROLE mm_worker WITH LOGIN PASSWORD %L', :'mm_worker_password');
        ELSE
            EXECUTE format('ALTER ROLE mm_worker WITH LOGIN PASSWORD %L', :'mm_worker_password');
        END IF;
    END \$roles\$;

    -- ─── mm_admin (admin plane) ─────────────────────────────────────────
    DO \$roles\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_admin') THEN
            EXECUTE format('CREATE ROLE mm_admin WITH LOGIN PASSWORD %L', :'mm_admin_password');
        ELSE
            EXECUTE format('ALTER ROLE mm_admin WITH LOGIN PASSWORD %L', :'mm_admin_password');
        END IF;
    END \$roles\$;

    -- ─── mm_retention (job audit retention, login NULL = no password auth) ─
    DO \$roles\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='mm_retention') THEN
            CREATE ROLE mm_retention WITH LOGIN PASSWORD NULL;
        END IF;
    END \$roles\$;

    \echo '  ✓ Roles ready: mm_api, mm_worker, mm_admin, mm_retention'
EOSQL

echo "══════════════════════════════════════════════════════"
echo "MemoryMesh: roles created, continuing with init-db.sql"
echo "══════════════════════════════════════════════════════"
