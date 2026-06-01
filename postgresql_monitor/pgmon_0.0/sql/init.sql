-- =============================================================
-- pgmon : 모니터링 DB 초기화 SQL
-- =============================================================

-- role
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgmon_owner') THEN
    CREATE ROLE pgmon_owner WITH LOGIN PASSWORD 'pgmon_owner_pass' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgmon_writer') THEN
    CREATE ROLE pgmon_writer WITH LOGIN PASSWORD 'pgmon_writer_pass' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgmon_reader') THEN
    CREATE ROLE pgmon_reader WITH LOGIN PASSWORD 'pgmon_reader_pass' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END$$;

-- database
SELECT pg_catalog.set_config('search_path', '', false);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'pgmon') THEN
    PERFORM dblink_exec('dbname=postgres', 'CREATE DATABASE pgmon OWNER pgmon_owner');
  END IF;
END$$;

\connect pgmon

-- extension (모니터링 DB 자체에는 불필요, 대상 DB에 설치)
-- pgmon DB는 순수 저장소 역할

-- schema
CREATE SCHEMA IF NOT EXISTS pgmon AUTHORIZATION pgmon_owner;

SET search_path = pgmon;

-- -------------------------------------------------------
-- 등록된 대상 DB 목록
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS registered_db (
    db_id          SERIAL PRIMARY KEY,
    nickname       VARCHAR(64) NOT NULL UNIQUE,
    host           VARCHAR(128) NOT NULL,
    port           INTEGER NOT NULL DEFAULT 5432,
    dbname         VARCHAR(64) NOT NULL,
    username       VARCHAR(64) NOT NULL,
    password       VARCHAR(256),
    retention_days INTEGER NOT NULL DEFAULT 15,
    active         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -------------------------------------------------------
-- 수집 설정 (메트릭별 수집 주기)
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS collection_config (
    config_id      SERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    metric_name    VARCHAR(64) NOT NULL,   -- dashboard, session, statement, vacuum, object, lock
    interval_sec   INTEGER NOT NULL DEFAULT 60,
    enabled        BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(db_id, metric_name)
);

-- -------------------------------------------------------
-- 대시보드 / 서버 상태 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_server_info (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    pg_version     VARCHAR(64),
    hostname       VARCHAR(128),
    server_ip      VARCHAR(64),
    db_uptime      INTERVAL,
    db_status      VARCHAR(32),     -- active / inactive
    ha_enabled     BOOLEAN,
    ha_role        VARCHAR(16),     -- primary / standby
    ha_last_switchover TIMESTAMPTZ,
    wal_size_bytes BIGINT,
    total_sessions INTEGER,
    active_sessions INTEGER,
    idle_sessions  INTEGER,
    idle_in_tx_sessions INTEGER,
    long_sessions  INTEGER,
    long_sql_count INTEGER,
    lock_count     INTEGER,
    vacuum_running INTEGER,
    dead_tuples_total BIGINT,
    cpu_usage_pct  NUMERIC(5,2),
    mem_total_mb   BIGINT,
    mem_used_mb    BIGINT,
    mem_usage_pct  NUMERIC(5,2),
    swap_total_mb  BIGINT,
    swap_used_mb   BIGINT,
    swap_usage_pct NUMERIC(5,2),
    disk_read_kbs  NUMERIC(12,2),
    disk_write_kbs NUMERIC(12,2)
);

CREATE INDEX IF NOT EXISTS idx_snap_server_db_time ON snap_server_info(db_id, collected_at DESC);

-- -------------------------------------------------------
-- 세션 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_session (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    pid            INTEGER,
    usename        VARCHAR(64),
    appname        VARCHAR(128),
    client_addr    VARCHAR(64),
    state          VARCHAR(32),
    wait_event_type VARCHAR(64),
    wait_event     VARCHAR(64),
    duration_sec   NUMERIC(12,2),
    query          TEXT,
    backend_type   VARCHAR(64)
);

CREATE INDEX IF NOT EXISTS idx_snap_session_db_time ON snap_session(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Statement 스냅샷 (pg_stat_statements)
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_statement (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    queryid        BIGINT,
    usename        VARCHAR(64),
    dbname         VARCHAR(64),
    calls          BIGINT,
    total_exec_ms  NUMERIC(18,3),
    mean_exec_ms   NUMERIC(18,3),
    max_exec_ms    NUMERIC(18,3),
    rows           BIGINT,
    shared_blks_hit BIGINT,
    shared_blks_read BIGINT,
    blk_hit_pct   NUMERIC(5,2),
    query          TEXT
);

CREATE INDEX IF NOT EXISTS idx_snap_stmt_db_time ON snap_statement(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Vacuum 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_vacuum (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname     VARCHAR(128),
    tablename      VARCHAR(128),
    last_vacuum    TIMESTAMPTZ,
    last_autovacuum TIMESTAMPTZ,
    last_analyze   TIMESTAMPTZ,
    n_dead_tup     BIGINT,
    n_live_tup     BIGINT,
    dead_ratio_pct NUMERIC(6,2),
    vacuum_count   BIGINT,
    autovacuum_count BIGINT,
    is_running     BOOLEAN DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_snap_vacuum_db_time ON snap_vacuum(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Lock 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_lock (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    blocking_pid   INTEGER,
    blocking_user  VARCHAR(64),
    blocking_query TEXT,
    blocked_pid    INTEGER,
    blocked_user   VARCHAR(64),
    blocked_query  TEXT,
    blocked_duration_sec NUMERIC(12,2),
    lock_type      VARCHAR(64)
);

CREATE INDEX IF NOT EXISTS idx_snap_lock_db_time ON snap_lock(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Object (테이블/인덱스) 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_table (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname     VARCHAR(128),
    tablename      VARCHAR(128),
    total_size_bytes BIGINT,
    table_size_bytes BIGINT,
    index_size_bytes BIGINT,
    seq_scan       BIGINT,
    idx_scan       BIGINT,
    n_live_tup     BIGINT,
    n_dead_tup     BIGINT,
    bloat_ratio_pct NUMERIC(6,2)
);

CREATE INDEX IF NOT EXISTS idx_snap_table_db_time ON snap_table(db_id, collected_at DESC);

CREATE TABLE IF NOT EXISTS snap_index (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname     VARCHAR(128),
    tablename      VARCHAR(128),
    indexname      VARCHAR(128),
    index_size_bytes BIGINT,
    idx_scan       BIGINT,
    idx_tup_read   BIGINT,
    idx_tup_fetch  BIGINT,
    is_unique      BOOLEAN,
    is_primary     BOOLEAN
);

CREATE INDEX IF NOT EXISTS idx_snap_index_db_time ON snap_index(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Replication 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_replication (
    snap_id        BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    client_addr    VARCHAR(64),
    usename        VARCHAR(64),
    application_name VARCHAR(128),
    state          VARCHAR(32),
    sync_state     VARCHAR(32),
    sent_lsn       TEXT,
    write_lsn      TEXT,
    flush_lsn      TEXT,
    replay_lsn     TEXT,
    replay_lag     INTERVAL,
    write_lag      INTERVAL,
    flush_lag      INTERVAL
);

CREATE INDEX IF NOT EXISTS idx_snap_repl_db_time ON snap_replication(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Alert 설정
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS alert_config (
    alert_id       SERIAL PRIMARY KEY,
    db_id          INTEGER REFERENCES registered_db(db_id) ON DELETE CASCADE,  -- NULL이면 전체 적용
    metric_name    VARCHAR(64) NOT NULL,
    warn_threshold NUMERIC,
    crit_threshold NUMERIC,
    enabled        BOOLEAN NOT NULL DEFAULT TRUE,
    notify_type    VARCHAR(32) DEFAULT 'log',   -- log / slack / email (확장 여지)
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 기본 alert 임계값 삽입
INSERT INTO alert_config (db_id, metric_name, warn_threshold, crit_threshold) VALUES
  (NULL, 'cpu_usage_pct',        70, 90),
  (NULL, 'mem_usage_pct',        75, 90),
  (NULL, 'swap_usage_pct',       50, 80),
  (NULL, 'lock_count',           5,  20),
  (NULL, 'idle_in_tx_sessions',  5,  15),
  (NULL, 'long_sessions',        3,  10),
  (NULL, 'dead_ratio_pct',       20, 50),
  (NULL, 'replication_lag_sec',  30, 120)
ON CONFLICT DO NOTHING;

-- -------------------------------------------------------
-- Alert 이력
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS alert_history (
    alert_hist_id  BIGSERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    fired_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    metric_name    VARCHAR(64),
    severity       VARCHAR(8),    -- WARN / CRIT
    current_value  NUMERIC,
    threshold      NUMERIC,
    message        TEXT,
    resolved_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_alert_hist_db_time ON alert_history(db_id, fired_at DESC);

-- -------------------------------------------------------
-- 권한 부여
-- -------------------------------------------------------
GRANT USAGE ON SCHEMA pgmon TO pgmon_writer, pgmon_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pgmon TO pgmon_writer;
GRANT SELECT ON ALL TABLES IN SCHEMA pgmon TO pgmon_reader;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgmon TO pgmon_writer;

ALTER DEFAULT PRIVILEGES IN SCHEMA pgmon
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pgmon_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmon
  GRANT SELECT ON TABLES TO pgmon_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmon
  GRANT USAGE, SELECT ON SEQUENCES TO pgmon_writer;
