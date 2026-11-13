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
