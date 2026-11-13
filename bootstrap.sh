#!/usr/bin/env bash
set -euo pipefail

mkdir -p \
  .devcontainer \
  infra/postgres/migrations \
  packages/shared-types/src/canonical \
  packages/state-machines/src \
  packages/observability/src \
  apps/api/src/plugins \
  apps/api/src/modules/materials \
  apps/api/src/modules/attachments \
  apps/api/tests/e2e \
  apps/mobile/public/icons \
  apps/mobile/src/db/repositories \
  apps/mobile/src/sync \
  apps/mobile/src/search \
  apps/mobile/src/hardware \
  apps/mobile/src/features/workOrders \
  apps/mobile/src/theme \
  apps/mobile/tests \
  apps/worker-integrations/src/adapters/payroll \
  apps/worker-integrations/src/adapters/wholesalers \
  apps/worker-integrations/src/adapters/tax \
  apps/worker-integrations/src/consumers \
  apps/worker-integrations/src/pdf \
  apps/worker-integrations/tests

# 1. Juuren workspace & Turborepo
cat << 'JSON' > package.json
{
  "name": "kentta-erp-platform",
  "private": true,
  "packageManager": "pnpm@9.12.0",
  "scripts": {
    "dev:api": "pnpm --filter @kentta/api dev",
    "dev:pwa": "pnpm --filter @kentta/mobile dev:web",
    "test": "turbo run test",
    "typecheck": "turbo run typecheck"
  },
  "devDependencies": {
    "turbo": "^2.3.0",
    "typescript": "^5.6.3",
    "vitest": "^2.1.4"
  }
}
JSON

cat << 'YAML' > pnpm-workspace.yaml
packages:
  - "apps/*"
  - "packages/*"
YAML

cat << 'JSON' > turbo.json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "typecheck": { "dependsOn": ["^typecheck"] },
    "test": { "dependsOn": ["^typecheck"] }
  }
}
JSON

cat << 'JSON' > tsconfig.base.json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "isolatedModules": true
  }
}
JSON

# 2. Jaetut paketit
cat << 'JSON' > packages/shared-types/package.json
{
  "name": "@kentta/shared-types",
  "version": "0.1.0",
  "type": "module",
  "main": "./src/index.ts",
  "dependencies": { "zod": "^3.23.8" }
}
JSON
echo "export * from './canonical/index.js';" > packages/shared-types/src/index.ts
touch packages/shared-types/src/canonical/index.ts

cat << 'JSON' > packages/state-machines/package.json
{
  "name": "@kentta/state-machines",
  "version": "0.1.0",
  "type": "module",
  "main": "./src/index.ts",
  "dependencies": { "xstate": "^5.18.2" }
}
JSON
echo "export * from './twoPhaseMaterialMachine.js';" > packages/state-machines/src/index.ts
touch packages/state-machines/src/twoPhaseMaterialMachine.ts

cat << 'JSON' > packages/observability/package.json
{
  "name": "@kentta/observability",
  "version": "0.1.0",
  "type": "module",
  "main": "./src/index.ts",
  "dependencies": { "pino": "^9.5.0" }
}
JSON

cat << 'TS' > packages/observability/src/index.ts
import pino from 'pino';

export type StructuredLogger = pino.Logger;

export function createLogger(service: string): StructuredLogger {
  return pino({
    name: service,
    level: process.env.LOG_LEVEL ?? 'info',
  });
}
TS

# 3. API-paketti (Fastify + Postgres + Redis + NATS)
cat << 'JSON' > apps/api/package.json
{
  "name": "@kentta/api",
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/server.ts",
    "test": "vitest run"
  },
  "dependencies": {
    "@aws-sdk/client-s3": "^3.693.0",
    "@aws-sdk/s3-request-presigner": "^3.693.0",
    "@kentta/observability": "workspace:*",
    "@kentta/shared-types": "workspace:*",
    "fastify": "^5.1.0",
    "fastify-plugin": "^5.0.1",
    "ioredis": "^5.4.1",
    "nats": "^2.29.0",
    "pg": "^8.13.1",
    "uuid": "^11.0.3"
  },
  "devDependencies": {
    "@types/node": "^22.9.0",
    "@types/pg": "^8.11.10",
    "@types/uuid": "^10.0.0",
    "tsx": "^4.19.2"
  }
}
JSON

