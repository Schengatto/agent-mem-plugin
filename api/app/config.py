"""Configurazione centralizzata FastAPI + Alembic.

Espanso in F2-01 con il set completo di variabili. La configurazione Alembic
(database_url, database_admin_url, fp_logging_enabled) è mantenuta compatibile
con gli alias esistenti usati da alembic/env.py.
"""
from __future__ import annotations

import functools
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ── DB (Alembic-compat aliases) ───────────────────────────────────────
    database_url: str = Field(
        alias="DATABASE_URL",
        default="postgresql+psycopg://postgres:postgres@localhost:5432/memorymesh",
    )
    database_admin_url: str | None = Field(default=None, alias="DATABASE_ADMIN_URL")
    fp_logging_enabled: bool = Field(default=False, alias="FP_LOGGING_ENABLED")

    # ── Core runtime ──────────────────────────────────────────────────────
    redis_url: str = Field(default="redis://redis:6379/0", alias="REDIS_URL")
    secret_key: str = Field(alias="SECRET_KEY")
    ollama_url: str = Field(default="http://ollama:11434", alias="OLLAMA_URL")
    deployment: Literal["lan", "vpn", "public"] = Field(
        default="lan", alias="MEMORYMESH_DEPLOYMENT"
    )

    # ── Manifest / search ────────────────────────────────────────────────
    manifest_default_budget: int = Field(default=3000, alias="MANIFEST_DEFAULT_BUDGET")
    search_default_limit: int = Field(default=5, alias="SEARCH_DEFAULT_LIMIT")
    search_max_limit: int = Field(default=20, alias="SEARCH_MAX_LIMIT")
    search_cache_ttl: int = Field(default=300, alias="SEARCH_CACHE_TTL")

    # ── Distillation thresholds ──────────────────────────────────────────
    merge_similarity_threshold: float = Field(
        default=0.92, alias="MERGE_SIMILARITY_THRESHOLD"
    )
    decay_observation_factor: float = Field(
        default=0.85, alias="DECAY_OBSERVATION_FACTOR"
    )
    decay_context_factor: float = Field(default=0.97, alias="DECAY_CONTEXT_FACTOR")
    tighten_min_words: int = Field(default=150, alias="TIGHTEN_MIN_WORDS")
    compress_threshold_tokens: int = Field(
        default=8000, alias="COMPRESS_THRESHOLD_TOKENS"
    )
    vocab_extract_enabled: bool = Field(default=True, alias="VOCAB_EXTRACT_ENABLED")

    # ── Token-first (Strategies 8-18) ────────────────────────────────────
    max_obs_tokens: int = Field(default=200, alias="MAX_OBS_TOKENS")
    shortcode_threshold: int = Field(default=10, alias="SHORTCODE_THRESHOLD")
    root_relevance_threshold: float = Field(
        default=0.85, alias="ROOT_RELEVANCE_THRESHOLD"
    )
    root_access_count_threshold: int = Field(
        default=50, alias="ROOT_ACCESS_COUNT_THRESHOLD"
    )
    lru_eviction_days: int = Field(default=60, alias="LRU_EVICTION_DAYS")
    bm25_skip_threshold: float = Field(default=0.3, alias="BM25_SKIP_THRESHOLD")
    search_rerank_enabled: bool = Field(default=True, alias="SEARCH_RERANK_ENABLED")
    fingerprint_min_sessions: int = Field(
        default=3, alias="FINGERPRINT_MIN_SESSIONS"
    )

    # ── LLM / Embed providers ────────────────────────────────────────────
    memorymesh_llm_provider: Literal["gemini", "ollama", "openai", "anthropic"] = Field(
        default="gemini", alias="MEMORYMESH_LLM_PROVIDER"
    )
    memorymesh_embed_provider: Literal["gemini", "ollama"] = Field(
        default="gemini", alias="MEMORYMESH_EMBED_PROVIDER"
    )
    memorymesh_llm_daily_token_cap: int = Field(
        default=500_000, alias="MEMORYMESH_LLM_DAILY_TOKEN_CAP"
    )

    # ── Derived (not from env) ────────────────────────────────────────────
    @property
    def database_url_asyncpg(self) -> str:
        """asyncpg uses 'postgresql://' — strip the SQLAlchemy driver prefix."""
        return self.database_url.replace("postgresql+psycopg://", "postgresql://")


@functools.lru_cache
def get_settings() -> Settings:
    return Settings()
