import type { LocalDatabaseDriver, QueryResult } from './driver';

export class WebSqliteDriver implements LocalDatabaseDriver {
  private worker = new Worker(new URL('./sqlite.worker.ts', import.meta.url), { type: 'module' });
  private nextId = 1;
  private pending = new Map<number, { resolve: (r: QueryResult) => void; reject: (e: Error) => void }>();
  private txMutex: Promise<unknown> = Promise.resolve();

  constructor() {
    this.worker.onmessage = (e) => {
      const { id, ok, rows, error } = e.data;
      const call = this.pending.get(id);
      if (!call) return;
      this.pending.delete(id);
      if (ok) call.resolve({ rows: rows ?? [] });
      else call.reject(new Error(error));
    };
  }

  private send(type: 'INIT' | 'EXEC', sql: string, params?: unknown[]): Promise<QueryResult> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ id, type, sql, params });
    });
  }

  async init(schemaSql: string): Promise<void> {
    await this.send('INIT', schemaSql);
  }

  execute(sql: string, params?: unknown[]): Promise<QueryResult> {
    return this.txMutex.then(() => this.send('EXEC', sql, params));
  }

  transaction<T>(fn: (tx: LocalDatabaseDriver) => Promise<T>): Promise<T> {
    const run = async (): Promise<T> => {
      await this.send('EXEC', 'BEGIN IMMEDIATE');
      const txDriver: LocalDatabaseDriver = {
        execute: (sql, params) => this.send('EXEC', sql, params),
        transaction: () => { throw new Error('Nested tx not supported'); },
      };
      try {
        const res = await fn(txDriver);
        await this.send('EXEC', 'COMMIT');
        return res;
      } catch (err) {
        await this.send('EXEC', 'ROLLBACK').catch(() => undefined);
        throw err;
      }
    };
    const next = this.txMutex.then(run, run);
    this.txMutex = next.catch(() => undefined);
    return next;
  }
}
