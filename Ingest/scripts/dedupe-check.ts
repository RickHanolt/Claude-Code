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
import { contentFingerprint, isDuplicateEvent } from "../src/dedupe";

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
  "reworded, more specific title on the same day is a duplicate",
  isDuplicateEvent(
    { title: "Golf Program Info Session in the School Library", startDate: "2026-09-03T17:00:00Z" },
    existing
  ),
  true
);

check(
  "punctuation and case differences are a duplicate",
  isDuplicateEvent({ title: "cheer practice!", startDate: "2026-08-27T09:00:00Z" }, existing),
  true
);

// --- The important half: things that must NOT be swallowed -----------------

check(
  "same title on a DIFFERENT day is kept",
  isDuplicateEvent({ title: "Cheer Practice", startDate: "2026-09-03T16:30:00Z" }, existing),
  false
);

check(
  "a different event on the same day is kept",
  isDuplicateEvent({ title: "Dads Social Hour", startDate: "2026-09-03T19:00:00Z" }, existing),
  false
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
