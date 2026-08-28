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
 * wrong. Deliberately conservative: same calendar day AND high word overlap.
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
 * Day Retakes" — is contained by requiring the same calendar day as well.
 * Those are genuinely different events, and they're never on the same day. */
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

function dayKey(isoDate: string): string {
  return isoDate.slice(0, 10);
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
  const day = dayKey(candidate.startDate);

  return existing.some(
    (other) =>
      dayKey(other.startDate) === day &&
      titleOverlap(candidate.title, other.title) >= TITLE_OVERLAP_THRESHOLD
  );
}
