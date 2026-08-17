-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — transform genérico `to_array`
-- ════════════════════════════════════════════════════════════════
-- Adiciona o transform `to_array` a zoho_transform_value, para
-- normalizar campos que mudam de seleção única → caixa de seleção
-- (multi-seleção / checkbox) no Zoho Forms.
--
-- Semântica (universal, vale para qualquer form):
--   null / string vazia  → NULL (chave ausente)
--   string não-vazia     → [string] (single-element array)
--   array                → passa intocado (short-circuit em 002)
--
-- Idempotente: o Zoho manda o checkbox já como array, e arrays são
-- devolvidos antes do CASE — então `to_array` NUNCA dobra um array.
-- Como a assinatura (jsonb, text) não muda, CREATE OR REPLACE basta.
-- ════════════════════════════════════════════════════════════════

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
    WHEN 'to_array' THEN
      IF btrim(v_text) = '' THEN RETURN NULL; END IF;
      RETURN to_jsonb(ARRAY[v_text]);
    ELSE
      RETURN to_jsonb(v_text);
  END CASE;

EXCEPTION
  WHEN OTHERS THEN
    -- Transform inválido (ex.: "abc" → to_float): mantém o valor original.
    RETURN p_value;
END;
$$;

GRANT EXECUTE ON FUNCTION zoho_transform_value(jsonb, text) TO anon, authenticated;
