import PostalMime from "postal-mime";
import { extractEvents } from "./extractor";
import { randomToken, sha256Hex } from "./auth";
import { collapseDuplicates, contentFingerprint, isDuplicateEvent, type ExistingEvent } from "./dedupe";
import { selectAttachment, type StoredAttachment } from "./attachments";
import { DEFAULT_TIMEZONE } from "./timezone";

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

/** How many times one email may be handed to the model before we stop paying
 * to retry it. Counted at claim time, so a pass killed mid-call counts too.
 * Three is enough to ride out a rate limit or a deploy, and small enough that
 * a deterministically-failing email costs three calls, not one per poll
 * forever. */
const MAX_EXTRACTION_ATTEMPTS = 3;

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

  // The school's zone decides what "3:00 p.m." in an email means. Read once
  // per pass rather than per email — it can't change mid-pass.
  const household = await env.DB.prepare("SELECT timezone FROM households WHERE id = ?")
    .bind(householdID)
    .first<{ timezone: string }>();
  const timeZone = household?.timezone || DEFAULT_TIMEZONE;

  const pending = await env.DB.prepare(
    `SELECT id, subject, body_text as bodyText, received_at as receivedAt
     FROM forwarded_emails
     WHERE household_id = ?
       AND extraction_attempts < ?
       AND (extraction_status = 'pending'
            OR (extraction_status = 'processing' AND (extracted_at IS NULL OR extracted_at < ?)))
     ORDER BY received_at ASC
     LIMIT 3`
  )
    .bind(householdID, MAX_EXTRACTION_ATTEMPTS, staleClaimCutoff)
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
      `UPDATE forwarded_emails
       SET extraction_status = 'processing',
           extracted_at = ?,
           extraction_attempts = extraction_attempts + 1
       WHERE id = ?
         AND extraction_attempts < ?
         AND (extraction_status = 'pending'
              OR (extraction_status = 'processing' AND (extracted_at IS NULL OR extracted_at < ?)))`
    )
      .bind(new Date().toISOString(), email.id, MAX_EXTRACTION_ATTEMPTS, staleClaimCutoff)
      .run();

    if (claim.meta.changes !== 1) continue;

    try {
      const attachments = await env.DB.prepare(
        `SELECT filename, media_type as mediaType, data FROM email_attachments
         WHERE forwarded_email_id = ?`
      )
        .bind(email.id)
        .all<StoredAttachment>();

      const events = await extractEvents(
        env.ANTHROPIC_API_KEY,
        email.subject,
        email.bodyText,
        new Date(email.receivedAt),
        attachments.results ?? [],
        timeZone
      );

      // Drop events this household already has. Two emails can describe the
      // same event — a newsletter and the reminder that follows it — and each
      // is extracted on its own, so the prompt's "merge duplicates" rule never
      // sees both. Matching is by calendar day plus title overlap; see
      // dedupe.ts for why containment rather than Jaccard.
      //
      // Consumed events count as existing. If it's already on the calendar,
      // offering it again is the same annoyance as showing it twice here.
      const existing = await env.DB.prepare(
        `SELECT title, start_date as startDate FROM candidate_events
         WHERE household_id = ? AND start_date >= ? AND start_date <= ?`
      )
        .bind(
          householdID,
          // Bounded by calendar day, not by the exact timestamps. Rows written
          // before date normalization carry milliseconds (`...00.000Z`), and
          // "." sorts BELOW "Z", so an exact-timestamp range would silently
          // exclude a boundary row from the comparison it exists to be part of.
          `${events.reduce((min, e) => (e.startDate < min ? e.startDate : min), "9999").slice(0, 10)}T00:00:00`,
          `${events.reduce((max, e) => (e.startDate > max ? e.startDate : max), "0000").slice(0, 10)}T99`
        )
        .all<ExistingEvent>();

      const seen: ExistingEvent[] = [...(existing.results ?? [])];
      const fresh = [];

      for (const event of events) {
        // `seen` grows as we go, so a duplicate *within* one extraction is
        // caught too — belt and braces behind the prompt rule.
        if (isDuplicateEvent(event, seen)) {
          console.log(`Skipping duplicate event: ${event.title} on ${event.startDate.slice(0, 10)}`);
          continue;
        }
        seen.push({ title: event.title, startDate: event.startDate });
        fresh.push(event);
      }

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
        ...fresh.map((event) =>
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
          `UPDATE forwarded_emails
           SET extraction_status = 'done', extracted_at = ?, extraction_error = NULL
           WHERE id = ?`
        ).bind(new Date().toISOString(), email.id),
      ]);
    } catch (error) {
      // Release the claim so a later pass retries this email. Leaving it
      // 'processing' would strand it forever, which is how a transient API
      // error turns into an email that silently never gets its events.
      //
      // Once the attempt cap is reached the row goes to 'failed' instead and
      // stops being retried. The email itself is still returned by /v1/pending
      // — nothing is lost, it just arrives without events — and 'failed' says
      // so explicitly rather than looking like "no dates in this one".
      // Record the reason ON THE ROW, not only in a log stream. An extraction
      // that fails silently is indistinguishable from an email with no dates
      // in it, and working out which took a comparison of failure timestamps
      // against deploy timestamps. The message is truncated because an API
      // error can carry a full request echo, and the first line is the part
      // that identifies the problem.
      const reason = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
      console.error(`Extraction failed for email ${email.id}:`, error);

      await env.DB.prepare(
        `UPDATE forwarded_emails
         SET extraction_status = CASE WHEN extraction_attempts >= ? THEN 'failed' ELSE 'pending' END,
             extraction_error = ?
         WHERE id = ?`
      )
        .bind(MAX_EXTRACTION_ATTEMPTS, reason.slice(0, 500), email.id)
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

  // Collapse duplicates on the way out as well as on the way in. The rows
  // already queued were written before any of this matching existed and can't
  // be repaired by SQL — the duplicate pairs differ in wording (two extraction
  // runs over one newsletter produced "Free for SMA students. Coach Craig
  // Madzinski." and "Coach Craig Madzinski. Free for SMA students."), and
  // SQLite has no fuzzy comparison. Filtering here fixes what's queued without
  // deleting anything, so a matching mistake hides a row rather than losing it.
  const events_ = (events.results ?? []) as Array<{ title: string; startDate: string }>;

  return json({ emails: emails.results, events: collapseDuplicates(events_) });
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

    // base64 is what the Messages API takes, so ask postal-mime for it
    // directly rather than converting an ArrayBuffer by hand — one less place
    // to corrupt bytes.
    const parsed = await new PostalMime({ attachmentEncoding: "base64" }).parse(message.raw);
    const subject = (parsed.subject ?? "").trim();
    const bodyText = (parsed.text ?? stripHtml(parsed.html ?? "")).trim();
    const sender = parsed.from?.address ?? message.from ?? "";
    const receivedAt = new Date().toISOString();

    // Forwarding one newsletter twice previously produced two rows, two model
    // calls, and every event twice in the app. Accept the message either way —
    // the mail was delivered correctly and bouncing it would be wrong — but
    // don't store or extract a second copy.
    const attachments = (parsed.attachments ?? [])
      .map(selectAttachment)
      .filter((item): item is StoredAttachment => item !== null);

    const contentHash = await sha256Hex(contentFingerprint(subject, bodyText, attachments));

    const alreadyStored = await env.DB.prepare(
      "SELECT id FROM forwarded_emails WHERE household_id = ? AND content_hash = ?"
    )
      .bind(household.id, contentHash)
      .first<{ id: string }>();

    if (alreadyStored) {
      console.log(`Ignoring duplicate forward of "${subject}" (matches ${alreadyStored.id}).`);
      return;
    }

    // Store first and let the message be accepted — an LLM call awaited here
    // would put seconds of latency into the handler that decides whether
    // Cloudflare takes the message, and an API outage would start bouncing
    // real school mail.
    const emailID = crypto.randomUUID();

    // The email and its attachments land in one batch. Split apart, a failure
    // between them would leave an email that looks fully stored but extracts
    // without the calendar that was the whole point of forwarding it.
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO forwarded_emails
           (id, household_id, sender, subject, body_text, received_at, content_hash)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).bind(
        emailID,
        household.id,
        sender,
        subject || "(no subject)",
        bodyText,
        receivedAt,
        contentHash
      ),
      ...attachments.map((attachment) =>
        env.DB.prepare(
          `INSERT INTO email_attachments
             (id, forwarded_email_id, household_id, filename, media_type, data, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`
        ).bind(
          crypto.randomUUID(),
          emailID,
          household.id,
          attachment.filename,
          attachment.mediaType,
          attachment.data,
          receivedAt
        )
      ),
    ]);

    if (attachments.length > 0) {
      console.log(`Stored ${attachments.length} attachment(s) for "${subject}".`);
    }

    // Then extract in the background. Mail arrives long before anyone opens
    // the app, so in practice the events are ready and waiting by the time
    // they look — without any request ever blocking on the model.
    ctx.waitUntil(extractPendingEmails(env, household.id));
  },
};
