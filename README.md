# Pipeline Zoho Forms → Supabase

Pipeline reutilizável de ingestão de submissões do Zoho Forms para o Supabase.
Adicionar um form novo é **configuração** (uma linha na tabela `zoho_form_registry`), não código.

## Fluxo

```
Zoho Forms (submissão)
      │
      └──▶ Webhook n8n (fonte primária)
                  │
                  ▼
      zoho_raw_submissions  (bruto, jsonb, imutável)
      insert ... on conflict (zoho_submission_id) do nothing
                  │
                  ▼
      RPC zoho_ingest_submission  (aplica mapeamento + valida, atômico)
                  │
                  ▼
      zoho_submissions_normalized  (jsonb com chaves padronizadas)
                  │
                  ▼
      zoho_vw_submissions_core  (dashboard consome SÓ as views)

Reconciliação de perdas: manual, via "Repush" no Zoho Forms (ver abaixo).
```

> **Nota:** a ideia original de polling via Zoho Forms API não foi possível —
> o endpoint `getRecords` do Zoho Forms foi descontinuado. A reconciliação é
> feita manualmente via "Repush" (re-envio do webhook no Zoho Forms).

Toda a normalização (etapa B) roda dentro de uma **RPC Postgres** (`SECURITY DEFINER`),
em uma única transação: grava o raw, aplica o `mapeamento`, valida e grava no
normalized (ou em `zoho_ingestion_errors`). O n8n só chama a RPC.

## Instalação

1. Rode no SQL Editor do Supabase, nesta ordem:
   - `migrations/001_zoho_schema.sql` — tabelas + view + índices + RLS
   - `migrations/002_zoho_ingest_rpc.sql` — RPCs de ingestão e de watermark
   - `migrations/004_zoho_form_config.sql` — colunas `required` e `file_fields`
   - `migrations/005_zoho_anon_read.sql` — SELECT anon no registry (pro n8n ler `file_fields`)
   - `migrations/006_zoho_dashboard_view.sql` — view `zoho_vw_submissions_dashboard` (núcleo + `data_completa` + `foto_urls`)
2. Cadastre os forms existentes em `migrations/003_zoho_seed_registry.sql` (preencha os dados reais).
3. Importe os workflows no n8n (Menu → Import from File):
   - `n8n/zoho-ingest-webhook.json`
4. Nos nós `HTTP Request` que usam a credential `Supabase account`, **re-selecione a credential**
   do seu n8n (o ID gravado é da instância atual — troque pelo seu).

## Onboarding de um form novo

Adicionar um form novo = **configuração no Zoho** + **1 INSERT no registry**. Nenhum código.

### Passos no Zoho Forms

1. **Pegue o `form_link_name`** — Form Properties → campo **"Link Name"** (ou a URL de
   compartilhamento: `https://forms.zoho.com/<org>/form/<form_link_name>`).
2. **Ative o webhook** — **Integrações → Webhooks** → nova notificação:
   - **URL**: `https://webhookn8n.tnledu.shop/webhook/zoho-forms-ingest?form_id=<form_link_name>`
   - **Método**: POST · **Formato**: JSON.
   - Em **Payload Parameters**, selecione/mapeie os campos que vão no payload. A chave
     do JSON é o *field link name* de cada campo — o mesmo nome que você usa no `mapeamento`.
3. **Anexos (se o form tiver upload)**: Settings → Submissions & Storage →
   **Manage Form Attachments → Google Drive**. Se o form já empurra anexos para o
   Google Sheets, remova de lá antes (anexo só vai para uma integração por vez).

### Passos no Supabase

```sql
INSERT INTO zoho_form_registry (form_id, nome, form_family, mapeamento) VALUES
(
  'cadastro_campo_2026',
  'Cadastro de Campo',
  'cadastro_campo',
  '{
    "nome":      {"campo": "nome", "transform": "concat", "with": "sobrenome"},
    "telefone":  {"campo": "telefone", "transform": "only_digits"},
    "Cidade":    "localizacao",
    "GPS_Lat":   {"campo": "latitude", "transform": "to_float"},
    "GPS_Long":  {"campo": "longitude", "transform": "to_float"}
  }'::jsonb
);
```

### Teste

Submeta uma entrada de teste e confira:
- no n8n, o `Ingest (RPC)` retornando `ok` (ou `error_*`, veja Métricas);
- no Supabase, a linha em `zoho_submissions_normalized` (ou `zoho_ingestion_errors`);
- se tiver foto, o arquivo no bucket `zoho-anexos/<form_id>/<file_id>`.

### Mapeamento (`mapeamento`)

| sintaxe | efeito |
| --- | --- |
| `"Campo_Zoho": "chave"` | de-para direto |
| `"Campo_Zoho": {"campo": "chave", "transform": "only_digits"}` | de-para + transform |
| `"Campo_Zoho": {"campo": "chave", "transform": "concat", "with": "Outro_Campo"}` | concatena dois campos (opcional `"separator"`, default espaço) |

