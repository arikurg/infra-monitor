-- db/init.sql
-- Runs once on first container init (mounted into /docker-entrypoint-initdb.d).
-- The postgres image already creates POSTGRES_DB (appdb) and POSTGRES_USER
-- (appuser) from env, so we only need the application schema here.

CREATE TABLE IF NOT EXISTS incidents (
    id          SERIAL PRIMARY KEY,
    service     VARCHAR(50)  NOT NULL,
    status      VARCHAR(20)  NOT NULL,
    latency_ms  INTEGER,
    detail      TEXT,
    checked_at  TIMESTAMPTZ  DEFAULT NOW()
);
