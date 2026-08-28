-- Repairs candidate_events rows the app cannot decode.
--
-- The extractor's schema told the model to include a time "only if the email
-- states one", so an all-day event came back as a bare `2026-09-09`. The iOS
-- client decodes with `.iso8601` (`ISO8601DateFormatter` in
-- `.withInternetDateTime` mode), which requires a time and an explicit offset,
-- and JSONDecoder fails the WHOLE response on one bad value — so a single
-- date-only row hid every email and every event behind "The data couldn't be
-- read because it isn't in the correct format."
--
-- src/extractor.ts now normalizes before inserting, but rows written before
-- that fix are still in the table and would keep breaking the response. This
-- repairs them in place with the same rules, deterministically and without
-- paying for a re-extraction.
--
-- Idempotent: every statement is scoped to rows not already in canonical form.

-- Date-only -> noon UTC. Noon rather than midnight because midnight renders as
-- the PREVIOUS day in any negative-offset timezone, which would silently move
-- an all-day event to the wrong date instead of merely failing loudly.
UPDATE candidate_events SET start_date = start_date || 'T12:00:00Z'
WHERE start_date LIKE '____-__-__' AND length(start_date) = 10;

UPDATE candidate_events SET end_date = end_date || 'T12:00:00Z'
WHERE end_date LIKE '____-__-__' AND length(end_date) = 10;

-- Naive datetime, no offset -> read as UTC, matching what the old chrono
-- parser produced in this Worker.
UPDATE candidate_events SET start_date = start_date || 'Z'
WHERE start_date LIKE '____-__-__T__:__:__' AND length(start_date) = 19;

UPDATE candidate_events SET end_date = end_date || 'Z'
WHERE end_date LIKE '____-__-__T__:__:__' AND length(end_date) = 19;

-- Minute precision, no seconds or offset.
UPDATE candidate_events SET start_date = start_date || ':00Z'
WHERE start_date LIKE '____-__-__T__:__' AND length(start_date) = 16;

UPDATE candidate_events SET end_date = end_date || ':00Z'
WHERE end_date LIKE '____-__-__T__:__' AND length(end_date) = 16;

-- An end_date that is still unrecoverable gets nulled rather than taking the
-- event down with it. A null end_date is already how this schema expresses
-- "all-day", so the event survives and reads correctly; only its end time is
-- lost, which for a school event is the less useful half.
UPDATE candidate_events SET end_date = NULL
WHERE end_date IS NOT NULL
  AND NOT (
    (end_date LIKE '____-__-__T__:__:__Z' AND length(end_date) = 20)
    OR (end_date LIKE '____-__-__T__:__:__.___Z' AND length(end_date) = 24)
  );

-- A start_date still not in one of the two decodable forms is unrecoverable
-- here (free text, a garbled year, an offset shape SQLite can't fix
-- arithmetically). Deleting is the right call rather than leaving it: the app
-- can't render the row either way, and while it exists it blocks every other
-- pending item. The source email is untouched and still listed in the Emails
-- tab, so nothing is actually lost.
DELETE FROM candidate_events
WHERE NOT (
  (start_date LIKE '____-__-__T__:__:__Z' AND length(start_date) = 20)
  OR (start_date LIKE '____-__-__T__:__:__.___Z' AND length(start_date) = 24)
);
