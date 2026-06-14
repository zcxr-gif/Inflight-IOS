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
    // and the layers exist, there is nothing to redraw. This is what makes the
    // 50 s refresh cycle free instead of a full filter rebuild every time.
    const activeKey = activeIds.join('|');
    if (activeKey === _lastActiveKey && map.getLayer('fir-active-labels')) {
        return;
    }
    _lastActiveKey = activeKey;

    // 3. Create a bulletproof "any" filter expression.
    // This explicitly checks if the map feature's ID starts with any of the active controller IDs.
    let filterExpression;

    if (activeIds.length === 0) {
        // If no ATC is online, apply an impossible condition to hide everything natively.
        filterExpression = ["==", "id", "NONE_ACTIVE"];
    } else {
        filterExpression = ["any"];
        activeIds.forEach(activeId => {
            // "index-of" returns 0 if the feature's ID starts with the activeId (e.g., 'KZLA' matches 'KZLA-CTR').
            // We use "coalesce" to prevent Mapbox from crashing if a feature has a missing ID.
            filterExpression.push(["==", ["index-of", activeId, ["coalesce", ["get", "id"], ""]], 0]);
        });
    }

    // --- FILTERING AND STYLING ---

    // Apply the filter directly to the FILL layer to kill any default faint outlines
    map.setFilter(layerId, filterExpression);
    map.setPaintProperty(layerId, 'fill-color', 'rgba(0, 0, 0, 0)');
    map.setPaintProperty(layerId, 'fill-opacity', 0);

    if (map.getLayer('fir-borders')) {
        // Move borders below aircraft but above terrain
        if (map.getLayer('sector-ops-live-flights-layer')) {
            map.moveLayer('fir-borders', 'sector-ops-live-flights-layer');
        }

        // Apply the exact filter to the borders layer so only active ones exist on the GPU
        map.setFilter('fir-borders', filterExpression);

        // Hardcode the active styling since everything else is filtered out
        map.setPaintProperty('fir-borders', 'line-color', '#ff0000');
        map.setPaintProperty('fir-borders', 'line-width', 2.0);

        // --- ADD OR UPDATE THE LABEL STRIP LAYER ---

        if (!map.getLayer('fir-active-labels')) {
            const borderLayer = map.getLayer('fir-borders');

            const labelLayer = {
                id: 'fir-active-labels',
                type: 'symbol',
                source: borderLayer.source,
                layout: {
                    'symbol-placement': 'line',
                    'text-field': ['get', 'id'],
                    'text-size': 14,
                    'text-offset': [0, 1.2],
                    'text-anchor': 'top',
                    'text-max-angle': 45
                },
                paint: {
                    'text-color': '#ff0000',
                    'text-halo-color': 'rgba(255, 255, 255, 0.95)',
                    'text-halo-width': 4,
                    'text-opacity': 1
                }
            };

            if (borderLayer.sourceLayer) {
                labelLayer['source-layer'] = borderLayer.sourceLayer;
            }

            map.addLayer(labelLayer, 'sector-ops-live-flights-layer');
        }

        // Apply the exact same filter to the labels layer
        map.setFilter('fir-active-labels', filterExpression);
        map.setPaintProperty('fir-active-labels', 'text-opacity', 1);
    }

    // Respect the user's ATC-boundaries toggle. The fir-active-labels layer is
    // created lazily above, so re-assert visibility here to cover the case
    // where a brand-new layer appears while the overlay is switched off.
    const boundariesOn = !(window.mapFilters && window.mapFilters.showAtcBoundaries === false);
    ['fir-fills', 'fir-borders', 'fir-active-labels'].forEach(id => {
        if (map.getLayer(id)) {
            map.setLayoutProperty(id, 'visibility', boundariesOn ? 'visible' : 'none');
        }
    });
}
