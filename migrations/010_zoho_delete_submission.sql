-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — soft delete de submissão
-- ════════════════════════════════════════════════════════════════
-- Execute depois de 009_zoho_stable_id.sql.
--
-- Deleção SOFT: em vez de apagar fisicamente, marca a linha em
-- zoho_submissions_normalized com `deleted_at` e esconde das views.
-- Motivação:
--   - o raw (zoho_raw_submissions) permanece IMUTÁVEL (auditoria);
--   - um "Repush" do Zoho acha a chave de idempotência no raw → vira
--     "duplicate" e NÃO re-ingere (a submissão não "volta");
--   - o reprocessamento (zoho_normalize_from_raw) usa UPSERT que NÃO
--     toca em `deleted_at` → uma submissão soft-deletada não "ressuscita";
--   - reversível via zoho_restore_submission (só SQL).
--
-- ⚠️ Coluna qualificada + `$1` nos WHERE: o parâmetro raw_submission_id tem o
-- mesmo nome da coluna. Em PL/pgSQL o nome do parâmetro vira uma variável e
-- colide com a coluna (42702 "ambiguous"); usar `$1` (posicional) evita a
-- colisão — mesmo padrão do zoho_mark_synced da 002.
--
-- ⚠️ Fotos: a deleção das fotos no bucket NÃO é feita aqui (SQL não alcança
-- Storage). O painel central apaga os anexos via Storage API antes de chamar
-- esta RPC. Restaurar recupera o registro, mas não as fotos.
--
-- Parâmetros SEM prefixo p_ (chamadas via PostgREST).
-- Idempotente: pode ser re-executado com segurança.
-- ════════════════════════════════════════════════════════════════

-- ── 1. Coluna de soft delete ──
ALTER TABLE zoho_submissions_normalized
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- ── 2. Soft delete (esconde das views) ──
CREATE OR REPLACE FUNCTION zoho_delete_submission(raw_submission_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE zoho_submissions_normalized
     SET deleted_at = now()
   WHERE zoho_submissions_normalized.raw_submission_id = $1;

  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;

  RETURN 'ok';
END;
$$;

-- ── 3. Restauração (desfaz o soft delete) ──
CREATE OR REPLACE FUNCTION zoho_restore_submission(raw_submission_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE zoho_submissions_normalized
     SET deleted_at = NULL
   WHERE zoho_submissions_normalized.raw_submission_id = $1;

  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;

  RETURN 'ok';
END;
$$;

-- ── 4. Privilégios: remove o default PUBLIC e libera só o service_role ──
-- (o painel central chama via service_role; anon/authenticated ficam bloqueados).
-- REVOKE de PUBLIC NÃO basta: o Supabase concede anon/authenticated via
-- default privileges na criação do objeto — revogar explicitamente também.
REVOKE ALL ON FUNCTION zoho_delete_submission(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION zoho_delete_submission(uuid) TO service_role;

REVOKE ALL ON FUNCTION zoho_restore_submission(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION zoho_restore_submission(uuid) TO service_role;

-- ── 5. Views excluem submissões soft-deletadas ──
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
FROM zoho_submissions_normalized
WHERE deleted_at IS NULL;

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
) f ON true
WHERE n.deleted_at IS NULL;
