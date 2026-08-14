-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — RPCs de ingestão e reprocessamento
-- ════════════════════════════════════════════════════════════════
-- Execute depois de 001_zoho_schema.sql.
--
-- A ingestão acontece inteira dentro de uma transação:
--   1. grava em zoho_raw_submissions (idempotente por zoho_submission_id)
--   2. resolve o form em zoho_form_registry e aplica o mapeamento
--   3. valida os campos obrigatórios do form (config `required`)
--   4. grava em zoho_submissions_normalized OU zoho_ingestion_errors
--
-- Status (text) — usado pelo n8n para contar:
--   'ok'                → normalizado com sucesso
--   'duplicate'         → submissão já existia (webhook já trouxe)
--   'error_unregistered'→ form não cadastrado no registry
--   'error_inactive'    → form desativado
--   'error_invalid'     → campo obrigatório ausente
--   'not_found'         → (reprocess) raw não encontrado
--
-- Idempotência: o webhook do Zoho Forms NÃO envia o ID nativo da
-- submissão. A chave de idempotência (zoho_submission_id) é então
-- DERIVADA aqui, de forma determinística, a partir de campos comuns
-- presentes tanto no webhook quanto no polling (getRecords). Assim,
-- webhook e polling geram a mesma chave e a dedup funciona.
-- ════════════════════════════════════════════════════════════════

