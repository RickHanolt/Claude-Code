-- Record WHY an extraction failed.
--
-- Two emails sat at extraction_status='failed', attempts=3, with no indication
-- anywhere of the cause. The error text went to console.error, which reaches a
-- log stream nobody was watching at the time and which is gone by the time the
-- problem is noticed. Diagnosis came down to lining up failure timestamps
-- against deploy timestamps and inferring which parameter changed — that
-- worked, but it is not a method, and it took hours.
--
-- With the reason on the row, the same question is one SELECT away.
ALTER TABLE forwarded_emails ADD COLUMN extraction_error TEXT;

-- Give the emails that failed under the broken configuration a clean retry.
-- Safe to do unconditionally: extraction is idempotent at the event level now,
-- because layer-2 dedup matches new events against what the household already
-- has, so a re-extraction of a newsletter already processed adds nothing.
UPDATE forwarded_emails
SET extraction_status = 'pending', extraction_attempts = 0, extraction_error = NULL
WHERE extraction_status = 'failed';
