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

const syncTimeSchema = z.object({
  sampleId: z.string().min(1).max(64),
  t0ClientMs: z.number().int().positive(),
});

const heartbeatSchema = roomCodeSchema.extend({
  clientNowMs: z.number().int().positive(),
});

const listPublicRoomsSchema = z
  .object({
    limit: z.number().int().min(1).max(100).optional(),
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

export class GameGateway {
  private readonly buzzerTimers = new Map<string, NodeJS.Timeout>();
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
        questionIds: questions.map((question) => question.id),
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

          delete room.players[socket.data.userId];
          const migration = migrateHostIfNeeded(room);

          return {
            room,
            migration,
            roomEmpty: Object.keys(room.players).length === 0,
          };
        });

        socket.leave(payload.roomCode);
        socket.data.roomCode = null;

        if (outcome.roomEmpty) {
          await this.roomStore.deleteByCode(payload.roomCode);
          ack?.(ok({ removed: true }));
          return;
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

          openQuestion(lockedRoom, {
            ...question,
            answerTimeLimitMs: question.answerTimeLimitMs ?? lockedRoom.settings.defaultAnswerTimeLimitMs,
          });

          return lockedRoom;
        });

        this.io.to(payload.roomCode).emit("question_opened", {
          questionId: payload.questionId,
          prompt: question.prompt,
          points: question.points,
          openedAtServerMs: room.game.buzzer.openedAtServerMs,
        });

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
        const room = await this.roomStore.withRoomLock(payload.roomCode, async (lockedRoom) => {
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

          const effectiveOffsetMs = payload.offsetMs ?? player.net.offsetMs;
          const effectiveRttMs = payload.rttMs ?? player.net.rttMs;
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

          lockedRoom.game.buzzer.attempts.push({
            userId: player.userId,
            recvServerMs,
            pressClientMs: payload.pressClientMs,
            offsetMs: effectiveOffsetMs,
            rttMs: effectiveRttMs,
            effectivePressMs,
          });

          if (!lockedRoom.game.buzzer.resolveAtServerMs) {
            lockedRoom.game.buzzer.resolveAtServerMs = recvServerMs + lockedRoom.settings.buzzResolveWindowMs;
            this.scheduleBuzzerFinalization(lockedRoom.code, lockedRoom.game.buzzer.resolveAtServerMs);
          }

          return lockedRoom;
        });

        this.emitRoomState(room);
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

          if (result.isCorrect) {
            applyScoreDelta(room, socket.data.userId, currentQuestion.points);
            closeQuestion(room);
            completeIfBoardFinished(room);
          } else {
            applyScoreDelta(room, socket.data.userId, -currentQuestion.points);
            const wrongOutcome = markWrongAnswer(room, socket.data.userId);

            if (wrongOutcome === "CLOSED") {
              closeQuestion(room);
              completeIfBoardFinished(room);
            }
          }

          return {
            room,
            answerResult: result,
            isCorrect: result.isCorrect,
            scoreDelta: result.isCorrect ? currentQuestion.points : -currentQuestion.points,
            correctAnswerDisplay: currentQuestion.answerDisplay,
          };
        });

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
          this.io.to(payload.roomCode).emit("question_closed", {
            questionId: payload.questionId,
            correctAnswerDisplay: outcome.correctAnswerDisplay,
            scores: this.extractScores(outcome.room),
          });
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

    socket.on("heartbeat", async (rawPayload: unknown, ack?: (response: Ack) => void) => {
      const parsed = heartbeatSchema.safeParse(rawPayload);
      if (!parsed.success) {
        ack?.(failure("INVALID_PAYLOAD", "Invalid heartbeat payload."));
        return;
      }

      try {
        const room = await this.roomStore.withRoomLock(parsed.data.roomCode, async (lockedRoom) => {
          const player = lockedRoom.players[socket.data.userId];
          if (!player) {
            throw new Error("PLAYER_NOT_IN_ROOM");
          }

          player.lastSeenAtMs = Date.now();
          player.connected = true;
          player.socketId = socket.id;

          return lockedRoom;
        });

        this.emitRoomState(room);
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
          };
        }

        player.connected = false;
        player.lastSeenAtMs = Date.now();

        const currentQuestion = room.game.currentQuestion;

        if (
          currentQuestion &&
          room.status === "ANSWERING" &&
          room.game.answering.activeUserId === player.userId
        ) {
          applyScoreDelta(room, player.userId, -currentQuestion.points);
          const wrongOutcome = markWrongAnswer(room, player.userId);
          if (wrongOutcome === "CLOSED") {
            closeQuestion(room);
            completeIfBoardFinished(room);
          }
        }

        const migration = migrateHostIfNeeded(room);

        return {
          room,
          migration,
          disconnectedUserId: player.userId,
          graceMs: room.settings.disconnectGraceMs,
        };
      });

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
    const existing = this.buzzerTimers.get(roomCode);
    if (existing) {
      clearTimeout(existing);
    }

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
