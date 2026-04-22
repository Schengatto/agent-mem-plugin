"""Redis Streams: nomi, consumer groups, helper ensure_stream_group (F1-05).

Convention:
    - prefisso `mm:` su tutti i key Redis → evita collisioni con altri tenant
      che potrebbero condividere il Redis (multi-tenant futuro, dev shared).
    - stream name usa lo schema `mm:<domain>_jobs`.
    - consumer group usa lo schema `<domain>-workers` (no prefisso mm: perché
      il group è scoped al singolo stream, non globale).
    - dead-letter queue usa lo schema `<stream>:dlq` (no consumer group — si
      ispeziona via admin UI o redis-cli XRANGE).

I worker (F3-01, F5-01, F2-07b) si autocreano il group all'avvio chiamando
`ensure_stream_group`. `MKSTREAM` garantisce idempotenza anche se il stream
non esiste ancora.
"""

from __future__ import annotations

from redis.asyncio import Redis

# ─── Stream names ─────────────────────────────────────────────────────────

STREAM_EMBED_JOBS: str = "mm:embed_jobs"
"""Pubblicato da POST /observations (F2-03) dopo INSERT. Il worker (F3-01) lo
consuma per calcolare `embedding` via provider (Gemini default, Ollama opt-in).
"""

STREAM_DISTILL_JOBS: str = "mm:distill_jobs"
"""Pubblicato da CRON 03:00 (APScheduler in distillation-worker) o dall'admin
via `/admin/distill/trigger`. Il worker (F5-01) esegue prune → merge → tighten
→ decay → extract vocab → rebuild manifest per il progetto indicato.
"""

STREAM_TIGHTEN_JOBS: str = "mm:tighten_jobs"
"""Pubblicato quando un'observation eccede `MAX_OBS_TOKENS` al write (F2-07b).
Il worker (parte di F5-01, step tighten) accorcia il content preservando
meaning e rigenera embedding.
"""

# ─── Consumer groups ──────────────────────────────────────────────────────

GROUP_EMBED_WORKERS: str = "embed-workers"
GROUP_DISTILL_WORKERS: str = "distill-workers"
GROUP_TIGHTEN_WORKERS: str = "tighten-workers"

# ─── Dead-letter queues ───────────────────────────────────────────────────

DLQ_EMBED_JOBS: str = f"{STREAM_EMBED_JOBS}:dlq"
DLQ_DISTILL_JOBS: str = f"{STREAM_DISTILL_JOBS}:dlq"
DLQ_TIGHTEN_JOBS: str = f"{STREAM_TIGHTEN_JOBS}:dlq"

# ─── Helper: bootstrap idempotente stream + group ─────────────────────────


async def ensure_stream_group(
    redis: Redis,
    stream: str,
    group: str,
    start_id: str = "0",
) -> bool:
    """Crea `group` su `stream` con `MKSTREAM`. Idempotente.

    Args:
        redis: client Redis asyncio connesso.
        stream: nome completo dello stream (es. ``mm:embed_jobs``).
        group: nome del consumer group (es. ``embed-workers``).
        start_id: ID di partenza per il group.
            - ``"0"`` (default) — legge anche i messaggi arretrati già in stream.
              Corretto per worker che riprendono dopo un restart.
            - ``"$"`` — legge solo messaggi NUOVI dopo la creazione. Corretto
              per stream ad alto throughput dove backfill è indesiderato.

    Returns:
        True se il group è stato creato ex-novo, False se esisteva già.
        (Utile per logging: il bootstrap iniziale logga al primo True.)

    Raises:
        redis.exceptions.ResponseError: per errori diversi da BUSYGROUP
          (es. stream key occupata da type incompatibile).
    """
    try:
        await redis.execute_command(
            "XGROUP", "CREATE", stream, group, start_id, "MKSTREAM"
        )
        return True
    except Exception as e:
        # `BUSYGROUP Consumer Group name already exists` — atteso a ogni boot
        # successivo al primo. L'errore è identificabile dal messaggio: il
        # redis-py 5.x lancia ResponseError senza sottoclasse specifica.
        if "BUSYGROUP" in str(e):
            return False
        raise
