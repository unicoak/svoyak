import crypto from "crypto";

const ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export const randomRoomCode = (length = 6): string => {
  let result = "";

  for (let i = 0; i < length; i += 1) {
    const index = crypto.randomInt(0, ROOM_CODE_ALPHABET.length);
    result += ROOM_CODE_ALPHABET[index];
  }

  return result;
};

export const randomToken = (): string => crypto.randomUUID();
