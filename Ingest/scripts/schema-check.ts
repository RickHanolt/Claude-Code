/**
 * Asserts the extraction schema actually converts to JSON Schema.
 *
 * This exists because of a bug that shipped to production: `tsc` passed, CI
 * was green, the Worker deployed, and every extraction threw
 * `TypeError: z.toJSONSchema is not a function` before reaching the API.
 * The SDK's `betaZodOutputFormat` calls a zod 4 API while the project had
 * zod 3 installed — the helper's *types* were satisfied, so nothing static
 * caught it, and the runtime failure surfaced only as emails arriving with
 * zero events, indistinguishable from "this email had no dates in it".
 *
 * Runs in CI with no API key and no network. If the zod major version and
 * the SDK helper ever diverge again, this fails in seconds instead of
 * silently degrading extraction in production.
 */
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { Extraction } from "../src/extractor";

const format = betaZodOutputFormat(Extraction) as unknown as {
  type?: string;
  schema?: { properties?: Record<string, unknown> };
};

if (format.type !== "json_schema") {
  console.error(`Expected type "json_schema", got ${JSON.stringify(format.type)}`);
  process.exit(1);
}

if (!format.schema?.properties?.events) {
  console.error("Schema is missing the expected `events` property.");
  console.error(JSON.stringify(format, null, 2).slice(0, 800));
  process.exit(1);
}

console.log("Extraction schema converts to JSON Schema cleanly.");
