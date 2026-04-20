#!/usr/bin/env bash
# MemoryMesh — postgres + pgvector smoke test (F1-03)
#
# Avvia il servizio `postgres` via docker compose, attende che diventi healthy,
# verifica:
#   1. extensions `vector` e `pgcrypto` installate
#   2. i 4 ruoli applicativi creati (mm_api, mm_worker, mm_admin, mm_retention)
#   3. default privileges configurate
#   4. REVOKE su PUBLIC applicata
#   5. ruoli applicativi possono CONNECT al DB
#
# Al termine (successo o fallimento) spegne postgres e rimuove il volume.
# Richiede: docker daemon attivo, `docker compose` v2.
#
# Invocato da:
#   - make postgres-check  (sviluppatore locale, richiede Docker Desktop attivo)
#   - .github/workflows/ci.yml  (CI su push/PR, job separato)

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail() { red "FAIL: $*"; cleanup; exit 1; }
pass() { green "PASS: $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── Env CI-safe ──────────────────────────────────────────────────────────
ENV_FILE="$(mktemp -t mm-ci-pg.XXXXXX)"
cp .env.example "$ENV_FILE"
sed -i \
  -e 's/^PG_ADMIN_PASSWORD=.*/PG_ADMIN_PASSWORD=ci_admin_pw/' \
  -e 's/^PG_MM_API_PASSWORD=.*/PG_MM_API_PASSWORD=ci_api_pw/' \
  -e 's/^PG_MM_WORKER_PASSWORD=.*/PG_MM_WORKER_PASSWORD=ci_worker_pw/' \
  -e 's/^PG_MM_ADMIN_PASSWORD=.*/PG_MM_ADMIN_PASSWORD=ci_admin_mm_pw/' \
  -e 's/^REDIS_PASSWORD=.*/REDIS_PASSWORD=ci_redis_pw/' \
  -e 's/^SECRET_KEY=.*/SECRET_KEY=ci-placeholder-64hex-0000000000000000000000000000000000000000000000000000000000/' \
  "$ENV_FILE"

COMPOSE="docker compose --env-file $ENV_FILE -f docker-compose.yml"

cleanup() {
  blue "──▶ Teardown postgres"
  $COMPOSE down -v postgres 2>/dev/null || true
  $COMPOSE down -v 2>/dev/null || true
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

# ─── 1. Boot postgres only ────────────────────────────────────────────────
blue "──▶ docker compose up -d postgres"
$COMPOSE up -d postgres

# ─── 2. Wait for healthy (max 90s) ────────────────────────────────────────
blue "──▶ Attesa healthy (max 90s)"
deadline=$((SECONDS + 90))
while :; do
  status="$($COMPOSE ps --format json postgres 2>/dev/null \
    | python3 -c 'import json,sys
data=sys.stdin.read().strip()
if not data: print("unknown"); sys.exit(0)
for line in data.splitlines():
    try:
        obj=json.loads(line)
        print(obj.get("Health","unknown")); break
    except Exception: pass
' 2>/dev/null || echo "unknown")"
  case "$status" in
    healthy) break ;;
    unhealthy) fail "postgres healthcheck=unhealthy" ;;
  esac
  if [[ $SECONDS -ge $deadline ]]; then
    $COMPOSE logs --tail=40 postgres || true
    fail "timeout (90s) attendendo postgres healthy — ultimo stato: $status"
  fi
  sleep 2
done
pass "postgres healthy"

# Shortcut: psql come superuser sul DB target
psql_super() { $COMPOSE exec -T postgres psql -U postgres -d memorymesh -tAq -c "$1"; }

# ─── 3. Extensions ────────────────────────────────────────────────────────
blue "──▶ Verifica extensions"
exts="$(psql_super "SELECT extname FROM pg_extension ORDER BY extname;")"
echo "$exts" | grep -qx vector     || fail "extension 'vector' non installata"
echo "$exts" | grep -qx pgcrypto   || fail "extension 'pgcrypto' non installata"
pass "extensions vector + pgcrypto installate"

# Verifica anche che la versione pgvector sia >= 0.8 (richiesto da CVE-2026-3172)
pgv_version="$(psql_super "SELECT extversion FROM pg_extension WHERE extname='vector';")"
if [[ -z "$pgv_version" ]]; then
  fail "impossibile leggere versione pgvector"
fi
# Confronto versionale semplice (pgvector usa pattern MAJOR.MINOR[.PATCH])
major="${pgv_version%%.*}"
rest="${pgv_version#*.}"; minor="${rest%%.*}"
if [[ "$major" -lt 0 ]] || { [[ "$major" -eq 0 ]] && [[ "$minor" -lt 8 ]]; }; then
  fail "pgvector $pgv_version < 0.8 (richiesto: CVE-2026-3172 fix parallel HNSW)"
fi
pass "pgvector $pgv_version (>= 0.8)"

# ─── 4. Ruoli applicativi ─────────────────────────────────────────────────
blue "──▶ Verifica ruoli applicativi"
roles="$(psql_super "SELECT rolname FROM pg_roles WHERE rolname LIKE 'mm_%' ORDER BY rolname;")"
for expected in mm_admin mm_api mm_retention mm_worker; do
  echo "$roles" | grep -qx "$expected" || fail "ruolo '$expected' non creato"
done
pass "ruoli mm_api/mm_worker/mm_admin/mm_retention creati"

# ─── 5. REVOKE PUBLIC ─────────────────────────────────────────────────────
blue "──▶ Verifica REVOKE PUBLIC"
# Dopo REVOKE ALL ON DATABASE memorymesh FROM PUBLIC: has_database_privilege su PUBLIC deve essere false
pub_connect="$(psql_super "SELECT has_database_privilege('public','memorymesh','CONNECT');")"
[[ "$pub_connect" == "f" ]] || fail "PUBLIC ha ancora CONNECT su memorymesh (REVOKE non applicata)"
pass "PUBLIC non può CONNECT a memorymesh"

# ─── 6. CONNECT come utenti applicativi ───────────────────────────────────
blue "──▶ Verifica CONNECT come utenti applicativi"
test_connect() {
  local user="$1" pw="$2"
  $COMPOSE exec -T -e PGPASSWORD="$pw" postgres \
    psql -h localhost -U "$user" -d memorymesh -tAq -c "SELECT 1;" > /dev/null \
    || fail "login con '$user' fallito"
}
test_connect mm_api      ci_api_pw
test_connect mm_worker   ci_worker_pw
test_connect mm_admin    ci_admin_mm_pw
pass "mm_api/mm_worker/mm_admin possono CONNECT a memorymesh"

# ─── 7. Default privileges ────────────────────────────────────────────────
blue "──▶ Verifica default privileges"
# Crea una tabella di prova come postgres, poi verifica i grant automatici.
psql_super "DROP TABLE IF EXISTS _mm_test_dp;"
psql_super "CREATE TABLE _mm_test_dp (id int);"
# mm_api deve avere INSERT
api_has_insert="$(psql_super "SELECT has_table_privilege('mm_api','_mm_test_dp','INSERT');")"
[[ "$api_has_insert" == "t" ]] || fail "mm_api non ha INSERT su tabelle nuove (default privileges mancanti)"
# mm_admin deve avere DELETE
admin_has_delete="$(psql_super "SELECT has_table_privilege('mm_admin','_mm_test_dp','DELETE');")"
[[ "$admin_has_delete" == "t" ]] || fail "mm_admin non ha DELETE su tabelle nuove"
psql_super "DROP TABLE _mm_test_dp;"
pass "default privileges applicate su tabelle nuove"

blue "──▶ Tutti i check F1-03 superati."
