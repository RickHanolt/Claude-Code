-- One household per family using SchoolSync's email auto-forward feature.
-- ingest_slug is the local part of the receiving address
-- (e.g. "hanolt-a1b2c3" for hanolt-a1b2c3@mail.yourdomain.com).
-- Only api_key_hash is stored; the raw API key is shown once at
-- provisioning time and can't be recovered.
CREATE TABLE households (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  ingest_slug TEXT NOT NULL UNIQUE,
  api_key_hash TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Every email received at a household's ingest address, in full — mirrors
-- ForwardedEmailRecord on-device, pulled down by the app and stored there.
CREATE TABLE forwarded_emails (
  id TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id),
  sender TEXT,
  subject TEXT NOT NULL,
  body_text TEXT NOT NULL,
  received_at TEXT NOT NULL,
  consumed_at TEXT
);
CREATE INDEX idx_forwarded_emails_household ON forwarded_emails(household_id, consumed_at);

-- Date candidates the heuristic found in a forwarded email, awaiting the
-- app's confirmation screen. One email can produce zero or more of these.
CREATE TABLE candidate_events (
  id TEXT PRIMARY KEY,
  forwarded_email_id TEXT NOT NULL REFERENCES forwarded_emails(id),
  household_id TEXT NOT NULL REFERENCES households(id),
  title TEXT NOT NULL,
  start_date TEXT NOT NULL,
  end_date TEXT,
  notes TEXT,
  consumed_at TEXT
);
CREATE INDEX idx_candidate_events_household ON candidate_events(household_id, consumed_at);
