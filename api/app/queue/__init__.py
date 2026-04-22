"""Redis Streams queue (F1-05).

Naming convention e helper per tutti i consumer async del sistema:

    mm:embed_jobs     → group embed-workers      (F3-01)
    mm:distill_jobs   → group distill-workers    (F5-01)
    mm:tighten_jobs   → group tighten-workers    (F2-07b)

Ogni stream ha un DLQ (`<stream>:dlq`) dove i worker pubblicano i messaggi che
hanno fallito oltre `MAX_ATTEMPTS`. Il DLQ NON ha consumer group — è
ispezionato manualmente via admin UI o `redis-cli XRANGE`.

Re-export delle primitive pubbliche:
    - STREAM_* / GROUP_* / DLQ_*  costanti
    - EmbedJob, DistillJob, TightenJob, DlqEnvelope  Pydantic contracts
    - ensure_stream_group  helper idempotente
"""

from app.queue.schemas import DlqEnvelope, DistillJob, EmbedJob, TightenJob
from app.queue.streams import (
    DLQ_DISTILL_JOBS,
    DLQ_EMBED_JOBS,
    DLQ_TIGHTEN_JOBS,
    GROUP_DISTILL_WORKERS,
    GROUP_EMBED_WORKERS,
    GROUP_TIGHTEN_WORKERS,
    STREAM_DISTILL_JOBS,
    STREAM_EMBED_JOBS,
    STREAM_TIGHTEN_JOBS,
    ensure_stream_group,
)

__all__ = [
    # streams.py
    "STREAM_EMBED_JOBS",
    "STREAM_DISTILL_JOBS",
    "STREAM_TIGHTEN_JOBS",
    "DLQ_EMBED_JOBS",
    "DLQ_DISTILL_JOBS",
    "DLQ_TIGHTEN_JOBS",
    "GROUP_EMBED_WORKERS",
    "GROUP_DISTILL_WORKERS",
    "GROUP_TIGHTEN_WORKERS",
    "ensure_stream_group",
    # schemas.py
    "EmbedJob",
    "DistillJob",
    "TightenJob",
    "DlqEnvelope",
]
