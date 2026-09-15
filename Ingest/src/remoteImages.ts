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

/** How many to fetch from one email. A newsletter references dozens of
 * pictures — logos, buttons, a LEGO stock photo — and one or two of them are
 * the calendar. Past a handful we are paying to read decorations. */
const MAX_IMAGES = 4;

/** Per image, before base64. Roughly the same ceiling the attachment path
 * uses, expressed in real bytes because here we control the fetch. */
const MAX_IMAGE_BYTES = 1_350_000;

/** Below this it is a logo, an icon, or a tracking pixel — the same floor the
 * attachment path applies, and for the same reason: a legible calendar page is
 * never this small. */
const MIN_IMAGE_BYTES = 15_000;

const SUPPORTED = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"]);

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

    const key = parsed.toString();
    if (seen.has(key)) continue;
    seen.add(key);
    urls.push(key);
  }

  return urls;
}

export interface RemoteImageResult {
  images: StoredAttachment[];
  /** Why the ones that didn't make it didn't, in a sentence someone can act
   * on. Null when every referenced image was read, or none were referenced. */
  note: string | null;
}

/** Fetches what `extractImageURLs` found, within the bounds above.
 *
 * Failures are collected rather than thrown. One unreachable picture must not
 * cost an email its extraction — the prose is still worth reading, and the
 * note says what was lost.
 */
export async function fetchRemoteImages(
  urls: string[],
  fetchImpl: typeof fetch = fetch
): Promise<RemoteImageResult> {
  if (urls.length === 0) return { images: [], note: null };

  const images: StoredAttachment[] = [];
  const problems: string[] = [];
  let skippedAsDecoration = 0;

  for (const url of urls.slice(0, MAX_IMAGES)) {
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
      if (bytes.byteLength > MAX_IMAGE_BYTES) {
        problems.push(`${label}: ${Math.round(bytes.byteLength / 1000)} KB is too large to send`);
        continue;
      }
      // Counted, not listed. Every newsletter references a dozen logos and
      // naming each one would bury the one line that matters.
      if (bytes.byteLength < MIN_IMAGE_BYTES) {
        skippedAsDecoration += 1;
        continue;
      }

      images.push({ filename: label, mediaType, data: base64(bytes) });
    } catch (error) {
      problems.push(`${label}: couldn't be downloaded`);
    }
  }

  const beyondCap = urls.length - Math.min(urls.length, MAX_IMAGES);
  if (beyondCap > 0) {
    problems.push(`${beyondCap} more picture${beyondCap === 1 ? "" : "s"} weren't read — forward any that matter on their own`);
  }

  return { images, note: problems.length > 0 ? problems.join("\n") : null };
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
