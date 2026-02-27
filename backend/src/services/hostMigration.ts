import { RoomState } from "../types/room.js";

const chooseNewHost = (room: RoomState): string | null => {
  const connectedPlayers = Object.values(room.players)
    .filter((player) => player.connected)
    .sort((a, b) => a.joinedAtMs - b.joinedAtMs || a.userId.localeCompare(b.userId));

  return connectedPlayers[0]?.userId ?? null;
};

export interface HostMigrationResult {
  oldHostUserId: string;
  newHostUserId: string;
}

export const migrateHostIfNeeded = (room: RoomState): HostMigrationResult | null => {
  const currentHost = room.players[room.hostUserId];

  if (currentHost && currentHost.connected) {
    return null;
  }

  const newHostUserId = chooseNewHost(room);
  if (!newHostUserId) {
    return null;
  }

  const oldHostUserId = room.hostUserId;

  room.hostUserId = newHostUserId;
  room.migration.hostMigrationSeq += 1;

  for (const player of Object.values(room.players)) {
    player.isHost = player.userId === newHostUserId;
  }

  return { oldHostUserId, newHostUserId };
};
