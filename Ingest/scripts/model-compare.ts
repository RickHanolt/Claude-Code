/**
 * Runs the same real emails through several models and compares what each one
 * found.
 *
 * Exists because "is a cheaper model good enough" is a measurement, not an
 * opinion, and the answer turns on one thing that no amount of reasoning
 * settles: whether a model can read a dense calendar grid out of a picture.
 * A school's year-at-a-glance is twelve cells of small print, and it is where
 * most of the value in these emails turns out to live.
 *
 * Reads emails from JSON dumped by `wrangler d1 execute --json` rather than
 * querying D1 itself, so it runs anywhere and the data-fetching step is visible
 * in the workflow rather than buried here.
 *
 * SPENDS REAL MONEY. Prints an estimate and refuses to exceed --max-cost.
 */
import { readFileSync } from "node:fs";
import { extractEvents, type ExtractionModel } from "../src/extractor";
import { fetchRemoteImages } from "../src/remoteImages";
import type { StoredAttachment } from "../src/attachments";

/** $ per million tokens. From the pricing table; update together. */
const PRICING: Record<string, { input: number; output: number }> = {
  "claude-opus-5": { input: 5, output: 25 },
  "claude-sonnet-5": { input: 2, output: 10 },
  "claude-haiku-4-5": { input: 1, output: 5 },
};

/** One variable changes: the model. Thinking stays off everywhere it is
 * accepted, so a difference in output is a difference in the model and not in
 * how it was configured.
 *
 * Haiku 4.5 sends no `thinking` parameter at all — it predates the disabled
 * form and expects `{type: "enabled", budget_tokens: N}`. Omitting is its
 * no-thinking setting. */
const ARMS: ExtractionModel[] = [
  { model: "claude-opus-5", thinking: { type: "disabled" } },
  { model: "claude-sonnet-5", thinking: { type: "disabled" } },
  { model: "claude-haiku-4-5" },
];

interface EmailRow {
  id: string;
  subject: string;
  bodyText: string;
  receivedAt: string;
  remoteImageURLs: string | null;
}

interface AttachmentRow {
  forwarded_email_id: string;
  filename: string | null;
  mediaType: string;
  data: string;
}

/** wrangler --json wraps results as [{ results: [...] }]; a bare array is what
 * you get from a hand-written fixture. Accept both. */
function rowsOf<T>(raw: string): T[] {
  const parsed = JSON.parse(raw);
  if (Array.isArray(parsed) && parsed[0]?.results) return parsed.flatMap((p: any) => p.results);
  if (Array.isArray(parsed)) return parsed as T[];
  return (parsed.results ?? []) as T[];
}

function arg(name: string, fallback: string): string {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
}

interface Seen {
  day: string;
  words: Set<string>;
  title: string;
}

function describe(e: { title: string; startDate: string }): Seen {
  return {
    day: e.startDate.slice(0, 10),
    words: new Set(
      e.title
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, " ")
        .split(" ")
        .filter((w) => w.length > 2)
    ),
    title: e.title,
  };
}

/** How much of the shorter title the two share.
 *
 * The first version of this compared word SETS for equality, which is far too
 * strict for the question being asked. "Fall LEGO Club" against "LEGO Club" is
 * one word apart and scored as a total miss; so did "Back to School Mass & BBQ"
 * against "...Mass and BBQ", because "and" survives the length filter. It
 * reported Sonnet at 30% recall on emails where both models had found the same
 * sixteen events.
 *
 * Containment against the shorter title is what the production dedupe uses, and
 * for the same reason: one side being wordier is the common case. */
function overlap(a: Seen, b: Seen): number {
  if (a.words.size === 0 || b.words.size === 0) {
    return a.title.toLowerCase() === b.title.toLowerCase() ? 1 : 0;
  }

  // Numbers disagreeing means different things, whatever the rest shares.
  // "Basketball Skills Program K-3rd" and "...4th-8th" overlap at 0.75 on
  // words alone and are two different sessions on the same afternoon — the
  // same guard the iOS matcher applies, and this check is why it's here.
  //
  // Only enforced when BOTH sides carry numbers: "SMA Golf Outing 2026"
  // against a plainer "Golf Outing" is one model being wordier, not a
  // disagreement.
  const digitsA = [...a.words].filter((w) => /\d/.test(w)).sort().join(" ");
  const digitsB = [...b.words].filter((w) => /\d/.test(w)).sort().join(" ");
  if (digitsA && digitsB && digitsA !== digitsB) return 0;

  let shared = 0;
  for (const w of a.words) if (b.words.has(w)) shared += 1;
  return shared / Math.min(a.words.size, b.words.size);
}

/** Lower than the production threshold (0.75) on purpose. Production is
 * deciding whether to HIDE a row, where a wrong merge loses information. Here
 * it decides whether two models saw the same thing, where being slightly
 * generous costs nothing and being strict invents a quality gap. */
const MATCH_THRESHOLD = 0.6;

function findMatch(needle: Seen, haystack: Seen[]): Seen | undefined {
  return haystack.find((c) => c.day === needle.day && overlap(needle, c) >= MATCH_THRESHOLD);
}

