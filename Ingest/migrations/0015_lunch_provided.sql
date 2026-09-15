-- Whether a meal was provided for a day, as a fact rather than an opinion.
--
-- Nullable on purpose, and NULL is not the same as 0. NULL means the document
-- said nothing (or the row predates this column); 0 means it positively said no
-- meal is coming and a lunch has to be packed. Collapsing those two would turn
-- every old row into a pack-a-lunch alert the moment this deployed.
ALTER TABLE candidate_exceptions ADD COLUMN lunch_provided INTEGER;
