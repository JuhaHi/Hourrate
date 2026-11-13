import { v4 as uuidv4 } from 'uuid';
import type { LocalDatabaseDriver } from '../db/driver';

export class OutboxProcessor {
  private isRunning = false;
  constructor(
    private readonly db: LocalDatabaseDriver,
    private readonly config: {
      apiBaseUrl: string;
      deviceId: string;
      isNetworkAvailable: () => Promise<boolean>;
      onDlqAlert: (err: { errorCode: string; errorMessage: string }) => void;
    }
  ) {}

  async processQueue(): Promise<{ syncedCount: number; dlqCount: number }> {
    if (this.isRunning || !(await this.config.isNetworkAvailable())) return { syncedCount: 0, dlqCount: 0 };
    this.isRunning = true;
    let syncedCount = 0;
    let dlqCount = 0;
    try {
      const nowIso = new Date().toISOString();
      const rowsRes = await this.db.execute(
        `SELECT o.* FROM sync_outbox o WHERE o.status IN ('PENDING', 'FAILED_RETRY')
         AND (o.next_retry_at IS NULL OR o.next_retry_at <= ?)
         AND NOT EXISTS (SELECT 1 FROM dead_letter_queue d WHERE d.aggregate_type = o.aggregate_type AND d.aggregate_id = o.aggregate_id AND d.resolved_at IS NULL)
         ORDER BY o.sequence_num ASC LIMIT 50`,
        [nowIso]
      );
      for (const item of rowsRes.rows) {
        const res = await fetch(`${this.config.apiBaseUrl}${String(item.endpoint)}`, {
          method: String(item.http_method),
          headers: {
            'Content-Type': 'application/json',
            'Idempotency-Key': String(item.id),
            'X-Correlation-Id': String(item.correlation_id),
            'X-Device-Id': this.config.deviceId,
          },
          body: String(item.payload_json),
        });
        if (res.ok) {
          await this.db.execute(`DELETE FROM sync_outbox WHERE id = ?`, [item.id]);
          syncedCount++;
        } else if ([400, 404, 409, 410, 422].includes(res.status)) {
          const body = (await res.json().catch(() => ({}))) as { code?: string; message?: string };
          const code = body.code ?? `HTTP_${res.status}`;
          const msg = body.message ?? res.statusText;
          await this.db.transaction(async (tx) => {
            await tx.execute(
              `INSERT INTO dead_letter_queue (id, original_outbox_id, aggregate_type, aggregate_id, event_type, payload_json, error_code, error_message, created_at)
               VALUES (?,?,?,?,?,?,?,?,?)`,
              [uuidv4(), item.id, item.aggregate_type, item.aggregate_id, item.event_type, item.payload_json, code, msg, nowIso]
            );
            await tx.execute(`UPDATE sync_outbox SET status = 'DLQ', last_error_code = ? WHERE id = ?`, [code, item.id]);
          });
          this.config.onDlqAlert({ errorCode: code, errorMessage: msg });
          dlqCount++;
        }
      }
    } finally {
      this.isRunning = false;
    }
    return { syncedCount, dlqCount };
  }
}
