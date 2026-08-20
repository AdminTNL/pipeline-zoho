# AGENTS.md

Repositório da pipeline reutilizável **Zoho Forms → Supabase** (captura de campo
offline). Adicionar um form novo é **configuração**, nunca código.

## Documentos de referência

- `README.md` — instalação, onboarding (Zoho + Supabase), gerenciamento de forms,
  webhook, reconciliação (Repush), reprocessamento, dashboard.
- `DASHBOARD.md` — como consumir os dados: criar dashboard, inspecionar o jsonb e
  explicar a estrutura de um form (payload + mapeamento).
- `migrations/` — schema + RPCs (001..010). Rodar em ordem no SQL Editor do Supabase.
- `n8n/` — workflow do webhook (`zoho-ingest-webhook.json`): ingest + branch de fotos.

## Convenções

- Tabelas/views da pipeline usam o prefixo `zoho_`.
- Escrita **só via RPC** (`SECURITY DEFINER`, `SET search_path = public`); RLS
  bloqueia escrita direta anon/authenticated.
- Dashboard lê **só as views** (`zoho_vw_submissions_core`,
  `zoho_vw_submissions_dashboard`), nunca `zoho_raw_submissions` nem o jsonb direto.
- `data` é jsonb com chaves padronizadas (do `mapeamento`) + extras crus.
- SQL avulso em `migrations/` deve ser idempotente; use `DROP ... IF EXISTS` quando
  a mudança altera assinatura de função ou colunas de view (Postgres não renomeia/reordena
  em `CREATE OR REPLACE`).
- Parâmetros de RPC chamadas via PostgREST **não** usam prefixo `p_` (o PostgREST
  casa as chaves do JSON com os nomes dos argumentos).
- Nomes de arquivo/objeto no bucket `zoho-anexos` seguem `<form_id>/<file_id>`.
- **Deleção de submissão é soft** (`zoho_delete_submission` marca `deleted_at`; `zoho_restore_submission` desfaz). Nunca apagar fisicamente `zoho_raw_submissions` — ele é imutável e é o que impede o "Repush" de re-ingerir.
- Em RPCs PL/pgSQL cujo parâmetro tem o mesmo nome de uma coluna, **qualifique a coluna E use `$1`** no WHERE (ex.: `WHERE zoho_submissions_normalized.raw_submission_id = $1`). Usar o nome do parâmetro vira variável e colide com a coluna (42702 "ambiguous") — mesmo padrão do `zoho_mark_synced` (002).
