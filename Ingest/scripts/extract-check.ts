/**
 * Runs the extractor against a real email and prints what it found.
 *
 * This exists because the parser it replaced looked fine in isolation and
 * fell apart on real mail: a single school newsletter produced 22 candidates
 * — five near-duplicates of one bulleted list, fragment titles, and entries
 * dated 2014/2015 from a comma-separated day list. Any change to the prompt
 * or model should be checked against real emails, not invented ones.
 *
 * Usage:
 *   export ANTHROPIC_API_KEY=sk-ant-...
 *   npx tsx scripts/extract-check.ts path/to/email.txt [received-date]
 *
 * To get plain text out of a PDF newsletter first:
 *   pdftotext -layout newsletter.pdf email.txt
 *
 * What good output looks like: one entry per real event, titles a parent
 * would recognize, every year matching the school year, and no entry
 * tracing back to a "From:"/"Date:" header or a bare month heading.
 */
import { readFileSync } from "fs";
import { extractEvents } from "../src/extractor";

const [, , filePath, receivedArg] = process.argv;

if (!filePath) {
  console.error("usage: npx tsx scripts/extract-check.ts <file> [received-date]");
  process.exit(1);
}

const apiKey = process.env.ANTHROPIC_API_KEY;
if (!apiKey) {
  console.error("ANTHROPIC_API_KEY is not set.");
  process.exit(1);
}

const bodyText = readFileSync(filePath, "utf-8");
const receivedAt = receivedArg ? new Date(receivedArg) : new Date();
const subject = bodyText.split("\n").find((line) => line.trim())?.trim() ?? "";

const events = await extractEvents(apiKey, subject, bodyText, receivedAt);

console.log(`Received ${receivedAt.toISOString().slice(0, 10)} — ${events.length} event(s)\n`);
for (const event of events) {
  console.log(`  ${event.startDate}${event.endDate ? ` → ${event.endDate}` : " (all day)"}`);
  console.log(`  ${event.title}`);
  if (event.notes) console.log(`  ${event.notes}`);
  console.log();
}

// Cheap checks for the exact failures that motivated the rewrite.
const years = new Set(events.map((e) => e.startDate.slice(0, 4)));
const starts = events.map((e) => e.startDate);
const duplicates = starts.filter((s, i) => starts.indexOf(s) !== i);

if (years.size > 2) console.warn(`⚠ events span ${years.size} years: ${[...years].join(", ")}`);
if (duplicates.length) console.warn(`⚠ repeated start times: ${[...new Set(duplicates)].join(", ")}`);
