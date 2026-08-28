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
// Expectations are in UTC; the comment gives the Chicago wall clock, which is
// the number a parent actually reads on the phone.
const TZ = "America/Chicago";

const cases: Array<[string | null, string | null]> = [
  // The shape that broke it first: all-day, no time. Anchored at local noon so
  // it stays on the right calendar day in any zone.
  ["2026-09-09", "2026-09-09T17:00:00Z"],

  // The shape that broke it SECOND, and worse. A newsletter said cross-country
  // practice runs "3:00-4:00 p.m."; the model returned a bare 15:00 because
  // the email states no offset. Read as UTC that rendered as 10:00 AM — five
  // hours early. Read in the school's zone it is 3:00 PM, as written.
  ["2026-08-24T15:00:00", "2026-08-24T20:00:00Z"],
  ["2026-08-24T15:00", "2026-08-24T20:00:00Z"],

  // Same wall clock in winter is an hour further from UTC. Hardcoding an
  // offset instead of asking Intl would get exactly one of these two right.
  ["2026-01-15T09:00:00", "2026-01-15T15:00:00Z"],

  // An explicit offset is respected, not relabelled.
  ["2026-09-09T09:00:00-05:00", "2026-09-09T14:00:00Z"],
  ["2026-09-09T14:00:00Z", "2026-09-09T14:00:00Z"],
  ["2026-09-09T14:00:00.000Z", "2026-09-09T14:00:00Z"],

  // Whitespace from the model shouldn't matter.
  ["  2026-09-09  ", "2026-09-09T17:00:00Z"],

  // Unparseable and empty return null so the caller can drop the event.
  ["next Tuesday", null],
  ["", null],
  [null, null],
];

let failures = 0;


for (const [input, expected] of cases) {
  const actual = normalizeISODate(input, TZ);
  if (actual !== expected) {
    console.error(`normalizeISODate(${JSON.stringify(input)}) = ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    failures += 1;
  }
}

// The contract the app depends on, stated directly rather than implied by the
// cases above: no fractional seconds, explicit Z, always a time component.
const INTERNET_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

for (const [input] of cases) {
  const actual = normalizeISODate(input, TZ);
  if (actual !== null && !INTERNET_DATE_TIME.test(actual)) {
    console.error(`normalizeISODate(${JSON.stringify(input)}) produced ${actual}, which .withInternetDateTime will reject.`);
    failures += 1;
  }
}

// The point of the local-noon anchor: an all-day event must land on the day
// the email named, read back in the school's zone. Midnight UTC would render
// as the previous day here, silently moving the event.
const allDay = normalizeISODate("2026-09-09", TZ);
const readBack = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, dateStyle: "short" })
  .format(new Date(allDay!));

if (readBack !== "2026-09-09") {
  console.error(`All-day 2026-09-09 reads back in ${TZ} as ${readBack}, not the day the email named.`);
  failures += 1;
}

if (failures > 0) {
  console.error(`${failures} date normalization failure(s).`);
  process.exit(1);
}

console.log(`Date normalization: ${cases.length} cases OK.`);
