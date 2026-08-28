import PostalMime from "postal-mime";
import { extractEvents } from "./extractor";
import { randomToken, sha256Hex } from "./auth";

export interface Env {
  DB: D1Database;
  ADMIN_TOKEN: string;
  ANTHROPIC_API_KEY: string;
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
  const header = (request.headers.get("authorization") ?? "").trim();
  if (header !== `Bearer ${env.ADMIN_TOKEN.trim()}`) {
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

/** Extracts emails still marked pending.
 *
 * ALWAYS run this via `ctx.waitUntil(...)`, never awaited inside a request.
 * An Opus call on a newsletter routinely takes longer than the app's 60s
 * URLSession timeout, so awaiting it in the poll handler produced "Couldn't
 * reach the backend — the request timed out" while the extraction itself was
 * working fine. waitUntil lets the Worker answer immediately and keep
 * extracting after the response is sent.
 *
 * Deliberately best-effort: one email's failure must not affect the others,
 * and anything that doesn't reach 'done' stays pending so a later pass
 * retries it. A missing or invalid API key degrades to "emails arrive with
 * no events yet" rather than losing mail — and the backlog drains itself
 * once the key is fixed.
 *
 * Capped per pass so a large backlog can't exhaust the Worker's time budget;
 * successive passes chew through the rest. */
async function extractPendingEmails(env: Env, householdID: string): Promise<void> {
  if (!env.ANTHROPIC_API_KEY) return;

  // Also reclaims rows stuck in 'processing'. Background work started with
  // waitUntil can be terminated by the platform mid-call, which would
  // otherwise strand an email in 'processing' permanently — no events, no
  // retry, no error anywhere. Anything claimed more than 10 minutes ago is
  // assumed dead and picked back up.
  const staleClaimCutoff = new Date(Date.now() - 10 * 60 * 1000).toISOString();

  const pending = await env.DB.prepare(
    `SELECT id, subject, body_text as bodyText, received_at as receivedAt
     FROM forwarded_emails
     WHERE household_id = ?
       AND (extraction_status = 'pending'
            OR (extraction_status = 'processing' AND (extracted_at IS NULL OR extracted_at < ?)))
     ORDER BY received_at ASC
     LIMIT 3`
  )
    .bind(householdID, staleClaimCutoff)
    .all<{ id: string; subject: string; bodyText: string; receivedAt: string }>();

  for (const email of pending.results ?? []) {
    // Claim the row before doing any work. Extraction now runs in the
    // background from two triggers (mail arrival and each poll), so two
    // passes can overlap and read the same pending set — without this both
    // would extract the same email and insert its events twice. The
    // conditional UPDATE is atomic: exactly one pass sees changes === 1.
    // extracted_at doubles as the claim timestamp so a dead claim can be
    // detected and reclaimed above; on success it's overwritten with the
    // completion time. Read it as "last touched".
    const claim = await env.DB.prepare(
      `UPDATE forwarded_emails SET extraction_status = 'processing', extracted_at = ?
       WHERE id = ?
         AND (extraction_status = 'pending'
              OR (extraction_status = 'processing' AND (extracted_at IS NULL OR extracted_at < ?)))`
    )
      .bind(new Date().toISOString(), email.id, staleClaimCutoff)
      .run();

    if (claim.meta.changes !== 1) continue;

    try {
      const events = await extractEvents(
        env.ANTHROPIC_API_KEY,
        email.subject,
        email.bodyText,
        new Date(email.receivedAt)
      );

      // The inserts and the status flip go in one atomic batch. Done
      // separately, a write that failed between them would leave the email
      // pending *with* its events already saved — and the retry would insert
      // them a second time. Batched, either the email is marked done with its
      // events or nothing landed and the retry is clean.
      const insertEvent = env.DB.prepare(
        `INSERT INTO candidate_events
           (id, forwarded_email_id, household_id, title, start_date, end_date, notes)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      );

      await env.DB.batch([
        ...events.map((event) =>
          insertEvent.bind(
            crypto.randomUUID(),
            email.id,
            householdID,
            event.title,
            event.startDate,
            event.endDate,
            event.notes
          )
        ),
        env.DB.prepare(
          "UPDATE forwarded_emails SET extraction_status = 'done', extracted_at = ? WHERE id = ?"
        ).bind(new Date().toISOString(), email.id),
      ]);
    } catch (error) {
      // Release the claim so a later pass retries this email. Leaving it
      // 'processing' would strand it forever, which is how a transient API
      // error turns into an email that silently never gets its events.
      console.error(`Extraction failed for email ${email.id}:`, error);
      await env.DB.prepare(
        "UPDATE forwarded_emails SET extraction_status = 'pending' WHERE id = ?"
      )
        .bind(email.id)
        .run();
    }
  }
}

/** Everything not yet acknowledged by the app for this household — full
 * emails (for the Emails tab) and the events found in them (for the
 * confirmation screen). Ordered oldest-first so the app can show them
 * in the order they arrived. */
async function handlePending(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const household = await authenticateHousehold(request, env);
  if (!household) return json({ error: "unauthorized" }, 401);

  // Kick off extraction for any stragglers but DON'T wait on it — this
  // response goes back immediately with whatever is already extracted.
  // Anything still processing shows up on the next poll.
  ctx.waitUntil(extractPendingEmails(env, household.id));

  // extractionStatus lets a client tell "this email genuinely had no dates"
  // from "extraction hasn't succeeded yet". Without it both render as an
  // empty event list, which is exactly how a zod version mismatch spent a
  // day looking like a confident "no dates found".
  const emails = await env.DB.prepare(
    `SELECT id, sender, subject, body_text as bodyText, received_at as receivedAt,
            extraction_status as extractionStatus
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
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/v1/households" && request.method === "POST") {
      return handleProvision(request, env);
    }
    if (url.pathname === "/v1/pending" && request.method === "GET") {
      return handlePending(request, env, ctx);
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
  async email(message: ForwardableEmailMessage, env: Env, ctx: ExecutionContext): Promise<void> {
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

    // Store first and let the message be accepted — an LLM call awaited here
    // would put seconds of latency into the handler that decides whether
    // Cloudflare takes the message, and an API outage would start bouncing
    // real school mail.
    await env.DB.prepare(
      `INSERT INTO forwarded_emails (id, household_id, sender, subject, body_text, received_at)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(
        crypto.randomUUID(),
        household.id,
        sender,
        subject || "(no subject)",
        bodyText,
        receivedAt
      )
      .run();

    // Then extract in the background. Mail arrives long before anyone opens
    // the app, so in practice the events are ready and waiting by the time
    // they look — without any request ever blocking on the model.
    ctx.waitUntil(extractPendingEmails(env, household.id));
  },
};
