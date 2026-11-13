import { createActor } from 'xstate';
import { v4 as uuidv4 } from 'uuid';
import { twoPhaseMaterialMachine } from '@kentta/state-machines';
import type { LocalDatabaseDriver } from '../driver';

export class MaterialRepository {
  constructor(private readonly db: LocalDatabaseDriver) {}

  async reserveDraftMaterial(input: {
    workOrderId: string; warehouseId: string; productId: string;
    qty: number; unitPriceCents: number; userId: string;
  }): Promise<string> {
    const allocationId = uuidv4();
    const idempotencyKey = uuidv4();
    const correlationId = uuidv4();
    const now = new Date().toISOString();

    const actor = createActor(twoPhaseMaterialMachine).start();
    actor.send({ type: 'RESERVE_DRAFT', allocationId, workOrderId: input.workOrderId, warehouseId: input.warehouseId, productId: input.productId, qty: input.qty });
    if (!actor.getSnapshot().matches('draftReserved')) throw new Error('Virheellinen varausmäärä.');

    await this.db.transaction(async (tx) => {
      const bal = await tx.execute(`SELECT on_hand_qty, reserved_qty FROM inventory_balances WHERE warehouse_id = ? AND product_id = ?`, [input.warehouseId, input.productId]);
      if (bal.rows.length > 0) {
        const avail = Number(bal.rows[0].on_hand_qty) - Number(bal.rows[0].reserved_qty);
        if (avail < input.qty) throw new Error(`Riittämätön vapaa saldo (${avail} < ${input.qty}).`);
      }

      await tx.execute(
        `INSERT INTO material_allocations (id, work_order_id, warehouse_id, product_id, qty, unit_price_cents, state, is_synced, created_by, created_at)
         VALUES (?,?,?,?,?,?, 'DRAFT_RESERVED', 0, ?, ?)`,
        [allocationId, input.workOrderId, input.warehouseId, input.productId, input.qty, input.unitPriceCents, input.userId, now]
      );
      await tx.execute(
        `UPDATE inventory_balances SET reserved_qty = reserved_qty + ?, updated_at = ? WHERE warehouse_id = ? AND product_id = ?`,
        [input.qty, now, input.warehouseId, input.productId]
      );
      const seqRes = await tx.execute(`SELECT COALESCE(MAX(sequence_num), 0) + 1 AS next_seq FROM sync_outbox`);
      const seq = Number(seqRes.rows[0]?.next_seq ?? 1);
      await tx.execute(
        `INSERT INTO sync_outbox (id, sequence_num, aggregate_type, aggregate_id, event_type, endpoint, http_method, payload_json, correlation_id, status, created_at)
         VALUES (?, ?, 'MATERIAL', ?, 'MATERIAL_RESERVED', '/v1/materials/reserve', 'POST', ?, ?, 'PENDING', ?)`,
        [idempotencyKey, seq, input.workOrderId, JSON.stringify({ allocationId, ...input, deltaQty: input.qty }), correlationId, now]
      );
    });
    return allocationId;
  }
}
