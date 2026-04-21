"""baseline schema (F1-04)

Revision ID: 0001
Revises:
Create Date: 2026-04-20

Schema completo descritto in docs/ARCHITECTURE.md §2. Le strategie
token-first (8-18) richiedono:

  - observations.scope TEXT[]          (Strategia 9 — manifest gerarchico)
  - observations.last_used_at          (Strategia 13 — LRU adaptive budget)
  - observations.access_count          (Strategia 13)
  - observations.token_estimate        (Strategia 17 — capping at write)
  - manifest_entries.scope_path        (Strategia 9 — root/branch split)
  - manifest_entries.is_root           (Strategia 8 — cache-stable prefix)
  - vocab_entries.shortcode UNIQUE     (Strategia 12)
  - query_fingerprints                 (Strategia 16)
  - token_metrics                      (Strategia 18)
  - project_manifest_meta              (Strategia 8 — ETag stabile)

Indici critici:

  - HNSW su observations.embedding (m=16, ef_construction=64)
  - GIN su observations.fts_vector
  - GIN su observations.scope
  - Partial index WHERE distilled_into IS NULL (corpus attivo)
  - Composite (project_id, is_root, scope_path) INCLUDE su manifest
  - LRU (project_id, last_used_at DESC, access_count DESC)

RLS policies: user isolation su observations/vocab_entries/manifest_entries/
sessions. Le policy sono bypassate dall'owner (mm_admin) → migrazioni e
admin plane operano senza restrizioni. mm_api/mm_worker devono setttare
`SET LOCAL app.user_id = '<uuid>'` all'inizio di ogni request.

Trigger single_admin_trg: nega INSERT su admin_users quando count >= 1
(architettura single-admin, vedi SECURITY.md).

NOTA Alembic: raw SQL via op.execute() invece di op.create_table().
Motivazione: autogenerate non gestisce HNSW, GIN, INCLUDE, partial WHERE,
generated columns (tsvector STORED), trigger function, RLS policies. Più
semplice e leggibile tenere SQL vicino allo schema descritto in ARCHITECTURE.md.
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0001"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# ──────────────────────────────────────────────────────────────────────────
# UPGRADE
# ──────────────────────────────────────────────────────────────────────────

def upgrade() -> None:
    # Safety net: se init-db.sql non le ha già installate (es. DB manuale).
    # CREATE EXTENSION IF NOT EXISTS è idempotente e no-op se già presenti.
    # Richiede privilegi superuser (in ambiente compose le extensions sono già
    # create da init-db.sql; in test/dev locale l'utente potrebbe essere
    # superuser diretto).
    op.execute("CREATE EXTENSION IF NOT EXISTS vector;")
    op.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto;")

    _create_core_tables()
    _create_admin_plane()
    _create_dependent_tables()
    _create_indexes()
    _create_triggers()
    _enable_row_level_security()


def _create_core_tables() -> None:
    """users, admin_users, projects, device_keys (Stage A + parte Stage B)."""
    op.execute(
        """
        ------------------------------------------------------------------
        -- users  (data plane; user_id referenziato da tutto il dominio)
        ------------------------------------------------------------------
        CREATE TABLE users (
            id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            api_key    TEXT UNIQUE NOT NULL,  -- legacy: SHA-256 hash. Da F2-09
                                              -- le chiavi reali vivono in device_keys.
                                              -- Colonna mantenuta per compat single-user bootstrap.
            name       TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        ------------------------------------------------------------------
        -- admin_users  (admin plane, single-admin constraint via trigger)
        ------------------------------------------------------------------
        CREATE TABLE admin_users (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            username        TEXT NOT NULL UNIQUE,
            password_hash   TEXT NOT NULL,
            totp_secret     TEXT NOT NULL,             -- cifrato AES-GCM (HKDF da SECRET_KEY)
            totp_verified   BOOLEAN NOT NULL DEFAULT false,
            recovery_codes  TEXT[],                    -- argon2id hash (vedi CONVENTIONS)
            created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            last_login_at   TIMESTAMPTZ,
            last_login_ip   INET,
            CONSTRAINT single_admin CHECK (id IS NOT NULL)
        );

        ------------------------------------------------------------------
        -- projects  (multi-user: owner user_id; parent_id per sub-project)
        ------------------------------------------------------------------
        CREATE TABLE projects (
            id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id    UUID REFERENCES users(id) ON DELETE CASCADE,
            slug       TEXT NOT NULL,
            is_team    BOOLEAN NOT NULL DEFAULT false,
            parent_id  UUID REFERENCES projects(id),
            git_remote TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (user_id, slug)
        );

        ------------------------------------------------------------------
        -- project_members  (membership team; ruolo per fine-grain in F2-04)
        ------------------------------------------------------------------
        CREATE TABLE project_members (
            project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            user_id    UUID NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
            role       TEXT NOT NULL DEFAULT 'member',
            added_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (project_id, user_id),
            CHECK (role IN ('owner', 'member', 'viewer'))
        );

        ------------------------------------------------------------------
        -- device_keys  (zero-touch onboarding, F2-09)
        ------------------------------------------------------------------
        CREATE TABLE device_keys (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            api_key_hash    TEXT NOT NULL UNIQUE,
            device_label    TEXT NOT NULL,
            hostname        TEXT,
            os_info         TEXT,
            agent_kinds     TEXT[] NOT NULL DEFAULT '{}',
            created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            created_via_pin UUID,                 -- FK logico a admin_pair_tokens
            created_ip      INET,
            last_seen_at    TIMESTAMPTZ,
            last_seen_ip    INET,
            revoked_at      TIMESTAMPTZ
        );
        """
    )


def _create_admin_plane() -> None:
    """admin_webauthn_credentials, admin_sessions, admin_audit_log, admin_settings, admin_pair_tokens.

    admin_pair_tokens referenzia sia admin_users che device_keys, quindi va
    creata DOPO device_keys.
    """
    op.execute(
        """
        ------------------------------------------------------------------
        -- admin_webauthn_credentials  (FIDO2/passkey, 0..N per admin)
        ------------------------------------------------------------------
        CREATE TABLE admin_webauthn_credentials (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            admin_id      UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
            credential_id BYTEA NOT NULL UNIQUE,
            public_key    BYTEA NOT NULL,
            sign_count    BIGINT NOT NULL DEFAULT 0,
            transports    TEXT[],
            label         TEXT,
            created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
            last_used_at  TIMESTAMPTZ
        );

        ------------------------------------------------------------------
        -- admin_sessions  (cookie opaco, UUID v7 per ordinabilità pg18)
        ------------------------------------------------------------------
        CREATE TABLE admin_sessions (
            id               UUID PRIMARY KEY DEFAULT uuidv7(),
            admin_id         UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
            session_token    TEXT NOT NULL UNIQUE,
            csrf_token       TEXT NOT NULL,
            mfa_fresh_until  TIMESTAMPTZ,
            ip               INET NOT NULL,
            user_agent       TEXT,
            created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
            expires_at       TIMESTAMPTZ NOT NULL,
            revoked_at       TIMESTAMPTZ
        );

        ------------------------------------------------------------------
        -- admin_audit_log  (append-only; ogni /admin/* non-GET qui)
        ------------------------------------------------------------------
        CREATE TABLE admin_audit_log (
            id          BIGSERIAL PRIMARY KEY,
            admin_id    UUID REFERENCES admin_users(id)    ON DELETE SET NULL,
            session_id  UUID REFERENCES admin_sessions(id) ON DELETE SET NULL,
            action      TEXT NOT NULL,
            target_type TEXT,
            target_id   TEXT,
            details     JSONB,
            ip          INET,
            success     BOOLEAN NOT NULL,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        ------------------------------------------------------------------
        -- admin_settings  (key/value JSONB, whitelist hardcoded in codice)
        ------------------------------------------------------------------
        CREATE TABLE admin_settings (
            key         TEXT PRIMARY KEY,
            value       JSONB NOT NULL,
            description TEXT,
            updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_by  UUID REFERENCES admin_users(id) ON DELETE SET NULL
        );

        ------------------------------------------------------------------
        -- admin_pair_tokens  (PIN onboarding; plaintext solo in Redis)
        ------------------------------------------------------------------
        CREATE TABLE admin_pair_tokens (
            id                  UUID PRIMARY KEY DEFAULT uuidv7(),
            pin_hash            TEXT NOT NULL UNIQUE,
            label_hint          TEXT,
            project_slug        TEXT,
            created_by          UUID REFERENCES admin_users(id) ON DELETE SET NULL,
            created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
            expires_at          TIMESTAMPTZ NOT NULL,
            consumed_at         TIMESTAMPTZ,
            consumed_by_device  UUID REFERENCES device_keys(id) ON DELETE SET NULL
        );
        """
    )


def _create_dependent_tables() -> None:
    """observations + tutto il dominio che dipende da projects/observations/sessions."""
    op.execute(
        """
        ------------------------------------------------------------------
        -- observations  (cuore del sistema; tipizzate in 5 categorie)
        ------------------------------------------------------------------
        CREATE TABLE observations (
            id              BIGSERIAL PRIMARY KEY,
            project_id      UUID REFERENCES projects(id) ON DELETE CASCADE,
            session_id      UUID,                          -- FK aggiunta dopo sessions
            type            TEXT NOT NULL DEFAULT 'observation',
            content         TEXT NOT NULL,
            tags            TEXT[],
            scope           TEXT[],
            expires_at      TIMESTAMPTZ,
            relevance_score FLOAT NOT NULL DEFAULT 1.0,
            embedding       vector(768),
            fts_vector      tsvector GENERATED ALWAYS AS
                              (to_tsvector('italian', content)) STORED,
            distilled_into  BIGINT REFERENCES observations(id),
            last_tightened  TIMESTAMPTZ,
            last_used_at    TIMESTAMPTZ,
            access_count    INT NOT NULL DEFAULT 0,
            token_estimate  INT,
            metadata        JSONB,
            created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            CHECK (type IN ('identity', 'directive', 'context', 'bookmark', 'observation'))
        );

        ------------------------------------------------------------------
        -- manifest_entries  (indice cache-stable; scope_path+is_root)
        ------------------------------------------------------------------
        CREATE TABLE manifest_entries (
            id         BIGSERIAL PRIMARY KEY,
            project_id UUID REFERENCES projects(id) ON DELETE CASCADE,
            obs_id     BIGINT REFERENCES observations(id) ON DELETE CASCADE,
            one_liner  TEXT NOT NULL,
            type       TEXT NOT NULL,
            priority   INT NOT NULL DEFAULT 0,
            scope_path TEXT NOT NULL DEFAULT '/',
            is_root    BOOLEAN NOT NULL DEFAULT false,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        ------------------------------------------------------------------
        -- vocab_entries  (shortcode UNIQUE per Strategia 12)
        ------------------------------------------------------------------
        CREATE TABLE vocab_entries (
            id          BIGSERIAL PRIMARY KEY,
            project_id  UUID REFERENCES projects(id) ON DELETE CASCADE,
            term        TEXT NOT NULL,
            shortcode   TEXT,
            category    TEXT NOT NULL,
            definition  TEXT NOT NULL,
            detail      TEXT,
            metadata    JSONB,
            source      TEXT NOT NULL DEFAULT 'auto',
            confidence  FLOAT NOT NULL DEFAULT 0.7,
            usage_count INT NOT NULL DEFAULT 0,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (project_id, term),
            UNIQUE (project_id, shortcode),
            CHECK (category IN ('entity', 'convention', 'decision', 'abbreviation', 'pattern')),
            CHECK (source IN ('auto', 'manual')),
            CHECK (shortcode IS NULL OR shortcode ~ '^\\$[A-Z0-9]{2,4}$')
        );

        ------------------------------------------------------------------
        -- query_fingerprints  (Strategia 16 — prefetch predittivo)
        ------------------------------------------------------------------
        CREATE TABLE query_fingerprints (
            id              BIGSERIAL PRIMARY KEY,
            project_id      UUID REFERENCES projects(id) ON DELETE CASCADE,
            trigger_pattern TEXT NOT NULL,
            predicted_ids   BIGINT[],
            predicted_terms TEXT[],
            hit_count       INT NOT NULL DEFAULT 0,
            miss_count      INT NOT NULL DEFAULT 0,
            confidence      FLOAT NOT NULL DEFAULT 0.0,
            updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (project_id, trigger_pattern)
        );

        ------------------------------------------------------------------
        -- project_manifest_meta  (ETag per cache-stable, Strategia 8)
        ------------------------------------------------------------------
        CREATE TABLE project_manifest_meta (
            project_id     UUID PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
            root_etag      TEXT NOT NULL,
            vocab_etag     TEXT NOT NULL,
            bloom_etag     TEXT,
            last_distilled TIMESTAMPTZ,
            updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        ------------------------------------------------------------------
        -- sessions  (logica di sessione agent; tool_sequence per fingerprint)
        ------------------------------------------------------------------
        CREATE TABLE sessions (
            id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            project_id     UUID REFERENCES projects(id),
            scope_hint     TEXT,
            started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
            closed_at      TIMESTAMPTZ,
            obs_count      INT NOT NULL DEFAULT 0,
            compressed_at  TIMESTAMPTZ,
            summary_obs_id BIGINT REFERENCES observations(id),
            tool_sequence  TEXT[]
        );

        -- Adesso che sessions esiste, chiudiamo la FK su observations.session_id.
        ALTER TABLE observations
            ADD CONSTRAINT observations_session_id_fkey
            FOREIGN KEY (session_id) REFERENCES sessions(id)
            ON DELETE SET NULL;

        ------------------------------------------------------------------
        -- token_metrics  (Strategia 18 — telemetria per sessione)
        ------------------------------------------------------------------
        CREATE TABLE token_metrics (
            id                     BIGSERIAL PRIMARY KEY,
            session_id             UUID REFERENCES sessions(id) ON DELETE CASCADE,
            project_id             UUID REFERENCES projects(id) ON DELETE CASCADE,
            tokens_manifest_root   INT NOT NULL DEFAULT 0,
            tokens_manifest_branch INT NOT NULL DEFAULT 0,
            tokens_vocab           INT NOT NULL DEFAULT 0,
            tokens_search          INT NOT NULL DEFAULT 0,
            tokens_batch_detail    INT NOT NULL DEFAULT 0,
            tokens_history_saved   INT NOT NULL DEFAULT 0,
            cache_hits_bytes       INT NOT NULL DEFAULT 0,
            cache_misses_bytes     INT NOT NULL DEFAULT 0,
            turns_total            INT NOT NULL DEFAULT 0,
            created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        ------------------------------------------------------------------
        -- llm_api_calls  (audit multi-provider; budget tracking F2-19)
        ------------------------------------------------------------------
        CREATE TABLE llm_api_calls (
            id              BIGSERIAL PRIMARY KEY,
            provider        TEXT NOT NULL,
            model           TEXT NOT NULL,
            purpose         TEXT NOT NULL,
            project_id      UUID REFERENCES projects(id) ON DELETE SET NULL,
            session_id      UUID REFERENCES sessions(id) ON DELETE SET NULL,
            input_tokens    INT NOT NULL,
            output_tokens   INT NOT NULL,
            cached_tokens   INT NOT NULL DEFAULT 0,
            cost_microcents INT,
            latency_ms      INT NOT NULL,
            success         BOOLEAN NOT NULL,
            error_class     TEXT,
            budget_day      DATE NOT NULL,
            created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            CHECK (provider IN ('gemini', 'ollama', 'openai', 'anthropic')),
            CHECK (purpose IN (
                'distill_merge', 'distill_tighten', 'distill_vocab',
                'compress_session', 'extract_facts'
            ))
        );
        """
    )


def _create_indexes() -> None:
    """Indici critici: HNSW, GIN, partial, composite, LRU."""
    op.execute(
        """
        ------------------------------------------------------------------
        -- observations (il set più denso: 7 indici, tutti con partial
        -- WHERE distilled_into IS NULL tranne HNSW/GIN full)
        ------------------------------------------------------------------

        -- ANN vettoriale (Strategia: pgvector HNSW default)
        CREATE INDEX observations_embedding_hnsw
            ON observations
            USING hnsw (embedding vector_cosine_ops)
            WITH (m = 16, ef_construction = 64);

        -- FTS (italian dictionary — F2-06 tuning se servirà multilingual)
        CREATE INDEX observations_fts_gin
            ON observations USING gin (fts_vector);

        -- Retrieval per tipo/relevance (pre-filter ANN)
        CREATE INDEX observations_active_type
            ON observations (project_id, type, relevance_score DESC)
            WHERE distilled_into IS NULL;

        -- Ordinamento cronologico attivo
        CREATE INDEX observations_active_created
            ON observations (project_id, created_at DESC)
            WHERE distilled_into IS NULL;

        -- Strategia 9: scope filtering prima dell'ANN
        CREATE INDEX observations_scope_gin
            ON observations USING gin (scope)
            WHERE distilled_into IS NULL;

        -- Strategia 13: LRU adaptive eviction
        CREATE INDEX observations_lru
            ON observations
            (project_id, last_used_at DESC NULLS LAST, access_count DESC)
            WHERE distilled_into IS NULL;

        -- Join frequente da sessions
        CREATE INDEX observations_session_id
            ON observations (session_id)
            WHERE session_id IS NOT NULL;

        ------------------------------------------------------------------
        -- manifest_entries (due indici, uno per priority order e uno
        -- scope-path lookup cache-stable)
        ------------------------------------------------------------------
        CREATE INDEX manifest_entries_priority
            ON manifest_entries (project_id, priority, updated_at DESC);

        -- Strategia 9: lookup root + branch INCLUDE-covering (niente heap fetch)
        CREATE INDEX manifest_entries_scope_path
            ON manifest_entries (project_id, is_root, scope_path)
            INCLUDE (obs_id, one_liner, type, priority);

        ------------------------------------------------------------------
        -- vocab_entries
        ------------------------------------------------------------------
        CREATE INDEX vocab_entries_category_usage
            ON vocab_entries (project_id, category, usage_count DESC);

        CREATE INDEX vocab_entries_shortcode
            ON vocab_entries (project_id, shortcode)
            WHERE shortcode IS NOT NULL;

        CREATE INDEX vocab_entries_fts
            ON vocab_entries
            USING gin (to_tsvector('english', term || ' ' || definition));

        ------------------------------------------------------------------
        -- query_fingerprints (Strategia 16 — solo sopra confidence 0.6)
        ------------------------------------------------------------------
        CREATE INDEX query_fingerprints_confidence
            ON query_fingerprints (project_id, confidence DESC)
            WHERE confidence >= 0.6;

        ------------------------------------------------------------------
        -- token_metrics (Strategia 18)
        ------------------------------------------------------------------
        CREATE INDEX token_metrics_project_created
            ON token_metrics (project_id, created_at DESC);

        ------------------------------------------------------------------
        -- device_keys (lookup api_key_hash + user attivi)
        ------------------------------------------------------------------
        CREATE INDEX device_keys_active
            ON device_keys (user_id, revoked_at)
            WHERE revoked_at IS NULL;

        CREATE INDEX device_keys_hash_active
            ON device_keys (api_key_hash)
            WHERE revoked_at IS NULL;

        ------------------------------------------------------------------
        -- admin_pair_tokens (lookup pending PIN, expires_at scan)
        ------------------------------------------------------------------
        CREATE INDEX admin_pair_tokens_pending
            ON admin_pair_tokens (expires_at)
            WHERE consumed_at IS NULL;

        ------------------------------------------------------------------
        -- admin_webauthn_credentials
        ------------------------------------------------------------------
        CREATE INDEX admin_webauthn_credentials_admin
            ON admin_webauthn_credentials (admin_id, last_used_at DESC);

        ------------------------------------------------------------------
        -- admin_sessions (lookup attive per admin)
        ------------------------------------------------------------------
        CREATE INDEX admin_sessions_active
            ON admin_sessions (admin_id, expires_at)
            WHERE revoked_at IS NULL;

        ------------------------------------------------------------------
        -- admin_audit_log (2 indici: per admin e per action)
        ------------------------------------------------------------------
        CREATE INDEX admin_audit_log_admin_created
            ON admin_audit_log (admin_id, created_at DESC);

        CREATE INDEX admin_audit_log_action_created
            ON admin_audit_log (action, created_at DESC);

        ------------------------------------------------------------------
        -- llm_api_calls (budget daily, error detection, per progetto)
        ------------------------------------------------------------------
        CREATE INDEX llm_api_calls_budget_day
            ON llm_api_calls (budget_day, provider);

        CREATE INDEX llm_api_calls_errors
            ON llm_api_calls (provider, model, success)
            WHERE success = false;

        CREATE INDEX llm_api_calls_project_created
            ON llm_api_calls (project_id, created_at DESC);

        ------------------------------------------------------------------
        -- project_members (lookup per user → progetti)
        ------------------------------------------------------------------
        CREATE INDEX project_members_user
            ON project_members (user_id);
        """
    )


def _create_triggers() -> None:
    """Trigger single_admin_trg: enforce max 1 riga in admin_users."""
    op.execute(
        """
        CREATE OR REPLACE FUNCTION enforce_single_admin() RETURNS trigger
        LANGUAGE plpgsql AS $fn$
        BEGIN
            IF (SELECT count(*) FROM admin_users) >= 1 THEN
                RAISE EXCEPTION 'Only one admin allowed. Use update flow.'
                    USING ERRCODE = 'check_violation';
            END IF;
            RETURN NEW;
        END
        $fn$;

        CREATE TRIGGER single_admin_trg
            BEFORE INSERT ON admin_users
            FOR EACH ROW EXECUTE FUNCTION enforce_single_admin();
        """
    )


def _enable_row_level_security() -> None:
    """RLS per isolamento utente. Bypassata dall'owner (mm_admin) e superuser."""
    op.execute(
        """
        ------------------------------------------------------------------
        -- observations
        ------------------------------------------------------------------
        ALTER TABLE observations ENABLE ROW LEVEL SECURITY;
        CREATE POLICY observations_user_isolation ON observations
            USING (
                project_id IN (
                    SELECT id FROM projects
                    WHERE user_id = current_setting('app.user_id', true)::uuid
                       OR (is_team = true AND id IN (
                               SELECT project_id FROM project_members
                               WHERE user_id = current_setting('app.user_id', true)::uuid
                           ))
                )
            );

        ------------------------------------------------------------------
        -- vocab_entries
        ------------------------------------------------------------------
        ALTER TABLE vocab_entries ENABLE ROW LEVEL SECURITY;
        CREATE POLICY vocab_entries_user_isolation ON vocab_entries
            USING (
                project_id IN (
                    SELECT id FROM projects
                    WHERE user_id = current_setting('app.user_id', true)::uuid
                       OR (is_team = true AND id IN (
                               SELECT project_id FROM project_members
                               WHERE user_id = current_setting('app.user_id', true)::uuid
                           ))
                )
            );

        ------------------------------------------------------------------
        -- manifest_entries
        ------------------------------------------------------------------
        ALTER TABLE manifest_entries ENABLE ROW LEVEL SECURITY;
        CREATE POLICY manifest_entries_user_isolation ON manifest_entries
            USING (
                project_id IN (
                    SELECT id FROM projects
                    WHERE user_id = current_setting('app.user_id', true)::uuid
                       OR (is_team = true AND id IN (
                               SELECT project_id FROM project_members
                               WHERE user_id = current_setting('app.user_id', true)::uuid
                           ))
                )
            );

        ------------------------------------------------------------------
        -- sessions
        ------------------------------------------------------------------
        ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
        CREATE POLICY sessions_user_isolation ON sessions
            USING (
                project_id IN (
                    SELECT id FROM projects
                    WHERE user_id = current_setting('app.user_id', true)::uuid
                       OR (is_team = true AND id IN (
                               SELECT project_id FROM project_members
                               WHERE user_id = current_setting('app.user_id', true)::uuid
                           ))
                )
            );
        """
    )


# ──────────────────────────────────────────────────────────────────────────
# DOWNGRADE
# ──────────────────────────────────────────────────────────────────────────

def downgrade() -> None:
    """Rimuove tutto ciò creato in upgrade(), ordine inverso.

    NOTA: non droppiamo le extensions (sono gestite da init-db.sql).
    Non droppiamo i privilegi default (idem).
    """
    op.execute(
        """
        -- Drop policies (RLS)
        DROP POLICY IF EXISTS sessions_user_isolation ON sessions;
        DROP POLICY IF EXISTS manifest_entries_user_isolation ON manifest_entries;
        DROP POLICY IF EXISTS vocab_entries_user_isolation ON vocab_entries;
        DROP POLICY IF EXISTS observations_user_isolation ON observations;

        -- Trigger + funzione
        DROP TRIGGER IF EXISTS single_admin_trg ON admin_users;
        DROP FUNCTION IF EXISTS enforce_single_admin();

        -- Tabelle Stage D+C+B+A (ordine inverso, FK safe tramite CASCADE)
        DROP TABLE IF EXISTS llm_api_calls       CASCADE;
        DROP TABLE IF EXISTS token_metrics       CASCADE;
        DROP TABLE IF EXISTS admin_pair_tokens   CASCADE;
        DROP TABLE IF EXISTS admin_audit_log     CASCADE;
        DROP TABLE IF EXISTS admin_settings      CASCADE;
        DROP TABLE IF EXISTS admin_sessions      CASCADE;
        DROP TABLE IF EXISTS admin_webauthn_credentials CASCADE;
        DROP TABLE IF EXISTS sessions            CASCADE;
        DROP TABLE IF EXISTS project_manifest_meta CASCADE;
        DROP TABLE IF EXISTS query_fingerprints  CASCADE;
        DROP TABLE IF EXISTS vocab_entries       CASCADE;
        DROP TABLE IF EXISTS manifest_entries    CASCADE;
        DROP TABLE IF EXISTS observations        CASCADE;
        DROP TABLE IF EXISTS device_keys         CASCADE;
        DROP TABLE IF EXISTS project_members     CASCADE;
        DROP TABLE IF EXISTS projects            CASCADE;
        DROP TABLE IF EXISTS admin_users         CASCADE;
        DROP TABLE IF EXISTS users               CASCADE;
        """
    )
