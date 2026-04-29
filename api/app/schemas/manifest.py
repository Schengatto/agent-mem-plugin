from __future__ import annotations

from pydantic import BaseModel

from app.schemas.observation import ObsType


class ManifestEntry(BaseModel):
    id: int
    obs_id: int
    type: ObsType
    one_liner: str
    priority: int
    scope_path: str
    is_root: bool


class ManifestResponse(BaseModel):
    entries: list[ManifestEntry]
    etag: str
    token_estimate: int


class ManifestDeltaResponse(BaseModel):
    added: list[ManifestEntry]
    removed: list[int]  # obs_ids
    etag: str
    full_refresh_required: bool
