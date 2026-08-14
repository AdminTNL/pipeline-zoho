-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — schema base
-- ════════════════════════════════════════════════════════════════
-- Execute no SQL Editor do Supabase (schema: public).
-- Todas as tabelas/views desta pipeline usam o prefixo `zoho_`.
--
-- Resumo do fluxo:
--   webhook/polling ──▶ zoho_raw_submissions (imutável, idempotente)
--        ──▶ RPC zoho_ingest_submission ──▶ zoho_submissions_normalized
--                                           (ou zoho_ingestion_errors)
--        ──▶ zoho_vw_submissions_core ──▶ dashboard
--
-- Este arquivo é idempotente: pode ser re-executado com segurança.
-- ════════════════════════════════════════════════════════════════

-- ── 3.1 zoho_form_registry — cadastro central de forms ──
-- Adicionar um form novo = inserir uma linha aqui. Nada de código.
CREATE TABLE IF NOT EXISTS zoho_form_registry (
  form_id        text PRIMARY KEY,                    -- ID/form_link_name do Zoho Forms
  nome           text NOT NULL,                       -- nome amigável
  form_family    text,                                -- agrupamento lógico (mesmo shape)
  mapeamento     jsonb NOT NULL DEFAULT '{}'::jsonb,  -- de-para: campo Zoho → campo padronizado
  ativo          boolean NOT NULL DEFAULT true,       -- desativa sem apagar histórico
  last_synced_at timestamptz,                         -- watermark do polling
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- ── 3.2 zoho_raw_submissions — baú imutável ──
-- Nunca é lido pelo dashboard. Fonte de auditoria/replay.
-- OBS: `form_id` NÃO tem FK para o registry de propósito. Assim uma
-- submissão de form ainda não cadastrado é gravada aqui (auditoria) e
-- cai em zoho_ingestion_errors, em vez de falhar por violação de FK.
CREATE TABLE IF NOT EXISTS zoho_raw_submissions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  form_id            text NOT NULL,
  zoho_submission_id text NOT NULL,                    -- chave de idempotência
  payload            jsonb NOT NULL,
  source             text NOT NULL CHECK (source IN ('webhook', 'polling')),
  received_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT zoho_raw_submissions_submission_id_unique UNIQUE (zoho_submission_id)
);

-- ── 3.3 zoho_submissions_normalized — resultado do mapeamento ──
-- Chaves padronizadas, independentes do form de origem.
CREATE TABLE IF NOT EXISTS zoho_submissions_normalized (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_submission_id uuid NOT NULL UNIQUE REFERENCES zoho_raw_submissions(id),
  form_id          text NOT NULL REFERENCES zoho_form_registry(form_id),
  submitted_at     timestamptz,
  data             jsonb NOT NULL
);

-- ── 3.4 zoho_ingestion_errors — linhas que falharam validação/mapeamento ──
-- Permite corrigir o `mapeamento` e reprocessar sem perder dado.
CREATE TABLE IF NOT EXISTS zoho_ingestion_errors (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_submission_id uuid REFERENCES zoho_raw_submissions(id),
  erro              text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  resolvido         boolean NOT NULL DEFAULT false
);

-- ── Índices ──
CREATE INDEX IF NOT EXISTS idx_zoho_raw_form_received
  ON zoho_raw_submissions(form_id, received_at);
CREATE INDEX IF NOT EXISTS idx_zoho_norm_form
  ON zoho_submissions_normalized(form_id);
CREATE INDEX IF NOT EXISTS idx_zoho_errors_resolvido
  ON zoho_ingestion_errors(resolvido);

-- ── 3.5 View núcleo comum ──
-- O dashboard consome SOMENTE esta view (nunca o jsonb bruto).
CREATE OR REPLACE VIEW zoho_vw_submissions_core AS
SELECT
  id,
  form_id,
  submitted_at,
  data->>'nome'        AS nome,
  data->>'telefone'    AS telefone,
  data->>'localizacao' AS localizacao,
  (data->>'latitude')::float  AS latitude,
  (data->>'longitude')::float AS longitude,
  data AS data_completa        -- extras específicos do form ficam acessíveis aqui
FROM zoho_submissions_normalized;

-- ── RLS ──
-- Escritas acontecem exclusivamente via RPC (SECURITY DEFINER), que
-- bypassa RLS. Acesso direto anon é negado por padrão.
ALTER TABLE zoho_form_registry          ENABLE ROW LEVEL SECURITY;
ALTER TABLE zoho_raw_submissions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE zoho_submissions_normalized ENABLE ROW LEVEL SECURITY;
ALTER TABLE zoho_ingestion_errors       ENABLE ROW LEVEL SECURITY;

-- Leitura para o dashboard. O service_role sempre ignora RLS; para leitura
-- com anon key ou usuários autenticados, adicione a política correspondente.
-- (Políticas abaixo cobrem `authenticated`; inclua `anon` se o dashboard
-- ler com a anon key.)
CREATE POLICY "zoho_read_registry"      ON zoho_form_registry          FOR SELECT TO authenticated USING (true);
CREATE POLICY "zoho_read_raw"           ON zoho_raw_submissions        FOR SELECT TO authenticated USING (true);
CREATE POLICY "zoho_read_normalized"    ON zoho_submissions_normalized FOR SELECT TO authenticated USING (true);
CREATE POLICY "zoho_read_errors"        ON zoho_ingestion_errors       FOR SELECT TO authenticated USING (true);
