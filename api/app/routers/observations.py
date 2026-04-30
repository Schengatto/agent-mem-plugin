from __future__ import annotations

from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, Response
from redis.asyncio import Redis

from app.dependencies import get_current_user, get_db, get_redis
from app.schemas.auth import AuthUser
from app.schemas.observation import ObsCreate, ObsCreated, ObsFull
from app.services.memory import MemoryService

router = APIRouter(tags=["observations"], dependencies=[Depends(get_current_user)])


@router.post("/observations", status_code=202, response_model=ObsCreated)
async def create_observation(
    body: ObsCreate,
    current_user: AuthUser = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> ObsCreated:
    svc = MemoryService()
    obs_id = await svc.create_observation(conn, redis, body, current_user.user_id)
    return ObsCreated(id=obs_id)


@router.get("/observations", response_model=list[ObsFull])
async def get_observations_batch(
    ids: list[int] = Query(default=[]),
    current_user: AuthUser = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db),
) -> list[ObsFull]:
    if not ids:
        return []
    svc = MemoryService()
    return await svc.get_observations_batch(conn, ids, current_user.user_id)


@router.get("/observations/{obs_id}", response_model=ObsFull)
async def get_observation(
    obs_id: int,
    current_user: AuthUser = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db),
) -> ObsFull:
    svc = MemoryService()
    obs = await svc.get_observation(conn, obs_id, current_user.user_id)
    if obs is None:
        raise HTTPException(status_code=404, detail="observation_not_found")
    return obs


@router.delete("/observations/{obs_id}")
async def delete_observation(
    obs_id: int,
    current_user: AuthUser = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db),
) -> Response:
    svc = MemoryService()
    found = await svc.delete_observation(conn, obs_id, current_user.user_id)
    if not found:
        raise HTTPException(status_code=404, detail="observation_not_found")
    return Response(status_code=204)
