import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";
import { attachmentBlocks, type StoredAttachment } from "./attachments";
import { DEFAULT_TIMEZONE, offsetLabel, zonedTimeToUTC } from "./timezone";

/**
 * Replaces the previous `chrono-node` date-detector heuristic (`dateParser.ts`).
 *
 * That approach hit its ceiling: run against a real school newsletter it
 * produced 22 candidates from one email — five near-duplicates of the same
 * bulleted list, mid-sentence fragment titles, and two entries dated 2014/2015
 * because a comma-separated day list ("Sept. 9, 14, 16") read as a two-digit
 * year. Each individual bug was fixable; the supply of them was not, because
 * pattern-matching can't tell a publication date from an event date, or notice
 * that two paragraphs describe the same thing.
 *
 * The output shape deliberately mirrors the existing `candidate_events` table
 * and the app's `PendingCandidateEvent` — this swap changes extraction quality
 * without touching the `/v1/pending` contract the app already consumes. An
 * all-day event is expressed the way the app already reads it: a null endDate.
 */
const ExtractedEvent = z.object({
  title: z
    .string()
    .describe(
      "The event name a parent would recognize, e.g. 'Fall Picture Day'. Never a sentence fragment or the email subject."
    ),
  startDate: z
    .string()
    .describe(
      "ISO 8601. Use YYYY-MM-DD for an all-day event, or YYYY-MM-DDTHH:MM:SS when the email states a time."
    ),
  endDate: z
    .string()
    .nullable()
    .describe(
      "ISO 8601 end time (YYYY-MM-DDTHH:MM:SS), or null for an all-day or open-ended event."
    ),
  notes: z
    .string()
    .nullable()
    .describe("Location and any detail worth keeping. Null if there is none."),
});

/** Exported so `scripts/schema-check.ts` can assert this actually converts to
 * JSON Schema. That check exists because a zod major-version mismatch is
 * invisible to `tsc` — the helper's types were satisfied by zod 3 while
 * `betaZodOutputFormat` called `z.toJSONSchema()`, a zod 4 API, and threw at
 * runtime on every extraction. Typecheck-green, production-broken. */
export const Extraction = z.object({
  events: z.array(ExtractedEvent),
});

export type ExtractedEvent = z.infer<typeof ExtractedEvent>;

/** Reference date is the moment the email arrived, so "next Tuesday" and
 * bare month/day pairs resolve against the right year — the wrong-year bug
 * the old parser produced came from having no such anchor. */
function buildPrompt(
  subject: string,
  bodyText: string,
  receivedAt: Date,
  timeZone: string
): string {
  const received = receivedAt.toISOString().slice(0, 10);
  const offset = offsetLabel(timeZone, receivedAt);

  return `You are extracting calendar events from an email a school sent to a parent.

The email arrived on ${received}. Resolve every relative or partial date against that — a bare "Sept. 9" means the September following that date, never a different year.

Subject: ${subject || "(no subject)"}

Body:
${bodyText}

Rules:
- One entry per real event. If the same event appears in both a summary list and a detail paragraph, that is ONE entry, not two.
- A list of dates for a recurring activity ("Sept. 9, 14, 16") is one entry per date — those are genuinely separate sessions.
- Ignore forwarded-message headers ("From:", "Date:", "Sent from my iPhone") and publication or "posted on" metadata. Those are not events.
- Ignore anything without a specific day. A heading like "September Schedule:" is not an event.
- Title the event as a parent would say it. Do not use the email subject as a title, and do not copy a fragment of surrounding text.
- Every clock time in a school email is local time in ${timeZone} (currently UTC${offset}). Attach that offset to every time you emit, e.g. a 3:00 p.m. practice is 2026-08-24T15:00:00${offset}. Never emit a time with no offset.
- Set a time only when the email gives one; otherwise leave endDate null so it reads as all-day.
- Put location and useful detail in notes. Null if there is nothing worth keeping.
- If the email contains no real dated events, return an empty list. That is a valid and common answer.
- Any attached calendars, flyers or schedules are part of this email. Read every date in them, not just the ones repeated in the body — a year-at-a-glance calendar listing sixty dates should produce sixty entries.
- A date range in an attachment ("3/25-4/2 Easter Break", "23-27 Thanksgiving Break") is ONE entry spanning it, not one per day.
- An attachment may state a month and year only in a column or section heading. Apply that heading to every date beneath it.
- An entry with no resolvable date ("Talent Show (TBD)") is not an event. Skip it.`;
}

