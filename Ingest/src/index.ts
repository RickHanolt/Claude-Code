import PostalMime from "postal-mime";
import { extractCandidateEvents } from "./dateParser";
import { randomToken, sha256Hex } from "./auth";

export interface Env {
  DB: D1Database;
  ADMIN_TOKEN: string;
  INGEST_DOMAIN?: string;
}

interface Household {
  id: string;
  name: string;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
}

/** Resolves the household that owns an API key from its `Authorization:
 * Bearer <key>` header. Every /v1/pending and /v1/ack call is scoped to
 * this household — one family can never see another's data. */
async function authenticateHousehold(request: Request, env: Env): Promise<Household | null> {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;

  const hash = await sha256Hex(match[1]);
  const row = await env.DB.prepare("SELECT id, name FROM households WHERE api_key_hash = ?")
    .bind(hash)
    .first<Household>();
  return row ?? null;
}

/** Creates a new household + ingest address + API key. Admin-only (this
 * app has no self-serve signup — it's provisioned once per family by
 * whoever runs the backend, via a single curl call documented in
 * INGEST_BACKEND.md). The API key is returned exactly once; only its hash
 * is ever persisted. */
async function handleProvision(request: Request, env: Env): Promise<Response> {
  if (request.headers.get("authorization") !== `Bearer ${env.ADMIN_TOKEN}`) {
    return json({ error: "unauthorized" }, 401);
  }

  const body = await request.json<{ name?: string }>().catch(() => ({}) as { name?: string });
  const name = (body.name ?? "Household").trim() || "Household";

  const slugBase = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-+|-+$)/g, "") || "family";
  const ingestSlug = `${slugBase}-${randomToken(3)}`;
  const apiKey = randomToken(24);

  await env.DB.prepare(
    "INSERT INTO households (id, name, ingest_slug, api_key_hash, created_at) VALUES (?, ?, ?, ?, ?)"
  )
    .bind(crypto.randomUUID(), name, ingestSlug, await sha256Hex(apiKey), new Date().toISOString())
    .run();

  return json({
    ingestAddress: `${ingestSlug}@${env.INGEST_DOMAIN ?? "mail.yourdomain.com"}`,
    apiKey,
  });
}

/** Everything not yet acknowledged by the app for this household — full
 * emails (for the Emails tab) and the date candidates found in them (for
 * the confirmation screen). Ordered oldest-first so the app can show them
 * in the order they arrived. */
async function handlePending(request: Request, env: Env): Promise<Response> {
  const household = await authenticateHousehold(request, env);
  if (!household) return json({ error: "unauthorized" }, 401);

  const emails = await env.DB.prepare(
    `SELECT id, sender, subject, body_text as bodyText, received_at as receivedAt
     FROM forwarded_emails WHERE household_id = ? AND consumed_at IS NULL
     ORDER BY received_at ASC`
  )
    .bind(household.id)
    .all();

  const events = await env.DB.prepare(
    `SELECT id, forwarded_email_id as forwardedEmailId, title, start_date as startDate,
            end_date as endDate, notes
     FROM candidate_events WHERE household_id = ? AND consumed_at IS NULL
     ORDER BY start_date ASC`
  )
    .bind(household.id)
    .all();

  return json({ emails: emails.results, events: events.results });
}

/** Marks emails/events as consumed once the app has pulled them into its
 * local store, so they aren't returned again on the next poll. */
async function handleAck(request: Request, env: Env): Promise<Response> {
  const household = await authenticateHousehold(request, env);
  if (!household) return json({ error: "unauthorized" }, 401);

  const body = await request
    .json<{ emailIds?: string[]; eventIds?: string[] }>()
    .catch(() => ({}) as { emailIds?: string[]; eventIds?: string[] });
  const now = new Date().toISOString();

  for (const id of body.emailIds ?? []) {
    await env.DB.prepare("UPDATE forwarded_emails SET consumed_at = ? WHERE id = ? AND household_id = ?")
      .bind(now, id, household.id)
      .run();
  }
  for (const id of body.eventIds ?? []) {
    await env.DB.prepare("UPDATE candidate_events SET consumed_at = ? WHERE id = ? AND household_id = ?")
      .bind(now, id, household.id)
      .run();
  }

  return json({ ok: true });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/households" && request.method === "POST") {
      return handleProvision(request, env);
    }
    if (url.pathname === "/v1/pending" && request.method === "GET") {
      return handlePending(request, env);
    }
    if (url.pathname === "/v1/ack" && request.method === "POST") {
      return handleAck(request, env);
    }
    return json({ error: "not found" }, 404);
  },

  /** Cloudflare Email Routing invokes this for every message sent to an
   * address on the ingest domain (wired up in the dashboard, not here —
   * see INGEST_BACKEND.md). Unknown recipients are rejected outright so
   * this can't become an open relay for storing arbitrary mail. */
  async email(message: ForwardableEmailMessage, env: Env): Promise<void> {
    const slug = (message.to ?? "").split("@")[0]?.toLowerCase() ?? "";

    const household = await env.DB.prepare("SELECT id FROM households WHERE ingest_slug = ?")
      .bind(slug)
      .first<{ id: string }>();

    if (!household) {
      message.setReject("Unknown recipient");
      return;
    }

    const parsed = await new PostalMime().parse(message.raw);
    const subject = (parsed.subject ?? "").trim();
    const bodyText = (parsed.text ?? stripHtml(parsed.html ?? "")).trim();
    const sender = parsed.from?.address ?? message.from ?? "";
    const receivedAt = new Date().toISOString();

    const emailId = crypto.randomUUID();
    await env.DB.prepare(
      `INSERT INTO forwarded_emails (id, household_id, sender, subject, body_text, received_at)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(emailId, household.id, sender, subject || "(no subject)", bodyText, receivedAt)
      .run();

    const candidates = extractCandidateEvents(subject, bodyText, new Date());
    for (const candidate of candidates) {
      await env.DB.prepare(
        `INSERT INTO candidate_events
           (id, forwarded_email_id, household_id, title, start_date, end_date, notes)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
        .bind(
          crypto.randomUUID(),
          emailId,
          household.id,
          candidate.title,
          candidate.startDate,
          candidate.endDate,
          candidate.notes
        )
        .run();
    }
  },
};
