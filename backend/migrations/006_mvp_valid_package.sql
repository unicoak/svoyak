BEGIN;

INSERT INTO users (id, username, display_name)
VALUES (
  '99999999-9999-9999-9999-000000000001',
  'mvp_author',
  'Svoyak MVP'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO quiz_packages (
  id,
  owner_user_id,
  title,
  description,
  language_code,
  visibility,
  is_published,
  version,
  author_name,
  difficulty,
  tags
)
VALUES (
  '99999999-9999-9999-9999-000000000002',
  '99999999-9999-9999-9999-000000000001',
  'MVP Starter 4x5',
  'Страховочный пакет для проверки механики: 4 темы × 5 вопросов.',
  'ru',
  'public',
  TRUE,
  1,
  'Svoyak Team',
  1,
  ARRAY['mvp', 'starter', '4x5']
)
ON CONFLICT (id) DO NOTHING;

WITH generated AS (
  SELECT
    row_no::smallint AS round_no,
    row_no::smallint AS board_row,
    board_col::smallint AS board_col,
    (board_col * 100)::smallint AS points,
    format('Сколько будет %s + %s?', row_no, board_col) AS prompt,
    (row_no + board_col)::text AS answer_text,
    (
      '99999999-9999-9999-9999-' ||
      lpad((row_no * 100 + board_col)::text, 12, '0')
    )::uuid AS question_id,
    (
      '99999999-9999-9999-aaaa-' ||
      lpad((row_no * 100 + board_col)::text, 12, '0')
    )::uuid AS answer_id
  FROM generate_series(1, 4) AS row_no
  CROSS JOIN generate_series(1, 5) AS board_col
)
INSERT INTO questions (
  id,
  package_id,
  round_no,
  board_row,
  board_col,
  points,
  prompt,
  answer_display,
  answer_time_limit_ms
)
SELECT
  question_id,
  '99999999-9999-9999-9999-000000000002',
  1,
  board_row,
  board_col,
  points,
  prompt,
  answer_text,
  5000
FROM generated
ON CONFLICT (id) DO NOTHING;

WITH generated AS (
  SELECT
    (
      '99999999-9999-9999-9999-' ||
      lpad((row_no * 100 + board_col)::text, 12, '0')
    )::uuid AS question_id,
    (
      '99999999-9999-9999-aaaa-' ||
      lpad((row_no * 100 + board_col)::text, 12, '0')
    )::uuid AS answer_id,
    (row_no + board_col)::text AS answer_text
  FROM generate_series(1, 4) AS row_no
  CROSS JOIN generate_series(1, 5) AS board_col
)
INSERT INTO question_accepted_answers (
  id,
  question_id,
  answer_raw,
  answer_norm,
  max_levenshtein
)
SELECT
  answer_id,
  question_id,
  answer_text,
  answer_text,
  0
FROM generated
ON CONFLICT (id) DO NOTHING;

COMMIT;
