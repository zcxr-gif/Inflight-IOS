/**
 * terrainMode.js
 *
 * "Terrain Awareness" mode — a free-for-all overlay built to help both pilots
 * and controllers plan around high terrain. It has two parts:
 *
 *   1. Elevation color map (hypsometric tint): land is tinted by height
 *      (green lowlands -> tan -> brown -> snow) over shaded relief, so ridges
 *      and high terrain read at a glance.
 *
 *   2. Altitude coloring (TAWS): an optional cockpit-style mode where terrain
 *      is colored RELATIVE to a planned altitude — terrain at/above the
 *      altitude glows red, just below it amber/yellow, and safely-below stays
 *      a faint green. Driven by the "Planned Altitude" slider.
 *
 * Rendering stack (bottom -> top), inserted beneath the first label layer so
 * place/road labels stay legible:
 *   terrain-color      raster layer, Terrain-RGB decoded via raster-color
 *   terrain-hillshade  shaded relief from the DEM
 * A gentle 3D exaggeration is applied via setTerrain so the view stays
 * analytical rather than cinematic.
 *
 * NOTE: the color layer relies on Mapbox GL JS v3 `raster-color`. If the
 * running engine doesn't support it, addLayer throws and we fall back to the
 * hillshade relief alone (still useful) rather than breaking the map.
 */

const DEM_SOURCE = 'mapbox-dem';        // raster-dem; shared with the Pro 3D-terrain toggle
const RGB_SOURCE = 'terrain-rgb-src';   // raster Terrain-RGB tiles for elevation decode
const COLOR_LAYER = 'terrain-color';
const HILLSHADE_LAYER = 'terrain-hillshade';

const FT_TO_M = 0.3048;

// Terrain-RGB decode to metres. Mapbox feeds raster-color-mix the channel
// values NORMALISED to [0,1] (its default mix is the luminance weights
// [0.2126,0.7152,0.0722,0], which only sum to 1 for 0-1 inputs), so the classic
// 0-255 formula is scaled by 255:
//   elevation_m = -10000 + (R255*65536 + G255*256 + B255) * 0.1   (R255 = R*255)
//               = R*(255*65536*0.1) + G*(255*256*0.1) + B*(255*0.1) - 10000
//               = R*1671168 + G*6528 + B*25.5 - 10000
const RGB_DECODE_MIX = [1671168, 6528, 25.5, -10000];

// Build an `interpolate` color expression from [value, color] pairs, forcing
// the input stops to be strictly ascending (Mapbox requires it). This lets the
// callers compute altitude-relative stops without worrying about collisions.
function buildInterpolate(pairs) {
    const expr = ['interpolate', ['linear'], ['raster-value']];
    let prev = -Infinity;
    pairs.forEach(([value, color]) => {
        let v = value;
        if (!(v > prev)) v = prev + 1;
        expr.push(v, color);
        prev = v;
    });
    return expr;
}

// Hypsometric tint (TAWS off). Alpha is baked into each colour so low ground
// stays subtle while peaks read strongly; raster-opacity is left at 1.
function hypsometricRamp() {
    return buildInterpolate([
        [0,    'rgba(31, 107, 58, 0.50)'],
        [300,  'rgba(74, 150, 70, 0.50)'],
        [700,  'rgba(150, 170, 70, 0.52)'],
        [1200, 'rgba(214, 182, 92, 0.55)'],
        [2000, 'rgba(185, 133, 63, 0.58)'],
        [3000, 'rgba(140, 90, 54, 0.62)'],
        [4200, 'rgba(180, 176, 170, 0.70)'],
        [5500, 'rgba(255, 255, 255, 0.80)']
    ]);
}

// Altitude-relative ramp (TAWS on). Coloured against the planned altitude:
//   below alt-2000 ft : faint green  (safe)
//   alt-2000..-1000   : yellow       (caution)
//   alt-1000..alt     : amber
//   at / above alt    : red          (danger)
function tawsRamp(altitudeFt) {
    const t1 = (altitudeFt - 2000) * FT_TO_M; // safe -> caution
    const t2 = (altitudeFt - 1000) * FT_TO_M; // caution -> amber
    const t3 = altitudeFt * FT_TO_M;          // amber -> danger
    return buildInterpolate([
        [Math.max(0, t1 - 600), 'rgba(40, 150, 75, 0.10)'],
        [Math.max(1, t1),       'rgba(255, 221, 64, 0.45)'],
        [Math.max(2, t2),       'rgba(255, 140, 0, 0.62)'],
        [Math.max(3, t3),       'rgba(255, 42, 42, 0.88)'],
        [Math.max(4, t3 + 800), 'rgba(255, 42, 42, 0.92)']
    ]);
}

function colorRange(opts) {
    if (opts && opts.tawsEnabled) {
        const t3 = (Number(opts.altitudeFt) || 10000) * FT_TO_M;
        return [0, Math.max(6000, Math.round(t3 + 1000))];
    }
    return [0, 6000];
}

