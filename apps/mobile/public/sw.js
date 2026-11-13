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
