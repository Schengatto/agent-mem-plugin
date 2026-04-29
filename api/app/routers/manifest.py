from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from app.dependencies import get_current_user

router = APIRouter(tags=["manifest"], dependencies=[Depends(get_current_user)])


@router.get("/manifest/ping")
async def ping():
    raise HTTPException(501, "not implemented")
