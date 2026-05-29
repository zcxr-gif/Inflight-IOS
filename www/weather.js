// weather.js
//
// Aviation weather service. Aggregates several FREE, key-less data sources:
//   • VATSIM METAR        - https://metar.vatsim.net          (live METAR text)
//   • NOAA Aviation Wx    - https://aviationweather.gov/api   (TAF, etc.)
//   • Open-Meteo          - https://api.open-meteo.com        (surface + winds aloft)
//   • NWS / weather.gov   - https://api.weather.gov           (US alerts)
//
// None of these require an API key.

/**
 * Parses a raw METAR string into a more readable object.
 * @param {string} metarString - The raw METAR data.
 * @returns {object} An object containing parsed wind, temperature, and condition.
 */
const parseMetar = (metarString) => {
    if (!metarString || typeof metarString !== 'string') {
        return { wind: '---', temp: '---', condition: '---', raw: 'Not Available' };
    }
    const parts = metarString.split(' ');
    const wind = parts.find(p => p.endsWith('KT'));
    const tempMatch = metarString.match(/M?\d{2}\/M?\d{2}/);
    const temp = tempMatch ? `${tempMatch[0].split('/')[0].replace('M', '-')}°C` : '---';
    const condition = parts.filter(p => /^(FEW|SCT|BKN|OVC|SKC|CLR|NSC)/.test(p)).join(' ');
    return {
        wind: wind || '---',
        temp: temp || '---',
        condition: condition || '---',
        raw: metarString
    };
};

/**
 * Fetches and parses the latest METAR for a given airport ICAO from the VATSIM network.
 * @param {string} icao - The ICAO code of the airport (e.g., "KJFK").
 * @returns {Promise<object>} A promise that resolves to the parsed weather object.
 */
const fetchAndParseMetar = async (icao) => {
    if (!icao || icao.length < 3) {
        return parseMetar(null); // Return default empty object if ICAO is invalid
    }
    try {
        const response = await fetch(`https://metar.vatsim.net/metar.php?id=${icao}`);
        if (!response.ok) {
            throw new Error('Weather data not available for this location.');
        }
        const rawMetar = await response.text();
        return parseMetar(rawMetar);
    } catch (error) {
        console.error(`Failed to fetch METAR for ${icao}:`, error);
        return parseMetar(null); // Return default on error
    }
};

/**
 * Fetches the latest TAF (Terminal Aerodrome Forecast) for an airport from the
 * NOAA Aviation Weather Center. No API key required.
 * @param {string} icao - The ICAO code of the airport (e.g., "KJFK").
 * @returns {Promise<{raw: string, lines: string[], available: boolean}>}
 */
const fetchTaf = async (icao) => {
    const empty = { raw: 'Not Available', lines: [], available: false };
    if (!icao || icao.length < 3) return empty;
    try {
        const url = `https://aviationweather.gov/api/data/taf?ids=${encodeURIComponent(icao)}&format=raw`;
        const response = await fetch(url);
        if (!response.ok) throw new Error('TAF request failed.');
        const raw = (await response.text()).trim();
        if (!raw) return empty;

        // Break the single-line TAF into readable forecast period lines.
        // Each period typically begins with FM / BECMG / TEMPO / PROB.
        const lines = raw
            .replace(/\s+(FM\d{6}|BECMG|TEMPO|PROB\d{2})/g, '\n$1')
            .split('\n')
            .map(l => l.trim())
            .filter(Boolean);

        return { raw, lines, available: true };
    } catch (error) {
        console.error(`Failed to fetch TAF for ${icao}:`, error);
        return empty;
    }
};

// Standard pressure levels available from Open-Meteo and their approximate
// pressure-altitude in feet (ISA). geopotential height from the API refines this.
const PRESSURE_LEVELS = [
    { hpa: 925, approxFt: 2500 },
    { hpa: 850, approxFt: 4800 },
    { hpa: 700, approxFt: 9900 },
    { hpa: 600, approxFt: 13800 },
    { hpa: 500, approxFt: 18300 },
    { hpa: 400, approxFt: 23600 },
    { hpa: 300, approxFt: 30100 },
    { hpa: 250, approxFt: 34000 },
    { hpa: 200, approxFt: 38700 },
    { hpa: 150, approxFt: 44600 }
];

