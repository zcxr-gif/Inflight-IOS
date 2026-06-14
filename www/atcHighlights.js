/**
 * atcHighlights.js
 * Mapbox GL JS version with Coordinate-to-FIR lookup.
 *
 * PERFORMANCE NOTES
 * -----------------
 * The active-sector recompute used to be the reason active ATC felt slow to
 * "put in": every 50 s refresh it ran a full point-in-polygon sweep over the
 * ENTIRE FIR boundary set (querySourceFeatures returns the whole ~1.7 MB
 * source), then rebuilt and re-applied the Mapbox filter on three layers even
 * when nothing had changed. That produced a visible hitch each cycle and a long
 * first paint.
 *
 * This version keeps the exact same visual result but:
 *   1. Skips all map work when the set of active sector IDs is unchanged.
 *   2. Memoizes coordinate -> FIR id lookups, so querySourceFeatures + the
 *      polygon sweep only run when a brand-new, unresolved controller appears.
 *   3. Caches the (expensive) FIR feature list between lookups.
 */

/**
 * Standard Point-in-Polygon algorithm to check if a lat/lon is inside a GeoJSON feature.
 */
function isPointInPolygon(point, polygon) {
    const x = point[0], y = point[1];
    let inside = false;

    const rings = polygon.type === 'Polygon' ? [polygon.coordinates] : polygon.coordinates;

    rings.forEach(ringSet => {
        ringSet.forEach(ring => {
            for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
                const xi = ring[i][0], yi = ring[i][1];
                const xj = ring[j][0], yj = ring[j][1];
                const intersect = ((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi);
                if (intersect) inside = !inside;
            }
        });
    });
    return inside;
}

// --- Caches (module scope) -------------------------------------------------
let _lastActiveKey = null;          // signature of the last applied active-id set
let _firFeatureCache = null;        // cached querySourceFeatures('fir-boundaries')
const _coordFirCache = new Map();   // "lon,lat" (rounded) -> firId | null

// ~0.01deg buckets (~1 km). Controllers sit deep inside their FIR, so rounding
// the position is more than precise enough and lets repeat lookups hit the cache.
function coordKey(lon, lat) {
    return `${lon.toFixed(2)},${lat.toFixed(2)}`;
}

/**
 * Clears the cached lookups. Call when the map/style is rebuilt so a fresh
 * boundary source is re-queried. Safe to call any time.
 */
export function resetActiveSectorCache() {
    _lastActiveKey = null;
    _firFeatureCache = null;
    _coordFirCache.clear();
}

/**
 * Updates the Mapbox layer style based on active ATC.
 * @param {object} map - Your Mapbox map instance
 * @param {string} layerId - The ID of the fill layer (e.g., 'fir-fills')
 * @param {Array} atcData - The array of online Center controllers
 */
export function updateActiveSectors(map, layerId, atcData) {
    if (!map || !map.getLayer(layerId)) return;

    // 1. Build the list of active IDs from data first to prevent flickering.
    const activeIdsSet = new Set();
    const lookupPoints = [];

    (atcData || []).forEach(controller => {
        if (controller.fir_id) {
            // Priority 1: Use the explicit ID from the API
            activeIdsSet.add(controller.fir_id);
        } else if (controller.latitude && controller.longitude) {
            // Priority 2: Queue for spatial lookup if ID is missing — but reuse
            // any previously resolved result so we never sweep polygons twice
            // for the same controller position.
            const lon = Number(controller.longitude);
            const lat = Number(controller.latitude);
            if (!Number.isFinite(lon) || !Number.isFinite(lat)) return;
            const key = coordKey(lon, lat);
            if (_coordFirCache.has(key)) {
                const cached = _coordFirCache.get(key);
                if (cached) activeIdsSet.add(cached);
            } else {
                lookupPoints.push({ lon, lat, key });
            }
        }
    });

    // 2. Supplemental spatial lookup for the (rare) unresolved coordinates only.
    if (lookupPoints.length > 0) {
        let firFeatures = _firFeatureCache;
        if (!firFeatures || firFeatures.length === 0) {
            try {
                firFeatures = map.querySourceFeatures('fir-boundaries') || [];
            } catch (_) {
                firFeatures = [];
            }
            // Only cache a genuinely populated result; an empty array usually
            // means the source hasn't finished loading yet.
            if (firFeatures.length) _firFeatureCache = firFeatures;
        }

        lookupPoints.forEach(p => {
            const match = firFeatures.find(f => isPointInPolygon([p.lon, p.lat], f.geometry));
            const firId = (match && match.properties && match.properties.id) ? match.properties.id : null;
            // Only memoize once we actually had boundaries to test against, so a
            // controller resolves correctly after the source finishes loading.
            if (firFeatures.length) _coordFirCache.set(p.key, firId);
            if (firId) activeIdsSet.add(firId);
        });
    }

    const activeIds = Array.from(activeIdsSet).sort();

    // Short-circuit: if the active set is identical to what's already applied
    // and the highlight layer exists, there is nothing to redraw. This is what
    // makes the 50 s refresh cycle free instead of a full filter rebuild.
    const activeKey = activeIds.join('|');
    if (activeKey === _lastActiveKey && map.getLayer(layerId)) {
        return;
    }
    _lastActiveKey = activeKey;

    // 3. Create a bulletproof "any" filter expression.
    // This explicitly checks if the map feature's ID starts with any of the active controller IDs.
    let filterExpression;

    if (activeIds.length === 0) {
        // If no ATC is online, apply an impossible condition so nothing is tinted.
        filterExpression = ["==", "id", "NONE_ACTIVE"];
    } else {
        filterExpression = ["any"];
        activeIds.forEach(activeId => {
            // "index-of" returns 0 if the feature's ID starts with the activeId (e.g., 'KZLA' matches 'KZLA-CTR').
            // We use "coalesce" to prevent Mapbox from crashing if a feature has a missing ID.
            filterExpression.push(["==", ["index-of", activeId, ["coalesce", ["get", "id"], ""]], 0]);
        });
    }

    // --- HIGHLIGHT STAFFED SECTORS -------------------------------------------
    // The full FIR boundary network is drawn by the always-on 'fir-borders'
    // line layer (set up in initializeMapBoundaries). All we do on each refresh
    // is give the sectors that currently have a controller online a faint
    // translucent tint, so staffed airspace reads at a glance. No red overlays,
    // no text labels — those were the ugly, broken parts of the old behaviour.
    map.setFilter(layerId, filterExpression);
    map.setPaintProperty(layerId, 'fill-color', '#22c55e');
    map.setPaintProperty(layerId, 'fill-opacity', activeIds.length ? 0.12 : 0);

    // Remove the legacy red label layer if an older build left it behind.
    if (map.getLayer('fir-active-labels')) {
        map.removeLayer('fir-active-labels');
    }

    // Keep the boundary layers below the aircraft so planes always sit on top.
    if (map.getLayer('sector-ops-live-flights-layer')) {
        if (map.getLayer('fir-fills')) map.moveLayer('fir-fills', 'sector-ops-live-flights-layer');
        if (map.getLayer('fir-borders')) map.moveLayer('fir-borders', 'sector-ops-live-flights-layer');
    }

    // Respect the user's ATC-boundaries toggle for both overlay layers.
    const boundariesOn = !(window.mapFilters && window.mapFilters.showAtcBoundaries === false);
    ['fir-fills', 'fir-borders'].forEach(id => {
        if (map.getLayer(id)) {
            map.setLayoutProperty(id, 'visibility', boundariesOn ? 'visible' : 'none');
        }
    });
}
