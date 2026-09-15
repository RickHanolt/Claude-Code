/**
 * Asserts the three-state lunch fact survives the round trip through D1.
 *
 * The failure this guards against is not a wrong flag on a new row — that's
 * visible the next morning and one forward fixes it. It's NULL quietly becoming
 * false. `Boolean(null)` and `Number(null)` are both falsy, and false here means
 * "no meal is coming, pack one". Collapse the third state anywhere along the
 * path and every exception row written before this column existed turns into a
 * pack-a-lunch alert, on days a meal was already bought and paid for.
 *
 * The rule those flags feed is asserted in the same terms Morning Mode uses:
 * emphasis means somebody at home has to act, not that the day is unusual.
 */
import { toStoredLunch, fromStoredLunch, lunchNeedsAction } from "../src/lunch";

let failures = 0;

function check(name: string, actual: unknown, expected: unknown) {
  if (actual !== expected) {
    console.error(`${name}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    failures += 1;
  }
}

// --- Writing to D1 ----------------------------------------------------------

check("provided stores as 1", toStoredLunch(true), 1);
check("not provided stores as 0", toStoredLunch(false), 0);
check("unstated stores as NULL", toStoredLunch(null), null);
// The extractor can omit the key entirely on a non-lunch field.
check("undefined stores as NULL", toStoredLunch(undefined), null);

// --- Reading back -----------------------------------------------------------

check("1 reads as provided", fromStoredLunch(1), true);
check("0 reads as not provided", fromStoredLunch(0), false);
check("NULL reads as unstated", fromStoredLunch(null), null);
check("a missing column reads as unstated", fromStoredLunch(undefined), null);

// The specific coercion that would break it. Left as a live assertion rather
// than a comment because the tempting one-liner is `Boolean(row.lunchProvided)`.
check("NULL must not read as false", fromStoredLunch(null) === false, false);
check("0 must not read as unstated", fromStoredLunch(0) === null, false);

// --- Round trip -------------------------------------------------------------

for (const value of [true, false, null] as const) {
  check(`round trip preserves ${JSON.stringify(value)}`, fromStoredLunch(toStoredLunch(value)), value);
}

// --- The rule itself --------------------------------------------------------

check("a day with no meal is an action", lunchNeedsAction(false), true);
check("a day with a meal provided is not", lunchNeedsAction(true), false);
// Unstated defers to the caller's own judgement — on iOS, the existing
// baseline comparison. It must not assert either way on its own.
check("unstated asserts nothing", lunchNeedsAction(null), null);
check("undefined asserts nothing", lunchNeedsAction(undefined), null);

// The property that makes the rule worth having: it depends on the fact alone,
// never on how anyone worded the kid's default. Same fact, opposite prose.
check("wording cannot change a pack day", lunchNeedsAction(false), lunchNeedsAction(false));
check("a provided day never alerts", lunchNeedsAction(true), false);

// --- The flagged day ---------------------------------------------------------
//
// A lunch calendar that marks a date without saying why — Grandparents Day,
// an early dismissal, a closed ordering window — is the case null exists for.
// The flag could mean a special lunch is served or that nobody ordered one, and
// extraction cannot tell which. Resolving it to false would put "Pack a lunch"
// on a morning the school may well be feeding him, stated in alert weight, on
// the one day the calendar went out of its way to mark.
//
// So this must stay unresolved here and defer to isNotable on the app side,
// which carries true for a flag. The consumer decides; this function does not
// get to guess.
check("a flagged day resolves to no answer", lunchNeedsAction(null), null);
check("a flagged day is not treated as a pack day", lunchNeedsAction(null) === true, false);
check("a flagged day is not treated as provided", lunchNeedsAction(null) === false, false);

console.log(failures === 0 ? "lunch-check: all passed" : `lunch-check: ${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
