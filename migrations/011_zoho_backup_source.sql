-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — source 'backup_replay'
-- ════════════════════════════════════════════════════════════════
-- Contexto: sistema de backup de ingestão (Cloudflare Worker + D1, ver
-- worker/README.md). O Zoho passa a enviar cada submissão também para um
-- Worker, que grava no D1 e reenvia pro n8n de hora em hora só o que não
-- foi confirmado como processado. Esse reenvio chama a mesma RPC
-- `zoho_ingest_submission`, mas com `source = 'backup_replay'` (não é
-- 'webhook' — não veio da chegada ao vivo — nem 'polling' — não é a API
-- do Zoho Forms, que está descontinuada). Preserva o propósito original
-- da coluna `source`: medir quantas submissões o caminho ao vivo perdeu.
--
-- Mudança puramente aditiva (alarga o CHECK, não estreita) — não afeta
-- nenhuma linha existente.
-- ════════════════════════════════════════════════════════════════

ALTER TABLE zoho_raw_submissions DROP CONSTRAINT IF EXISTS zoho_raw_submissions_source_check;

ALTER TABLE zoho_raw_submissions
  ADD CONSTRAINT zoho_raw_submissions_source_check
  CHECK (source IN ('webhook', 'polling', 'backup_replay'));
