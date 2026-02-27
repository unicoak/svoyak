CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username CITEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  email CITEXT UNIQUE,
  avatar_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TYPE package_visibility AS ENUM ('private', 'unlisted', 'public');

CREATE TABLE quiz_packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  language_code TEXT NOT NULL DEFAULT 'ru',
  visibility package_visibility NOT NULL DEFAULT 'private',
  is_published BOOLEAN NOT NULL DEFAULT FALSE,
  version INT NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_quiz_packages_owner ON quiz_packages(owner_user_id);

CREATE TRIGGER trg_quiz_packages_updated_at
BEFORE UPDATE ON quiz_packages
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE questions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id UUID NOT NULL REFERENCES quiz_packages(id) ON DELETE CASCADE,
  round_no SMALLINT NOT NULL DEFAULT 1 CHECK (round_no BETWEEN 1 AND 3),
  board_row SMALLINT NOT NULL CHECK (board_row BETWEEN 1 AND 6),
  board_col SMALLINT NOT NULL CHECK (board_col BETWEEN 1 AND 5),
  points INT NOT NULL CHECK (points > 0),
  prompt TEXT NOT NULL,
  answer_display TEXT NOT NULL,
  answer_time_limit_ms INT NOT NULL DEFAULT 5000 CHECK (answer_time_limit_ms BETWEEN 1000 AND 60000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (package_id, round_no, board_row, board_col)
);

CREATE INDEX idx_questions_package_round ON questions(package_id, round_no);

CREATE TRIGGER trg_questions_updated_at
BEFORE UPDATE ON questions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE question_accepted_answers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id UUID NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  answer_raw TEXT NOT NULL,
  answer_norm TEXT NOT NULL,
  max_levenshtein SMALLINT NOT NULL DEFAULT 1 CHECK (max_levenshtein BETWEEN 0 AND 5),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (question_id, answer_norm)
);

CREATE INDEX idx_question_accepted_answers_qid ON question_accepted_answers(question_id);
