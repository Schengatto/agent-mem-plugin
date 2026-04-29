#!/usr/bin/env bash
# MemoryMesh — backup+restore roundtrip smoke test (F1-08)
#
# Verifica end-to-end che il ciclo pg_dump → gzip → age → filesystem →
# age -d → gunzip → pg_restore (psql) preservi i dati fedelmente.
#
# Flusso:
#   1. Boot postgres (compose, senza dep su api)
#   2. Seed `test_backup` schema con 3 righe
#   3. Genera ephemeral age keypair (dockerizzato)
#   4. Esegue scripts/backup-pg.sh con AGE_CMD=docker wrapper
#   5. DROP schema test_backup
#   6. Esegue scripts/restore-pg.sh
#   7. Verifica 3 righe sopravvissute + contenuto uguale
#   8. Verifica il file .sql.gz.enc ha magic header age valido
#   9. Verifica retention (KEEP_LAST=1 → 2° backup rimuove il primo)
#
# Age è fornito via image Docker (alpine + apk add age) — evita di
# richiedere `age` sul PATH host (portabile Linux/macOS/Windows).
#
# Richiede: docker daemon + docker compose v2.
#
# Invocato da:
#   - make backup-check
#   - .github/workflows/ci.yml

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail() { red "FAIL: $*"; cleanup; exit 1; }
pass() { green "PASS: $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# NOTA: NON esportiamo MSYS_NO_PATHCONV globalmente. Le invocazioni
# `docker compose --env-file /tmp/...` hanno BISOGNO della traduzione
# MSYS da POSIX a Windows path. La disabilitiamo solo per i docker run
# con -v <host>:<container-posix-path>, dove il path del container deve
# restare POSIX (non va tradotto in Windows).

# ─── Env CI-safe ────────────────────────────────────────────────────────
ENV_FILE="$(mktemp -t mm-ci-backup.XXXXXX)"
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

# backup-pg.sh usa `docker compose` puro (senza --env-file) → legge .env dalla
# root del progetto. Per il test sostituiamo temporaneamente .env e lo
# ripristiniamo al teardown.
BACKUP_ENV=""
if [[ -f .env ]]; then
  BACKUP_ENV="$(mktemp -t mm-ci-backup-envbackup.XXXXXX)"
  cp .env "$BACKUP_ENV"
fi
cp "$ENV_FILE" .env

# Directory di lavoro temporanee per chiavi + backup.
# NOTA cross-platform: il path viene usato in `docker run -v <host>:...`.
# Su Git-Bash/MSYS, `/tmp/` è dentro %TEMP% Windows ma Docker Desktop
# (WSL2 backend) non lo riconosce. Convertiamo in Windows path via cygpath
# se disponibile, così i volumi si bindano correttamente su tutte le
# piattaforme (cygpath no-op su Linux/macOS).
WORK_DIR="$(mktemp -d -t mm-ci-backup-work.XXXXXX)"
if command -v cygpath >/dev/null 2>&1; then
  WORK_DIR_MOUNT="$(cygpath -w "$WORK_DIR")"
else
  WORK_DIR_MOUNT="$WORK_DIR"
fi
KEYS_DIR="$WORK_DIR/keys"
BACKUP_DIR="$WORK_DIR/backups"
KEYS_DIR_MOUNT="$WORK_DIR_MOUNT/keys"
mkdir -p "$KEYS_DIR" "$BACKUP_DIR"

cleanup() {
  blue "──▶ Teardown"
  $COMPOSE down -v 2>/dev/null || true
  # Ripristina .env originale se esisteva
  if [[ -n "$BACKUP_ENV" && -f "$BACKUP_ENV" ]]; then
    mv "$BACKUP_ENV" .env
  else
    rm -f .env
  fi
  # Cleanup immagine age ephemeral (non lasciarne una per ogni test run)
  docker rmi "$AGE_IMAGE" 2>/dev/null || true
  # Preserve work_dir in caso di fail per debugging, se il caller non ha
  # settato MM_TEST_KEEP_WORKDIR
  if [[ -z "${MM_TEST_KEEP_WORKDIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  else
    blue "  (work_dir preservato in $WORK_DIR per ispezione)"
  fi
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

# ─── Age wrapper (Docker-based per portabilità cross-OS) ────────────────
# Build un'immagine anonima una volta, riusa per tutte le age call.
AGE_IMAGE="mm-age-test:$$"
blue "──▶ Build immagine age (alpine + apk add age)"
docker build -q -t "$AGE_IMAGE" - >/dev/null <<'DOCKERFILE' \
  || fail "build age image fallita"
FROM alpine:3.21
RUN apk add --no-cache age
DOCKERFILE
pass "age image pronta: $AGE_IMAGE"

# ─── 1. Genera ephemeral age keypair ────────────────────────────────────
blue "──▶ Genera ephemeral age keypair in $KEYS_DIR"
# MSYS_NO_PATHCONV=1 impedisce che Git-Bash traduca /keys in C:/Program Files/Git/keys
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$KEYS_DIR_MOUNT:/keys" \
  "$AGE_IMAGE" age-keygen -o /keys/privkey.age >/dev/null 2>&1 \
  || fail "age-keygen fallita"
# age-keygen -y estrae la public key dalla private
PUBKEY="$(MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$KEYS_DIR_MOUNT:/keys" \
  "$AGE_IMAGE" age-keygen -y /keys/privkey.age)" \
  || fail "age-keygen -y (public extraction) fallita"
echo "$PUBKEY" > "$KEYS_DIR/pubkey.txt"
[[ "$PUBKEY" =~ ^age1[0-9a-z]+ ]] \
  || fail "public key format inatteso: $PUBKEY"
pass "age keypair generato (pub: ${PUBKEY:0:16}...)"

# ─── 2. Boot postgres ──────────────────────────────────────────────────
blue "──▶ docker compose up -d postgres"
$COMPOSE up -d postgres

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
  [[ $SECONDS -ge $deadline ]] && fail "timeout postgres healthy"
  sleep 2
done
pass "postgres healthy"

psql_super() { $COMPOSE exec -T postgres psql -U postgres -d memorymesh -tAq -c "$1"; }

# ─── 3. Seed dati di test ──────────────────────────────────────────────
blue "──▶ Seed schema test_backup con 3 righe"
psql_super "CREATE SCHEMA IF NOT EXISTS test_backup;
            CREATE TABLE test_backup.items (
              id INT PRIMARY KEY,
              label TEXT NOT NULL,
              created_at TIMESTAMPTZ DEFAULT now()
            );
            INSERT INTO test_backup.items (id, label) VALUES
              (1, 'alpha'),
              (2, 'beta'),
              (3, 'gamma è úñîcödé');" >/dev/null
count="$(psql_super "SELECT count(*) FROM test_backup.items;")"
[[ "$count" == "3" ]] || fail "seed fallito: atteso 3 righe, trovate $count"
pass "seed 3 righe (incluso unicode)"

# ─── 4. Backup via scripts/backup-pg.sh ─────────────────────────────────
# Lo script prod richiede `age` sul PATH. Per portabilità del test usiamo
# un PATH custom con shim `age` → docker wrapper.
blue "──▶ Shim age → docker wrapper (PATH injection)"
SHIM_DIR="$WORK_DIR/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/age" <<SHIM_EOF
#!/usr/bin/env bash
# Shim che proxy'a age alla docker image $AGE_IMAGE
# (creato in test-backup.sh per bypassare l'assenza di age sul host).
#
# Monta KEYS_DIR al PATH host POSIX *esatto* così il caller può passare
# path come "/tmp/.../keys/privkey.age" e age li trova dentro container.
# MSYS_NO_PATHCONV=1 evita che Git-Bash traduca $KEYS_DIR:/... in path
# Windows lato container (lato host lo convertiamo con cygpath -w).
exec env MSYS_NO_PATHCONV=1 docker run --rm -i \\
  -v "$KEYS_DIR_MOUNT:$KEYS_DIR:ro" \\
  "$AGE_IMAGE" age "\$@"
SHIM_EOF
chmod +x "$SHIM_DIR/age"

export PATH="$SHIM_DIR:$PATH"
command -v age | grep -q "$SHIM_DIR/age" \
  || fail "shim age non è in testa al PATH ($(command -v age))"
pass "age shim attivo"

blue "──▶ scripts/backup-pg.sh primo run"
BACKUP_RECIPIENT="$KEYS_DIR/pubkey.txt" \
BACKUP_DIR="$BACKUP_DIR" \
KEEP_LAST=0 \
PG_ADMIN_USER=postgres \
bash scripts/backup-pg.sh 2>&1 | grep -v '^\[0m' | tail -10 \
  || fail "backup-pg.sh exit !=0"

# Uno e un solo file backup-*.sql.gz.enc creato
mapfile -t BACKUPS < <(ls -1 "$BACKUP_DIR"/backup-*.sql.gz.enc 2>/dev/null)
[[ ${#BACKUPS[@]} -eq 1 ]] \
  || fail "atteso 1 file backup, trovati ${#BACKUPS[@]}: ${BACKUPS[*]}"
BACKUP_FILE="${BACKUPS[0]}"
SIZE="$(wc -c < "$BACKUP_FILE" | tr -d ' ')"
[[ "$SIZE" -gt 100 ]] || fail "backup troppo piccolo: $SIZE bytes"
pass "backup creato: $(basename "$BACKUP_FILE") ($SIZE bytes)"

# ─── 5. Age header check ────────────────────────────────────────────────
blue "──▶ Verifica magic header age nel file"
head -c 32 "$BACKUP_FILE" | grep -q 'age-encryption.org' \
  || fail "header age mancante — il file non è cifrato correttamente"
pass "magic header age presente"

# ─── 6. DROP schema e restore via scripts/restore-pg.sh ─────────────────
blue "──▶ DROP schema test_backup"
psql_super "DROP SCHEMA test_backup CASCADE;" >/dev/null
# Verifica drop avvenuto
exists="$(psql_super "SELECT count(*) FROM information_schema.schemata WHERE schema_name='test_backup';")"
[[ "$exists" == "0" ]] || fail "schema test_backup ancora presente dopo DROP"
pass "schema droppato (verifica fresh restore)"

blue "──▶ scripts/restore-pg.sh"
# Il restore crea un DB fresh identico — il file contiene `DROP ... IF EXISTS;
# CREATE ...` perché backup-pg.sh usa --clean --if-exists.
FILE="$BACKUP_FILE" \
BACKUP_PRIVKEY="$KEYS_DIR/privkey.age" \
PG_ADMIN_USER=postgres \
bash scripts/restore-pg.sh 2>&1 | tail -5 \
  || fail "restore-pg.sh exit !=0"

# ─── 7. Verifica dati sopravvissuti ────────────────────────────────────
blue "──▶ Verifica 3 righe + contenuto uguale"
count="$(psql_super "SELECT count(*) FROM test_backup.items;")"
[[ "$count" == "3" ]] || fail "post-restore atteso 3 righe, trovate $count"

# Verifica contenuto esatto (incluso unicode)
vals="$(psql_super "SELECT string_agg(id || ':' || label, '|' ORDER BY id)
                    FROM test_backup.items;")"
expected="1:alpha|2:beta|3:gamma è úñîcödé"
[[ "$vals" == "$expected" ]] \
  || fail "contenuto post-restore differisce.
atteso:    $expected
ricevuto:  $vals"
pass "roundtrip integrità 3 righe + unicode preservato"

# ─── 8. Retention: secondo backup con KEEP_LAST=1 rimuove il primo ─────
blue "──▶ scripts/backup-pg.sh secondo run con KEEP_LAST=1"
# Dormiamo 61s? No, usiamo TS diverso forzando un altro timestamp.
# date -u +%Y-%m-%d-%H%M ha risoluzione minuto — se siamo nello stesso
# minuto del primo run, il nome file collide. Facciamo sleep minimo per
# cambiare il minuto O forziamo TS via env.
sleep 61  # brutta ma semplice; alternativa: patch script per TS from env

BACKUP_RECIPIENT="$KEYS_DIR/pubkey.txt" \
BACKUP_DIR="$BACKUP_DIR" \
KEEP_LAST=1 \
PG_ADMIN_USER=postgres \
bash scripts/backup-pg.sh 2>&1 | tail -5 \
  || fail "secondo backup exit !=0"

mapfile -t BACKUPS < <(ls -1t "$BACKUP_DIR"/backup-*.sql.gz.enc 2>/dev/null)
[[ ${#BACKUPS[@]} -eq 1 ]] \
  || fail "retention: atteso 1 file dopo 2° run con KEEP_LAST=1, trovati ${#BACKUPS[@]}: ${BACKUPS[*]}"
pass "retention KEEP_LAST=1 ha rimosso il backup più vecchio"

blue "──▶ Tutti i check F1-08 superati."
