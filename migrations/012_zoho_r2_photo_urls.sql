-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — foto_urls aponta pro R2
-- ════════════════════════════════════════════════════════════════
-- Contexto: a VPS que hospeda o Supabase self-hosted não comporta o
-- volume de anexos previsto (28+ GB só no form CoberturaPECompleto21,
-- ~6.180 arquivos, crescendo). Os anexos migram para um bucket R2
-- dedicado (`zoho-anexos`, mesma organização `<form_id>/<file_id>`),
-- publicado em `https://assets-pe.centraldeengajamento.com.br`. Ver
-- `worker/R2-MIGRATION.md`.
--
-- ⚠️ NÃO RODAR ISOLADO. Aplicar SÓ junto com (ou depois de) o corte do
-- fluxo n8n que passa a enviar os UPLOADS NOVOS pro R2 em vez do
-- Supabase Storage. Se essa view for trocada antes do corte, toda
-- submissão nova (que ainda vai só pro Supabase Storage) fica com
-- `foto_urls` apontando pra um arquivo que não existe no R2 ainda —
-- 404 na view até o corte acontecer. A migração dos arquivos JÁ
-- existentes (feita via worker temporário, ver R2-MIGRATION.md) não
-- tem esse problema — é sobre o histórico, que já está 1:1 replicado.
--
-- Puramente uma troca de domínio na construção da URL — mesma
-- organização de chave (`<form_id>/<file_id>`), sem mexer em dado.
-- ════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS zoho_vw_submissions_dashboard;

CREATE OR REPLACE VIEW zoho_vw_submissions_dashboard AS
SELECT
  n.id,
  n.raw_submission_id,
  n.form_id,
  n.submitted_at,
  n.data->>'nome'        AS nome,
  n.data->>'telefone'    AS telefone,
  n.data->>'localizacao' AS localizacao,
  (n.data->>'latitude')::float  AS latitude,
  (n.data->>'longitude')::float AS longitude,
  n.data AS data_completa,
  f.urls AS foto_urls
FROM zoho_submissions_normalized n
LEFT JOIN LATERAL (
  SELECT jsonb_agg(url ORDER BY ord) AS urls
  FROM (
    SELECT
      'https://assets-pe.centraldeengajamento.com.br/'
        || n.form_id || '/'
        || substring(u.value from '/file/d/([^/?]+)') AS url,
      u.ord
    FROM zoho_form_registry r
    CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(r.file_fields, '[]'::jsonb)) AS ff(field_name)
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE
        WHEN jsonb_typeof(n.data -> ff.field_name) = 'array'  THEN n.data -> ff.field_name
        WHEN jsonb_typeof(n.data -> ff.field_name) = 'string' THEN jsonb_build_array(n.data ->> ff.field_name)
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS u(value, ord)
    WHERE r.form_id = n.form_id
      AND u.value LIKE '%/file/d/%'
  ) s
) f ON true;