/**
 * Fetches winds & temperatures aloft from Open-Meteo (global, key-less) for a
 * point, across standard pressure levels. Optionally selects the level nearest a
 * given aircraft altitude (useful for live cruise OAT/wind).
 *
 * @param {number} lat
 * @param {number} lon
 * @param {number} [altFt] - Aircraft altitude in feet, used to pick `nearest`.
 * @returns {Promise<{levels: Array, nearest: object|null, surface: object|null}>}
 */
const fetchWindsAloft = async (lat, lon, altFt) => {
    const result = { levels: [], nearest: null, surface: null };
    if (lat == null || lon == null) return result;

    const vars = [];
    PRESSURE_LEVELS.forEach(l => {
        vars.push(
            `temperature_${l.hpa}hPa`,
            `wind_speed_${l.hpa}hPa`,
            `wind_direction_${l.hpa}hPa`,
            `geopotential_height_${l.hpa}hPa`
        );
    });

    const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
        `&current=temperature_2m,wind_speed_10m,wind_direction_10m` +
        `&hourly=${vars.join(',')}` +
        `&wind_speed_unit=kn&forecast_days=1`;

    try {
        const response = await fetch(url);
        if (!response.ok) throw new Error('Open-Meteo winds-aloft request failed.');
        const data = await response.json();

        if (data.current) {
            result.surface = {
                tempC: data.current.temperature_2m,
                spdKts: Math.round(data.current.wind_speed_10m),
                dirDeg: data.current.wind_direction_10m
            };
        }

        const hourly = data.hourly;
        if (hourly && Array.isArray(hourly.time) && hourly.time.length) {
            // Pick the hour closest to "now".
            const now = Date.now();
            let idx = 0, best = Infinity;
            hourly.time.forEach((t, i) => {
                const diff = Math.abs(new Date(t).getTime() - now);
                if (diff < best) { best = diff; idx = i; }
            });

            PRESSURE_LEVELS.forEach(l => {
                const tempC = hourly[`temperature_${l.hpa}hPa`]?.[idx];
                const spdKts = hourly[`wind_speed_${l.hpa}hPa`]?.[idx];
                const dirDeg = hourly[`wind_direction_${l.hpa}hPa`]?.[idx];
                const gpm = hourly[`geopotential_height_${l.hpa}hPa`]?.[idx]; // metres
                if (tempC == null || spdKts == null || dirDeg == null) return;
                const altFtLevel = gpm != null ? Math.round(gpm * 3.28084) : l.approxFt;
                result.levels.push({
                    hpa: l.hpa,
                    altFt: altFtLevel,
                    fl: `FL${String(Math.round(altFtLevel / 100)).padStart(3, '0')}`,
                    tempC: Math.round(tempC),
                    spdKts: Math.round(spdKts),
                    dirDeg: Math.round(dirDeg)
                });
            });

            if (altFt != null && result.levels.length) {
                result.nearest = result.levels.reduce((a, b) =>
                    Math.abs(b.altFt - altFt) < Math.abs(a.altFt - altFt) ? b : a
                );
            }
        }
    } catch (error) {
        console.error('Failed to fetch winds aloft:', error);
    }
    return result;
};

/**
 * Fetches active NWS (US National Weather Service) alerts for a point.
 * No API key required. US coverage only; returns [] elsewhere or on error.
 * @param {number} lat
 * @param {number} lon
 * @returns {Promise<Array<{event:string, severity:string, headline:string, ends:string}>>}
 */
const fetchNwsAlerts = async (lat, lon) => {
    if (lat == null || lon == null) return [];
    try {
        const url = `https://api.weather.gov/alerts/active?point=${lat.toFixed(4)},${lon.toFixed(4)}`;
        const response = await fetch(url, { headers: { 'Accept': 'application/geo+json' } });
        if (!response.ok) return [];
        const data = await response.json();
        if (!data.features) return [];
        return data.features.map(f => ({
            event: f.properties?.event || 'Alert',
            severity: f.properties?.severity || 'Unknown',
            urgency: f.properties?.urgency || '',
            headline: f.properties?.headline || '',
            ends: f.properties?.ends || f.properties?.expires || ''
        }));
    } catch (error) {
        console.error('Failed to fetch NWS alerts:', error);
        return [];
    }
};

