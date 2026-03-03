import { QuestionSnapshot, RoomState } from "../types/room.js";

const clamp = (value: number, min: number, max: number): number =>
  Math.max(min, Math.min(max, value));

export const resetBuzzerState = (room: RoomState, state: "CLOSED" | "OPEN" | "LOCKED"): void => {
  room.game.buzzer.state = state;
  room.game.buzzer.readStartedAtServerMs = null;
  room.game.buzzer.readEndsAtServerMs = null;
  room.game.buzzer.openAtServerMs = null;
  room.game.buzzer.closeAtServerMs = null;
  room.game.buzzer.openedAtServerMs = state === "OPEN" ? Date.now() : null;
  room.game.buzzer.resolveAtServerMs = null;
  room.game.buzzer.winnerUserId = null;
  room.game.buzzer.attempts = [];

  if (state !== "LOCKED") {
    room.game.answering.activeUserId = null;
    room.game.answering.deadlineServerMs = null;
    room.game.answering.draftAnswerText = "";
    room.game.answering.pausedReadRemainingMs = null;
    room.game.answering.pausedCloseRemainingMs = null;
  }
};

export const openQuestion = (room: RoomState, question: QuestionSnapshot): void => {
  const revealDurationMs = Math.max(1, question.revealDurationMs ?? 1);
  room.status = "QUESTION_OPEN";
  room.game.currentQuestion = {
    ...question,
    revealDurationMs,
    revealedMs: clamp(question.revealedMs ?? 0, 0, revealDurationMs),
    revealResumedAtServerMs: question.revealResumedAtServerMs ?? Date.now(),
  };
  room.game.autoNextQuestionAtServerMs = null;
  room.game.board.remainingQuestionIds = room.game.board.remainingQuestionIds.filter((id) => id !== question.id);

  for (const player of Object.values(room.players)) {
    player.canBuzz = true;
  }

  room.game.buzzer.lockedOutUserIds = [];
  resetBuzzerState(room, "CLOSED");
};

export const lockBuzzerWinner = (room: RoomState, winnerUserId: string): void => {
  room.status = "ANSWERING";
  room.game.buzzer.state = "LOCKED";
  room.game.buzzer.winnerUserId = winnerUserId;
  room.game.answering.activeUserId = winnerUserId;
  room.game.answering.draftAnswerText = "";

  const timeLimit = room.game.currentQuestion?.answerTimeLimitMs ?? room.settings.defaultAnswerTimeLimitMs;
  room.game.answering.deadlineServerMs = Date.now() + timeLimit;
};

export type WrongAnswerOutcome = "REOPENED" | "CLOSED";

export const markWrongAnswer = (
  room: RoomState,
  userId: string,
  options?: { fallbackReopenWindowMs?: number },
): WrongAnswerOutcome => {
  const nowMs = Date.now();
  if (!room.game.buzzer.lockedOutUserIds.includes(userId)) {
    room.game.buzzer.lockedOutUserIds.push(userId);
  }
  room.game.answering.activeUserId = null;
  room.game.answering.deadlineServerMs = null;
  room.game.answering.draftAnswerText = "";

  const pausedReadRemainingMs = Math.max(0, room.game.answering.pausedReadRemainingMs ?? 0);
  const pausedCloseRemainingMs = Math.max(
    0,
    room.game.answering.pausedCloseRemainingMs ??
      options?.fallbackReopenWindowMs ??
      room.settings.buzzWindowMs ??
      7_000,
  );
  room.game.answering.pausedReadRemainingMs = null;
  room.game.answering.pausedCloseRemainingMs = null;

  const eligible = Object.values(room.players).some(
    (player) =>
      player.connected &&
      !room.game.buzzer.lockedOutUserIds.includes(player.userId) &&
      player.canBuzz,
  );

  room.status = eligible ? "QUESTION_OPEN" : "QUESTION_CLOSED";
  room.game.buzzer.state = "CLOSED";
  room.game.buzzer.readStartedAtServerMs = null;
  room.game.buzzer.readEndsAtServerMs = null;
  room.game.buzzer.openAtServerMs = null;
  room.game.buzzer.closeAtServerMs = null;
  room.game.buzzer.winnerUserId = null;
  room.game.buzzer.resolveAtServerMs = null;
  room.game.buzzer.attempts = [];
  room.game.buzzer.openedAtServerMs = null;

  if (eligible) {
    const question = room.game.currentQuestion;
    const revealDurationMs = Math.max(1, question?.revealDurationMs ?? 1);
    const revealedMs = clamp(question?.revealedMs ?? revealDurationMs, 0, revealDurationMs);
    const readRemainingMs = Math.max(
      0,
      Math.min(pausedReadRemainingMs, Math.max(0, revealDurationMs - revealedMs)),
    );

    if (question) {
      question.revealedMs = revealedMs;
      question.revealResumedAtServerMs = readRemainingMs > 0 ? nowMs : null;
    }

    const readEndsAtServerMs = readRemainingMs > 0 ? nowMs + readRemainingMs : nowMs;
    const allowFalseStarts = room.settings.allowFalseStarts ?? true;
    const openAtServerMs = allowFalseStarts ? readEndsAtServerMs : nowMs;
    const closeAtServerMs = nowMs + pausedCloseRemainingMs;
    const isOpenNow = openAtServerMs <= nowMs;

    room.game.buzzer.readStartedAtServerMs = readRemainingMs > 0 ? nowMs : null;
    room.game.buzzer.readEndsAtServerMs = readRemainingMs > 0 ? readEndsAtServerMs : nowMs;
    room.game.buzzer.openAtServerMs = openAtServerMs;
    room.game.buzzer.closeAtServerMs = closeAtServerMs;
    room.game.buzzer.state = isOpenNow ? "OPEN" : "CLOSED";
    room.game.buzzer.openedAtServerMs = isOpenNow ? nowMs : null;
  }

  return eligible ? "REOPENED" : "CLOSED";
};

export const closeQuestion = (room: RoomState): void => {
  if (room.game.currentQuestion) {
    room.game.board.playedQuestionIds.push(room.game.currentQuestion.id);
  }

  room.status = "QUESTION_CLOSED";
  room.game.autoNextQuestionAtServerMs = null;
  room.game.buzzer.state = "CLOSED";
  room.game.buzzer.readStartedAtServerMs = null;
  room.game.buzzer.readEndsAtServerMs = null;
  room.game.buzzer.openAtServerMs = null;
  room.game.buzzer.closeAtServerMs = null;
  room.game.buzzer.openedAtServerMs = null;
  room.game.buzzer.resolveAtServerMs = null;
  room.game.buzzer.winnerUserId = null;
  room.game.buzzer.attempts = [];
  room.game.answering.activeUserId = null;
  room.game.answering.deadlineServerMs = null;
  room.game.answering.draftAnswerText = "";
  room.game.answering.pausedReadRemainingMs = null;
  room.game.answering.pausedCloseRemainingMs = null;
};

export const completeIfBoardFinished = (room: RoomState): void => {
  if (room.game.board.remainingQuestionIds.length === 0 && room.status === "QUESTION_CLOSED") {
    room.status = "FINISHED";
  }
};

export const applyScoreDelta = (room: RoomState, userId: string, delta: number): number => {
  const player = room.players[userId];
  if (!player) {
    return 0;
  }

  player.score += delta;
  return player.score;
};
