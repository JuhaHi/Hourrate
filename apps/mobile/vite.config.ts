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
