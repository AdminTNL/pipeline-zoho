export interface ZohoPayload {
  [key: string]: unknown;
}

function pick(payload: ZohoPayload, keys: string[]): string {
  for (const key of keys) {
    const value = payload[key];
    if (value !== undefined && value !== null && value !== "") {
      return String(value);
    }
  }
  return "";
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Mesma composição de campos da RPC `zoho_derive_submission_id`
// (migrations/002_zoho_ingest_rpc.sql, no repo raiz), mas hasheada com
// SHA-256 em vez de MD5 (o Web Crypto do Worker não tem MD5). Não precisa
// bater byte-a-byte com o hash do Postgres — só precisa ser estável entre
// os dois escritores do D1 (webhook do Zoho e callback de mark-synced do
// n8n), que usam esta mesma função.
export async function deriveDedupKey(payload: ZohoPayload): Promise<string> {
  const composite = [
    pick(payload, ["email_id", "Email_ID", "Email"]),
    pick(payload, ["nome", "Nome"]),
    pick(payload, ["sobrenome", "Sobrenome"]),
    pick(payload, ["telefone", "Telefone"]),
    pick(payload, ["added_time", "Added_Time", "ADDED_TIME"]),
  ].join("|");

  const trimmed = composite.replace(/^\|+|\|+$/g, "");
  const source = trimmed === "" ? JSON.stringify(payload ?? {}) : composite;
  return sha256Hex(source);
}

const MONTHS: Record<string, number> = {
  Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
  Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11,
};

// Mesmo parser do node "Extract submission" em n8n/zoho-ingest-webhook.json.
export function parseZohoDate(value: unknown): string | null {
  if (!value) return null;
  const match = String(value).match(/(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})/);
  if (!match) return null;
  const [, day, mon, year, hour, min, sec] = match;
  const month = MONTHS[mon];
  if (month === undefined) return null;
  return new Date(Date.UTC(+year, month, +day, +hour, +min, +sec)).toISOString();
}
