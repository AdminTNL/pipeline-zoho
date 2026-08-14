
# Spec: Arquitetura Escalável de Ingestão de Zoho Forms → Supabase

## 1. Objetivo

Criar uma pipeline **reutilizável** para integrar qualquer novo Zoho Form ao Supabase sem construir uma automação nova a cada form. Adicionar um form novo deve ser **configuração** (uma linha em uma tabela), não código novo.

Contexto: forms de captação de campo (modo offline), frequência recorrente, formatos variam de form para form mas compartilham um núcleo comum de campos: `nome`, `telefone`, `localização`, `latitude`, `longitude`.

**Convenção de nomenclatura:** todas as tabelas e views desta pipeline usam o prefixo `zoho_`, para diferenciá-las de outras tabelas do banco usadas para outros propósitos.

## 2. Visão geral do fluxo

```
Zoho Forms (submissão)
      │
      ├──▶ Webhook n8n (rápido, mas não garante entrega)
      │
      └──▶ Polling agendado via Zoho Forms API (reconciliação, confiável)
                  │
                  ▼
      zoho_raw_submissions  (bruto, jsonb, imutável — auditoria/replay)
      insert ... on conflict (zoho_submission_id) do nothing
                  │
                  ▼
Code node n8n: lê zoho_form_registry → aplica mapeamento
                  │
                  ▼
      zoho_submissions_normalized  (jsonb com chaves padronizadas)
                  │
                  ▼
      Views SQL (por form ou por "família de form")
                  │
                  ▼
      Dashboard (consome só as views, nunca o jsonb bruto)
```

## 3. Schema Supabase

### 3.1 `zoho_form_registry`

Cadastro de cada form conhecido. É a peça central — adicionar form novo = inserir uma linha aqui.

| coluna             | tipo        | descrição                                                                                       |
| ------------------ | ----------- | ------------------------------------------------------------------------------------------------- |
| `form_id`        | text (PK)   | ID/`form_link_name` do Zoho Forms                                                               |
| `nome`           | text        | nome amigável do form                                                                            |
| `form_family`    | text        | agrupamento lógico (forms recriados periodicamente com o mesmo shape caem na mesma família)     |
| `mapeamento`     | jsonb       | de-para: campo Zoho → campo padronizado, com transform opcional                                  |
| `ativo`          | boolean     | permite desativar sem apagar histórico                                                           |
| `last_synced_at` | timestamptz | watermark: última submissão reconciliada pelo polling, evita reprocessar tudo a cada execução |
| `created_at`     | timestamptz |                                                                                                   |

Exemplo de `mapeamento`:

```json
{
  "Nome_Completo": "nome",
  "Telefone_Contato": {"campo": "telefone", "transform": "only_digits"},
  "Cidade": "localizacao",
  "GPS_Lat": {"campo": "latitude", "transform": "to_float"},
  "GPS_Long": {"campo": "longitude", "transform": "to_float"}
}
```

### 3.2 `zoho_raw_submissions`

Baú imutável. Nunca é lido pelo dashboard.

| coluna                 | tipo                                                                                                 |
| ---------------------- | ---------------------------------------------------------------------------------------------------- |
| `id`                 | uuid (PK)                                                                                            |
| `form_id`            | text (FK → zoho_form_registry)                                                                      |
| `zoho_submission_id` | text (UNIQUE) — ID nativo da submissão no Zoho, usado como chave de idempotência                  |
| `payload`            | jsonb                                                                                                |
| `source`             | text —`'webhook'` ou `'polling'`, útil para medir quantas submissões o webhook está perdendo |
| `received_at`        | timestamptz                                                                                          |

### 3.3 `zoho_submissions_normalized`

Resultado do mapeamento aplicado ao payload bruto. Chaves padronizadas independente do form de origem.

| coluna                | tipo                                                                                                                                         |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`                | uuid (PK)                                                                                                                                    |
| `raw_submission_id` | uuid (FK → zoho_raw_submissions)                                                                                                            |
| `form_id`           | text (FK → zoho_form_registry)                                                                                                              |
| `submitted_at`      | timestamptz                                                                                                                                  |
| `data`              | jsonb — chaves do núcleo comum (`nome`, `telefone`, `localizacao`, `latitude`, `longitude`) + campos extras específicos do form |

### 3.4 `zoho_ingestion_errors`

Para linhas que falharam validação/mapeamento — permite corrigir o `mapeamento` no registry e reprocessar em lote sem perder dado de campo.

| coluna                | tipo        |
| --------------------- | ----------- |
| `id`                | uuid (PK)   |
| `raw_submission_id` | uuid        |
| `erro`              | text        |
| `created_at`        | timestamptz |
| `resolvido`         | boolean     |

### 3.5 View núcleo comum: `zoho_vw_submissions_core`

Como todo form compartilha nome/telefone/localização/lat/long, uma view base cobre a maioria dos casos de dashboard direto:

```sql
create view zoho_vw_submissions_core as
select
  id,
  form_id,
  submitted_at,
  data->>'nome'        as nome,
  data->>'telefone'    as telefone,
  data->>'localizacao' as localizacao,
  (data->>'latitude')::float  as latitude,
  (data->>'longitude')::float as longitude,
  data as data_completa -- extras específicos do form ficam acessíveis aqui
