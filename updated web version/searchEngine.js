/**
 * searchEngine.js
 *
 * Categorized global search over three live datasets:
 *   - Live flights  (from currentMapFeatures via window.getLiveFlightData)
 *   - Airports      (from airportsData; indexed once, refreshed on change)
 *   - Airlines      (derived dynamically from active liveryName values)
 *
 * Pure logic — no DOM. Consumers pass a query string and get back
 *   { flights: [...], airports: [...], airlines: [...] }
 * with each list pre-ranked and capped.
 */

const PER_CATEGORY_CAP = 5;

const norm = (s) => (s == null ? '' : String(s)).toLowerCase().trim();
const upper = (s) => (s == null ? '' : String(s)).toUpperCase();

// Rank: lower is better. Exact prefix wins, then word-prefix, then substring.
function rankMatch(haystack, needle) {
    const h = norm(haystack);
    const n = norm(needle);
    if (!h || !n) return Infinity;
    if (h === n) return 0;
    if (h.startsWith(n)) return 1;
    const wordPrefix = h.split(/[\s\-/]+/).some(w => w.startsWith(n));
    if (wordPrefix) return 2;
    const idx = h.indexOf(n);
    if (idx >= 0) return 3 + Math.min(idx / 50, 1);
    return Infinity;
}

function bestRank(fields, needle) {
    let best = Infinity;
    for (const f of fields) {
        const r = rankMatch(f, needle);
        if (r < best) best = r;
        if (best === 0) break;
    }
    return best;
}

let _airportIndex = null;
let _airportIndexSize = 0;

function buildAirportIndex(airportsData) {
    if (!airportsData) return [];
    const keys = Object.keys(airportsData);
    if (_airportIndex && _airportIndexSize === keys.length) return _airportIndex;

    const out = new Array(keys.length);
    for (let i = 0; i < keys.length; i++) {
        const icao = keys[i];
        const a = airportsData[icao];
        if (!a) continue;
        out[i] = {
            icao: icao.toUpperCase(),
            name: a.name || '',
            country: a.country || '',
            lat: a.lat,
            lon: a.lon,
        };
    }
    _airportIndex = out.filter(Boolean);
    _airportIndexSize = keys.length;
    return _airportIndex;
}

function searchFlights(query, flights) {
    const results = [];
    for (const f of flights) {
        const p = f.properties || {};
        let acData = p.aircraft;
        if (typeof acData === 'string') {
            try { acData = JSON.parse(acData); } catch { acData = {}; }
        }
        acData = acData || {};
        const callsign = p.callsign || '';
        const username = p.username || '';
        const reg = acData.registration || p.registration || '';
        const acName = acData.aircraftName || p.aircraftName || '';
        const livName = acData.liveryName || p.liveryName || '';

        const r = bestRank([callsign, username, reg, acName, livName], query);
        if (r !== Infinity) {
            results.push({ rank: r, feature: f, callsign, username, livName, acName });
        }
    }
    results.sort((a, b) => a.rank - b.rank);
    return results.slice(0, PER_CATEGORY_CAP);
}

function searchAirports(query, airportIndex) {
    const results = [];
    for (const a of airportIndex) {
        const r = bestRank([a.icao, a.name, a.country], query);
        if (r !== Infinity) results.push({ rank: r, airport: a });
    }
    // Tie-breaker: shorter ICAO first (favor real 4-letter codes), then name length.
    results.sort((a, b) => {
        if (a.rank !== b.rank) return a.rank - b.rank;
        const la = a.airport.icao.length, lb = b.airport.icao.length;
        if (la !== lb) return la - lb;
        return a.airport.name.length - b.airport.name.length;
    });
    return results.slice(0, PER_CATEGORY_CAP);
}

function searchAirlines(query, flights) {
    // Build a count map over active liveries.
    const tally = new Map();
    for (const f of flights) {
        const p = f.properties || {};
        let acData = p.aircraft;
        if (typeof acData === 'string') {
            try { acData = JSON.parse(acData); } catch { acData = {}; }
        }
        const liv = (acData && acData.liveryName) || p.liveryName;
        if (!liv) continue;
        const key = String(liv).trim();
        if (!key || /^generic$/i.test(key)) continue;
        tally.set(key, (tally.get(key) || 0) + 1);
    }

    const results = [];
    for (const [name, count] of tally) {
        const r = rankMatch(name, query);
        if (r !== Infinity) results.push({ rank: r, name, count });
    }
    // Tie-breaker: higher active fleet count first.
    results.sort((a, b) => {
        if (a.rank !== b.rank) return a.rank - b.rank;
        return b.count - a.count;
    });
    return results.slice(0, PER_CATEGORY_CAP);
}

/**
 * Run a categorized search.
 * @param {string} query
 * @param {Object} ctx
 * @param {Object} ctx.airportsData - keyed by ICAO
 * @param {Array}  ctx.flights      - GeoJSON features from currentMapFeatures
 * @returns {{flights: Array, airports: Array, airlines: Array, query: string}}
 */
export function runSearch(query, ctx) {
    const q = (query || '').trim();
    if (q.length < 2) return { flights: [], airports: [], airlines: [], query: q };

    const airportIndex = buildAirportIndex(ctx.airportsData || {});
    const flights = ctx.flights || [];

    return {
        query: q,
        flights: searchFlights(q, flights),
        airports: searchAirports(q, airportIndex),
        airlines: searchAirlines(q, flights),
    };
}

export function invalidateAirportIndex() {
    _airportIndex = null;
    _airportIndexSize = 0;
}

// Expose globally for non-module callers (flight.js uses window.* glue).
if (typeof window !== 'undefined') {
    window.GlobalSearchEngine = { runSearch, invalidateAirportIndex };
}
