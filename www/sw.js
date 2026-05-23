// Service worker is a no-op now that map tiles are served by native MapKit
// (no HTTP cache to manage). Kept registered so existing scope/registration
// lifecycle is unaffected.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
