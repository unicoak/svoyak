import { Pool } from "pg";
import { env } from "../config/env.js";

export const pgPool = new Pool({
  connectionString: env.pgConnectionString,
});

export const closePg = async (): Promise<void> => {
  await pgPool.end();
};
