import { describe, it, expect, vi } from 'vitest';
import { OutboxProcessor } from '../src/sync/outboxProcessor.js';
import { TieredProductSearchService } from '../src/search/tieredSearch.js';
import { parseVoiceCommand } from '../src/hardware/voiceCommands.js';

describe('Mobile Offline-First: Outbox DLQ & Voice & Search', () => {
  it('siirtää 409 BILLING_PERIOD_LOCKED tapahtuman DLQ-tilaan', async () => {
    const sqls: string[] = [];
    const mockDb = {
      execute: vi.fn(async (sql: string) => {
        sqls.push(sql);
        if (sql.includes('FROM sync_outbox o')) {
          return { rows: [{ id: 'i1', sequence_num: 1, aggregate_type: 'MATERIAL', aggregate_id: 'wo-1', event_type: 'MATERIAL_RESERVED', endpoint: '/v1/materials/reserve', http_method: 'POST', payload_json: '{}', correlation_id: 'c1' }] };
        }
        return { rows: [] };
      }),
      transaction: vi.fn(async (fn: (tx: unknown) => Promise<void>) => fn({ execute: vi.fn(async (s: string) => { sqls.push(s); return { rows: [] }; }) })),
    };
    const onDlqAlert = vi.fn();
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ code: 'BILLING_PERIOD_LOCKED', message: 'Lukittu' }), { status: 409 })));

    const proc = new OutboxProcessor(mockDb as never, { apiBaseUrl: '', deviceId: 'd1', isNetworkAvailable: async () => true, onDlqAlert });
    const res = await proc.processQueue();
    expect(res).toEqual({ syncedCount: 0, dlqCount: 1 });
    expect(onDlqAlert).toHaveBeenCalled();
    expect(sqls.some((s) => s.includes('INSERT INTO dead_letter_queue'))).toBe(true);
  });

  it('parsii suomenkieliset äänikomennot ja pitää haun < 100 ms', async () => {
    expect(parseVoiceCommand('Lisää 3 kpl MMJ 3x1.5')).toEqual({ type: 'ADD_MATERIAL', quantity: 3, searchQuery: 'mmj 3x1.5' });
    const search = new TieredProductSearchService({ execute: vi.fn(async () => ({ rows: [] })), transaction: vi.fn() } as never);
    const { durationMs } = await search.search('0401234', 'van-1');
    expect(durationMs).toBeLessThan(100);
  });
});