from zoho_submissions_normalized;
```

Views específicas por família de form (quando um form tem campos extras que valem colunas próprias) seguem o mesmo padrão — nome sugerido `zoho_vw_<familia>` —, filtrando por `form_id`/`form_family` e extraindo chaves adicionais do jsonb.

## 4. Workflow n8n

Dois pontos de entrada convergindo na mesma tabela, mais a etapa de normalização.

**Etapa A1 — Recepção via webhook (rápida, não garantida)**

1. Webhook recebe submissão do Zoho Forms
2. Extrai `form_id` e `zoho_submission_id` do payload
3. Insere em `zoho_raw_submissions` com `source = 'webhook'`, usando `insert ... on conflict (zoho_submission_id) do nothing`

**Etapa A2 — Reconciliação via polling (agendada, confiável)**

1. A cada 15-30 min, para cada `form_id` ativo em `zoho_form_registry`, consulta a Zoho Forms API (`Get Records`) por submissões mais novas que `last_synced_at`
2. Insere em `zoho_raw_submissions` com `source = 'polling'`, mesmo `on conflict do nothing` (submissões que o webhook já trouxe são ignoradas)
3. Atualiza `last_synced_at` do form
4. Loga quantas linhas foram "recuperadas" nessa execução — se esse número for consistentemente alto, é sinal de que o webhook está falhando com frequência acima do normal

**Etapa B — Normalização (genérica, parametrizada, dispara após A1 ou A2)**

1. Code node busca a linha correspondente em `zoho_form_registry` pelo `form_id`
2. Aplica o `mapeamento` (de-para + transforms: `to_int`, `to_float`, `only_digits`, etc.) sobre o payload bruto
3. Valida o resultado (schema mínimo esperado: núcleo comum presente)
   - Se válido → insere em `zoho_submissions_normalized`
   - Se inválido → insere em `zoho_ingestion_errors` com o motivo
4. Se `form_id` não existir em `zoho_form_registry` → cai automaticamente em `zoho_ingestion_errors`, sinalizando "form novo não cadastrado" — vira o alerta natural de "preciso cadastrar esse form"

## 5. Processo de onboarding de um form novo

1. Form novo é publicado no Zoho Forms
2. Insere-se uma linha em `zoho_form_registry` com o `mapeamento` de-para
3. Nenhuma alteração de código/workflow é necessária — a próxima submissão já é processada corretamente
4. Se o form tiver campos além do núcleo comum que mereçam colunas próprias no dashboard, cria-se (ou estende-se) uma view específica

## 6. Estratégia de evolução

- **Baixo/médio volume**: views comuns (leitura em tempo real, zero manutenção)
- **Alto volume / views pesadas**: trocar por materialized views com refresh agendado (n8n cron ou `pg_cron`) — troca é transparente para o dashboard, que já lê a view pelo nome
- **Reprocessamento**: como `zoho_raw_submissions` é imutável e completo, qualquer erro de mapeamento é corrigível retroativamente sem perda de dado — corrige o `mapeamento`, roda um job que reprocessa as linhas de `zoho_ingestion_errors` (ou todas as `zoho_raw_submissions` de um form, se necessário)

## 7. Próximos passos de implementação

- [ ] Criar as 4 tabelas no Supabase com prefixo `zoho_` (`zoho_form_registry`, `zoho_raw_submissions`, `zoho_submissions_normalized`, `zoho_ingestion_errors`)
- [ ] Criar a constraint única `zoho_submission_id` em `zoho_raw_submissions`
- [ ] Criar a view `zoho_vw_submissions_core`
- [ ] Construir o workflow n8n: webhook (A1) + polling agendado (A2) + Code node de mapeamento/validação (B)
- [ ] Cadastrar os forms já existentes em `zoho_form_registry` com seus mapeamentos
- [ ] Conectar o dashboard às views (não às tabelas normalized/raw)
