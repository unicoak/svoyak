import { Pool, type PoolConfig } from "pg";
import { env } from "../config/env.js";

const SSL_QUERY_KEYS = [
  "sslmode",
  "sslcert",
  "sslkey",
  "sslrootcert",
  "sslcrl",
  "sslpassword",
  "ssl_min_protocol_version",
  "ssl_max_protocol_version",
  "sslsni",
  "sslnegotiation",
];

const sanitizeConnectionStringForSslOverride = (connectionString: string): string => {
  const url = new URL(connectionString);
  for (const key of SSL_QUERY_KEYS) {
    url.searchParams.delete(key);
  }
  return url.toString();
};

const buildPgConfig = (): PoolConfig => {
  if (env.pgSslRejectUnauthorized !== undefined) {
    return {
      // pg parses sslmode from URL and can override explicit ssl config.
      // Remove URL-level SSL params when env override is configured.
      connectionString: sanitizeConnectionStringForSslOverride(env.pgConnectionString),
      ssl: { rejectUnauthorized: env.pgSslRejectUnauthorized },
    };
  }

  return {
    connectionString: env.pgConnectionString,
  };
};

export const createPgPool = (): Pool => new Pool(buildPgConfig());

export const pgPool = createPgPool();

export const closePg = async (): Promise<void> => {
  await pgPool.end();
};
