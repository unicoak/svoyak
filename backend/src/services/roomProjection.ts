import { RoomState } from "../types/room.js";

export type PublicRoomState = Omit<RoomState, "players"> & {
  players: Record<
    string,
    {
      userId: string;
      name: string;
      score: number;
      joinedAtMs: number;
      lastSeenAtMs: number;
      connected: boolean;
      isHost: boolean;
      canBuzz: boolean;
      net: {
        offsetMs: number;
        rttMs: number;
        jitterMs: number;
        syncSampleCount: number;
        lastSyncAtMs: number;
      };
    }
  >;
};

export const toPublicRoomState = (room: RoomState): PublicRoomState => {
  const cloned = structuredClone(room) as PublicRoomState;
  cloned.game.answering.draftAnswerText = "";

  for (const [userId, player] of Object.entries(room.players)) {
    cloned.players[userId] = {
      userId: player.userId,
      name: player.name,
      score: player.score,
      joinedAtMs: player.joinedAtMs,
      lastSeenAtMs: player.lastSeenAtMs,
      connected: player.connected,
      isHost: player.isHost,
      canBuzz: player.canBuzz,
      net: { ...player.net },
    };
  }

  if (
    cloned.game.currentQuestion &&
    (cloned.status === "QUESTION_OPEN" || cloned.status === "ANSWERING")
  ) {
    cloned.game.currentQuestion.answerDisplay = "";
    cloned.game.currentQuestion.answerComment = "";
  }

  return cloned;
};
