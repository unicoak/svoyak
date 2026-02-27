type LogLevel = "INFO" | "WARN" | "ERROR";

const write = (level: LogLevel, message: string, extra?: unknown): void => {
  const time = new Date().toISOString();
  if (extra === undefined) {
    console.log(`[${time}] [${level}] ${message}`);
    return;
  }

  console.log(`[${time}] [${level}] ${message}`, extra);
};

export const logger = {
  info: (message: string, extra?: unknown): void => write("INFO", message, extra),
  warn: (message: string, extra?: unknown): void => write("WARN", message, extra),
  error: (message: string, extra?: unknown): void => write("ERROR", message, extra),
};
