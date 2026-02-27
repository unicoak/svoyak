import { Pool, type PoolConfig } from "pg";
import { env } from "../config/env.js";

const buildPgConfig = (): PoolConfig => {
  const config: PoolConfig = {
    connectionString: env.pgConnectionString,
  };

  if (env.pgSslRejectUnauthorized !== undefined) {
    config.ssl = { rejectUnauthorized: env.pgSslRejectUnauthorized };
  }

  return config;
};

export const createPgPool = (): Pool => new Pool(buildPgConfig());

export const pgPool = createPgPool();

export const closePg = async (): Promise<void> => {
  await pgPool.end();
};
