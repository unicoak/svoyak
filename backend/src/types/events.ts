import { RoomState } from "./room.js";

export interface SocketContext {
  userId: string;
  displayName: string;
}

export interface AckOk<T = Record<string, never>> {
  ok: true;
  data: T;
}

export interface AckError {
  ok: false;
  error: {
    code: string;
    message: string;
  };
}

export type Ack<T = unknown> = AckOk<T> | AckError;

export interface RoomStatePayload {
  version: number;
  state: RoomState;
}
