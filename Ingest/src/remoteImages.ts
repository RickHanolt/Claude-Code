/**
 * Images a newsletter references but doesn't carry.
 *
 * Mailing platforms host pictures on their own CDN and point at them with
 * `<img src>`. The bytes are never in the message, so an email whose entire
 * calendar is a picture arrives with zero attachments and extraction sees only
 * the surrounding prose. That is exactly how St. Mary's September calendar —
 * and with it "Pizza/Jean Day" — reached the app as nothing at all.
 *
 * Fetching them is a deliberate widening of what this Worker will reach out
 * and touch, so the bounds are written here rather than spread across the
 * caller.
 */

import type { StoredAttachment } from "./attachments";

/** How many to download. Cheap — these are bytes, not model calls. */
const MAX_FETCHED = 12;

/** How many to actually hand the model. This is the number that costs, and it
 * is deliberately separate from the one above.
 *
 * Conflating them is what made the first version useless: capped at four and
 * taken in document order, every slot went to the header banner and the
 * newsletter's decorative strips, which were then dropped as too small to be
 * documents. Four fetches, nothing sent, and a note that said only "25 more
 * weren't read". A school's year calendar sat in slot eleven. */
const MAX_SENT = 5;

/** Total bytes downloaded per email, so a page of large photographs can't run
 * up a bill on its own. */
const MAX_TOTAL_BYTES = 5_000_000;

/** Per image, before base64. Roughly the same ceiling the attachment path
 * uses, expressed in real bytes because here we control the fetch. */
const MAX_IMAGE_BYTES = 1_350_000;

/** Below this it is a logo, an icon, or a tracking pixel — the same floor the
 * attachment path applies, and for the same reason: a legible calendar page is
 * never this small. */
const MIN_IMAGE_BYTES = 15_000;

const SUPPORTED = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"]);

/** Boilerplate every newsletter of this kind carries, matched on where it
 * lives rather than what it looks like.
 *
 * Measured, not guessed: one real St. Mary's newsletter referenced 29 images,
 * of which six were Giphy animations, two were file-type icons, one was a
 * "no photo" placeholder and one was the platform's tracking pixel. Ten of
 * twenty-nine, removed before a single byte is downloaded. */
function isBoilerplate(url: URL): boolean {
  const host = url.hostname.toLowerCase();
  const path = url.pathname.toLowerCase();

  // Animated reaction GIFs. Never a calendar, frequently several per email.
  if (host.endsWith("giphy.com")) return true;
  // Open-tracking pixels, which exist to be fetched and say nothing.
  if (host.startsWith("emailimage.")) return true;
  // The platform's own furniture: file-type icons, avatars, placeholders.
  if (path.includes("/images/files/")) return true;
  if (path.includes("nophoto")) return true;
  // Masthead strips. "bannar" is the platform's spelling, not a typo here.
  if (/banner|bannar|logo|header|footer|divider|spacer/.test(path)) return true;

  return false;
}

/** Hosts that are never a school's newsletter image and are the shape of an
 * attack rather than a mistake.
 *
 * A Worker has no VPC and no cloud metadata endpoint, which is what makes SSRF
 * dangerous elsewhere — so this is defence in depth rather than the main
 * control. The main control is that fetching is capped, typed and sized, and
 * that only whoever knows the ingest address can make this run at all. */
function isDisallowedHost(hostname: string): boolean {
  const host = hostname.toLowerCase();
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".internal")) return true;

  // Bare IP literals. A legitimate CDN is always named.
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return true;
  if (host.startsWith("[") || host.includes(":")) return true;

  return false;
}

/** Every `<img src>` in the HTML, https only, de-duplicated, in document order.
 *
 * Deliberately a regex rather than a parser. A Worker has no DOM, the input is
 * one attribute of one tag, and the failure mode of getting it slightly wrong
 * is a URL that doesn't fetch — not a security boundary. */
