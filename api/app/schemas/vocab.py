from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

VocabCategory = Literal["entity", "convention", "decision", "abbreviation", "pattern"]


class VocabEntry(BaseModel):
    id: int
    term: str
    shortcode: str | None
    category: VocabCategory
    definition: str = Field(max_length=80)
    detail: str | None
    usage_count: int
    confidence: float = Field(ge=0.0, le=1.0)


class VocabLookupResponse(BaseModel):
    found: bool
    entry: VocabEntry | None
    match_type: Literal["exact", "fuzzy", "semantic"] | None


class VocabUpsertRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    term: str = Field(min_length=1, max_length=100)
    category: VocabCategory
    definition: str = Field(min_length=1, max_length=80)
    detail: str | None = None
    metadata: dict | None = None
