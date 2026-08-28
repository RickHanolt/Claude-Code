/**
 * Reads the MealViewer feed for a school's published menus.
 *
 * Parsed structurally, never sent to the model. One week of this feed is 4.3MB
 * — mostly per-item nutrition tables, allergen icons and the full USDA
 * nondiscrimination statement — and none of that is needed to answer "what's
 * for lunch". Handing it to Claude would be slow, expensive and pointless when
 * the answer is sitting in a named element.
 *
 * Regex rather than a DOM parser: Workers have no DOMParser, an XML library
 * would be a dependency added for one feed, and the fields wanted here are a
 * handful of uniquely-named elements rather than anything needing tree
 * traversal.
 */

export interface MealViewerBlock {
  /** e.g. "K-8 Express Lunch", "K-8 GNG Breakfast", "Pre-K Lunch". */
  name: string;
  /** True when the school publishes no service that day — a closure or a
   * holiday. Worth surfacing: "no lunch served" is exactly the kind of thing a
   * parent needs before 8am, and it's the opposite of a menu. */
  blackedOut: boolean;
  /** Entrée names in menu order, category headers removed. */
  entrees: string[];
}

export interface MealViewerDay {
  /** ISO date, no time: the feed's own DateFull with the zero time dropped. */
  date: string;
  blocks: MealViewerBlock[];
}

function firstTag(xml: string, tag: string): string | null {
  const match = xml.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return match ? match[1] : null;
}

/** Splits on a repeated element without a DOM.
 *
 * Deliberately non-greedy and anchored on the closing tag: MenuBlock contains
 * FoodItem which contains its own nested lists, and a greedy match would
 * swallow the rest of the document. */
function sections(xml: string, tag: string): string[] {
  const found: string[] = [];
  const pattern = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, "g");
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(xml)) !== null) found.push(match[1]);
  return found;
}

/** A category label rather than something a child eats.
 *
 * The feed lists "FEATURED ENTREES" and "CHOICE OF MILK" as FoodItems
 * alongside the actual food. They're distinguishable structurally rather than
 * by their capitalisation: a header carries `<Calories i:nil="true" />` while
 * real food carries a number. Matching on the names would mean maintaining a
 * list of every heading the district ever writes. */
function isCategoryHeader(item: string): boolean {
  return /<Calories i:nil="true"\s*\/>/.test(item);
}

export function parseMealViewer(xml: string): MealViewerDay[] {
  return sections(xml, "MenuSchedule").map((schedule) => {
    const dateFull = firstTag(schedule, "DateFull") ?? "";

    const blocks = sections(schedule, "MenuBlock").map((block) => {
      const entrees = sections(block, "FoodItem")
        .filter((item) => firstTag(item, "Item_Type")?.trim() === "ENTREES")
        .filter((item) => !isCategoryHeader(item))
        .map((item) => (firstTag(item, "Item_Name") ?? "").trim())
        .filter((name) => name.length > 0);

      return {
        // BlockName appears both on the block and repeated inside every
        // FoodItem; the block's own is the authoritative one.
        name: (firstTag(block, "BlockName") ?? "").trim(),
        blackedOut: firstTag(block, "BlackedOut")?.trim() === "true",
        entrees,
      };
    });

    return { date: dateFull.slice(0, 10), blocks };
  });
}

/** Picks the block a given kid actually eats from.
 *
 * The feed publishes Pre-K and K-8 variants of both meals on the same day, so
 * choosing by meal alone would hand an eighth-grader the Pre-K menu. Matching
 * is case-insensitive on both the grade band and the meal, because block names
 * are typed by district staff and "K-8 GNG Breakfast" versus "K-8 Express
 * Lunch" shows they aren't following a template.
 */
export function findBlock(
  day: MealViewerDay,
  gradeBand: string,
  meal: "breakfast" | "lunch"
): MealViewerBlock | null {
  const band = gradeBand.toLowerCase();
  return (
    day.blocks.find(
      (block) =>
        block.name.toLowerCase().includes(band) &&
        block.name.toLowerCase().includes(meal)
    ) ?? null
  );
}

/** The one-line answer for a morning: the featured entrée, or the fact that
 * nothing is being served.
 *
 * Returns null rather than a placeholder when there's simply no data, so the
 * caller can fall back to the kid's own default instead of printing something
 * that looks like information. */
export function summarize(block: MealViewerBlock | null): string | null {
  if (!block) return null;
  if (block.blackedOut) return "No meal served";
  if (block.entrees.length === 0) return null;

  // First two at most. A CPS lunch lists the entrée plus condiments and
  // alternates; past the first couple it stops being a summary and turns into
  // the menu board, which is not what a parent reads at 7am.
  return block.entrees.slice(0, 2).join(" · ");
}
