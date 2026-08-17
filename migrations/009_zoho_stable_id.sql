-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — id estável (raw_submission_id)
-- ════════════════════════════════════════════════════════════════
-- Motivo: o `id` de zoho_submissions_normalized era um uuid gerado a
-- cada INSERT. O reprocessamento (DELETE + INSERT) REGENERAVA o id,
-- quebrando consumidores que ancoravam nele (dashboard de revisão).
--
-- O que muda aqui:
--   1. Reprocessamento passa a ser UPSERT em `raw_submission_id`,
--      PRESERVANDO o `id` já existente (o DO UPDATE não toca no id).
--   2. Erros e normalized são reconciliados no mesmo lugar, sem DELETE
--      manual nos reprocess_* (evita sobrar linha órfã / duplicar erro).
--   3. As views passam a expor `raw_submission_id` — o id IMUTÁVEL do
--      zoho_raw_submissions (não muda no Repush nem no reprocess) — que
--      passa a ser a âncora estável para os consumidores.
--
-- Segurança / dados: NÃO altera nenhuma linha existente. Só reescreve
-- definições de função e de view. Nenhum DELETE sobre dados atuais.
-- Idempotente: assinaturas não mudam (CREATE OR REPLACE), views usam
-- DROP ... IF EXISTS (adicionar coluna em view exige DROP + recreate).
-- ════════════════════════════════════════════════════════════════

