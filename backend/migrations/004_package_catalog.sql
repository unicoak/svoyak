ALTER TABLE quiz_packages
  ADD COLUMN IF NOT EXISTS author_name TEXT NOT NULL DEFAULT '';

ALTER TABLE quiz_packages
  ADD COLUMN IF NOT EXISTS difficulty SMALLINT NOT NULL DEFAULT 3
  CHECK (difficulty BETWEEN 1 AND 5);

ALTER TABLE quiz_packages
  ADD COLUMN IF NOT EXISTS tags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];

CREATE INDEX IF NOT EXISTS idx_quiz_packages_published
  ON quiz_packages (is_published);

CREATE INDEX IF NOT EXISTS idx_quiz_packages_title_lower
  ON quiz_packages ((lower(title)));

CREATE INDEX IF NOT EXISTS idx_quiz_packages_author_lower
  ON quiz_packages ((lower(author_name)));

CREATE INDEX IF NOT EXISTS idx_quiz_packages_difficulty
  ON quiz_packages (difficulty);

UPDATE quiz_packages
SET
  author_name = 'Ася Самойлова',
  difficulty = 3,
  tags = ARRAY['крафт', 'командная', 'своя игра']
WHERE id = '88888888-8888-8888-8888-000000000002';

UPDATE quiz_packages
SET
  author_name = 'Demo Team',
  difficulty = 1,
  tags = ARRAY['demo', 'starter']
WHERE id = '22222222-2222-2222-2222-222222222222';
