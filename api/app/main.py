from __future__ import annotations

from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI
from fastapi.middleware.gzip import GZipMiddleware
from redis.asyncio import Redis

from app.config import get_settings
from app.routers import health, manifest, mcp, observations, search, sessions, vocab


@asynccontextmanager
async def lifespan(app: FastAPI):
    s = get_settings()
    app.state.db_pool = await asyncpg.create_pool(
        s.database_url_asyncpg, min_size=2, max_size=10
    )
    app.state.redis = Redis.from_url(s.redis_url, decode_responses=True)
    yield
    await app.state.db_pool.close()
    await app.state.redis.aclose()


app = FastAPI(
    title="MemoryMesh API",
    version="0.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
    lifespan=lifespan,
)

app.add_middleware(GZipMiddleware, minimum_size=1000)

app.include_router(health.router)
app.include_router(observations.router, prefix="/api/v1")
app.include_router(search.router,       prefix="/api/v1")
app.include_router(manifest.router,     prefix="/api/v1")
app.include_router(vocab.router,        prefix="/api/v1")
app.include_router(sessions.router,     prefix="/api/v1")
app.include_router(mcp.router,          prefix="/mcp")