Transforms disponíveis: `only_digits`, `to_float`, `to_int`, `trim`, `lower`, `upper`, `concat`.
Campos do payload fora do mapeamento viram **extras** dentro de `data` (visíveis em `data_completa`).
Validação: os campos obrigatórios vêm da coluna `required` (ver abaixo).

### `required` (campos obrigatórios)

Coluna `required` (jsonb) = lista de chaves **padronizadas** (pós-mapeamento) que
são obrigatórias. Default `["nome","telefone"]`.

- Form que **não capta nome** e tem telefone opcional → `required = '[]'::jsonb` (aceita tudo).
- Ou exija só o que fizer sentido: `'["latitude","longitude"]'::jsonb`.

```sql
INSERT INTO zoho_form_registry (form_id, nome, form_family, mapeamento, required, file_fields) VALUES
(
  'CoberturaPECompleto21',
  'Cobertura PE',
  'cobertura_pe',
  '{
    "submitters_latitude":  {"campo": "latitude", "transform": "to_float"},
    "submitters_longitude": {"campo": "longitude", "transform": "to_float"},
    "submitters_location":  "localizacao"
  }'::jsonb,
  '[]'::jsonb,              -- aceita tudo
  '["foto_casa"]'::jsonb    -- campo de upload
);
```

### `file_fields` (anexos / fotos)

Coluna `file_fields` (jsonb) = campos do payload que são **uploads de arquivo**.
Com o "Manage Form Attachments → Google Drive" ativo, o webhook manda a **URL do
Drive** (ex.: `["https://drive.google.com/file/d/<FILE_ID>/view?usp=drivesdk"]`).

Para salvar o arquivo no Supabase Storage:

1. Crie o bucket **`zoho-anexos`** (Supabase → Storage → New bucket; recomendado público).
2. No Zoho Forms, por form: **Settings → Submissions & Storage → Manage Form Attachments → Google Drive**
   (remove antes os anexos do Google Sheets, se houver — anexo só vai para uma integração por vez).
3. Liste os campos de upload em `file_fields`.

O workflow do webhook então: extrai o `file_id` da URL do Drive → baixa o arquivo
pelo id → envia para o bucket em `zoho-anexos/<form_id>/<file_id>`. O caminho é
determinístico, então um "Repush" sobrescreve o mesmo arquivo (idempotente).

A URL pública da foto é derivável a partir do `file_id` + `form_id`:

```
https://database.tnledu.shop/storage/v1/object/public/zoho-anexos/<form_id>/<file_id>
```

### Como achar o `form_id` (form_link_name)

O `form_id` do registry é o **`form_link_name`** do form no Zoho (identificador do form), não o "Form ID" numérico.

1. No Zoho Forms, abra o form → **Form Properties** → campo **"Link Name"**.
   (Ou olhe a URL de compartilhamento: `https://forms.zoho.com/<org>/form/<form_link_name>`.)
2. Esse mesmo valor é o que você usa:
   - como `form_id` no `INSERT` do registry;
   - no `?form_id=` da URL do webhook.

## Gerenciando forms

O histórico é **imutável**: `zoho_raw_submissions` guarda o payload original para
sempre, e o `data` (jsonb) de cada submissão não é alterado. Mudar um form afeta
apenas as **novas** submissões — a config (`mapeamento`, `required`, `file_fields`)
define o futuro; o passado só muda com reprocessamento explícito.

### O que cada mudança implica

| mudança | config a ajustar | efeito nas novas submissões | histórico |
| --- | --- | --- | --- |
| adicionar campo | nenhuma (vira extra) ou `mapeamento` p/ tipar | entra como extra no `data` | intacto |
| deletar campo | remover de `required`/`file_fields`/`mapeamento` | some do payload; se estava em `required` → `error_invalid` até remover | intacto |
| renomear campo (link name) | atualizar `mapeamento`/`file_fields` | chave nova no payload | fica com a chave antiga |
| mudar `required` | editar coluna `required` | validação das próximas muda | intacto |
| mudar `mapeamento` (de-para/transform) | editar coluna `mapeamento` | aplicado nas próximas | re-aplique via `zoho_reprocess_form` se quiser retroagir |
| mudar `file_fields` | editar coluna `file_fields` | ramo de fotos das próximas muda | ⚠️ ver limitações abaixo |

### Perdeu submissões?

Use o **Repush** no Zoho (seção "Reconciliação"): reenvia o webhook e a idempotência
ingere só o que faltou.

### Corrigindo o passado

Para re-aplicar um `mapeamento` corrigido sobre dados já gravados, rode
`zoho_reprocess_form('<form_id>')` (ver seção "Reprocessamento").

### Limitações conhecidas

1. **Chave de dedup**: derivada de `email_id|nome|sobrenome|telefone|added_time`.
   Para forms **sem** esses campos (ex.: só geolocalização), degenera para
   `md5(added_time)` — risco de colisão e de duplicar ao fazer Repush depois de
   mudar um campo do núcleo.
