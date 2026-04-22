#!/usr/bin/env bash
# MemoryMesh — Redis Streams smoke test (F1-05)
#
# Verifica end-to-end che:
#
#   1. `ensure_stream_group` crea stream + consumer group idempotente
#   2. I 3 stream ufficiali (mm:embed_jobs, mm:distill_jobs, mm:tighten_jobs)
#      accettano XADD con payload serializzato dai Pydantic schemas
#   3. Un consumer può leggere via XREADGROUP, ACK via XACK, e il pending
#      list si azzera dopo ACK
#   4. Il DLQ accetta XADD senza group (ispezione manuale)
#   5. Schemi Pydantic (EmbedJob/DistillJob/TightenJob/DlqEnvelope) istanziano
#      + serializzano senza errori di validazione
#
# Richiede:
#   - docker daemon attivo + `docker compose` v2
#   - python3 (>= 3.11) con pip sul PATH host
#
# Invocato da:
#   - make redis-check
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
  fail "python3 $PY_VER trovato; richiesto >= 3.11"
fi

# Port locale per redis durante il test
REDIS_HOST_PORT="${REDIS_HOST_PORT:-56379}"

# ─── Env CI-safe ────────────────────────────────────────────────────────
ENV_FILE="$(mktemp -t mm-ci-redis.XXXXXX)"
cp .env.example "$ENV_FILE"
sed -i \
  -e 's/^PG_ADMIN_PASSWORD=.*/PG_ADMIN_PASSWORD=ci_admin_pw/' \
  -e 's/^PG_MM_API_PASSWORD=.*/PG_MM_API_PASSWORD=ci_api_pw/' \
  -e 's/^PG_MM_WORKER_PASSWORD=.*/PG_MM_WORKER_PASSWORD=ci_worker_pw/' \
  -e 's/^PG_MM_ADMIN_PASSWORD=.*/PG_MM_ADMIN_PASSWORD=ci_admin_mm_pw/' \
  -e 's/^REDIS_PASSWORD=.*/REDIS_PASSWORD=ci_redis_pw/' \
  -e 's/^SECRET_KEY=.*/SECRET_KEY=ci-placeholder-64hex-0000000000000000000000000000000000000000000000000000000000/' \
  "$ENV_FILE"

# Override compose per il test:
#   - espone redis su 127.0.0.1:$REDIS_HOST_PORT (mm_internal è internal:true,
#     aggiungiamo mm_ingress per il port publish — vedi F1-04 stesso pattern)
#   - disabilita AOF/RDB persistence: il test non ha bisogno di durabilità
#     e l'image redis:8.6-alpine in read_only:true ha un bug con AOF su volume
#     Docker Desktop Windows (Permission denied creando /data/appendonlydir).
#     Tracked come F1-02 follow-up — vedi docs/F1-05.md §Known Issues.
OVERRIDE_FILE="$(mktemp -t mm-ci-redis-override.XXXXXX.yml)"
cat > "$OVERRIDE_FILE" <<EOF
services:
  redis:
    networks:
      - mm_internal
      - mm_ingress
    ports:
      - "127.0.0.1:${REDIS_HOST_PORT}:6379"
    command: >
      redis-server
      --requirepass ci_redis_pw
      --maxmemory 512mb
      --maxmemory-policy allkeys-lru
      --save ""
      --appendonly no
EOF

COMPOSE="docker compose --env-file $ENV_FILE -f docker-compose.yml -f $OVERRIDE_FILE"

VENV_DIR="$(mktemp -d -t mm-ci-redis-venv.XXXXXX)"

cleanup() {
  blue "──▶ Teardown (redis + venv + tmp files)"
  $COMPOSE down -v 2>/dev/null || true
  rm -rf "$VENV_DIR"
  rm -f "$ENV_FILE" "$OVERRIDE_FILE"
}
trap cleanup EXIT

# ─── 1. Venv + pip install ──────────────────────────────────────────────
blue "──▶ Setup venv host (python $PY_VER)"
python3 -m venv "$VENV_DIR"
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

# ─── 2. Boot redis con port exposed ─────────────────────────────────────
blue "──▶ docker compose up -d redis (con port 127.0.0.1:${REDIS_HOST_PORT})"
$COMPOSE up -d redis

# ─── 3. Wait healthy ────────────────────────────────────────────────────
blue "──▶ Attesa redis healthy (max 60s)"
deadline=$((SECONDS + 60))
while :; do
  status="$($COMPOSE ps --format json redis 2>/dev/null \
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
    unhealthy) fail "redis healthcheck=unhealthy" ;;
  esac
  if [[ $SECONDS -ge $deadline ]]; then
    $COMPOSE logs --tail=40 redis || true
    fail "timeout (60s) attendendo redis healthy — ultimo stato: $status"
  fi
  sleep 2
done
pass "redis healthy"

# Shortcut: redis-cli autenticato dentro il container
redis_cmd() { $COMPOSE exec -T redis redis-cli --no-auth-warning -a ci_redis_pw "$@"; }

