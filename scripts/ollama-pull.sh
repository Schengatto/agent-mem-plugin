#!/usr/bin/env bash
# MemoryMesh — Ollama model pull (F1-06)
#
# Scarica idempotentemente i modelli Ollama necessari al profile attivo:
#
#   - OLLAMA_EMBED_MODEL    (default: nomic-embed-text-v2-moe)
#   - OLLAMA_DISTILL_MODEL  (default: qwen3.5:9b)
#
# Viene eseguito SOLO se il deployment usa Ollama come provider (profile B
# per embed, profile C per embed+LLM). Per profile A (cloud Gemini default)
# il container Ollama non parte nemmeno → questo script è no-op.
#
# Pattern idempotente: per ogni modello, `ollama list` prima e skip se
# già presente. Evita re-download multi-GB su re-run.
#
# Uso:
#   scripts/ollama-pull.sh              # pull di entrambi
#   scripts/ollama-pull.sh --embed-only # solo embed model (profile B)
#   scripts/ollama-pull.sh --llm-only   # solo LLM model (uso raro)
#   scripts/ollama-pull.sh --dry-run    # lista cosa farebbe, senza pull
#
# Invocato da:
#   - make ollama-pull
#   - manualmente dopo il primo `docker compose --profile ollama up`

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

fail() { red "ERROR: $*"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── Args ───────────────────────────────────────────────────────────────
PULL_EMBED=1
PULL_LLM=1
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --embed-only) PULL_LLM=0 ;;
    --llm-only)   PULL_EMBED=0 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) fail "argomento sconosciuto: $1 (usa --help)" ;;
  esac
  shift
done

# ─── Env ────────────────────────────────────────────────────────────────
# Parser dedicato invece di `source .env`: il file può contenere valori
# non-quotati con spazi (es. `DISTILLATION_CRON=0 3 * * *`) che farebbero
# esplodere bash. Estraiamo solo le due chiavi che ci interessano con un
# regex preciso — sed semplice, niente evaluation del contenuto.
env_get() {
  local key="$1" file="${2:-.env}"
  [[ -f "$file" ]] || return 0
  # Cerca "KEY=..." all'inizio riga, ignora commenti/vuote; rimuove quote
  # esterne se presenti; restituisce il valore raw (può contenere spazi).
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$file" \
    | tail -n1
}

EMBED_MODEL="${OLLAMA_EMBED_MODEL:-$(env_get OLLAMA_EMBED_MODEL)}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text-v2-moe}"
LLM_MODEL="${OLLAMA_DISTILL_MODEL:-$(env_get OLLAMA_DISTILL_MODEL)}"
LLM_MODEL="${LLM_MODEL:-qwen3.5:9b}"

command -v docker >/dev/null || fail "docker non trovato sul PATH"

COMPOSE="docker compose"

# ─── Ollama running? ────────────────────────────────────────────────────
status="$($COMPOSE ps --format '{{.Service}}={{.Status}}' ollama 2>/dev/null \
  | grep -i 'Up' || true)"
if [[ -z "$status" ]]; then
  yellow "⚠ Ollama non è in running."
  yellow "  Avvia con: docker compose --profile ollama up -d ollama"
  yellow "  (oppure questo script è no-op — profile cloud non richiede Ollama)"
  exit 0
fi

# ─── Helper: model presente? ────────────────────────────────────────────
have_model() {
  local name="$1"
  # `ollama list` stampa NAME TAG, cerca match esatto su prima colonna.
  # Il NAME include il tag (es. "qwen3.5:9b"), matchiamo all'inizio della
  # riga per evitare false positive su substring.
  $COMPOSE exec -T ollama ollama list 2>/dev/null \
    | awk -v m="$name" 'NR>1 && $1 == m { found=1; exit } END { exit !found }'
}

# ─── Pull con skip idempotente ──────────────────────────────────────────
pull_if_missing() {
  local name="$1" purpose="$2"
  blue "──▶ Check $purpose: $name"
  if have_model "$name"; then
    green "  ✓ già presente, skip"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    yellow "  [dry-run] avrebbe eseguito: ollama pull $name"
    return 0
  fi
  blue "  ⇩ ollama pull $name (primo download — può essere lungo)"
  $COMPOSE exec -T ollama ollama pull "$name" \
    || fail "pull $name fallito"
  green "  ✓ pulled"
}

# ─── Esecuzione ─────────────────────────────────────────────────────────
if [[ "$PULL_EMBED" == "1" ]]; then
  pull_if_missing "$EMBED_MODEL" "embed model (MEMORYMESH_EMBED_PROVIDER=ollama)"
fi
if [[ "$PULL_LLM" == "1" ]]; then
  pull_if_missing "$LLM_MODEL" "LLM model (MEMORYMESH_LLM_PROVIDER=ollama)"
fi

blue "──▶ Stato finale"
$COMPOSE exec -T ollama ollama list || true
green "──▶ Tutti i modelli richiesti sono disponibili."
