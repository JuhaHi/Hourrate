/// <reference lib="webworker" />
import sqlite3InitModule from '@sqlite.org/sqlite-wasm';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let dbInstance: any = null;

async function initDb(schemaSql: string) {
  if (dbInstance) return;
  const sqlite3 = await sqlite3InitModule({ print: console.log, printErr: console.error });
  if (!('installOpfsSAHPoolVfs' in sqlite3)) {
    throw new Error('OPFS SAHPool ei tuettu: avaa HTTPS-yhteydellä Android Chromessa.');
  }
  const poolUtil = await sqlite3.installOpfsSAHPoolVfs({ name: 'kentta-pool', initialCapacity: 8 });
  dbInstance = new poolUtil.OpfsSAHPoolDb('/kentta-erp-mvp.sqlite3');
  dbInstance.exec(schemaSql);
}

self.onmessage = async (event: MessageEvent<{ id: number; type: 'INIT' | 'EXEC'; sql: string; params?: unknown[] }>) => {
  const { id, type, sql, params } = event.data;
  try {
    if (type === 'INIT') {
      await initDb(sql);
      self.postMessage({ id, ok: true, rows: [] });
      return;
    }
    const rows: Record<string, unknown>[] = [];
    dbInstance.exec({
      sql,
      bind: params ?? [],
      rowMode: 'object',
      callback: (row: Record<string, unknown>) => rows.push(row),
    });
    self.postMessage({ id, ok: true, rows });
  } catch (err) {
    self.postMessage({ id, ok: false, error: err instanceof Error ? err.message : String(err) });
  }
};