# ─── 4. Run il Python driver ────────────────────────────────────────────
# Il driver esercita: ensure_stream_group (idempotenza), XADD via Pydantic
# schemas, XREADGROUP, XACK, XLEN pre/post-ACK, DLQ append, schema validation.
blue "──▶ Run Python driver (redis async + pydantic schemas)"
export REDIS_URL="redis://:ci_redis_pw@127.0.0.1:${REDIS_HOST_PORT}/0"
export PYTHONPATH="$ROOT/api"
export PYTHONIOENCODING="utf-8"

"$VENV_BIN/python" - <<'PYDRIVER' || fail "Python driver fallito"
import asyncio
import os
import sys
from datetime import datetime, timezone
from uuid import uuid4

from redis.asyncio import Redis

from app.queue import (
    DLQ_DISTILL_JOBS,
    DLQ_EMBED_JOBS,
    DLQ_TIGHTEN_JOBS,
    DistillJob,
    DlqEnvelope,
    EmbedJob,
    GROUP_DISTILL_WORKERS,
    GROUP_EMBED_WORKERS,
    GROUP_TIGHTEN_WORKERS,
    STREAM_DISTILL_JOBS,
    STREAM_EMBED_JOBS,
    STREAM_TIGHTEN_JOBS,
    TightenJob,
    ensure_stream_group,
)


def section(title: str) -> None:
    print(f"  [driver] {title}", flush=True)