export function extractImageURLs(html: string): string[] {
  const urls: string[] = [];
  const seen = new Set<string>();

  for (const match of html.matchAll(/<img\b[^>]*?\ssrc\s*=\s*["']([^"']+)["']/gi)) {
    const raw = match[1]?.trim();
    if (!raw) continue;

    // Data URIs are already in the message and would have arrived as
    // attachments; cid: references point at parts postal-mime already gave us.
    if (!/^https:\/\//i.test(raw)) continue;

    let parsed: URL;
    try {
      parsed = new URL(raw);
    } catch {
      continue;
    }

    if (isDisallowedHost(parsed.hostname)) continue;
    if (isBoilerplate(parsed)) continue;

    const key = parsed.toString();
    if (seen.has(key)) continue;
    seen.add(key);
    urls.push(key);
  }

  return urls;
}

export interface RemoteImageResult {
  /** What actually goes to the model, largest first. */
  images: StoredAttachment[];
  /** What happened, in a sentence someone can act on. Null when everything
   * referenced was read and sent. */
  note: string | null;
}

/** Downloads what `extractImageURLs` found, then sends only the biggest few.
 *
 * Size is the signal, and it is a better one than it sounds. A school calendar
 * is a full page of small print; a decorative strip is a few kilobytes. Nothing
 * here needs to recognise a calendar — it only needs to prefer documents over
 * ornaments, and bytes do that without a single filename heuristic. The one
 * real newsletter this was built against names its files `unnamed73175` and
 * `img023885`, so filename heuristics were never going to work anyway.
 *
 * Failures are collected rather than thrown. One unreachable picture must not
 * cost an email its extraction — the prose is still worth reading, and the note
 * says what was lost.
 */
export async function fetchRemoteImages(
  urls: string[],
  fetchImpl: typeof fetch = fetch
): Promise<RemoteImageResult> {
  if (urls.length === 0) return { images: [], note: null };

  const candidates: StoredAttachment[] = [];
  const problems: string[] = [];
  let decorations = 0;
  let downloadedBytes = 0;
  let stoppedEarly = false;

  for (const url of urls.slice(0, MAX_FETCHED)) {
    if (downloadedBytes >= MAX_TOTAL_BYTES) {
      stoppedEarly = true;
      break;
    }

    const label = shortLabel(url);
    try {
      const response = await fetchImpl(url, { redirect: "follow" });
      if (!response.ok) {
        problems.push(`${label}: the server returned HTTP ${response.status}`);
        continue;
      }

      const mediaType = (response.headers.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
      if (!SUPPORTED.has(mediaType)) {
        problems.push(`${label}: ${mediaType || "unknown type"} isn't an image we can read`);
        continue;
      }

      const bytes = new Uint8Array(await response.arrayBuffer());
      downloadedBytes += bytes.byteLength;

      if (bytes.byteLength > MAX_IMAGE_BYTES) {
        problems.push(`${label}: ${Math.round(bytes.byteLength / 1000)} KB is too large to send`);
        continue;
      }
      if (bytes.byteLength < MIN_IMAGE_BYTES) {
        decorations += 1;
        continue;
      }

      candidates.push({ filename: label, mediaType, data: base64(bytes) });
    } catch {
      problems.push(`${label}: couldn't be downloaded`);
    }
  }

  // Biggest first, then take the few that go to the model. `data` is base64,
  // so its length is proportional to the original — no need to keep the raw
  // byte count around just to sort by it.
  candidates.sort((a, b) => b.data.length - a.data.length);
  const images = candidates.slice(0, MAX_SENT);

  // Reported, not merely counted. The first version tallied decorations
  // silently, which is how four fetched images became zero sent images with
  // nothing on the record saying so.
  const unsent = candidates.length - images.length;
  const unlooked = Math.max(0, urls.length - MAX_FETCHED);

  const summary: string[] = [...problems];
  if (unsent > 0) {
    summary.push(`${unsent} smaller picture${unsent === 1 ? "" : "s"} weren't sent — only the ${MAX_SENT} largest are read`);
  }
  if (unlooked > 0 || stoppedEarly) {
    summary.push(
      `${unlooked} of ${urls.length} pictures weren't downloaded — forward any that matter on their own`
    );
  }
  if (decorations > 0 && images.length === 0) {
    // Only worth saying when nothing survived. Otherwise it is noise about
    // logos nobody wanted.
    summary.push(`${decorations} picture${decorations === 1 ? " was" : "s were"} too small to be a document`);
  }

  return { images, note: summary.length > 0 ? summary.join("\n") : null };
}

/** A filename the model and a person can both use. The last path segment is
 * usually descriptive ("september-calendar.png"); when it isn't, the host at
 * least says where it came from. */
function shortLabel(url: string): string {
  try {
    const parsed = new URL(url);
    const last = parsed.pathname.split("/").filter(Boolean).pop();
    return last && last.length > 1 ? decodeURIComponent(last).slice(0, 80) : parsed.hostname;
  } catch {
    return "image";
  }
}

/** Chunked because a single String.fromCharCode spread over a megabyte
 * overflows the argument limit — which shows up as a RangeError on exactly the
 * large images this exists to carry. */
function base64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
