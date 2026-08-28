/**
 * Asserts which attachments are sent to the model and which are skipped.
 *
 * The risk here runs one way. Sending something extra costs tokens and is
 * visible on the bill. Skipping something wrongly means a school's year
 * calendar never reaches the app and nobody ever finds out — the email looks
 * processed, the events simply aren't there. That's the failure this covers.
 */
import { attachmentBlocks, selectAttachment } from "../src/attachments";

let failures = 0;

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
  selectAttachment({ filename: "calendar.png", mimeType: "image/png", content: big })?.mediaType,
  "image/png"
);

check(
  "a PDF is accepted",
  selectAttachment({ filename: "year.pdf", mimeType: "application/pdf", content: big })?.mediaType,
  "application/pdf"
);

// A PDF is never a tracking pixel, so it has no size floor — a one-page text
// PDF is legitimately small.
check(
  "a small PDF is still accepted",
  selectAttachment({ filename: "note.pdf", mimeType: "application/pdf", content: tiny })?.mediaType,
  "application/pdf"
);

// Mailers write this constantly and the API does not accept it.
check(
  "image/jpg is normalized to image/jpeg",
  selectAttachment({ filename: "flyer.jpg", mimeType: "image/jpg", content: big })?.mediaType,
  "image/jpeg"
);

check(
  "media type parameters are ignored",
  selectAttachment({ filename: "c.png", mimeType: 'image/png; name="c.png"', content: big })?.mediaType,
  "image/png"
);

// --- skipped ---------------------------------------------------------------

check(
  "a signature logo is skipped",
  selectAttachment({ filename: "logo.png", mimeType: "image/png", content: tiny }),
  null
);

check(
  "an oversized scan is skipped",
  selectAttachment({ filename: "packet.pdf", mimeType: "application/pdf", content: "A".repeat(2_000_000) }),
  null
);

check(
  "an unreadable type is skipped",
  selectAttachment({ filename: "roster.xlsx", mimeType: "application/vnd.ms-excel", content: big }),
  null
);

check(
  "a non-base64 payload is skipped rather than guessed at",
  selectAttachment({ filename: "c.png", mimeType: "image/png", content: new ArrayBuffer(500_000) }),
  null
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
