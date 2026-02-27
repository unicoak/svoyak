import { AcceptedAnswer, QuestionSnapshot } from "./room.js";

export interface QuizPackageSummary {
  id: string;
  title: string;
  languageCode: string;
  isPublished: boolean;
}

export interface QuizPackageCatalogItem extends QuizPackageSummary {
  authorName: string;
  difficulty: number;
  questionsCount: number;
}

export interface QuizQuestionRow extends QuestionSnapshot {}

export interface AcceptedAnswerRow extends AcceptedAnswer {}
