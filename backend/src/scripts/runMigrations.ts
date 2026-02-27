import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Pool } from "pg";
import { createPgPool } from "../db/pg.js";

const MIGRATIONS_TABLE = "schema_migrations";

const parseBoolean = (value: string | undefined): boolean => {
  if (!value) {
    return false;
  }

  const normalized = value.trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes";
};

const shouldIncludeSeedMigrations = (): boolean => {
  if (process.argv.includes("--with-seed")) {
    return true;
  }

  return parseBoolean(process.env.MIGRATE_WITH_SEED);
};

const pathExists = async (targetPath: string): Promise<boolean> => {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
};

const resolveMigrationsDir = async (): Promise<string> => {
  const currentFilePath = fileURLToPath(import.meta.url);
  const currentDir = path.dirname(currentFilePath);

  const candidates = [
    path.resolve(process.cwd(), "migrations"),
    path.resolve(currentDir, "../../migrations"),
    path.resolve(currentDir, "../../../migrations"),
  ];

  for (const candidate of candidates) {
    if (await pathExists(candidate)) {
      return candidate;
    }
  }

  throw new Error(
    `Could not locate migrations directory. Tried: ${candidates.join(", ")}`,
  );
};

const readMigrationFiles = async (withSeed: boolean): Promise<string[]> => {
  const migrationsDir = await resolveMigrationsDir();
  const entries = await fs.readdir(migrationsDir, { withFileTypes: true });
  const sqlFiles = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".sql"))
    .map((entry) => entry.name)
    .sort((a, b) => a.localeCompare(b));

  if (withSeed) {
    return sqlFiles;
  }

  return sqlFiles.filter((fileName) => !fileName.toLowerCase().includes("seed"));
};

const ensureMigrationsTable = async (pool: Pool): Promise<void> => {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS ${MIGRATIONS_TABLE} (
      filename TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
};

const fetchAppliedMigrations = async (pool: Pool): Promise<Set<string>> => {
  const result = await pool.query<{ filename: string }>(
    `SELECT filename FROM ${MIGRATIONS_TABLE};`,
  );
  return new Set(result.rows.map((row) => row.filename));
};

const applyMigration = async (
  pool: Pool,
  migrationFileName: string,
  migrationSql: string,
): Promise<void> => {
  const client = await pool.connect();
  try {
    await client.query("BEGIN;");
    await client.query(migrationSql);
    await client.query(
      `INSERT INTO ${MIGRATIONS_TABLE} (filename) VALUES ($1);`,
      [migrationFileName],
    );
    await client.query("COMMIT;");
  } catch (error) {
    await client.query("ROLLBACK;");
    throw error;
  } finally {
    client.release();
  }
};

const run = async (): Promise<void> => {
  const withSeed = shouldIncludeSeedMigrations();
  const pool = createPgPool();

  try {
    await ensureMigrationsTable(pool);
    const allFiles = await readMigrationFiles(withSeed);
    const applied = await fetchAppliedMigrations(pool);
    const pending = allFiles.filter((fileName) => !applied.has(fileName));

    if (pending.length === 0) {
      console.log("[migrations] No pending migrations.");
      return;
    }

    const migrationsDir = await resolveMigrationsDir();
    console.log(`[migrations] Applying ${pending.length} migration(s)...`);

    for (const fileName of pending) {
      const fullPath = path.join(migrationsDir, fileName);
      const sql = await fs.readFile(fullPath, "utf-8");
      console.log(`[migrations] -> ${fileName}`);
      await applyMigration(pool, fileName, sql);
    }

    console.log("[migrations] Done.");
  } finally {
    await pool.end();
  }
};

run().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error("[migrations] Failed:", message);
  process.exit(1);
});
