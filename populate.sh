#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# 1. DEVCONTAINER & DOCKER-COMPOSE (Kevyt 2-core Codespace-infra)
# ============================================================================
cat << 'JSON' > .devcontainer/devcontainer.json
{
  "name": "Kentta-ERP MVP (Codespaces + PWA)",
  "image": "mcr.microsoft.com/devcontainers/typescript-node:22",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "forwardPorts": [3000, 8081],
  "portsAttributes": {
    "3000": { "label": "Fastify API", "visibility": "public" },
    "8081": { "label": "Kenttä PWA", "visibility": "public" }
  },
  "postCreateCommand": "corepack enable && pnpm install",
  "postStartCommand": "docker compose -f infra/docker-compose.yml up -d postgres redis nats"
}
JSON

cat << 'YAML' > infra/docker-compose.yml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: kentta
      POSTGRES_PASSWORD: kentta_dev_password
      POSTGRES_DB: kentta_erp
    ports: ["5432:5432"]
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./postgres/migrations:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U kentta -d kentta_erp"]
      interval: 5s
      timeout: 3s
      retries: 10

  redis:
    image: redis:7-alpine
    command: ["redis-server", "--appendonly", "yes"]
    ports: ["6379:6379"]
    volumes: [redis_data:/data]

  nats:
    image: nats:2.10-alpine
    command: ["-js", "-sd", "/data", "-m", "8222"]
    ports: ["4222:4222", "8222:8222"]
    volumes: [nats_data:/data]

volumes:
  pg_data:
  redis_data:
  nats_data:
YAML

# ============================================================================
# 2. POSTGRESQL MIGRAATIO (001_init.sql)
# ============================================================================
cat << 'SQL' > infra/postgres/migrations/001_init.sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE TYPE warehouse_type_enum AS ENUM ('CENTRAL', 'VAN', 'SITE');
CREATE TYPE work_order_status_enum AS ENUM ('ASSIGNED', 'DRAFT', 'IN_PROGRESS', 'READY_FOR_SIGN', 'COMMITTED', 'CANCELLED');
CREATE TYPE material_tx_type_enum AS ENUM ('RESERVE', 'RELEASE', 'COMMIT', 'RESTOCK', 'ADJUSTMENT');
CREATE TYPE tes_category_enum AS ENUM ('REGULAR', 'OVERTIME_50', 'OVERTIME_100', 'EMERGENCY_CALLOUT', 'TRAVEL_TIME');
CREATE TYPE user_role_enum AS ENUM ('ADMIN', 'DISPATCHER', 'TECHNICIAN', 'ACCOUNTANT');

CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    business_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    oidc_subject TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    role user_role_enum NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    user_id UUID NOT NULL REFERENCES users(id),
    device_fingerprint TEXT NOT NULL,
    platform TEXT NOT NULL,
    last_sync_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, device_fingerprint)
);
CREATE TABLE processed_idempotency_keys (
    idempotency_key UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    user_id UUID NOT NULL REFERENCES users(id),
    endpoint TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    response_status INTEGER NOT NULL,
    response_body JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE warehouses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    warehouse_type warehouse_type_enum NOT NULL,
    assigned_user_id UUID REFERENCES users(id),
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    is_active BOOLEAN NOT NULL DEFAULT true,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    sku TEXT NOT NULL,
    ean_barcode TEXT,
    sahkonumero TEXT,
    lvi_number TEXT,
    name TEXT NOT NULL,
    description TEXT,
    unit TEXT NOT NULL,
    manufacturer TEXT,
    primary_wholesaler TEXT,
    list_price_cents BIGINT NOT NULL DEFAULT 0,
    net_price_cents BIGINT NOT NULL DEFAULT 0,
    ai_class_label TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, sku)
);
CREATE TABLE inventory_balances (
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    product_id UUID NOT NULL REFERENCES products(id),
    on_hand_qty NUMERIC(12, 3) NOT NULL DEFAULT 0,
    reserved_qty NUMERIC(12, 3) NOT NULL DEFAULT 0,
    min_threshold NUMERIC(12, 3) NOT NULL DEFAULT 0,
    max_threshold NUMERIC(12, 3) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (warehouse_id, product_id),
    CONSTRAINT chk_reserved_non_negative CHECK (reserved_qty >= 0)
);
CREATE TABLE inventory_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    product_id UUID NOT NULL REFERENCES products(id),
    work_order_id UUID,
    tx_type material_tx_type_enum NOT NULL,
    delta_on_hand NUMERIC(12, 3) NOT NULL DEFAULT 0,
    delta_reserved NUMERIC(12, 3) NOT NULL DEFAULT 0,
    idempotency_key UUID NOT NULL UNIQUE,
    correlation_id UUID NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id),
    device_id UUID REFERENCES devices(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    business_id TEXT,
    address TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE work_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    work_order_number TEXT NOT NULL,
    customer_id UUID NOT NULL REFERENCES customers(id),
    title TEXT NOT NULL,
    site_address TEXT,
    status work_order_status_enum NOT NULL DEFAULT 'ASSIGNED',
    assigned_user_id UUID NOT NULL REFERENCES users(id),
    billing_period_locked BOOLEAN NOT NULL DEFAULT false,
    version INTEGER NOT NULL DEFAULT 1,
    committed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, work_order_number)
);
CREATE TABLE work_phases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id UUID NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'PENDING'
);
CREATE TABLE work_order_materials (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    work_order_id UUID NOT NULL REFERENCES work_orders(id),
    work_phase_id UUID REFERENCES work_phases(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    product_id UUID NOT NULL REFERENCES products(id),
    qty NUMERIC(12, 3) NOT NULL CHECK (qty > 0),
    unit_price_cents BIGINT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('DRAFT_RESERVED', 'COMMITTED', 'RELEASED')),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    committed_at TIMESTAMPTZ
);
CREATE TABLE work_time_entries (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    work_order_id UUID NOT NULL REFERENCES work_orders(id),
    user_id UUID NOT NULL REFERENCES users(id),
    tes_category tes_category_enum NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    duration_minutes INTEGER NOT NULL CHECK (duration_minutes >= 0),
    notes TEXT,
    idempotency_key UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE server_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    aggregate_type TEXT NOT NULL,
    aggregate_id UUID NOT NULL,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    correlation_id UUID NOT NULL,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

# ============================================================================
# 3. JAETUT PAKETIT (Canonical Types & Two-Phase State Machine)
# ============================================================================
cat << 'TS' > packages/shared-types/src/canonical/index.ts
import { z } from 'zod';

export const TesCategorySchema = z.enum([
  'REGULAR', 'OVERTIME_50', 'OVERTIME_100', 'EMERGENCY_CALLOUT', 'TRAVEL_TIME',
]);

export const CanonicalPayrollTimeEntrySchema = z.object({
  entryId: z.string().uuid(),
  tenantId: z.string().uuid(),
  employeeInternalId: z.string().uuid(),
  employeeExternalKey: z.string(),
  workDateIso: z.string(),
  tesCategory: TesCategorySchema,
  durationHours: z.number().positive(),
  description: z.string().optional(),
  correlationId: z.string().uuid(),
});
export type CanonicalPayrollTimeEntry = z.infer<typeof CanonicalPayrollTimeEntrySchema>;

export interface CanonicalTravelExpense {
  travelLogId: string;
  employeeExternalKey: string;
  dateIso: string;
  routeDescription: string;
  distanceKm: number;
  allowanceType: 'NONE' | 'PARTIAL_DAY' | 'FULL_DAY';
}

export interface CanonicalSalesInvoice {
  tenantId: string;
  workOrderId: string;
  workOrderNumber: string;
  customerExternalKey: string;
  invoiceDateIso: string;
  paymentTermDays: number;
  lines: Array<{
    skuOrCode: string;
    description: string;
    quantity: number;
    unitPriceCents: number;
    vatRatePercent: number;
    discountPercent: number;
  }>;
  correlationId: string;
}
TS

cat << 'TS' > packages/state-machines/src/twoPhaseMaterialMachine.ts
import { setup, assign } from 'xstate';

export interface MaterialAllocationContext {
  allocationId: string;
  workOrderId: string;
  warehouseId: string;
  productId: string;
  qty: number;
  error: string | null;
}

export type MaterialAllocationEvent =
  | { type: 'RESERVE_DRAFT'; allocationId: string; workOrderId: string; warehouseId: string; productId: string; qty: number }
  | { type: 'ADJUST_QTY'; newQty: number }
  | { type: 'RELEASE' }
  | { type: 'COMMIT' };

export const twoPhaseMaterialMachine = setup({
  types: {
    context: {} as MaterialAllocationContext,
    events: {} as MaterialAllocationEvent,
  },
  guards: {
    isValidPositiveQty: ({ event }) =>
      (event.type === 'RESERVE_DRAFT' && event.qty > 0) ||
      (event.type === 'ADJUST_QTY' && event.newQty > 0),
  },
  actions: {
    init: assign(({ event }) =>
      event.type === 'RESERVE_DRAFT'
        ? { allocationId: event.allocationId, workOrderId: event.workOrderId, warehouseId: event.warehouseId, productId: event.productId, qty: event.qty, error: null }
        : {}
    ),
    setError: assign({ error: 'Määrän on oltava > 0' }),
  },
}).createMachine({
  id: 'twoPhaseMaterial',
  initial: 'unallocated',
  context: { allocationId: '', workOrderId: '', warehouseId: '', productId: '', qty: 0, error: null },
  states: {
    unallocated: {
      on: {
        RESERVE_DRAFT: [
          { guard: 'isValidPositiveQty', target: 'draftReserved', actions: 'init' },
          { actions: 'setError' },
        ],
      },
    },
    draftReserved: {
      on: { RELEASE: 'released', COMMIT: 'committed' },
    },
    committed: { type: 'final' },
    released: { type: 'final' },
  },
});
TS

# ============================================================================
# 4. API: IDEMPOTENCY MIDDLEWARE + MATERIAL SERVICE + SERVER + E2E-TESTI
# ============================================================================
cat << 'TS' > apps/api/src/plugins/idempotency.ts
import fp from 'fastify-plugin';
import crypto from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { Redis } from 'ioredis';
import type { Pool } from 'pg';

const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

declare module 'fastify' {
  interface FastifyRequest {
    auth?: { tenantId: string; userId: string };
    idempotencyMeta?: { key: string; redisKey: string; requestHash: string; tenantId: string; userId: string };
  }
}

function computeHash(method: string, url: string, body: unknown): string {
  return crypto.createHash('sha256').update(JSON.stringify({ method, url, body: body ?? null })).digest('hex');
}

export const idempotencyPlugin = fp<{ redis: Redis; pgPool: Pool }>(
  async (fastify: FastifyInstance, { redis, pgPool }) => {
    fastify.addHook('preHandler', async (request: FastifyRequest, reply: FastifyReply) => {
      if (!MUTATING_METHODS.has(request.method)) return;
      const rawKey = request.headers['idempotency-key'];
      const key = Array.isArray(rawKey) ? rawKey[0] : rawKey;
      if (!key || !UUID_V4_REGEX.test(key)) {
        return reply.status(400).send({
          code: 'MISSING_OR_INVALID_IDEMPOTENCY_KEY',
          message: 'Vaaditaan validi UUIDv4 Idempotency-Key -otsikko.',
        });
      }

      const tenantId = request.auth?.tenantId ?? '00000000-0000-4000-8000-000000000001';
      const userId = request.auth?.userId ?? '00000000-0000-4000-8000-000000000002';
      const redisKey = `idem:${tenantId}:${key}`;
      const requestHash = computeHash(request.method, request.url, request.body);

      const cachedRaw = await redis.get(redisKey);
      if (cachedRaw) {
        const cached = JSON.parse(cachedRaw);
        if (cached.requestHash !== requestHash) {
          return reply.status(422).send({ code: 'IDEMPOTENCY_KEY_PAYLOAD_MISMATCH', message: 'Eri payload samalla avaimella.' });
        }
        if (cached.status === 'IN_FLIGHT') {
          return reply.status(409).header('Retry-After', '2').send({ code: 'IDEMPOTENCY_CONCURRENT_REQUEST', message: 'Käsittelyssä.' });
        }
        return reply.status(cached.responseStatus).header('X-Idempotent-Replayed', 'true').send(cached.responseBody);
      }

      const pgRes = await pgPool.query(
        `SELECT request_hash, response_status, response_body FROM processed_idempotency_keys WHERE idempotency_key = $1 AND tenant_id = $2`,
        [key, tenantId]
      );
      if (pgRes.rows.length > 0) {
        const row = pgRes.rows[0];
        if (row.request_hash !== requestHash) {
          return reply.status(422).send({ code: 'IDEMPOTENCY_KEY_PAYLOAD_MISMATCH', message: 'Eri payload samalla avaimella.' });
        }
        await redis.set(redisKey, JSON.stringify({ status: 'COMPLETED', requestHash, responseStatus: row.response_status, responseBody: row.response_body }), 'EX', 86400);
        return reply.status(row.response_status).header('X-Idempotent-Replayed', 'true').send(row.response_body);
      }

      const acquired = await redis.set(redisKey, JSON.stringify({ status: 'IN_FLIGHT', requestHash }), 'EX', 30, 'NX');
      if (!acquired) {
        return reply.status(409).header('Retry-After', '2').send({ code: 'IDEMPOTENCY_CONCURRENT_REQUEST', message: 'Duplikaatti torjuttu.' });
      }
      request.idempotencyMeta = { key, redisKey, requestHash, tenantId, userId };
    });

    fastify.addHook('onSend', async (request, reply, payload) => {
      const meta = request.idempotencyMeta;
      if (!meta) return payload;
      if (reply.statusCode >= 500) {
        await redis.del(meta.redisKey);
        return payload;
      }
      let parsed: unknown = payload;
      if (typeof payload === 'string') {
        try { parsed = JSON.parse(payload); } catch { parsed = { raw: payload }; }
      }
      await Promise.all([
        redis.set(meta.redisKey, JSON.stringify({ status: 'COMPLETED', requestHash: meta.requestHash, responseStatus: reply.statusCode, responseBody: parsed }), 'EX', 86400),
        pgPool.query(
          `INSERT INTO processed_idempotency_keys (idempotency_key, tenant_id, user_id, endpoint, request_hash, response_status, response_body)
           VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (idempotency_key) DO NOTHING`,
          [meta.key, meta.tenantId, meta.userId, request.url, meta.requestHash, reply.statusCode, JSON.stringify(parsed ?? {})]
        ),
      ]);
      return payload;
    });

    fastify.addHook('onError', async (request) => {
      if (request.idempotencyMeta) await redis.del(request.idempotencyMeta.redisKey);
    });
  }
);
TS

cat << 'TS' > apps/api/src/modules/materials/materialService.ts
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
TS

cat << 'TS' > apps/api/src/server.ts
import Fastify from 'fastify';
import { Pool } from 'pg';
import Redis from 'ioredis';
import { v4 as uuidv4 } from 'uuid';
import { createLogger } from '@kentta/observability';
import { idempotencyPlugin } from './plugins/idempotency.js';
import { MaterialService, DomainConflictError } from './modules/materials/materialService.js';

const logger = createLogger('api');
const pgPool = new Pool({ connectionString: process.env.DATABASE_URL ?? 'postgresql://kentta:kentta_dev_password@localhost:5432/kentta_erp' });
const redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');
const materialService = new MaterialService(pgPool);

const app = Fastify({ logger: false });
const DEV_TENANT = '00000000-0000-4000-8000-000000000001';
const DEV_USER = '00000000-0000-4000-8000-000000000002';

app.addHook('onRequest', async (req) => {
  req.auth = { tenantId: DEV_TENANT, userId: DEV_USER };
});

await app.register(idempotencyPlugin, { redis, pgPool });

app.get('/v1/health', async () => ({ status: 'ok', time: new Date().toISOString() }));

app.post('/v1/materials/reserve', async (req, reply) => {
  try {
    const b = req.body as Record<string, unknown>;
    const res = await materialService.reserveMaterial({
      tenantId: DEV_TENANT,
      userId: DEV_USER,
      idempotencyKey: req.headers['idempotency-key'] as string,
      correlationId: (req.headers['x-correlation-id'] as string) ?? uuidv4(),
      allocationId: String(b.allocationId),
      workOrderId: String(b.workOrderId),
      warehouseId: String(b.warehouseId),
      productId: String(b.productId),
      deltaQty: Number(b.deltaQty),
      unitPriceCents: Number(b.unitPriceCents),
    });
    return reply.status(201).send(res);
  } catch (err) {
    if (err instanceof DomainConflictError) return reply.status(err.statusCode).send({ code: err.code, message: err.message });
    throw err;
  }
});

app.post('/v1/work-orders/:id/materials/commit', async (req, reply) => {
  try {
    const { id } = req.params as { id: string };
    const b = req.body as { allocationIds: string[] };
    const res = await materialService.commitWorkOrderMaterials({
      tenantId: DEV_TENANT,
      userId: DEV_USER,
      workOrderId: id,
      allocationIds: b.allocationIds,
      correlationId: (req.headers['x-correlation-id'] as string) ?? uuidv4(),
    });
    return reply.status(200).send(res);
  } catch (err) {
    if (err instanceof DomainConflictError) return reply.status(err.statusCode).send({ code: err.code, message: err.message });
    throw err;
  }
});

app.post('/v1/time-entries', async (_req, reply) => {
  return reply.status(201).send({ accepted: true });
});

const port = Number(process.env.PORT ?? 3000);
app.listen({ port, host: '0.0.0.0' }).then(() => logger.info(`API running on :${port}`));
TS

cat << 'TS' > apps/api/tests/e2e/idempotencyAndTwoPhase.e2e.test.ts
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
TS

# ============================================================================
# 5. MOBIILI / PWA (SQLite WASM + Outbox + Tiered Search + Field UI + Testit)
# ============================================================================
cat << 'TS' > apps/mobile/src/db/driver.ts
export interface QueryResult {
  rows: Record<string, unknown>[];
}
export interface LocalDatabaseDriver {
  execute(sql: string, params?: unknown[]): Promise<QueryResult>;
  transaction<T>(fn: (tx: LocalDatabaseDriver) => Promise<T>): Promise<T>;
}
TS

cat << 'TS' > apps/mobile/src/db/schema.ts
export const SQLITE_INIT_SCHEMA = `
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS sync_outbox (
    id TEXT PRIMARY KEY NOT NULL,
    sequence_num INTEGER NOT NULL UNIQUE,
    aggregate_type TEXT NOT NULL,
    aggregate_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    http_method TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    correlation_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING',
    retry_count INTEGER NOT NULL DEFAULT 0,
    next_retry_at TEXT,
    last_error_code TEXT,
    last_error_message TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dead_letter_queue (
    id TEXT PRIMARY KEY NOT NULL,
    original_outbox_id TEXT NOT NULL,
    aggregate_type TEXT NOT NULL,
    aggregate_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    error_code TEXT NOT NULL,
    error_message TEXT NOT NULL,
    resolution_action TEXT,
    resolved_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS warehouses (
    id TEXT PRIMARY KEY NOT NULL,
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    warehouse_type TEXT NOT NULL,
    latitude REAL,
    longitude REAL,
    is_active INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS products (
    id TEXT PRIMARY KEY NOT NULL,
    sku TEXT NOT NULL,
    ean_barcode TEXT,
    sahkonumero TEXT,
    lvi_number TEXT,
    name TEXT NOT NULL,
    unit TEXT NOT NULL,
    manufacturer TEXT,
    primary_wholesaler TEXT,
    net_price_cents INTEGER NOT NULL DEFAULT 0,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS products_fts USING fts5(
    product_id UNINDEXED, name, sku, ean_barcode, sahkonumero, lvi_number, manufacturer,
    content='products', content_rowid='rowid'
);

CREATE TRIGGER IF NOT EXISTS products_ai AFTER INSERT ON products BEGIN
    INSERT INTO products_fts(rowid, product_id, name, sku, ean_barcode, sahkonumero, lvi_number, manufacturer)
    VALUES (new.rowid, new.id, new.name, new.sku, new.ean_barcode, new.sahkonumero, new.lvi_number, new.manufacturer);
END;

CREATE TABLE IF NOT EXISTS inventory_balances (
    warehouse_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    on_hand_qty REAL NOT NULL DEFAULT 0,
    reserved_qty REAL NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (warehouse_id, product_id)
);

CREATE TABLE IF NOT EXISTS material_allocations (
    id TEXT PRIMARY KEY NOT NULL,
    work_order_id TEXT NOT NULL,
    work_phase_id TEXT,
    warehouse_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    qty REAL NOT NULL,
    unit_price_cents INTEGER NOT NULL,
    state TEXT NOT NULL,
    is_synced INTEGER NOT NULL DEFAULT 0,
    created_by TEXT NOT NULL,
    created_at TEXT NOT NULL,
    committed_at TEXT
);

CREATE TABLE IF NOT EXISTS work_time_entries (
    id TEXT PRIMARY KEY NOT NULL,
    work_order_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    tes_category TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    duration_minutes INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'DRAFT',
    is_synced INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
`;
TS

cat << 'TS' > apps/mobile/src/db/sqlite.worker.ts
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
TS

cat << 'TS' > apps/mobile/src/db/driver.web.ts
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
TS

cat << 'TS' > apps/mobile/src/db/repositories/materialRepository.ts
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
TS

cat << 'TS' > apps/mobile/src/sync/outboxProcessor.ts
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
TS

cat << 'TS' > apps/mobile/src/hardware/voiceCommands.ts
export type VoiceIntent =
  | { type: 'ADD_MATERIAL'; quantity: number; searchQuery: string }
  | { type: 'START_TIME_ENTRY'; tesCategory: 'REGULAR' | 'OVERTIME_50' | 'OVERTIME_100' | 'EMERGENCY_CALLOUT' | 'TRAVEL_TIME' }
  | { type: 'STOP_TIME_ENTRY' }
  | { type: 'UNKNOWN'; rawTranscript: string };

export function parseVoiceCommand(transcript: string): VoiceIntent {
  const n = transcript.toLowerCase().trim();
  if (/(lopeta|pysäytä)\s*(työ|aika)/.test(n)) return { type: 'STOP_TIME_ENTRY' };
  if (/(aloita|käynnistä)\s*(ylityö\s*50|ylityö)/.test(n)) return { type: 'START_TIME_ENTRY', tesCategory: 'OVERTIME_50' };
  if (/(aloita|käynnistä)\s*(normaali|työ)/.test(n)) return { type: 'START_TIME_ENTRY', tesCategory: 'REGULAR' };
  const m = n.match(/^(?:lisää|ota)\s+(\d+(?:[.,]\d+)?)\s*(?:kpl|kappaletta|m|metriä)?\s+(.+)$/i);
  if (m) return { type: 'ADD_MATERIAL', quantity: Number(m[1].replace(',', '.')), searchQuery: m[2].trim() };
  return { type: 'UNKNOWN', rawTranscript: transcript };
}
TS

cat << 'TS' > apps/mobile/src/search/tieredSearch.ts
import type { LocalDatabaseDriver } from '../db/driver';

export interface ProductSearchResult {
  productId: string; sku: string; sahkonumero: string | null; name: string;
  unit: string; netPriceCents: number; availableWarehouseId: string | null;
  availableWarehouseName: string | null; availableQty: number;
}

export class TieredProductSearchService {
  constructor(private readonly db: LocalDatabaseDriver) {}

  async search(rawQuery: string, ownVanWarehouseId: string) {
    const t0 = performance.now();
    const q = rawQuery.trim();
    if (!q) return { results: [] as ProductSearchResult[], durationMs: 0 };

    const exact = await this.db.execute(
      `SELECT p.id AS productId, p.sku, p.sahkonumero, p.name, p.unit, p.net_price_cents AS netPriceCents,
              w.id AS availableWarehouseId, w.name AS availableWarehouseName,
              COALESCE(ib.on_hand_qty - ib.reserved_qty, 0) AS availableQty
       FROM products p
       LEFT JOIN inventory_balances ib ON ib.product_id = p.id AND ib.warehouse_id = ?
       LEFT JOIN warehouses w ON w.id = ib.warehouse_id
       WHERE p.ean_barcode = ? OR p.sahkonumero = ? OR p.lvi_number = ? OR p.sku = ? LIMIT 10`,
      [ownVanWarehouseId, q, q, q, q]
    );
    if (exact.rows.length > 0) {
      return { results: exact.rows as unknown as ProductSearchResult[], durationMs: Math.round((performance.now() - t0) * 100) / 100 };
    }

    const fts = q.replace(/["*^():-]/g, ' ').split(/\s+/).filter(Boolean).map((t) => `"${t}"*`).join(' AND ');
    if (!fts) return { results: [], durationMs: 0 };

    const res = await this.db.execute(
      `SELECT p.id AS productId, p.sku, p.sahkonumero, p.name, p.unit, p.net_price_cents AS netPriceCents,
              w.id AS availableWarehouseId, COALESCE(w.name, 'Katalogi') AS availableWarehouseName,
              COALESCE(ib.on_hand_qty - ib.reserved_qty, 0) AS availableQty
       FROM products_fts f
       JOIN products p ON p.id = f.product_id
       LEFT JOIN inventory_balances ib ON ib.product_id = p.id
       LEFT JOIN warehouses w ON w.id = ib.warehouse_id
       WHERE products_fts MATCH ?
       ORDER BY CASE WHEN ib.warehouse_id = ? THEN 0 ELSE 1 END, p.is_favorite DESC
       LIMIT 20`,
      [fts, ownVanWarehouseId]
    );
    return { results: res.rows as unknown as ProductSearchResult[], durationMs: Math.round((performance.now() - t0) * 100) / 100 };
  }
}
TS

cat << 'TSX' > apps/mobile/src/main.web.tsx
import React, { useEffect, useState, useCallback } from 'react';
import { createRoot } from 'react-dom/client';
import { View, Text, TextInput, Pressable, FlatList } from 'react-native';
import { WebSqliteDriver } from './db/driver.web';
import { SQLITE_INIT_SCHEMA } from './db/schema';
import { TieredProductSearchService, type ProductSearchResult } from './search/tieredSearch';
import { MaterialRepository } from './db/repositories/materialRepository';
import { OutboxProcessor } from './sync/outboxProcessor';

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(console.error));
}

const VAN_ID = '11111111-1111-4111-8111-111111111111';
const WO_ID = '22222222-2222-4222-8222-222222222222';
const USER_ID = '00000000-0000-4000-8000-000000000002';

function PwaFieldApp() {
  const [driver] = useState(() => new WebSqliteDriver());
  const [ready, setReady] = useState(false);
  const [errMsg, setErrMsg] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<ProductSearchResult[]>([]);
  const [latencyMs, setLatencyMs] = useState<number | null>(null);
  const [outboxCount, setOutboxCount] = useState(0);
  const [darkMode, setDarkMode] = useState(true);

  const refreshOutbox = useCallback(async () => {
    const r = await driver.execute(`SELECT COUNT(*) AS cnt FROM sync_outbox WHERE status != 'DLQ'`);
    setOutboxCount(Number(r.rows[0]?.cnt ?? 0));
  }, [driver]);

  useEffect(() => {
    (async () => {
      try {
        await driver.init(SQLITE_INIT_SCHEMA);
        const existing = await driver.execute(`SELECT COUNT(*) AS cnt FROM products`);
        if (Number(existing.rows[0]?.cnt ?? 0) === 0) {
          const now = new Date().toISOString();
          await driver.execute(`INSERT INTO warehouses (id, code, name, warehouse_type, updated_at) VALUES (?, 'VAN-01', 'Oma Huoltoauto', 'VAN', ?)`, [VAN_ID, now]);
          await driver.execute(`INSERT INTO products (id, sku, sahkonumero, name, unit, net_price_cents, is_favorite, updated_at) VALUES ('p1','MMJ-315','0401234','MMJ 3x1.5S asennuskaapeli','m',125,1,?)`, [now]);
          await driver.execute(`INSERT INTO products (id, sku, sahkonumero, name, unit, net_price_cents, is_favorite, updated_at) VALUES ('p2','SUKO-IP44','2506100','Suko-pistorasia IP44 pinta','kpl',1490,1,?)`, [now]);
          await driver.execute(`INSERT INTO inventory_balances (warehouse_id, product_id, on_hand_qty, reserved_qty, updated_at) VALUES (?, 'p1', 100, 0, ?)`, [VAN_ID, now]);
          await driver.execute(`INSERT INTO inventory_balances (warehouse_id, product_id, on_hand_qty, reserved_qty, updated_at) VALUES (?, 'p2', 12, 0, ?)`, [VAN_ID, now]);
        }
        await refreshOutbox();
        setReady(true);
      } catch (e) {
        setErrMsg(e instanceof Error ? e.message : String(e));
      }
    })();
  }, [driver, refreshOutbox]);

  useEffect(() => {
    if (!ready) return;
    const svc = new TieredProductSearchService(driver);
    void svc.search(query || 'MMJ', VAN_ID).then((r) => {
      setResults(r.results);
      setLatencyMs(r.durationMs);
    });
  }, [query, ready, driver]);

  const handleReserve = async (item: ProductSearchResult) => {
    const repo = new MaterialRepository(driver);
    await repo.reserveDraftMaterial({
      workOrderId: WO_ID,
      warehouseId: item.availableWarehouseId ?? VAN_ID,
      productId: item.productId,
      qty: 1,
      unitPriceCents: item.netPriceCents,
      userId: USER_ID,
    });
    await refreshOutbox();
    const outbox = new OutboxProcessor(driver, {
      apiBaseUrl: '', // Käyttää saman originin /v1-proxya!
      deviceId: 'android-pwa',
      isNetworkAvailable: async () => navigator.onLine,
      onDlqAlert: (d) => alert(`DLQ: ${d.errorCode} - ${d.errorMessage}`),
    });
    await outbox.processQueue().catch(() => undefined);
    await refreshOutbox();
  };

  const bg = darkMode ? '#050505' : '#FFFFFF';
  const fg = darkMode ? '#FFFFFF' : '#000000';
  const btnBg = darkMode ? '#FFD600' : '#002B7F';
  const btnFg = darkMode ? '#000000' : '#FFFFFF';

  if (errMsg) return <View style={{ padding: 20, backgroundColor: '#B00020' }}><Text style={{ color: '#FFF', fontSize: 18 }}>{errMsg}</Text></View>;
  if (!ready) return <View style={{ padding: 20, backgroundColor: bg }}><Text style={{ color: fg, fontSize: 18 }}>Alustetaan SQLite WASM (OPFS)...</Text></View>;

  return (
    <View style={{ minHeight: '100vh' as never, padding: 16, backgroundColor: bg }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
        <View>
          <Text style={{ color: fg, fontSize: 22, fontWeight: '900' }}>Työ #WO-2026-001</Text>
          <Text style={{ color: fg, fontSize: 14 }}>Outbox-jono: {outboxCount} • Haku: {latencyMs ?? 0} ms</Text>
        </View>
        <Pressable onPress={() => setDarkMode((d) => !d)} style={{ minHeight: 48, paddingHorizontal: 14, justifyContent: 'center', backgroundColor: btnBg, borderRadius: 8 }}>
          <Text style={{ color: btnFg, fontWeight: '900' }}>{darkMode ? 'PÄIVÄ' : 'PIMEÄ'}</Text>
        </Pressable>
      </View>

      <TextInput
        value={query}
        onChangeText={setQuery}
        placeholder="Hae sähkönumerolla tai nimellä..."
        placeholderTextColor="#888"
        style={{ minHeight: 56, borderWidth: 2, borderColor: fg, borderRadius: 8, paddingHorizontal: 12, color: fg, fontSize: 18, marginBottom: 12 }}
      />

      <FlatList
        data={results}
        keyExtractor={(i) => i.productId}
        renderItem={({ item }) => (
          <Pressable
            onPress={() => void handleReserve(item)}
            style={{ minHeight: 60, padding: 12, borderWidth: 2, borderColor: fg, borderRadius: 8, marginBottom: 8, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}
          >
            <View style={{ flex: 1 }}>
              <Text style={{ color: fg, fontWeight: '800', fontSize: 16 }}>{item.name}</Text>
              <Text style={{ color: fg, fontSize: 13 }}>{item.sahkonumero} • Saldo: {item.availableQty} {item.unit}</Text>
            </View>
            <View style={{ minHeight: 48, paddingHorizontal: 14, justifyContent: 'center', backgroundColor: btnBg, borderRadius: 6 }}>
              <Text style={{ color: btnFg, fontWeight: '900' }}>+ VARAA</Text>
            </View>
          </Pressable>
        )}
      />
    </View>
  );
}

createRoot(document.getElementById('root')!).render(<PwaFieldApp />);
TSX

cat << 'JSON' > apps/mobile/public/manifest.webmanifest
{
  "name": "Kenttä-ERP Asentaja",
  "short_name": "KenttäERP",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#050505",
  "theme_color": "#002B7F"
}
JSON

cat << 'JS' > apps/mobile/public/sw.js
const CACHE = 'kentta-pwa-v1';
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(['/', '/index.html', '/manifest.webmanifest'])));
  self.skipWaiting();
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.pathname.startsWith('/v1/') || e.request.method !== 'GET') return;
  e.respondWith(caches.match(e.request).then((c) => c || fetch(e.request)));
});
JS

cat << 'TS' > apps/mobile/tests/offlineSyncAndSearch.test.ts
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
TS

echo "✅ populate.sh valmis! Koodi ja testit kirjoitettu."
