/**
 * The one place that knows how a lunch fact crosses a boundary.
 *
 * Whether a meal was provided has three states, and the third one carries
 * weight: null means the document didn't say, which is different from saying no
 * meal is coming. SQLite stores it as INTEGER-or-NULL and JSON carries it as
 * boolean-or-null, and every conversion between those is somewhere `Boolean()`
 * or `Number()` would look obviously correct and silently turn "we don't know"
 * into "pack a lunch". Centralised so there is one of them to get right.
 */

/** What a lunch fact means for the morning, or null when it says nothing.
 *
 * The whole point of the field. Emphasis in Morning Mode tracks whether someone
 * at home has to act, not whether the day departs from the usual — because the
 * usual moves. A kid packs every day until the month somebody orders twenty hot
 * lunches, and a rule anchored to his habit inverts with it, in the direction
 * that sends him to school with nothing.
 */
export function lunchNeedsAction(provided: boolean | null | undefined): boolean | null {
  if (provided === null || provided === undefined) return null;
  return !provided;
}

/** JSON/extraction value to the D1 column. */
export function toStoredLunch(provided: boolean | null | undefined): 1 | 0 | null {
  if (provided === null || provided === undefined) return null;
  return provided ? 1 : 0;
}

/** D1 column back to the value the app decodes. */
export function fromStoredLunch(stored: unknown): boolean | null {
  if (stored === null || stored === undefined) return null;
  return Boolean(stored);
}