-- Deriva a chave de idempotência a partir de campos comuns do payload.
-- Determinística: mesmo payload → mesma chave, no webhook e no polling.
CREATE OR REPLACE FUNCTION zoho_derive_submission_id(p_payload jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_key text;
BEGIN
  v_key :=
    COALESCE(
      p_payload ->> 'email_id',
      p_payload ->> 'Email_ID',
      p_payload ->> 'Email', '') || '|' ||
    COALESCE(p_payload ->> 'nome', p_payload ->> 'Nome', '') || '|' ||
    COALESCE(p_payload ->> 'sobrenome', p_payload ->> 'Sobrenome', '') || '|' ||
    COALESCE(p_payload ->> 'telefone', p_payload ->> 'Telefone', '') || '|' ||
    COALESCE(
      p_payload ->> 'added_time',
      p_payload ->> 'Added_Time',
      p_payload ->> 'ADDED_TIME', '');

  -- Se não há nenhum campo comum (payload atípico), usa o hash do payload.
  IF btrim(v_key, '|') = '' THEN
    RETURN md5(p_payload::text);
  END IF;

  RETURN md5(v_key);
END;
$$;

-- Transforma um valor jsonb de acordo com o transform indicado no mapeamento.
CREATE OR REPLACE FUNCTION zoho_transform_value(p_value jsonb, p_transform text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text;
BEGIN
  IF p_value IS NULL OR p_value = 'null'::jsonb THEN
    RETURN NULL;
  END IF;

  -- Multi-valor (array): transforms não se aplicam, retorna como veio.
  IF jsonb_typeof(p_value) = 'array' THEN
    RETURN p_value;
  END IF;

  IF p_transform IS NULL OR p_transform = '' THEN
    RETURN p_value;
  END IF;

  v_text := p_value #>> '{}';

  CASE p_transform
    WHEN 'only_digits' THEN
      RETURN to_jsonb(regexp_replace(v_text, '[^0-9]', '', 'g'));
    WHEN 'trim' THEN
      RETURN to_jsonb(btrim(v_text));
    WHEN 'lower' THEN
      RETURN to_jsonb(lower(v_text));
    WHEN 'upper' THEN
      RETURN to_jsonb(upper(v_text));
    WHEN 'to_float' THEN
      IF NULLIF(btrim(v_text), '') IS NULL THEN RETURN NULL; END IF;
      RETURN to_jsonb(NULLIF(btrim(v_text), '')::double precision);
    WHEN 'to_int' THEN
      IF NULLIF(btrim(v_text), '') IS NULL THEN RETURN NULL; END IF;
      RETURN to_jsonb(NULLIF(btrim(v_text), '')::bigint);
    ELSE
      RETURN to_jsonb(v_text);
  END CASE;

EXCEPTION
  WHEN OTHERS THEN
    -- Transform inválido (ex.: "abc" → to_float): mantém o valor original.
    RETURN p_value;
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- Normaliza uma submissão já gravada em zoho_raw_submissions.
-- Recebe o raw_id (já inserido) + os dados, aplica mapeamento/validação
-- e grava no normalized OU em errors. Usado pela ingestão e pelo reprocessamento.
-- ────────────────────────────────────────────────────────────────
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
    INSERT INTO zoho_ingestion_errors (raw_submission_id, erro)
    VALUES (p_raw_id, 'form não cadastrado: ' || p_form_id);
    RETURN 'error_unregistered';
  END IF;

  IF v_registry.ativo IS NOT TRUE THEN
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
      INSERT INTO zoho_ingestion_errors (raw_submission_id, erro)
      VALUES (p_raw_id, 'campo obrigatório ausente: ' || (v_req #>> '{}'));
      RETURN 'error_invalid';
    END IF;
  END LOOP;

  -- Grava normalizado
  INSERT INTO zoho_submissions_normalized (raw_submission_id, form_id, submitted_at, data)
  VALUES (p_raw_id, p_form_id, p_submitted_at, v_data);

  RETURN 'ok';
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- Ponto de entrada principal (chamado pelo webhook e pelo polling).
-- ────────────────────────────────────────────────────────────────
-- Parâmetros SEM prefixo `p_`: o PostgREST casa as chaves do JSON do
-- body com os nomes dos argumentos (form_id, zoho_submission_id, ...).
-- Por isso o DROP antes do CREATE (CREATE OR REPLACE não renomeia args).
DROP FUNCTION IF EXISTS zoho_ingest_submission(text, text, jsonb, text, timestamptz);

CREATE OR REPLACE FUNCTION zoho_ingest_submission(
  form_id text,
  zoho_submission_id text,
  payload jsonb,
  source text,
  submitted_at timestamptz DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_raw_id uuid;
  v_submission_id text;
BEGIN
  v_submission_id := COALESCE(NULLIF(zoho_submission_id, ''), zoho_derive_submission_id(payload));

  INSERT INTO zoho_raw_submissions (form_id, zoho_submission_id, payload, source)
  VALUES (form_id, v_submission_id, payload, source)
  ON CONFLICT ON CONSTRAINT zoho_raw_submissions_submission_id_unique DO NOTHING
  RETURNING id INTO v_raw_id;

  IF v_raw_id IS NULL THEN
    RETURN 'duplicate';
  END IF;

  RETURN zoho_normalize_from_raw(v_raw_id, form_id, payload, submitted_at);
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- Reprocessa uma submissão já gravada (após corrigir o mapeamento).
-- ────────────────────────────────────────────────────────────────
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

  DELETE FROM zoho_submissions_normalized WHERE raw_submission_id = p_raw_id;
  DELETE FROM zoho_ingestion_errors WHERE raw_submission_id = p_raw_id;

  RETURN zoho_normalize_from_raw(v_raw.id, v_raw.form_id, v_raw.payload, v_raw.received_at);
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- Reprocessa todas as submissões de um form. Retorna quantas processou.
-- ────────────────────────────────────────────────────────────────
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
    DELETE FROM zoho_submissions_normalized WHERE raw_submission_id = v_raw.id;
    DELETE FROM zoho_ingestion_errors WHERE raw_submission_id = v_raw.id;
    PERFORM zoho_normalize_from_raw(v_raw.id, v_raw.form_id, v_raw.payload, v_raw.received_at);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- Atualiza o watermark de reconciliação do form (chamado pelo polling).
-- Usa `$1` para evitar colisão do nome do parâmetro `form_id` com a coluna
-- de mesmo nome (um `form_id = form_id` atualizaria todas as linhas).
DROP FUNCTION IF EXISTS zoho_mark_synced(text);

CREATE OR REPLACE FUNCTION zoho_mark_synced(form_id text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE zoho_form_registry SET last_synced_at = now()
  WHERE zoho_form_registry.form_id = $1;
$$;

-- ── Exposição via REST ──
-- Ingestão precisa de anon (webhook/polling). Reprocessamento fica
-- restrito a `authenticated` (roda no SQL Editor como o usuário dono).
GRANT EXECUTE ON FUNCTION zoho_ingest_submission(text, text, jsonb, text, timestamptz) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION zoho_mark_synced(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION zoho_normalize_from_raw(uuid, text, jsonb, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION zoho_reprocess_raw(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION zoho_reprocess_form(text) TO authenticated;
GRANT EXECUTE ON FUNCTION zoho_transform_value(jsonb, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION zoho_derive_submission_id(jsonb) TO anon, authenticated;
