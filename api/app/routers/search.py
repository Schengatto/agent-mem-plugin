from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["search"])


@router.get("/search/ping")
async def ping():
    raise HTTPException(501, "not implemented")
