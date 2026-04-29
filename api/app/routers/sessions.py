from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["sessions"])


@router.get("/sessions/ping")
async def ping():
    raise HTTPException(501, "not implemented")