function ensureSources(map) {
    if (!map.getSource(DEM_SOURCE)) {
        map.addSource(DEM_SOURCE, {
            type: 'raster-dem',
            url: 'mapbox://mapbox.mapbox-terrain-dem-v1',
            tileSize: 512,
            maxzoom: 14
        });
    }
    if (!map.getSource(RGB_SOURCE)) {
        map.addSource(RGB_SOURCE, {
            type: 'raster',
            url: 'mapbox://mapbox.terrain-rgb',
            tileSize: 256,
            maxzoom: 14
        });
    }
}

// Insert beneath the first symbol (label) layer so labels stay on top.
function pickBeforeId(map) {
    const layers = (map.getStyle() && map.getStyle().layers) || [];
    const firstSymbol = layers.find(l => l.type === 'symbol');
    return firstSymbol ? firstSymbol.id : undefined;
}

/**
 * Turn the terrain overlay on and sync its colouring to `opts`.
 * @param {object} map  Mapbox map instance
 * @param {{tawsEnabled?:boolean, altitudeFt?:number}} opts
 */
export function applyTerrainMode(map, opts = {}) {
    if (!map) return;
    // Defer until the style is ready so addSource/addLayer don't throw.
    if (typeof map.isStyleLoaded === 'function' && !map.isStyleLoaded()) {
        map.once('idle', () => applyTerrainMode(map, opts));
        return;
    }

    ensureSources(map);
    const beforeId = pickBeforeId(map);

    if (!map.getLayer(COLOR_LAYER)) {
        try {
            map.addLayer({
                id: COLOR_LAYER,
                type: 'raster',
                source: RGB_SOURCE,
                paint: {
                    'raster-color-mix': RGB_DECODE_MIX,
                    'raster-color-range': colorRange(opts),
                    'raster-color': opts.tawsEnabled
                        ? tawsRamp(Number(opts.altitudeFt) || 10000)
                        : hypsometricRamp(),
                    'raster-opacity': 1,
                    'raster-resampling': 'linear',
                    'raster-fade-duration': 300
                }
            }, beforeId);
        } catch (e) {
            // Engine without raster-color support — relief shading alone still
            // conveys terrain, so carry on instead of breaking the map.
            console.warn('Terrain color layer unsupported; using hillshade only.', e);
        }
    }

    if (!map.getLayer(HILLSHADE_LAYER)) {
        map.addLayer({
            id: HILLSHADE_LAYER,
            type: 'hillshade',
            source: DEM_SOURCE,
            paint: {
                'hillshade-exaggeration': 0.55,
                'hillshade-shadow-color': 'rgba(0, 0, 0, 0.6)',
                'hillshade-highlight-color': 'rgba(255, 255, 255, 0.4)',
                'hillshade-accent-color': 'rgba(0, 0, 0, 0.3)'
            }
        }, beforeId);
    }

    // Gentle 3D so terrain reads as relief without an exaggerated flythrough.
    try { map.setTerrain({ source: DEM_SOURCE, exaggeration: 1.1 }); } catch (_) {}

    updateTerrainColoring(map, opts);
}

/**
 * Re-apply just the colour ramp (hypsometric vs TAWS) — used when the planned
 * altitude slider moves or the TAWS toggle flips while terrain mode is on.
 */
export function updateTerrainColoring(map, opts = {}) {
    if (!map || !map.getLayer(COLOR_LAYER)) return;
    try {
        map.setPaintProperty(COLOR_LAYER, 'raster-color-range', colorRange(opts));
        map.setPaintProperty(COLOR_LAYER, 'raster-color', opts.tawsEnabled
            ? tawsRamp(Number(opts.altitudeFt) || 10000)
            : hypsometricRamp());
    } catch (_) { /* unsupported engine — hillshade fallback already shown */ }
}

/**
 * Turn the terrain overlay off.
 * @param {object} map
 * @param {{keepDemTerrain?:boolean}} opts  keepDemTerrain restores the Pro
 *        3D-terrain elevation (which shares the DEM source) instead of clearing it.
 */
export function removeTerrainMode(map, opts = {}) {
    if (!map) return;
    if (map.getLayer(COLOR_LAYER)) map.removeLayer(COLOR_LAYER);
    if (map.getLayer(HILLSHADE_LAYER)) map.removeLayer(HILLSHADE_LAYER);
    // Leave the shared DEM source in place; only drop our private RGB source.
    if (map.getSource(RGB_SOURCE)) {
        try { map.removeSource(RGB_SOURCE); } catch (_) {}
    }

    if (opts.keepDemTerrain) {
        try { map.setTerrain({ source: DEM_SOURCE, exaggeration: 1.5 }); } catch (_) {}
    } else {
        try { map.setTerrain(null); } catch (_) {}
    }
}
