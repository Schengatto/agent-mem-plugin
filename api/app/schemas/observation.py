from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


class ObsType(str, Enum):
    identity = "identity"
    directive = "directive"
    context = "context"
    bookmark = "bookmark"
    observation = "observation"


class ObsCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: ObsType = ObsType.observation
    content: str = Field(min_length=1, max_length=20_000)
    tags: list[str] = []
    scope: list[str] = []
    token_estimate: int | None = Field(default=None, ge=0)
    expires_at: datetime | None = None
    metadata: dict | None = None


class ObsCompact(BaseModel):
    id: int
    type: ObsType
    one_liner: str
    score: float | None = None
    age_hours: int | None = None


class ObsFull(BaseModel):
    id: int
    type: ObsType
    content: str
    tags: list[str]
    scope: list[str]
    token_estimate: int | None
    metadata: dict | None
    created_at: datetime
    expires_at: datetime | None
