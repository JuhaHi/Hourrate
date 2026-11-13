import type { Pool } from 'pg';
import { v4 as uuidv4 } from 'uuid';

export class DomainConflictError extends Error {
  constructor(public readonly statusCode: number, public readonly code: string, message: string) {
    super(message);
  }
}

export class MaterialService {
  constructor(private readonly pgPool: Pool) {}

  async reserveMaterial(params: {
    tenantId: string; userId: string; idempotencyKey: string; correlationId: string;
    allocationId: string; workOrderId: string; warehouseId: string; productId: string;
    deltaQty: number; unitPriceCents: number;
  }) {
    const client = await this.pgPool.connect();
    try {
      await client.query('BEGIN');
      const wo = await client.query(`SELECT billing_period_locked FROM work_orders WHERE id = $1 AND tenant_id = $2 FOR SHARE`, [params.workOrderId, params.tenantId]);
      if (wo.rows.length === 0) throw new DomainConflictError(404, 'WORK_ORDER_NOT_FOUND', 'Työnumeroa ei löydy.');
      if (wo.rows[0].billing_period_locked) throw new DomainConflictError(409, 'BILLING_PERIOD_LOCKED', 'Laskutuskausi on lukittu.');

      const bal = await client.query(`SELECT on_hand_qty, reserved_qty FROM inventory_balances WHERE warehouse_id = $1 AND product_id = $2 AND tenant_id = $3 FOR UPDATE`, [params.warehouseId, params.productId, params.tenantId]);
      if (bal.rows.length === 0) throw new DomainConflictError(409, 'INSUFFICIENT_STOCK', 'Ei saldoa.');
      const avail = Number(bal.rows[0].on_hand_qty) - Number(bal.rows[0].reserved_qty);
      if (avail < params.deltaQty) throw new DomainConflictError(409, 'INSUFFICIENT_STOCK', `Vapaa saldo ${avail} < ${params.deltaQty}`);

      await client.query(`UPDATE inventory_balances SET reserved_qty = reserved_qty + $1, updated_at = now() WHERE warehouse_id = $2 AND product_id = $3 AND tenant_id = $4`, [params.deltaQty, params.warehouseId, params.productId, params.tenantId]);
      await client.query(
        `INSERT INTO inventory_ledger (tenant_id, warehouse_id, product_id, work_order_id, tx_type, delta_on_hand, delta_reserved, idempotency_key, correlation_id, created_by)
         VALUES ($1,$2,$3,$4,'RESERVE',0,$5,$6,$7,$8)`,
        [params.tenantId, params.warehouseId, params.productId, params.workOrderId, params.deltaQty, params.idempotencyKey, params.correlationId, params.userId]
      );
      await client.query(
        `INSERT INTO work_order_materials (id, tenant_id, work_order_id, warehouse_id, product_id, qty, unit_price_cents, state, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7,'DRAFT_RESERVED',$8)`,
        [params.allocationId, params.tenantId, params.workOrderId, params.warehouseId, params.productId, params.deltaQty, params.unitPriceCents, params.userId]
      );
      await client.query('COMMIT');
      return { allocationId: params.allocationId, state: 'DRAFT_RESERVED' };
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  }

  async commitWorkOrderMaterials(args: { tenantId: string; userId: string; workOrderId: string; allocationIds: string[]; correlationId: string }) {
    const client = await this.pgPool.connect();
    try {
      await client.query('BEGIN');
      const wo = await client.query(`SELECT billing_period_locked FROM work_orders WHERE id = $1 AND tenant_id = $2 FOR UPDATE`, [args.workOrderId, args.tenantId]);
      if (wo.rows.length === 0) throw new DomainConflictError(404, 'WORK_ORDER_NOT_FOUND', 'Työnumeroa ei löydy.');
      if (wo.rows[0].billing_period_locked) throw new DomainConflictError(409, 'BILLING_PERIOD_LOCKED', 'Laskutuskausi lukittu.');

      const mat = await client.query(
        `SELECT id, warehouse_id, product_id, qty FROM work_order_materials WHERE work_order_id = $1 AND tenant_id = $2 AND state = 'DRAFT_RESERVED' AND id = ANY($3::uuid[]) FOR UPDATE`,
        [args.workOrderId, args.tenantId, args.allocationIds]
      );
      for (const item of mat.rows) {
        const qty = Number(item.qty);
        const upd = await client.query(
          `UPDATE inventory_balances SET reserved_qty = GREATEST(0, reserved_qty - $1), on_hand_qty = on_hand_qty - $1, updated_at = now()
           WHERE warehouse_id = $2 AND product_id = $3 AND tenant_id = $4 RETURNING on_hand_qty, min_threshold`,
          [qty, item.warehouse_id, item.product_id, args.tenantId]
        );
        await client.query(
          `INSERT INTO inventory_ledger (tenant_id, warehouse_id, product_id, work_order_id, tx_type, delta_on_hand, delta_reserved, idempotency_key, correlation_id, created_by)
           VALUES ($1,$2,$3,$4,'COMMIT',$5,$6,$7,$8,$9)`,
          [args.tenantId, item.warehouse_id, item.product_id, args.workOrderId, -qty, -qty, uuidv4(), args.correlationId, args.userId]
        );
        if (upd.rows.length > 0 && Number(upd.rows[0].min_threshold) > 0 && Number(upd.rows[0].on_hand_qty) <= Number(upd.rows[0].min_threshold)) {
          await client.query(
            `INSERT INTO server_outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload, correlation_id) VALUES ($1,'INVENTORY',$2,'LOW_STOCK_THRESHOLD_BREACHED',$3,$4)`,
            [args.tenantId, item.warehouse_id, JSON.stringify({ productId: item.product_id, onHand: Number(upd.rows[0].on_hand_qty) }), args.correlationId]
          );
        }
      }
      if (mat.rows.length > 0) {
        await client.query(`UPDATE work_order_materials SET state = 'COMMITTED', committed_at = now() WHERE id = ANY($1::uuid[])`, [mat.rows.map((r) => r.id)]);
        await client.query(
          `INSERT INTO server_outbox (tenant_id, aggregate_type, aggregate_id, event_type, payload, correlation_id) VALUES ($1,'WORK_ORDER',$2,'MATERIALS_COMMITTED_FOR_BILLING',$3,$4)`,
          [args.tenantId, args.workOrderId, JSON.stringify({ items: mat.rows }), args.correlationId]
        );
      }
      await client.query('COMMIT');
      return { committedCount: mat.rows.length };
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  }
}