/** A forwarded newsletter routinely arrives twice over (the original plus the
 * forward) and carries entity noise from the HTML strip in `index.ts`. None of
 * that adds information, but all of it is billed as input tokens, so it gets
 * cleaned before the call.
 *
 * The character cap is a cost fuse, not a quality decision: anything past it is
 * a digest or a long reply chain, and truncating is a better failure mode than
 * an unbounded bill. */
const MAX_BODY_CHARS = 60_000;

function prepareBody(bodyText: string): string {
  const cleaned = bodyText
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&quot;/gi, '"')
    .replace(/[ \t\u00a0]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  if (cleaned.length <= MAX_BODY_CHARS) return cleaned;

  console.warn(`Email body truncated from ${cleaned.length} to ${MAX_BODY_CHARS} chars before extraction.`);
  return cleaned.slice(0, MAX_BODY_CHARS);
}

/** Extended thinking is switched OFF, explicitly.
 *
 * It was briefly capped at a 2000-token budget instead, to bound the cost of
 * the adaptive default. That change correlates exactly with extraction
 * breaking: every email received before it deployed extracted cleanly, and
 * every one after failed all three attempts. `thinking` is the only parameter
 * that changed, and it had never run against the live API — I could not test
 * it from the build environment and shipped it anyway.
 *
 * Disabling rather than removing the parameter: omitting it lets Opus 5 reason
 * adaptively, billed as output tokens with only max_tokens as a ceiling, which
 * is what turned a ~$0.02 estimate into $1.40. Off is both the cheap answer and
 * the one that removes the parameter combination under suspicion.
 *
 * Extraction here is a structured read of text that is already explicit —
 * finding the dates a newsletter states outright. The prompt rules carry the
 * judgement calls. If quality drops measurably without reasoning, a bounded
 * budget can come back, but only after a live call proves the API accepts it.
 */
const MAX_TOKENS_TEXT_ONLY = 8000;
const MAX_TOKENS_WITH_ATTACHMENTS = 16000;

/** Rewrites whatever ISO-8601 shape the model produced into the one strict
 * form the app can actually decode.
 *
 * The iOS client decodes with `JSONDecoder.dateDecodingStrategy = .iso8601`,
 * which is `ISO8601DateFormatter` in `.withInternetDateTime` mode: it requires
 * a time AND an explicit offset. The previous `chrono-node` parser only ever
 * emitted `date.toISOString()`, so this never came up — then the schema here
 * told the model "include a time only if the email states one", it duly
 * returned a bare `2026-09-09` for an all-day event, and the app failed the
 * whole response with "The data couldn't be read because it isn't in the
 * correct format." A loosened producer against an unchanged strict consumer.
 *
 * Two shapes get repaired:
 *
 * - Date-only (`2026-09-09`) is anchored at **noon** UTC, not midnight. Naive
 *   midnight renders as the *previous day* in every negative-offset timezone,
 *   so an all-day event on the 9th would show up on the 8th here. Noon is also
 *   what chrono produced for a date with no stated time (its implied hour),
 *   so this preserves the behavior that was already working rather than
 *   inventing one.
 * - A datetime with no offset (`2026-09-09T09:00:00`) is read as UTC, again
 *   matching what the old parser did in this Worker.
 *
 * KNOWN LIMITATION, inherited rather than introduced: a stated clock time is
 * the school's local time, and nothing here knows what timezone that is, so
 * "9:00 AM" is stored as 09:00Z and displays shifted. Fixing it properly means
 * storing a timezone per household — that belongs with the per-kid settings
 * work, not in a crash fix.
 *
 * Returns null for anything unparseable; the caller drops those events rather
 * than storing a value that will break decoding again downstream. */
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;
const NAIVE_DATETIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?$/;