/**
 * Fetches ALL active NWS alerts as a GeoJSON FeatureCollection, for use as a
 * map overlay. Only alerts with geometry are returned.
 * @returns {Promise<object>} GeoJSON FeatureCollection (possibly empty).
 */
const fetchActiveAlertsGeoJSON = async () => {
    const empty = { type: 'FeatureCollection', features: [] };
    try {
        const response = await fetch('https://api.weather.gov/alerts/active', {
            headers: { 'Accept': 'application/geo+json' }
        });
        if (!response.ok) return empty;
        const data = await response.json();
        if (!data.features) return empty;
        // Keep only alerts that carry a polygon so they can be drawn.
        data.features = data.features.filter(f => f.geometry);
        return data;
    } catch (error) {
        console.error('Failed to fetch active alerts GeoJSON:', error);
        return empty;
    }
};

/**
 * Fetches active G-AIRMETs (Graphical AIRMETs: turbulence, icing, IFR, mountain
 * obscuration, surface winds, LLWS) from the NOAA Aviation Weather Center as a
 * GeoJSON FeatureCollection for the map overlay. No API key required.
 * @returns {Promise<object>} GeoJSON FeatureCollection (possibly empty).
 */
const fetchGAirmetGeoJSON = async () => {
    const empty = { type: 'FeatureCollection', features: [] };
    try {
        const response = await fetch('https://aviationweather.gov/api/data/gairmet?format=geojson');
        if (!response.ok) return empty;
        const data = await response.json();
        if (!data || !data.features) return empty;
        data.features = data.features.filter(f => f.geometry);
        return data;
    } catch (error) {
        console.error('Failed to fetch G-AIRMETs:', error);
        return empty;
    }
};

/**
 * Fetches recent PIREPs (pilot reports) from the NOAA Aviation Weather Center as
 * a GeoJSON FeatureCollection of points. No API key required.
 * @param {number} [ageHours=2] - How far back to look.
 * @returns {Promise<object>} GeoJSON FeatureCollection (possibly empty).
 */
const fetchPirepsGeoJSON = async (ageHours = 2) => {
    const empty = { type: 'FeatureCollection', features: [] };
    try {
        const response = await fetch(`https://aviationweather.gov/api/data/pirep?format=geojson&age=${ageHours}`);
        if (!response.ok) return empty;
        const data = await response.json();
        if (!data || !data.features) return empty;
        data.features = data.features.filter(f => f.geometry);
        return data;
    } catch (error) {
        console.error('Failed to fetch PIREPs:', error);
        return empty;
    }
};

/**
 * Fetches the NWS textual point forecast for a location (US only, no key).
 * Two-step: resolve the grid point, then read its forecast periods.
 * @param {number} lat
 * @param {number} lon
 * @returns {Promise<Array<{name:string, temp:string, wind:string, short:string, detailed:string}>>}
 */
const fetchPointForecast = async (lat, lon) => {
    if (lat == null || lon == null) return [];
    try {
        const ptRes = await fetch(`https://api.weather.gov/points/${lat.toFixed(4)},${lon.toFixed(4)}`, {
            headers: { 'Accept': 'application/geo+json' }
        });
        if (!ptRes.ok) return [];
        const pt = await ptRes.json();
        const forecastUrl = pt.properties?.forecast;
        if (!forecastUrl) return [];

        const fRes = await fetch(forecastUrl, { headers: { 'Accept': 'application/geo+json' } });
        if (!fRes.ok) return [];
        const f = await fRes.json();
        const periods = f.properties?.periods || [];
        return periods.slice(0, 6).map(p => ({
            name: p.name || '',
            temp: p.temperature != null ? `${p.temperature}°${p.temperatureUnit || 'F'}` : '--',
            wind: [p.windSpeed, p.windDirection].filter(Boolean).join(' '),
            short: p.shortForecast || '',
            detailed: p.detailedForecast || ''
        }));
    } catch (error) {
        console.error('Failed to fetch NWS point forecast:', error);
        return [];
    }
};

// Expose the service to be used by other scripts
window.WeatherService = {
    fetchAndParseMetar,
    parseMetar,
    fetchTaf,
    fetchWindsAloft,
    fetchNwsAlerts,
    fetchActiveAlertsGeoJSON,
    fetchGAirmetGeoJSON,
    fetchPirepsGeoJSON,
    fetchPointForecast
};
