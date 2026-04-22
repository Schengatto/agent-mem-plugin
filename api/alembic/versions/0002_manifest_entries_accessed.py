"""manifest_entries_accessed (Strategia 16 avanzata)

Revision ID: 0002
Revises: 0001
Create Date: 2026-04-20

Tabella di logging per la Strategia 16 avanzata (vedi docs/TOKEN_OPT.md §16).
Registra quale manifest entry viene effettivamente acceduta per sessione +
turno, così il distillation worker può aggregare i pattern in
`query_fingerprints.trigger_pattern` → `predicted_ids`.

Schema "sempre creato", write "opt-in": il flag `FP_LOGGING_ENABLED` in
`app.config.Settings` gate SOLO la scrittura lato applicazione (F3-06).
Creare la tabella è gratuito (vuota); gating lato schema introdurrebbe
deriva fra ambienti e rotture di FK in migrazioni future.

Designer note:
  - `obs_id` come target preferito rispetto a `manifest_entry_id`: le
    fingerprint lavorano sulle osservazioni (riviste dall'extract + merge),
    non sui one-liner che vengono rigenerati a ogni distillazione.
  - partition-ready: `created_at` scelto come primo indice candidato per
    eventuale partitioning by range in F5-08 (retention automatica).
"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0002"
down_revision: Union[str, Sequence[str], None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE manifest_entries_accessed (
            id         BIGSERIAL PRIMARY KEY,
            session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            obs_id     BIGINT NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
            turn_no    INT,                 -- nullable: non sempre determinabile lato capture
            source     TEXT NOT NULL DEFAULT 'batch',
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            CHECK (source IN ('batch', 'search', 'inject', 'other'))
        );

        -- Aggregazione per sessione (distill worker legge per sessione intera)
        CREATE INDEX manifest_entries_accessed_session
            ON manifest_entries_accessed (session_id, created_at);

        -- Retention & partition candidate
        CREATE INDEX manifest_entries_accessed_project_created
            ON manifest_entries_accessed (project_id, created_at DESC);

        -- RLS coerente con le altre tabelle per-project
        ALTER TABLE manifest_entries_accessed ENABLE ROW LEVEL SECURITY;
        CREATE POLICY manifest_entries_accessed_user_isolation
            ON manifest_entries_accessed
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


def downgrade() -> None:
    op.execute(
        """
        DROP POLICY IF EXISTS manifest_entries_accessed_user_isolation ON manifest_entries_accessed;
        DROP TABLE IF EXISTS manifest_entries_accessed CASCADE;
        """
    )
