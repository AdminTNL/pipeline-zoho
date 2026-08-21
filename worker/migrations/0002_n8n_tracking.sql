-- ════════════════════════════════════════════════════════════════
-- zoho-forms-backup (Cloudflare Worker + D1) — rastreio de execução n8n
-- ════════════════════════════════════════════════════════════════
-- n8n_exec_id: id da execução n8n que confirmou o sucesso (pra abrir
-- direto no editor e depurar). n8n_flow_id: id do workflow de TOPO que
-- processou (produção/paralelo via caminho rápido, ou backup replay via
-- cron) — dá pra saber, sem adivinhar, se a submissão foi pega ao vivo ou
-- recuperada pelo backup.

ALTER TABLE zoho_submissions ADD COLUMN n8n_exec_id TEXT;
ALTER TABLE zoho_submissions ADD COLUMN n8n_flow_id TEXT;
