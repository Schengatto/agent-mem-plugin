from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["vocab"])


@router.get("/vocab/ping")
async def ping():
    raise HTTPException(501, "not implemented")
