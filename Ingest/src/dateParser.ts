import * as chrono from "chrono-node";

/**
 * Server-side port of `Shared/Services/EmailParserService.swift`'s
 * heuristic: scan the body for dates and surface each hit as a candidate
 * event titled after the subject, for the app to show for review — this
 * never auto-saves anything.
 *
 * Matches landing on the same calendar day as `referenceDate` (the moment
 * the email arrived) are suppressed by default, same trade-off as the
 * on-device version: these are almost always a templated newsletter's
 * "posted on" metadata rather than a real same-day event, so we favor
 * fewer false positives over catching genuine same-day notices.
 */
export interface CandidateEvent {
  title: string;
  startDate: string;
  endDate: string | null;
  notes: string | null;
}

export function extractCandidateEvents(
  subject: string,
  bodyText: string,
  referenceDate: Date = new Date()
): CandidateEvent[] {
  const results = chrono.parse(bodyText, referenceDate);
  const seenStarts = new Set<number>();
  const candidates: CandidateEvent[] = [];

  for (const result of results) {
    // A bare month reference with no day number ("September Schedule:")
    // gets a defaulted day from chrono rather than a real one — confirmed
    // live: "September Schedule:" parsed as September 1st, landing a
    // nonexistent event on the calendar. isCertain("day") is false exactly
    // when the day was inferred rather than present in the text.
    if (!result.start.isCertain("day")) continue;

    const date = result.start.date();
    if (isSameCalendarDay(date, referenceDate)) continue;

    const startMs = date.getTime();
    if (seenStarts.has(startMs)) continue;
    seenStarts.add(startMs);

    const endDate = result.end ? result.end.date() : null;
    const notes = surroundingSnippet(bodyText, result.index, result.text.length);
    const trimmedSubject = subject.trim();
    const fallbackTitle = trimmedSubject.length ? trimmedSubject : "Forwarded event";

    candidates.push({
      title: eventTitle(notes, fallbackTitle),
      startDate: date.toISOString(),
      endDate: endDate ? endDate.toISOString() : null,
      notes,
    });
  }

  return candidates;
}

/**
 * A single email often contains several distinct dates (a newsletter
 * listing multiple events, say) — reusing the email subject as every
 * candidate's title made them all show up identically in the calendar.
 * The surrounding-text snippet is a much better per-event label when one's
 * available; the subject is only a fallback for a match with no usable
 * context. Mirrors `eventTitle` in the Swift version.
 */
function eventTitle(snippet: string | null, fallback: string): string {
  if (!snippet) return fallback;
  const limit = 60;
  if (snippet.length <= limit) return snippet;

  const truncated = snippet.slice(0, limit);
  const spaceIdx = truncated.lastIndexOf(" ");
  const trimmed = spaceIdx === -1 ? truncated : truncated.slice(0, spaceIdx);
  return `${trimmed}…`;
}

function isSameCalendarDay(a: Date, b: Date): boolean {
  return (
    a.getUTCFullYear() === b.getUTCFullYear() &&
    a.getUTCMonth() === b.getUTCMonth() &&
    a.getUTCDate() === b.getUTCDate()
  );
}

/**
 * Grabs a short window of context around the matched date, trimmed to
 * whole words on each side rather than cutting mid-word — mirrors
 * `surroundingSnippet` in the Swift version.
 */
function surroundingSnippet(text: string, matchIndex: number, matchLength: number): string | null {
  const padding = 30;

  let lower = Math.max(0, matchIndex - padding);
  if (lower > 0) {
    const spaceIdx = text.lastIndexOf(" ", lower);
    lower = spaceIdx === -1 ? lower : spaceIdx + 1;
  }

  let upper = Math.min(text.length, matchIndex + matchLength + padding);
  if (upper < text.length) {
    const spaceIdx = text.indexOf(" ", upper);
    upper = spaceIdx === -1 ? upper : spaceIdx;
  }

  const snippet = text
    .slice(lower, upper)
    .replace(/\s+/g, " ")
    .trim();
  return snippet.length ? snippet : null;
}
