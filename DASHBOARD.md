# Criando um dashboard (consumindo os dados da pipeline)

Guia para quem constrói um dashboard sobre um form captado pelo Zoho. Aqui você
aprende a inspecionar os dados, entender os campos (principalmente os que ficam em
jsonb) e explicar a estrutura do form para uma IA.

## Modelo de dados

```
payload do webhook (chaves cruas = field link names)
   → mapeamento (registry) → data (jsonb: chaves padronizadas + extras)
   → views (core / dashboard / família) → dashboard
```

O `data` (jsonb) de cada submissão em `zoho_submissions_normalized` mistura dois
tipos de chave:

- **padronizadas** (vindas do `mapeamento`): `nome`, `telefone`, `localizacao`,
  `latitude`, `longitude`;
- **extras** (tudo que NÃO está no `mapeamento`): os *field link names* crus do form.

## Passo a passo de um dashboard novo

1. **Garanta que o form está no pipeline** — webhook no Zoho (`?form_id=`) + linha no
   `zoho_form_registry` (ver `README.md` → "Onboarding de um form novo").
2. **Inspecione os dados** — use os SQLs abaixo para ver as chaves e os valores reais.
3. **Defina a view** que o dashboard vai ler: a genérica já cobre a maioria; crie uma
   de família se precisar de colunas tipadas para extras.
4. **Construa o dashboard apontando SÓ para a view** — nunca para as tabelas raw/normalized.

## Como explicar o form para a IA

O artefato mais eficiente é **um payload real do webhook** + o **`mapeamento`**. Cole
estes 4 itens e a IA enxerga tudo:

1. **Payload de exemplo** (1 submissão real) — revela os *field link names* exatos,
   os tipos (string vs array) e valores de exemplo.
2. **`mapeamento`** (do registry) — mostra o de-para e quais campos viram chaves padronizadas.
3. **`required`** e **`file_fields`** — o que é obrigatório e o que é upload.
4. **Uma frase de negócio** — o que o form capta e o que o dashboard deve mostrar.

Exemplo do que colar:

```
Form: Cobertura PE (form_id = CoberturaPECompleto21)
mapeamento: {
  "submitters_latitude":  {"campo":"latitude","transform":"to_float"},
  "submitters_longitude": {"campo":"longitude","transform":"to_float"},
  "submitters_location":  "localizacao"
}
required: []   file_fields: ["foto_casa"]

payload: {
  "telefone_whatsapp": "",
  "submitters_longitude": "-35.7106433",
  "added_time": "14-Aug-2026 14:44:18",
  "entrou_comunidade": "false",
  "foto_casa": ["https://drive.google.com/file/d/<ID>/view"],
  "tipo_acao": "Porta a porta",
  "submitters_latitude": "-9.6275361",
  "submitters_location": "Rua Selma Bandeira, ...",
  "de_quem_casa": "💛 João"
}
```

## SQLs de inspeção

```sql
-- a) confirmar o form e ver a config
SELECT form_id, mapeamento, required, file_fields
FROM zoho_form_registry WHERE form_id = 'CoberturaPECompleto21';

-- b) listar TODAS as chaves que já existem no `data`
SELECT DISTINCT jsonb_object_keys(data) AS key
FROM zoho_submissions_normalized
WHERE form_id = 'CoberturaPECompleto21';

-- c) ver 1 linha "bonita" (jsonb_pretty)
SELECT id, submitted_at, jsonb_pretty(data) AS data
FROM zoho_submissions_normalized
WHERE form_id = 'CoberturaPECompleto21'
ORDER BY submitted_at DESC LIMIT 1;

-- d) o payload bruto original (JSON exato do webhook)
SELECT jsonb_pretty(payload) FROM zoho_raw_submissions
WHERE form_id = 'CoberturaPECompleto21' LIMIT 1;

-- e) consultar direto pela view do dashboard
SELECT * FROM zoho_vw_submissions_dashboard
WHERE form_id = 'CoberturaPECompleto21' LIMIT 10;
```

## Views disponíveis

- **`zoho_vw_submissions_core`** — núcleo comum (`nome`, `telefone`, `localizacao`,
  `latitude`, `longitude`, `form_id`, `submitted_at`) + `data_completa`. Cobre a
  maioria dos dashboards.
- **`zoho_vw_submissions_dashboard`** — all-in-one: núcleo tipado + `data_completa`
  (todos os extras) + `foto_urls` (array de URLs públicas das fotos). Uma linha por
  submissão; o botão de fotos abre `foto_urls`.
- **View de família** (`zoho_vw_<familia>`) — quando um extra merece coluna tipada
  (ex.: `tipo_acao`, `municipio`). Crie filtrando por `form_family`/`form_id` e
  extraindo as chaves do `data`. Exemplo:

```sql
CREATE OR REPLACE VIEW zoho_vw_cobertura_pe AS
SELECT
  id, raw_submission_id, form_id, submitted_at,
  data->>'localizacao' AS localizacao,
  (data->>'latitude')::float  AS latitude,
  (data->>'longitude')::float AS longitude,
  data->>'tipo_acao'    AS tipo_acao,
  data->>'municipio'    AS municipio,
  data->>'de_quem_casa' AS de_quem_casa,
  data                  AS data_completa
FROM zoho_submissions_normalized
WHERE form_id = 'CoberturaPECompleto21';
```

> **Identificador estável:** ambas as views expõem **`raw_submission_id`**. Use ele
> (não `id`) para referenciar uma submissão de forma duradoura — anotações, edições,
> de-para com a sua ferramenta. `raw_submission_id` é o id imutável do
> `zoho_raw_submissions` (não muda no Repush nem no reprocessamento). Para cruzar
> com um export do Zoho, use a chave natural `submitted_at` + `latitude` +
> `longitude` (+ `referrer_email`, quando houver).

## Nota sobre o `data_completa`

Na view, `data_completa` é o jsonb inteiro da submissão. No frontend, acesse qualquer
extra como objeto (ex.: `data_completa.tipo_acao`); via PostgREST, `data_completa->>'tipo_acao'`.
