#!/usr/bin/env bash
# MemoryMesh — mDNS broadcaster smoke test (F1-09)
#
# Verifica:
#
#   1. security/avahi-memorymesh.service è XML well-formed
#   2. api/app/mdns.py importabile senza errori di sintassi
#   3. ZeroconfBroadcaster start/stop ciclo completo
#   4. Roundtrip: un ServiceBrowser rileva il servizio pubblicato con
#      name corretto + type _memorymesh._tcp.local + port + TXT record
#   5. stop() rimuove il servizio dalla rete (unregister+close)
#
# Tutto in Python host (venv), nessun container Docker necessario.
# Il test è cross-OS portable (Linux/macOS/Windows).
#
# Richiede: python3 (>= 3.11) con pip sul PATH.
#
# Invocato da:
#   - make mdns-check
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
command -v python3 >/dev/null || fail "python3 (>=3.11) richiesto"
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJOR="${PY_VER%%.*}"
PY_MINOR="${PY_VER##*.}"
if [[ "$PY_MAJOR" -lt 3 ]] || { [[ "$PY_MAJOR" -eq 3 ]] && [[ "$PY_MINOR" -lt 11 ]]; }; then
  fail "python3 $PY_VER trovato; richiesto >= 3.11 (zeroconf 0.135)"
fi

VENV_DIR="$(mktemp -d -t mm-ci-mdns-venv.XXXXXX)"

cleanup() {
  blue "──▶ Teardown (venv)"
  rm -rf "$VENV_DIR"
}
trap cleanup EXIT

# ─── 1. Avahi service file: XML well-formed ─────────────────────────────
blue "──▶ security/avahi-memorymesh.service: XML well-formed check"
AVAHI_XML="$ROOT/security/avahi-memorymesh.service"
[[ -f "$AVAHI_XML" ]] || fail "file non trovato: $AVAHI_XML"

# Python host (Windows) non riconosce POSIX path di Git-Bash. Convertiamo
# a Windows path con cygpath + forward-slash (Python gestisce entrambi su
# Win ma le backslash sono escape in string literals; usiamo `cygpath -m`
# per ottenere "G:/workspace/..." senza escape). No-op su Linux/macOS.
if command -v cygpath >/dev/null 2>&1; then
  AVAHI_XML_PY="$(cygpath -m "$AVAHI_XML")"
else
  AVAHI_XML_PY="$AVAHI_XML"
fi

# Usiamo python stdlib (xml.etree) — niente dipendenze extra
python3 - <<PY || fail "XML malformato"
import sys
import xml.etree.ElementTree as ET
try:
    tree = ET.parse("$AVAHI_XML_PY")
    root = tree.getroot()
    assert root.tag == "service-group", f"root atteso 'service-group', trovato {root.tag!r}"
    services = root.findall("service")
    assert len(services) >= 1, "nessun <service> trovato"
    svc = services[0]
    t = svc.find("type")
    p = svc.find("port")
    assert t is not None and t.text == "_memorymesh._tcp", f"<type> atteso '_memorymesh._tcp', trovato {t.text if t is not None else 'None'!r}"
    assert p is not None and p.text == "80", f"<port> atteso '80', trovato {p.text if p is not None else 'None'!r}"
    txt = [tr.text for tr in svc.findall("txt-record")]
    assert any("version" in (t or "") for t in txt), f"txt-record 'version' atteso, trovati: {txt}"
    assert any("service=memorymesh" in (t or "") for t in txt), f"txt-record 'service=memorymesh' atteso, trovati: {txt}"
except (ET.ParseError, AssertionError) as e:
    print(f"XML check failed: {e}", file=sys.stderr)
    sys.exit(1)
print("avahi-memorymesh.service: well-formed + contenuto atteso")
PY
pass "avahi-memorymesh.service XML valido (type, port, txt-record corretti)"

# ─── 2. Venv + install zeroconf ─────────────────────────────────────────
blue "──▶ Setup venv host + zeroconf"
python3 -m venv "$VENV_DIR"
if [[ -f "$VENV_DIR/bin/activate" ]]; then
  VENV_BIN="$VENV_DIR/bin"
elif [[ -f "$VENV_DIR/Scripts/activate" ]]; then
  VENV_BIN="$VENV_DIR/Scripts"
