-- supabase/00-bootstrap.sql
-- Runs once on a fresh Postgres volume during /docker-entrypoint-initdb.d/*
-- Purpose:
--   * Ensure auth/storage schemas exist
--   * Seed enums used by Supabase Auth
--   * Pre-fix GoTrue's buggy backfill (uuid=text issue) safely
--   * Avoid creating any migrations tables (leave to services)

-- Keep search_path predictable for the session
SET search_path = public, auth;

-- --- Schemas (safe if run multiple times) ---
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;

-- --- Seed MFA enums so later ALTER TYPE succeeds (idempotent) ---
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'auth' AND t.typname = 'factor_type'
  ) THEN
    CREATE TYPE auth.factor_type AS ENUM ('totp', 'webauthn');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'auth' AND t.typname = 'factor_status'
  ) THEN
    CREATE TYPE auth.factor_status AS ENUM ('unverified', 'verified');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'auth' AND t.typname = 'aal_level'
  ) THEN
    CREATE TYPE auth.aal_level AS ENUM ('aal1', 'aal2', 'aal3');
  END IF;
END $$;


-- --- PRE-FIX GoTrue's bad backfill migration ---
-- Original buggy migration compared uuid to text (id = user_id::text), which can error.
-- We apply the intended backfill with a proper uuid-to-uuid comparison.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name   = 'identities'
      AND column_name  = 'last_sign_in_at'
  ) THEN
    UPDATE auth.identities
       SET last_sign_in_at = '2022-11-25'
     WHERE last_sign_in_at IS NULL
       AND created_at::date = '2022-11-25'
       AND updated_at::date = '2022-11-25'
       AND provider = 'email'
       AND id = user_id;  -- both are uuid
  END IF;
END $$;

-- --- IMPORTANT ---
-- Do NOT create any *schema_migrations* tables here.
--   - supabase-auth (GoTrue) expects:   auth.schema_migrations(version TEXT)
--   - supabase-realtime (Ecto) expects: public.schema_migrations(version BIGINT, inserted_at TIMESTAMP)
-- Both services manage their own migrations tables.
-- Your post-init job (db-init-supabase) will insert the two GoTrue skip markers
-- into auth.schema_migrations after the DB is healthy.
