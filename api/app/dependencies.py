from __future__ import annotations

import asyncpg
from fastapi import Depends, Request
from redis.asyncio import Redis

from app.config import Settings, get_settings


async def get_db(request: Request) -> asyncpg.Connection:
    async with request.app.state.db_pool.acquire() as conn:
        yield conn


async def get_redis(request: Request) -> Redis:
    return request.app.state.redis


def get_cfg(settings: Settings = Depends(get_settings)) -> Settings:
    return settings


async def get_current_user():
    raise NotImplementedError("get_current_user: implemented in F2-02 (auth middleware)")


async def get_project():
    raise NotImplementedError("get_project: implemented in F2-04 (projects)")
