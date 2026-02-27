import { AcceptedAnswer, QuestionSnapshot } from "./room.js";

export interface QuizPackageSummary {
  id: string;
  title: string;
  languageCode: string;
  isPublished: boolean;
}

export interface QuizQuestionRow extends QuestionSnapshot {}

export interface AcceptedAnswerRow extends AcceptedAnswer {}
