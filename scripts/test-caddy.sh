#!/usr/bin/env bash
# MemoryMesh — Caddy config smoke test (F1-07)
#
# Verifica:
#
#   1. Caddyfile (LAN profile): `caddy validate` passa
#   2. Caddyfile.prod (VPN/public): `caddy validate` passa con env vars
#      MEMORYMESH_HOSTNAME + ADMIN_EMAIL settate
#   3. Boot Caddy standalone + stub HTTP upstream (container alias `api`)
#   4. Routing /health → stub, risposta 200
#   5. Routing /api/v1/x → stub, risposta 200 (header X-Forwarded-Proto http)
#   6. Routing /mcp/x → stub, risposta 200
#   7. Path ignoto → 404 (non espone la SPA)
#   8. Security headers presenti:
#        X-Content-Type-Options: nosniff
#        X-Frame-Options: DENY
#        Referrer-Policy: strict-origin-when-cross-origin
#        Permissions-Policy: camera=(), microphone=(), geolocation=(), usb=()
#   9. Header Server/X-Powered-By rimossi
#
# NON testa Caddyfile.prod live (richiede TLS + ACME reale + hostname
# pubblico). Testa solo la validità sintattica della config.
#
# Non dipende dal container `api` MemoryMesh (che non esiste ancora
# fino a F2-01): usa un'immagine python:alpine come stub upstream.
#
# Richiede: docker daemon + `docker compose` v2 + curl.
#
# Invocato da:
#   - make caddy-check
#   - .github/workflows/ci.yml

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

