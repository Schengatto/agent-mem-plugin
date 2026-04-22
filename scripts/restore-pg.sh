#!/usr/bin/env bash
# MemoryMesh — restore da backup cifrato (F1-08)
#
# Inverte scripts/backup-pg.sh:
#
#     age -d -i <PRIVKEY> <FILE> | gunzip | psql (via docker compose exec)
#
# ATTENZIONE: sovrascrive il DB esistente (pg_dump con --clean --if-exists).
# L'operazione NON è reversibile — il caller deve avere backup pre-restore.
#
# Requisiti host: docker, docker compose v2, age sul PATH, gunzip.
#
# Env vars:
#   BACKUP_PRIVKEY  — path al file .age privato (REQUIRED)
#                     Default: ~/.mm-backup-privkey.age
#   PG_ADMIN_USER   — user postgres superuser. Default: postgres.
#   FILE            — path al file .sql.gz.enc da ripristinare (REQUIRED).
#
# Uso:
#   FILE=backups/backup-2026-04-22-0300.sql.gz.enc bash scripts/restore-pg.sh
#   # oppure:
#   make restore BACKUP=backups/backup-2026-04-22-0300.sql.gz.enc

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail() { red "ERROR: $*"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── Pre-flight ─────────────────────────────────────────────────────────
command -v docker >/dev/null || fail "docker non trovato sul PATH"
command -v age    >/dev/null || fail "age non trovato sul PATH"
command -v gunzip >/dev/null || fail "gunzip non trovato sul PATH"

BACKUP_PRIVKEY="${BACKUP_PRIVKEY:-$HOME/.mm-backup-privkey.age}"
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"
FILE="${FILE:-}"

[[ -n "$FILE" ]]             || fail "FILE non settato. Usage: FILE=backups/foo.sql.gz.enc ..."
[[ -f "$FILE" ]]             || fail "file non trovato: $FILE"
[[ -f "$BACKUP_PRIVKEY" ]]   || fail "private key non trovata: $BACKUP_PRIVKEY"

# Verifica che sia un file age
if ! head -c 32 "$FILE" | grep -q 'age-encryption.org'; then
  fail "il file non sembra cifrato con age (magic header mancante): $FILE"
fi

if ! docker compose ps --format '{{.Service}}={{.Status}}' postgres 2>/dev/null \
    | grep -qi 'Up'; then
  fail "servizio 'postgres' non è in esecuzione. Avvia con: make up"
fi

blue "──▶ RESTORE da $FILE"
blue "    ATTENZIONE: il DB corrente verrà sovrascritto."

# ─── Restore ────────────────────────────────────────────────────────────
set -o pipefail
# `-v ON_ERROR_STOP=1` esce non-zero al primo errore SQL
age -d -i "$BACKUP_PRIVKEY" < "$FILE" \
  | gunzip \
  | docker compose exec -T postgres \
      psql -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 -d memorymesh

green "  ✓ restore OK"
blue "──▶ Restore completato."
