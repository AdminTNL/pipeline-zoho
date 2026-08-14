-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — config por form
-- ════════════════════════════════════════════════════════════════
-- Execute depois de 001_zoho_schema.sql e 002_zoho_ingest_rpc.sql.
--
-- `required`: lista de chaves PADRONIZADAS (pós-mapeamento) que são
--   obrigatórias na validação. O default ["nome","telefone"] preserva o
--   comportamento original; forms que não captam nome/telefone usam
--   '[]' (aceita tudo) ou os campos que fizerem sentido.
--
-- `file_fields`: lista de nomes de campos do payload que contêm arquivos
--   (upload de foto/anexo). O webhook do Zoho manda apenas o NOME do
--   arquivo; o n8n baixa o arquivo do Google Drive (via "Manage Form
--   Attachments") e salva no bucket zoho-anexos com path determinístico
--   <form_id>/<nome_do_arquivo>.
-- ════════════════════════════════════════════════════════════════

ALTER TABLE zoho_form_registry
  ADD COLUMN IF NOT EXISTS required jsonb NOT NULL DEFAULT '["nome","telefone"]'::jsonb;

ALTER TABLE zoho_form_registry
  ADD COLUMN IF NOT EXISTS file_fields jsonb NOT NULL DEFAULT '[]'::jsonb;
