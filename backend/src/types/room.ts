export type RoomStatus = "LOBBY" | "QUESTION_OPEN" | "ANSWERING" | "QUESTION_CLOSED" | "FINISHED";
export type BuzzerState = "CLOSED" | "OPEN" | "LOCKED";
export type RoomVisibility = "PUBLIC" | "PRIVATE";

export interface PlayerNetStats {
  offsetMs: number;
  rttMs: number;
  jitterMs: number;
  syncSampleCount: number;
  lastSyncAtMs: number;
}

export interface PlayerState {
  userId: string;
  name: string;
  socketId: string;
  score: number;
  joinedAtMs: number;
  lastSeenAtMs: number;
  connected: boolean;
  isHost: boolean;
  canBuzz: boolean;
  reconnectToken: string;
  net: PlayerNetStats;
}

export interface QuestionSnapshot {
  id: string;
  roundNo: number;
  boardRow: number;
  boardCol: number;
  points: number;
  prompt: string;
  answerDisplay: string;
  answerTimeLimitMs: number;
}

export interface BuzzerAttempt {
  userId: string;
  recvServerMs: number;
  pressClientMs: number;
  offsetMs: number;
  rttMs: number;
  effectivePressMs: number;
}

export interface Buzzer {
  state: BuzzerState;
  openedAtServerMs: number | null;
  resolveAtServerMs: number | null;
  winnerUserId: string | null;
  lockedOutUserIds: string[];
  attempts: BuzzerAttempt[];
}

export interface Answering {
  activeUserId: string | null;
  deadlineServerMs: number | null;
}

export interface GameState {
  roundNo: number;
  board: {
    remainingQuestionIds: string[];
    playedQuestionIds: string[];
  };
  currentQuestion: QuestionSnapshot | null;
  buzzer: Buzzer;
  answering: Answering;
}

export interface RoomSettings {
  maxPlayers: number;
  disconnectGraceMs: number;
  buzzResolveWindowMs: number;
  defaultAnswerTimeLimitMs: number;
}

export interface RoomState {
  schemaVersion: number;
  version: number;
  roomId: string;
  code: string;
  visibility: RoomVisibility;
  status: RoomStatus;
  hostUserId: string;
  packageId: string;
  createdAtMs: number;
  updatedAtMs: number;
  settings: RoomSettings;
  players: Record<string, PlayerState>;
  game: GameState;
  migration: {
    hostMigrationSeq: number;
  };
}

export interface AcceptedAnswer {
  id: string;
  answerRaw: string;
  answerNorm: string;
  maxLevenshtein: number;
}

export interface PublicRoomSummary {
  roomId: string;
  roomCode: string;
  status: RoomStatus;
  hostUserId: string;
  hostName: string;
  playersCount: number;
  maxPlayers: number;
  hasFreeSlots: boolean;
  createdAtMs: number;
}
