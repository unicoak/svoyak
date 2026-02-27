import { QuestionSnapshot, RoomState } from "../types/room.js";

export const resetBuzzerState = (room: RoomState, state: "CLOSED" | "OPEN" | "LOCKED"): void => {
  room.game.buzzer.state = state;
  room.game.buzzer.openedAtServerMs = state === "OPEN" ? Date.now() : null;
  room.game.buzzer.resolveAtServerMs = null;
  room.game.buzzer.winnerUserId = null;
  room.game.buzzer.attempts = [];

  if (state !== "LOCKED") {
    room.game.answering.activeUserId = null;
    room.game.answering.deadlineServerMs = null;
  }
};

export const openQuestion = (room: RoomState, question: QuestionSnapshot): void => {
  room.status = "QUESTION_OPEN";
  room.game.currentQuestion = question;
  room.game.board.remainingQuestionIds = room.game.board.remainingQuestionIds.filter((id) => id !== question.id);

  for (const player of Object.values(room.players)) {
    player.canBuzz = true;
  }

  room.game.buzzer.lockedOutUserIds = [];
  resetBuzzerState(room, "OPEN");
};

export const lockBuzzerWinner = (room: RoomState, winnerUserId: string): void => {
  room.status = "ANSWERING";
  room.game.buzzer.state = "LOCKED";
  room.game.buzzer.winnerUserId = winnerUserId;
  room.game.answering.activeUserId = winnerUserId;

  const timeLimit = room.game.currentQuestion?.answerTimeLimitMs ?? room.settings.defaultAnswerTimeLimitMs;
  room.game.answering.deadlineServerMs = Date.now() + timeLimit;
};

export type WrongAnswerOutcome = "REOPENED" | "CLOSED";

export const markWrongAnswer = (room: RoomState, userId: string): WrongAnswerOutcome => {
  room.game.buzzer.lockedOutUserIds.push(userId);
  room.game.answering.activeUserId = null;
  room.game.answering.deadlineServerMs = null;

  const eligible = Object.values(room.players).some(
    (player) =>
      player.connected &&
      !room.game.buzzer.lockedOutUserIds.includes(player.userId) &&
      player.canBuzz,
  );

  room.status = eligible ? "QUESTION_OPEN" : "QUESTION_CLOSED";
  room.game.buzzer.state = eligible ? "OPEN" : "CLOSED";
  room.game.buzzer.winnerUserId = null;
  room.game.buzzer.resolveAtServerMs = null;
  room.game.buzzer.attempts = [];
  room.game.buzzer.openedAtServerMs = eligible ? Date.now() : null;

  return eligible ? "REOPENED" : "CLOSED";
};

export const closeQuestion = (room: RoomState): void => {
  if (room.game.currentQuestion) {
    room.game.board.playedQuestionIds.push(room.game.currentQuestion.id);
  }

  room.status = "QUESTION_CLOSED";
  room.game.buzzer.state = "CLOSED";
  room.game.buzzer.openedAtServerMs = null;
  room.game.buzzer.resolveAtServerMs = null;
  room.game.buzzer.winnerUserId = null;
  room.game.buzzer.attempts = [];
  room.game.answering.activeUserId = null;
  room.game.answering.deadlineServerMs = null;
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
