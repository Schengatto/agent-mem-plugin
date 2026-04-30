from __future__ import annotations

from uuid import UUID

import asyncpg
from redis.asyncio import Redis

from app.schemas.observation import ObsCreate, ObsFull


class MemoryService:
    async def create_observation(
        self,
        conn: asyncpg.Connection,
        redis: Redis,
        data: ObsCreate,
        user_id: UUID,
    ) -> int:
        obs_id: int = await conn.fetchval(
            """
            INSERT INTO observations
                (type, content, tags, scope, token_estimate, expires_at, metadata,
                 project_id, session_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            RETURNING id
            """,
            data.type.value,
            data.content,
            data.tags,
            data.scope,
            data.token_estimate,
            data.expires_at,
            data.metadata,
            data.project_id,
            data.session_id,
        )
        await redis.xadd("embed_jobs", {"obs_id": str(obs_id)})
        return obs_id

    async def get_observation(
        self,
        conn: asyncpg.Connection,
        obs_id: int,
        user_id: UUID,
    ) -> ObsFull | None:
        row = await conn.fetchrow(
            """
            SELECT id, type, content, tags, scope, token_estimate,
                   metadata, project_id, created_at, expires_at
            FROM observations
            WHERE id = $1
            """,
            obs_id,
        )
        if row is None:
            return None
        return _row_to_full(row)

    async def get_observations_batch(
        self,
        conn: asyncpg.Connection,
        ids: list[int],
        user_id: UUID,
    ) -> list[ObsFull]:
        rows = await conn.fetch(
            """
            SELECT id, type, content, tags, scope, token_estimate,
                   metadata, project_id, created_at, expires_at
            FROM observations
            WHERE id = ANY($1::bigint[])
            """,
            ids,
        )
        return [_row_to_full(row) for row in rows]

    async def delete_observation(
        self,
        conn: asyncpg.Connection,
        obs_id: int,
        user_id: UUID,
    ) -> bool:
        status: str = await conn.execute(
            "DELETE FROM observations WHERE id = $1",
            obs_id,
        )
        return status != "DELETE 0"


def _row_to_full(row: dict) -> ObsFull:
    return ObsFull(
        id=row["id"],
        type=row["type"],
        content=row["content"],
        tags=row["tags"] or [],
        scope=row["scope"] or [],
        token_estimate=row["token_estimate"],
        metadata=row["metadata"],
        project_id=row["project_id"],
        created_at=row["created_at"],
        expires_at=row["expires_at"],
    )
