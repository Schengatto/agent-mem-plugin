"""Configurazione minimale usata in F1-04 dall'env.py di Alembic.

La configurazione completa FastAPI arriva con F2-01 (vedi docs/CONVENTIONS.md
§ Config). Qui servono solo le variabili lette dalle migrazioni.
"""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    database_url: str = Field(
        default="postgresql+psycopg://postgres:postgres@localhost:5432/memorymesh",
        alias="DATABASE_URL",
    )
    database_admin_url: str | None = Field(
        default=None,
        alias="DATABASE_ADMIN_URL",
    )
    fp_logging_enabled: bool = Field(
        default=False,
        alias="FP_LOGGING_ENABLED",
    )


def get_settings() -> Settings:
    return Settings()