cat << 'TS' > apps/api/src/server.ts
import Fastify from 'fastify';
import { createLogger } from '@kentta/observability';

const logger = createLogger('api');
const app = Fastify({ logger: false });

app.get('/v1/health', async () => {
  return { status: 'ok', timestamp: new Date().toISOString() };
});

const port = Number(process.env.PORT ?? 3000);
// Tärkeää Codespacesille: kuunnellaan 0.0.0.0-osoitetta
app.listen({ port, host: '0.0.0.0' }).then(() => {
  logger.info(`API listening on http://0.0.0.0:${port}`);
});
TS

# 4. Mobiili / PWA-paketti (React Native Web + Vite + SQLite WASM)
cat << 'JSON' > apps/mobile/package.json
{
  "name": "@kentta/mobile",
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev:web": "vite --host 0.0.0.0 --port 8081",
    "build:web": "vite build",
    "test": "vitest run"
  },
  "dependencies": {
    "@kentta/observability": "workspace:*",
    "@kentta/state-machines": "workspace:*",
    "@sqlite.org/sqlite-wasm": "^3.46.1-build3",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-native-web": "^0.19.13",
    "uuid": "^11.0.3",
    "xstate": "^5.18.2"
  },
  "devDependencies": {
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@types/uuid": "^10.0.0",
    "@vitejs/plugin-react": "^4.3.3",
    "vite": "^5.4.11"
  }
}
JSON

# Vite-konfiguraatio: SQLite WASM exclude + React Native Web alias + /v1 proxy API:in!
cat << 'TS' > apps/mobile/vite.config.ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      'react-native': 'react-native-web',
    },
    extensions: ['.web.tsx', '.web.ts', '.web.js', '.tsx', '.ts', '.js'],
  },
  optimizeDeps: {
    // Kriittinen asetus @sqlite.org/sqlite-wasm:lle jottei .wasm-polut rikkoudu
    exclude: ['@sqlite.org/sqlite-wasm'],
  },
  worker: {
    format: 'es',
  },
  server: {
    host: '0.0.0.0',
    port: 8081,
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
    // Ohjaa PWA:n /v1/* kutsut suoraan API:in ilman CORS- ja porttiongelmia!
    proxy: {
      '/v1': {
        target: 'http://127.0.0.1:3000',
        changeOrigin: true,
      },
    },
  },
});
TS

cat << 'HTML' > apps/mobile/index.html
<!doctype html>
<html lang="fi">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no" />
    <meta name="theme-color" content="#002B7F" />
    <link rel="manifest" href="/manifest.webmanifest" />
    <title>Kenttä-ERP Asentaja</title>
  </head>
  <body style="margin:0;padding:0;background:#050505;">
    <div id="root"></div>
    <script type="module" src="/src/main.web.tsx"></script>
  </body>
</html>
HTML

cat << 'TSX' > apps/mobile/src/main.web.tsx
import React from 'react';
import { createRoot } from 'react-dom/client';
import { View, Text } from 'react-native';

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(console.error);
  });
}

function BootScreen() {
  return (
    <View style={{ flex: 1, minHeight: '100vh' as never, padding: 20, backgroundColor: '#050505', justifyContent: 'center' }}>
      <Text style={{ color: '#FFD600', fontSize: 24, fontWeight: '900' }}>
        Kenttä-ERP PWA (WCAG AAA)
      </Text>
      <Text style={{ color: '#FFFFFF', fontSize: 16, marginTop: 10 }}>
        Runko käynnissä Android-selaimessa. Seuraavaksi kytketään SQLite WASM & FieldWorkOrderScreen!
      </Text>
    </View>
  );
}

createRoot(document.getElementById('root')!).render(<BootScreen />);
TSX

# 5. Integraatiotyöläinen
cat << 'JSON' > apps/worker-integrations/package.json
{
  "name": "@kentta/worker-integrations",
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "test": "vitest run"
  },
  "dependencies": {
    "@aws-sdk/client-s3": "^3.693.0",
    "@kentta/observability": "workspace:*",
    "@kentta/shared-types": "workspace:*",
    "nats": "^2.29.0",
    "pdf-lib": "^1.17.1",
    "pg": "^8.13.1",
    "uuid": "^11.0.3"
  }
}
JSON

echo "✅ Runko luotu! Aja seuraavaksi: corepack enable && pnpm install"
