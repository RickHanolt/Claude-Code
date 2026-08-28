-- Extraction moves out of the inbound-mail path and onto the app's poll.
--
-- Running an LLM call inside email() would put multiple seconds of latency
-- into the handler that decides whether Cloudflare accepts a message, and a
-- slow or failing API would start bouncing real school mail. Instead email()
-- stores the message immediately and marks it pending; handlePending()
-- extracts anything still pending before answering the app.
--
-- A failed extraction simply leaves the row 'pending', so the next poll
-- retries it. That is the whole retry mechanism — no queue, no cron.
ALTER TABLE forwarded_emails ADD COLUMN extraction_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE forwarded_emails ADD COLUMN extracted_at TEXT;

-- Rows that predate this migration were already processed by the old
-- chrono-node parser, so their candidate_events exist. Mark them done rather
-- than re-extracting (and duplicating) history.
UPDATE forwarded_emails SET extraction_status = 'done', extracted_at = received_at;

CREATE INDEX idx_forwarded_emails_extraction ON forwarded_emails(household_id, extraction_status);
