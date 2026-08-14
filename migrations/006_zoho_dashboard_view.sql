-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — view de dashboard (all-in-one)
-- ════════════════════════════════════════════════════════════════
-- Uma linha por submissão, com:
--   - núcleo comum tipado (nome, telefone, localizacao, latitude, longitude)
--   - data_completa (jsonb com TODOS os extras do form)
--   - foto_urls (array com as URLs públicas das fotos no bucket zoho-anexos)
--
-- Genérica: cobre qualquer form com `file_fields` declarado no registry.
-- A URL pública é derivada do file_id da URL do Google Drive que o Zoho
-- envia no webhook: https://drive.google.com/file/d/<ID>/view → <ID>.
--
-- DROP antes do CREATE: CREATE OR REPLACE VIEW não renomeia/reordena
-- colunas, então o DROP permite evoluir a view sem o erro 42P16.
-- ════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS zoho_vw_submissions_dashboard;

CREATE OR REPLACE VIEW zoho_vw_submissions_dashboard AS
SELECT
  n.id,
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
      'https://database.tnledu.shop/storage/v1/object/public/zoho-anexos/'
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
