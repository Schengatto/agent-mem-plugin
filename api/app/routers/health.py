from __future__ import annotations

from fastapi import APIRouter

from app.config import get_settings

router = APIRouter(tags=["health"])


@router.get("/health")
async def health():
    s = get_settings()
    return {"status": "ok", "version": "0.1.0", "deployment": s.deployment}