async function main() {
  const emails = rowsOf<EmailRow>(readFileSync(arg("emails", "emails.json"), "utf8"));
  const attachments = rowsOf<AttachmentRow>(
    readFileSync(arg("attachments", "attachments.json"), "utf8")
  );
  const maxCost = Number(arg("max-cost", "3.00"));
  const apiKey = process.env.ANTHROPIC_API_KEY;

  if (!apiKey) {
    console.error("ANTHROPIC_API_KEY is not set. Nothing was run and nothing was billed.");
    process.exit(1);
  }
  if (emails.length === 0) {
    console.error("No emails in the dump. Nothing to compare.");
    process.exit(1);
  }

  console.log(`Comparing ${ARMS.length} models across ${emails.length} email(s).`);
  console.log(`Cost ceiling: $${maxCost.toFixed(2)}. Anything beyond it stops the run.\n`);

  const spend: Record<string, number> = {};
  const found: Record<string, Record<string, Seen[]>> = {};
  let total = 0;

  for (const email of emails) {
    console.log("─".repeat(72));
    console.log(`${email.receivedAt.slice(0, 10)}  ${email.subject.slice(0, 60)}`);

    const stored: StoredAttachment[] = attachments
      .filter((a) => a.forwarded_email_id === email.id)
      .map((a) => ({ filename: a.filename, mediaType: a.mediaType, data: a.data }));

    // Fetched once and reused across arms. Re-downloading per model would be
    // wasteful and, worse, could hand different models different inputs if a
    // CDN hiccuped between runs.
    let referenced: string[] = [];
    try {
      referenced = email.remoteImageURLs ? JSON.parse(email.remoteImageURLs) : [];
    } catch {
      referenced = [];
    }
    const remote = await fetchRemoteImages(referenced);
    const inputs = [...stored, ...remote.images];
    console.log(`  inputs: ${stored.length} attachment(s), ${remote.images.length} fetched image(s)`);

    for (const armConfig of ARMS) {
      if (total >= maxCost) {
        console.log(`\nStopped: $${total.toFixed(2)} reached the ceiling.`);
        report(spend, found, emails);
        return;
      }

      try {
        const result = await extractEvents(
          apiKey,
          email.subject,
          email.bodyText,
          new Date(email.receivedAt),
          inputs,
          "America/Chicago",
          armConfig
        );

        const price = PRICING[armConfig.model] ?? { input: 0, output: 0 };
        const cost =
          (result.usage.inputTokens / 1e6) * price.input +
          (result.usage.outputTokens / 1e6) * price.output;

        total += cost;
        spend[armConfig.model] = (spend[armConfig.model] ?? 0) + cost;
        found[armConfig.model] ??= {};
        found[armConfig.model][email.id] = result.events.map(describe);

        console.log(
          `  ${armConfig.model.padEnd(20)} ${String(result.events.length).padStart(3)} events  ` +
            `${String(result.exceptions.length).padStart(3)} exceptions  $${cost.toFixed(4)}`
        );
      } catch (error) {
        // One model failing must not cost the comparison. A 400 from a model
        // that rejects a parameter is itself a result worth printing.
        console.log(`  ${armConfig.model.padEnd(20)} FAILED: ${(error as Error).message.slice(0, 90)}`);
        found[armConfig.model] ??= {};
        found[armConfig.model][email.id] = [];
      }
    }
  }

  report(spend, found, emails);
}

function report(
  spend: Record<string, number>,
  found: Record<string, Record<string, Seen[]>>,
  emails: EmailRow[]
) {
  const baseline = ARMS[0].model;
  console.log("\n" + "═".repeat(72));
  console.log("AGAINST THE BASELINE (" + baseline + ")\n");

  for (const arm of ARMS.slice(1)) {
    let agreed = 0;
    let missed = 0;
    let extra = 0;
    const examples: string[] = [];

    for (const email of emails) {
      const base = found[baseline]?.[email.id] ?? [];
      const mine = found[arm.model]?.[email.id] ?? [];

      // Each candidate is claimed at most once, so a model that emits the same
      // event three times can't score three matches against one baseline row.
      const unclaimed = [...mine];
      for (const b of base) {
        const hit = findMatch(b, unclaimed);
        if (hit) {
          agreed += 1;
          unclaimed.splice(unclaimed.indexOf(hit), 1);
        } else {
          missed += 1;
          if (examples.length < 10) examples.push(`${b.day}  ${b.title.slice(0, 54)}`);
        }
      }
      extra += unclaimed.length;
    }

    const recall = agreed + missed > 0 ? (agreed / (agreed + missed)) * 100 : 0;
    console.log(`${arm.model}`);
    console.log(`  found ${agreed} of the baseline's ${agreed + missed} events (${recall.toFixed(0)}%)`);
    console.log(`  ${extra} event(s) the baseline did not find`);
    if (examples.length > 0) console.log("  not found by this model:");
    for (const line of examples) console.log(`    ${line}`);
    console.log();
  }

  console.log("SPEND");
  let total = 0;
  for (const [model, amount] of Object.entries(spend)) {
    total += amount;
    console.log(`  ${model.padEnd(20)} $${amount.toFixed(4)}`);
  }
  console.log(`  ${"total".padEnd(20)} $${total.toFixed(4)}`);
  console.log(
    "\nRecall against the baseline is not the same as correctness — the baseline" +
      "\nis not ground truth. Check the missed events against the source document" +
      "\nbefore concluding anything."
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