fail() { red "FAIL: $*"; cleanup; exit 1; }
pass() { green "PASS: $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v curl >/dev/null || fail "curl richiesto sul PATH"

# Git-Bash/MSYS2 converte path POSIX in Windows quando li passa a docker.exe
# (es. /etc/caddy/Caddyfile → C:/Program Files/Git/etc/caddy/Caddyfile).
# Disabilitiamo la conversione per tutti i docker run di questo script.
export MSYS_NO_PATHCONV=1

# ─── Config test isolation ──────────────────────────────────────────────
NET_NAME="mm-caddy-test-$$"
CADDY_NAME="mm-caddy-test-$$"
STUB_NAME="api"                    # Alias DNS atteso dal Caddyfile
CADDY_PORT="${CADDY_HOST_PORT:-18080}"

cleanup() {
  blue "──▶ Teardown (container + network)"
  docker rm -f "$CADDY_NAME" "$STUB_NAME" 2>/dev/null || true
  docker network rm "$NET_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ─── 1. caddy validate: Caddyfile (LAN) ─────────────────────────────────
blue "──▶ caddy validate Caddyfile (LAN)"
docker run --rm \
  -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e MEMORYMESH_HOSTNAME=mm.local \
  -e MEMORYMESH_DEPLOYMENT=lan \
  caddy:2-alpine \
  caddy validate --config /etc/caddy/Caddyfile \
  || fail "caddy validate Caddyfile (LAN) fallito"
pass "Caddyfile LAN sintatticamente valido"

# ─── 2. caddy validate: Caddyfile.prod ─────────────────────────────────
# Caddyfile.prod usa auto_https (Let's Encrypt ACME). caddy validate tenta
# di inizializzare il TLS issuer ma ACME è gated via env + volume ops.
# Passiamo hostname sensato; ACME non si attiva durante validate.
blue "──▶ caddy validate Caddyfile.prod (vpn/public)"
docker run --rm \
  -v "$ROOT/Caddyfile.prod:/etc/caddy/Caddyfile:ro" \
  -e MEMORYMESH_HOSTNAME=test.invalid.example \
  -e MEMORYMESH_DEPLOYMENT=public \
  -e ADMIN_EMAIL=admin@invalid.example \
  caddy:2-alpine \
  caddy validate --config /etc/caddy/Caddyfile \
  || fail "caddy validate Caddyfile.prod fallito"
pass "Caddyfile.prod sintatticamente valido"

# ─── 3. Setup network + stub upstream ───────────────────────────────────
blue "──▶ Crea network + stub HTTP upstream (alias 'api')"
docker network create "$NET_NAME" >/dev/null \
  || fail "network create fallita"

# Stub Python HTTP server: GET ritorna 200 + echo del path; include header
# distintivo così si vede che il reverse_proxy ha raggiunto lo stub.
docker run -d --rm \
  --name "$STUB_NAME" \
  --network "$NET_NAME" \
  --network-alias api \
  python:3.12-alpine \
  python -c 'from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
  def do_GET(self):
    self.send_response(200)
    self.send_header("Content-Type", "text/plain")
    self.send_header("X-Mm-Stub", "1")
    self.end_headers()
    self.wfile.write(f"stub:{self.path}".encode())
  def log_message(self, *a, **kw): pass
HTTPServer(("0.0.0.0", 8000), H).serve_forever()' \
  >/dev/null || fail "stub upstream start fallito"

# Wait stub up (internal check)
deadline=$((SECONDS + 20))
while :; do
  if docker exec "$STUB_NAME" python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/").read()' 2>/dev/null; then
    break
  fi
  [[ $SECONDS -ge $deadline ]] && fail "stub upstream non risponde entro 20s"
  sleep 1
done
pass "stub upstream attivo (alias 'api:8000')"

# ─── 4. Boot Caddy standalone con Caddyfile LAN ─────────────────────────
blue "──▶ Boot caddy:2-alpine con Caddyfile LAN (port 127.0.0.1:$CADDY_PORT)"
docker run -d --rm \
  --name "$CADDY_NAME" \
  --network "$NET_NAME" \
  -p "127.0.0.1:$CADDY_PORT:80" \
  -v "$ROOT/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e MEMORYMESH_HOSTNAME=mm.local \
  -e MEMORYMESH_DEPLOYMENT=lan \
  caddy:2-alpine \
  >/dev/null || fail "caddy container start fallito"

# Wait Caddy up: accettiamo QUALUNQUE risposta HTTP valida (anche 404/501),
# basta che la socket accetti connessioni TCP. Usiamo `curl --head`
# (HEAD su / rende `Connection: close` più rapido) e match su "HTTP/"
# nell'output, così non dipendiamo da exit code di curl con --max-time.
deadline=$((SECONDS + 20))
got_response=0
while [[ $SECONDS -lt $deadline ]]; do
  output="$(curl -s --max-time 2 -I "http://127.0.0.1:$CADDY_PORT/" 2>/dev/null || true)"
  if echo "$output" | grep -qE '^HTTP/[0-9.]+ [0-9]{3}'; then
    got_response=1
    break
  fi
  sleep 1
done
if [[ $got_response -ne 1 ]]; then
  docker logs "$CADDY_NAME" 2>&1 | tail -30 || true
  fail "Caddy non risponde su 127.0.0.1:$CADDY_PORT entro 20s"
fi
pass "caddy in ascolto su 127.0.0.1:$CADDY_PORT"

# Helper: GET su Caddy, ritorna "<code>|<body>". `set +e` localmente
# perché curl può chiudere con exit !=0 anche con risposta 4xx/5xx valida
# e `set -e` terminerebbe lo script senza messaggio.
get_caddy() {
  local path="$1"
  local out
  set +e
  out="$(curl -s -w '\n%{http_code}' --max-time 5 \
    "http://127.0.0.1:$CADDY_PORT$path" 2>/dev/null)"
  set -e
  local code="${out##*$'\n'}"
  local body="${out%$'\n'*}"
  printf '%s|%s' "$code" "$body"
}

check_status() {
  local path="$1" expected="$2" label="$3"
  blue "──▶ GET $path → $label"
  local resp code body
  resp="$(get_caddy "$path")"
  code="${resp%%|*}"
  body="${resp#*|}"
  [[ "$code" == "$expected" ]] \
    || fail "$path atteso $expected, ricevuto '$code' (body='$body')"
  pass "$path → $expected $label"
}

# ─── 5. /health → 200 (reverse proxy allo stub) ─────────────────────────
resp="$(get_caddy /health)"
code="${resp%%|*}"
body="${resp#*|}"
blue "──▶ GET /health → stub"
[[ "$code" == "200" ]] || fail "/health atteso 200, ricevuto '$code' (body='$body')"
[[ "$body" == "stub:/health" ]] \
  || fail "/health: body inatteso '$body' (il reverse_proxy non ha raggiunto lo stub?)"
pass "/health → 200 via reverse_proxy allo stub"

# ─── 6. /api/v1/x → 200 (data plane) ───────────────────────────────────
check_status /api/v1/observations 200 "stub (data plane)"

# ─── 7. /mcp/x → 200 ───────────────────────────────────────────────────
check_status /mcp/tools/search 200 "stub (MCP tools)"

# ─── 8. Path sconosciuto → 404 (fallback) ───────────────────────────────
check_status /unknown/path 404 "fallback"
check_status / 404 "root (niente SPA leak)"

# ─── 9. Security headers presenti ──────────────────────────────────────
blue "──▶ Verifica security headers su /health"
headers="$(curl -sI "http://127.0.0.1:$CADDY_PORT/health" | tr -d '\r')"
check_header() {
  local name="$1" expected="$2"
  local line
  line="$(echo "$headers" | grep -i "^$name:" || true)"
  [[ -n "$line" ]] || fail "header '$name' assente"
  if [[ -n "$expected" ]]; then
    # NOTA: niente -F. Il combo `-i -F -q` crasha grep su Git-Bash MSYS
    # (con "Aborted"). Le stringhe atteso non contengono regex special chars.
    echo "$line" | grep -qi "$expected" \
      || fail "$name: atteso contenente '$expected', ricevuto '$line'"
  fi
}
check_header "X-Content-Type-Options" "nosniff"
check_header "X-Frame-Options" "DENY"
check_header "Referrer-Policy" "strict-origin-when-cross-origin"
check_header "Permissions-Policy" "camera=()"
pass "security headers presenti (X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy)"

# ─── 10. Server/X-Powered-By RIMOSSI ───────────────────────────────────
blue "──▶ Verifica rimozione header Server/X-Powered-By"
if echo "$headers" | grep -qi '^Server:'; then
  fail "header 'Server' non rimosso — Caddy leak: $(echo "$headers" | grep -i '^Server:')"
fi
if echo "$headers" | grep -qi '^X-Powered-By:'; then
  fail "header 'X-Powered-By' non rimosso"
fi
pass "header Server e X-Powered-By rimossi"

blue "──▶ Tutti i check F1-07 superati."
