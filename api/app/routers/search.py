from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import get_current_user

router = APIRouter(tags=["search"], dependencies=[Depends(get_current_user)])


@router.get("/search/ping")
async def ping():
    raise HTTPException(501, "not implemented")
