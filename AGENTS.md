# AGENTS.md

Repositório da pipeline reutilizável **Zoho Forms → Supabase** (captura de campo
offline). Adicionar um form novo é **configuração**, nunca código.

## Documentos de referência

- `README.md` — instalação, onboarding (Zoho + Supabase), gerenciamento de forms,
  webhook, reconciliação (Repush), reprocessamento, dashboard.
- `DASHBOARD.md` — como consumir os dados: criar dashboard, inspecionar o jsonb e
  explicar a estrutura de um form (payload + mapeamento).
- `migrations/` — schema + RPCs (001..012). Rodar em ordem no SQL Editor do Supabase.
- `n8n/` — espelhos locais (`{nodes, connections, meta}`, formato de
  export do editor) da instância real, atualizados via `query-n8n`/
  `escrita-n8n` depois de cada mudança em produção — nunca editados à mão
  primeiro. **`zoho-forms-ingest-with-backup-sync.json`** é o fluxo de
  ingestão **oficial em produção** (`Zoho Forms Ingest (produção)`, id
  `hkFJBLTHiHSGQZU5`, path `zoho-forms-ingest-parallel`) desde 2026-08-19 —
  chama a RPC via sub-workflow (`Execute Workflow`), tem check antecipado de
  dedup + checagem de foto por `file_id` + dual-write Supabase/R2 + avisa o
  D1 (`Mark synced`). `zoho-ingest-webhook.json` é o fluxo de produção
  **antigo** (`Zoho Forms Ingest (Webhook)`, id `DXpRe6n1HoRtcxTM`) — **está
  inativo**, mantido só como histórico/rollback (chamava a RPC direto,
  sem sub-workflow). `zoho-ingest-core.json` é o sub-workflow compartilhado
  da RPC (`Zoho Ingest Core (backup)`). `zoho-forms-ingest-backup.json` é o
  fluxo do cron de backup (`Zoho Forms Ingest — Backup Replay`, id
  `RhHusynIWIx5PmPX`, path `zoho-forms-backup-replay`) — recebe reenvios do
  Worker (`worker/`) pra submissões que o caminho ao vivo não confirmou.
  Detalhe completo da arquitetura, do corte pra fluxo único e do que ainda
  falta: ver [worker/README.md](./worker/README.md).
- `worker/` — Cloudflare Worker + D1: backup de ingestão pra cobrir quedas
  do n8n. Ver [worker/README.md](./worker/README.md). Também documenta a
  migração de anexos Supabase Storage → R2, ver
  [worker/R2-MIGRATION.md](./worker/R2-MIGRATION.md).

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
