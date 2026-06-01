// atcReplay.js
// Self-contained ATC session replay/playback. Reconstructs a single
// controller's session on the main mapbox-gl map: their facility location,
// a search-radius ring, the staffed-frequency timeline, and every flight that
// was inside their airspace during the window — each flight's full track drawn
// as an altitude-coloured polyline with the aircraft animated along it.
//
// Mirrors the conventions of flightReplay.js (injected styles, traffic-hiding,
// docked control panel, full teardown on close) so the two feel like siblings.
//
// Public API:
//   AtcReplay.open({ map, replayUrl, meta?, onClose? })
//   AtcReplay.close()
//   AtcReplay.isOpen()

const ATC_SPEED_OPTIONS = [1, 2, 5, 10, 30, 60, 120];

export const AtcReplay = (() => {
    // ---------- state ----------
    let map = null;
    let controller = null;          // controller object from the replay payload
    let flights = [];               // normalized flights: { ...meta, points: [] }
    let onCloseCallback = null;

    // Shared session timeline. Everything is animated against this single
    // clock so all aircraft move in lock-step the way they did live.
    let spanStart = 0;              // absolute Unix-ms of timeline t=0
    let totalDurationMs = 0;
    let currentMs = 0;              // elapsed ms into the timeline
    let speed = 1;
    let isPlaying = false;
    let isScrubbing = false;
    let lastTickWall = 0;
    let rafHandle = null;

    // map artifacts we own (and must tear down)
    let controllerMarker = null;
    let panelEl = null;
    let focusedFlightId = null;
    let isFollowing = false;        // camera follows the focused flight
    let currentMeta = {};           // caller-supplied {airportName, username}
    let flightRowEls = {};          // flightId -> list <div> (cached for animation)

    const SRC_RADIUS = 'atc-replay-radius-source';
    const LYR_RADIUS_FILL = 'atc-replay-radius-fill';
    const LYR_RADIUS_LINE = 'atc-replay-radius-line';
    const SRC_PATHS = 'atc-replay-paths-source';
    const LYR_PATHS = 'atc-replay-paths-layer';
    const SRC_PLANES = 'atc-replay-planes-source';
    const LYR_PLANES = 'atc-replay-planes-layer';
    const LYR_PLANE_LABELS = 'atc-replay-plane-labels';

    // Traffic-hiding (identical strategy to flightReplay): while the ATC
    // replay is up we blank every live aircraft so the historical picture
    // stands alone. We snapshot each layer's prior filter and restore it.
    let prevTrafficFilters = null;
    const TRAFFIC_LAYER_IDS = [
        'sector-ops-live-flights-layer',
        'sector-ops-live-flights-hover-layer',
        'sector-ops-live-flights-labels'
    ];
    const HIDE_ALL_FILTER = ['==', ['get', 'flightId'], '__none__'];

    // ---------- altitude colour ramp (shared look with flightReplay) ----------
    function getAltColor(alt) {
        const stops = [
            [0,     [56, 189, 248]],
            [10000, [45, 212, 191]],
            [20000, [163, 230, 53]],
            [30000, [250, 204, 21]],
            [40000, [244, 63, 94]]
        ];
        const clampAlt = Math.max(0, Math.min(40000, alt || 0));
        let s1 = stops[0], s2 = stops[stops.length - 1];
        for (let i = 0; i < stops.length - 1; i++) {
            if (clampAlt >= stops[i][0] && clampAlt <= stops[i + 1][0]) {
                s1 = stops[i]; s2 = stops[i + 1]; break;
            }
        }
        const range = s2[0] - s1[0];
        const f = range === 0 ? 0 : (clampAlt - s1[0]) / range;
        const r = Math.round(s1[1][0] + (s2[1][0] - s1[1][0]) * f);
        const g = Math.round(s1[1][1] + (s2[1][1] - s1[1][1]) * f);
        const b = Math.round(s1[1][2] + (s2[1][2] - s1[1][2]) * f);
        return `rgb(${r}, ${g}, ${b})`;
    }

    // Best-effort aircraft → sprite-category mapping so the animated planes
    // reuse the same icon sheet the live map uses. The host (flight.js)
    // exposes getAircraftCategory globally; fall back to a sane default.
    function categoryFor(aircraftName) {
        if (typeof window.getAircraftCategory === 'function') {
            try { return window.getAircraftCategory(aircraftName); } catch (_) {}
        }
        return 'B737';
    }

    function atcTypeLabel(type) {
        // Frequencies arrive as human-readable strings already, but guard for
        // the numeric form just in case.
        const map = {
            0: 'Ground', 1: 'Tower', 2: 'Unicom', 3: 'Clearance',
            4: 'Approach', 5: 'Departure', 6: 'Center', 7: 'ATIS'
        };
        return (typeof type === 'number') ? (map[type] || 'Unknown') : (type || '—');
    }

    // ---------- geometry ----------
    // Polygon approximating a circle of radiusNm around [lon,lat]. 1nm of
    // latitude ≈ 1/60°; longitude is corrected by cos(lat).
    function circlePolygon(lon, lat, radiusNm, points = 128) {
        const coords = [];
        const latRad = lat * Math.PI / 180;
        const dLat = radiusNm / 60;
        const dLon = radiusNm / (60 * Math.max(0.01, Math.cos(latRad)));
        for (let i = 0; i <= points; i++) {
            const theta = (i / points) * 2 * Math.PI;
            coords.push([lon + dLon * Math.cos(theta), lat + dLat * Math.sin(theta)]);
        }
        return { type: 'Feature', geometry: { type: 'Polygon', coordinates: [coords] }, properties: {} };
    }

    // ---------- data normalization ----------
    function normalizePath(raw) {
        const norm = (raw || []).map(p => {
            if (!p || typeof p !== 'object') return null;
            const lat = num(p.lat, p.latitude);
            const lon = num(p.lon, p.longitude);
            const altitude = num(p.alt, p.altitude, p.alt_ft);
            const groundSpeed = num(p.gs, p.groundSpeed, p.gs_kt);
            const track = num(p.hdg, p.heading, p.track, p.heading_deg);
            const t = num(p.time, p.timeMs, p.lastReportMs);
            if (typeof lat !== 'number' || typeof lon !== 'number' || typeof t !== 'number') return null;
            return { lat, lon, altitude, groundSpeed, track, t };
        }).filter(Boolean);
        norm.sort((a, b) => a.t - b.t);
        // de-dupe identical timestamps
        const out = [];
        for (const p of norm) {
            if (!out.length || p.t !== out[out.length - 1].t) out.push(p);
        }
        return out;
    }

    function num(...candidates) {
        for (const v of candidates) if (typeof v === 'number' && !isNaN(v)) return v;
        return null;
    }

    // interpolate a flight's position at absolute time absT, or null if absT
    // falls outside the flight's recorded track.
    function positionAt(points, absT) {
        if (!points || !points.length) return null;
        if (absT < points[0].t || absT > points[points.length - 1].t) return null;
        if (absT === points[0].t) return { ...points[0] };

        let lo = 0, hi = points.length - 1;
        while (lo + 1 < hi) {
            const mid = (lo + hi) >> 1;
            if (points[mid].t <= absT) lo = mid; else hi = mid;
        }
        const a = points[lo], b = points[hi];
        const span = b.t - a.t || 1;
        const f = (absT - a.t) / span;

        let track = a.track;
        if (typeof a.track === 'number' && typeof b.track === 'number') {
            let delta = b.track - a.track;
            if (delta > 180) delta -= 360; else if (delta < -180) delta += 360;
            track = (a.track + delta * f + 360) % 360;
        } else if (typeof b.track === 'number') {
            track = b.track;
        }
        const lerp = (x, y) => (typeof x === 'number' && typeof y === 'number') ? x + (y - x) * f : (typeof y === 'number' ? y : x);
        return {
            lat: a.lat + (b.lat - a.lat) * f,
            lon: a.lon + (b.lon - a.lon) * f,
            altitude: lerp(a.altitude, b.altitude),
            groundSpeed: lerp(a.groundSpeed, b.groundSpeed),
            track,
            t: absT
        };
    }

    // ---------- styles ----------
    function injectStyles() {
        if (document.getElementById('atc-replay-styles')) return;
        const style = document.createElement('style');
        style.id = 'atc-replay-styles';
        style.textContent = `
            #atc-replay-panel {
                position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%);
                width: min(820px, calc(100vw - 32px));
                background: rgba(24, 26, 32, 0.94);
                border: 1px solid rgba(120, 170, 255, 0.22);
                border-radius: 16px;
                backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px);
                box-shadow: 0 20px 60px rgba(0,0,0,0.6), 0 0 40px rgba(80,140,255,0.08);
                color: #fff; font-family: 'Inter', system-ui, -apple-system, sans-serif;
                z-index: 9000; padding: 14px 18px 12px;
                display: flex; flex-direction: column; gap: 10px;
                animation: atc-replay-slide-up 220ms ease-out;
            }
            @keyframes atc-replay-slide-up {
                from { transform: translate(-50%, 24px); opacity: 0; }
                to   { transform: translate(-50%, 0);    opacity: 1; }
            }
            #atc-replay-panel .atcr-header { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
            #atc-replay-panel .atcr-title { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 13px; min-width: 0; }
            #atc-replay-panel .atcr-title i { color: #7dd3fc; font-size: 14px; }
            #atc-replay-panel .atcr-apt { font-family: 'JetBrains Mono', ui-monospace, monospace; color: #fff; }
            #atc-replay-panel .atcr-ctrl { color: #9aa0a6; font-size: 11px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            #atc-replay-panel .atcr-close {
                background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.12);
                color: #e8eaed; width: 28px; height: 28px; border-radius: 50%; cursor: pointer;
                display: grid; place-items: center; transition: all .15s ease; flex-shrink: 0;
            }
            #atc-replay-panel .atcr-close:hover { background: rgba(255,255,255,0.15); color: #fff; }

            /* frequency timeline bars */
            #atc-replay-panel .atcr-freqs { display: flex; flex-direction: column; gap: 4px; }
            #atc-replay-panel .atcr-freq-row { display: flex; align-items: center; gap: 8px; }
            #atc-replay-panel .atcr-freq-label { width: 78px; flex-shrink: 0; font-size: 10px; font-weight: 700; letter-spacing: .4px; color: #cbd5e1; text-align: right; }
            #atc-replay-panel .atcr-freq-track { position: relative; flex: 1; height: 10px; background: rgba(255,255,255,0.06); border-radius: 5px; overflow: hidden; }
            #atc-replay-panel .atcr-freq-bar { position: absolute; top: 0; bottom: 0; background: linear-gradient(90deg, #38bdf8, #6366f1); border-radius: 5px; }
            #atc-replay-panel .atcr-freq-bar.open { background: linear-gradient(90deg, #4ade80, #22d3ee); }

            #atc-replay-panel .atcr-hud { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
            #atc-replay-panel .atcr-stat { display: flex; flex-direction: column; align-items: center; gap: 2px; padding: 6px 4px; background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; }
            #atc-replay-panel .atcr-stat label { font-size: 9px; font-weight: 700; letter-spacing: .8px; color: #9aa0a6; }
            #atc-replay-panel .atcr-stat span { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 15px; font-weight: 700; color: #fff; line-height: 1; }
            #atc-replay-panel .atcr-stat small { font-size: 9px; color: #9aa0a6; font-weight: 600; }

            #atc-replay-panel .atcr-controls { display: flex; align-items: center; gap: 10px; }
            #atc-replay-panel .atcr-btn {
                background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.2); color: #fff;
                width: 34px; height: 34px; border-radius: 50%; cursor: pointer; display: grid; place-items: center;
                transition: all .15s ease; flex-shrink: 0;
            }
            #atc-replay-panel .atcr-btn:hover { background: rgba(255,255,255,0.15); transform: scale(1.05); }
            #atc-replay-panel .atcr-play { background: #fff; color: #181a20; width: 38px; height: 38px; border-color: #fff; }
            #atc-replay-panel .atcr-play:hover { background: #e8eaed; }
            #atc-replay-panel .atcr-fit.active { background: #fff; color: #181a20; border-color: #fff; }
            #atc-replay-panel .atcr-time { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 11px; font-weight: 600; color: #e8eaed; min-width: 56px; text-align: center; }
            #atc-replay-panel .atcr-time-total { color: #9aa0a6; }
            #atc-replay-panel .atcr-scrubber {
                flex: 1; -webkit-appearance: none; appearance: none; height: 4px;
                background: rgba(255,255,255,0.15); border-radius: 4px; outline: none; cursor: pointer;
            }
            #atc-replay-panel .atcr-scrubber::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 14px; height: 14px; border-radius: 50%; background: #7dd3fc; box-shadow: 0 0 8px rgba(125,211,252,0.7); cursor: grab; }
            #atc-replay-panel .atcr-scrubber::-moz-range-thumb { width: 14px; height: 14px; border-radius: 50%; background: #7dd3fc; border: none; cursor: grab; }
            #atc-replay-panel .atcr-speed-wrap { display: flex; gap: 2px; background: rgba(0,0,0,0.3); border-radius: 8px; padding: 2px; flex-shrink: 0; }
            #atc-replay-panel .atcr-speed-btn { background: transparent; border: none; color: #9aa0a6; font-size: 10px; font-weight: 700; font-family: 'JetBrains Mono', ui-monospace, monospace; padding: 4px 6px; border-radius: 6px; cursor: pointer; min-width: 26px; transition: all .12s ease; }
            #atc-replay-panel .atcr-speed-btn:hover { color: #fff; }
            #atc-replay-panel .atcr-speed-btn.active { background: rgba(255,255,255,0.15); color: #fff; }

            /* flight list */
            #atc-replay-panel .atcr-flights { max-height: 132px; overflow-y: auto; display: flex; flex-direction: column; gap: 4px; padding-right: 2px; }
            #atc-replay-panel .atcr-flight { display: flex; align-items: center; gap: 10px; padding: 6px 10px; border-radius: 8px; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06); cursor: pointer; transition: all .12s ease; }
            #atc-replay-panel .atcr-flight:hover { background: rgba(255,255,255,0.08); }
            #atc-replay-panel .atcr-flight.focused { border-color: #7dd3fc; background: rgba(125,211,252,0.1); }
            #atc-replay-panel .atcr-flight.airport { border-left: 3px solid #4ade80; }
            #atc-replay-panel .atcr-flight.inactive { opacity: 0.4; }
            #atc-replay-panel .atcr-flight .fl-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; box-shadow: 0 0 6px currentColor; }
            #atc-replay-panel .atcr-flight .fl-cs { font-family: 'JetBrains Mono', ui-monospace, monospace; font-weight: 700; font-size: 12px; color: #fff; min-width: 64px; }
            #atc-replay-panel .atcr-flight .fl-ac { font-size: 11px; color: #94a3b8; flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            #atc-replay-panel .atcr-flight .fl-nm { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 10px; color: #cbd5e1; white-space: nowrap; }
            #atc-replay-panel .atcr-flight .fl-badge { font-size: 8px; font-weight: 800; letter-spacing: .5px; color: #4ade80; border: 1px solid #4ade80; border-radius: 3px; padding: 0 3px; }
            #atc-replay-panel .atcr-section-label { font-size: 10px; font-weight: 700; letter-spacing: .6px; color: #64748b; text-transform: uppercase; }

            /* controller marker */
            .atc-replay-controller-marker { pointer-events: none; display: grid; place-items: center; }
            .atc-replay-controller-marker .ctrl-ring { position: absolute; width: 40px; height: 40px; border-radius: 50%; background: rgba(99,102,241,0.25); animation: atc-ctrl-pulse 2s ease-out infinite; }
            .atc-replay-controller-marker .ctrl-core { position: relative; width: 30px; height: 30px; border-radius: 50%; background: linear-gradient(135deg, #6366f1, #38bdf8); display: grid; place-items: center; color: #fff; font-size: 14px; box-shadow: 0 2px 10px rgba(0,0,0,0.5); border: 2px solid rgba(255,255,255,0.85); }
            @keyframes atc-ctrl-pulse { 0% { transform: scale(0.6); opacity: 0.8; } 100% { transform: scale(2.2); opacity: 0; } }

            .atc-replay-toast { position: fixed; top: 24px; left: 50%; transform: translateX(-50%); background: rgba(24,26,32,0.95); border: 1px solid rgba(255,255,255,0.2); color: #fff; padding: 10px 18px; border-radius: 10px; font-family: 'Inter', sans-serif; font-size: 13px; font-weight: 600; z-index: 9001; box-shadow: 0 10px 30px rgba(0,0,0,0.5); transition: opacity .4s ease, transform .4s ease; }
            .atc-replay-toast.fade-out { opacity: 0; transform: translate(-50%, -8px); }

            @media (max-width: 640px) {
                #atc-replay-panel { left: 8px; right: 8px; bottom: calc(8px + env(safe-area-inset-bottom, 0px)); transform: none; width: auto; padding: 10px 12px; gap: 8px; border-radius: 14px; animation: none; }
                #atc-replay-panel .atcr-ctrl { display: none; }
                #atc-replay-panel .atcr-freq-label { width: 60px; font-size: 9px; }
                #atc-replay-panel .atcr-flights { max-height: 96px; }
                #atc-replay-panel .atcr-hud { gap: 6px; }
                #atc-replay-panel .atcr-stat span { font-size: 13px; }
                #atc-replay-panel .atcr-speed-btn { font-size: 9px; padding: 3px 4px; min-width: 20px; }
            }
        `;
        document.head.appendChild(style);
    }

    // ---------- traffic hiding ----------
    function hideLiveTraffic() {
        if (!map) return;
        if (!prevTrafficFilters) {
            prevTrafficFilters = {};
            TRAFFIC_LAYER_IDS.forEach(id => {
                if (!map.getLayer || !map.getLayer(id)) return;
                try { prevTrafficFilters[id] = map.getFilter(id) || null; } catch (_) { prevTrafficFilters[id] = null; }
            });
        }
        TRAFFIC_LAYER_IDS.forEach(id => {
            if (!map.getLayer || !map.getLayer(id)) return;
            try { map.setFilter(id, HIDE_ALL_FILTER); } catch (_) {}
        });
    }
    function restoreLiveTraffic() {
        if (!map || !prevTrafficFilters) return;
        TRAFFIC_LAYER_IDS.forEach(id => {
            if (!map.getLayer || !map.getLayer(id)) return;
            try { map.setFilter(id, prevTrafficFilters[id] || null); } catch (_) {}
        });
        prevTrafficFilters = null;
    }

    // ---------- map layers ----------
    function ensureLayers() {
        if (!map) return;

        // Radius ring (skip if controller has no location)
        if (controller && typeof controller.lat === 'number' && typeof controller.lon === 'number') {
            const circle = circlePolygon(controller.lon, controller.lat, controller.searchRadiusNm || 30);
            if (!map.getSource(SRC_RADIUS)) {
                map.addSource(SRC_RADIUS, { type: 'geojson', data: circle });
            } else {
                map.getSource(SRC_RADIUS).setData(circle);
            }
            if (!map.getLayer(LYR_RADIUS_FILL)) {
                map.addLayer({ id: LYR_RADIUS_FILL, type: 'fill', source: SRC_RADIUS, paint: { 'fill-color': '#6366f1', 'fill-opacity': 0.06 } });
            }
            if (!map.getLayer(LYR_RADIUS_LINE)) {
                map.addLayer({ id: LYR_RADIUS_LINE, type: 'line', source: SRC_RADIUS, paint: { 'line-color': '#818cf8', 'line-width': 1.5, 'line-dasharray': [3, 3], 'line-opacity': 0.7 } });
            }
        }

        // Static full flight paths (drawn once)
        if (!map.getSource(SRC_PATHS)) {
            map.addSource(SRC_PATHS, { type: 'geojson', data: buildPathFeatures() });
        } else {
            map.getSource(SRC_PATHS).setData(buildPathFeatures());
        }
        if (!map.getLayer(LYR_PATHS)) {
            map.addLayer({
                id: LYR_PATHS, type: 'line', source: SRC_PATHS,
                layout: { 'line-cap': 'round', 'line-join': 'round' },
                paint: {
                    'line-color': ['get', 'color'],
                    'line-width': ['case', ['boolean', ['get', 'focused'], false], 4.5, 2.5],
                    'line-opacity': ['case', ['boolean', ['get', 'dim'], false], 0.18, 0.9]
                }
            });
        }

        // Animated aircraft positions
        if (!map.getSource(SRC_PLANES)) {
            map.addSource(SRC_PLANES, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
        }
        if (!map.getLayer(LYR_PLANES)) {
            map.addLayer({
                id: LYR_PLANES, type: 'symbol', source: SRC_PLANES,
                layout: {
                    'icon-image': ['concat', 'icon-', ['coalesce', ['get', 'category'], 'B737']],
                    'icon-rotate': ['get', 'heading'],
                    'icon-rotation-alignment': 'map',
                    'icon-allow-overlap': true,
                    'icon-ignore-placement': true,
                    'icon-size': (window.mapFilters?.planeIconSize || 0.16)
                },
                paint: { 'icon-color': ['coalesce', ['get', 'color'], '#ffffff'] }
            });
        }
        if (!map.getLayer(LYR_PLANE_LABELS)) {
            map.addLayer({
                id: LYR_PLANE_LABELS, type: 'symbol', source: SRC_PLANES,
                layout: {
                    'text-field': ['get', 'callsign'],
                    'text-font': ['Inter Regular', 'Arial Unicode MS Regular'],
                    'text-size': 10,
                    'text-offset': [0, 1.4],
                    'text-anchor': 'top',
                    'text-allow-overlap': false
                },
                paint: { 'text-color': '#ffffff', 'text-halo-color': 'rgba(0,0,0,0.8)', 'text-halo-width': 1.4 }
            });
        }

        // Controller facility marker
        if (controller && typeof controller.lat === 'number' && typeof controller.lon === 'number' && !controllerMarker) {
            const el = document.createElement('div');
            el.className = 'atc-replay-controller-marker';
            el.innerHTML = `<div class="ctrl-ring"></div><div class="ctrl-core"><i class="fa-solid fa-tower-broadcast"></i></div>`;
            controllerMarker = new mapboxgl.Marker({ element: el })
                .setLngLat([controller.lon, controller.lat])
                .addTo(map);
        }
    }

    // Build the static path FeatureCollection for all flights, segment-coloured
    // by altitude. The focused flight is drawn brighter; others dim when one is
    // focused.
    function buildPathFeatures() {
        const features = [];
        const anyFocused = !!focusedFlightId;
        for (const fl of flights) {
            const focused = fl.flightId === focusedFlightId;
            const dim = anyFocused && !focused;
            for (let i = 0; i < fl.points.length - 1; i++) {
                const p1 = fl.points[i], p2 = fl.points[i + 1];
                features.push({
                    type: 'Feature',
                    geometry: { type: 'LineString', coordinates: [[p1.lon, p1.lat], [p2.lon, p2.lat]] },
                    properties: { color: getAltColor(p1.altitude), focused, dim }
                });
            }
        }
        return { type: 'FeatureCollection', features };
    }

    // ---------- animation ----------
    function tick() {
        rafHandle = null;
        if (!isPlaying) return;
        const now = performance.now();
        const dt = now - lastTickWall;
        lastTickWall = now;
        currentMs = Math.min(totalDurationMs, currentMs + dt * speed);
        renderFrame();
        if (currentMs >= totalDurationMs) pause();
        else rafHandle = requestAnimationFrame(tick);
    }

    function renderFrame() {
        const absT = spanStart + currentMs;
        const features = [];
        let activeCount = 0;

        for (const fl of flights) {
            const pos = positionAt(fl.points, absT);
            const listEl = flightRowEls[fl.flightId];
            if (!pos) {
                if (listEl) listEl.classList.add('inactive');
                continue;
            }
            activeCount++;
            if (listEl) listEl.classList.remove('inactive');
            features.push({
                type: 'Feature',
                geometry: { type: 'Point', coordinates: [pos.lon, pos.lat] },
                properties: {
                    category: fl.category,
                    heading: pos.track || 0,
                    callsign: fl.callsign,
                    color: getAltColor(pos.altitude),
                    flightId: fl.flightId
                }
            });
        }

        if (map && map.getSource(SRC_PLANES)) {
            map.getSource(SRC_PLANES).setData({ type: 'FeatureCollection', features });
        }

        // follow focused flight if "fit/follow" is engaged
        if (isFollowing && focusedFlightId && map) {
            const fl = flights.find(f => f.flightId === focusedFlightId);
            const pos = fl && positionAt(fl.points, absT);
            if (pos) map.jumpTo({ center: [pos.lon, pos.lat] });
        }

        updateHUD(activeCount);
        if (!isScrubbing) updateScrubber();
    }

    // ---------- formatting ----------
    function fmtZulu(epochMs) {
        const d = new Date(epochMs);
        const p = (n) => String(n).padStart(2, '0');
        return `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}Z`;
    }
    function fmtClock(ms) {
        const s = Math.max(0, Math.floor(ms / 1000));
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
        const pad = (n) => String(n).padStart(2, '0');
        return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
    }

    // ---------- panel ----------
    function buildPanel() {
        if (panelEl) return panelEl;
        panelEl = document.createElement('div');
        panelEl.id = 'atc-replay-panel';

        const apt = (controller && controller.airportName) || (currentMeta.airportName) || '----';
        const user = (controller && controller.username) || currentMeta.username || 'Controller';
        const radius = (controller && controller.searchRadiusNm) || '--';
        const freqList = (controller && controller.frequencies) || [];

        // frequency timeline rows (relative to the session window)
        const winStart = controller?.window?.start ?? spanStart;
        const winEnd = controller?.window?.end ?? (spanStart + totalDurationMs);
        const winSpan = Math.max(1, winEnd - winStart);
        const freqRows = freqList.map(f => {
            const label = atcTypeLabel(f.type);
            const fs = Math.max(winStart, f.start ?? winStart);
            const fe = Math.min(winEnd, (f.open ? winEnd : (f.end ?? winEnd)));
            const left = ((fs - winStart) / winSpan) * 100;
            const width = Math.max(2, ((fe - fs) / winSpan) * 100);
            return `<div class="atcr-freq-row">
                <span class="atcr-freq-label">${label}</span>
                <span class="atcr-freq-track"><span class="atcr-freq-bar${f.open ? ' open' : ''}" style="left:${left}%;width:${width}%;"></span></span>
            </div>`;
        }).join('');

        // flight list
        const flightRows = flights.map(fl => {
            const nm = (typeof fl.closestNm === 'number') ? `${fl.closestNm.toFixed(1)}nm` : '';
            const acLabel = [fl.aircraftName, fl.liveryName].filter(Boolean).join(' · ') || '—';
            const dotColor = getAltColor(fl.points[0]?.altitude || 0);
            return `<div class="atcr-flight${fl.atAirport ? ' airport' : ''}" data-fid="${fl.flightId}">
                <span class="fl-dot" style="color:${dotColor};background:${dotColor};"></span>
                <span class="fl-cs">${fl.callsign || '----'}</span>
                <span class="fl-ac">${acLabel}</span>
                ${fl.atAirport ? '<span class="fl-badge">FIELD</span>' : ''}
                <span class="fl-nm">${nm}</span>
            </div>`;
        }).join('');

        panelEl.innerHTML = `
            <div class="atcr-header">
                <div class="atcr-title">
                    <i class="fa-solid fa-headset"></i>
                    <span class="atcr-apt">${apt}</span>
                    <span class="atcr-ctrl">${user}${radius !== '--' ? ` · ${radius}nm radius` : ''}</span>
                </div>
                <button class="atcr-close" title="Close ATC Replay"><i class="fa-solid fa-xmark"></i></button>
            </div>

            ${freqRows ? `<div class="atcr-freqs">${freqRows}</div>` : ''}

            <div class="atcr-hud">
                <div class="atcr-stat"><label>UTC</label><span data-hud="utc">--:--:--</span><small>z</small></div>
                <div class="atcr-stat"><label>AIRBORNE</label><span data-hud="active">0</span><small>in airspace</small></div>
                <div class="atcr-stat"><label>FLIGHTS</label><span data-hud="total">${flights.length}</span><small>total</small></div>
                <div class="atcr-stat"><label>FIELD OPS</label><span data-hud="field">${flights.filter(f => f.atAirport).length}</span><small>arr/dep</small></div>
            </div>

            <div class="atcr-controls">
                <button class="atcr-btn atcr-restart" title="Restart"><i class="fa-solid fa-backward-step"></i></button>
                <button class="atcr-btn atcr-play" title="Play / Pause"><i class="fa-solid fa-play"></i></button>
                <button class="atcr-btn atcr-fit" title="Fit airspace / follow focused flight"><i class="fa-solid fa-expand"></i></button>
                <div class="atcr-time" data-hud="elapsed">0:00</div>
                <input type="range" class="atcr-scrubber" min="0" max="1000" value="0" step="1">
                <div class="atcr-time atcr-time-total">${fmtClock(totalDurationMs)}</div>
                <div class="atcr-speed-wrap">
                    ${ATC_SPEED_OPTIONS.map(s => `<button class="atcr-speed-btn${s === 1 ? ' active' : ''}" data-speed="${s}">${s}×</button>`).join('')}
                </div>
            </div>

            ${flightRows ? `<div class="atcr-section-label">Flights in airspace (nearest first)</div><div class="atcr-flights">${flightRows}</div>` : '<div class="atcr-section-label">No flights recorded in this airspace window.</div>'}
        `;
        document.body.appendChild(panelEl);
        bindPanelEvents();
        return panelEl;
    }

    function bindPanelEvents() {
        panelEl.querySelector('.atcr-close').addEventListener('click', () => close());
        panelEl.querySelector('.atcr-play').addEventListener('click', () => { isPlaying ? pause() : play(); });
        panelEl.querySelector('.atcr-restart').addEventListener('click', () => { currentMs = 0; renderFrame(); });

        const fitBtn = panelEl.querySelector('.atcr-fit');
        fitBtn.addEventListener('click', () => {
            if (focusedFlightId) {
                // toggle follow mode on the focused flight
                isFollowing = !isFollowing;
                fitBtn.classList.toggle('active', isFollowing);
                if (isFollowing) renderFrame();
            } else {
                fitToAirspace();
            }
        });

        const slider = panelEl.querySelector('.atcr-scrubber');
        slider.addEventListener('pointerdown', () => { isScrubbing = true; });
        const endScrub = () => { isScrubbing = false; };
        slider.addEventListener('pointerup', endScrub);
        slider.addEventListener('pointercancel', endScrub);
        slider.addEventListener('input', (e) => {
            currentMs = Math.max(0, Math.min(totalDurationMs, (Number(e.target.value) / 1000) * totalDurationMs));
            renderFrame();
        });

        panelEl.querySelectorAll('.atcr-speed-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                speed = Number(btn.dataset.speed);
                panelEl.querySelectorAll('.atcr-speed-btn').forEach(b => b.classList.toggle('active', b === btn));
            });
        });

        // flight list → focus a flight (highlight its path, dim the rest)
        flightRowEls = {};
        panelEl.querySelectorAll('.atcr-flight').forEach(row => {
            flightRowEls[row.dataset.fid] = row;
            row.addEventListener('click', () => {
                const fid = row.dataset.fid;
                if (focusedFlightId === fid) {
                    focusedFlightId = null;
                    isFollowing = false;
                    panelEl.querySelector('.atcr-fit')?.classList.remove('active');
                } else {
                    focusedFlightId = fid;
                }
                panelEl.querySelectorAll('.atcr-flight').forEach(r => r.classList.toggle('focused', r.dataset.fid === focusedFlightId));
                if (map && map.getSource(SRC_PATHS)) map.getSource(SRC_PATHS).setData(buildPathFeatures());
                // pan to the focused flight's current (or first) position
                const fl = flights.find(f => f.flightId === focusedFlightId);
                if (fl && map) {
                    const pos = positionAt(fl.points, spanStart + currentMs) || fl.points[0];
                    if (pos) map.easeTo({ center: [pos.lon, pos.lat], zoom: Math.max(map.getZoom(), 8), duration: 600 });
                }
            });
        });
    }

    function updateHUD(activeCount) {
        if (!panelEl) return;
        const set = (sel, val) => { const el = panelEl.querySelector(sel); if (el) el.textContent = val; };
        set('[data-hud="utc"]', fmtZulu(spanStart + currentMs));
        set('[data-hud="active"]', String(activeCount));
        set('[data-hud="elapsed"]', fmtClock(currentMs));
    }
    function updateScrubber() {
        if (!panelEl) return;
        const ratio = totalDurationMs > 0 ? currentMs / totalDurationMs : 0;
        const s = panelEl.querySelector('.atcr-scrubber');
        if (s) s.value = String(Math.round(ratio * 1000));
    }
    function setPlayIcon() {
        const ic = panelEl && panelEl.querySelector('.atcr-play i');
        if (ic) ic.className = isPlaying ? 'fa-solid fa-pause' : 'fa-solid fa-play';
    }

    function fitToAirspace() {
        if (!map) return;
        try {
            const b = new mapboxgl.LngLatBounds();
            let has = false;
            if (controller && typeof controller.lat === 'number' && typeof controller.lon === 'number') {
                b.extend([controller.lon, controller.lat]); has = true;
            }
            for (const fl of flights) for (const p of fl.points) { b.extend([p.lon, p.lat]); has = true; }
            if (has) map.fitBounds(b, { padding: 80, maxZoom: 11, duration: 800 });
        } catch (_) {}
    }

    // ---------- public ----------
    function play() {
        if (currentMs >= totalDurationMs) currentMs = 0;
        isPlaying = true;
        lastTickWall = performance.now();
        setPlayIcon();
        if (!rafHandle) rafHandle = requestAnimationFrame(tick);
    }
    function pause() {
        isPlaying = false;
        if (rafHandle) { cancelAnimationFrame(rafHandle); rafHandle = null; }
        setPlayIcon();
    }

    function showToast(msg) {
        const t = document.createElement('div');
        t.className = 'atc-replay-toast';
        t.textContent = msg;
        document.body.appendChild(t);
        setTimeout(() => t.classList.add('fade-out'), 2400);
        setTimeout(() => t.remove(), 3000);
    }

    function close() {
        pause();
        restoreLiveTraffic();
        if (map) {
            [LYR_PLANE_LABELS, LYR_PLANES, LYR_PATHS, LYR_RADIUS_LINE, LYR_RADIUS_FILL].forEach(id => {
                if (map.getLayer && map.getLayer(id)) { try { map.removeLayer(id); } catch (_) {} }
            });
            [SRC_PLANES, SRC_PATHS, SRC_RADIUS].forEach(id => {
                if (map.getSource && map.getSource(id)) { try { map.removeSource(id); } catch (_) {} }
            });
        }
        if (controllerMarker) { try { controllerMarker.remove(); } catch (_) {} controllerMarker = null; }
        if (panelEl) { panelEl.remove(); panelEl = null; }

        controller = null; flights = []; currentMeta = {}; flightRowEls = {};
        spanStart = 0; totalDurationMs = 0; currentMs = 0; speed = 1;
        isScrubbing = false; focusedFlightId = null; isFollowing = false;

        const cb = onCloseCallback; onCloseCallback = null;
        if (typeof cb === 'function') { try { cb(); } catch (e) { console.warn('[AtcReplay] onClose threw:', e); } }
    }

    async function open(opts) {
        if (!opts || !opts.map || !opts.replayUrl) {
            showToast('ATC Replay error: missing map or session.');
            return false;
        }
        close();
        injectStyles();
        map = opts.map;
        currentMeta = opts.meta || {};
        onCloseCallback = (typeof opts.onClose === 'function') ? opts.onClose : null;

        let payload = null;
        try {
            const res = await fetch(opts.replayUrl);
            if (res.status === 404) { showToast('This ATC session has expired (data is kept 48h).'); close(); return false; }
            payload = res.ok ? await res.json() : null;
        } catch (e) {
            console.warn('[AtcReplay] fetch failed:', e);
        }
        if (!payload || !payload.ok || !payload.controller) {
            showToast('Could not load ATC session.');
            close();
            return false;
        }

        controller = payload.controller;
        flights = (payload.flights || []).map(f => {
            const ac = f.aircraft || {};
            return {
                flightId: f.flightId,
                callsign: f.callsign || '----',
                aircraftName: ac.aircraftName || '',
                liveryName: ac.liveryName || '',
                category: categoryFor(ac.aircraftName),
                closestNm: f.closestNm,
                atAirport: !!f.atAirport,
                points: normalizePath(f.path)
            };
        }).filter(f => f.points.length >= 1);

        // Build the shared timeline. Prefer the controller window; widen it to
        // cover any path points that fall outside (the backend pads the scan).
        const win = controller.window || {};
        let start = (typeof win.start === 'number') ? win.start : Infinity;
        let end = (typeof win.end === 'number') ? win.end : -Infinity;
        for (const fl of flights) {
            if (fl.points.length) {
                start = Math.min(start, fl.points[0].t);
                end = Math.max(end, fl.points[fl.points.length - 1].t);
            }
        }
        if (!isFinite(start) || !isFinite(end) || end <= start) {
            showToast('No replayable track data in this session window.');
            close();
            return false;
        }
        spanStart = start;
        totalDurationMs = end - start;
        currentMs = 0;

        buildPanel();

        const setup = () => {
            ensureLayers();
            hideLiveTraffic();
            fitToAirspace();
            renderFrame();
            play();
        };
        if (map.isStyleLoaded && !map.isStyleLoaded()) map.once('idle', setup);
        else setup();
        return true;
    }

    return { open, close, isOpen: () => !!panelEl };
})();
