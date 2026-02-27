import crypto from "crypto";
import { RoomSettings, RoomState, RoomVisibility } from "../types/room.js";
import { randomToken } from "../utils/ids.js";

interface CreateRoomStateInput {
  roomId: string;
  roomCode: string;
  visibility: RoomVisibility;
  hostUserId: string;
  hostName: string;
  hostSocketId: string;
  packageId: string;
  nowMs: number;
  settings: RoomSettings;
  questionIds: string[];
}

export const defaultRoomSettings = (defaults: {
  buzzResolveWindowMs: number;
  defaultAnswerTimeLimitMs: number;
}): RoomSettings => ({
  maxPlayers: 6,
  disconnectGraceMs: 30_000,
  buzzResolveWindowMs: defaults.buzzResolveWindowMs,
  buzzWindowMs: 5_000,
  defaultAnswerTimeLimitMs: defaults.defaultAnswerTimeLimitMs,
  allowFalseStarts: true,
});

export const mergeRoomSettings = (
  base: RoomSettings,
  partial?: Partial<RoomSettings>,
): RoomSettings => {
  if (!partial) {
    return base;
  }

  return {
    maxPlayers: partial.maxPlayers ?? base.maxPlayers,
    disconnectGraceMs: partial.disconnectGraceMs ?? base.disconnectGraceMs,
    buzzResolveWindowMs: partial.buzzResolveWindowMs ?? base.buzzResolveWindowMs,
    buzzWindowMs: partial.buzzWindowMs ?? base.buzzWindowMs,
    defaultAnswerTimeLimitMs: partial.defaultAnswerTimeLimitMs ?? base.defaultAnswerTimeLimitMs,
    allowFalseStarts: partial.allowFalseStarts ?? base.allowFalseStarts,
  };
};

export const createInitialRoomState = (input: CreateRoomStateInput): RoomState => ({
  schemaVersion: 2,
  version: 1,
  roomId: input.roomId,
  code: input.roomCode,
  visibility: input.visibility,
  status: "LOBBY",
  hostUserId: input.hostUserId,
  packageId: input.packageId,
  createdAtMs: input.nowMs,
  updatedAtMs: input.nowMs,
  settings: input.settings,
  players: {
    [input.hostUserId]: {
      userId: input.hostUserId,
      name: input.hostName,
      socketId: input.hostSocketId,
      score: 0,
      joinedAtMs: input.nowMs,
      lastSeenAtMs: input.nowMs,
      connected: true,
      isHost: true,
      canBuzz: true,
      reconnectToken: randomToken(),
      net: {
        offsetMs: 0,
        rttMs: 120,
        jitterMs: 0,
        syncSampleCount: 0,
        lastSyncAtMs: input.nowMs,
      },
    },
  },
  game: {
    roundNo: 1,
    board: {
      remainingQuestionIds: input.questionIds,
      playedQuestionIds: [],
    },
    currentQuestion: null,
    buzzer: {
      state: "CLOSED",
      readStartedAtServerMs: null,
      readEndsAtServerMs: null,
      openAtServerMs: null,
      closeAtServerMs: null,
      openedAtServerMs: null,
      resolveAtServerMs: null,
      winnerUserId: null,
      lockedOutUserIds: [],
      attempts: [],
    },
    answering: {
      activeUserId: null,
      deadlineServerMs: null,
    },
  },
  migration: {
    hostMigrationSeq: 0,
  },
});

export const newRoomId = (): string => crypto.randomUUID();
