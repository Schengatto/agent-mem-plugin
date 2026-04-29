#!/usr/bin/env bash
# MemoryMesh — backup pg_dump encrypted (F1-08)
#
# Produce `backups/backup-YYYY-MM-DD-HHMM.sql.gz.enc` eseguendo:
#
#     pg_dump (via docker compose exec) | gzip | age -r <RECIPIENT>
#
# Pattern SECURITY.md §6.4:
#   - Recipient key = PUBLIC age key sul server (safe da compromettere)
#   - Private key (decrypt) solo OFF-server, in password manager admin
#
# Invocato manualmente (`make backup`) o da cron (vedi docs/F1-08.md
# §Scheduling). Idempotente: ogni run produce un nuovo file timestamped.
#
# Requisiti host:
#   - docker + `docker compose` v2
#   - `age` binary sul PATH (https://github.com/FiloSottile/age)
#     Install:
#       Ubuntu/Debian: sudo apt install age
#       macOS:         brew install age
#       Windows:       scoop install age
#
# Env vars:
#   BACKUP_RECIPIENT    — path al file .age pubblico (REQUIRED)
#                         Default: /etc/memorymesh/backup-pubkey.age
#   BACKUP_DIR          — directory output (REQUIRED)
#                         Default: ./backups
#   PG_ADMIN_USER       — user postgres superuser (da .env)
#                         Default: postgres
#   KEEP_LAST           — retention: mantiene solo gli ultimi N backup.
#                         Default: 30 (giorni di backup giornalieri).
#                         0 = disable retention.

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail() { red "ERROR: $*"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── Pre-flight ─────────────────────────────────────────────────────────
command -v docker >/dev/null || fail "docker non trovato sul PATH"
command -v age    >/dev/null || fail "age non trovato sul PATH (vedi docs/F1-08.md §Install)"
command -v gzip   >/dev/null || fail "gzip non trovato sul PATH"

# ─── Config ─────────────────────────────────────────────────────────────
BACKUP_RECIPIENT="${BACKUP_RECIPIENT:-/etc/memorymesh/backup-pubkey.age}"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backups}"
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"
KEEP_LAST="${KEEP_LAST:-30}"

[[ -f "$BACKUP_RECIPIENT" ]] \
  || fail "recipient key non trovata: $BACKUP_RECIPIENT
(Setup: age-keygen -o ~/.mm-backup-privkey.age && \\
        age-keygen -y ~/.mm-backup-privkey.age > \$BACKUP_RECIPIENT
 La private key NON deve restare sul server — salvala nel password manager.)"

mkdir -p "$BACKUP_DIR"

# Service postgres up?
if ! docker compose ps --format '{{.Service}}={{.Status}}' postgres 2>/dev/null \
    | grep -qi 'Up'; then
  fail "servizio 'postgres' non è in esecuzione. Avvia con: make up"
fi

# ─── Backup ─────────────────────────────────────────────────────────────
TS="$(date -u +%Y-%m-%d-%H%M)"
OUT="$BACKUP_DIR/backup-$TS.sql.gz.enc"

blue "──▶ pg_dump → gzip → age → $OUT"

# NOTA: pg_dump in formato plain (non --format=custom) perché gzip lo
# comprime meglio e la combinazione è più portable (restore funziona con
# psql direttamente). Il custom format verrà usato per backup big volume
# in F1-XX (se mai arriverà). Per ora plain + gzip è lo standard.

# Usiamo `-T` (no TTY) per pipe-friendliness. Redirect stderr su file di
# log a parte per audit (no interleaving su stdout del pipe).
LOG="$BACKUP_DIR/.backup-$TS.log"

set -o pipefail
docker compose exec -T postgres \
    pg_dump -U "$PG_ADMIN_USER" \
            --no-owner --no-acl --clean --if-exists \
            memorymesh 2>"$LOG" \
  | gzip -9 \
  | age -r "$(cat "$BACKUP_RECIPIENT")" \
  > "$OUT"

# Check integrità: file non vuoto + age header presente
SIZE="$(wc -c < "$OUT" | tr -d ' ')"
[[ "$SIZE" -gt 100 ]] \
  || fail "backup file sospetto ($SIZE bytes). Log: $LOG"

# age file inizia con "age-encryption.org/v1" magic header
if ! head -c 32 "$OUT" | grep -q 'age-encryption.org'; then
  fail "backup non ha l'header age atteso. Log: $LOG"
fi

green "  ✓ backup OK: $OUT ($SIZE bytes)"
rm -f "$LOG"

# ─── Retention ──────────────────────────────────────────────────────────
if [[ "$KEEP_LAST" -gt 0 ]]; then
  # Ordina per mtime desc, mantiene i primi N, rimuove gli altri
  # `ls -t` + `tail -n +$((N+1))` = backup più vecchi del N-esimo più recente
  mapfile -t OLD < <(
    cd "$BACKUP_DIR" && ls -1t backup-*.sql.gz.enc 2>/dev/null | tail -n "+$((KEEP_LAST + 1))"
  )
  if [[ ${#OLD[@]} -gt 0 ]]; then
    blue "──▶ Retention: rimuovo ${#OLD[@]} backup più vecchi di $KEEP_LAST"
    for f in "${OLD[@]}"; do
      rm -f "$BACKUP_DIR/$f"
      echo "  - $f"
    done
  fi
fi

blue "──▶ Backup completato."
