import type { ZohoPayload } from "./dedup";

export interface SubmissionRow {
  dedup_key: string;
  form_id: string;
  payload: string;
  submitted_at: string | null;
  received_at: string;
  synced: number;
  synced_at: string | null;
  sync_attempts: number;
  last_attempt_at: string | null;
  last_error: string | null;
  n8n_exec_id: string | null;
  n8n_flow_id: string | null;
}

// Nunca reverte uma linha já synced=1 de volta pra 0 — só cria a linha se
// ainda não existir. Usado pelo webhook público (chegada do Zoho).
export async function insertPending(
  db: D1Database,
  dedupKey: string,
  formId: string,
  payload: ZohoPayload,
  submittedAt: string | null
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO zoho_submissions (dedup_key, form_id, payload, submitted_at, received_at, synced)
       VALUES (?, ?, ?, ?, datetime('now'), 0)
       ON CONFLICT(dedup_key) DO NOTHING`
    )
    .bind(dedupKey, formId, JSON.stringify(payload), submittedAt)
    .run();
}

// Upsert de verdade: cria a linha (se o callback do n8n chegar antes do
// webhook do Zoho) ou marca synced=1 (se a linha já existia). Usado pelo
// callback /internal/mark-synced — o caminho rápido (produção/paralelo).
export async function markSynced(
  db: D1Database,
  dedupKey: string,
  formId: string,
  payload: ZohoPayload,
  submittedAt: string | null,
  n8nExecId: string | null,
  n8nFlowId: string | null
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO zoho_submissions (dedup_key, form_id, payload, submitted_at, received_at, synced, synced_at, n8n_exec_id, n8n_flow_id)
       VALUES (?, ?, ?, ?, datetime('now'), 1, datetime('now'), ?, ?)
       ON CONFLICT(dedup_key) DO UPDATE SET
         synced = 1, synced_at = datetime('now'),
         n8n_exec_id = excluded.n8n_exec_id, n8n_flow_id = excluded.n8n_flow_id`
    )
    .bind(dedupKey, formId, JSON.stringify(payload), submittedAt, n8nExecId, n8nFlowId)
    .run();
}

// Marca synced=1 numa linha já existente (não cria) — usado pelo cron
// depois que o backup replay confirma sucesso.
export async function markSyncedByKey(
  db: D1Database,
  dedupKey: string,
  n8nExecId: string | null,
  n8nFlowId: string | null
): Promise<void> {
  await db
    .prepare(
      `UPDATE zoho_submissions
       SET synced = 1, synced_at = datetime('now'), n8n_exec_id = ?, n8n_flow_id = ?
       WHERE dedup_key = ?`
    )
    .bind(n8nExecId, n8nFlowId, dedupKey)
    .run();
}

// Leitura pura — usada pelo check antecipado dos fluxos n8n (early exit
// antes de baixar foto/chamar RPC de novo pra algo já concluído).
export async function isSynced(db: D1Database, dedupKey: string): Promise<boolean> {
  const row = await db
    .prepare(`SELECT synced FROM zoho_submissions WHERE dedup_key = ?`)
    .bind(dedupKey)
    .first<{ synced: number }>();
  return !!row && row.synced === 1;
}

export async function getPendingBatch(db: D1Database, limit: number): Promise<SubmissionRow[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM zoho_submissions
       WHERE synced = 0 AND sync_attempts < 50
       ORDER BY received_at ASC
       LIMIT ?`
    )
    .bind(limit)
    .all<SubmissionRow>();
  return results ?? [];
}

export async function markAttemptFailure(db: D1Database, dedupKey: string, error: string): Promise<void> {
  await db
    .prepare(
      `UPDATE zoho_submissions
       SET sync_attempts = sync_attempts + 1, last_attempt_at = datetime('now'), last_error = ?
       WHERE dedup_key = ?`
    )
    .bind(error.slice(0, 500), dedupKey)
    .run();
}

export async function getStatus(db: D1Database) {
  const counts = await db
    .prepare(
      `SELECT
         SUM(CASE WHEN synced = 1 THEN 1 ELSE 0 END) AS synced_count,
         SUM(CASE WHEN synced = 0 AND sync_attempts < 50 THEN 1 ELSE 0 END) AS pending_count,
         SUM(CASE WHEN synced = 0 AND sync_attempts >= 50 THEN 1 ELSE 0 END) AS dead_letter_count
       FROM zoho_submissions`
    )
    .first();
  const oldestPending = await db
    .prepare(
      `SELECT dedup_key, form_id, received_at, sync_attempts, last_error
       FROM zoho_submissions WHERE synced = 0 ORDER BY received_at ASC LIMIT 20`
    )
    .all();
  return { counts, oldest_pending: oldestPending.results ?? [] };
}
