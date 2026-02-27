import http from "http";
import express from "express";
import { Server } from "socket.io";
import { env } from "./config/env.js";
import { closePg, pgPool } from "./db/pg.js";
import { closeRedis, redis } from "./db/redis.js";
import { GameGateway } from "./sockets/gameGateway.js";
import { QuizRepository } from "./services/quizRepository.js";
import { RoomStore } from "./services/roomStore.js";
import { logger } from "./utils/logger.js";

const bootstrap = async (): Promise<void> => {
  const app = express();
  app.use(express.json());

  app.get("/health", async (_req, res) => {
    try {
      await pgPool.query("SELECT 1");
      await redis.ping();
      res.status(200).json({ status: "ok" });
    } catch (error) {
      res.status(500).json({ status: "error", error: (error as Error).message });
    }
  });

  const server = http.createServer(app);

  const io = new Server(server, {
    cors: {
      origin: "*",
      methods: ["GET", "POST"],
    },
  });

  const quizRepository = new QuizRepository(pgPool);
  const roomStore = new RoomStore(redis, env.roomTtlSeconds);

  const gameGateway = new GameGateway(io, roomStore, quizRepository);
  gameGateway.register();

  server.listen(env.port, () => {
    logger.info(`Server listening on port ${env.port}`);
  });

  const shutdown = async (): Promise<void> => {
    logger.info("Shutting down server...");
    io.close();
    server.close();
    await closePg();
    await closeRedis();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
};

bootstrap().catch((error) => {
  logger.error("Fatal bootstrap error", error);
  process.exit(1);
});
