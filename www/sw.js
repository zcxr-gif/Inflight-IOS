const CACHE_NAME = 'mapbox-tiles-cache-v1';
const MAPBOX_URLS = ['api.mapbox.com', 'tiles.mapbox.com'];

// 1. Immediate activation
self.addEventListener('install', (event) => {
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    // 2. Take control of the page immediately without a reload
    event.waitUntil(clients.claim());
});

self.addEventListener('fetch', (event) => {
    const { request } = event;
    const url = new URL(request.url);

    // 3. Faster domain check using 'host'
    const isMapboxRequest = MAPBOX_URLS.some(domain => url.host.includes(domain));

    if (isMapboxRequest) {
        event.respondWith(handleMapboxRequest(request));
    }
});

async function handleMapboxRequest(request) {
    // 4. Open cache once per request handler
    const cache = await caches.open(CACHE_NAME);
    const cachedResponse = await cache.match(request);

    if (cachedResponse) {
        return cachedResponse;
    }

    try {
        const networkResponse = await fetch(request);

        // 5. Optimization: Only cache valid, successful responses
        if (networkResponse.ok) {
            cache.put(request, networkResponse.clone());
        }

        return networkResponse;
    } catch (error) {
        // Fallback for network failure if not in cache
        return new Response('Network error', { status: 408 });
    }
}