async def main() -> int:
    url = os.environ["REDIS_URL"]
    r = Redis.from_url(url, decode_responses=True)

    try:
        # 1. Schema validation — rejects extra fields + type errors
        section("pydantic schemas — happy path")
        job1 = EmbedJob(obs_id=42, project_id=uuid4())
        job2 = DistillJob(project_id=uuid4(), trigger="manual")
        job3 = TightenJob(obs_id=99, project_id=uuid4(), reason="capped_at_write")
        for j in (job1, job2, job3):
            assert j.v == 1 and j.attempt == 0, f"default non applicati: {j}"

        section("pydantic schemas — extra='forbid'")
        try:
            EmbedJob(obs_id=1, project_id=uuid4(), unknown_field="boom")  # type: ignore[call-arg]
            print("FAIL: EmbedJob ha accettato campo extra", file=sys.stderr)
            return 1
        except Exception:
            pass

        section("pydantic schemas — obs_id > 0")
        try:
            EmbedJob(obs_id=0, project_id=uuid4())
            print("FAIL: EmbedJob ha accettato obs_id=0", file=sys.stderr)
            return 1
        except Exception:
            pass

        # 2. ensure_stream_group — create then verify idempotent
        section("ensure_stream_group — create phase")
        specs = [
            (STREAM_EMBED_JOBS, GROUP_EMBED_WORKERS),
            (STREAM_DISTILL_JOBS, GROUP_DISTILL_WORKERS),
            (STREAM_TIGHTEN_JOBS, GROUP_TIGHTEN_WORKERS),
        ]
        for stream, group in specs:
            created = await ensure_stream_group(r, stream, group, start_id="0")
            assert created is True, f"{stream}/{group} doveva essere creato ex-novo"

        section("ensure_stream_group — idempotency")
        for stream, group in specs:
            created = await ensure_stream_group(r, stream, group, start_id="0")
            assert created is False, f"{stream}/{group} doveva essere 'già esistente'"

        # 3. XINFO GROUPS — verifica group reali
        section("XINFO GROUPS — verifica struttura")
        for stream, group in specs:
            groups = await r.xinfo_groups(stream)
            names = [g["name"] for g in groups]
            assert group in names, f"group {group} non trovato in {stream}: {names}"

        # 4. Round-trip: XADD via EmbedJob → XREADGROUP → XACK
        section("round-trip: XADD -> XREADGROUP -> XACK")
        pid = uuid4()
        job = EmbedJob(obs_id=1001, project_id=pid, content_kind="observation")
        # Serializzazione manuale (helper to_stream_fields arriverà in F3-01)
        fields = {
            "v": str(job.v),
            "attempt": str(job.attempt),
            "obs_id": str(job.obs_id),
            "project_id": str(job.project_id),
            "content_kind": job.content_kind,
        }
        entry_id = await r.xadd(STREAM_EMBED_JOBS, fields)
        assert isinstance(entry_id, str) and "-" in entry_id, f"XADD id inatteso: {entry_id}"

        # Consumer legge
        resp = await r.xreadgroup(
            GROUP_EMBED_WORKERS,
            "test-consumer-1",
            {STREAM_EMBED_JOBS: ">"},
            count=10,
            block=1000,
        )
        # redis-py returns: [(stream, [(id, {field: value}), ...])]
        assert len(resp) == 1 and len(resp[0][1]) >= 1, f"XREADGROUP empty: {resp}"
        read_id, read_fields = resp[0][1][0]
        assert read_fields["obs_id"] == "1001"
        assert read_fields["project_id"] == str(pid)

        # Verifica che il messaggio sia nella PEL (pending entries list) prima di ACK
        pending = await r.xpending(STREAM_EMBED_JOBS, GROUP_EMBED_WORKERS)
        pel_count = pending["pending"] if isinstance(pending, dict) else pending[0]
        assert pel_count == 1, f"PEL count atteso 1, trovato {pel_count}"

        # ACK
        acked = await r.xack(STREAM_EMBED_JOBS, GROUP_EMBED_WORKERS, read_id)
        assert acked == 1, f"XACK return atteso 1, trovato {acked}"

        # PEL azzerata
        pending = await r.xpending(STREAM_EMBED_JOBS, GROUP_EMBED_WORKERS)
        pel_count = pending["pending"] if isinstance(pending, dict) else pending[0]
        assert pel_count == 0, f"PEL post-ACK atteso 0, trovato {pel_count}"

        # 5. DLQ append (no group)
        section("DLQ — XADD senza group, XLEN verifica")
        envelope = DlqEnvelope(
            original_stream=STREAM_EMBED_JOBS,
            original_id=entry_id,
            payload=fields,
            error_class="TimeoutError",
            error_message="embed provider timeout after 60s",
            attempts=5,
            first_failure_at=datetime.now(timezone.utc),
            last_failure_at=datetime.now(timezone.utc),
        )
        # DLQ serialization (stringify all, payload comma-join — F3-01 migliorerà)
        dlq_fields = {
            "v": str(envelope.v),
            "original_stream": envelope.original_stream,
            "original_id": envelope.original_id,
            "error_class": envelope.error_class,
            "error_message": envelope.error_message,
            "attempts": str(envelope.attempts),
            "first_failure_at": envelope.first_failure_at.isoformat(),
            "last_failure_at": envelope.last_failure_at.isoformat(),
            # payload flattened per evitare JSON nested:
            "payload.obs_id": envelope.payload["obs_id"],
            "payload.project_id": envelope.payload["project_id"],
        }
        for dlq in (DLQ_EMBED_JOBS, DLQ_DISTILL_JOBS, DLQ_TIGHTEN_JOBS):
            dlq_id = await r.xadd(dlq, dlq_fields)
            assert "-" in dlq_id
        # DLQ NON ha group
        for dlq in (DLQ_EMBED_JOBS, DLQ_DISTILL_JOBS, DLQ_TIGHTEN_JOBS):
            groups = await r.xinfo_groups(dlq)
            assert groups == [], f"DLQ {dlq} non deve avere group, trovati: {groups}"
            length = await r.xlen(dlq)
            assert length == 1, f"{dlq} XLEN atteso 1, trovato {length}"

        # 6. start_id="$" variant — nuovo group non legge messaggi arretrati
        section("ensure_stream_group — start_id='$' skip backlog")
        await r.xadd(STREAM_EMBED_JOBS, {"v": "1", "obs_id": "9999", "project_id": str(uuid4()),
                                          "content_kind": "observation", "attempt": "0"})
        created = await ensure_stream_group(r, STREAM_EMBED_JOBS,
                                             "embed-workers-fresh", start_id="$")
        assert created is True
        resp = await r.xreadgroup("embed-workers-fresh", "c1",
                                   {STREAM_EMBED_JOBS: ">"}, count=100, block=500)
        assert resp == [] or len(resp[0][1]) == 0, \
            f"group con start_id=$ ha letto backlog: {resp}"

        print("  [driver] tutti i check OK", flush=True)
        return 0

    finally:
        await r.aclose()


sys.exit(asyncio.run(main()))
PYDRIVER
pass "Python driver (schemas + round-trip + DLQ + start_id='\$') tutti i check OK"

# ─── 5. Sanity esterna via redis-cli ────────────────────────────────────
blue "──▶ Sanity check via redis-cli (stream + group count)"
streams=$(redis_cmd --scan --pattern 'mm:*' | grep -v '^$' | sort)
expected_streams=(
  "mm:distill_jobs"
  "mm:distill_jobs:dlq"
  "mm:embed_jobs"
  "mm:embed_jobs:dlq"
  "mm:tighten_jobs"
  "mm:tighten_jobs:dlq"
)
for s in "${expected_streams[@]}"; do
  echo "$streams" | grep -qx "$s" || fail "stream '$s' non trovato via redis-cli (vedi: $streams)"
done
pass "redis-cli vede tutti i 6 stream attesi (3 primari + 3 DLQ)"

# Conta group per stream primari: 1 ciascuno + 1 extra sul embed_jobs
n_embed="$(redis_cmd XINFO GROUPS mm:embed_jobs | grep -c '^name$' || true)"
[[ "$n_embed" -ge 1 ]] || fail "mm:embed_jobs non ha group (atteso >=1)"
pass "mm:embed_jobs ha group (${n_embed} — embed-workers + fresh extra)"

blue "──▶ Tutti i check F1-05 superati."
