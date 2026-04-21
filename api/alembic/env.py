"""Alembic environment — sync mode con psycopg3 (F1-04).

Legge DATABASE_ADMIN_URL (fallback DATABASE_URL) da env: le migrazioni devono
girare come `mm_admin` o `postgres` perché creano tabelle/trigger/RLS policies
che mm_api/mm_worker non possono gestire.
"""

from __future__ import annotations

import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.config import get_settings
from app.db import metadata as app_metadata

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# ─── Risoluzione URL: ADMIN_URL > DATABASE_URL > default ────────────────
_settings = get_settings()
_url = _settings.database_admin_url or _settings.database_url

# Alembic richiede driver sync: se arriva un URL asyncpg lo normalizziamo.
if _url.startswith("postgresql+asyncpg://"):
    _url = _url.replace("postgresql+asyncpg://", "postgresql+psycopg://", 1)
elif _url.startswith("postgresql://"):
    _url = _url.replace("postgresql://", "postgresql+psycopg://", 1)

config.set_main_option("sqlalchemy.url", _url)

# target_metadata resta volutamente vuoto: migrazioni sono raw SQL (vedi docs/F1-04.md)
target_metadata = app_metadata


def _include_object(obj, name: str, type_: str, reflected: bool, compare_to):
    # Impedisce che autogenerate droppi oggetti creati da init-db.sql
    # (extensions, grants, default privileges non tracciati qui).
    if type_ == "table" and name.startswith("_mm_test_"):
        return False
    return True


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        include_object=_include_object,
        # Ogni migration nella stessa transazione: rollback atomico in caso di errore
        transaction_per_migration=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            include_object=_include_object,
            transaction_per_migration=True,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
