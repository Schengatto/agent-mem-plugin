#!/usr/bin/env bash
# MemoryMesh — docker-compose smoke test (F1-02)
#
# Verifica che docker-compose.yml e docker-compose.prod.yml siano sintatticamente
# validi, che tutti i servizi attesi siano dichiarati, che gli healthcheck e le
# direttive di hardening essenziali siano presenti sui servizi infrastrutturali.
#
# Invocato da:
#   - make compose-check  (sviluppatore locale)
#   - .github/workflows/ci.yml  (CI su push/PR)
#
# Dipendenze: docker (compose v2), python3.
# Exit 0 = tutti i check passano; exit != 0 = fallimento.

set -euo pipefail

# ─── Utility ───────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail()  { red "FAIL: $*"; exit 1; }
pass()  { green "PASS: $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ─── 1. Env file CI-safe ──────────────────────────────────────────────────
# Evita di leggere .env reale (potrebbe avere secret). Usa un file temporaneo
# con placeholder che soddisfano le variabili `:?` required.
ENV_FILE="$(mktemp -t mm-ci-env.XXXXXX)"
trap 'rm -f "$ENV_FILE"' EXIT

cp .env.example "$ENV_FILE"
# Sostituisce i placeholder CHANGE_ME e fornisce i campi richiesti dal prod override.
# NB: questi valori sono puramente sintattici — NON avviano nulla.
sed -i \
  -e 's/^PG_ADMIN_PASSWORD=.*/PG_ADMIN_PASSWORD=ci-placeholder/' \
  -e 's/^PG_MM_API_PASSWORD=.*/PG_MM_API_PASSWORD=ci-placeholder/' \
  -e 's/^PG_MM_WORKER_PASSWORD=.*/PG_MM_WORKER_PASSWORD=ci-placeholder/' \
  -e 's/^PG_MM_ADMIN_PASSWORD=.*/PG_MM_ADMIN_PASSWORD=ci-placeholder/' \
  -e 's/^REDIS_PASSWORD=.*/REDIS_PASSWORD=ci-placeholder/' \
  -e 's/^SECRET_KEY=.*/SECRET_KEY=ci-placeholder-64hex-0000000000000000000000000000000000000000000000000000000000/' \
  "$ENV_FILE"
printf '\nADMIN_EMAIL=ci@example.invalid\nMEMORYMESH_HOSTNAME=ci.example.invalid\n' >> "$ENV_FILE"

# ─── 2. Syntax validation (base + prod override) ──────────────────────────
blue "──▶ Validazione sintassi compose files"
docker compose --env-file "$ENV_FILE" -f docker-compose.yml config --quiet \
  || fail "docker-compose.yml non valido"
pass "docker-compose.yml syntax OK"

docker compose --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.prod.yml config --quiet \
  || fail "docker-compose.prod.yml override non valido"
pass "docker-compose.prod.yml override syntax OK"

# ─── 3. Strutturale: servizi, healthcheck, hardening ──────────────────────
blue "──▶ Audit struttura compose (servizi, healthcheck, hardening)"

# Il `config` standard omette i servizi con profile non attivo. Per vederli tutti
# nell'output JSON, si passa `--profile` per ciascun profilo gate.
CONFIG_JSON="$(docker compose --env-file "$ENV_FILE" \
  --profile lan --profile ollama \
  -f docker-compose.yml config --format json)"

python3 - "$CONFIG_JSON" <<'PY'
import json, sys

cfg = json.loads(sys.argv[1])
services = cfg.get("services", {})
networks = cfg.get("networks", {})
volumes  = cfg.get("volumes", {})

EXPECTED_SERVICES = {
    "postgres", "redis", "ollama", "api",
    "embed-worker", "distillation-worker", "caddy", "avahi",
}
EXPECTED_NETWORKS = {"mm_ingress", "mm_internal"}
EXPECTED_VOLUMES  = {"pg_data", "redis_data", "ollama_models", "caddy_data", "caddy_config"}

# Servizi che DEVONO avere healthcheck (F1-02 DoD).
# Workers esclusi: healthcheck semantico definito in F3-01 / F5-07 quando
# il loop consumer implementerà l'heartbeat Redis.
MUST_HAVE_HEALTHCHECK = {"postgres", "redis", "ollama", "api", "caddy"}

# Hardening baseline — cap_drop=ALL su tutti i servizi applicativi.
# avahi è esentato perché network_mode=host richiede NET_RAW/NET_BIND_SERVICE
# e il cap_drop ALL è già presente con explicit cap_add.
MUST_HAVE_CAP_DROP_ALL = {
    "postgres", "redis", "ollama", "api",
    "embed-worker", "distillation-worker", "caddy", "avahi",
}

errors = []

missing = EXPECTED_SERVICES - set(services)
if missing:
    errors.append(f"servizi mancanti: {sorted(missing)}")
unexpected = set(services) - EXPECTED_SERVICES
if unexpected:
    errors.append(f"servizi inattesi: {sorted(unexpected)}")

missing_net = EXPECTED_NETWORKS - set(networks)
if missing_net:
    errors.append(f"reti mancanti: {sorted(missing_net)}")

missing_vol = EXPECTED_VOLUMES - set(volumes)
if missing_vol:
    errors.append(f"volumi mancanti: {sorted(missing_vol)}")

for svc in MUST_HAVE_HEALTHCHECK:
    if svc not in services:
        continue  # gia' segnalato come mancante sopra
    hc = services[svc].get("healthcheck")
    if not hc or not hc.get("test"):
        errors.append(f"servizio '{svc}' senza healthcheck")

for svc in MUST_HAVE_CAP_DROP_ALL:
    if svc not in services:
        continue
    cap_drop = services[svc].get("cap_drop") or []
    # Docker compose normalizza in lista di stringhe maiuscole
    if "ALL" not in [c.upper() for c in cap_drop]:
        errors.append(f"servizio '{svc}' senza cap_drop: [ALL]")

# mm_internal DEVE essere internal=true (no egress internet default)
internal_flag = networks.get("mm_internal", {}).get("internal")
if internal_flag is not True:
    errors.append("rete 'mm_internal' deve avere internal: true")

# Caddy DEVE avere pubblicate 80/443 (unico ingress)
caddy_ports = [p for p in services.get("caddy", {}).get("ports", []) if isinstance(p, dict)]
target_ports = {int(p.get("target", 0)) for p in caddy_ports}
if not {80, 443}.issubset(target_ports):
    errors.append(f"caddy deve esporre 80 e 443, trovati target={sorted(target_ports)}")

# api/worker NON DEVONO avere `ports:` (isolamento ingress tramite caddy)
for svc in ("api", "embed-worker", "distillation-worker", "postgres", "redis"):
    if svc in services and services[svc].get("ports"):
        errors.append(f"servizio '{svc}' non deve esporre port (ingress solo via caddy)")

if errors:
    print("AUDIT FAIL:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"Audit OK · {len(services)} servizi · "
      f"{len(networks)} reti · {len(volumes)} volumi · "
      f"{len(MUST_HAVE_HEALTHCHECK)} healthcheck richiesti presenti")
PY

pass "Audit strutturale OK"

blue "──▶ Tutti i check F1-02 superati."
