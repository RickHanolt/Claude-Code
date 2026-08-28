/**
 * Asserts duplicate suppression collapses what it should and, more importantly,
 * leaves alone what it shouldn't.
 *
 * The failure this guards against is not "duplicates got through" — that's
 * visible and annoying but harmless. It's the opposite: a threshold that
 * quietly swallows a real event because it shares words with another on the
 * same day. That failure is invisible, and an event silently missing from a
 * parent's calendar is the worst outcome this app has.
 */
import { collapseDuplicates, contentFingerprint, isDuplicateEvent } from "../src/dedupe";

let failures = 0;

function check(name: string, actual: unknown, expected: unknown) {
  if (actual !== expected) {
    console.error(`${name}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    failures += 1;
  }
}

// --- Layer 1: email fingerprinting -----------------------------------------

const body = "Picture Day is September 9.\nSpirit wear orders close Friday.";

check(
  "identical bodies fingerprint the same",
  contentFingerprint("Newsletter", body) === contentFingerprint("Newsletter", body),
  true
);

// The case that actually occurred: Gmail stamps each forward with its own
// Date: line, so the raw bytes differ while the content is identical.
check(
  "forward headers are ignored",
  contentFingerprint("Fwd: Newsletter", `---------- Forwarded message ---------\nFrom: School <a@b.com>\nDate: Wed, Aug 27, 2026\n\n${body}`) ===
    contentFingerprint("Fwd: Newsletter", `---------- Forwarded message ---------\nFrom: School <a@b.com>\nDate: Thu, Aug 28, 2026\n\n${body}`),
  true
);

check(
  "genuinely different mail fingerprints differently",
  contentFingerprint("Newsletter", body) === contentFingerprint("Newsletter", "Half day on Friday."),
  false
);

// An email carrying a calendar is not the same email as one that isn't. The
// first version hashed text only, so re-forwarding to pick up an attachment the
// original lacked would have been dropped as a duplicate.
check(
  "attachments change the fingerprint",
  contentFingerprint("Newsletter", body) ===
    contentFingerprint("Newsletter", body, [
      { filename: "calendar.pdf", mediaType: "application/pdf", data: "AAAA" },
    ]),
  false
);

check(
  "the same attachment set fingerprints the same",
  contentFingerprint("Newsletter", body, [
    { filename: "calendar.pdf", mediaType: "application/pdf", data: "AAAA" },
  ]) ===
    contentFingerprint("Newsletter", body, [
      { filename: "calendar.pdf", mediaType: "application/pdf", data: "BBBB" },
    ]),
  true
);

// --- Layer 2: event matching ------------------------------------------------

const existing = [
  { title: "Cheer Practice", startDate: "2026-08-27T16:30:00Z" },
  { title: "Golf Program Info Session", startDate: "2026-09-03T17:00:00Z" },
  { title: "Picture Day", startDate: "2026-09-09T12:00:00Z" },
];

check(
  "exact repeat is a duplicate",
  isDuplicateEvent({ title: "Cheer Practice", startDate: "2026-08-27T16:30:00Z" }, existing),
  true
);

check(
  "reworded, more specific title at the same instant is a duplicate",
  isDuplicateEvent(
    { title: "Golf Program Info Session in the School Library", startDate: "2026-09-03T17:00:00Z" },
    existing
  ),
  true
);

check(
  "punctuation and case differences are a duplicate",
  isDuplicateEvent({ title: "cheer practice!", startDate: "2026-08-27T16:30:00Z" }, existing),
  true
);

// Rows written before date normalization carry milliseconds; same instant,
// different spelling.
check(
  "millisecond spelling of the same instant is a duplicate",
  isDuplicateEvent({ title: "Cheer Practice", startDate: "2026-08-27T16:30:00.000Z" }, existing),
  true
);

// --- The important half: things that must NOT be swallowed -----------------

check(
  "same title on a DIFFERENT day is kept",
  isDuplicateEvent({ title: "Cheer Practice", startDate: "2026-09-03T16:30:00Z" }, existing),
  false
);

// The case a real newsletter exposed, and the reason matching is keyed on the
// start instant rather than the calendar day. A father-son event ran at 8:00
// for grades 1-4 and 9:00 for grades 5-7; a clinic ran at 10:00 and 11:00 the
// same day. Identical titles, same day, genuinely separate sessions a parent
// has to show up for. Day-granularity matching silently ate one of each pair.
const sessions = [
  { title: "Father-Son Retreat", startDate: "2026-09-13T13:00:00Z" },
  { title: "Basketball Skills Clinic", startDate: "2026-09-16T15:00:00Z" },
];

check(
  "a second session later the same day is kept",
  isDuplicateEvent({ title: "Father-Son Retreat", startDate: "2026-09-13T14:00:00Z" }, sessions),
  false
);

check(
  "a second clinic hour the same day is kept",
  isDuplicateEvent({ title: "Basketball Skills Clinic", startDate: "2026-09-16T16:00:00Z" }, sessions),
  false
);

check(
  "a different event on the same day is kept",
  isDuplicateEvent({ title: "Dads Social Hour", startDate: "2026-09-03T19:00:00Z" }, existing),
  false
);

// End to end on the shape actually observed: two extraction runs over one
// newsletter, notes reordered, plus two real sessions an hour apart.
const observed = [
  { title: "Basketball Skills Clinic", startDate: "2026-09-16T15:00:00Z" },
  { title: "Basketball Skills Clinic at SMA", startDate: "2026-09-16T15:00:00Z" },
  { title: "Basketball Skills Clinic", startDate: "2026-09-16T16:00:00Z" },
  { title: "Basketball Skills Clinic at SMA", startDate: "2026-09-16T16:00:00Z" },
];

check("collapse keeps both real sessions", collapseDuplicates(observed).length, 2);
check(
  "collapse keeps the 10:00 session",
  collapseDuplicates(observed)[0].startDate,
  "2026-09-16T15:00:00Z"
);
check(
  "collapse keeps the 11:00 session",
  collapseDuplicates(observed)[1].startDate,
  "2026-09-16T16:00:00Z"
);

// The containment-scoring risk, spelled out: "Picture Day" is wholly contained
// in "Picture Day Retakes". They are different events and must both survive —
// which they do only because they fall on different days.
check(
  "Picture Day Retakes on another day is kept",
  isDuplicateEvent({ title: "Picture Day Retakes", startDate: "2026-10-14T12:00:00Z" }, existing),
  false
);

check(
  "nothing matches an empty history",
  isDuplicateEvent({ title: "Cheer Practice", startDate: "2026-08-27T16:30:00Z" }, []),
  false
);

if (failures > 0) {
  console.error(`${failures} dedupe failure(s).`);
  process.exit(1);
}

console.log("Dedupe: all cases OK.");