export function normalizeISODate(
  value: string | null,
  timeZone: string = DEFAULT_TIMEZONE
): string | null {
  if (value === null) return null;

  const trimmed = value.trim();
  if (!trimmed) return null;

  // Both repairs resolve in the school's zone, not UTC.
  //
  // Naive datetime: the email said "3:00 p.m." and meant 3pm where the school
  // is. Reading that as UTC is what put cross-country practice on the calendar
  // five hours early.
  //
  // Date-only: anchored at local noon. Noon UTC was the old rule and it kept
  // the right calendar day in the Americas only by luck of the offset's sign;
  // local noon keeps it in every zone, which starts mattering the moment a
  // household is provisioned somewhere else.
  if (DATE_ONLY.test(trimmed)) {
    const noon = zonedTimeToUTC(trimmed + "T12:00:00", timeZone);
    return noon ? formatInstant(noon) : null;
  }

  if (NAIVE_DATETIME.test(trimmed)) {
    const withSeconds = trimmed.length === 16 ? trimmed + ":00" : trimmed;
    const resolved = zonedTimeToUTC(withSeconds, timeZone);
    return resolved ? formatInstant(resolved) : null;
  }

  const parsed = new Date(trimmed);
  if (Number.isNaN(parsed.getTime())) return null;

  return formatInstant(parsed);
}

/** Milliseconds are dropped deliberately. `.withInternetDateTime`, the mode the
 * app's decoder uses, rejects fractional seconds unless `.withFractionalSeconds`
 * is also set. Recent Foundation is lenient about it — the emails' received_at
 * carries `.000Z` and decodes fine today — but "works because the platform is
 * currently forgiving" is not a property worth depending on, and this form is
 * canonical RFC 3339 either way. */
function formatInstant(instant: Date): string {
  return instant.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/**
 * Throws on API failure rather than returning empty — the caller distinguishes
 * "the model found nothing" (a legitimate empty list, common for a newsletter
 * with no dates) from "we never got an answer", and only the latter should
 * leave the email queued for another attempt.
 */
export async function extractEvents(
  apiKey: string,
  subject: string,
  bodyText: string,
  receivedAt: Date = new Date(),
  attachments: StoredAttachment[] = [],
  timeZone: string = DEFAULT_TIMEZONE
): Promise<ExtractedEvent[]> {
  // maxRetries is explicit because the SDK's default of 2 sits *inside* an
  // outer retry: a failed extraction releases the row back to pending and a
  // later pass tries it again. Left at the default, one consistently bad email
  // could bill three model calls per pass.
  const client = new Anthropic({ apiKey, maxRetries: 1 });

  // Text first, then each attachment. The prompt has to precede the images for
  // its date-resolution rules to apply to what the model reads in them.
  const content = [
    { type: "text" as const, text: buildPrompt(subject, prepareBody(bodyText), receivedAt, timeZone) },
    ...attachments.flatMap(attachmentBlocks),
  ];

  const message = await client.beta.messages.parse({
    model: "claude-opus-5",
    max_tokens: attachments.length > 0 ? MAX_TOKENS_WITH_ATTACHMENTS : MAX_TOKENS_TEXT_ONLY,
    thinking: { type: "disabled" },
    messages: [{ role: "user", content }],
    output_format: betaZodOutputFormat(Extraction),
  });

  // Logged on every call so cost is something we measure in `wrangler tail`
  // rather than estimate. The absence of this number is why a 60x overrun was
  // only visible on the billing page.
  console.log(
    `Extraction usage: input=${message.usage.input_tokens} output=${message.usage.output_tokens} ` +
      `stop=${message.stop_reason} attachments=${attachments.length} subject="${subject.slice(0, 60)}"`
  );

  // `parsed_output` is null when the response didn't satisfy the schema.
  // Treating that as a failure (not an empty result) keeps the email queued
  // for retry rather than silently recording zero events.
  if (!message.parsed_output) {
    throw new Error(`Extraction returned no parseable output (stop_reason: ${message.stop_reason})`);
  }

  // Normalize before anything is stored. Doing it here rather than at the
  // insert keeps the invariant with the schema it belongs to: everything this
  // function returns is decodable by the app.
  const normalized: ExtractedEvent[] = [];

  for (const event of message.parsed_output.events) {
    const startDate = normalizeISODate(event.startDate, timeZone);

    if (!startDate) {
      console.warn(`Dropping event with unparseable startDate: ${JSON.stringify(event.startDate)}`);
      continue;
    }

    normalized.push({ ...event, startDate, endDate: normalizeISODate(event.endDate, timeZone) });
  }

  return normalized;
}
