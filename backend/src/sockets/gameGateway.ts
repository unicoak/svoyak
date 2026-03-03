import { Server, Socket } from "socket.io";
import { z } from "zod";
import { env } from "../config/env.js";
import {
  applyScoreDelta,
  closeQuestion,
  completeIfBoardFinished,
  lockBuzzerWinner,
  markWrongAnswer,
  openQuestion,
} from "../services/gameState.js";
import { migrateHostIfNeeded } from "../services/hostMigration.js";
import { toPublicRoomState } from "../services/roomProjection.js";
import {
  createInitialRoomState,
  defaultRoomSettings,
  mergeRoomSettings,
  newRoomId,
} from "../services/roomFactory.js";
import { RoomNotFoundError, RoomStore } from "../services/roomStore.js";
import { evaluateAnswer } from "../services/answerChecker.js";
import { QuizRepository } from "../services/quizRepository.js";
import { computeEffectivePressMs, updateJitter } from "../services/timeSync.js";
import { Ack, AckError, AckOk } from "../types/events.js";
import { QuizQuestionRow } from "../types/quiz.js";
import { PublicRoomSummary, RoomState } from "../types/room.js";
import { logger } from "../utils/logger.js";
import { randomRoomCode, randomToken } from "../utils/ids.js";

interface SocketData {
  userId: string;
  displayName: string;
  roomCode: string | null;
}

type GameSocket = Socket<any, any, any, SocketData>;

const createRoomSchema = z.object({
  packageId: z.string().uuid(),
  displayName: z.string().trim().min(1).max(30),
  visibility: z.enum(["PUBLIC", "PRIVATE"]).default("PRIVATE"),
  settings: z
    .object({
      maxPlayers: z.number().int().min(2).max(12).optional(),
      disconnectGraceMs: z.number().int().min(5_000).max(120_000).optional(),
      buzzResolveWindowMs: z.number().int().min(30).max(400).optional(),
      defaultAnswerTimeLimitMs: z.number().int().min(1_000).max(60_000).optional(),
      allowFalseStarts: z.boolean().optional(),
    })
    .optional(),
});

const joinRoomSchema = z.object({
  roomCode: z.string().trim().toUpperCase().length(6),
  displayName: z.string().trim().min(1).max(30),
  reconnectToken: z.string().uuid().optional(),
});

const roomCodeSchema = z.object({
  roomCode: z.string().trim().toUpperCase().length(6),
});

const selectQuestionSchema = roomCodeSchema.extend({
  questionId: z.string().uuid(),
});

const buzzAttemptSchema = roomCodeSchema.extend({
  questionId: z.string().uuid(),
  pressClientMs: z.number().int().positive(),
  offsetMs: z.number().int().min(-5_000).max(5_000).optional(),
  rttMs: z.number().int().min(1).max(5_000).optional(),
  sampleId: z.string().optional(),
});

const answerSubmittedSchema = roomCodeSchema.extend({
  questionId: z.string().uuid(),
  answerText: z.string().trim().min(1).max(200),
  submittedClientMs: z.number().int().optional(),
});

const answerDraftSchema = roomCodeSchema.extend({
  questionId: z.string().uuid(),
  answerText: z.string().max(200),
});

const syncTimeSchema = z.object({
  sampleId: z.string().min(1).max(64),
  t0ClientMs: z.number().int().positive(),
});

const syncTimeMetricsSchema = roomCodeSchema.extend({
  offsetMs: z.number().int().min(-5_000).max(5_000),
  rttMs: z.number().int().min(1).max(5_000),
  sampleId: z.string().min(1).max(64).optional(),
});

const heartbeatSchema = roomCodeSchema.extend({
  clientNowMs: z.number().int().positive(),
});

const listPublicRoomsSchema = z
  .object({
    limit: z.number().int().min(1).max(100).optional(),
  })
  .optional();

const listPackagesSchema = z
  .object({
    query: z.string().trim().max(80).optional(),
    difficulty: z.number().int().min(1).max(3).optional(),
    limit: z.number().int().min(1).max(50).optional(),
  })
  .optional();

const ok = <T>(data: T): AckOk<T> => ({ ok: true, data });
const failure = (code: string, message: string): AckError => ({
  ok: false,
  error: { code, message },
});

interface FinalizeOutcome {
  winnerUserId: string;
  effectivePressMs: number;
  questionId: string;
}

interface PackageStructureValidation {
  valid: boolean;
  reason?: string;
  orderedQuestionIds?: string[];
}

const QUESTION_REVEAL_MIN_MS = 1_800;
const QUESTION_REVEAL_MAX_MS = 9_000;
const QUESTION_REVEAL_PER_CHAR_MS = 34;
const ANSWER_INPUT_WINDOW_MS = 15_000;
const CORRECT_ANSWER_REVEAL_MS = 10_000;
const EARLY_PRESS_TOLERANCE_MS = 35;

export class GameGateway {
  private readonly buzzerTimers = new Map<string, NodeJS.Timeout>();
  private readonly questionWindowTimers = new Map<string, NodeJS.Timeout>();
  private readonly answerTimers = new Map<string, NodeJS.Timeout>();
  private readonly autoNextQuestionTimers = new Map<string, NodeJS.Timeout>();
  private readonly disconnectTimers = new Map<string, NodeJS.Timeout>();
  private readonly settingsDefaults = defaultRoomSettings({
    buzzResolveWindowMs: env.buzzResolveWindowMs,
    defaultAnswerTimeLimitMs: env.defaultAnswerTimeLimitMs,
  });

  constructor(
    private readonly io: Server<any, any, any, SocketData>,
    private readonly roomStore: RoomStore,
    private readonly quizRepository: QuizRepository,
  ) {}

  register(): void {
    this.io.on("connection", (socket: GameSocket) => {
      this.initializeSocketData(socket);
      this.registerEventHandlers(socket);
    });
  }

  private initializeSocketData(socket: GameSocket): void {
    const handshakeUserId = socket.handshake.auth.userId;
    const handshakeDisplayName = socket.handshake.auth.displayName;

    socket.data.userId = typeof handshakeUserId === "string" && handshakeUserId ? handshakeUserId : randomToken();
    socket.data.displayName =
      typeof handshakeDisplayName === "string" && handshakeDisplayName.trim()
        ? handshakeDisplayName.trim().slice(0, 30)
        : `Player-${socket.id.slice(0, 6)}`;
    socket.data.roomCode = null;
  }