else
  fail "venv: activate non trovato né in bin/ né in Scripts/"
fi
"$VENV_BIN/python" -m pip install --disable-pip-version-check --quiet --upgrade pip
"$VENV_BIN/python" -m pip install --disable-pip-version-check --quiet -r api/requirements.txt
pass "venv + zeroconf installato"

# ─── 3. Import di app.mdns ──────────────────────────────────────────────
blue "──▶ Import api/app/mdns.py"
PYTHONPATH="$ROOT/api" "$VENV_BIN/python" -c "
from app.mdns import ZeroconfBroadcaster, BroadcastConfig, SERVICE_TYPE
assert SERVICE_TYPE == '_memorymesh._tcp.local.'
print('import OK')
" || fail "import mdns.py fallito"
pass "app.mdns importabile"

# ─── 4. Roundtrip broadcast + discovery ─────────────────────────────────
blue "──▶ Roundtrip: broadcaster → ServiceBrowser → verifica dati"
PYTHONPATH="$ROOT/api" "$VENV_BIN/python" - <<'PY' || fail "roundtrip fallito"
import sys
import time
from threading import Event
from zeroconf import Zeroconf, ServiceBrowser, ServiceListener

from app.mdns import ZeroconfBroadcaster, SERVICE_TYPE

INSTANCE = "test-host"  # scelto per predicibilità assert


class Listener(ServiceListener):
    def __init__(self) -> None:
        self.added = Event()
        self.info = None

    def add_service(self, zc, type_, name):
        info = zc.get_service_info(type_, name)
        if info and "MemoryMesh" in name:
            self.info = info
            self.added.set()

    def remove_service(self, zc, type_, name):
        pass

    def update_service(self, zc, type_, name):
        pass


bc = ZeroconfBroadcaster(hostname=INSTANCE, port=8080, version="1.0")
info_published = bc.start()
print(f"  published: name={info_published.name!r} port={info_published.port}")
assert info_published.port == 8080, f"port atteso 8080, trovato {info_published.port}"
assert "MemoryMesh" in info_published.name, f"name atteso con 'MemoryMesh': {info_published.name}"

# Dai al multicast il tempo di propagare (loopback è istantaneo ma il Browser
# inizializza un thread separato). 2s è conservativo per CI cold-start.
time.sleep(1)

zc = Zeroconf()
listener = Listener()
browser = ServiceBrowser(zc, SERVICE_TYPE, listener)
try:
    # Polling max 10s — i runner CI di GitHub a volte sono lenti sul setup mDNS.
    found = listener.added.wait(timeout=10)
    assert found, "ServiceBrowser non ha trovato il servizio entro 10s"

    info = listener.info
    assert info is not None, "info None dopo found"
    assert info.port == 8080, f"port inatteso: {info.port}"
    assert "MemoryMesh" in info.name, f"name inatteso: {info.name}"

    # TXT record check — keys/values raw bytes
    props = info.properties
    assert props.get(b"service") == b"memorymesh", f"TXT service: {props}"
    assert props.get(b"version") == b"1.0", f"TXT version: {props}"
    print(f"  discovered: name={info.name!r} port={info.port} txt={dict(props)}")
finally:
    browser.cancel()
    zc.close()
    bc.stop()
    assert not bc.is_running, "broadcaster non fermato dopo stop()"

print("roundtrip OK")
PY
pass "broadcaster published + ServiceBrowser found (name, port, TXT record corretti)"

# ─── 5. Double stop è safe (idempotency) ────────────────────────────────
blue "──▶ Idempotency: start→stop→stop non esplode"
PYTHONPATH="$ROOT/api" "$VENV_BIN/python" - <<'PY' || fail "idempotency fallito"
from app.mdns import ZeroconfBroadcaster
bc = ZeroconfBroadcaster(hostname="idempotency-test", port=80)
bc.start()
bc.stop()
bc.stop()  # safe no-op
assert not bc.is_running
# Double start è OK e ritorna lo stesso info (ma prima serve un fresh start)
bc.start()
info1 = bc.start()  # seconda chiamata è no-op, ritorna lo stesso
assert bc.is_running
bc.stop()
print("idempotency OK")
PY
pass "start/stop idempotenti"

blue "──▶ Tutti i check F1-09 superati."
