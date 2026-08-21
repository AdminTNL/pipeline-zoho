import { deriveDedupKey, parseZohoDate, type ZohoPayload } from "./dedup";
import { insertPending, markSynced, markSyncedByKey, markAttemptFailure, getPendingBatch, getStatus, isSynced } from "./db";

export interface Env {
  DB: D1Database;
  PHOTOS: R2Bucket;
  ZOHO_BACKUP_TOKEN: string;
  INGEST_CALLBACK_TOKEN: string;
  N8N_BACKUP_TOKEN: string;
  ASSET_UPLOAD_TOKEN: string;
  CHECK_SYNCED_TOKEN: string;
  N8N_BACKUP_URL: string;
  N8N_INGEST_URL: string;
}

const MAX_ASSET_BYTES = 50 * 1024 * 1024; // 50MB — generoso pra foto de celular, protege contra corpo absurdo
const MAX_BODY_BYTES = 256 * 1024;
const CRON_BATCH_SIZE = 200;
const CRON_CONCURRENCY = 5;
// ~2 dias de tentativas horárias antes de virar "dead letter" (ver getPendingBatch em db.ts).

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

async function readJsonBody(request: Request): Promise<ZohoPayload | null> {
  const contentLength = request.headers.get("content-length");
  if (contentLength && Number(contentLength) > MAX_BODY_BYTES) return null;
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return null;
  try {
    return JSON.parse(text) as ZohoPayload;
  } catch {
    return null;
  }
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Zoho só aceita 1 webhook por form — o Worker é o único destino e repassa
// pro n8n de ingestão. Best-effort: se o repasse falhar (n8n fora do ar), a
// linha já gravada no D1 com synced=false é pega pelo cron horário depois —
// não perde nada, só atrasa.
async function forwardToN8n(env: Env, formId: string, payload: ZohoPayload): Promise<void> {
  try {
    await fetch(`${env.N8N_INGEST_URL}?form_id=${encodeURIComponent(formId)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch {
    // best-effort — o cron horário é a rede de segurança de verdade
  }
}

async function handleZohoWebhook(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const url = new URL(request.url);
  const token = url.searchParams.get("token") ?? "";
  if (!env.ZOHO_BACKUP_TOKEN || !timingSafeEqual(token, env.ZOHO_BACKUP_TOKEN)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const formId = url.searchParams.get("form_id");
  if (!formId) return json({ ok: false, error: "missing_form_id" }, 400);

  const payload = await readJsonBody(request);
  if (!payload) return json({ ok: false, error: "invalid_body" }, 400);

  const submittedAt = parseZohoDate(payload["Added_Time"] ?? payload["added_time"]);
  const dedupKey = await deriveDedupKey(payload);

  await insertPending(env.DB, dedupKey, formId, payload, submittedAt);
  ctx.waitUntil(forwardToN8n(env, formId, payload));

  return json({ ok: true });
}

async function handleMarkSynced(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const token = request.headers.get("x-internal-token") ?? "";
  if (!env.INGEST_CALLBACK_TOKEN || !timingSafeEqual(token, env.INGEST_CALLBACK_TOKEN)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const body = await readJsonBody(request);
  if (!body || typeof body.form_id !== "string" || typeof body.payload !== "object" || body.payload === null) {
    return json({ ok: false, error: "invalid_body" }, 400);
  }

  const payload = body.payload as ZohoPayload;
  const formId = body.form_id;
  const submittedAt =
    (typeof body.submitted_at === "string" ? body.submitted_at : null) ??
    parseZohoDate(payload["Added_Time"] ?? payload["added_time"]);
  const execId = typeof body.exec_id === "string" ? body.exec_id : null;
  const flowId = typeof body.flow_id === "string" ? body.flow_id : null;
  const dedupKey = await deriveDedupKey(payload);

  await markSynced(env.DB, dedupKey, formId, payload, submittedAt, execId, flowId);

  return json({ ok: true });
}

// Check antecipado: cada fluxo n8n chama isso logo após extrair a
// submissão, ANTES de chamar a RPC ou baixar foto — se já synced=1, para
// ali (evita baixar/subir a mesma foto duas vezes quando o outro fluxo já
// terminou). Falha aberta por design: erro/timeout aqui não deve travar
// processamento real, então quem chama trata qualquer coisa != synced:true
// como "segue o fluxo normal".
async function handleCheckSynced(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const token = request.headers.get("x-internal-token") ?? "";
  if (!env.CHECK_SYNCED_TOKEN || !timingSafeEqual(token, env.CHECK_SYNCED_TOKEN)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const body = await readJsonBody(request);
  if (!body || typeof body.payload !== "object" || body.payload === null) {
    return json({ ok: false, error: "invalid_body" }, 400);
  }

  const payload = body.payload as ZohoPayload;
  const dedupKey = await deriveDedupKey(payload);
  const synced = await isSynced(env.DB, dedupKey);

  return json({ ok: true, synced });
}

// Dual-write de anexos: o fluxo n8n (produção/paralelo/backup) manda o
// binário do Drive pra cá além de mandar pro Supabase Storage — assim o R2
// fica em dia sozinho, sem precisar de uma rotina de sincronização à parte.
// Mesma chave `<form_id>/<file_id>` usada no Supabase Storage.
async function handleUploadAsset(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  const token = request.headers.get("x-upload-token") ?? "";
  if (!env.ASSET_UPLOAD_TOKEN || !timingSafeEqual(token, env.ASSET_UPLOAD_TOKEN)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const url = new URL(request.url);
  const formId = url.searchParams.get("form_id");
  const fileId = url.searchParams.get("file_id");
  if (!formId || !fileId) return json({ ok: false, error: "missing_form_id_or_file_id" }, 400);

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_ASSET_BYTES) return json({ ok: false, error: "payload_too_large" }, 413);
  if (!request.body) return json({ ok: false, error: "empty_body" }, 400);

  const key = `${formId}/${fileId}`;
  await env.PHOTOS.put(key, request.body, {
    httpMetadata: {
      contentType: request.headers.get("content-type") || "application/octet-stream",
    },
  });

  return json({ ok: true, key });
}

// Diagnóstico: lista as chaves hoje no R2 (pra checar lacuna contra o
// Supabase Storage — ex. depois de um período sem dual-write). Não é
// usado no fluxo normal.
async function handleListAssets(request: Request, env: Env): Promise<Response> {
  const token = request.headers.get("x-upload-token") ?? "";
  if (!env.ASSET_UPLOAD_TOKEN || !timingSafeEqual(token, env.ASSET_UPLOAD_TOKEN)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }
  const keys: string[] = [];
  let cursor: string | undefined;
  do {
    const listing = await env.PHOTOS.list({ cursor, limit: 1000 });
    for (const o of listing.objects) keys.push(o.key);
    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);
  return json({ ok: true, count: keys.length, keys });
}

async function handleStatus(request: Request, env: Env): Promise<Response> {
  const token = request.headers.get("x-internal-token") ?? "";
  if (!env.INGEST_CALLBACK_TOKEN || !timingSafeEqual(token, env.INGEST_CALLBACK_TOKEN)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }
  const status = await getStatus(env.DB);
  return json({ ok: true, ...status });
}

async function processPending(env: Env): Promise<{ synced: number; failed: number }> {
  const rows = await getPendingBatch(env.DB, CRON_BATCH_SIZE);
  let synced = 0;
  let failed = 0;

  for (let i = 0; i < rows.length; i += CRON_CONCURRENCY) {
    const chunk = rows.slice(i, i + CRON_CONCURRENCY);
    const outcomes = await Promise.all(
      chunk.map(async (row) => {
        try {
          const payload = JSON.parse(row.payload) as ZohoPayload;
          const res = await fetch(env.N8N_BACKUP_URL, {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-backup-token": env.N8N_BACKUP_TOKEN,
            },
            body: JSON.stringify({ form_id: row.form_id, payload }),
          });

          let ok = res.ok;
          let data: Record<string, unknown> = {};
          if (ok) {
            data = (await res.json().catch(() => ({}))) as Record<string, unknown>;
            if (data.ok === false) ok = false;
          }

          if (ok) {
            const execId = typeof data.exec_id === "string" ? data.exec_id : null;
            const flowId = typeof data.flow_id === "string" ? data.flow_id : null;
            await markSyncedByKey(env.DB, row.dedup_key, execId, flowId);
            return true;
          }
          await markAttemptFailure(env.DB, row.dedup_key, `http_${res.status}`);
          return false;
        } catch (err) {
          await markAttemptFailure(env.DB, row.dedup_key, (err as Error).message);
          return false;
        }
      })
    );
    synced += outcomes.filter(Boolean).length;
    failed += outcomes.filter((v) => !v).length;
  }

  return { synced, failed };
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/zoho-forms-backup") return handleZohoWebhook(request, env, ctx);
    if (url.pathname === "/internal/mark-synced") return handleMarkSynced(request, env);
    if (url.pathname === "/internal/check-synced") return handleCheckSynced(request, env);
    if (url.pathname === "/internal/status") return handleStatus(request, env);
    if (url.pathname === "/internal/upload-asset") return handleUploadAsset(request, env);
    if (url.pathname === "/internal/list-assets") return handleListAssets(request, env);
    return json({ ok: false, error: "not_found" }, 404);
  },

  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      processPending(env).then(({ synced, failed }) => {
        console.log(`[zoho-backup-cron] synced=${synced} failed=${failed}`);
      })
    );
  },
};
