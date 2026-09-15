/**
 * Exercises remote image handling against the shapes a real newsletter and a
 * malicious sender both produce. Run by `npm run check`.
 */
import { extractImageURLs, fetchRemoteImages } from "../src/remoteImages";

let failures = 0;
function check(name: string, condition: boolean, detail = "") {
  if (condition) return;
  failures += 1;
  console.error(`FAIL ${name}${detail ? ` — ${detail}` : ""}`);
}

// --- extractImageURLs -------------------------------------------------------

const newsletter = `
  <div><img src="https://cdn.example-mail.com/september-calendar.png" width="600"></div>
  <p>Text</p>
  <IMG SRC='https://cdn.example-mail.com/year-at-a-glance.jpg' alt="calendar">
  <img class="logo" src="https://cdn.example-mail.com/september-calendar.png">
  <img src="http://cdn.example-mail.com/insecure.png">
  <img src="data:image/png;base64,AAAA">
  <img src="cid:part1.abc@mail">
  <img src="https://127.0.0.1/admin.png">
  <img src="https://localhost/admin.png">
  <img src="https://[::1]/admin.png">
`;
const urls = extractImageURLs(newsletter);

check("finds https images", urls.length === 2, JSON.stringify(urls));
check("keeps document order", urls[0]?.includes("september-calendar") === true);
check("handles uppercase tags and single quotes", urls[1]?.includes("year-at-a-glance") === true);
check("collapses duplicates", urls.filter((u) => u.includes("september-calendar")).length === 1);
check("rejects http", !urls.some((u) => u.startsWith("http://")));
check("rejects data URIs", !urls.some((u) => u.startsWith("data:")));
check("rejects cid references", !urls.some((u) => u.startsWith("cid:")));
check("rejects IPv4 literals", !urls.some((u) => u.includes("127.0.0.1")));
check("rejects localhost", !urls.some((u) => u.includes("localhost")));
check("rejects IPv6 literals", !urls.some((u) => u.includes("::1")));
check("empty html is empty", extractImageURLs("").length === 0);

// --- fetchRemoteImages ------------------------------------------------------

const CALENDAR = new Uint8Array(200_000).fill(65);
const PIXEL = new Uint8Array(200).fill(65);
const HUGE = new Uint8Array(1_400_000).fill(65);

function reply(body: Uint8Array, type = "image/png", status = 200): Response {
  return new Response(body, { status, headers: { "content-type": type } });
}

async function fakeFetch(input: string | URL | Request): Promise<Response> {
  const url = String(input);
  if (url.includes("calendar")) return reply(CALENDAR);
  if (url.includes("pixel")) return reply(PIXEL);
  if (url.includes("huge")) return reply(HUGE);
  if (url.includes("html")) return reply(CALENDAR, "text/html");
  if (url.includes("missing")) return reply(new Uint8Array(), "image/png", 404);
  if (url.includes("boom")) throw new Error("network");
  return reply(CALENDAR);
}

const base = "https://cdn.example-mail.com";

const kept = await fetchRemoteImages([`${base}/calendar.png`], fakeFetch as typeof fetch);
check("keeps a real calendar image", kept.images.length === 1);
check("no note when everything read", kept.note === null, String(kept.note));
check("base64 round-trips", kept.images[0]?.data.length ? atob(kept.images[0].data).length === 200_000 : false);

const pixel = await fetchRemoteImages([`${base}/pixel.png`], fakeFetch as typeof fetch);
check("drops tracking pixels", pixel.images.length === 0);
check("does not name each decoration", pixel.note === null, String(pixel.note));

const wrongType = await fetchRemoteImages([`${base}/html.png`], fakeFetch as typeof fetch);
check("refuses non-images", wrongType.images.length === 0);
check("says why a non-image was refused", (wrongType.note ?? "").includes("isn't an image"));

const missing = await fetchRemoteImages([`${base}/missing.png`], fakeFetch as typeof fetch);
check("reports HTTP failures", (missing.note ?? "").includes("404"));

const huge = await fetchRemoteImages([`${base}/huge.png`], fakeFetch as typeof fetch);
check("refuses oversized images", huge.images.length === 0);
check("says an image was too large", (huge.note ?? "").includes("too large"));

const boom = await fetchRemoteImages([`${base}/boom.png`], fakeFetch as typeof fetch);
check("survives a network error", boom.images.length === 0);
check("reports a network error", (boom.note ?? "").includes("couldn't be downloaded"));

const many = await fetchRemoteImages(
  Array.from({ length: 7 }, (_, i) => `${base}/calendar-${i}.png`),
  fakeFetch as typeof fetch
);
check("caps how many are fetched", many.images.length === 4, String(many.images.length));
check("says how many went unread", (many.note ?? "").includes("3 more pictures"));

const none = await fetchRemoteImages([], fakeFetch as typeof fetch);
check("no urls means no note", none.images.length === 0 && none.note === null);

// One bad picture must not cost the good one beside it.
const mixed = await fetchRemoteImages(
  [`${base}/boom.png`, `${base}/calendar.png`],
  fakeFetch as typeof fetch
);
check("one failure doesn't lose the others", mixed.images.length === 1);
check("failure is still reported", (mixed.note ?? "").includes("couldn't be downloaded"));

if (failures > 0) {
  console.error(`\n${failures} check(s) failed.`);
  process.exit(1);
}
console.log("remote images: all checks passed");
