-- Duplicate suppression, in two layers.
--
-- Forwarding one newsletter twice created two forwarded_emails rows, each
-- extracted by its own model call, and every event appeared twice in the app
-- with subtly different wording. The extraction prompt's "merge duplicates"
-- rule can't help: it only ever sees one email at a time.

-- Layer 1: a content fingerprint per email, so an identical forward is
-- recognized on arrival and never stored or extracted a second time. Not
-- UNIQUE — SQLite can't add a unique column by ALTER, and the check belongs in
-- code anyway so a collision degrades to "store it" rather than to a 500 that
-- would bounce real school mail.
ALTER TABLE forwarded_emails ADD COLUMN content_hash TEXT;

CREATE INDEX idx_forwarded_emails_content_hash
  ON forwarded_emails(household_id, content_hash);

-- Layer 2 needs to scan a household's events by day, which this supports.
CREATE INDEX idx_candidate_events_household_start
  ON candidate_events(household_id, start_date);

-- Clean up the duplicates already sitting in the review screen: keep one row
-- per (household, day, title) and drop the rest. Titles are compared exactly
-- here because SQLite has no fuzzy matching — the two extraction runs produced
-- near-identical titles but differently worded notes, so this catches most of
-- them. Anything left is unchecked by hand once, and the code-side layers stop
-- it recurring.
DELETE FROM candidate_events
WHERE id NOT IN (
  SELECT MIN(id) FROM candidate_events
  GROUP BY household_id, date(start_date), lower(trim(title))
);
