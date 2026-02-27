BEGIN;

UPDATE quiz_packages
SET difficulty = GREATEST(1, LEAST(3, difficulty))
WHERE difficulty < 1 OR difficulty > 3;

ALTER TABLE quiz_packages
  DROP CONSTRAINT IF EXISTS quiz_packages_difficulty_check;

ALTER TABLE quiz_packages
  ADD CONSTRAINT quiz_packages_difficulty_check
  CHECK (difficulty BETWEEN 1 AND 3);

COMMIT;
