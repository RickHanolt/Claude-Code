/**
 * Two layers of duplicate suppression, because there are two different
 * duplicate problems and only one of them has a clean answer.
 *
 * Layer 1 — the same email arriving twice. Forwarding one newsletter twice
 * produced two `forwarded_emails` rows, each extracted independently, and the
 * app showed every event twice with subtly different wording (one run wrote
 * "For K-8th grade students", the other "K-8th grade. Free for SMA students").
 * Two independent model calls, so the in-prompt "merge duplicates" rule never
 * had a chance — it only ever sees one email. This layer is exact and free.
 *
 * Layer 2 — the same event described in two different emails. A school sends a
 * newsletter and then a reminder covering the same dates. No hash catches that,
 * so it needs fuzzy matching, which means accepting that it can occasionally be
 * wrong. Deliberately conservative: identical start instant AND high word
 * overlap.
 */

/** Content fingerprint for an inbound email.
 *
 * Forwarded-message headers are stripped before hashing because Gmail stamps
 * the forward with its own `Date:` line — two forwards of one newsletter differ
 * by those bytes and nothing else, which would defeat a naive hash of the raw
 * body. Whatever slips past this is caught by layer 2. */
export function contentFingerprint(subject: string, bodyText: string): string {
  const stripped = bodyText
    .split("\n")
    .filter((line) => !/^\s*(from|to|cc|bcc|date|sent|subject|reply-to)\s*:/i.test(line))
    .filter((line) => !/^\s*-+\s*forwarded message\s*-+\s*$/i.test(line))
    .join("\n");

  return `${normalizeText(subject)}\n${normalizeText(stripped)}`;
}

function normalizeText(value: string): string {
  return value.toLowerCase().replace(/\s+/g, " ").trim();
}

/** Comparable form of an event title: case, punctuation and spacing removed,
 * so "SMA Dads' Social Hour" and "SMA Dads Social Hour" are the same string. */
function titleTokens(title: string): Set<string> {
  return new Set(
    title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .split(" ")
      .filter((word) => word.length > 2)
  );
}

/** Overlap as a fraction of the SHORTER title, not of the union.
 *
 * Jaccard would score "Golf Info Session" against "Golf Info Session in the
 * School Library" as a poor match purely because the second is more specific,
 * which is precisely the pair we want to collapse. Containment handles the
 * "one email is wordier than the other" case that actually occurs here.
 *
 * The obvious risk of containment — "Picture Day" scoring 1.0 against "Picture
 * Day Retakes" — is held off by also requiring the same start instant. Those
 * are different events and never share one. */
function titleOverlap(a: string, b: string): number {
  const left = titleTokens(a);
  const right = titleTokens(b);

  // Titles made entirely of short words ("PE Day") tokenize to nothing;
  // fall back to exact comparison rather than declaring everything a match.
  if (left.size === 0 || right.size === 0) {
    return normalizeText(a) === normalizeText(b) ? 1 : 0;
  }

  let shared = 0;
  for (const word of left) if (right.has(word)) shared += 1;
  return shared / Math.min(left.size, right.size);
}

/** How much of the shorter title must be shared before two same-day events are
 * treated as one. High enough that "Picture Day" and "Pizza Day" (zero overlap)
 * stay separate, low enough that a reminder email's rewording still collapses. */
const TITLE_OVERLAP_THRESHOLD = 0.75;

/** Two events are candidates for merging only if they start at the same
 * moment — not merely on the same day.
 *
 * Same-day was the first cut and it was wrong. A real newsletter listed a
 * father-son event at 8:00 AM for grades 1-4 and 9:00 AM for grades 5-7, and a
 * clinic at 10:00 AM and 11:00 AM on the same day. Those are separate sessions
 * a parent has to be at; day-granularity matching would have collapsed each
 * pair into one and silently dropped a session from the calendar.
 *
 * Comparing to second precision rather than by string equality because rows
 * written before date normalization carry milliseconds (`...00.000Z`) while
 * newer ones don't — the same instant in two spellings.
 *
 * The cost of the tighter key: a reminder email that states a time the original
 * newsletter left off won't merge with it. That's a visible duplicate, which is
 * the failure worth having. */
function instantKey(isoDate: string): string {
  return isoDate.slice(0, 19);
}

export interface ExistingEvent {
  title: string;
  startDate: string;
}

/** True when `candidate` describes an event already recorded for this
 * household — same calendar day, and titles that overlap enough to be the
 * same thing said twice. */
export function isDuplicateEvent(
  candidate: { title: string; startDate: string },
  existing: ExistingEvent[]
): boolean {
  const instant = instantKey(candidate.startDate);

  return existing.some(
    (other) =>
      instantKey(other.startDate) === instant &&
      titleOverlap(candidate.title, other.title) >= TITLE_OVERLAP_THRESHOLD
  );
}

/** Collapses duplicates within a single list, keeping the first of each group.
 *
 * Used on the way out of /v1/pending as well as on the way in, because the rows
 * already in the database predate this matching and can't be repaired by SQL —
 * the duplicate pairs differ in wording, and SQLite has no fuzzy comparison.
 * Filtering on read fixes what's already queued without deleting anything, so a
 * matching mistake hides a row rather than destroying it. */
export function collapseDuplicates<T extends { title: string; startDate: string }>(
  events: T[]
): T[] {
  const kept: T[] = [];

  for (const event of events) {
    if (isDuplicateEvent(event, kept)) continue;
    kept.push(event);
  }

  return kept;
}
