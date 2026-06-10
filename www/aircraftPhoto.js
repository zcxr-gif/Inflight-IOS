/**
 * aircraftPhoto.js
 *
 * Tiny shared resolver for real aircraft photos, keyed by registration.
 * Uses the free Planespotters public API (CORS-enabled, no key). Results —
 * including misses — are cached per session so the same airframe is only
 * fetched once, and every consumer (search detail card, pilot profile) shares
 * the same in-flight promise.
 *
 * window.InflightAircraftPhoto.get(registration) -> Promise<{
 *   src, link, photographer
 * } | null>
 */

const PLANESPOTTERS_URL = 'https://api.planespotters.net/pubapi/v1/photos/reg/';

const _cache = new Map(); // reg(UPPER) -> Promise<photo|null>

export function getAircraftPhoto(registration) {
    const reg = String(registration || '').trim().toUpperCase();
    if (!reg) return Promise.resolve(null);
    if (_cache.has(reg)) return _cache.get(reg);

    const p = fetch(`${PLANESPOTTERS_URL}${encodeURIComponent(reg)}`)
        .then(r => (r.ok ? r.json() : null))
        .then(json => {
            const photo = json?.photos?.[0];
            if (!photo) return null;
            const src = photo.thumbnail_large?.src || photo.thumbnail?.src || null;
            if (!src) return null;
            return {
                src,
                link: photo.link || null,
                photographer: photo.photographer || null,
            };
        })
        .catch(() => null);

    _cache.set(reg, p);
    return p;
}

if (typeof window !== 'undefined') {
    window.InflightAircraftPhoto = { get: getAircraftPhoto };
}
