/**
 * Timezone handling for extracted event times.
 *
 * A real newsletter said cross-country practice runs "3:00–4:00 p.m." The model
 * read that correctly and returned `2026-08-24T15:00:00` — no offset, because
 * the email doesn't state one. The normalizer treated a naive datetime as UTC,
 * so the app rendered 10:00 AM Central: five hours early, for an app whose
 * entire job is making sure a parent shows up at the right time.
 *
 * `Intl` is the only timezone database available in a Worker, so the offset is
 * computed from it rather than hardcoded — which also means DST is handled by
 * the platform instead of by a table that goes stale.
 */

/** Minutes that `timeZone` is ahead of UTC at a given instant. Negative for
 * the Americas. Derived by formatting the instant into the zone and reading
 * the wall clock back, because there is no direct offset API. */
function offsetMinutes(instant: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })
    .formatToParts(instant)
    .reduce<Record<string, string>>((acc, part) => {
      acc[part.type] = part.value;
      return acc;
    }, {});

  const asIfUTC = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    // Some locales render midnight as hour 24; the modulo keeps that from
    // rolling the date forward a day.
    Number(parts.hour) % 24,
    Number(parts.minute),
    Number(parts.second)
  );

  return (asIfUTC - instant.getTime()) / 60000;
}

/**
 * Reads a naive wall-clock string ("2026-08-24T15:00:00") as local time in
 * `timeZone` and returns the instant it denotes.
 *
 * Two passes: the first offset is measured at the wrong instant (the naive
 * string read as UTC), and applying it can land on the other side of a DST
 * boundary, so the corrected instant is measured again. On the two days a year
 * where a wall clock is ambiguous or skipped this settles on one valid reading
 * — good enough for school events, which never fall in that 1-2am window.
 *
 * Returns null if the zone is unusable, so the caller can decide rather than
 * silently recording a time that's hours off.
 */
export function zonedTimeToUTC(naive: string, timeZone: string): Date | null {
  const guess = new Date(`${naive}Z`);
  if (Number.isNaN(guess.getTime())) return null;

  try {
    let result = guess;
    for (let pass = 0; pass < 2; pass++) {
      result = new Date(guess.getTime() - offsetMinutes(result, timeZone) * 60000);
    }
    return Number.isNaN(result.getTime()) ? null : result;
  } catch {
    // An unknown zone name throws on the first format. Better to say so than
    // to quietly fall back to UTC, which is exactly the bug this file exists
    // to fix.
    console.error(`Unusable timezone ${JSON.stringify(timeZone)}; cannot resolve "${naive}".`);
    return null;
  }
}

/** Offset as "-05:00", for stating the zone concretely in the prompt. The
 * model resolves dates better when told the offset in effect than when handed
 * an IANA name it has to reason about. */
export function offsetLabel(timeZone: string, at: Date): string {
  try {
    const minutes = offsetMinutes(at, timeZone);
    const sign = minutes <= 0 ? "-" : "+";
    const abs = Math.abs(minutes);
    const hh = String(Math.floor(abs / 60)).padStart(2, "0");
    const mm = String(abs % 60).padStart(2, "0");
    return `${sign}${hh}:${mm}`;
  } catch {
    return "+00:00";
  }
}

export const DEFAULT_TIMEZONE = "America/Chicago";
