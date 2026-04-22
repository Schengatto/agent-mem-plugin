"""Pydantic contract per i messaggi pubblicati sulle Redis Streams (F1-05).

Ogni job è serializzato come flat dict di stringhe (richiesto da Redis Streams
XADD — non supporta JSON nativo). I Pydantic model centralizzano:
    - validazione dei campi publisher-side
    - coerenza del schema fra publisher e consumer (stesso file importato)
    - versioning: il campo `v` consente di evolvere il contratto senza
      rompere i consumer esistenti (F2-07b + F3-01 leggono stesso schema).

Convenzioni serializzazione (applicate uniformemente da `to_stream_fields` dei
futuri publisher in F2-03/F2-07b):
    - UUID → `str(uuid)` hex lowercase con trattini
    - int → `str(n)`
    - enum/Literal → string
    - lista di str → `",".join(...)` (nessuna lista contiene `,`)
    - datetime → ISO-8601 con timezone
Mai serializzare oggetti annidati (JSON dentro stream field) — usa un campo
separato per ogni proprietà.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class _StreamPayload(BaseModel):
    """Base class: extra='forbid' + versioning."""

    model_config = ConfigDict(extra="forbid", frozen=False)

    v: int = Field(default=1, description="Schema version for forward compat")
    attempt: int = Field(
        default=0,
        ge=0,
        description="Numero di retry già tentati (incrementato dal worker)",
    )


class EmbedJob(_StreamPayload):
    """Embedding calculation per una observation.

    Pubblicato da POST /observations (F2-03) dopo INSERT della riga (con
    `embedding IS NULL`). Il worker (F3-01) legge la observation, chiama il
    provider embed, UPDATE observations SET embedding = [...].
    """

    obs_id: int = Field(gt=0)
    project_id: UUID
    content_kind: Literal["observation", "manifest_entry", "vocab"] = "observation"


class DistillJob(_StreamPayload):
    """Distillazione notturna per un progetto.

    Pubblicato da:
        - APScheduler CRON (default 03:00 UTC) in `distillation-worker`
        - admin manual trigger via `POST /admin/distill`
        - retry dal DLQ dopo admin review
    """

    project_id: UUID
    trigger: Literal["cron", "manual", "retry"] = "cron"


class TightenJob(_StreamPayload):
    """Tightening di un'observation troppo lunga.

    Pubblicato quando il capping a `MAX_OBS_TOKENS` in POST /observations
    (F2-07b) tronca il content ma conserva `metadata.full_content`. Il worker
    rigenera una versione compressa via LLM + nuovo embedding.
    """

    obs_id: int = Field(gt=0)
    project_id: UUID
    reason: Literal["capped_at_write", "distill_cluster"] = "capped_at_write"


class DlqEnvelope(BaseModel):
    """Envelope per i messaggi scaricati nella DLQ.

    Il publisher DLQ è il worker stesso, dopo aver esaurito `MAX_ATTEMPTS`
    (default 5 per embed, 3 per distill). Il campo `payload` contiene il dict
    serializzato del job originale — non lo deserializziamo qui perché la DLQ
    è ispezionata da admin, non da automation.
    """

    model_config = ConfigDict(extra="forbid")

    v: int = Field(default=1)
    original_stream: str
    original_id: str = Field(description="Redis stream entry ID del messaggio originale")
    payload: dict
    error_class: str = Field(max_length=64, description="es. 'TimeoutError', 'HTTPError'")
    error_message: str = Field(max_length=512)
    attempts: int = Field(gt=0)
    first_failure_at: datetime
    last_failure_at: datetime
