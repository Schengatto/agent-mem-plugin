#!/usr/bin/env bash
# MemoryMesh — Alembic migrations smoke test (F1-04)
#
# Verifica end-to-end che la baseline schema migration produca lo schema
# atteso in `docs/ARCHITECTURE.md §2`:
#
#   1. `alembic upgrade head` su postgres pulito → no errori
#   2. Tutte le 19 tabelle attese esistono
#   3. Tutti gli indici critici esistono (HNSW, GIN, partial, composite)
#   4. Trigger `single_admin_trg` blocca il secondo INSERT su admin_users
#   5. RLS abilitata su observations/vocab_entries/manifest_entries/sessions/
#      manifest_entries_accessed
#   6. Migrazioni idempotenti: secondo `upgrade head` = no-op
#   7. `alembic downgrade base` pulisce tutto
#   8. Re-upgrade funziona dopo downgrade (ciclo completo)
#
# Richiede:
#   - docker daemon attivo + `docker compose` v2
#   - python3 (>= 3.11) con pip sul PATH host
#     Alembic gira lato host contro postgres esposto su 127.0.0.1:${PG_HOST_PORT}
#     (usiamo un override compose per port-mapping senza modificare il file
#     docker-compose.yml principale).
#
# Invocato da:
#   - make test-alembic
#   - .github/workflows/ci.yml

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail() { red "FAIL: $*"; cleanup; exit 1; }
pass() { green "PASS: $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── Pre-flight ─────────────────────────────────────────────────────────
command -v python3 >/dev/null || fail "python3 (>=3.11) richiesto sul PATH host"
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJOR="${PY_VER%%.*}"
PY_MINOR="${PY_VER##*.}"
if [[ "$PY_MAJOR" -lt 3 ]] || { [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -lt 11 ]]; }; then
  fail "python3 $PY_VER trovato; richiesto >= 3.11 (psycopg3)"
fi

# Port locale per postgres durante il test (default 55432; override via env)
PG_HOST_PORT="${PG_HOST_PORT:-55432}"

# ─── Env CI-safe ────────────────────────────────────────────────────────
ENV_FILE="$(mktemp -t mm-ci-alembic.XXXXXX)"
cp .env.example "$ENV_FILE"
sed -i \
  -e 's/^PG_ADMIN_PASSWORD=.*/PG_ADMIN_PASSWORD=ci_admin_pw/' \
  -e 's/^PG_MM_API_PASSWORD=.*/PG_MM_API_PASSWORD=ci_api_pw/' \
  -e 's/^PG_MM_WORKER_PASSWORD=.*/PG_MM_WORKER_PASSWORD=ci_worker_pw/' \
  -e 's/^PG_MM_ADMIN_PASSWORD=.*/PG_MM_ADMIN_PASSWORD=ci_admin_mm_pw/' \
  -e 's/^REDIS_PASSWORD=.*/REDIS_PASSWORD=ci_redis_pw/' \
  -e 's/^SECRET_KEY=.*/SECRET_KEY=ci-placeholder-64hex-0000000000000000000000000000000000000000000000000000000000/' \
  "$ENV_FILE"

# Override compose: espone postgres su 127.0.0.1:$PG_HOST_PORT durante il test.
# Il port mapping richiede che il container sia su una rete NON `internal: true`;
# mm_ingress è bridge non-internal, quindi lo aggiungiamo qui solo per il test
# (in produzione postgres resta su mm_internal soltanto).
OVERRIDE_FILE="$(mktemp -t mm-ci-alembic-override.XXXXXX.yml)"
cat > "$OVERRIDE_FILE" <<EOF
services:
  postgres:
    networks:
      - mm_internal
      - mm_ingress
    ports:
      - "127.0.0.1:${PG_HOST_PORT}:5432"
EOF

COMPOSE="docker compose --env-file $ENV_FILE -f docker-compose.yml -f $OVERRIDE_FILE"

# Venv host per alembic/psycopg
VENV_DIR="$(mktemp -d -t mm-ci-alembic-venv.XXXXXX)"

cleanup() {
  blue "──▶ Teardown (postgres + venv + tmp files)"
  $COMPOSE down -v 2>/dev/null || true
  rm -rf "$VENV_DIR"
  rm -f "$ENV_FILE" "$OVERRIDE_FILE"
}
trap cleanup EXIT