  private registerEventHandlers(socket: GameSocket): void {
    socket.on("list_public_rooms", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = listPublicRoomsSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid list_public_rooms payload."));
        return;
      }

      try {
        const rooms = await this.roomStore.listPublicRooms(parsed.data?.limit ?? 20);
        ack?.(ok({ rooms: rooms.map((room) => this.toPublicRoomSummary(room)) }));
      } catch (error) {
        logger.error("list_public_rooms failed", error);
        ack?.(failure("LIST_PUBLIC_ROOMS_FAILED", "Unable to load public rooms."));
      }
    });

    socket.on("list_packages", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = listPackagesSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid list_packages payload."));
        return;
      }

      try {
        const packages = await this.quizRepository.listPublishedPackages({
          query: parsed.data?.query,
          difficulty: parsed.data?.difficulty,
          limit: parsed.data?.limit ?? 20,
        });
        ack?.(ok({ packages }));
      } catch (error) {
        logger.error("list_packages failed", error);
        ack?.(failure("LIST_PACKAGES_FAILED", "Unable to load quiz packages."));
      }
    });

    socket.on("create_room", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = createRoomSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", parsed.error.flatten().formErrors.join("; ") || "Invalid create_room payload"));
        return;
      }

      const payload = parsed.data;
      socket.data.displayName = payload.displayName;

      let resolvedPackageId = payload.packageId;
      let resolvedPackage = await this.quizRepository.getPackageById(payload.packageId);
      let usedFallbackPackage = false;

      if (!resolvedPackage) {
        const fallbackPackage = await this.quizRepository.getLatestPublishedPackage();
        if (!fallbackPackage) {
          ack?.(failure("PACKAGE_NOT_FOUND", "Quiz package does not exist."));
          return;
        }

        resolvedPackageId = fallbackPackage.id;
        resolvedPackage = fallbackPackage;
        usedFallbackPackage = true;
      }

      const questions = await this.quizRepository.listQuestionsByPackage(resolvedPackageId);
      if (questions.length === 0) {
        ack?.(failure("EMPTY_PACKAGE", "Selected package has no questions."));
        return;
      }

      const structure = this.validatePackageStructure(questions);
      if (!structure.valid || !structure.orderedQuestionIds) {
        ack?.(
          failure(
            "INVALID_PACKAGE_STRUCTURE",
            structure.reason ??
              "Package must contain 4-8 themes with 5 sequential questions in each theme.",
          ),
        );
        return;
      }

      const roomCode = await this.generateUniqueRoomCode();
      const nowMs = Date.now();

      const room = createInitialRoomState({
        roomId: newRoomId(),
        roomCode,
        visibility: payload.visibility,
        hostUserId: socket.data.userId,
        hostName: payload.displayName,
        hostSocketId: socket.id,
        packageId: resolvedPackageId,
        nowMs,
        settings: mergeRoomSettings(this.settingsDefaults, payload.settings),
        questionIds: structure.orderedQuestionIds,
        themeTitlesByRow: this.resolveThemeTitlesByRow(
          questions,
          resolvedPackage.id,
          resolvedPackage.description,
        ),
      });

      await this.roomStore.save(room);

      socket.join(roomCode);
      socket.data.roomCode = roomCode;

      const reconnectToken = room.players[socket.data.userId].reconnectToken;
      const publicState = toPublicRoomState(room);

      socket.emit("room_joined", {
        roomId: room.roomId,
        roomCode: room.code,
        selfUserId: socket.data.userId,
        reconnectToken,
        serverNowMs: Date.now(),
        state: publicState,
      });

      this.emitRoomState(room);
      ack?.(
        ok({
          roomCode: room.code,
          roomId: room.roomId,
          reconnectToken,
          packageId: resolvedPackageId,
          requestedPackageId: payload.packageId,
          packageFallbackUsed: usedFallbackPackage,
          packageTitle: resolvedPackage.title,
        }),
      );
    });

    socket.on("join_room", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = joinRoomSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", parsed.error.flatten().formErrors.join("; ") || "Invalid join_room payload"));
        return;
      }

      const payload = parsed.data;

      try {
        const result = await this.roomStore.withRoomLock(payload.roomCode, async (room) => {
          if (Object.keys(room.players).length >= room.settings.maxPlayers && !payload.reconnectToken) {
            throw new Error("ROOM_FULL");
          }

          let userId = socket.data.userId;
          let reconnectToken: string | undefined;
          let player = room.players[userId];

          if (payload.reconnectToken) {
            const rejoinCandidate = Object.values(room.players).find(
              (candidate) => candidate.reconnectToken === payload.reconnectToken,
            );

            if (rejoinCandidate) {
              userId = rejoinCandidate.userId;
              player = rejoinCandidate;
              reconnectToken = rejoinCandidate.reconnectToken;
            }
          }

          if (!player) {
            userId = randomToken();
            reconnectToken = randomToken();

            room.players[userId] = {
              userId,
              name: payload.displayName,
              socketId: socket.id,
              score: 0,
              joinedAtMs: Date.now(),
              lastSeenAtMs: Date.now(),
              connected: true,
              isHost: false,
              canBuzz: true,
              reconnectToken,
              net: {
                offsetMs: 0,
                rttMs: 120,
                jitterMs: 0,
                syncSampleCount: 0,
                lastSyncAtMs: Date.now(),
              },
            };
          } else {
            player.socketId = socket.id;
            player.connected = true;
            player.lastSeenAtMs = Date.now();
            player.name = payload.displayName;
            reconnectToken = player.reconnectToken;
          }

          socket.data.userId = userId;
          socket.data.displayName = payload.displayName;

          const disconnectKey = `${payload.roomCode}:${userId}`;
          const scheduledDisconnect = this.disconnectTimers.get(disconnectKey);
          if (scheduledDisconnect) {
            clearTimeout(scheduledDisconnect);
            this.disconnectTimers.delete(disconnectKey);
          }

          return {
            room,
            reconnectToken,
            userId,
          };
        });

        socket.join(payload.roomCode);
        socket.data.roomCode = payload.roomCode;

        const publicState = toPublicRoomState(result.room);

        socket.emit("room_joined", {
          roomId: result.room.roomId,
          roomCode: result.room.code,
          selfUserId: result.userId,
          reconnectToken: result.reconnectToken,
          serverNowMs: Date.now(),
          state: publicState,
        });

        this.io.to(payload.roomCode).emit("player_presence", {
          userId: result.userId,
          connected: true,
          atMs: Date.now(),
        });

        this.restoreTimersForRoomState(payload.roomCode, result.room);
        this.emitRoomState(result.room);
        ack?.(ok({ roomCode: result.room.code, reconnectToken: result.reconnectToken, selfUserId: result.userId }));
      } catch (error) {
        if (error instanceof RoomNotFoundError) {
          ack?.(failure("ROOM_NOT_FOUND", "Room does not exist."));
          return;
        }

        if (error instanceof Error && error.message === "ROOM_FULL") {
          ack?.(failure("ROOM_FULL", "Room is full."));
          return;
        }

        logger.error("join_room failed", error);
        ack?.(failure("JOIN_FAILED", "Unable to join room."));
      }
    });

    socket.on("leave_room", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = roomCodeSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid leave_room payload."));
        return;
      }

      const payload = parsed.data;

      try {
        const outcome = await this.roomStore.withRoomLock(payload.roomCode, async (room) => {
          const player = room.players[socket.data.userId];
          if (!player) {
            throw new Error("PLAYER_NOT_IN_ROOM");
          }

          let clearAnswerTimer = false;
          let questionClosed: null | {
            questionId: string;
            correctAnswerDisplay: string;
            correctAnswerComment: string;
            autoNextAtServerMs: number | null;
          } = null;
          const currentQuestion = room.game.currentQuestion;
          if (
            currentQuestion &&
            room.status === "ANSWERING" &&
            room.game.answering.activeUserId === player.userId
          ) {
            clearAnswerTimer = true;
            applyScoreDelta(room, player.userId, -currentQuestion.points);
            const wrongOutcome = markWrongAnswer(room, player.userId, {
              fallbackReopenWindowMs: room.settings.buzzWindowMs ?? 7_000,
            });
            if (wrongOutcome === "CLOSED") {
              closeQuestion(room);
              completeIfBoardFinished(room);
              questionClosed = {
                questionId: currentQuestion.id,
                correctAnswerDisplay: currentQuestion.answerDisplay,
                correctAnswerComment: currentQuestion.answerComment,
                autoNextAtServerMs: this.assignAutoNextQuestion(room),
              };
            }
          }

          delete room.players[socket.data.userId];
          const migration = migrateHostIfNeeded(room);

          return {
            room,
            migration,
            roomEmpty: Object.keys(room.players).length === 0,
            clearAnswerTimer,
            questionClosed,
            buzzReopened:
              room.status === "QUESTION_OPEN" &&
              room.game.buzzer.closeAtServerMs != null,
          };
        });

        socket.leave(payload.roomCode);
        socket.data.roomCode = null;

        if (outcome.clearAnswerTimer) {
          this.clearAnswerDeadlineTimer(payload.roomCode);
        }

        if (outcome.roomEmpty) {
          this.clearRoomTimers(payload.roomCode);
          await this.roomStore.deleteByCode(payload.roomCode);
          ack?.(ok({ removed: true }));
          return;
        }

        if (outcome.buzzReopened) {
          this.scheduleQuestionWindowForOpenState(payload.roomCode, outcome.room);
        } else if (outcome.questionClosed) {
          this.clearQuestionWindowTimer(payload.roomCode);
          this.clearBuzzerFinalizationTimer(payload.roomCode);
          this.io.to(payload.roomCode).emit("question_closed", {
            questionId: outcome.questionClosed.questionId,
            correctAnswerDisplay: outcome.questionClosed.correctAnswerDisplay,
            correctAnswerComment: outcome.questionClosed.correctAnswerComment,
            autoNextAtServerMs: outcome.questionClosed.autoNextAtServerMs,
            scores: this.extractScores(outcome.room),
          });
          if (outcome.questionClosed.autoNextAtServerMs) {
            this.scheduleAutoNextQuestion(payload.roomCode, outcome.questionClosed.autoNextAtServerMs);
          } else {
            this.clearAutoNextQuestionTimer(payload.roomCode);
          }
        } else if (outcome.room.status === "QUESTION_CLOSED" && outcome.room.game.autoNextQuestionAtServerMs) {
          this.scheduleAutoNextQuestion(payload.roomCode, outcome.room.game.autoNextQuestionAtServerMs);
        } else if (outcome.room.status === "QUESTION_CLOSED") {
          this.clearQuestionWindowTimer(payload.roomCode);
          this.clearBuzzerFinalizationTimer(payload.roomCode);
          this.clearAutoNextQuestionTimer(payload.roomCode);
        } else if (outcome.room.status === "FINISHED") {
          this.clearQuestionWindowTimer(payload.roomCode);
          this.clearBuzzerFinalizationTimer(payload.roomCode);
          this.clearAutoNextQuestionTimer(payload.roomCode);
        }

        if (outcome.migration) {
          this.io.to(payload.roomCode).emit("host_migrated", {
            oldHostUserId: outcome.migration.oldHostUserId,
            newHostUserId: outcome.migration.newHostUserId,
            reason: "host_left",
          });
        }

        this.emitRoomState(outcome.room);
        ack?.(ok({ removed: false }));
      } catch (error) {
        if (error instanceof RoomNotFoundError) {
          ack?.(failure("ROOM_NOT_FOUND", "Room does not exist."));
          return;
        }

        ack?.(failure("LEAVE_FAILED", "Unable to leave room."));
      }
    });

    socket.on("sync_time", (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = syncTimeSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid sync_time payload."));
        return;
      }

      const t1ServerRecvMs = Date.now();
      const t2ServerSendMs = Date.now();

      socket.emit("time_sync", {
        sampleId: parsed.data.sampleId,
        t1ServerRecvMs,
        t2ServerSendMs,
      });

      ack?.(ok({ t1ServerRecvMs, t2ServerSendMs }));
    });

    socket.on("sync_time_metrics", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = syncTimeMetricsSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid sync_time_metrics payload."));
        return;
      }

      try {
        await this.roomStore.withRoomLock(parsed.data.roomCode, async (room) => {
          const player = room.players[socket.data.userId];
          if (!player) {
            throw new Error("PLAYER_NOT_IN_ROOM");
          }

          const offsetMs = Math.max(-1_500, Math.min(1_500, parsed.data.offsetMs));
          const rttMs = Math.max(10, Math.min(3_000, parsed.data.rttMs));
          const smoothedOffset = Math.round((player.net.offsetMs * 3 + offsetMs) / 4);
          const smoothedRtt = Math.round((player.net.rttMs * 3 + rttMs) / 4);
          const jitter = updateJitter({
            offsetMs: smoothedOffset,
            rttMs: smoothedRtt,
            previousRttMs: player.net.rttMs,
          });

          player.net.offsetMs = smoothedOffset;
          player.net.rttMs = smoothedRtt;
          player.net.jitterMs = jitter;
          player.net.syncSampleCount += 1;
          player.net.lastSyncAtMs = Date.now();

          return room;
        });

        ack?.(ok({ accepted: true }));
      } catch (error) {
        if (error instanceof RoomNotFoundError) {
          ack?.(failure("ROOM_NOT_FOUND", "Room does not exist."));
          return;
        }

        if (error instanceof Error && error.message === "PLAYER_NOT_IN_ROOM") {
          ack?.(failure("PLAYER_NOT_IN_ROOM", "Player is not in room."));
          return;
        }

        ack?.(failure("SYNC_TIME_METRICS_FAILED", "Unable to apply sync metrics."));
      }
    });

    socket.on("start_game", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = roomCodeSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid start_game payload."));
        return;
      }

      try {
        const room = await this.roomStore.withRoomLock(parsed.data.roomCode, async (lockedRoom) => {
          if (lockedRoom.hostUserId !== socket.data.userId) {
            throw new Error("HOST_ONLY");
          }

          if (lockedRoom.status !== "LOBBY") {
            throw new Error("INVALID_ROOM_STATUS");
          }

          lockedRoom.status = "QUESTION_CLOSED";
          return lockedRoom;
        });

        this.emitRoomState(room);
        ack?.(ok({ started: true }));
      } catch (error) {
        if (error instanceof Error && error.message === "HOST_ONLY") {
          ack?.(failure("HOST_ONLY", "Only host can start the game."));
          return;
        }

        if (error instanceof Error && error.message === "INVALID_ROOM_STATUS") {
          ack?.(failure("INVALID_ROOM_STATUS", "Game has already started."));
          return;
        }

        ack?.(failure("START_FAILED", "Unable to start game."));
      }
    });

    socket.on("select_question", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = selectQuestionSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid select_question payload."));
        return;
      }

      const payload = parsed.data;

      try {
        const question = await this.quizRepository.getQuestionById(payload.questionId);
        if (!question) {
          ack?.(failure("QUESTION_NOT_FOUND", "Question does not exist."));
          return;
        }

        const room = await this.roomStore.withRoomLock(payload.roomCode, async (lockedRoom) => {
          if (lockedRoom.hostUserId !== socket.data.userId) {
            throw new Error("HOST_ONLY");
          }

          if (!(lockedRoom.status === "QUESTION_CLOSED" || lockedRoom.status === "LOBBY")) {
            throw new Error("INVALID_ROOM_STATUS");
          }

          if (!lockedRoom.game.board.remainingQuestionIds.includes(payload.questionId)) {
            throw new Error("QUESTION_ALREADY_PLAYED");
          }

          const expectedQuestionId = lockedRoom.game.board.remainingQuestionIds[0];
          if (expectedQuestionId !== payload.questionId) {
            throw new Error("OUT_OF_ORDER_QUESTION");
          }

          this.openQuestionInRoom(lockedRoom, question);

          return lockedRoom;
        });

        this.clearBuzzerFinalizationTimer(payload.roomCode);
        this.clearAnswerDeadlineTimer(payload.roomCode);
        this.clearAutoNextQuestionTimer(payload.roomCode);
        this.scheduleQuestionWindowForOpenState(payload.roomCode, room);

        this.emitQuestionOpened(payload.roomCode, room, question);

        this.emitRoomState(room);
        ack?.(ok({ opened: true }));
      } catch (error) {
        if (error instanceof Error && error.message === "HOST_ONLY") {
          ack?.(failure("HOST_ONLY", "Only host can select question."));
          return;
        }

        if (error instanceof Error && error.message === "INVALID_ROOM_STATUS") {
          ack?.(failure("INVALID_ROOM_STATUS", "Question cannot be selected right now."));
          return;
        }

        if (error instanceof Error && error.message === "QUESTION_ALREADY_PLAYED") {
          ack?.(failure("QUESTION_ALREADY_PLAYED", "Question has already been played."));
          return;
        }

        if (error instanceof Error && error.message === "OUT_OF_ORDER_QUESTION") {
          ack?.(failure("OUT_OF_ORDER_QUESTION", "Questions must be played in order."));
          return;
        }

        ack?.(failure("SELECT_FAILED", "Unable to select question."));
      }
    });

    socket.on("buzz_attempt", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = buzzAttemptSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid buzz_attempt payload."));
        return;
      }

      const payload = parsed.data;
      const recvServerMs = Date.now();

      try {
        const outcome = await this.roomStore.withRoomLock(payload.roomCode, async (lockedRoom) => {
          if (lockedRoom.status !== "QUESTION_OPEN") {
            throw new Error("BUZZ_CLOSED");
          }

          if (lockedRoom.game.currentQuestion?.id !== payload.questionId) {
            throw new Error("QUESTION_MISMATCH");
          }

          const player = lockedRoom.players[socket.data.userId];
          if (!player || !player.connected) {
            throw new Error("PLAYER_NOT_ACTIVE");
          }

          if (lockedRoom.game.buzzer.lockedOutUserIds.includes(player.userId) || !player.canBuzz) {
            throw new Error("LOCKED_OUT");
          }

          if (lockedRoom.game.buzzer.attempts.some((attempt) => attempt.userId === player.userId)) {
            throw new Error("DUPLICATE_BUZZ");
          }

          const openAtServerMs = lockedRoom.game.buzzer.openAtServerMs;
          const closeAtServerMs = lockedRoom.game.buzzer.closeAtServerMs;
          if (!openAtServerMs || !closeAtServerMs) {
            throw new Error("BUZZ_CLOSED");
          }

          const effectiveOffsetMs = player.net.offsetMs;
          const effectiveRttMs = player.net.rttMs;
          const effectivePressMs = computeEffectivePressMs({
            recvServerMs,
            pressClientMs: payload.pressClientMs,
            offsetMs: effectiveOffsetMs,
            rttMs: effectiveRttMs,
          });

          const jitter = updateJitter({
            offsetMs: effectiveOffsetMs,
            rttMs: effectiveRttMs,
            previousRttMs: player.net.rttMs,
          });

          player.net.offsetMs = effectiveOffsetMs;
          player.net.rttMs = effectiveRttMs;
          player.net.jitterMs = jitter;
          player.net.syncSampleCount += 1;
          player.net.lastSyncAtMs = Date.now();

          if (effectivePressMs < openAtServerMs - EARLY_PRESS_TOLERANCE_MS) {
            if (lockedRoom.settings.allowFalseStarts ?? true) {
              player.canBuzz = false;
              if (!lockedRoom.game.buzzer.lockedOutUserIds.includes(player.userId)) {
                lockedRoom.game.buzzer.lockedOutUserIds.push(player.userId);
              }

              const stillEligible = Object.values(lockedRoom.players).some(
                (candidate) =>
                  candidate.connected &&
                  candidate.canBuzz &&
                  !lockedRoom.game.buzzer.lockedOutUserIds.includes(candidate.userId),
              );

              if (!stillEligible) {
                closeQuestion(lockedRoom);
                completeIfBoardFinished(lockedRoom);
                const autoNextAtServerMs = this.assignAutoNextQuestion(lockedRoom);
                return {
                  room: lockedRoom,
                  rejectionCode: "FALSE_START",
                  questionClosed: {
                    questionId: payload.questionId,
                    correctAnswerDisplay: lockedRoom.game.currentQuestion?.answerDisplay ?? "",
                    correctAnswerComment: lockedRoom.game.currentQuestion?.answerComment ?? "",
                    autoNextAtServerMs,
                  },
                };
              }
              return {
                room: lockedRoom,
                rejectionCode: "FALSE_START",
                questionClosed: null as null | {
                  questionId: string;
                  correctAnswerDisplay: string;
                  correctAnswerComment: string;
                  autoNextAtServerMs: number | null;
                },
              };
            }

            throw new Error("TOO_EARLY");
          }

          if (effectivePressMs > closeAtServerMs) {
            throw new Error("BUZZ_WINDOW_CLOSED");
          }

          if (lockedRoom.game.buzzer.state !== "OPEN") {
            lockedRoom.game.buzzer.state = "OPEN";
            lockedRoom.game.buzzer.openedAtServerMs = openAtServerMs;
          }

          const hadAttempts = lockedRoom.game.buzzer.attempts.length > 0;
          lockedRoom.game.buzzer.attempts.push({
            userId: player.userId,
            recvServerMs,
            pressClientMs: payload.pressClientMs,
            offsetMs: effectiveOffsetMs,
            rttMs: effectiveRttMs,
            effectivePressMs,
          });

          if (!lockedRoom.game.buzzer.resolveAtServerMs) {
            lockedRoom.game.buzzer.resolveAtServerMs = Math.min(
              recvServerMs + lockedRoom.settings.buzzResolveWindowMs,
              closeAtServerMs,
            );
            this.scheduleBuzzerFinalization(lockedRoom.code, lockedRoom.game.buzzer.resolveAtServerMs);
          }

          if (!hadAttempts) {
            this.pauseQuestionTimelineForAnswering(lockedRoom, recvServerMs);
            this.clearQuestionWindowTimer(lockedRoom.code);
          }

          return {
            room: lockedRoom,
            rejectionCode: null as string | null,
            questionClosed: null as null | {
              questionId: string;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              autoNextAtServerMs: number | null;
            },
          };
        });

        this.emitRoomState(outcome.room);

        if (outcome.rejectionCode) {
          if (outcome.questionClosed) {
            this.clearQuestionWindowTimer(payload.roomCode);
            this.clearBuzzerFinalizationTimer(payload.roomCode);
            this.io.to(payload.roomCode).emit("question_closed", {
              questionId: outcome.questionClosed.questionId,
              correctAnswerDisplay: outcome.questionClosed.correctAnswerDisplay,
              correctAnswerComment: outcome.questionClosed.correctAnswerComment,
              autoNextAtServerMs: outcome.questionClosed.autoNextAtServerMs,
              scores: this.extractScores(outcome.room),
            });
            if (outcome.questionClosed.autoNextAtServerMs) {
              this.scheduleAutoNextQuestion(payload.roomCode, outcome.questionClosed.autoNextAtServerMs);
            } else {
              this.clearAutoNextQuestionTimer(payload.roomCode);
            }
          }

          ack?.(failure(outcome.rejectionCode, "Buzz attempt rejected."));
          socket.emit("buzz_rejected", { reason: outcome.rejectionCode });
          return;
        }

        ack?.(ok({ recvServerMs }));
      } catch (error) {
        if (error instanceof Error) {
          ack?.(failure(error.message, "Buzz attempt rejected."));
          socket.emit("buzz_rejected", { reason: error.message });
          return;
        }

        ack?.(failure("BUZZ_FAILED", "Unable to process buzz."));
      }
    });

    socket.on("answer_submitted", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = answerSubmittedSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid answer_submitted payload."));
        return;
      }

      const payload = parsed.data;

      try {
        const acceptedAnswers = await this.quizRepository.getAcceptedAnswers(payload.questionId);

        const outcome = await this.roomStore.withRoomLock(payload.roomCode, async (room) => {
          if (room.status !== "ANSWERING") {
            throw new Error("NOT_IN_ANSWERING_STATE");
          }

          if (room.game.currentQuestion?.id !== payload.questionId) {
            throw new Error("QUESTION_MISMATCH");
          }

          if (room.game.answering.activeUserId !== socket.data.userId) {
            throw new Error("NOT_ACTIVE_ANSWERER");
          }

          const currentQuestion = room.game.currentQuestion;
          if (!currentQuestion) {
            throw new Error("QUESTION_MISSING");
          }

          const result = evaluateAnswer(payload.answerText, acceptedAnswers);
          let wrongOutcome: "REOPENED" | "CLOSED" | null = null;
          let autoNextAtServerMs: number | null = null;

          if (result.isCorrect) {
            applyScoreDelta(room, socket.data.userId, currentQuestion.points);
            closeQuestion(room);
            completeIfBoardFinished(room);
            autoNextAtServerMs = this.assignAutoNextQuestion(room);
          } else {
            applyScoreDelta(room, socket.data.userId, -currentQuestion.points);
            wrongOutcome = markWrongAnswer(room, socket.data.userId, {
              fallbackReopenWindowMs: room.settings.buzzWindowMs ?? 7_000,
            });

            if (wrongOutcome === "CLOSED") {
              closeQuestion(room);
              completeIfBoardFinished(room);
              autoNextAtServerMs = this.assignAutoNextQuestion(room);
            }
          }

          return {
            room,
            answerResult: result,
            isCorrect: result.isCorrect,
            scoreDelta: result.isCorrect ? currentQuestion.points : -currentQuestion.points,
            correctAnswerDisplay: currentQuestion.answerDisplay,
            correctAnswerComment: currentQuestion.answerComment,
            autoNextAtServerMs,
            buzzReopened: wrongOutcome === "REOPENED",
          };
        });

        this.clearAnswerDeadlineTimer(payload.roomCode);

        this.io.to(payload.roomCode).emit("answer_result", {
          questionId: payload.questionId,
          userId: socket.data.userId,
          isCorrect: outcome.isCorrect,
          scoreDelta: outcome.scoreDelta,
          normalizedInput: outcome.answerResult.normalizedInput,
          matchedAnswerId: outcome.answerResult.matchedAnswerId,
          distance: outcome.answerResult.distance,
          threshold: outcome.answerResult.threshold,
        });

        if (outcome.isCorrect || outcome.room.status === "QUESTION_CLOSED" || outcome.room.status === "FINISHED") {
          this.clearQuestionWindowTimer(payload.roomCode);
          this.clearBuzzerFinalizationTimer(payload.roomCode);
          this.io.to(payload.roomCode).emit("question_closed", {
            questionId: payload.questionId,
            correctAnswerDisplay: outcome.correctAnswerDisplay,
            correctAnswerComment: outcome.correctAnswerComment,
            autoNextAtServerMs: outcome.autoNextAtServerMs,
            scores: this.extractScores(outcome.room),
          });
          if (outcome.autoNextAtServerMs) {
            this.scheduleAutoNextQuestion(payload.roomCode, outcome.autoNextAtServerMs);
          } else {
            this.clearAutoNextQuestionTimer(payload.roomCode);
          }
        } else if (outcome.buzzReopened) {
          this.scheduleQuestionWindowForOpenState(payload.roomCode, outcome.room);
        }

        this.emitRoomState(outcome.room);
        ack?.(ok({ accepted: true, isCorrect: outcome.isCorrect }));
      } catch (error) {
        if (error instanceof Error) {
          ack?.(failure(error.message, "Answer submission rejected."));
          return;
        }

        ack?.(failure("ANSWER_FAILED", "Unable to process answer."));
      }
    });

    socket.on("answer_draft", async (rawPayload: unknown) => {
      const parsed = answerDraftSchema.safeParse(rawPayload);
      if (!parsed.success) {
        return;
      }

      try {
        await this.roomStore.withRoomLock(parsed.data.roomCode, async (room) => {
          if (room.status !== "ANSWERING") {
            return room;
          }

          if (room.game.currentQuestion?.id !== parsed.data.questionId) {
            return room;
          }

          if (room.game.answering.activeUserId !== socket.data.userId) {
            return room;
          }

          room.game.answering.draftAnswerText = parsed.data.answerText.trim().slice(0, 200);
          return room;
        });
      } catch {
        // ignore draft updates that race with room state transitions
      }
    });

    socket.on("heartbeat", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = heartbeatSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid heartbeat payload."));
        return;
      }

      try {
        const outcome = await this.roomStore.withRoomLock(parsed.data.roomCode, async (lockedRoom) => {
          const player = lockedRoom.players[socket.data.userId];
          if (!player) {
            throw new Error("PLAYER_NOT_IN_ROOM");
          }

          player.lastSeenAtMs = Date.now();
          player.connected = true;
          player.socketId = socket.id;

          const timedOutQuestion = this.closeOverdueQuestionIfNeeded(lockedRoom);
          return { room: lockedRoom, timedOutQuestion };
        });

        if (outcome.timedOutQuestion) {
          this.clearQuestionWindowTimer(parsed.data.roomCode);
          this.clearBuzzerFinalizationTimer(parsed.data.roomCode);
          this.io.to(parsed.data.roomCode).emit("question_closed", {
            questionId: outcome.timedOutQuestion.questionId,
            correctAnswerDisplay: outcome.timedOutQuestion.correctAnswerDisplay,
            correctAnswerComment: outcome.timedOutQuestion.correctAnswerComment,
            autoNextAtServerMs: outcome.timedOutQuestion.autoNextAtServerMs,
            scores: this.extractScores(outcome.room),
          });

          if (outcome.timedOutQuestion.autoNextAtServerMs) {
            this.scheduleAutoNextQuestion(parsed.data.roomCode, outcome.timedOutQuestion.autoNextAtServerMs);
          } else {
            this.clearAutoNextQuestionTimer(parsed.data.roomCode);
          }
        } else {
          this.restoreTimersForRoomState(parsed.data.roomCode, outcome.room);
        }

        this.emitRoomState(outcome.room);
        ack?.(ok({ now: Date.now() }));
      } catch (error) {
        ack?.(failure("HEARTBEAT_FAILED", "Unable to process heartbeat."));
      }
    });

    socket.on("disconnect", () => {
      void this.handleDisconnect(socket);
    });
  }

  private async handleDisconnect(socket: GameSocket): Promise<void> {
    const roomCode = socket.data.roomCode;

    if (!roomCode) {
      return;
    }

    try {
      const outcome = await this.roomStore.withRoomLock(roomCode, async (room) => {
        const player = room.players[socket.data.userId];
        if (!player) {
          return {
            room,
            migration: null,
            disconnectedUserId: null as string | null,
            graceMs: room.settings.disconnectGraceMs,
            clearAnswerTimer: false,
          };
        }

        player.connected = false;
        player.lastSeenAtMs = Date.now();

        const currentQuestion = room.game.currentQuestion;
        let clearAnswerTimer = false;
        let questionClosed: null | {
          questionId: string;
          correctAnswerDisplay: string;
          correctAnswerComment: string;
          autoNextAtServerMs: number | null;
        } = null;

        if (
          currentQuestion &&
          room.status === "ANSWERING" &&
          room.game.answering.activeUserId === player.userId
        ) {
          clearAnswerTimer = true;
          applyScoreDelta(room, player.userId, -currentQuestion.points);
          const wrongOutcome = markWrongAnswer(room, player.userId, {
            fallbackReopenWindowMs: room.settings.buzzWindowMs ?? 7_000,
          });
          if (wrongOutcome === "CLOSED") {
            closeQuestion(room);
            completeIfBoardFinished(room);
            questionClosed = {
              questionId: currentQuestion.id,
              correctAnswerDisplay: currentQuestion.answerDisplay,
              correctAnswerComment: currentQuestion.answerComment,
              autoNextAtServerMs: this.assignAutoNextQuestion(room),
            };
          }
        }

        const migration = migrateHostIfNeeded(room);

        return {
          room,
          migration,
            disconnectedUserId: player.userId,
            graceMs: room.settings.disconnectGraceMs,
            clearAnswerTimer,
            questionClosed,
            buzzReopened:
              room.status === "QUESTION_OPEN" &&
              room.game.buzzer.closeAtServerMs != null,
          };
        });

      if (outcome.clearAnswerTimer) {
        this.clearAnswerDeadlineTimer(roomCode);
      }

      if (outcome.buzzReopened) {
        this.scheduleQuestionWindowForOpenState(roomCode, outcome.room);
      } else if (outcome.questionClosed) {
        this.clearQuestionWindowTimer(roomCode);
        this.clearBuzzerFinalizationTimer(roomCode);
        this.io.to(roomCode).emit("question_closed", {
          questionId: outcome.questionClosed.questionId,
          correctAnswerDisplay: outcome.questionClosed.correctAnswerDisplay,
          correctAnswerComment: outcome.questionClosed.correctAnswerComment,
          autoNextAtServerMs: outcome.questionClosed.autoNextAtServerMs,
          scores: this.extractScores(outcome.room),
        });
        if (outcome.questionClosed.autoNextAtServerMs) {
          this.scheduleAutoNextQuestion(roomCode, outcome.questionClosed.autoNextAtServerMs);
        } else {
          this.clearAutoNextQuestionTimer(roomCode);
        }
      } else if (outcome.room.status === "QUESTION_CLOSED" && outcome.room.game.autoNextQuestionAtServerMs) {
        this.scheduleAutoNextQuestion(roomCode, outcome.room.game.autoNextQuestionAtServerMs);
      } else if (outcome.room.status === "QUESTION_CLOSED") {
        this.clearQuestionWindowTimer(roomCode);
        this.clearBuzzerFinalizationTimer(roomCode);
        this.clearAutoNextQuestionTimer(roomCode);
      } else if (outcome.room.status === "FINISHED") {
        this.clearQuestionWindowTimer(roomCode);
        this.clearBuzzerFinalizationTimer(roomCode);
        this.clearAutoNextQuestionTimer(roomCode);
      }

      if (outcome.disconnectedUserId) {
        this.io.to(roomCode).emit("player_presence", {
          userId: outcome.disconnectedUserId,
          connected: false,
          atMs: Date.now(),
        });

        this.scheduleDisconnectExpiry(roomCode, outcome.disconnectedUserId, outcome.graceMs);
      }

      if (outcome.migration) {
        this.io.to(roomCode).emit("host_migrated", {
          oldHostUserId: outcome.migration.oldHostUserId,
          newHostUserId: outcome.migration.newHostUserId,
          reason: "disconnect",
        });
      }

      this.emitRoomState(outcome.room);
    } catch (error) {
      logger.warn("disconnect handling failed", error);
    }
  }

  private clearBuzzerFinalizationTimer(roomCode: string): void {
    const existing = this.buzzerTimers.get(roomCode);
    if (!existing) {
      return;
    }

    clearTimeout(existing);
    this.buzzerTimers.delete(roomCode);
  }

  private clearQuestionWindowTimer(roomCode: string): void {
    const existing = this.questionWindowTimers.get(roomCode);
    if (!existing) {
      return;
    }

    clearTimeout(existing);
    this.questionWindowTimers.delete(roomCode);
  }

  private scheduleQuestionWindowOpen(roomCode: string, openAtServerMs: number): void {
    this.clearQuestionWindowTimer(roomCode);

    const timeoutMs = Math.max(0, openAtServerMs - Date.now());
    const timer = setTimeout(() => {
      void this.handleQuestionWindowOpen(roomCode);
    }, timeoutMs);

    this.questionWindowTimers.set(roomCode, timer);
  }

  private scheduleQuestionWindowClose(roomCode: string, closeAtServerMs: number): void {
    this.clearQuestionWindowTimer(roomCode);

    const timeoutMs = Math.max(0, closeAtServerMs - Date.now());
    const timer = setTimeout(() => {
      void this.handleQuestionWindowClose(roomCode);
    }, timeoutMs);

    this.questionWindowTimers.set(roomCode, timer);
  }

  private clearAnswerDeadlineTimer(roomCode: string): void {
    const existing = this.answerTimers.get(roomCode);
    if (!existing) {
      return;
    }

    clearTimeout(existing);
    this.answerTimers.delete(roomCode);
  }

  private clearAutoNextQuestionTimer(roomCode: string): void {
    const existing = this.autoNextQuestionTimers.get(roomCode);
    if (!existing) {
      return;
    }

    clearTimeout(existing);
    this.autoNextQuestionTimers.delete(roomCode);
  }

  private clearRoomTimers(roomCode: string): void {
    this.clearBuzzerFinalizationTimer(roomCode);
    this.clearQuestionWindowTimer(roomCode);
    this.clearAnswerDeadlineTimer(roomCode);
    this.clearAutoNextQuestionTimer(roomCode);
  }

  private scheduleDisconnectExpiry(roomCode: string, userId: string, graceMs: number): void {
    const key = `${roomCode}:${userId}`;

    const existingTimer = this.disconnectTimers.get(key);
    if (existingTimer) {
      clearTimeout(existingTimer);
    }

    const timer = setTimeout(() => {
      void this.expireDisconnectedPlayer(roomCode, userId);
    }, graceMs);

    this.disconnectTimers.set(key, timer);
  }

  private scheduleAnswerDeadline(roomCode: string, deadlineServerMs: number): void {
    this.clearAnswerDeadlineTimer(roomCode);

    const timeoutMs = Math.max(0, deadlineServerMs - Date.now());
    const timer = setTimeout(() => {
      void this.handleAnswerDeadline(roomCode);
    }, timeoutMs);

    this.answerTimers.set(roomCode, timer);
  }

  private scheduleAutoNextQuestion(roomCode: string, openAtServerMs: number): void {
    this.clearAutoNextQuestionTimer(roomCode);

    const timeoutMs = Math.max(0, openAtServerMs - Date.now());
    const timer = setTimeout(() => {
      void this.handleAutoNextQuestion(roomCode);
    }, timeoutMs);

    this.autoNextQuestionTimers.set(roomCode, timer);
  }

  private restoreTimersForRoomState(roomCode: string, room: RoomState): void {
    if (room.status === "QUESTION_OPEN") {
      if (room.game.buzzer.attempts.length > 0 && room.game.buzzer.resolveAtServerMs) {
        this.scheduleBuzzerFinalization(roomCode, room.game.buzzer.resolveAtServerMs);
      } else {
        this.scheduleQuestionWindowForOpenState(roomCode, room);
      }
      return;
    }

    if (room.status === "ANSWERING") {
      if (room.game.answering.deadlineServerMs) {
        this.scheduleAnswerDeadline(roomCode, room.game.answering.deadlineServerMs);
      }
      return;
    }

    if (room.status === "QUESTION_CLOSED") {
      if (room.game.autoNextQuestionAtServerMs) {
        this.scheduleAutoNextQuestion(roomCode, room.game.autoNextQuestionAtServerMs);
      }
      return;
    }
  }

  private closeOverdueQuestionIfNeeded(room: RoomState): null | {
    questionId: string;
    correctAnswerDisplay: string;
    correctAnswerComment: string;
    autoNextAtServerMs: number | null;
  } {
    if (room.status !== "QUESTION_OPEN") {
      return null;
    }

    if (room.game.buzzer.attempts.length > 0) {
      return null;
    }

    const closeAtServerMs = room.game.buzzer.closeAtServerMs;
    if (!closeAtServerMs || Date.now() < closeAtServerMs) {
      return null;
    }

    const question = room.game.currentQuestion;
    if (!question) {
      return null;
    }

    closeQuestion(room);
    completeIfBoardFinished(room);
    const autoNextAtServerMs = this.assignAutoNextQuestion(room);

    return {
      questionId: question.id,
      correctAnswerDisplay: question.answerDisplay,
      correctAnswerComment: question.answerComment,
      autoNextAtServerMs,
    };
  }

  private assignAutoNextQuestion(room: RoomState): number | null {
    if (room.status !== "QUESTION_CLOSED" || room.game.board.remainingQuestionIds.length === 0) {
      room.game.autoNextQuestionAtServerMs = null;
      return null;
    }

    const autoNextAtServerMs = Date.now() + CORRECT_ANSWER_REVEAL_MS;
    room.game.autoNextQuestionAtServerMs = autoNextAtServerMs;
    return autoNextAtServerMs;
  }

  private scheduleQuestionWindowForOpenState(roomCode: string, room: RoomState): void {
    this.clearQuestionWindowTimer(roomCode);
    const openAtServerMs = room.game.buzzer.openAtServerMs;
    const closeAtServerMs = room.game.buzzer.closeAtServerMs;
    if (!openAtServerMs || !closeAtServerMs) {
      return;
    }

    if (openAtServerMs > Date.now()) {
      this.scheduleQuestionWindowOpen(roomCode, openAtServerMs);
      return;
    }

    this.scheduleQuestionWindowClose(roomCode, closeAtServerMs);
  }

  private pauseQuestionTimelineForAnswering(room: RoomState, pausedAtServerMs: number): void {
    const question = room.game.currentQuestion;
    if (!question) {
      return;
    }

    const revealDurationMs = Math.max(
      1,
      question.revealDurationMs ?? this.computeQuestionRevealDurationMs(question.prompt),
    );
    const baseRevealedMs = Math.max(
      0,
      Math.min(revealDurationMs, question.revealedMs ?? 0),
    );
    const resumedAtServerMs = question.revealResumedAtServerMs;
    const liveRevealMs =
      resumedAtServerMs == null ? 0 : Math.max(0, pausedAtServerMs - resumedAtServerMs);
    const revealedMs = Math.max(
      0,
      Math.min(revealDurationMs, baseRevealedMs + liveRevealMs),
    );

    question.revealDurationMs = revealDurationMs;
    question.revealedMs = revealedMs;
    question.revealResumedAtServerMs = null;

    room.game.answering.pausedReadRemainingMs = Math.max(0, revealDurationMs - revealedMs);
    room.game.answering.pausedCloseRemainingMs = room.game.buzzer.closeAtServerMs
      ? Math.max(0, room.game.buzzer.closeAtServerMs - pausedAtServerMs)
      : room.settings.buzzWindowMs ?? 7_000;

    room.game.buzzer.readStartedAtServerMs = null;
    room.game.buzzer.readEndsAtServerMs = null;
  }

  private async handleQuestionWindowOpen(roomCode: string): Promise<void> {
    this.questionWindowTimers.delete(roomCode);

    try {
      const outcome = await this.roomStore.withRoomLock(roomCode, async (room) => {
        if (room.status !== "QUESTION_OPEN") {
          return {
            room,
            opened: null as null | {
              questionId: string;
              openAtServerMs: number;
              closeAtServerMs: number;
            },
            closed: null as null | {
              questionId: string;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              autoNextAtServerMs: number | null;
            },
          };
        }

        const question = room.game.currentQuestion;
        const openAtServerMs = room.game.buzzer.openAtServerMs;
        const closeAtServerMs = room.game.buzzer.closeAtServerMs;
        if (!question || !openAtServerMs || !closeAtServerMs) {
          return {
            room,
            opened: null as null | {
              questionId: string;
              openAtServerMs: number;
              closeAtServerMs: number;
            },
            closed: null as null | {
              questionId: string;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              autoNextAtServerMs: number | null;
            },
          };
        }

        if (Date.now() >= closeAtServerMs) {
          closeQuestion(room);
          completeIfBoardFinished(room);
          const autoNextAtServerMs = this.assignAutoNextQuestion(room);
          return {
            room,
            opened: null as null | {
              questionId: string;
              openAtServerMs: number;
              closeAtServerMs: number;
            },
            closed: {
              questionId: question.id,
              correctAnswerDisplay: question.answerDisplay,
              correctAnswerComment: question.answerComment,
              autoNextAtServerMs,
            },
          };
        }

        const eligiblePlayers = Object.values(room.players).some(
          (player) =>
            player.connected &&
            player.canBuzz &&
            !room.game.buzzer.lockedOutUserIds.includes(player.userId),
        );
        if (!eligiblePlayers) {
          closeQuestion(room);
          completeIfBoardFinished(room);
          const autoNextAtServerMs = this.assignAutoNextQuestion(room);
          return {
            room,
            opened: null as null | {
              questionId: string;
              openAtServerMs: number;
              closeAtServerMs: number;
            },
            closed: {
              questionId: question.id,
              correctAnswerDisplay: question.answerDisplay,
              correctAnswerComment: question.answerComment,
              autoNextAtServerMs,
            },
          };
        }

        room.game.buzzer.state = "OPEN";
        room.game.buzzer.openedAtServerMs = openAtServerMs;

        return {
          room,
          opened: {
            questionId: question.id,
            openAtServerMs,
            closeAtServerMs,
          },
          closed: null as null | {
            questionId: string;
            correctAnswerDisplay: string;
            correctAnswerComment: string;
            autoNextAtServerMs: number | null;
          },
        };
      });

      if (outcome.opened) {
        this.io.to(roomCode).emit("buzzer_window_opened", {
          questionId: outcome.opened.questionId,
          openAtServerMs: outcome.opened.openAtServerMs,
          closeAtServerMs: outcome.opened.closeAtServerMs,
        });
        this.scheduleQuestionWindowClose(roomCode, outcome.opened.closeAtServerMs);
      } else if (outcome.closed) {
        this.clearBuzzerFinalizationTimer(roomCode);
        this.io.to(roomCode).emit("question_closed", {
          questionId: outcome.closed.questionId,
          correctAnswerDisplay: outcome.closed.correctAnswerDisplay,
          correctAnswerComment: outcome.closed.correctAnswerComment,
          autoNextAtServerMs: outcome.closed.autoNextAtServerMs,
          scores: this.extractScores(outcome.room),
        });
        if (outcome.closed.autoNextAtServerMs) {
          this.scheduleAutoNextQuestion(roomCode, outcome.closed.autoNextAtServerMs);
        } else {
          this.clearAutoNextQuestionTimer(roomCode);
        }
      }

      this.emitRoomState(outcome.room);
    } catch (error) {
      logger.warn("question window open handling failed", { roomCode, error });
    }
  }

  private async handleQuestionWindowClose(roomCode: string): Promise<void> {
    this.questionWindowTimers.delete(roomCode);

    try {
      const outcome = await this.roomStore.withRoomLock(roomCode, async (room) => {
        if (room.status !== "QUESTION_OPEN") {
          return {
            room,
            closed: null as null | {
              questionId: string;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              autoNextAtServerMs: number | null;
            },
            shouldFinalize: false,
            resolveAtServerMs: null as number | null,
          };
        }

        if (room.game.buzzer.attempts.length > 0 && room.game.buzzer.resolveAtServerMs) {
          return {
            room,
            closed: null as null | {
              questionId: string;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              autoNextAtServerMs: number | null;
            },
            shouldFinalize: true,
            resolveAtServerMs: room.game.buzzer.resolveAtServerMs,
          };
        }

        const question = room.game.currentQuestion;
        if (!question) {
          return {
            room,
            closed: null as null | {
              questionId: string;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              autoNextAtServerMs: number | null;
            },
            shouldFinalize: false,
            resolveAtServerMs: null as number | null,
          };
        }

        closeQuestion(room);
        completeIfBoardFinished(room);
        const autoNextAtServerMs = this.assignAutoNextQuestion(room);
        return {
          room,
          closed: {
            questionId: question.id,
            correctAnswerDisplay: question.answerDisplay,
            correctAnswerComment: question.answerComment,
            autoNextAtServerMs,
          },
          shouldFinalize: false,
          resolveAtServerMs: null as number | null,
        };
      });

      if (outcome.shouldFinalize && outcome.resolveAtServerMs) {
        this.scheduleBuzzerFinalization(roomCode, outcome.resolveAtServerMs);
      }

      if (outcome.closed) {
        this.clearBuzzerFinalizationTimer(roomCode);
        this.io.to(roomCode).emit("question_closed", {
          questionId: outcome.closed.questionId,
          correctAnswerDisplay: outcome.closed.correctAnswerDisplay,
          correctAnswerComment: outcome.closed.correctAnswerComment,
          autoNextAtServerMs: outcome.closed.autoNextAtServerMs,
          scores: this.extractScores(outcome.room),
        });
        if (outcome.closed.autoNextAtServerMs) {
          this.scheduleAutoNextQuestion(roomCode, outcome.closed.autoNextAtServerMs);
        } else {
          this.clearAutoNextQuestionTimer(roomCode);
        }
      }

      this.emitRoomState(outcome.room);
    } catch (error) {
      logger.warn("question window close handling failed", { roomCode, error });
    }
  }

  private async handleAnswerDeadline(roomCode: string): Promise<void> {
    this.answerTimers.delete(roomCode);

    try {
      const outcome = await this.roomStore.withRoomLock(roomCode, async (room) => {
        if (room.status !== "ANSWERING") {
          return {
            room,
            result: null as null | {
              questionId: string;
              userId: string;
              isCorrect: boolean;
              scoreDelta: number;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              shouldCloseQuestion: boolean;
              buzzReopened: boolean;
              autoNextAtServerMs: number | null;
              answerResult: {
                normalizedInput: string;
                matchedAnswerId: string | null;
                distance: number | null;
                threshold: number | null;
              };
            },
          };
        }

        const currentQuestion = room.game.currentQuestion;
        const activeUserId = room.game.answering.activeUserId;
        if (!currentQuestion || !activeUserId) {
          return {
            room,
            result: null as null | {
              questionId: string;
              userId: string;
              isCorrect: boolean;
              scoreDelta: number;
              correctAnswerDisplay: string;
              correctAnswerComment: string;
              shouldCloseQuestion: boolean;
              buzzReopened: boolean;
              autoNextAtServerMs: number | null;
              answerResult: {
                normalizedInput: string;
                matchedAnswerId: string | null;
                distance: number | null;
                threshold: number | null;
              };
            },
          };
        }

        const draftAnswer = room.game.answering.draftAnswerText.trim();
        const acceptedAnswers = await this.quizRepository.getAcceptedAnswers(currentQuestion.id);
        const answerResult = evaluateAnswer(draftAnswer, acceptedAnswers);

        if (answerResult.isCorrect) {
          applyScoreDelta(room, activeUserId, currentQuestion.points);
          closeQuestion(room);
          completeIfBoardFinished(room);
          const autoNextAtServerMs = this.assignAutoNextQuestion(room);

          return {
            room,
            result: {
              questionId: currentQuestion.id,
              userId: activeUserId,
              isCorrect: true,
              scoreDelta: currentQuestion.points,
              correctAnswerDisplay: currentQuestion.answerDisplay,
              correctAnswerComment: currentQuestion.answerComment,
              shouldCloseQuestion: true,
              buzzReopened: false,
              autoNextAtServerMs,
              answerResult: {
                normalizedInput: answerResult.normalizedInput,
                matchedAnswerId: answerResult.matchedAnswerId,
                distance: answerResult.distance,
                threshold: answerResult.threshold,
              },
            },
          };
        }

        applyScoreDelta(room, activeUserId, -currentQuestion.points);
        const wrongOutcome = markWrongAnswer(room, activeUserId, {
          fallbackReopenWindowMs: room.settings.buzzWindowMs ?? 7_000,
        });

        if (wrongOutcome === "CLOSED") {
          closeQuestion(room);
          completeIfBoardFinished(room);
        }
        const autoNextAtServerMs =
          wrongOutcome === "CLOSED" ? this.assignAutoNextQuestion(room) : null;

        return {
          room,
          result: {
            questionId: currentQuestion.id,
            userId: activeUserId,
            isCorrect: false,
            scoreDelta: -currentQuestion.points,
            correctAnswerDisplay: currentQuestion.answerDisplay,
            correctAnswerComment: currentQuestion.answerComment,
            shouldCloseQuestion: wrongOutcome === "CLOSED",
            buzzReopened: wrongOutcome === "REOPENED",
            autoNextAtServerMs,
            answerResult: {
              normalizedInput: answerResult.normalizedInput,
              matchedAnswerId: answerResult.matchedAnswerId,
              distance: answerResult.distance,
              threshold: answerResult.threshold,
            },
          },
        };
      });

      if (outcome.result) {
        this.io.to(roomCode).emit("answer_result", {
          questionId: outcome.result.questionId,
          userId: outcome.result.userId,
          isCorrect: outcome.result.isCorrect,
          scoreDelta: outcome.result.scoreDelta,
          timedOut: true,
          normalizedInput: outcome.result.answerResult.normalizedInput,
          matchedAnswerId: outcome.result.answerResult.matchedAnswerId,
          distance: outcome.result.answerResult.distance,
          threshold: outcome.result.answerResult.threshold,
        });

        if (outcome.result.isCorrect || outcome.result.shouldCloseQuestion) {
          this.clearQuestionWindowTimer(roomCode);
          this.clearBuzzerFinalizationTimer(roomCode);
          this.io.to(roomCode).emit("question_closed", {
            questionId: outcome.result.questionId,
            correctAnswerDisplay: outcome.result.correctAnswerDisplay,
            correctAnswerComment: outcome.result.correctAnswerComment,
            autoNextAtServerMs: outcome.result.autoNextAtServerMs,
            scores: this.extractScores(outcome.room),
          });
          if (outcome.result.autoNextAtServerMs) {
            this.scheduleAutoNextQuestion(roomCode, outcome.result.autoNextAtServerMs);
          } else {
            this.clearAutoNextQuestionTimer(roomCode);
          }
        } else if (outcome.result.buzzReopened) {
          this.scheduleQuestionWindowForOpenState(roomCode, outcome.room);
        }
      }

      this.emitRoomState(outcome.room);
    } catch (error) {
      logger.warn("answer deadline handling failed", { roomCode, error });
    }
  }

  private async expireDisconnectedPlayer(roomCode: string, userId: string): Promise<void> {
    const key = `${roomCode}:${userId}`;
    this.disconnectTimers.delete(key);

    try {
      const outcome = await this.roomStore.withRoomLock(roomCode, async (room) => {
        const player = room.players[userId];
        if (!player || player.connected) {
          return {
            room,
            removed: false,
            roomEmpty: Object.keys(room.players).length === 0,
            migration: null,
          };
        }

        delete room.players[userId];
        const migration = migrateHostIfNeeded(room);

        return {
          room,
          removed: true,
          roomEmpty: Object.keys(room.players).length === 0,
          migration,
        };
      });

      if (outcome.roomEmpty) {
        this.clearRoomTimers(roomCode);
        await this.roomStore.deleteByCode(roomCode);
        return;
      }

      if (outcome.migration) {
        this.io.to(roomCode).emit("host_migrated", {
          oldHostUserId: outcome.migration.oldHostUserId,
          newHostUserId: outcome.migration.newHostUserId,
          reason: "disconnect_timeout",
        });
      }

      if (outcome.removed) {
        this.io.to(roomCode).emit("player_presence", {
          userId,
          connected: false,
          atMs: Date.now(),
        });
      }

      this.emitRoomState(outcome.room);
    } catch (error) {
      logger.warn("disconnect expiry failed", { roomCode, userId, error });
    }
  }

  private scheduleBuzzerFinalization(roomCode: string, resolveAtServerMs: number): void {
    this.clearBuzzerFinalizationTimer(roomCode);

    const timeoutMs = Math.max(0, resolveAtServerMs - Date.now());

    const timer = setTimeout(() => {
      void this.finalizeBuzzer(roomCode);
    }, timeoutMs);

    this.buzzerTimers.set(roomCode, timer);
  }

  private async finalizeBuzzer(roomCode: string): Promise<void> {
    this.buzzerTimers.delete(roomCode);

    try {
      const outcome = await this.roomStore.withRoomLock(roomCode, async (room) => {
        if (room.status !== "QUESTION_OPEN") {
          return { room, result: null as FinalizeOutcome | null };
        }

        const question = room.game.currentQuestion;
        const attempts = room.game.buzzer.attempts;

        if (!question || attempts.length === 0) {
          room.game.buzzer.resolveAtServerMs = null;
          return { room, result: null as FinalizeOutcome | null };
        }

        attempts.sort(
          (a, b) =>
            a.effectivePressMs - b.effectivePressMs ||
            a.recvServerMs - b.recvServerMs ||
            a.userId.localeCompare(b.userId),
        );

        const winner = attempts[0];
        lockBuzzerWinner(room, winner.userId);

        return {
          room,
          result: {
            winnerUserId: winner.userId,
            effectivePressMs: winner.effectivePressMs,
            questionId: question.id,
          },
        };
      });

      if (!outcome.result) {
        this.emitRoomState(outcome.room);
        return;
      }

      const answerDeadlineMs = outcome.room.game.answering.deadlineServerMs;
      if (answerDeadlineMs) {
        this.scheduleAnswerDeadline(roomCode, answerDeadlineMs);
      }

      this.clearQuestionWindowTimer(roomCode);

      this.io.to(roomCode).emit("buzz_locked", {
        questionId: outcome.result.questionId,
        winnerUserId: outcome.result.winnerUserId,
        effectivePressMs: outcome.result.effectivePressMs,
        lockedAtServerMs: Date.now(),
      });

      this.emitRoomState(outcome.room);
    } catch (error) {
      logger.error("finalizeBuzzer failed", { roomCode, error });
    }
  }

  private async handleAutoNextQuestion(roomCode: string): Promise<void> {
    this.autoNextQuestionTimers.delete(roomCode);

    try {
      const roomSnapshot = await this.roomStore.getByCode(roomCode);
      if (
        !roomSnapshot ||
        roomSnapshot.status !== "QUESTION_CLOSED" ||
        roomSnapshot.game.board.remainingQuestionIds.length === 0
      ) {
        return;
      }

      const nextQuestionId = roomSnapshot.game.board.remainingQuestionIds[0];
      const nextQuestion = await this.quizRepository.getQuestionById(nextQuestionId);
      if (!nextQuestion) {
        logger.warn("auto next question not found in quiz repository", {
          roomCode,
          questionId: nextQuestionId,
        });
        return;
      }

      const outcome = await this.roomStore.withRoomLock(roomCode, async (room) => {
        if (room.status !== "QUESTION_CLOSED") {
          return { room, opened: false };
        }

        const expectedQuestionId = room.game.board.remainingQuestionIds[0];
        if (!expectedQuestionId || expectedQuestionId !== nextQuestionId) {
          return { room, opened: false };
        }

        this.openQuestionInRoom(room, nextQuestion);
        return { room, opened: true };
      });

      if (!outcome.opened) {
        this.emitRoomState(outcome.room);
        return;
      }

      this.clearBuzzerFinalizationTimer(roomCode);
      this.clearAnswerDeadlineTimer(roomCode);
      this.clearQuestionWindowTimer(roomCode);
      this.scheduleQuestionWindowForOpenState(roomCode, outcome.room);

      this.emitQuestionOpened(roomCode, outcome.room, nextQuestion);
      this.emitRoomState(outcome.room);
    } catch (error) {
      logger.warn("auto next question handling failed", { roomCode, error });
    }
  }

  private openQuestionInRoom(room: RoomState, question: QuizQuestionRow): void {
    const readStartedAtServerMs = Date.now();
    const revealDurationMs = this.computeQuestionRevealDurationMs(question.prompt);
    const readEndsAtServerMs = readStartedAtServerMs + revealDurationMs;
    const allowFalseStarts = room.settings.allowFalseStarts ?? true;
    const openAtServerMs = allowFalseStarts ? readEndsAtServerMs : readStartedAtServerMs;
    const closeAtServerMs = readEndsAtServerMs + (room.settings.buzzWindowMs ?? 7_000);

    openQuestion(room, {
      ...question,
      answerComment: question.answerComment ?? "",
      answerTimeLimitMs: ANSWER_INPUT_WINDOW_MS,
      revealDurationMs,
      revealedMs: 0,
      revealResumedAtServerMs: readStartedAtServerMs,
    });

    room.game.buzzer.readStartedAtServerMs = readStartedAtServerMs;
    room.game.buzzer.readEndsAtServerMs = readEndsAtServerMs;
    room.game.buzzer.openAtServerMs = openAtServerMs;
    room.game.buzzer.closeAtServerMs = closeAtServerMs;
    room.game.buzzer.state = openAtServerMs <= readStartedAtServerMs ? "OPEN" : "CLOSED";
    room.game.buzzer.openedAtServerMs = openAtServerMs <= readStartedAtServerMs ? readStartedAtServerMs : null;
  }

  private emitQuestionOpened(roomCode: string, room: RoomState, question: QuizQuestionRow): void {
    this.io.to(roomCode).emit("question_opened", {
      questionId: question.id,
      prompt: question.prompt,
      points: question.points,
      readStartedAtServerMs: room.game.buzzer.readStartedAtServerMs,
      readEndsAtServerMs: room.game.buzzer.readEndsAtServerMs,
      buzzOpenAtServerMs: room.game.buzzer.openAtServerMs,
      buzzCloseAtServerMs: room.game.buzzer.closeAtServerMs,
      buzzWindowMs: room.settings.buzzWindowMs ?? 7_000,
      falseStartsEnabled: room.settings.allowFalseStarts ?? true,
      openedAtServerMs: room.game.buzzer.openedAtServerMs,
    });
  }

  private computeQuestionRevealDurationMs(prompt: string): number {
    const estimatedMs = prompt.trim().length * QUESTION_REVEAL_PER_CHAR_MS;
    return Math.max(QUESTION_REVEAL_MIN_MS, Math.min(QUESTION_REVEAL_MAX_MS, estimatedMs));
  }

  private parseThemeTitlesFromPackageDescription(description: string): string[] {
    const marker = /темы?\s*:\s*/i;
    const markerMatch = marker.exec(description);
    if (!markerMatch) {
      return [];
    }

    const rawTail = description.slice(markerMatch.index + markerMatch[0].length);
    const mainPart = rawTail
      .split(/\.\s|\n/u)
      .map((part) => part.trim())
      .find((part) => part.length > 0) ?? "";

    return mainPart
      .split(";")
      .map((part) => part.trim())
      .filter((part) => part.length > 0);
  }

  private fallbackThemeTitlesByPackageId(packageId: string): Record<string, string> {
    if (packageId === "88888888-8888-8888-8888-000000000002") {
      return {
        "1": "ПРЯНОСТИ",
        "2": "КРЫЛЬЯ",
        "3": "НАЧИНАЕТСЯ С ПРИСТАВКИ",
        "4": "МАТРИЧНАЯ -МИР-",
        "5": "ИГРЫ",
        "6": "КОРОЛЕВСКОЕ ГЕОГРАФИЧЕСКОЕ ОБЩЕСТВО",
      };
    }

    return {};
  }

  private resolveThemeTitlesByRow(
    questions: QuizQuestionRow[],
    packageId: string,
    packageDescription: string,
  ): Record<string, string> {
    const rows = Array.from(new Set(questions.map((question) => question.boardRow))).sort((a, b) => a - b);
    const parsedTitles = this.parseThemeTitlesFromPackageDescription(packageDescription);
    const fallbackTitles = this.fallbackThemeTitlesByPackageId(packageId);
    const titlesByRow: Record<string, string> = {};

    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      const key = String(row);
      const parsed = parsedTitles[index]?.trim();
      const fallback = fallbackTitles[key]?.trim();
      titlesByRow[key] = parsed && parsed.length > 0
        ? parsed
        : fallback && fallback.length > 0
          ? fallback
          : `Тема ${row}`;
    }

    return titlesByRow;
  }

  private validatePackageStructure(questions: QuizQuestionRow[]): PackageStructureValidation {
    if (questions.length === 0) {
      return { valid: false, reason: "Selected package has no questions." };
    }

    const hasOnlyFirstRound = questions.every((question) => question.roundNo === 1);
    if (!hasOnlyFirstRound) {
      return { valid: false, reason: "Only single-round packages are supported for now." };
    }

    const byRow = new Map<number, Map<number, QuizQuestionRow>>();
    for (const question of questions) {
      if (!Number.isInteger(question.boardRow) || !Number.isInteger(question.boardCol)) {
        return { valid: false, reason: "Invalid question coordinates in selected package." };
      }

      if (question.boardRow < 1 || question.boardCol < 1 || question.boardCol > 5) {
        return { valid: false, reason: "Question coordinates must be in range row>=1 and col 1..5." };
      }

      const row = byRow.get(question.boardRow) ?? new Map<number, QuizQuestionRow>();
      if (row.has(question.boardCol)) {
        return { valid: false, reason: "Package has duplicate questions in the same row/column slot." };
      }

      row.set(question.boardCol, question);
      byRow.set(question.boardRow, row);
    }

    if (byRow.size < 4 || byRow.size > 8) {
      return { valid: false, reason: "Package must contain from 4 to 8 themes." };
    }

    const orderedRows = Array.from(byRow.keys()).sort((a, b) => a - b);
    const orderedQuestionIds: string[] = [];

    for (const rowNumber of orderedRows) {
      const row = byRow.get(rowNumber);
      if (!row || row.size !== 5) {
        return { valid: false, reason: "Each theme must contain exactly 5 questions." };
      }

      const orderedCols = Array.from(row.keys()).sort((a, b) => a - b);
      for (let index = 0; index < 5; index += 1) {
        if (orderedCols[index] !== index + 1) {
          return { valid: false, reason: "Questions in each theme must have sequential columns 1..5." };
        }
      }

      let previousPoints: number | null = null;
      for (const col of orderedCols) {
        const question = row.get(col);
        if (!question) {
          continue;
        }

        if (previousPoints != null && question.points < previousPoints) {
          return { valid: false, reason: "Question points must increase by difficulty order in each theme." };
        }

        previousPoints = question.points;
      }
    }

    // Fixed order for gameplay: by difficulty column first, then by theme row.
    for (let col = 1; col <= 5; col += 1) {
      for (const rowNumber of orderedRows) {
        const question = byRow.get(rowNumber)?.get(col);
        if (!question) {
          return { valid: false, reason: "Each theme must contain exactly 5 questions." };
        }
        orderedQuestionIds.push(question.id);
      }
    }

    return {
      valid: true,
      orderedQuestionIds,
    };
  }

  private toPublicRoomSummary(room: RoomState): PublicRoomSummary {
    const host = room.players[room.hostUserId];
    const playersCount = Object.keys(room.players).length;
    return {
      roomId: room.roomId,
      roomCode: room.code,
      status: room.status,
      hostUserId: room.hostUserId,
      hostName: host?.name ?? "Host",
      playersCount,
      maxPlayers: room.settings.maxPlayers,
      hasFreeSlots: playersCount < room.settings.maxPlayers,
      createdAtMs: room.createdAtMs,
    };
  }

  private emitRoomState(room: RoomState): void {
    this.io.to(room.code).emit("room_state", {
      version: room.version,
      state: toPublicRoomState(room),
    });
  }

  private extractScores(room: RoomState): Array<{ userId: string; score: number }> {
    return Object.values(room.players).map((player) => ({
      userId: player.userId,
      score: player.score,
    }));
  }

  private async generateUniqueRoomCode(): Promise<string> {
    for (let i = 0; i < 20; i += 1) {
      const code = randomRoomCode();
      const existing = await this.roomStore.getByCode(code);
      if (!existing) {
        return code;
      }
    }

    throw new Error("Could not allocate unique room code.");
  }
}
