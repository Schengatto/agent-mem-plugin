from __future__ import annotations

from collections.abc import AsyncGenerator

import asyncpg
from fastapi import Depends, HTTPException, Request, Security
from redis.asyncio import Redis

from app.auth import api_key_header, hash_api_key
from app.config import Settings, get_settings
from app.schemas.auth import AuthUser


async def get_db(request: Request) -> AsyncGenerator[asyncpg.Connection, None]:
    async with request.app.state.db_pool.acquire() as conn:
        yield conn


async def get_redis(request: Request) -> Redis:
    return request.app.state.redis


def get_cfg(settings: Settings = Depends(get_settings)) -> Settings:
    return settings


async def get_current_user(
    raw_key: str | None = Security(api_key_header),
    conn: asyncpg.Connection = Depends(get_db),
) -> AuthUser:
    if not raw_key:
        raise HTTPException(status_code=401, detail="authentication_required")
    key_hash = hash_api_key(raw_key)
    row = await conn.fetchrow(
        "SELECT id, user_id, device_label FROM device_keys"
        " WHERE api_key_hash = $1 AND revoked_at IS NULL",
        key_hash,
    )
    if row is None:
        raise HTTPException(status_code=403, detail="invalid_or_revoked_key")
    return AuthUser(
        user_id=row["user_id"],
        device_id=row["id"],
        device_label=row["device_label"],
    )


async def get_project():
    raise NotImplementedError("get_project: implemented in F2-04 (projects)")
