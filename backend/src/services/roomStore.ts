import type { Redis } from "ioredis";
import { RoomState } from "../types/room.js";

const LOCK_TTL_MS = 2_000;
const LOCK_RETRIES = 40;
const LOCK_RETRY_DELAY_MS = 25;

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export class RoomNotFoundError extends Error {
  constructor(codeOrId: string) {
    super(`Room not found: ${codeOrId}`);
  }
}

export class LockAcquireError extends Error {
  constructor(key: string) {
    super(`Could not acquire lock: ${key}`);
  }
}

export class RoomStore {
  private readonly publicRoomsSetKey = "rooms:public";

  constructor(
    private readonly redis: Redis,
    private readonly ttlSeconds: number,
  ) {}

  private roomKey(code: string): string {
    return `room:${code}`;
  }

  private roomIdIndexKey(roomId: string): string {
    return `room_id:${roomId}`;
  }

  private lockKey(code: string): string {
    return `lock:room:${code}`;
  }

  async getByCode(code: string): Promise<RoomState | null> {
    const raw = await this.redis.get(this.roomKey(code));
    if (!raw) {
      return null;
    }

    return JSON.parse(raw) as RoomState;
  }

  async getById(roomId: string): Promise<RoomState | null> {
    const code = await this.redis.get(this.roomIdIndexKey(roomId));
    if (!code) {
      return null;
    }

    return this.getByCode(code);
  }

  async save(room: RoomState): Promise<void> {
    room.updatedAtMs = Date.now();

    const pipeline = this.redis.pipeline();
    pipeline.set(this.roomKey(room.code), JSON.stringify(room), "EX", this.ttlSeconds);
    pipeline.set(this.roomIdIndexKey(room.roomId), room.code, "EX", this.ttlSeconds);
    if (room.visibility === "PUBLIC") {
      pipeline.sadd(this.publicRoomsSetKey, room.code);
    } else {
      pipeline.srem(this.publicRoomsSetKey, room.code);
    }
    await pipeline.exec();
  }

  async deleteByCode(code: string): Promise<void> {
    const room = await this.getByCode(code);
    const pipeline = this.redis.pipeline();
    pipeline.del(this.roomKey(code));
    pipeline.srem(this.publicRoomsSetKey, code);

    if (room) {
      pipeline.del(this.roomIdIndexKey(room.roomId));
    }

    await pipeline.exec();
  }

  async listPublicRooms(limit = 20): Promise<RoomState[]> {
    const sanitizedLimit = Math.max(1, Math.min(limit, 100));
    const allCodes = await this.redis.smembers(this.publicRoomsSetKey);

    if (allCodes.length === 0) {
      return [];
    }

    const pipeline = this.redis.pipeline();
    for (const code of allCodes) {
      pipeline.get(this.roomKey(code));
    }

    const rows = await pipeline.exec();
    if (!rows) {
      return [];
    }

    const staleCodes: string[] = [];
    const rooms: RoomState[] = [];

    for (let i = 0; i < allCodes.length; i += 1) {
      const code = allCodes[i];
      const row = rows[i];
      const error = row?.[0];
      const raw = row?.[1];

      if (error || typeof raw !== "string") {
        staleCodes.push(code);
        continue;
      }

      try {
        const room = JSON.parse(raw) as RoomState;
        if (room.visibility !== "PUBLIC" || room.status === "FINISHED") {
          staleCodes.push(code);
          continue;
        }

        rooms.push(room);
      } catch {
        staleCodes.push(code);
      }
    }

    if (staleCodes.length > 0) {
      await this.redis.srem(this.publicRoomsSetKey, ...staleCodes);
    }

    rooms.sort((a, b) => b.createdAtMs - a.createdAtMs);
    return rooms.slice(0, sanitizedLimit);
  }

  private async acquireLock(code: string, token: string): Promise<void> {
    const key = this.lockKey(code);

    for (let i = 0; i < LOCK_RETRIES; i += 1) {
      const result = await this.redis.set(key, token, "PX", LOCK_TTL_MS, "NX");
      if (result === "OK") {
        return;
      }

      await sleep(LOCK_RETRY_DELAY_MS);
    }

    throw new LockAcquireError(key);
  }

  private async releaseLock(code: string, token: string): Promise<void> {
    const key = this.lockKey(code);
    const lua = `
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
      end
      return 0
    `;

    await this.redis.eval(lua, 1, key, token);
  }

  async withRoomLock<T>(code: string, operation: (room: RoomState) => Promise<T>): Promise<T> {
    const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    await this.acquireLock(code, token);

    try {
      const room = await this.getByCode(code);
      if (!room) {
        throw new RoomNotFoundError(code);
      }

      const result = await operation(room);
      room.version += 1;
      await this.save(room);
      return result;
    } finally {
      await this.releaseLock(code, token);
    }
  }
}
