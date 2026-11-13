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
