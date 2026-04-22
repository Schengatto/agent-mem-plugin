#!/usr/bin/env bash
# MemoryMesh — Ollama smoke test (F1-06)
#
# Verifica:
#
#   1. Con profile default (senza `--profile ollama`) il servizio ollama
#      NON viene avviato (è opt-in via profile).
#   2. Con `--profile ollama` parte e diventa healthy entro 120s.
#   3. Le env var hardening sono settate:
#        OLLAMA_MAX_LOADED_MODELS=1
#        OLLAMA_KEEP_ALIVE=5m
#        OLLAMA_HOST=0.0.0.0:11434
#   4. `ollama list` risponde senza errori (empty al primo boot).
#   5. `ollama-pull.sh --dry-run` si connette e rileva correttamente
#      l'assenza del modello (skip pull effettivo per evitare download
#      multi-GB in CI).
#
# NON scarica modelli veri (nomic-embed-text-v2-moe = ~500MB,
# qwen3.5:9b = ~5.5GB). Il test del pull vero è manuale via
# `make ollama-pull` durante il setup locale.
#
# Richiede: docker daemon attivo + `docker compose` v2.
#
# Invocato da:
#   - make ollama-check
#   - .github/workflows/ci.yml

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail() { red "FAIL: $*"; cleanup; exit 1; }
pass() { green "PASS: $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── Env CI-safe ────────────────────────────────────────────────────────
ENV_FILE="$(mktemp -t mm-ci-ollama.XXXXXX)"
cp .env.example "$ENV_FILE"
sed -i \
  -e 's/^PG_ADMIN_PASSWORD=.*/PG_ADMIN_PASSWORD=ci_admin_pw/' \
  -e 's/^PG_MM_API_PASSWORD=.*/PG_MM_API_PASSWORD=ci_api_pw/' \
  -e 's/^PG_MM_WORKER_PASSWORD=.*/PG_MM_WORKER_PASSWORD=ci_worker_pw/' \
  -e 's/^PG_MM_ADMIN_PASSWORD=.*/PG_MM_ADMIN_PASSWORD=ci_admin_mm_pw/' \
  -e 's/^REDIS_PASSWORD=.*/REDIS_PASSWORD=ci_redis_pw/' \
  -e 's/^SECRET_KEY=.*/SECRET_KEY=ci-placeholder-64hex-0000000000000000000000000000000000000000000000000000000000/' \
  "$ENV_FILE"

COMPOSE_BASE="docker compose --env-file $ENV_FILE -f docker-compose.yml"
COMPOSE_OLLAMA="$COMPOSE_BASE --profile ollama"

cleanup() {
  blue "──▶ Teardown"
  $COMPOSE_OLLAMA down -v 2>/dev/null || true
  $COMPOSE_BASE down -v 2>/dev/null || true
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

# ─── 1. Profile default: ollama NON parte ───────────────────────────────
blue "──▶ docker compose config (no --profile) → ollama NON deve essere presente"
services="$($COMPOSE_BASE config --services | sort)"
# Verifica: 'ollama' non compare nei servizi attivi del profilo default.
# `docker compose config --services` rispetta i `profiles:` se nessun
# --profile è attivato. Ollama ha profiles:[ollama], quindi deve essere esclusa.
if echo "$services" | grep -qx 'ollama'; then
  fail "ollama compare in 'config --services' senza --profile (dovrebbe essere opt-in)"
fi
pass "ollama è opt-in — escluso dal profile default"

# ─── 2. Con --profile ollama → servizio presente ────────────────────────
blue "──▶ docker compose --profile ollama config → ollama presente"
services_ollama="$($COMPOSE_OLLAMA config --services | sort)"
echo "$services_ollama" | grep -qx 'ollama' \
  || fail "ollama non compare nemmeno con --profile ollama: $services_ollama"
pass "ollama presente con --profile ollama"

# ─── 3. Avvio ollama (no dipendenze altre) ──────────────────────────────
blue "──▶ docker compose --profile ollama up -d ollama"
$COMPOSE_OLLAMA up -d ollama

# ─── 4. Wait healthy (max 120s — Ollama è lento a boot) ────────────────
blue "──▶ Attesa ollama healthy (max 120s)"
deadline=$((SECONDS + 120))
while :; do
  status="$($COMPOSE_OLLAMA ps --format json ollama 2>/dev/null \
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
    unhealthy) fail "ollama healthcheck=unhealthy" ;;
  esac
  if [[ $SECONDS -ge $deadline ]]; then
    $COMPOSE_OLLAMA logs --tail=40 ollama || true
    fail "timeout (120s) attendendo ollama healthy — ultimo stato: $status"
  fi
  sleep 3
done
pass "ollama healthy"

# Shortcut: exec comandi dentro il container ollama
ollama_exec() { $COMPOSE_OLLAMA exec -T ollama "$@"; }

# ─── 5. Env vars hardening ──────────────────────────────────────────────
blue "──▶ Verifica env var hardening"
check_env() {
  local key="$1" expected="$2"
  local got
  got="$(ollama_exec printenv "$key" 2>/dev/null || echo "")"
  # printenv termina con newline; strip
  got="${got%$'\r'}"
  [[ "$got" == "$expected" ]] \
    || fail "$key: atteso '$expected', trovato '$got'"
}
check_env OLLAMA_MAX_LOADED_MODELS 1
check_env OLLAMA_KEEP_ALIVE 5m
check_env OLLAMA_HOST '0.0.0.0:11434'
pass "env var hardening: MAX_LOADED_MODELS=1, KEEP_ALIVE=5m, HOST=0.0.0.0:11434"

# ─── 6. ollama list risponde (empty al primo boot) ──────────────────────
blue "──▶ ollama list"
out="$(ollama_exec ollama list 2>&1)" \
  || fail "ollama list ha fallito: $out"
# Output atteso: header "NAME  ID  SIZE  MODIFIED" (senza modelli al primo boot).
# Accettiamo sia "NAME" su singola riga sia header+rows.
echo "$out" | grep -qi 'NAME' \
  || fail "ollama list output inatteso (header 'NAME' mancante): $out"
pass "ollama list funziona (stato iniziale: empty)"

# ─── 7. Pull script: syntax + dry-run ───────────────────────────────────
blue "──▶ scripts/ollama-pull.sh: syntax check"
bash -n scripts/ollama-pull.sh || fail "ollama-pull.sh ha errori di sintassi"
pass "ollama-pull.sh sintatticamente valido"

blue "──▶ scripts/ollama-pull.sh --dry-run (niente download)"
# Lo script legge .env dalla root; passiamo override env_file via export.
# Usiamo un .env temp per evitare di toccare quello del dev.
BACKUP_ENV=""
if [[ -f .env ]]; then
  BACKUP_ENV="$(mktemp -t mm-ci-ollama-envbackup.XXXXXX)"
  cp .env "$BACKUP_ENV"
fi
cp "$ENV_FILE" .env
trap 'cleanup; if [[ -n "$BACKUP_ENV" ]]; then mv "$BACKUP_ENV" .env; else rm -f .env; fi' EXIT

out="$(COMPOSE_PROFILES=ollama bash scripts/ollama-pull.sh --dry-run 2>&1)" \
  || fail "ollama-pull.sh --dry-run è fallito:
$out"
# Verifichiamo le due decisioni: skip (già presente) oppure [dry-run] pull
echo "$out" | grep -qE '(\[dry-run\] avrebbe eseguito|già presente, skip)' \
  || fail "ollama-pull.sh --dry-run output inatteso (manca indicator):
$out"
pass "ollama-pull.sh --dry-run attraversa lo stato atteso"

blue "──▶ Tutti i check F1-06 superati."
