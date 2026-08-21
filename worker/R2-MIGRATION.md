# Migração de anexos: Supabase Storage → Cloudflare R2

## Por quê

O Supabase deste projeto é self-hosted, rodando numa VPS com disco
limitado. O bucket `zoho-anexos` já tem **~28,7 GB / 6.180 arquivos** (só
no form `CoberturaPECompleto21`) e o volume previsto não cabe na VPS. Os
anexos migram para um bucket **R2** dedicado — armazenamento object storage
gerenciado pela Cloudflare, sem limite prático de disco local.

## O que já está feito

- **Bucket R2** `zoho-anexos` criado.
- **Domínio público**: `https://assets-pe.centraldeengajamento.com.br`
  (custom domain do R2, TLS mínimo 1.2) — zona `centraldeengajamento.com.br`,
  já usada por outros serviços do projeto (ex.: `referrer_email` dos
  payloads do Zoho).
- **Organização idêntica à do Supabase Storage**: mesma chave plana
  `<form_id>/<file_id>` (confirmado lendo o bucket atual via Storage API,
  não só documentação — ex.: `CoberturaPECompleto21/1--Cc6kULGW0LeJ27wffK5f0HsSrMiFzl`).
  Trocar o domínio na URL pública é suficiente, não precisa reescrever
  nenhum caminho.
- **Todo o histórico já existente foi copiado** (Supabase Storage → R2,
  servidor-a-servidor, via um Worker temporário — ver seção abaixo).
  **Verificado 2026-08-19**: 6.180/6.180 arquivos, 30.833.155.246 bytes —
  contagem e tamanho total do R2 batendo exatamente com o Supabase Storage
  original, mais checagem individual (status/content-type/tamanho) no
  primeiro, meio e último arquivo da lista.

## URL pública — antes/depois

| | Supabase Storage (atual) | R2 (novo) |
| --- | --- | --- |
| padrão | `https://database.tnledu.shop/storage/v1/object/public/zoho-anexos/<form_id>/<file_id>` | `https://assets-pe.centraldeengajamento.com.br/<form_id>/<file_id>` |

## Como a cópia do histórico foi feita

Com 28,7 GB em 6.180 arquivos, baixar e reenviar cada um through minha
própria sessão seria lento e desperdiçaria tempo/banda à toa. Em vez
disso, subi um **Worker temporário e descartável** (`zoho-r2-migrate-temp`,
já removido após a migração — não faz parte do código permanente do
projeto) com um binding de R2 e um endpoint `POST /migrate-batch`: recebe
uma lista de chaves, e pra cada uma faz `fetch` na URL pública do Supabase
Storage e `env.BUCKET.put(key, response.body, ...)` — cópia
servidor-a-servidor dentro da rede da Cloudflare, streaming (sem bufferizar
o arquivo inteiro em memória), sem passar pela minha máquina.

Detalhes técnicos que importam se isso precisar rodar de novo (novo form
com anexos, por exemplo):

- **Idempotente**: cada chamada faz `HEAD` no R2 antes de copiar — se já
  existe, pula (`skipped: true`). Dá pra rodar a lista inteira de novo sem
  duplicar trabalho nem sobrescrever à toa.
- **Limite de conexões simultâneas por invocação do Worker**: um
  `Promise.all` sobre um lote grande direto estourou "Response closed due
  to connection limit". A correção foi um pool de concorrência fixa
  (5 workers internos consumindo uma fila) em vez de disparar tudo de uma
  vez — cabe em qualquer tamanho de lote, só muda o tempo total.
- **Lotes grandes demais falham por inteiro, não parcial**: com lote de 50
  chaves, batches com muitos arquivos genuinamente novos (não só
  `skip`) começaram a falhar 100% (nunca parcial) — sintoma de timeout
  proporcional ao tamanho do lote (a cópia real do arquivo em si sempre
  funcionava — reprocessar o mesmo lote depois mostrava tudo já presente
  via `skip`, ou seja, o trabalho do lado do Worker tinha completado, só a
  resposta HTTP não voltava a tempo). Correção: lote menor (15 chaves) +
  lógica de **dividir ao meio e tentar de novo** quando um lote falha por
  inteiro depois dos retries — se degrada sozinho até um tamanho que
  funciona, em vez de exigir acertar o número certo de antemão.