2. **`foto_urls` usa o `file_fields` atual**: a view `zoho_vw_submissions_dashboard`
   cruza o `data` com o `file_fields` de hoje. Remover um campo de arquivo do
   `file_fields` faz os anexos históricos daquele campo sumirem da view (continuam
   no bucket e no `data_completa`).

## Webhook (A1)

- URL: `https://<seu-n8n>/webhook/zoho-forms-ingest?form_id=<form_link_name>`
- O `?form_id=<form_link_name>` é o que identifica o form (o webhook do Zoho não envia o ID nativo da submissão).
- **Chave de idempotência**: como o webhook não carrega o `zoho_submission_id`, a RPC
  `zoho_ingest_submission` **deriva** a chave de forma determinística a partir de campos comuns
  (`email_id`, `nome`, `sobrenome`, `telefone`, `added_time`). O "Repush" reenvia o mesmo
  payload, então gera a mesma chave — o que já entrou vira `duplicate`, sem duplicidade.
- `submitted_at` é lido de `Added_Time` (formato `DD-Mon-YYYY HH:MM:SS`) e convertido para ISO.
- O node `Ingest (RPC)` tem `retryOnFail` + `onError: continueErrorOutput` (falha transitória
  do Supabase é retentada e não descarta a execução silenciosamente).

## Reconciliação (repush manual)

O polling via Zoho Forms API **não é possível** (o `getRecords` foi descontinuado).
Para cobrir eventuais perdas do webhook (falha no envio do Zoho ou no n8n), a
reconciliação é feita **manualmente** pelo "Repush" do Zoho Forms:

1. No Zoho Forms, abra o form → **All Entries** (todas as entradas).
2. Filtre as submissões com falha (ou o período que deseja conferir).
3. Selecione as entradas → **Repush** (re-envia o webhook para elas).
4. O webhook re-roteia → n8n → `zoho_ingest_submission`.
5. A idempotência resolve o resto: como a chave é derivada dos campos, o que já
   tinha entrado vira `duplicate` (ignorado) e o que faltou é ingerido agora.

Esse repush é o substituto do polling: sem duplicidade e sem código novo.

### Alternativas futuras (automação)

- **Import de CSV**: exportar as entradas em CSV e importar pela mesma RPC
  `zoho_ingest_submission` (padrão já usado no projeto `supabase-chega-junto`).
- **Zoho Analytics API**: as submissões vivem no Zoho Analytics; a API dele
  (`analyticsapi.zoho.com`) lê a tabela do form programaticamente.

## Métricas / observabilidade

- `ok` → novo, normalizado agora.
- `duplicate` → já existia (repush/submissão repetida, sem efeito).
- `error_*` → caiu em `zoho_ingestion_errors` (ex.: form não cadastrado, núcleo ausente).

Falhas de HTTP são retentadas e ficam no log de execução do n8n. A perda Zoho→n8n
não é mensurável sem uma segunda fonte — por isso o repush manual é a rede de segurança.

## Reprocessamento (correção de mapeamento)

`zoho_raw_submissions` é imutável e completo. Para corrigir um mapeamento errado:

1. Corrija o `mapeamento` do form no registry.
2. Reprocesse as linhas que falharam (ou todas do form), via RPCs dedicadas:

```sql
-- Reprocessa uma submissão específica:
SELECT zoho_reprocess_raw('<raw_submission_id>');

-- Reprocessa todas as submissões de um form (ex.: corrigiu o mapeamento):
SELECT zoho_reprocess_form('cadastro_campo_2026');
```

As RPCs de reprocessamento apagam o resultado anterior (normalized/erros) e
re-aplicam o mapeamento corrente a partir do raw imutável — nada se perde.

## Dashboard

O dashboard lê **somente as views**, nunca `zoho_raw_submissions` ou o `jsonb` direto:
- `zoho_vw_submissions_core` — núcleo comum (`nome`, `telefone`, `localizacao`, `latitude`, `longitude`) + `data_completa`.
- `zoho_vw_submissions_dashboard` — all-in-one: núcleo tipado + `data_completa` (extras) + `foto_urls` (array de URLs públicas das fotos). Uma linha por submissão; o botão de fotos abre `foto_urls`.
- Views por família: crie `zoho_vw_<familia>` filtrando por `form_family`/`form_id` e extraindo chaves extras tipadas.

Para **criar um dashboard** (consumir os dados, inspecionar o jsonb, explicar o form pra IA): veja [DASHBOARD.md](./DASHBOARD.md).

## Evolução

- **Alto volume / views pesadas**: troque a view por uma materialized view com refresh agendado
  (n8n cron ou `pg_cron`). A troca é transparente para o dashboard, que já lê a view pelo nome.
- **Novos transforms**: adicione um `WHEN` no `CASE` de `zoho_transform_value` (002).
