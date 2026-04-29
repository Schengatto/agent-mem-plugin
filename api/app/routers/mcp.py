from __future__ import annotations

from fastapi import APIRouter, HTTPException

router = APIRouter(tags=["mcp"])


@router.get("/ping")
async def ping():
    raise HTTPException(501, "not implemented")
