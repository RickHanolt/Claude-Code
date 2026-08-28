/**
 * Asserts the extractor emits dates the iOS app can actually decode.
 *
 * The app decodes with `JSONDecoder.dateDecodingStrategy = .iso8601`, i.e.
 * `ISO8601DateFormatter` in `.withInternetDateTime` mode, which requires a
 * time and an explicit offset. When the schema was loosened to let the model
 * omit a time, it returned a bare `2026-09-09` for an all-day event and the
 * app rejected the entire /v1/pending response with "The data couldn't be read
 * because it isn't in the correct format" — no events, no partial result, and
 * nothing in the backend looking wrong.
 *
 * Runs in CI with no API key and no network, alongside schema-check.
 */
import { normalizeISODate } from "../src/extractor";

// Anything the model plausibly returns, mapped to the one form the app takes.
const cases: Array<[string | null, string | null]> = [
  // The shape that actually broke it: all-day, no time. Anchored at noon so a
  // negative-offset timezone doesn't render it as the previous day.
  ["2026-09-09", "2026-09-09T12:00:00Z"],
  // Datetime with no offset — read as UTC, matching the old parser.
  ["2026-09-09T09:00:00", "2026-09-09T09:00:00Z"],
  ["2026-09-09T09:00", "2026-09-09T09:00:00Z"],
  // Already-correct forms survive unchanged.
  ["2026-09-09T09:00:00Z", "2026-09-09T09:00:00Z"],
  ["2026-09-09T09:00:00.000Z", "2026-09-09T09:00:00Z"],
  // A real offset is respected, not blindly relabelled.
  ["2026-09-09T09:00:00-05:00", "2026-09-09T14:00:00Z"],
  // Whitespace from the model shouldn't matter.
  ["  2026-09-09  ", "2026-09-09T12:00:00Z"],
  // Unparseable and empty return null so the caller can drop the event.
  ["next Tuesday", null],
  ["", null],
  [null, null],
];

let failures = 0;

for (const [input, expected] of cases) {
  const actual = normalizeISODate(input);
  if (actual !== expected) {
    console.error(`normalizeISODate(${JSON.stringify(input)}) = ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    failures += 1;
  }
}

// The contract the app depends on, stated directly rather than implied by the
// cases above: no fractional seconds, explicit Z, always a time component.
const INTERNET_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

for (const [input] of cases) {
  const actual = normalizeISODate(input);
  if (actual !== null && !INTERNET_DATE_TIME.test(actual)) {
    console.error(`normalizeISODate(${JSON.stringify(input)}) produced ${actual}, which .withInternetDateTime will reject.`);
    failures += 1;
  }
}

if (failures > 0) {
  console.error(`${failures} date normalization failure(s).`);
  process.exit(1);
}

console.log(`Date normalization: ${cases.length} cases OK.`);
