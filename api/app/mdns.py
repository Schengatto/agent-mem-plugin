"""mDNS broadcaster (F1-09) — Zeroconf-based.

Annuncia il server MemoryMesh sulla LAN come ``_memorymesh._tcp.local`` così
il plugin Claude Code e l'adapter Codex possono fare discovery zero-touch
(vedi ARCHITECTURE.md §Zero-Touch Onboarding).

Due path di deployment:

1. **Python in-process (questo modulo)** — usato quando il container ``api``
   ha ``network_mode: host`` o è in rete bridge con avahi-reflector sidecar.
   Pro: nessuna dipendenza extra (solo ``zeroconf`` library).
   Con: il container deve vedere la LAN multicast (228.0.0.251:5353).

2. **Avahi sidecar** (``security/avahi-memorymesh.service``) — path cross-OS.
   Pro: compatibile con Docker Desktop Mac/Win via AVAHI_REFLECTOR.
   Con: container extra sempre up.

Usage standalone (senza FastAPI):

    >>> from app.mdns import ZeroconfBroadcaster
    >>> b = ZeroconfBroadcaster(hostname="mm.local", port=80)
    >>> b.start()
    >>> # ... runtime ...
    >>> b.stop()

Usage FastAPI (F2-01+):

    @app.on_event("startup")
    async def _start_mdns() -> None:
        app.state.mdns = ZeroconfBroadcaster.from_settings(settings)
        app.state.mdns.start()

    @app.on_event("shutdown")
    async def _stop_mdns() -> None:
        app.state.mdns.stop()
"""

from __future__ import annotations

import socket
from dataclasses import dataclass
from ipaddress import IPv4Address, ip_address
from typing import Iterable

from zeroconf import InterfaceChoice, IPVersion, ServiceInfo, Zeroconf

# Service type canonico — tutti i plugin/adapter cercano questo.
SERVICE_TYPE: str = "_memorymesh._tcp.local."
"""Il trailing dot è parte della convenzione mDNS (FQDN absoluto)."""

DEFAULT_PORT: int = 80
"""Porta di default del listener Caddy (profile LAN HTTP)."""


@dataclass(frozen=True)
class BroadcastConfig:
    """Parametri statici del broadcast. Immutable per side-effect safety."""

    hostname: str
    """Es. ``mm.local``. Appare come ``MemoryMesh on mm``."""

    port: int = DEFAULT_PORT
    """Porta HTTP/S dell'ingress (di solito Caddy 80 o 443)."""

    version: str = "1.0"
    """Mostrato nel TXT record — il plugin può filtrare per version matching."""

    ip: str | None = None
    """IPv4 address to advertise. Se None, zeroconf auto-rileva interfaccia."""

    def __post_init__(self) -> None:
        if not self.hostname:
            raise ValueError("hostname must be non-empty")
        if not (0 < self.port < 65536):
            raise ValueError(f"port out of range: {self.port}")
        if self.ip is not None:
            try:
                if not isinstance(ip_address(self.ip), IPv4Address):
                    raise ValueError("only IPv4 supported currently")
            except ValueError as e:
                raise ValueError(f"invalid ip '{self.ip}': {e}") from e


def _resolve_local_ipv4() -> str:
    """Rileva l'IPv4 primario della macchina senza internet egress.

    Trick standard: apre socket UDP verso 8.8.8.8:53 (non invia nulla),
    poi legge socket.getsockname()[0]. Funziona offline.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 53))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def _build_service_info(cfg: BroadcastConfig) -> ServiceInfo:
    """Traduce la config in ``zeroconf.ServiceInfo`` pronto da register."""
    ip_str = cfg.ip or _resolve_local_ipv4()

    # Il "name" completo di ServiceInfo è <instance>.<type>
    # Il plugin ricerca <type> (_memorymesh._tcp.local.) e discrimina sui
    # singoli istanti. "MemoryMesh on <host>" è leggibile dall'admin UI.
    instance = f"MemoryMesh on {cfg.hostname.split('.')[0]}"
    name = f"{instance}.{SERVICE_TYPE}"

    # Server field: hostname pubblicato come AAAA record mDNS. Deve terminare
    # con ".local." per resolverlo via mDNS (niente DNS ricorsivo).
    server = cfg.hostname if cfg.hostname.endswith(".local.") else (
        cfg.hostname.removesuffix(".") + ".local."
    )

    return ServiceInfo(
        type_=SERVICE_TYPE,
        name=name,
        addresses=[socket.inet_aton(ip_str)],
        port=cfg.port,
        server=server,
        # TXT record key=value. Il plugin fa parse per version matching +
        # capability sniffing. "service" è ridondante ma utile per debug
        # con dns-sd / avahi-browse -a.
        properties={
            b"version": cfg.version.encode("utf-8"),
            b"service": b"memorymesh",
        },
    )


class ZeroconfBroadcaster:
    """Lifecycle wrapper (start/stop) del service publish mDNS."""

    def __init__(
        self,
        hostname: str,
        port: int = DEFAULT_PORT,
        version: str = "1.0",
        ip: str | None = None,
        interfaces: Iterable[str] | None = None,
    ) -> None:
        self.config = BroadcastConfig(
            hostname=hostname, port=port, version=version, ip=ip,
        )
        # ``interfaces=None`` = zeroconf usa tutte le interfacce disponibili.
        # Lista esplicita = restringe a subnet specifiche (prod multi-NIC).
        self._interfaces = list(interfaces) if interfaces else None
        self._zc: Zeroconf | None = None
        self._info: ServiceInfo | None = None

    @property
    def is_running(self) -> bool:
        return self._zc is not None

    def start(self) -> ServiceInfo:
        """Registra il servizio. Idempotente: ri-chiamare è no-op."""
        if self._zc is not None:
            assert self._info is not None
            return self._info

        self._info = _build_service_info(self.config)
        # Zeroconf 0.135+ vuole una lista di IP o InterfaceChoice.Default.
        # None non è accettato.
        interfaces = self._interfaces if self._interfaces else InterfaceChoice.Default
        self._zc = Zeroconf(
            interfaces=interfaces,
            ip_version=IPVersion.V4Only,
        )
        self._zc.register_service(self._info)
        return self._info

    def stop(self) -> None:
        """Unregister + close. Idempotente."""
        if self._zc is None:
            return
        try:
            if self._info is not None:
                self._zc.unregister_service(self._info)
        finally:
            self._zc.close()
            self._zc = None
            self._info = None
