export interface QueryResult {
  rows: Record<string, unknown>[];
}
export interface LocalDatabaseDriver {
  execute(sql: string, params?: unknown[]): Promise<QueryResult>;
  transaction<T>(fn: (tx: LocalDatabaseDriver) => Promise<T>): Promise<T>;
}
