import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";

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
    .describe("ISO 8601. Include a time only if the email states one."),
  endDate: z
    .string()
    .nullable()
    .describe("ISO 8601 end time, or null for an all-day or open-ended event."),
  notes: z
    .string()
    .nullable()
    .describe("Location and any detail worth keeping. Null if there is none."),
});

const Extraction = z.object({
  events: z.array(ExtractedEvent),
});

export type ExtractedEvent = z.infer<typeof ExtractedEvent>;

/** Reference date is the moment the email arrived, so "next Tuesday" and
 * bare month/day pairs resolve against the right year — the wrong-year bug
 * the old parser produced came from having no such anchor. */
function buildPrompt(subject: string, bodyText: string, receivedAt: Date): string {
  const received = receivedAt.toISOString().slice(0, 10);

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
- Set a time only when the email gives one; otherwise leave endDate null so it reads as all-day.
- Put location and useful detail in notes. Null if there is nothing worth keeping.
- If the email contains no real dated events, return an empty list. That is a valid and common answer.`;
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
  receivedAt: Date = new Date()
): Promise<ExtractedEvent[]> {
  const client = new Anthropic({ apiKey });

  const message = await client.beta.messages.parse({
    model: "claude-opus-5",
    max_tokens: 16000,
    messages: [{ role: "user", content: buildPrompt(subject, bodyText, receivedAt) }],
    output_format: betaZodOutputFormat(Extraction),
  });

  // `parsed_output` is null when the response didn't satisfy the schema.
  // Treating that as a failure (not an empty result) keeps the email queued
  // for retry rather than silently recording zero events.
  if (!message.parsed_output) {
    throw new Error("Extraction returned no parseable output");
  }

  return message.parsed_output.events;
}
