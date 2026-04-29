from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.observation import ObsType


class SearchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    q: str = Field(min_length=1, max_length=500)
    project_id: UUID
    scope: list[str] = []
    limit: int = Field(default=5, ge=1, le=20)
    mode: Literal["bm25", "vector", "hybrid"] = "hybrid"
    expand: bool = False


class SearchResult(BaseModel):
    id: int
    type: ObsType
    one_liner: str
    score: float
    mode_used: str
    rerank_applied: bool


class SearchResponse(BaseModel):
    results: list[SearchResult]
    total_ms: int