- **Lotes de 15 chaves por chamada HTTP**, dirigido por um script Node
  (`run_migration.js`, também descartável — não faz parte do repo) que
  pagina a lista completa de arquivos, chama o Worker lote a lote (com o
  split acima em caso de falha), e loga progresso.
- **Idempotência salvou a pele aqui**: interrompi a migração no meio (pra
  investigar as falhas) e reiniciei do zero duas vezes — o `HEAD` antes de
  copiar fez cada reinício pular tudo que já estava certo e só gastar
  tempo com o que realmente faltava.

## Reprocessar / rodar de novo

Se aparecerem mais anexos no Supabase Storage antes do corte definitivo
(novas submissões continuam indo pro caminho antigo até o fluxo n8n ser
migrado — ver abaixo), rode a mesma receita:

1. Listar o bucket via Storage API (`POST /storage/v1/object/list/zoho-anexos`
   com a service role key, paginando por `offset`/`limit`).
2. Subir de novo um Worker temporário nesse mesmo formato (ou reaproveitar,
   se ainda existir) com binding R2 pro bucket `zoho-anexos`.
3. Rodar os lotes — idempotente, então só copia o que faltar.

## Dual-write — 2026-08-19, autorizado e feito

O fluxo principal (`Zoho Forms Ingest (Webhook)`, produção) agora escreve
**nos dois lugares** a cada foto nova: Supabase Storage (como sempre) e R2
(novo). Assim o R2 nunca mais fica pra trás — não precisa de rotina de
sincronização separada, é automático a cada submissão.

**Como**: node novo `Upload photo (R2)`, ligado em paralelo ao `Upload
photo` (Supabase) — ambos recebem o mesmo binário direto do `Download
photo`, então não há risco de um afetar o outro (nenhum dos dois espera
o outro terminar; se um falhar, o outro segue normal). `Upload photo (R2)`
chama `POST /internal/upload-asset?form_id=...&file_id=...` no Worker
(`worker/README.md`), que grava no bucket R2 via binding — não usa
credencial S3, é só um endpoint HTTP autenticado por token, mesmo padrão
dos outros endpoints internos do Worker. `onError: continueRegularOutput`
+ `retryOnFail: true`: uma falha no R2 não derruba a execução nem afeta o
Supabase/Drive (que continuam exatamente como sempre funcionaram).

**Rollout**: aplicado primeiro no fluxo de backup e no paralelo (menor
risco, dá pra testar com tráfego real sem afetar produção), confirmado
funcionando com fotos reais nos dois, só então replicado — usando a
definição **puxada ao vivo do n8n** (não um arquivo local, pra zero risco
de reverter alguma coisa) — no fluxo de produção. Confirmado com submissão
real: mesmo tamanho de arquivo (`7987126` bytes) nos dois lados,
`Upload photo` (Supabase) e `Delete a file` continuam funcionando
exatamente como antes.

**Lacuna fechada**: entre a migração completa do histórico e o dual-write
entrar no ar, ~217 fotos novas foram só pro Supabase Storage (via o
mesmo `/internal/upload-asset`, comparando as duas listagens e copiando só
a diferença). R2 e Supabase Storage estão equivalentes agora, e
permanecem assim automaticamente daqui pra frente.

**O que ainda falta** (decisão pendente, não fiz sozinho): a migration
`migrations/012_zoho_r2_photo_urls.sql` (troca a URL construída em
`zoho_vw_submissions_dashboard` pro domínio do R2) — agora que o dual-write
está ativo, **já é segura de aplicar quando você quiser** (toda foto nova
já existe nos dois lugares, não há mais risco de 404 pra submissão
recente). Só falta você decidir quando trocar o dashboard pra ler do R2 em
vez do Supabase Storage — não depende de mais nenhuma mudança de código.
