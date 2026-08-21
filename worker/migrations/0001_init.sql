-- ════════════════════════════════════════════════════════════════
-- zoho-forms-backup (Cloudflare Worker + D1) — schema inicial
-- ════════════════════════════════════════════════════════════════
-- Bookkeeping de "essa submissão já chegou no Postgres?" — não é a fonte
-- de verdade de deduplicação (essa é a RPC zoho_ingest_submission, que já
-- é idempotente por si só). O D1 só evita reprocessamento redundante pelo
-- cron de backup.

CREATE TABLE zoho_submissions (
  dedup_key       TEXT PRIMARY KEY,
  form_id         TEXT NOT NULL,
  payload         TEXT NOT NULL,             -- JSON bruto do Zoho
  submitted_at    TEXT,                      -- ISO 8601, parseado de Added_Time
  received_at     TEXT NOT NULL DEFAULT (datetime('now')),
  synced          INTEGER NOT NULL DEFAULT 0,
  synced_at       TEXT,
  sync_attempts   INTEGER NOT NULL DEFAULT 0,
  last_attempt_at TEXT,
  last_error      TEXT
);

CREATE INDEX idx_zoho_submissions_pending ON zoho_submissions(received_at) WHERE synced = 0;