-- ── 1. Normalização idempotente (preserva id no reprocess) ──
CREATE OR REPLACE FUNCTION zoho_normalize_from_raw(
  p_raw_id uuid,
  p_form_id text,
  p_payload jsonb,
  p_submitted_at timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_registry   zoho_form_registry%ROWTYPE;
  v_mapeamento jsonb;
  v_data       jsonb := '{}'::jsonb;
  v_zoho_field text;
  v_target     jsonb;
  v_std_key    text;
  v_transform  text;
  v_transformed jsonb;
  v_extra      jsonb;
  v_concat_with text;
  v_concat_sep  text;
  v_req        jsonb;
BEGIN
  -- Resolve o form no registry
  SELECT * INTO v_registry
  FROM zoho_form_registry
  WHERE form_id = p_form_id;

  IF NOT FOUND THEN
    DELETE FROM zoho_submissions_normalized WHERE raw_submission_id = p_raw_id;
    DELETE FROM zoho_ingestion_errors WHERE raw_submission_id = p_raw_id;
    INSERT INTO zoho_ingestion_errors (raw_submission_id, erro)
    VALUES (p_raw_id, 'form não cadastrado: ' || p_form_id);
    RETURN 'error_unregistered';
  END IF;

  IF v_registry.ativo IS NOT TRUE THEN
    DELETE FROM zoho_submissions_normalized WHERE raw_submission_id = p_raw_id;
    DELETE FROM zoho_ingestion_errors WHERE raw_submission_id = p_raw_id;
    INSERT INTO zoho_ingestion_errors (raw_submission_id, erro)
    VALUES (p_raw_id, 'form inativo: ' || p_form_id);
    RETURN 'error_inactive';
  END IF;

  -- Aplica o mapeamento (de-para + transforms)
  v_mapeamento := COALESCE(v_registry.mapeamento, '{}'::jsonb);

  FOR v_zoho_field, v_target IN
    SELECT key, value FROM jsonb_each(v_mapeamento)
  LOOP
    IF jsonb_typeof(v_target) = 'object' THEN
      v_std_key   := v_target ->> 'campo';
      v_transform := v_target ->> 'transform';
    ELSE
      v_std_key   := v_target #>> '{}';
      v_transform := NULL;
    END IF;

    IF v_std_key IS NOT NULL AND v_std_key <> '' THEN
      IF v_transform = 'concat' THEN
        -- concatena o campo atual com outro campo do payload (opcional: separator)
        v_concat_with := v_target ->> 'with';
        v_concat_sep  := COALESCE(NULLIF(v_target ->> 'separator', ''), ' ');
        v_transformed := to_jsonb(btrim(concat_ws(
          v_concat_sep,
          COALESCE(p_payload ->> v_zoho_field, ''),
          COALESCE(p_payload ->> v_concat_with, '')
        )));
        IF v_transformed = '""'::jsonb THEN
          v_transformed := NULL;
        END IF;
      ELSE
        v_transformed := zoho_transform_value(p_payload -> v_zoho_field, v_transform);
      END IF;

      IF v_transformed IS NOT NULL AND v_transformed <> 'null'::jsonb THEN
        v_data := v_data || jsonb_build_object(v_std_key, v_transformed);
      END IF;
    END IF;
  END LOOP;

  -- Extras: campos do payload fora do mapeamento (preserva tipos originais).
  -- Não sobrescrevem chaves já mapeadas.
  FOR v_extra IN
    SELECT jsonb_build_object(p.key, p.value) AS obj
    FROM jsonb_each(p_payload) AS p
    WHERE NOT v_mapeamento ? p.key
      AND NOT v_data ? p.key
  LOOP
    v_data := v_data || v_extra;
  END LOOP;

  -- Valida campos obrigatórios do form (chaves padronizadas, config em `required`)
  FOR v_req IN
    SELECT value FROM jsonb_array_elements(COALESCE(v_registry.required, '[]'::jsonb))
  LOOP
    IF v_data ->> (v_req #>> '{}') IS NULL OR btrim(v_data ->> (v_req #>> '{}')) = '' THEN
      DELETE FROM zoho_submissions_normalized WHERE raw_submission_id = p_raw_id;
      DELETE FROM zoho_ingestion_errors WHERE raw_submission_id = p_raw_id;
      INSERT INTO zoho_ingestion_errors (raw_submission_id, erro)
      VALUES (p_raw_id, 'campo obrigatório ausente: ' || (v_req #>> '{}'));
      RETURN 'error_invalid';
    END IF;
  END LOOP;

  -- Grava normalizado (UPSERT: preserva o `id` se a linha já existia).
  -- O DO UPDATE não inclui `id`, então o uuid existente é mantido.
  DELETE FROM zoho_ingestion_errors WHERE raw_submission_id = p_raw_id;

  -- UPSERT: preserva `id` e `submitted_at` já existentes. `submitted_at` não é
  -- tocado no reprocess porque ele deriva de Added_Time (parseado no n8n na
  -- primeira ingestão); o reprocess não tem esse valor e antes o sobrescrevia
  -- com received_at.
  INSERT INTO zoho_submissions_normalized (id, raw_submission_id, form_id, submitted_at, data)
  VALUES (gen_random_uuid(), p_raw_id, p_form_id, p_submitted_at, v_data)
  ON CONFLICT (raw_submission_id) DO UPDATE SET
    form_id      = EXCLUDED.form_id,
    data         = EXCLUDED.data;

  RETURN 'ok';
END;
$$;

-- ── 2. Reprocessamento: delega a reconciliação à normalização ──
CREATE OR REPLACE FUNCTION zoho_reprocess_raw(p_raw_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_raw zoho_raw_submissions%ROWTYPE;
BEGIN
  SELECT * INTO v_raw FROM zoho_raw_submissions WHERE id = p_raw_id;

  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;

  RETURN zoho_normalize_from_raw(v_raw.id, v_raw.form_id, v_raw.payload, v_raw.received_at);
END;
$$;

CREATE OR REPLACE FUNCTION zoho_reprocess_form(p_form_id text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_raw   zoho_raw_submissions%ROWTYPE;
  v_count bigint := 0;
BEGIN
  FOR v_raw IN
    SELECT * FROM zoho_raw_submissions WHERE form_id = p_form_id ORDER BY received_at
  LOOP
    PERFORM zoho_normalize_from_raw(v_raw.id, v_raw.form_id, v_raw.payload, v_raw.received_at);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ── 3. Views: expor `raw_submission_id` (id estável) ──
DROP VIEW IF EXISTS zoho_vw_submissions_core;

CREATE OR REPLACE VIEW zoho_vw_submissions_core AS
SELECT
  id,
  raw_submission_id,
  form_id,
  submitted_at,
  data->>'nome'        AS nome,
  data->>'telefone'    AS telefone,
  data->>'localizacao' AS localizacao,
  (data->>'latitude')::float  AS latitude,
  (data->>'longitude')::float AS longitude,
  data AS data_completa
FROM zoho_submissions_normalized;

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
