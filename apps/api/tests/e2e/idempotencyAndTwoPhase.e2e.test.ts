import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { Pool } from 'pg';
import Redis from 'ioredis';
import { v4 as uuidv4 } from 'uuid';
import { idempotencyPlugin } from '../../src/plugins/idempotency.js';
import { MaterialService, DomainConflictError } from '../../src/modules/materials/materialService.js';

describe('E2E: Idempotency & Two-Phase Material Flow', () => {
  let app: FastifyInstance;
  let pgPool: Pool;
  let redis: Redis;
  const tenantId = uuidv4();
  const userId = uuidv4();
  const customerId = uuidv4();
  const warehouseId = uuidv4();
  const productId = uuidv4();
  const workOrderId = uuidv4();

  beforeAll(async () => {
    pgPool = new Pool({ connectionString: process.env.DATABASE_URL ?? 'postgresql://kentta:kentta_dev_password@localhost:5432/kentta_erp' });
    redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');
    const svc = new MaterialService(pgPool);
    app = Fastify();
    app.addHook('onRequest', async (req) => { req.auth = { tenantId, userId }; });
    await app.register(idempotencyPlugin, { redis, pgPool });
    app.post('/v1/materials/reserve', async (req, reply) => {
      try {
        const b = req.body as Record<string, unknown>;
        return reply.status(201).send(await svc.reserveMaterial({
          tenantId, userId, idempotencyKey: req.headers['idempotency-key'] as string, correlationId: uuidv4(),
          allocationId: String(b.allocationId), workOrderId: String(b.workOrderId), warehouseId: String(b.warehouseId),
          productId: String(b.productId), deltaQty: Number(b.deltaQty), unitPriceCents: Number(b.unitPriceCents),
        }));
      } catch (e) {
        if (e instanceof DomainConflictError) return reply.status(e.statusCode).send({ code: e.code });
        throw e;
      }
    });
    await app.ready();
  });

  beforeEach(async () => {
    await redis.flushdb();
    await pgPool.query(`TRUNCATE tenants, users, customers, warehouses, products, inventory_balances, inventory_ledger, work_orders, work_order_materials, server_outbox, processed_idempotency_keys CASCADE`);
    await pgPool.query(`INSERT INTO tenants (id, name, business_id) VALUES ($1,'Testi Oy','1234567-8')`, [tenantId]);
    await pgPool.query(`INSERT INTO users (id, tenant_id, oidc_subject, email, full_name, role) VALUES ($1,$2,$3,'a@b.fi','Asentaja','TECHNICIAN')`, [userId, tenantId, userId]);
    await pgPool.query(`INSERT INTO customers (id, tenant_id, name) VALUES ($1,$2,'Asiakas Oy')`, [customerId, tenantId]);
    await pgPool.query(`INSERT INTO warehouses (id, tenant_id, code, name, warehouse_type) VALUES ($1,$2,'VAN-1','Auto 1','VAN')`, [warehouseId, tenantId]);
    await pgPool.query(`INSERT INTO products (id, tenant_id, sku, name, unit) VALUES ($1,$2,'MMJ-315','MMJ 3x1.5','m')`, [productId, tenantId]);
    await pgPool.query(`INSERT INTO inventory_balances (tenant_id, warehouse_id, product_id, on_hand_qty, reserved_qty) VALUES ($1,$2,$3,50,0)`, [tenantId, warehouseId, productId]);
    await pgPool.query(`INSERT INTO work_orders (id, tenant_id, work_order_number, customer_id, title, assigned_user_id) VALUES ($1,$2,'WO-1',$3,'Asennus',$4)`, [workOrderId, tenantId, customerId, userId]);
  });

  afterAll(async () => { await app.close(); await pgPool.end(); await redis.quit(); });

  it('rejects missing Idempotency-Key and replays duplicate requests safely', async () => {
    const bad = await app.inject({ method: 'POST', url: '/v1/materials/reserve', payload: {} });
    expect(bad.statusCode).toBe(400);

    const idem = uuidv4();
    const payload = { allocationId: uuidv4(), workOrderId, warehouseId, productId, deltaQty: 5, unitPriceCents: 100 };
    const r1 = await app.inject({ method: 'POST', url: '/v1/materials/reserve', headers: { 'idempotency-key': idem }, payload });
    const r2 = await app.inject({ method: 'POST', url: '/v1/materials/reserve', headers: { 'idempotency-key': idem }, payload });
    expect(r1.statusCode).toBe(201);
    expect(r2.headers['x-idempotent-replayed']).toBe('true');

    const bal = await pgPool.query(`SELECT reserved_qty FROM inventory_balances WHERE warehouse_id=$1`, [warehouseId]);
    expect(Number(bal.rows[0].reserved_qty)).toBe(5);
  });
});
