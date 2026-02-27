import { AcceptedAnswer } from "../types/room.js";

export interface AnswerMatch {
  isCorrect: boolean;
  normalizedInput: string;
  matchedAnswerId: string | null;
  distance: number | null;
  threshold: number | null;
}

export const normalizeAnswer = (input: string): string =>
  input
    .toLowerCase()
    .replace(/ё/g, "е")
    .replace(/[\p{P}\p{S}]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();

export const levenshteinDistance = (left: string, right: string): number => {
  if (left === right) {
    return 0;
  }

  if (left.length === 0) {
    return right.length;
  }

  if (right.length === 0) {
    return left.length;
  }

  const prev = new Array<number>(right.length + 1);
  const curr = new Array<number>(right.length + 1);

  for (let j = 0; j <= right.length; j += 1) {
    prev[j] = j;
  }

  for (let i = 1; i <= left.length; i += 1) {
    curr[0] = i;

    for (let j = 1; j <= right.length; j += 1) {
      const substitutionCost = left[i - 1] === right[j - 1] ? 0 : 1;
      curr[j] = Math.min(
        prev[j] + 1,
        curr[j - 1] + 1,
        prev[j - 1] + substitutionCost,
      );
    }

    for (let j = 0; j <= right.length; j += 1) {
      prev[j] = curr[j];
    }
  }

  return prev[right.length];
};

export const evaluateAnswer = (input: string, acceptedAnswers: AcceptedAnswer[]): AnswerMatch => {
  const normalizedInput = normalizeAnswer(input);

  if (!normalizedInput || acceptedAnswers.length === 0) {
    return {
      isCorrect: false,
      normalizedInput,
      matchedAnswerId: null,
      distance: null,
      threshold: null,
    };
  }

  let bestDistance = Number.POSITIVE_INFINITY;
  let matchedAnswer: AcceptedAnswer | null = null;

  for (const accepted of acceptedAnswers) {
    const distance = levenshteinDistance(normalizedInput, accepted.answerNorm);
    if (distance < bestDistance) {
      bestDistance = distance;
      matchedAnswer = accepted;
    }
  }

  if (!matchedAnswer) {
    return {
      isCorrect: false,
      normalizedInput,
      matchedAnswerId: null,
      distance: null,
      threshold: null,
    };
  }

  const threshold = matchedAnswer.maxLevenshtein;

  return {
    isCorrect: bestDistance <= threshold,
    normalizedInput,
    matchedAnswerId: matchedAnswer.id,
    distance: bestDistance,
    threshold,
  };
};
