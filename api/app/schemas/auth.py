from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel


class AuthUser(BaseModel):
    user_id: UUID
    device_id: UUID
    device_label: str
