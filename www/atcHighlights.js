/**
 * atcHighlights.js
 * Mapbox GL JS version with Coordinate-to-FIR lookup
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

    atcData.forEach(controller => {
        if (controller.fir_id) {
            // Priority 1: Use the explicit ID from the API
            activeIdsSet.add(controller.fir_id);
        } else if (controller.latitude && controller.longitude) {
            // Priority 2: Queue for spatial lookup if ID is missing
            lookupPoints.push([controller.longitude, controller.latitude]);
        }
    });

    // 2. Supplemental lookup for coordinates if needed.
    if (lookupPoints.length > 0) {
        const firFeatures = map.querySourceFeatures('fir-boundaries');
        lookupPoints.forEach(point => {
            const match = firFeatures.find(f => isPointInPolygon(point, f.geometry));
            if (match && match.properties.id) {
                activeIdsSet.add(match.properties.id);
            }
        });
    }

    const activeIds = Array.from(activeIdsSet);
    
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
}