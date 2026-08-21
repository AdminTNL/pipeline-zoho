# zoho-forms-backup (Cloudflare Worker + D1 + R2)

Duas responsabilidades no mesmo Worker:

1. **Caminho de segurança para a ingestão** de submissões do Zoho Forms —
   existe porque o n8n roda numa VPS em Docker Swarm que eventualmente
   reinicia, e mesmo 2-3 minutos fora do ar podem significar perder uma
   submissão de campo para sempre (o Zoho Forms não reenvia webhook falho
   automaticamente, e o polling via API foi descontinuado).
2. **Dual-write de anexos** (`/internal/upload-asset`) pro bucket R2
   `zoho-anexos`, chamado pelos nodes de foto do n8n (produção, paralelo e
   backup) em paralelo ao upload no Supabase Storage — ver
   [R2-MIGRATION.md](./R2-MIGRATION.md) pro contexto completo (por que
   migrar, como o histórico foi copiado, como o dual-write funciona).

## Como funciona

**Descoberta em produção**: o Zoho Forms só permite **1 webhook por
form** (não dá pra registrar 2+ notificações em paralelo, como o desenho
original previa). Isso muda quem recebe a submissão primeiro: em vez de
Zoho falar direto com o n8n E com o Worker, o Zoho fala **só com o
Worker**, que é quem repassa (fan-out) pro(s) n8n configurado(s). Não
muda o fluxo de produção em si (nenhum node dele foi tocado) — só troca
pra onde o Zoho aponta, uma configuração do lado do Zoho.

```
Zoho Forms (submissão)
   └──▶ Worker (/zoho-forms-backup)     ← ÚNICO webhook cadastrado no Zoho
            ├─ grava no D1 com synced=false                (durabilidade)
            └─ repassa pro webhook de ingestão do n8n       (caminho rápido)

Cron horário (0 * * * *):
   D1 (synced=false, tentativas < 50)
      └─ reenvia pro webhook de backup do n8n
           └─ sucesso → synced=true | falha → tentativa++, tenta de novo na próxima hora
```

