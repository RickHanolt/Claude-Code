/**
 * Asserts which attachments are sent to the model and which are skipped.
 *
 * The risk here runs one way. Sending something extra costs tokens and is
 * visible on the bill. Skipping something wrongly means a school's year
 * calendar never reaches the app and nobody ever finds out — the email looks
 * processed, the events simply aren't there. That's the failure this covers.
 */
import { attachmentBlocks, selectAttachment, type AttachmentDecision } from "../src/attachments";

let failures = 0;

/** The media type of a kept attachment, or undefined if it was skipped. */
function kept(decision: AttachmentDecision): string | undefined {
  return decision.kind === "keep" ? decision.attachment.mediaType : undefined;
}

/** The skip reason, or undefined if the attachment was kept. */
function skipReason(decision: AttachmentDecision): string | undefined {
  return decision.kind === "skip" ? decision.reason : undefined;
}

function check(name: string, actual: unknown, expected: unknown) {
  if (actual !== expected) {
    console.error(`${name}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    failures += 1;
  }
}

const big = "A".repeat(500_000);
const tiny = "A".repeat(1_000);

// --- accepted --------------------------------------------------------------

check(
  "a page-sized PNG is accepted",
  kept(selectAttachment({ filename: "calendar.png", mimeType: "image/png", content: big })),
  "image/png"
);

check(
  "a PDF is accepted",
  kept(selectAttachment({ filename: "year.pdf", mimeType: "application/pdf", content: big })),
  "application/pdf"
);

// A PDF is never a tracking pixel, so it has no size floor — a one-page text
// PDF is legitimately small.
check(
  "a small PDF is still accepted",
  kept(selectAttachment({ filename: "note.pdf", mimeType: "application/pdf", content: tiny })),
  "application/pdf"
);

// Mailers write this constantly and the API does not accept it.
check(
  "image/jpg is normalized to image/jpeg",
  kept(selectAttachment({ filename: "flyer.jpg", mimeType: "image/jpg", content: big })),
  "image/jpeg"
);

check(
  "media type parameters are ignored",
  kept(selectAttachment({ filename: "c.png", mimeType: 'image/png; name="c.png"', content: big })),
  "image/png"
);

// --- skipped ---------------------------------------------------------------

check(
  "a signature logo is skipped",
  selectAttachment({ filename: "logo.png", mimeType: "image/png", content: tiny }).kind,
  "skip"
);

check(
  "an oversized scan is skipped",
  selectAttachment({ filename: "packet.pdf", mimeType: "application/pdf", content: "A".repeat(2_000_000) }).kind,
  "skip"
);

check(
  "an unreadable type is skipped",
  selectAttachment({ filename: "roster.xlsx", mimeType: "application/vnd.ms-excel", content: big }).kind,
  "skip"
);

check(
  "a non-base64 payload is skipped rather than guessed at",
  selectAttachment({ filename: "c.png", mimeType: "image/png", content: new ArrayBuffer(500_000) }).kind,
  "skip"
);

// --- skip reasons ----------------------------------------------------------
//
// A skip is only better than a silent drop if the reason survives to somewhere
// a person will see it. These assert the reason exists and names the file, so
// a future refactor can't quietly go back to dropping the explanation.

check(
  "an HEIC photo is skipped by type",
  skipReason(selectAttachment({ filename: "IMG_4821.HEIC", mimeType: "image/heic", content: big }))?.includes("image/heic"),
  true
);

// The failure mode this whole change exists for: a forwarded phone photo
// yields nothing, and the reason has to say what to do differently.
check(
  "the HEIC reason says how to resend",
  skipReason(selectAttachment({ filename: "IMG_4821.HEIC", mimeType: "image/heic", content: big }))?.includes("PNG"),
  true
);

check(
  "a skip reason names the file",
  skipReason(selectAttachment({ filename: "roster.xlsx", mimeType: "application/vnd.ms-excel", content: big }))?.includes("roster.xlsx"),
  true
);

// Sizes are reported in the units of the thing the sender chose, not in base64
// characters — "1.5 MB is over the 900 KB limit" is actionable, "2000000" is
// not.
check(
  "an oversized skip reports an approximate original size",
  skipReason(selectAttachment({ filename: "packet.pdf", mimeType: "application/pdf", content: "A".repeat(2_000_000) }))?.includes("1.5 MB"),
  true
);

check(
  "a missing filename doesn't produce an unreadable reason",
  skipReason(selectAttachment({ filename: null, mimeType: "image/heic", content: big }))?.startsWith("(unnamed)"),
  true
);

// --- block shapes ----------------------------------------------------------

const pdfBlocks = attachmentBlocks({ filename: "year.pdf", mediaType: "application/pdf", data: "AAA" });
check("a PDF becomes a document block", pdfBlocks[1].type, "document");
check("the document block is labelled", pdfBlocks[0].type, "text");
check(
  "the label names the file",
  (pdfBlocks[0] as { text: string }).text.includes("year.pdf"),
  true
);

const imageBlocks = attachmentBlocks({ filename: "c.png", mediaType: "image/png", data: "AAA" });
check("an image becomes an image block", imageBlocks[1].type, "image");
check(
  "the image carries its media type",
  (imageBlocks[1] as { source: { media_type: string } }).source.media_type,
  "image/png"
);

if (failures > 0) {
  console.error(`${failures} attachment failure(s).`);
  process.exit(1);
}

console.log("Attachments: all cases OK.");
