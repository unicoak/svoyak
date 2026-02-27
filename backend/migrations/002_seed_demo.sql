INSERT INTO users (id, username, display_name, email)
VALUES
  (
    '11111111-1111-1111-1111-111111111111',
    'demo_host',
    'Demo Host',
    'demo@example.com'
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
  version
)
VALUES
  (
    '22222222-2222-2222-2222-222222222222',
    '11111111-1111-1111-1111-111111111111',
    'Demo Svoyak Pack',
    'Starter package for local MVP checks',
    'ru',
    'public',
    TRUE,
    1
  )
ON CONFLICT (id) DO NOTHING;

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
VALUES
  (
    '33333333-3333-3333-3333-333333333333',
    '22222222-2222-2222-2222-222222222222',
    1,
    1,
    1,
    100,
    'Столица Франции?',
    'Париж',
    5000
  ),
  (
    '44444444-4444-4444-4444-444444444444',
    '22222222-2222-2222-2222-222222222222',
    1,
    1,
    2,
    200,
    '2 + 2 = ?',
    '4',
    5000
  )
ON CONFLICT (id) DO NOTHING;

INSERT INTO question_accepted_answers (id, question_id, answer_raw, answer_norm, max_levenshtein)
VALUES
  (
    '55555555-5555-5555-5555-555555555555',
    '33333333-3333-3333-3333-333333333333',
    'Париж',
    'париж',
    1
  ),
  (
    '66666666-6666-6666-6666-666666666666',
    '44444444-4444-4444-4444-444444444444',
    '4',
    '4',
    0
  )
ON CONFLICT (id) DO NOTHING;
