import dotenv from "dotenv";

dotenv.config();

const parseIntOrDefault = (value: string | undefined, fallback: number): number => {
  if (!value) {
    return fallback;
  }

  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const parseBooleanOrUndefined = (value: string | undefined): boolean | undefined => {
  if (!value) {
    return undefined;
  }

  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }

  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }

  return undefined;
};

export const env = {
  nodeEnv: process.env.NODE_ENV ?? "development",
  port: parseIntOrDefault(process.env.PORT, 3000),
  pgConnectionString:
    process.env.PG_CONNECTION_STRING ??
    process.env.DATABASE_URL ??
    "postgres://postgres:postgres@localhost:5432/svoyak",
  pgSslRejectUnauthorized: parseBooleanOrUndefined(process.env.PG_SSL_REJECT_UNAUTHORIZED),
  redisUrl: process.env.REDIS_URL ?? "redis://localhost:6379",
  roomTtlSeconds: parseIntOrDefault(process.env.ROOM_TTL_SECONDS, 24 * 60 * 60),
  buzzResolveWindowMs: parseIntOrDefault(process.env.BUZZ_RESOLVE_WINDOW_MS, 80),
  defaultAnswerTimeLimitMs: parseIntOrDefault(process.env.DEFAULT_ANSWER_TIME_LIMIT_MS, 5000),
};
