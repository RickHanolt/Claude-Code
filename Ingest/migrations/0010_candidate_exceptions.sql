-- Days where a kid's routine doesn't hold, extracted from a document.
--
-- Separate from candidate_events because they answer different questions. An
-- event is something on the calendar at a time; an exception is "what does this
-- kid need today" differing from their baseline. "Pizza day - no lunch needed"
-- is not a calendar entry anyone wants; it's a change to one field of one
-- morning.
--
-- A Boonli month produces twenty of these and zero events, which is why
-- extraction could not usefully read one before: there was no shape to put the
-- answer in.
--
-- No kid column, deliberately. Kid identity lives in the app, not here — the
-- backend has never known which child an email belongs to, and the review
-- screen already asks. Exceptions inherit that answer by riding along with
-- their source email, exactly as candidate events do.
CREATE TABLE candidate_exceptions (
  id TEXT PRIMARY KEY,
  forwarded_email_id TEXT NOT NULL,
  household_id TEXT NOT NULL,
  day TEXT NOT NULL,
  field TEXT NOT NULL,
  value TEXT NOT NULL,
  is_notable INTEGER NOT NULL DEFAULT 1,
  note TEXT,
  consumed_at TEXT,
  FOREIGN KEY (forwarded_email_id) REFERENCES forwarded_emails(id)
);

CREATE INDEX idx_candidate_exceptions_household
  ON candidate_exceptions(household_id, consumed_at);
