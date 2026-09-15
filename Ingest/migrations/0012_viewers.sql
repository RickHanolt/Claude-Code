-- Read-only access for a second parent, a grandparent, a babysitter.
--
-- See VIEWER_MODE.md. One phone publishes a snapshot; other phones read it and
-- can send back reports, nothing else.
--
-- Everything a viewer touches is stored as an opaque blob. The payloads are
-- encrypted on the phone with a key that travels in a QR code and never reaches
-- this database, so the columns below are deliberately structureless: there is
-- nothing here to index on, query by, or accidentally log.

-- A single-use code, handed over as a QR, that a new viewer device redeems for
-- its own credential.
--
-- Single use because a QR code is a photograph: it can be screenshotted, left
-- on a table, or sent on. Redeeming it once and burning it means the thing
-- someone might capture is worthless by the time they'd use it.
CREATE TABLE viewer_invites (
  id TEXT PRIMARY KEY,
  household_id TEXT NOT NULL,
  code_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  redeemed_at TEXT,
  redeemed_by_device_id TEXT,
  FOREIGN KEY (household_id) REFERENCES households(id)
);

-- One row per viewing phone.
--
-- Per-device rather than one shared viewer key, so revoking a babysitter's
-- access doesn't also lock out a grandparent. The label is whatever the owner
-- typed when inviting ("Mum's iPhone") — it's how a row in a revoke list is
-- identified by a human, and it's the only thing here that isn't a hash or a
-- timestamp.
CREATE TABLE viewer_devices (
  id TEXT PRIMARY KEY,
  household_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  label TEXT,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT,
  FOREIGN KEY (household_id) REFERENCES households(id)
);

CREATE INDEX idx_viewer_devices_household ON viewer_devices(household_id, revoked_at);

-- The current snapshot, one per household.
--
-- No history. A snapshot is derived from the owner's local store, so an old one
-- has no evidentiary value — it can always be regenerated, and keeping copies
-- would only widen what a breach exposes.
--
-- version increments on every publish so a viewer can tell whether what it
-- holds is current, and so a report can name exactly what its author was
-- looking at.
CREATE TABLE household_snapshots (
  household_id TEXT PRIMARY KEY,
  payload TEXT NOT NULL,
  version INTEGER NOT NULL,
  published_at TEXT NOT NULL,
  FOREIGN KEY (household_id) REFERENCES households(id)
);

-- "This is wrong" from a viewer, going the other way.
--
-- The only thing a viewer may write. snapshot_version records which version the
-- report was made against, which is what separates "the lunch is wrong" from
-- "you were reading Monday's data on Wednesday".
CREATE TABLE viewer_reports (
  id TEXT PRIMARY KEY,
  household_id TEXT NOT NULL,
  viewer_device_id TEXT NOT NULL,
  payload TEXT NOT NULL,
  snapshot_version INTEGER,
  created_at TEXT NOT NULL,
  consumed_at TEXT,
  FOREIGN KEY (household_id) REFERENCES households(id),
  FOREIGN KEY (viewer_device_id) REFERENCES viewer_devices(id)
);

CREATE INDEX idx_viewer_reports_household ON viewer_reports(household_id, consumed_at);