O repasse pro n8n é *best-effort*, via `ctx.waitUntil` (não atrasa a
resposta ao Zoho): se o n8n estiver fora do ar, o repasse falha
silenciosamente, mas a linha já está gravada no D1 — o cron horário pega
depois. Isso preserva exatamente a garantia original ("nunca perde,
no pior caso atrasa até 1h") — o Worker é o ponto de entrada único, seguro
porque Workers rodam na edge da Cloudflare, independente da VPS do n8n —
não introduz um novo ponto de falha compartilhado com o que estamos
tentando proteger.

`N8N_INGEST_URL` é uma `var` (não secret) no `wrangler.jsonc` — aponta pro
fluxo de ingestão ativo. **Histórico**: até 2026-08-19 o Worker fazia
fan-out pra dois fluxos n8n em paralelo (`N8N_PRODUCTION_URL` +
`N8N_PARALLEL_URL`, com 2s de vantagem pro paralelo) durante um período de
validação com tráfego real. Validado com ~562 execuções 100% `success` e
paridade funcional completa, o fluxo `[PARALELO/VALIDAÇÃO]` foi promovido a
produção (renomeado pra `Zoho Forms Ingest (produção)`, mesmo id
`hkFJBLTHiHSGQZU5`), o `Zoho Forms Ingest (Webhook)` antigo (id
`DXpRe6n1HoRtcxTM`) foi **desativado** (não deletado — fica como
histórico/rollback), e o Worker voltou a repassar pra um único destino, sem
delay.

A ingestão em si (Postgres, `zoho_ingest_submission`) já é idempotente por
conta própria — deriva uma chave determinística do payload e faz `ON
CONFLICT DO NOTHING`. O D1 aqui é só **bookkeeping de eficiência** (evita
reprocessar hora a hora o que o caminho rápido já capturou), não a fonte de
verdade de deduplicação. Pior caso de qualquer bug nesta camada: uma
chamada de RPC redundante que volta `'duplicate'` — nunca dado duplicado.

## Estado atual (o que já está feito)

- ✅ Worker publicado: `https://zoho-forms-backup.gentle-pine-bedc.workers.dev`
- ✅ D1 `zoho-backup` criado, migrations `0001_init.sql`/`0002_n8n_tracking.sql` aplicadas
- ✅ R2 `zoho-anexos` com binding `PHOTOS` — dual-write ativo (ver [R2-MIGRATION.md](./R2-MIGRATION.md))
- ✅ 5 secrets configurados (`ZOHO_BACKUP_TOKEN`, `INGEST_CALLBACK_TOKEN`, `N8N_BACKUP_TOKEN`, `ASSET_UPLOAD_TOKEN`, `CHECK_SYNCED_TOKEN`)
- ✅ Cron horário registrado
- ✅ Webhook do Zoho (form `CoberturaPECompleto21`) já aponta pro Worker
  (único ponto de entrada) desde 2026-08-19
- ✅ `migrations/011_zoho_backup_source.sql` aplicada (confirmado via
  constraint real no Postgres) — caminho de backup-replay desbloqueado
- ✅ n8n: sub-workflow `Zoho Ingest Core (backup)` criado (id `qJsTKWztz6IRjWRB`)
- ✅ n8n: fluxo `Zoho Forms Ingest — Backup Replay` criado e **ativo**
  (id `RhHusynIWIx5PmPX`, path `zoho-forms-backup-replay`)
- ✅ n8n: **`Zoho Forms Ingest (produção)`** (id `hkFJBLTHiHSGQZU5`, path
  `zoho-forms-ingest-parallel`) — fluxo único de ingestão em produção desde
  2026-08-19 (ex-`[PARALELO/VALIDAÇÃO]`, promovido depois de validado com
  tráfego real). O `Zoho Forms Ingest (Webhook)` antigo (id
  `DXpRe6n1HoRtcxTM`) está **inativo**, mantido só como histórico/rollback.
- ✅ Testado ponta a ponta: webhook público (dedup/auth), callback de
  mark-synced (upsert sem duplicar linha), a cadeia
  webhook-de-backup → sub-workflow → RPC (incluindo o branch de erro).
- ✅ **Check antecipado** (`/internal/check-synced`): os fluxos n8n
  (produção, backup) checam logo depois do `Extract submission` se aquela
  hash já está `synced=1` — se sim, param ali, sem chamar a RPC de novo.
  Foto tem check **separado** por `file_id` (`Check photo exists`), não
  gateado pelo mesmo hash — evita a colisão descrita abaixo.
- ✅ **Produção chama `mark-synced`** — `Ingest (RPC)` (dentro do
  sub-workflow `Zoho Ingest Core`) → sucesso → `Mark synced (backup D1)`.
- ⚠️ **Bug de colisão de hash (corrigido)**: forms sem nome/telefone/email
  (ex. `CoberturaPECompleto21`) degeneram a chave de dedup pra só
  `added_time` — duas submissões reais diferentes no mesmo segundo
  colidiram, e a otimização do check antecipado (na época, gateando RPC E
  foto pelo mesmo hash) fez a segunda pular o upload da própria foto, que
  nunca tinha sido feito. Corrigido separando os dois checks (RPC por
  hash, foto por `file_id` único do Drive). Foto perdida recuperada
  reenviando o payload original pelo fluxo já corrigido.
- ✅ **Cron de backup validado ponta a ponta com o trigger real** (não só
  simulado) — 2026-08-20: resetei manualmente 3 linhas já `synced=1` no D1
  pra `synced=0` e esperei o próximo disparo natural do
  `triggers.crons` (`0 * * * *`) da Cloudflare. Resultado: o trigger
  disparou no minuto exato, pegou as 3 linhas, reenviou pro
  `zoho-forms-backup-replay` (3 execuções novas nele, todas `success`,
  ~1-3s cada) e o D1 voltou pra `synced=1` com `n8n_flow_id =
  RhHusynIWIx5PmPX` — prova de que quem sincronizou foi o caminho de
  backup, não o ao vivo. Primeira confirmação real de que o cron horário
  funciona (antes disso, nunca tinha havido uma submissão que ficasse
  pendente tempo suficiente pra precisar dele).

## O que falta — só você pode fazer

### 1. Dashboard ainda lê fotos do Supabase Storage, não do R2

`foto_urls` (view `zoho_vw_submissions_dashboard`) constrói a URL com
domínio fixo do Supabase Storage — `migrations/012_zoho_r2_photo_urls.sql`
troca pro domínio do R2, já é segura de aplicar (dual-write ativo, todo o
histórico já replicado 1:1). **Mas antes de aplicar**: o dashboard
(`cobertura-coordenadores-pe`, hospedado no Netlify) usa o proxy de
otimização de imagem do Netlify (`/.netlify/images?url=...`), que tem um
allowlist de domínios remotos — testado ao vivo em 2026-08-19 e confirmado
que `assets-pe.centraldeengajamento.com.br` **não está** nesse allowlist
(erro `400: url ... is not an allowed pattern`). Sem adicionar o domínio
do R2 no `[images].remote_images` do `netlify.toml` desse dashboard
**antes**, aplicar a migration 011 quebra toda foto em produção mesmo o R2
funcionando perfeitamente por fora. Repositório do dashboard não
localizado nas pastas locais conhecidas — confirmar caminho antes de
mexer.

## Schema do D1 (`zoho_submissions`)

| coluna | tipo | descrição |
| --- | --- | --- |
| `dedup_key` | TEXT (PK) | SHA-256 de `email_id\|nome\|sobrenome\|telefone\|added_time` do payload — mesma composição de campos da RPC `zoho_derive_submission_id`, hasheada diferente (Worker não tem MD5). Não é a fonte de verdade de dedup, só bookkeeping consistente entre os escritores do D1. |
| `form_id`, `payload`, `submitted_at`, `received_at` | TEXT | dados da submissão (payload bruto do Zoho, serializado). |
| `synced` | INTEGER (0/1) | 0 = ainda não confirmado no Postgres; 1 = confirmado. |
| `synced_at` | TEXT | quando virou `synced=1`. |
| `sync_attempts`, `last_attempt_at`, `last_error` | — | tentativas do cron que falharam; 50 tentativas (~2 dias) vira dead letter. |
| `n8n_exec_id` | TEXT | id da execução n8n que confirmou o sucesso — abre direto no editor pra depurar. |
| `n8n_flow_id` | TEXT | id do **workflow de topo** que processou: `hkFJBLTHiHSGQZU5` (`Zoho Forms Ingest (produção)`, o fluxo oficial), `DXpRe6n1HoRtcxTM` (produção antiga, inativa — só aparece em linhas de antes do corte de 2026-08-19), ou `RhHusynIWIx5PmPX` (backup replay via cron) — dá pra saber se a submissão foi pega ao vivo ou recuperada pelo backup, sem adivinhar. |

Preenchidos em dois pontos: `handleMarkSynced` (callback síncrono do
fluxo que processou ao vivo, manda `exec_id`/`flow_id` via
`$execution.id`/`$workflow.id`) e `processPending` (cron, lê os mesmos
campos da resposta do webhook de backup replay, que também os expõe via
`$execution.id`/`$workflow.id` — mas do **backup replay**, não do
sub-workflow `Zoho Ingest Core` que ele chama por baixo).

## Operação

- **Ver pendências**: `GET /internal/status` com header `x-internal-token`
  (contagens + as 20 mais antigas pendentes). O token não está neste
  arquivo — está só no secret store do Worker (`wrangler secret list`
  mostra o nome, não o valor).
- **Ver o que tem no R2**: `GET /internal/list-assets` com header
  `x-upload-token` (`ASSET_UPLOAD_TOKEN`) — contagem + todas as chaves.
  Usado pra checar lacuna contra o Supabase Storage se precisar (ver
  R2-MIGRATION.md).
- **Dead letter**: depois de 50 tentativas horárias (~2 dias) sem sucesso,
  uma linha para de ser retentada automaticamente — investigar via
  `/internal/status` (aparece em `oldest_pending` com `sync_attempts >= 50`
  se você aumentar o `LIMIT` da consulta, ou direto no D1).
- **Logs do cron**: `wrangler tail zoho-forms-backup` (ou aba Logs no
  dashboard da Cloudflare).
- **Consultar o D1 direto**:
  `wrangler d1 execute zoho-backup --remote --command "SELECT * FROM zoho_submissions ORDER BY received_at DESC LIMIT 20"`

## Desenvolvimento

```bash
cd worker
npm install
npx tsc --noEmit          # type-check
wrangler dev --test-scheduled   # local, com endpoint pra disparar o cron manualmente
wrangler deploy
```

Mudou o schema? `wrangler d1 migrations create zoho-backup <nome>`, edite o
`.sql` gerado, `wrangler d1 migrations apply zoho-backup --remote`.
