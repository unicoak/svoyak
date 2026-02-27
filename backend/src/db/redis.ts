import { Redis } from "ioredis";
import { env } from "../config/env.js";
import { logger } from "../utils/logger.js";

export const redis = new Redis(env.redisUrl, {
  maxRetriesPerRequest: null,
  retryStrategy: (attempt) => Math.min(attempt * 200, 5_000),
});

let lastRedisErrorLogAt = 0;

redis.on("error", (error) => {
  const now = Date.now();
  if (now - lastRedisErrorLogAt >= 5_000) {
    logger.warn("Redis connection error", error);
    lastRedisErrorLogAt = now;
  }
});

export const closeRedis = async (): Promise<void> => {
  await redis.quit();
};
