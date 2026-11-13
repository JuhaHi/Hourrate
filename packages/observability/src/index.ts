import pino from 'pino';

export type StructuredLogger = pino.Logger;

export function createLogger(service: string): StructuredLogger {
  return pino({
    name: service,
    level: process.env.LOG_LEVEL ?? 'info',
  });
}
