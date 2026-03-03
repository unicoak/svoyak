import { Pool } from "pg";
import {
  AcceptedAnswerRow,
  QuizPackageCatalogItem,
  QuizPackageSummary,
  QuizQuestionRow,
} from "../types/quiz.js";

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
          LEAST(50, GREATEST(10, board_col * 10))::int AS points,
          prompt,
          answer_display AS "answerDisplay",
          answer_comment AS "answerComment",
          answer_time_limit_ms AS "answerTimeLimitMs"
        FROM questions
        WHERE package_id = $1
        ORDER BY round_no ASC, board_row ASC, board_col ASC
      `,
      [packageId],
    );

    return result.rows;
  }

  async listPublishedPackages(options?: {
    query?: string;
    difficulty?: number;
    limit?: number;
  }): Promise<QuizPackageCatalogItem[]> {
    const query = options?.query?.trim() || null;
    const difficulty = options?.difficulty ?? null;
    const limit = Math.max(1, Math.min(options?.limit ?? 20, 50));

    const result = await this.pool.query<QuizPackageCatalogItem>(
      `
        SELECT
          p.id,
          p.title,
          p.language_code AS "languageCode",
          p.is_published AS "isPublished",
          p.author_name AS "authorName",
          p.difficulty,
          COUNT(q.id)::int AS "questionsCount"
        FROM quiz_packages p
        LEFT JOIN questions q ON q.package_id = p.id
        WHERE p.is_published = TRUE
          AND p.visibility = 'public'
          AND (
            $1::text IS NULL
            OR p.title ILIKE '%' || $1 || '%'
            OR p.author_name ILIKE '%' || $1 || '%'
          )
          AND ($2::smallint IS NULL OR p.difficulty = $2)
        GROUP BY p.id
        HAVING COUNT(q.id) >= 20
          AND COUNT(q.id) <= 40
          AND COUNT(DISTINCT q.round_no) = 1
          AND MIN(q.round_no) = 1
          AND COUNT(DISTINCT q.board_row) BETWEEN 4 AND 8
          AND COUNT(q.id) = COUNT(DISTINCT q.board_row) * 5
          AND COUNT(*) FILTER (WHERE q.board_col BETWEEN 1 AND 5) = COUNT(q.id)
          AND COUNT(DISTINCT (q.board_row, q.board_col)) = COUNT(q.id)
        ORDER BY p.updated_at DESC, p.created_at DESC
        LIMIT $3
      `,
      [query, difficulty, limit],
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
          LEAST(50, GREATEST(10, board_col * 10))::int AS points,
          prompt,
          answer_display AS "answerDisplay",
          answer_comment AS "answerComment",
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
