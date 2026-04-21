-- ═══════════════════════════════════════════════════════════════════════════
-- MemoryMesh — init-db.sql (fase 2 di 2, post init-roles.sh)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Eseguito DOPO init-roles.sh (ordine alfabetico: "init-db.sql" < "init-roles.sh"
-- nel sorting POSIX? In realtà .sh viene eseguito prima per convenzione Docker
-- postgres entrypoint, ma per essere sicuri usiamo prefix numerico:
--   mount: /docker-entrypoint-initdb.d/
--     00-init-roles.sh    ← ruoli (dinamico da env)
--     01-init-db.sql      ← extensions + grants (statico)
--
-- Responsabilità di questo script:
--   1. Extensions vector + pgcrypto
--   2. GRANT database-level + schema-level
--   3. Default privileges per tabelle FUTURE (create da Alembic)
--   4. Revoke public schema access
--   5. PostgreSQL tuning security-related
-- ═══════════════════════════════════════════════════════════════════════════

\echo '══════════════════════════════════════════════════════'
\echo 'MemoryMesh: init-db.sql (extensions + grants)'
\echo '══════════════════════════════════════════════════════'

-- ─── Extensions ───────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

\echo '  ✓ Extensions vector + pgcrypto installed'

-- ─── Permessi database-level ─────────────────────────────────────────────
GRANT CONNECT ON DATABASE memorymesh TO mm_api, mm_worker, mm_admin, mm_retention;
GRANT USAGE ON SCHEMA public TO mm_api, mm_worker, mm_admin, mm_retention;

-- mm_admin è schema owner per le tabelle applicative: serve CREATE su public
-- per eseguire Alembic come mm_admin (path di default in docker-compose.yml,
-- evita di esporre la password superuser al container api). Le tabelle admin_*
-- e applicative saranno create e "possedute" da mm_admin → RLS policies
-- applicate alle app role ma bypassate dall'owner (comportamento voluto).
GRANT CREATE ON SCHEMA public TO mm_admin;

-- ─── Default Privileges per tabelle FUTURE ───────────────────────────────
-- Alembic può essere eseguito come `postgres` (superuser, test/bootstrap) o
-- come `mm_admin` (runtime `make migrate`). Le ALTER DEFAULT PRIVILEGES sono
-- replicate per entrambi gli owner: i grant si applicano automaticamente a
-- ogni nuova tabella — evita di dover ricordare GRANT a ogni migration.

-- mm_api: SELECT/INSERT/UPDATE su tabelle operative. DELETE solo via admin.
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE ON TABLES TO mm_api;
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO mm_api;
ALTER DEFAULT PRIVILEGES FOR USER mm_admin IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE ON TABLES TO mm_api;
ALTER DEFAULT PRIVILEGES FOR USER mm_admin IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO mm_api;

-- mm_worker: stesso set di mm_api (worker fa write-back su observations)
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE ON TABLES TO mm_worker;
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO mm_worker;
ALTER DEFAULT PRIVILEGES FOR USER mm_admin IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE ON TABLES TO mm_worker;
ALTER DEFAULT PRIVILEGES FOR USER mm_admin IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO mm_worker;

-- mm_admin: SELECT su tutte le tabelle (UI readonly) + FULL su tabelle admin_*
-- (grant FULL applicato esplicitamente in migration dedicata dopo che admin_*
-- esistono — qui solo default SELECT per readonly e tabelle nuove).
-- DELETE su observations è permesso (destructive op via admin UI).
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public
    GRANT SELECT, UPDATE, DELETE ON TABLES TO mm_admin;
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO mm_admin;
-- Quando mm_admin crea una tabella ne è già owner → tutti i privilegi
-- impliciti. La default privilege esplicita sotto serve come safety net per
-- tabelle create da postgres in situazioni di emergenza.
ALTER DEFAULT PRIVILEGES FOR USER mm_admin IN SCHEMA public
    GRANT SELECT, UPDATE, DELETE ON TABLES TO mm_admin;
ALTER DEFAULT PRIVILEGES FOR USER mm_admin IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO mm_admin;

\echo '  ✓ Default privileges configured (apply to future Alembic tables)'

-- ─── Row-Level Security (nota informativa) ────────────────────────────────
-- Le policy RLS richiedono che la tabella esista. Alembic le creerà DOPO
-- aver creato observations/vocab/sessions, in una migration dedicata
-- (es. 003_enable_rls.py).
--
-- Template RLS policy (riferimento, non eseguito qui):
--
--   ALTER TABLE observations ENABLE ROW LEVEL SECURITY;
--   CREATE POLICY observations_user_isolation ON observations
--     USING (
--       project_id IN (
--         SELECT id FROM projects
--         WHERE user_id = current_setting('app.user_id', true)::uuid
--         OR (is_team = true AND id IN (
--             SELECT project_id FROM project_members
--             WHERE user_id = current_setting('app.user_id', true)::uuid
--         ))
--       )
--     );
--
-- L'applicazione setta `app.user_id` all'inizio di ogni richiesta:
--   SET LOCAL app.user_id = '<user_uuid_from_device_keys>';
--
-- Fornisce una seconda linea di difesa se il codice dimentica WHERE user_id.

-- ─── Sicurezza PostgreSQL generale ───────────────────────────────────────
-- Revoke tutto dal ruolo PUBLIC (catch-all implicito per utenti non elencati)
REVOKE ALL ON DATABASE memorymesh FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Log query lente (>500ms) — utile per anomaly detection (SQL injection
-- tentativi, search bulk exfiltration, N+1 bugs in migrations)
ALTER SYSTEM SET log_min_duration_statement = '500ms';
ALTER SYSTEM SET log_connections = 'on';
ALTER SYSTEM SET log_disconnections = 'on';
ALTER SYSTEM SET log_hostname = 'off';            -- no reverse DNS (privacy)
ALTER SYSTEM SET log_statement = 'ddl';           -- log DDL, no DML plaintext

-- Enforce TLS fra API e DB anche su network interno (se cert disponibili)
-- ALTER SYSTEM SET ssl = 'on';   -- abilitare quando cert sono montati

SELECT pg_reload_conf();

\echo '  ✓ PostgreSQL security tuning applied'
\echo ''
\echo '══════════════════════════════════════════════════════'
\echo 'MemoryMesh: init-db completed'
\echo '══════════════════════════════════════════════════════'
\echo ''
\echo '  Next: apply Alembic migrations'
\echo '         make migrate'
\echo ''
