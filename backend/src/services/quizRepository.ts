import { Pool } from "pg";
import { AcceptedAnswerRow, QuizPackageSummary, QuizQuestionRow } from "../types/quiz.js";

export class QuizRepository {
  constructor(private readonly pool: Pool) {}

  async getPackageById(packageId: string): Promise<QuizPackageSummary | null> {
    const result = await this.pool.query<QuizPackageSummary>(
      `
        SELECT
          id,
          title,
          language_code AS "languageCode",
          is_published AS "isPublished"
        FROM quiz_packages
        WHERE id = $1
      `,
      [packageId],
    );

    return result.rows[0] ?? null;
  }

  async getLatestPublishedPackage(): Promise<QuizPackageSummary | null> {
    const result = await this.pool.query<QuizPackageSummary>(
      `
        SELECT
          id,
          title,
          language_code AS "languageCode",
          is_published AS "isPublished"
        FROM quiz_packages
        WHERE is_published = TRUE
        ORDER BY updated_at DESC, created_at DESC
        LIMIT 1
      `,
    );

    return result.rows[0] ?? null;
  }

  async listQuestionsByPackage(packageId: string): Promise<QuizQuestionRow[]> {
    const result = await this.pool.query<QuizQuestionRow>(
      `
        SELECT
          id,
          round_no AS "roundNo",
          board_row AS "boardRow",
          board_col AS "boardCol",
          points,
          prompt,
          answer_display AS "answerDisplay",
          answer_time_limit_ms AS "answerTimeLimitMs"
        FROM questions
        WHERE package_id = $1
        ORDER BY round_no ASC, board_row ASC, board_col ASC
      `,
      [packageId],
    );

    return result.rows;
  }

  async getQuestionById(questionId: string): Promise<QuizQuestionRow | null> {
    const result = await this.pool.query<QuizQuestionRow>(
      `
        SELECT
          id,
          round_no AS "roundNo",
          board_row AS "boardRow",
          board_col AS "boardCol",
          points,
          prompt,
          answer_display AS "answerDisplay",
          answer_time_limit_ms AS "answerTimeLimitMs"
        FROM questions
        WHERE id = $1
      `,
      [questionId],
    );

    return result.rows[0] ?? null;
  }

  async getAcceptedAnswers(questionId: string): Promise<AcceptedAnswerRow[]> {
    const result = await this.pool.query<AcceptedAnswerRow>(
      `
        SELECT
          id,
          answer_raw AS "answerRaw",
          answer_norm AS "answerNorm",
          max_levenshtein AS "maxLevenshtein"
        FROM question_accepted_answers
        WHERE question_id = $1
      `,
      [questionId],
    );

    return result.rows;
  }
}
