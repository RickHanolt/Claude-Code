-- Attachments, so extraction can read them.
--
-- A forwarded school email carried an FSA event calendar and a year-at-a-glance
-- PDF listing roughly sixty dates between them. None could reach the app:
-- extraction only ever saw parsed.text, and attachments were parsed and thrown
-- away. The prose in the body was the small half of the email.
--
-- Stored as base64 rather than BLOB because that's the form the Messages API
-- takes and the form postal-mime can emit directly — converting in either
-- direction would only add a place to corrupt bytes.
--
-- Kept after extraction rather than deleted. They're the only copy of that
-- flyer we hold, and keeping them means a future prompt improvement can be
-- re-run over the same input instead of needing the email forwarded again.
CREATE TABLE email_attachments (
  id TEXT PRIMARY KEY,
  forwarded_email_id TEXT NOT NULL,
  household_id TEXT NOT NULL,
  filename TEXT,
  media_type TEXT NOT NULL,
  data TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (forwarded_email_id) REFERENCES forwarded_emails(id)
);

CREATE INDEX idx_email_attachments_email ON email_attachments(forwarded_email_id);
