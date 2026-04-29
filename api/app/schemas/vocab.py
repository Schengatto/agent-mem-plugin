from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class VocabEntry(BaseModel):
    id: int
    term: str
    shortcode: str | None
    category: Literal["entity", "convention", "decision", "abbreviation", "pattern"]
    definition: str = Field(max_length=80)
    detail: str | None
    usage_count: int
    confidence: float


class VocabLookupResponse(BaseModel):
    found: bool
    entry: VocabEntry | None
    match_type: Literal["exact", "fuzzy", "semantic"] | None


class VocabUpsertRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    term: str = Field(min_length=1, max_length=100)
    category: Literal["entity", "convention", "decision", "abbreviation", "pattern"]
    definition: str = Field(min_length=1, max_length=80)
    detail: str | None = None
    metadata: dict | None = None
