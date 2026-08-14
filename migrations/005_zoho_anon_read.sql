-- ════════════════════════════════════════════════════════════════
-- Pipeline Zoho Forms → Supabase — leitura anon do registry
-- ════════════════════════════════════════════════════════════════
-- O n8n lê o `zoho_form_registry` diretamente (GET no `file_fields`)
-- usando a chave anon. Por isso o registry precisa de SELECT para `anon`
-- (apenas leitura de config — sem dado sensível).
--
-- O restante da escrita continua exclusivamente via RPC (SECURITY DEFINER),
-- que bypassa o RLS. Esta política só habilita LEITURA do registry.
-- ════════════════════════════════════════════════════════════════

CREATE POLICY "zoho_read_registry_anon"
  ON zoho_form_registry
  FOR SELECT TO anon USING (true);
