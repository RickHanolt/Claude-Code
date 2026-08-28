/**
 * Email attachments as extraction input.
 *
 * A real school email carries its most valuable content as attachments: the
 * FSA event calendar and the year-at-a-glance PDF between them list around
 * sixty dates, and none of them could reach the app because extraction only
 * ever saw `parsed.text`. The prose in the email body is the small half.
 *
 * This is the same capability the Boonli month screenshot and the Pulaski
 * semester PDF need, so it isn't a detour.
 */

/** What Claude can actually read. Anything else — .docx, .xlsx, .zip, a
 * calendar .ics — is skipped rather than sent and rejected. */
const SUPPORTED_IMAGE_TYPES = ["image/jpeg", "image/png", "image/gif", "image/webp"] as const;
const PDF_TYPE = "application/pdf";

type SupportedImageType = (typeof SUPPORTED_IMAGE_TYPES)[number];

/** Base64 length cap per attachment, ~900KB of original bytes.
 *
 * Two things are being bounded, and the tighter one wins: D1's per-value
 * ceiling, and the input-token cost of handing a large scan to Opus. A
 * one-page flyer or a year calendar sits far below this; anything above it is
 * a photo album or a scanned packet, and silently skipping with a log beats
 * either a failed insert or a surprise bill. */
const MAX_BASE64_LENGTH = 1_200_000;

/** Images below this are signature logos, social icons and tracking pixels,
 * which every school email carries and none of which contain a date. Cost
 * guard, not a correctness rule — a legible calendar page is never this small.
 * PDFs get no such floor: a PDF is never a tracking pixel. */
const MIN_IMAGE_BASE64_LENGTH = 20_000;

export interface StoredAttachment {
  filename: string | null;
  mediaType: string;
  data: string;
}

/** What happened to one MIME part, including why it was left out.
 *
 * The reason used to be a bare `null` return. A Boonli month screenshot was
 * forwarded, produced no events and no exceptions, and the review screen said
 * "No dates found in this email" — which is also what it says when the model
 * read the page and genuinely found nothing. Two entirely different situations
 * rendering identically, with the explanation discarded at the point it was
 * known. That is the same failure as an extraction that recorded no error, and
 * it cost the same thing: a person having to ask what happened.
 *
 * Reasons are written for whoever has to act on them, not for a log grep. */
export type AttachmentDecision =
  | { kind: "keep"; attachment: StoredAttachment }
  | { kind: "skip"; reason: string };

/** Approximate original size from a base64 length, for a message a person
 * reads. Base64 runs 4 characters per 3 bytes. */
function sizeLabel(base64Length: number): string {
  const bytes = Math.round((base64Length * 3) / 4);
  return bytes >= 1_000_000
    ? `${(bytes / 1_000_000).toFixed(1)} MB`
    : `${Math.max(1, Math.round(bytes / 1000))} KB`;
}

/** Narrows a parsed MIME part to something worth storing. `content` is typed
 * as a union because postal-mime's encoding is configurable; anything that
 * isn't the base64 string we asked for is skipped rather than guessed at. */
export function selectAttachment(part: {
  filename: string | null;
  mimeType: string;
  content: ArrayBuffer | Uint8Array | string;
}): AttachmentDecision {
  // Strip any parameters ("image/png; name=calendar.png") and normalize the
  // one spelling mailers get wrong often enough to matter: image/jpg is not a
  // media type the API accepts, and dropping a school's calendar over a
  // three-letter alias would be an absurd way to lose a date.
  const declared = part.mimeType?.toLowerCase().split(";")[0]?.trim() ?? "";
  const mediaType = declared === "image/jpg" ? "image/jpeg" : declared;
  const name = part.filename?.trim() || "(unnamed)";

  const isImage = (SUPPORTED_IMAGE_TYPES as readonly string[]).includes(mediaType);
  const isPdf = mediaType === PDF_TYPE;

  if (!isImage && !isPdf) {
    // The case that actually bites: an iPhone photo forwarded as HEIC. The
    // API does not accept it and a Worker has no way to transcode it, so the
    // only useful thing to do is say so in a sentence that names the fix.
    return {
      kind: "skip",
      reason: `${name}: ${mediaType || "unknown file type"} can't be read — resend as PNG, JPEG or PDF`,
    };
  }

  if (typeof part.content !== "string") {
    return { kind: "skip", reason: `${name}: attachment was not base64-encoded` };
  }

  if (part.content.length > MAX_BASE64_LENGTH) {
    return {
      kind: "skip",
      reason: `${name}: ${sizeLabel(part.content.length)} is over the ${sizeLabel(MAX_BASE64_LENGTH)} limit — resend it choosing a smaller image size`,
    };
  }

  if (isImage && part.content.length < MIN_IMAGE_BASE64_LENGTH) {
    return {
      kind: "skip",
      reason: `${name}: ${sizeLabel(part.content.length)} is too small to be a document — treated as a logo`,
    };
  }

  return { kind: "keep", attachment: { filename: part.filename, mediaType, data: part.content } };
}

/** The content blocks for one attachment, in the shape the Messages API takes.
 * PDFs go as `document` (the model reads the pages, text and layout both),
 * images as `image`.
 *
 * Each is preceded by a text block naming the file. Without it, several
 * attachments arrive as an unlabelled pile and the model can't say which
 * calendar a date came from — which matters as soon as one email carries both
 * a school-wide calendar and a single club's flyer. */
export function attachmentBlocks(attachment: StoredAttachment): Array<
  | { type: "text"; text: string }
  | { type: "image"; source: { type: "base64"; media_type: SupportedImageType; data: string } }
  | { type: "document"; source: { type: "base64"; media_type: "application/pdf"; data: string } }
> {
  const label = {
    type: "text" as const,
    text: `Attachment: ${attachment.filename ?? "(unnamed)"}`,
  };

  if (attachment.mediaType === PDF_TYPE) {
    return [
      label,
      {
        type: "document",
        source: { type: "base64", media_type: "application/pdf", data: attachment.data },
      },
    ];
  }

  return [
    label,
    {
      type: "image",
      source: {
        type: "base64",
        media_type: attachment.mediaType as SupportedImageType,
        data: attachment.data,
      },
    },
  ];
}
