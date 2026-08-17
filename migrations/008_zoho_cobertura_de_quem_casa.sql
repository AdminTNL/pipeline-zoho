-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — Cobertura PE: `de_quem_casa` → array
-- ════════════════════════════════════════════════════════════════
-- Ajuste de configuração (dado, não código) para o form CoberturaPE.
--
-- O campo `de_quem_casa` era seleção única no Zoho (string) e passou a
-- caixa de seleção (multi-seleção → array). Mapeamos ele com o transform
-- genérico `to_array` (criado em 007) para uniformizar o tipo em `data`.
--
-- Requer que 007_zoho_to_array_transform.sql já tenha sido executado.
--
-- Segurança: nada aqui toca em zoho_raw_submissions. O reprocessamento
-- apenas RE-LÊ o raw imutável e reescreve o normalized/errors. Se quiser
-- uma cópia de segurança antes do backfill, rode antes:
--
--   CREATE TABLE zoho_norm_bkp_cobertura_pe AS
--     SELECT * FROM zoho_submissions_normalized
--     WHERE form_id = 'CoberturaPECompleto21';
--
-- Os dois comandos abaixo são idempotentes (podem ser re-executados).
-- ════════════════════════════════════════════════════════════════

UPDATE zoho_form_registry
SET mapeamento = mapeamento || '{"de_quem_casa": {"campo": "de_quem_casa", "transform": "to_array"}}'::jsonb
WHERE form_id = 'CoberturaPECompleto21';

-- Re-aplica o mapeamento corrente sobre todo o histórico do form.
-- Retorna o número de submissões reprocessadas.
SELECT zoho_reprocess_form('CoberturaPECompleto21');