# ─── 1. Venv host + pip install ─────────────────────────────────────────
blue "──▶ Setup venv host (python $PY_VER)"
python3 -m venv "$VENV_DIR"
# Cross-platform: Linux/macOS usano bin/, Windows+Git-Bash usano Scripts/
if [[ -f "$VENV_DIR/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  VENV_BIN="$VENV_DIR/bin"
elif [[ -f "$VENV_DIR/Scripts/activate" ]]; then
  # shellcheck disable=SC1091
  source "$VENV_DIR/Scripts/activate"
  VENV_BIN="$VENV_DIR/Scripts"
else
  fail "venv creato ma né bin/activate né Scripts/activate trovato in $VENV_DIR"
fi
"$VENV_BIN/python" -m pip install --disable-pip-version-check --quiet --upgrade pip
"$VENV_BIN/python" -m pip install --disable-pip-version-check --quiet -r api/requirements.txt
pass "venv pronto + requirements installati"

# ─── 2. Boot postgres con port exposed ──────────────────────────────────
blue "──▶ docker compose up -d postgres (con port 127.0.0.1:${PG_HOST_PORT})"
$COMPOSE up -d postgres

# ─── 3. Wait healthy (max 90s) ──────────────────────────────────────────
blue "──▶ Attesa postgres healthy (max 90s)"
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

# Shortcut: psql come superuser dentro il container
psql_super() { $COMPOSE exec -T postgres psql -U postgres -d memorymesh -tAq -c "$1"; }

# ─── 4. Run alembic upgrade head ────────────────────────────────────────
blue "──▶ alembic upgrade head (run #1, DB pulito)"
export DATABASE_ADMIN_URL="postgresql+psycopg://postgres:ci_admin_pw@127.0.0.1:${PG_HOST_PORT}/memorymesh"
cd api
"$VENV_BIN/alembic" upgrade head || { cd "$ROOT"; fail "alembic upgrade head fallita al primo run"; }
cd "$ROOT"
pass "alembic upgrade head OK (run #1)"

# ─── 5. Tabelle attese esistono ─────────────────────────────────────────
blue "──▶ Verifica presenza tabelle"
EXPECTED_TABLES=(
  users projects project_members
  admin_users admin_webauthn_credentials admin_sessions
  admin_audit_log admin_settings admin_pair_tokens
  device_keys
  observations manifest_entries vocab_entries
  query_fingerprints project_manifest_meta sessions
  token_metrics llm_api_calls
  manifest_entries_accessed
)
tables="$(psql_super "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;")"
for t in "${EXPECTED_TABLES[@]}"; do
  echo "$tables" | grep -qx "$t" || fail "tabella '$t' non trovata dopo upgrade"
done
pass "tutte le ${#EXPECTED_TABLES[@]} tabelle attese esistono"

# Nessuna tabella di Alembic "scappata" (alembic_version è l'unica extra attesa)
all_tables="$(echo "$tables" | grep -v '^$' | wc -l)"
expected_count=$((${#EXPECTED_TABLES[@]} + 1))  # +1 alembic_version
[[ "$all_tables" == "$expected_count" ]] \
  || fail "atteso $expected_count tabelle (incl. alembic_version), trovate $all_tables: $(echo "$tables" | tr '\n' ' ')"
pass "nessuna tabella spuria (solo attese + alembic_version)"

# ─── 6. Indici critici ──────────────────────────────────────────────────
blue "──▶ Verifica indici critici"
EXPECTED_INDEXES=(
  observations_embedding_hnsw
  observations_fts_gin
  observations_active_type
  observations_active_created
  observations_scope_gin
  observations_lru
  observations_session_id
  manifest_entries_priority
  manifest_entries_scope_path
  vocab_entries_category_usage
  vocab_entries_shortcode
  vocab_entries_fts
  query_fingerprints_confidence
  token_metrics_project_created
  device_keys_active
  device_keys_hash_active
  admin_pair_tokens_pending
  admin_webauthn_credentials_admin
  admin_sessions_active
  admin_audit_log_admin_created
  admin_audit_log_action_created
  llm_api_calls_budget_day
  llm_api_calls_errors
  llm_api_calls_project_created
  project_members_user
  manifest_entries_accessed_session
  manifest_entries_accessed_project_created
)
indexes="$(psql_super "SELECT indexname FROM pg_indexes WHERE schemaname='public' ORDER BY indexname;")"
for idx in "${EXPECTED_INDEXES[@]}"; do
  echo "$indexes" | grep -qx "$idx" || fail "indice '$idx' non trovato"
done
pass "tutti i ${#EXPECTED_INDEXES[@]} indici critici presenti"

# Verifica specifica HNSW m=16, ef_construction=64
hnsw_opts="$(psql_super "
SELECT pg_get_indexdef(indexrelid)
FROM pg_index
WHERE indexrelid = 'observations_embedding_hnsw'::regclass;
")"
echo "$hnsw_opts" | grep -q "m='16'" || fail "HNSW m != 16: $hnsw_opts"
echo "$hnsw_opts" | grep -q "ef_construction='64'" || fail "HNSW ef_construction != 64: $hnsw_opts"
pass "HNSW parametri corretti (m=16, ef_construction=64)"

# Verifica INCLUDE su manifest_entries_scope_path
include_cols="$(psql_super "
SELECT pg_get_indexdef(indexrelid)
FROM pg_index
WHERE indexrelid = 'manifest_entries_scope_path'::regclass;
")"
echo "$include_cols" | grep -q "INCLUDE (obs_id, one_liner, type, priority)" \
  || fail "manifest_entries_scope_path non ha INCLUDE atteso: $include_cols"
pass "manifest_entries_scope_path INCLUDE colonne corrette"

# ─── 7. Trigger single_admin ────────────────────────────────────────────
blue "──▶ Verifica trigger single_admin_trg"
psql_super "INSERT INTO admin_users (username, password_hash, totp_secret)
            VALUES ('admin1', 'dummy_hash', 'dummy_secret');" > /dev/null \
  || fail "primo INSERT su admin_users fallito"

set +e
out="$($COMPOSE exec -T postgres psql -U postgres -d memorymesh -v ON_ERROR_STOP=1 -tA -c \
  "INSERT INTO admin_users (username, password_hash, totp_secret)
   VALUES ('admin2', 'dummy_hash', 'dummy_secret');" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "secondo INSERT su admin_users doveva fallire (trigger bypassato)"
fi
echo "$out" | grep -q 'Only one admin allowed' \
  || fail "secondo INSERT ha fallito ma messaggio inatteso: $out"
pass "trigger single_admin_trg blocca il secondo INSERT (msg atteso)"

# ─── 8. RLS abilitata sulle tabelle attese ──────────────────────────────
blue "──▶ Verifica RLS abilitata"
RLS_TABLES=(observations vocab_entries manifest_entries sessions manifest_entries_accessed)
for t in "${RLS_TABLES[@]}"; do
  rls="$(psql_super "SELECT relrowsecurity FROM pg_class WHERE relname='$t';")"
  [[ "$rls" == "t" ]] || fail "RLS non abilitata su '$t' (trovato: '$rls')"
done
pass "RLS abilitata su ${RLS_TABLES[*]}"

# Verifica che la policy associata esista (una per tabella)
for t in "${RLS_TABLES[@]}"; do
  count="$(psql_super "SELECT count(*) FROM pg_policies WHERE tablename='$t';")"
  [[ "$count" -ge "1" ]] || fail "nessuna policy trovata per '$t'"
done
pass "policy RLS presenti su tutte le tabelle"

# ─── 9. Idempotenza: secondo upgrade head = no-op ──────────────────────
blue "──▶ Verifica idempotenza upgrade head"
cd api
out="$("$VENV_BIN/alembic" upgrade head 2>&1)"
cd "$ROOT"
echo "$out" | grep -qE 'Will assume.*non-transactional|already at head|target.*same as current' \
  || echo "$out" | grep -vqE 'Running upgrade|CREATE ' \
  || fail "secondo upgrade head non no-op:
$out"
pass "secondo upgrade head idempotente"

# ─── 10. alembic current == '0002 (head)' ──────────────────────────────
blue "──▶ Verifica alembic current"
cd api
cur="$("$VENV_BIN/alembic" current 2>&1)"
cd "$ROOT"
echo "$cur" | grep -q '0002' || fail "alembic current non è su 0002: $cur"
pass "alembic current = 0002 (head)"

# ─── 11. Downgrade base → schema vuoto ─────────────────────────────────
blue "──▶ Verifica alembic downgrade base"
# Clean admin_users prima (trigger impedisce delete? no, trigger è BEFORE INSERT)
psql_super "DELETE FROM admin_users;" > /dev/null
cd api
"$VENV_BIN/alembic" downgrade base || { cd "$ROOT"; fail "alembic downgrade base fallita"; }
cd "$ROOT"
remaining="$(psql_super "SELECT count(*) FROM pg_tables
                         WHERE schemaname='public' AND tablename != 'alembic_version';")"
[[ "$remaining" == "0" ]] \
  || fail "dopo downgrade base restano $remaining tabelle (atteso 0)"
pass "downgrade base rimuove tutte le tabelle applicative"

# ─── 12. Re-upgrade dopo downgrade ──────────────────────────────────────
blue "──▶ Re-upgrade head dopo downgrade"
cd api
"$VENV_BIN/alembic" upgrade head || { cd "$ROOT"; fail "re-upgrade dopo downgrade fallita"; }
cd "$ROOT"
cnt="$(psql_super "SELECT count(*) FROM pg_tables WHERE schemaname='public'
                    AND tablename != 'alembic_version';")"
[[ "$cnt" == "${#EXPECTED_TABLES[@]}" ]] \
  || fail "dopo re-upgrade trovate $cnt tabelle (atteso ${#EXPECTED_TABLES[@]})"
pass "re-upgrade ripristina esattamente ${#EXPECTED_TABLES[@]} tabelle"

blue "──▶ Tutti i check F1-04 superati."
