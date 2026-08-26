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
    const date = result.start.date();
    if (isSameCalendarDay(date, referenceDate)) continue;

    const startMs = date.getTime();
    if (seenStarts.has(startMs)) continue;
    seenStarts.add(startMs);

    const endDate = result.end ? result.end.date() : null;
    const notes = surroundingSnippet(bodyText, result.index, result.text.length);
    const trimmedSubject = subject.trim();

    candidates.push({
      title: trimmedSubject.length ? trimmedSubject : "Forwarded event",
      startDate: date.toISOString(),
      endDate: endDate ? endDate.toISOString() : null,
      notes,
    });
  }

  return candidates;
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
