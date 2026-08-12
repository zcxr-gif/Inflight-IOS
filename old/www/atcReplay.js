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

// Shared source of truth for "is this user signed in?" — the same binding the
// rest of the app gates its Pro controls on (see flight.js). Used by the 3D
// (free-look) Pro gate so a signed-in pilot is recognised on every platform.
import { ProfileUI } from './profileUI.js';

const ATC_SPEED_OPTIONS = [1, 2, 5, 10, 60, 240, 480];

// How the flown tracks are drawn. 'trails' fades a comet tail in behind each
// aircraft; 'full' draws every track end-to-end; 'off' hides them entirely.
const PATH_MODES = ['trails', 'full', 'off'];
const PATH_MODE_STORAGE_KEY = 'atcReplayPathMode';
// How much flown history (in session time) trails behind each plane. This is
// the default; the user can retune it live with the path-length slider (see
// trailWindowMs / TRAIL_WINDOW_STORAGE_KEY).
const TRAIL_WINDOW_MS = 120000;
// Slider bounds for the trail/path length, in session ms. The upper bound is
// clamped to the session duration at open() time so "max" shows the whole path.
const TRAIL_WINDOW_MIN_MS = 30000;          // 30s — a short, tight comet tail
let TRAIL_WINDOW_MAX_MS = 1800000;          // 30min ceiling (clamped per session)
const TRAIL_WINDOW_STORAGE_KEY = 'atcReplayTrailWindowMs';
// Fallback / minimum coverage radius when the controller payload omits one.
const DEFAULT_RADIUS_NM = 50;
// Loss-of-separation alert thresholds (airborne aircraft only).
const CONFLICT_NM = 3;
const CONFLICT_FT = 1000;

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
    // Smoothed cost (ms) of a single rendered frame. Drives the adaptive trail
    // budget below so a frame that's running hot automatically sheds trail detail
    // instead of piling up work until the iOS web view is watchdog-killed.
    let frameMsEMA = 16;

    // map artifacts we own (and must tear down)
    let panelEl = null;
    let focusedFlightId = null;
    let isFollowing = false;        // camera follows the focused flight
    let isFreeLook = false;         // detached camera: orbit / tilt / pan the traffic freely
    let preFreeLookCam = null;      // camera snapshot, restored when free-look exits
    let preFreeLookGestures = null; // gesture + max-pitch snapshot, restored on exit
    let three = null;               // Three.js 3D traffic layer state (dots + altitude stems)
    let currentMeta = {};           // caller-supplied {airportName, username, userId, apiBase}
    let flightRowEls = {};          // flightId -> list <div> (cached for animation)
    let pathMode = 'trails';        // how flown tracks are drawn (see PATH_MODES)
    let trailWindowMs = TRAIL_WINDOW_MS; // live trail/path length (slider-driven)
    let onProStatusChanged = null;  // live pro-status listener (free-look unlock)
    let enforcementCount = null;    // violations the controller issued (null = unknown)
    let freqWinStart = 0;           // abs-ms at the left edge of the freq timeline
    let freqWinSpan = 0;            // width of the freq timeline in ms
    let freqBars = [];              // cached freq bars (+parsed window) for the per-frame sweep
    let freqPlayheads = [];         // cached freq playhead nodes
    let isLooping = false;          // restart at the end instead of stopping
    let isCollapsed = false;        // panel collapsed to a slim playback bar
    const COLLAPSE_STORAGE_KEY = 'atcReplayCollapsed';
    let altBand = 'all';            // altitude-band display filter
    const ALT_BAND_STORAGE_KEY = 'atcReplayAltBand';
    let conflictIntervals = [];     // precomputed [{start,end}] (ms into timeline)
    let hoverPopup = null;          // map hover tooltip
    let onPlaneMove = null;

    // Altitude display bands (ft). 'all' clears the filter.
    const ALT_BANDS = { all: [0, 100000], low: [0, 10000], mid: [10000, 25000], high: [25000, 100000] };
    let onKeyDown = null;           // bound keyboard-shortcut handler
    let onPlaneClick = null, onPlaneEnter = null, onPlaneLeave = null; // map handlers

    const SRC_RADIUS = 'atc-replay-radius-source';
    const LYR_RADIUS_FILL = 'atc-replay-radius-fill';
    const LYR_RADIUS_LINE = 'atc-replay-radius-line';
    const SRC_PATHS = 'atc-replay-paths-source';
    const LYR_PATHS = 'atc-replay-paths-layer';
    const SRC_TRAILS = 'atc-replay-trails-source';
    const LYR_TRAILS = 'atc-replay-trails-layer';
    const SRC_PLANES = 'atc-replay-planes-source';
    const LYR_PLANES = 'atc-replay-planes-layer';
    const LYR_PLANE_LABELS = 'atc-replay-plane-labels';
    const LYR_CONFLICT = 'atc-replay-conflict-layer';
    const LYR_3D = 'atc-replay-3d';          // Three.js custom layer: elevated traffic dots

    // 3D traffic tuning. Dots are drawn at the aircraft's true altitude (in
    // metres) but exaggerated vertically so the stack reads in the tilted
    // free-look view; each dot trails a faint stem down to the ground.
    const MAX_3D_DOTS = 2000;
    const ALT_EXAGGERATION = 2.5;            // vertical scale for the dot/stem heights
    const DOT_SIZE_PX = 24;                  // on-screen dot size (constant, no attenuation)

    // Traffic-hiding (identical strategy to flightReplay): while the ATC
    // replay is up we blank every live aircraft so the historical picture
    // stands alone. We snapshot each layer's prior filter and restore it.
    let prevTrafficFilters = null;
    const TRAFFIC_LAYER_IDS = [
        'sector-ops-live-flights-layer',
        'sector-ops-live-flights-natural-layer',
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

    // Altitude colour snapped to ~1500ft bands. Continuous getAltColor() gives a
    // slightly different colour to every point, which would split a track into
    // one feature per segment (and re-introduce the round-cap blobs). Snapping
    // lets long stretches share a colour and merge into single smooth polylines,
    // while still reading as a gradient across climbs/descents.
    const ALT_BAND = 1500;
    function bandColor(alt) {
        return getAltColor(Math.round((alt || 0) / ALT_BAND) * ALT_BAND);
    }

    // Best-effort aircraft → sprite-category mapping so the animated planes
    // reuse the same icon sheet the live map uses. The host (flight.js)
    // exposes getAircraftCategory globally; fall back to a sane default.
    function categoryFor(aircraftName) {
        if (typeof window.getAircraftCategory === 'function') {
            try {
                const c = window.getAircraftCategory(aircraftName);
                // getAircraftCategory() returns 'default' for blank/unknown names,
                // but the sprite sheet has no 'icon-default' frame. Historical ATC
                // sessions frequently omit the aircraft name, so resolving to a real
                // sprite here keeps the plane visible — and stops Mapbox from
                // re-requesting the missing image on every frame (a leak that
                // eventually crashes the iOS web view).
                if (c && c !== 'default') return c;
            } catch (_) {}
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
    function circleRing(lon, lat, radiusNm, points = 128) {
        const coords = [];
        const latRad = lat * Math.PI / 180;
        const dLat = radiusNm / 60;
        const dLon = radiusNm / (60 * Math.max(0.01, Math.cos(latRad)));
        for (let i = 0; i <= points; i++) {
            const theta = (i / points) * 2 * Math.PI;
            coords.push([lon + dLon * Math.cos(theta), lat + dLat * Math.sin(theta)]);
        }
        return coords;
    }

    function circlePolygon(lon, lat, radiusNm, points = 128) {
        return { type: 'Feature', geometry: { type: 'Polygon', coordinates: [circleRing(lon, lat, radiusNm, points)] }, properties: {} };
    }

    // Concentric annulus bands whose opacity fades toward the perimeter, so the
    // coverage area softly dissolves at its edge instead of stopping at a hard
    // line. Each band is its own (non-overlapping) feature carrying an `op`
    // property the fill layer reads directly.
    function fadingRingFeatures(lon, lat, radiusNm, bands = 9) {
        const features = [];
        for (let k = 0; k < bands; k++) {
            const rInner = radiusNm * (k / bands);
            const rOuter = radiusNm * ((k + 1) / bands);
            const outer = circleRing(lon, lat, rOuter, 96);
            const inner = circleRing(lon, lat, rInner, 96).reverse(); // hole
            // brightest at the centre, fading to nearly nothing at the rim
            const op = 0.11 * Math.pow(1 - k / bands, 1.4);
            const rings = rInner > 0 ? [outer, inner] : [outer];
            features.push({
                type: 'Feature',
                geometry: { type: 'Polygon', coordinates: rings },
                properties: { op: Math.max(0.004, op) }
            });
        }
        return { type: 'FeatureCollection', features };
    }

    // Chaikin corner-cutting: rounds the kinks out of a coarse track so the
    // drawn polyline reads as a smooth flown path rather than a chain of
    // straight hops. Endpoints are preserved. Works component-wise on points of
    // any dimension, so the trail can carry fade/altitude alongside lon/lat and
    // have them smoothed in lock-step.
    function smoothCoords(coords, iterations = 3) {
        let pts = coords;
        const dim = pts.length ? pts[0].length : 2;
        for (let it = 0; it < iterations && pts.length > 2; it++) {
            const out = [pts[0]];
            for (let i = 0; i < pts.length - 1; i++) {
                const a = pts[i], b = pts[i + 1];
                const q = new Array(dim), r = new Array(dim);
                for (let d = 0; d < dim; d++) {
                    q[d] = a[d] * 0.75 + b[d] * 0.25;
                    r[d] = a[d] * 0.25 + b[d] * 0.75;
                }
                out.push(q, r);
            }
            out.push(pts[pts.length - 1]);
            pts = out;
        }
        return pts;
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
            /* loading overlay shown while the session payload is fetched */
            #atc-replay-loading {
                position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%);
                width: min(420px, calc(100vw - 32px));
                background: rgba(24, 26, 32, 0.94);
                border: 1px solid rgba(120, 170, 255, 0.22); border-radius: 16px;
                backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px);
                box-shadow: 0 20px 60px rgba(0,0,0,0.6), 0 0 40px rgba(80,140,255,0.08);
                color: #fff; font-family: 'Inter', system-ui, -apple-system, sans-serif;
                z-index: 9001; padding: 18px 20px;
                display: flex; align-items: center; gap: 14px;
                animation: atc-replay-slide-up 220ms ease-out;
            }
            #atc-replay-loading.fade-out { opacity: 0; transition: opacity .2s ease; }
            #atc-replay-loading .atcr-spinner {
                width: 26px; height: 26px; flex-shrink: 0; border-radius: 50%;
                border: 3px solid rgba(125,211,252,0.25); border-top-color: #7dd3fc;
                animation: atcr-spin 0.8s linear infinite;
            }
            @keyframes atcr-spin { to { transform: rotate(360deg); } }
            #atc-replay-loading .atcr-loading-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
            #atc-replay-loading .atcr-loading-title { font-weight: 700; font-size: 13px; }
            #atc-replay-loading .atcr-loading-sub { color: #9aa0a6; font-size: 11px; }
            /* pro-locked free-look button */
            #atc-replay-panel .atcr-freelook { position: relative; }
            #atc-replay-panel .atcr-freelook.locked { opacity: 0.9; }
            #atc-replay-panel .atcr-pro-crown {
                position: absolute; top: -5px; right: -5px; font-size: 9px; color: #fbbf24;
                text-shadow: 0 1px 2px rgba(0,0,0,0.6); pointer-events: none;
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
            #atc-replay-panel .atcr-collapse {
                background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.12);
                color: #e8eaed; width: 28px; height: 28px; border-radius: 50%; cursor: pointer;
                display: grid; place-items: center; transition: all .15s ease; flex-shrink: 0;
            }
            #atc-replay-panel .atcr-collapse:hover { background: rgba(255,255,255,0.15); color: #fff; }

            /* collapsed: shrink to header + transport bar */
            #atc-replay-panel.collapsed { gap: 8px; padding-bottom: 12px; }
            #atc-replay-panel.collapsed .atcr-collapsible { display: none !important; }

            /* per-section fold (flights / frequencies) */
            #atc-replay-panel .atcr-toggle { cursor: pointer; user-select: none; display: flex; align-items: center; gap: 6px; }
            #atc-replay-panel .atcr-toggle:hover { color: #cbd5e1; }
            #atc-replay-panel .sect-chev { font-size: 9px; transition: transform .15s ease; }
            #atc-replay-panel .atcr-toggle.section-collapsed .sect-chev { transform: rotate(-90deg); }

            /* frequency timeline bars */
            #atc-replay-panel .atcr-freqs { display: flex; flex-direction: column; gap: 4px; }
            #atc-replay-panel .atcr-freqs-label { margin-bottom: 2px; }
            #atc-replay-panel .atcr-freqs-hint { color: #475569; font-weight: 600; text-transform: none; letter-spacing: 0; }
            #atc-replay-panel .atcr-freq-row { display: flex; align-items: center; gap: 8px; }
            #atc-replay-panel .atcr-freq-label { width: 78px; flex-shrink: 0; font-size: 10px; font-weight: 700; letter-spacing: .4px; color: #cbd5e1; text-align: right; }
            #atc-replay-panel .atcr-freq-track { position: relative; flex: 1; height: 10px; background: rgba(255,255,255,0.06); border-radius: 5px; overflow: hidden; }
            #atc-replay-panel .atcr-freq-bar { position: absolute; top: 0; bottom: 0; background: linear-gradient(90deg, #38bdf8, #6366f1); border-radius: 5px; opacity: 0.5; transition: opacity .15s ease, box-shadow .15s ease; }
            #atc-replay-panel .atcr-freq-bar.open { background: linear-gradient(90deg, #4ade80, #22d3ee); }
            /* the bar covering the current replay moment lights up */
            #atc-replay-panel .atcr-freq-bar.on-air { opacity: 1; box-shadow: 0 0 8px rgba(125,211,252,0.85); }
            #atc-replay-panel .atcr-freq-playhead { position: absolute; top: 0; bottom: 0; width: 2px; margin-left: -1px; background: #fff; box-shadow: 0 0 6px rgba(255,255,255,0.9); pointer-events: none; z-index: 2; }

            #atc-replay-panel .atcr-hud { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
            #atc-replay-panel .atcr-stat { display: flex; flex-direction: column; align-items: center; gap: 2px; padding: 6px 4px; background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; }
            #atc-replay-panel .atcr-stat label { font-size: 9px; font-weight: 700; letter-spacing: .8px; color: #9aa0a6; }
            #atc-replay-panel .atcr-stat span { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 15px; font-weight: 700; color: #fff; line-height: 1; }
            #atc-replay-panel .atcr-stat small { font-size: 9px; color: #9aa0a6; font-weight: 600; }

            #atc-replay-panel .atcr-controls { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; row-gap: 8px; }
            #atc-replay-panel .atcr-btn {
                background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.2); color: #fff;
                width: 34px; height: 34px; border-radius: 50%; cursor: pointer; display: grid; place-items: center;
                transition: all .15s ease; flex-shrink: 0;
            }
            #atc-replay-panel .atcr-btn:hover { background: rgba(255,255,255,0.15); transform: scale(1.05); }
            #atc-replay-panel .atcr-play { background: #fff; color: #181a20; width: 38px; height: 38px; border-color: #fff; }
            #atc-replay-panel .atcr-play:hover { background: #e8eaed; }
            #atc-replay-panel .atcr-fit.active { background: #fff; color: #181a20; border-color: #fff; }
            #atc-replay-panel .atcr-loop.active { background: #7dd3fc; color: #0b1220; border-color: #7dd3fc; }
            #atc-replay-panel .atcr-freelook.active { background: #fbbf24; color: #181a20; border-color: #fbbf24; box-shadow: 0 0 12px rgba(251,191,36,0.55); }
            #atc-replay-panel .atcr-time { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 11px; font-weight: 600; color: #e8eaed; min-width: 56px; text-align: center; }
            #atc-replay-panel .atcr-time-total { color: #9aa0a6; }
            /* scrub bar + conflict markers */
            #atc-replay-panel .atcr-scrub-wrap { position: relative; flex: 1 1 120px; min-width: 120px; display: flex; align-items: center; }
            #atc-replay-panel .atcr-scrub-marks { position: absolute; left: 0; right: 0; top: 50%; transform: translateY(-50%); height: 9px; pointer-events: none; z-index: 2; }
            #atc-replay-panel .atcr-scrub-mark { position: absolute; top: 0; bottom: 0; min-width: 2px; background: #f87171; border-radius: 2px; box-shadow: 0 0 4px rgba(248,113,113,0.85); opacity: 0.85; pointer-events: auto; cursor: pointer; }
            #atc-replay-panel .atcr-scrub-mark:hover { opacity: 1; }
            #atc-replay-panel .atcr-scrubber {
                flex: 1; width: 100%; min-width: 0; position: relative; z-index: 1; -webkit-appearance: none; appearance: none; height: 4px;
                background: rgba(255,255,255,0.15); border-radius: 4px; outline: none; cursor: pointer;
            }
            #atc-replay-panel .atcr-scrubber::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 14px; height: 14px; border-radius: 50%; background: #7dd3fc; box-shadow: 0 0 8px rgba(125,211,252,0.7); cursor: grab; }
            #atc-replay-panel .atcr-scrubber::-moz-range-thumb { width: 14px; height: 14px; border-radius: 50%; background: #7dd3fc; border: none; cursor: grab; }
            #atc-replay-panel .atcr-speed-wrap { display: flex; gap: 2px; background: rgba(0,0,0,0.3); border-radius: 8px; padding: 2px; flex-shrink: 0; flex-wrap: wrap; justify-content: center; }
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
            #atc-replay-panel .atcr-flight.conflict { border-color: #f87171; background: rgba(248,113,113,0.12); }
            #atc-replay-panel .atcr-flight .fl-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; box-shadow: 0 0 6px currentColor; }
            #atc-replay-panel .atcr-flight .fl-cs { font-family: 'JetBrains Mono', ui-monospace, monospace; font-weight: 700; font-size: 12px; color: #fff; min-width: 64px; }
            #atc-replay-panel .atcr-flight .fl-ac { font-size: 11px; color: #94a3b8; flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            #atc-replay-panel .atcr-flight .fl-nm { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 10px; color: #cbd5e1; white-space: nowrap; }
            #atc-replay-panel .atcr-flight .fl-badge { font-size: 8px; font-weight: 800; letter-spacing: .5px; color: #4ade80; border: 1px solid #4ade80; border-radius: 3px; padding: 0 3px; }
            #atc-replay-panel .atcr-section-label { font-size: 10px; font-weight: 700; letter-spacing: .6px; color: #64748b; text-transform: uppercase; }

            /* enforcement badge (violations the controller issued) */
            #atc-replay-panel .atcr-enforce { display: inline-flex; align-items: center; gap: 4px; font-size: 10px; font-weight: 800; letter-spacing: .4px; padding: 2px 7px; border-radius: 999px; white-space: nowrap; flex-shrink: 0; }
            #atc-replay-panel .atcr-enforce.issued { color: #fca5a5; background: rgba(248,113,113,0.14); border: 1px solid rgba(248,113,113,0.5); }
            #atc-replay-panel .atcr-enforce.clean { color: #6ee7b7; background: rgba(52,211,153,0.12); border: 1px solid rgba(52,211,153,0.4); }

            /* loss-of-separation chip */
            #atc-replay-panel .atcr-conflict { display: inline-flex; align-items: center; gap: 4px; font-size: 10px; font-weight: 800; letter-spacing: .4px; padding: 2px 7px; border-radius: 999px; white-space: nowrap; flex-shrink: 0; color: #fca5a5; background: rgba(248,113,113,0.16); border: 1px solid rgba(248,113,113,0.6); cursor: pointer; animation: atcr-conflict-blink 1s ease-in-out infinite; }
            #atc-replay-panel .atcr-conflict:hover { background: rgba(248,113,113,0.28); }
            @keyframes atcr-conflict-blink { 0%,100% { opacity: 1; } 50% { opacity: 0.45; } }

            /* focused-flight live telemetry strip */
            #atc-replay-panel .atcr-focus { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 12px; padding: 6px 12px; border-radius: 10px; background: rgba(125,211,252,0.1); border: 1px solid rgba(125,211,252,0.35); font-size: 11px; color: #cbd5e1; }
            #atc-replay-panel .atcr-focus > i { color: #7dd3fc; }
            #atc-replay-panel .atcr-focus .ff-cs { font-family: 'JetBrains Mono', ui-monospace, monospace; font-weight: 800; font-size: 12px; color: #fff; }
            #atc-replay-panel .atcr-focus .ff-stat { color: #9aa0a6; font-weight: 600; }
            #atc-replay-panel .atcr-focus .ff-stat b { font-family: 'JetBrains Mono', ui-monospace, monospace; color: #fff; font-weight: 700; margin-left: 3px; }

            /* path-mode segmented control */
            #atc-replay-panel .atcr-pathmode { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; row-gap: 6px; }
            #atc-replay-panel .atcr-pathmode-label { font-size: 10px; font-weight: 700; letter-spacing: .6px; color: #64748b; text-transform: uppercase; }
            #atc-replay-panel .atcr-seg { display: flex; gap: 2px; background: rgba(0,0,0,0.3); border-radius: 8px; padding: 2px; }
            #atc-replay-panel .atcr-seg-btn { background: transparent; border: none; color: #9aa0a6; font-size: 10px; font-weight: 700; padding: 4px 10px; border-radius: 6px; cursor: pointer; transition: all .12s ease; display: inline-flex; align-items: center; gap: 5px; }
            #atc-replay-panel .atcr-seg-btn:hover { color: #fff; }
            #atc-replay-panel .atcr-seg-btn.active { background: rgba(255,255,255,0.15); color: #fff; }

            /* path/trail length slider */
            #atc-replay-panel .atcr-trail-len { display: flex; align-items: center; gap: 8px; flex: 1 1 200px; min-width: 160px; }
            #atc-replay-panel .atcr-trail-slider {
                flex: 1; min-width: 0; -webkit-appearance: none; appearance: none; height: 4px;
                background: rgba(255,255,255,0.15); border-radius: 4px; outline: none; cursor: pointer;
            }
            #atc-replay-panel .atcr-trail-slider::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 14px; height: 14px; border-radius: 50%; background: #7dd3fc; box-shadow: 0 0 8px rgba(125,211,252,0.7); cursor: grab; }
            #atc-replay-panel .atcr-trail-slider::-moz-range-thumb { width: 14px; height: 14px; border-radius: 50%; background: #7dd3fc; border: none; cursor: grab; }
            #atc-replay-panel .atcr-trail-val { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 10px; font-weight: 700; color: #cbd5e1; min-width: 42px; text-align: right; }
            #atc-replay-panel .atcr-trail-len.disabled { opacity: 0.4; pointer-events: none; }

            /* altitude colour legend */
            #atc-replay-panel .atcr-legend { display: flex; align-items: center; gap: 6px; margin-left: auto; font-size: 9px; font-weight: 700; color: #64748b; }
            #atc-replay-panel .atcr-legend-bar { width: 90px; height: 6px; border-radius: 3px; background: linear-gradient(90deg, rgb(56,189,248), rgb(45,212,191), rgb(163,230,53), rgb(250,204,21), rgb(244,63,94)); }

            /* map hover tooltip */
            .atcr-popup .mapboxgl-popup-content { background: rgba(20,22,28,0.95); border: 1px solid rgba(125,211,252,0.35); border-radius: 8px; padding: 6px 9px; box-shadow: 0 6px 20px rgba(0,0,0,0.5); }
            .atcr-popup .mapboxgl-popup-tip { display: none; }
            .atcr-popup .atcr-pop { display: flex; flex-direction: column; gap: 1px; font-family: 'Inter', system-ui, sans-serif; line-height: 1.25; }
            .atcr-popup .atcr-pop b { font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 12px; font-weight: 800; color: #fff; }
            .atcr-popup .atcr-pop span { font-size: 10px; color: #9aa0a6; font-weight: 600; }
            .atcr-popup .atcr-pop em { font-size: 10px; color: #fca5a5; font-weight: 700; font-style: normal; }

            .atc-replay-toast { position: fixed; top: 24px; left: 50%; transform: translateX(-50%); background: rgba(24,26,32,0.95); border: 1px solid rgba(255,255,255,0.2); color: #fff; padding: 10px 18px; border-radius: 10px; font-family: 'Inter', sans-serif; font-size: 13px; font-weight: 600; z-index: 9001; box-shadow: 0 10px 30px rgba(0,0,0,0.5); transition: opacity .4s ease, transform .4s ease; }
            .atc-replay-toast.fade-out { opacity: 0; transform: translate(-50%, -8px); }

            @media (max-width: 640px) {
                #atc-replay-panel { left: 8px; right: 8px; bottom: calc(8px + env(safe-area-inset-bottom, 0px)); transform: none; width: auto; padding: 10px 12px; gap: 8px; border-radius: 14px; animation: none; }
                #atc-replay-panel .atcr-ctrl { display: none; }
                #atc-replay-panel .atcr-freq-label { width: 60px; font-size: 9px; }
                #atc-replay-panel .atcr-flights { max-height: 96px; }
                #atc-replay-panel .atcr-hud { gap: 6px; }
                #atc-replay-panel .atcr-stat span { font-size: 13px; }
                /* speed presets drop to their own full-width row and spread
                   evenly so they always fit the phone screen */
                #atc-replay-panel .atcr-speed-wrap { flex: 1 1 100%; justify-content: space-between; }
                #atc-replay-panel .atcr-speed-btn { flex: 1 1 auto; font-size: 10px; padding: 5px 2px; min-width: 0; }
                #atc-replay-panel .atcr-legend { display: none; }
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

        // Coverage perimeter (skip if controller has no location). The fill is a
        // stack of concentric bands that fade toward the rim, and the boundary
        // is a faint dashed line — soft and persistent rather than a hard edge.
        if (controller && typeof controller.lat === 'number' && typeof controller.lon === 'number') {
            const radiusNm = Math.max(DEFAULT_RADIUS_NM, controller.searchRadiusNm || 0);
            const fillData = fadingRingFeatures(controller.lon, controller.lat, radiusNm);
            const lineData = circlePolygon(controller.lon, controller.lat, radiusNm);
            if (!map.getSource(SRC_RADIUS)) {
                map.addSource(SRC_RADIUS, { type: 'geojson', data: fillData });
            } else {
                map.getSource(SRC_RADIUS).setData(fillData);
            }
            const lineSrcId = SRC_RADIUS + '-line';
            if (!map.getSource(lineSrcId)) {
                map.addSource(lineSrcId, { type: 'geojson', data: lineData });
            } else {
                map.getSource(lineSrcId).setData(lineData);
            }
            if (!map.getLayer(LYR_RADIUS_FILL)) {
                map.addLayer({ id: LYR_RADIUS_FILL, type: 'fill', source: SRC_RADIUS, paint: { 'fill-color': '#6366f1', 'fill-opacity': ['get', 'op'] } });
            }
            if (!map.getLayer(LYR_RADIUS_LINE)) {
                map.addLayer({ id: LYR_RADIUS_LINE, type: 'line', source: lineSrcId, paint: { 'line-color': '#818cf8', 'line-width': 1.5, 'line-dasharray': [3, 4], 'line-opacity': 0.28 } });
            }
        }

        // Static flown tracks (rebuilt when focus / path-mode changes)
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

        // Fading comet trails behind each aircraft (refreshed every frame)
        if (!map.getSource(SRC_TRAILS)) {
            map.addSource(SRC_TRAILS, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
        }
        if (!map.getLayer(LYR_TRAILS)) {
            map.addLayer({
                id: LYR_TRAILS, type: 'line', source: SRC_TRAILS,
                // butt caps so adjacent fade bands abut seamlessly (no blobs);
                // round joins keep the curve itself smooth
                layout: { 'line-cap': 'butt', 'line-join': 'round' },
                paint: {
                    'line-color': ['get', 'color'],
                    'line-opacity': ['get', 'fade'],
                    'line-width': ['interpolate', ['linear'], ['get', 'fade'], 0, 0.6, 1, 4.5],
                    'line-blur': 0.4
                }
            });
        }

        // Animated aircraft positions
        if (!map.getSource(SRC_PLANES)) {
            map.addSource(SRC_PLANES, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
        }
        // Loss-of-separation rings, drawn under the aircraft icons
        if (!map.getLayer(LYR_CONFLICT)) {
            map.addLayer({
                id: LYR_CONFLICT, type: 'circle', source: SRC_PLANES,
                filter: ['==', ['get', 'conflict'], true],
                paint: {
                    'circle-radius': 15,
                    'circle-color': 'rgba(248,113,113,0.16)',
                    'circle-stroke-color': '#f87171',
                    'circle-stroke-width': 2,
                    'circle-stroke-opacity': 0.9
                }
            });
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

        ensureTraffic3D();
        bindMapInteractions();
        applyPathMode();
    }

    // Let controllers click an aircraft on the map to focus it (same effect as
    // tapping its row), with a pointer cursor on hover.
    function bindMapInteractions() {
        if (!map || onPlaneClick) return;
        onPlaneClick = (e) => {
            const f = e.features && e.features[0];
            if (f && f.properties) focusFlight(f.properties.flightId);
        };
        onPlaneEnter = () => { try { map.getCanvas().style.cursor = 'pointer'; } catch (_) {} };
        onPlaneLeave = () => {
            try { map.getCanvas().style.cursor = ''; } catch (_) {}
            if (hoverPopup) { try { hoverPopup.remove(); } catch (_) {} }
        };
        // hover tooltip (desktop) — callsign + altitude + ground speed
        onPlaneMove = (e) => {
            const f = e.features && e.features[0];
            if (!f) return;
            const p = f.properties;
            if (!hoverPopup && typeof mapboxgl !== 'undefined') {
                hoverPopup = new mapboxgl.Popup({ closeButton: false, closeOnClick: false, offset: 14, className: 'atcr-popup' });
            }
            if (hoverPopup) {
                hoverPopup.setLngLat(e.lngLat).setHTML(
                    `<div class="atcr-pop"><b>${p.callsign || '----'}</b>` +
                    `<span>${Number(p.alt || 0).toLocaleString()} ft · ${Number(p.gs || 0)} kt</span>` +
                    (p.conflict ? `<em>⚠ separation loss</em>` : '') + `</div>`
                ).addTo(map);
            }
        };
        map.on('click', LYR_PLANES, onPlaneClick);
        map.on('mouseenter', LYR_PLANES, onPlaneEnter);
        map.on('mouseleave', LYR_PLANES, onPlaneLeave);
        // hover tooltip only on devices with a real pointer (skip touch)
        const hasHover = !window.matchMedia || window.matchMedia('(hover: hover)').matches;
        if (hasHover) map.on('mousemove', LYR_PLANES, onPlaneMove);
        else onPlaneMove = null;
    }
    function unbindMapInteractions() {
        if (!map) return;
        try {
            if (onPlaneClick) map.off('click', LYR_PLANES, onPlaneClick);
            if (onPlaneEnter) map.off('mouseenter', LYR_PLANES, onPlaneEnter);
            if (onPlaneMove) map.off('mousemove', LYR_PLANES, onPlaneMove);
            if (onPlaneLeave) map.off('mouseleave', LYR_PLANES, onPlaneLeave);
        } catch (_) {}
        if (hoverPopup) { try { hoverPopup.remove(); } catch (_) {} hoverPopup = null; }
        onPlaneClick = onPlaneEnter = onPlaneLeave = onPlaneMove = null;
    }

    // Show/hide the static-paths and trails layers to match the active path
    // mode, and rebuild the static paths (in 'trails' mode only the focused
    // flight keeps a full track; everyone else relies on their comet trail).
    function applyPathMode() {
        if (!map) return;
        const showFull = pathMode === 'full' || (pathMode === 'trails' && !!focusedFlightId);
        const showTrails = pathMode === 'trails';
        if (map.getLayer(LYR_PATHS)) map.setLayoutProperty(LYR_PATHS, 'visibility', showFull ? 'visible' : 'none');
        if (map.getLayer(LYR_TRAILS)) map.setLayoutProperty(LYR_TRAILS, 'visibility', showTrails ? 'visible' : 'none');
        if (map.getSource(SRC_PATHS)) map.getSource(SRC_PATHS).setData(buildPathFeatures());
        if (!showTrails && map.getSource(SRC_TRAILS)) {
            map.getSource(SRC_TRAILS).setData({ type: 'FeatureCollection', features: [] });
        }
    }

    // The path-length slider only drives the comet trails ('full' already draws
    // every track end-to-end, 'off' draws nothing), so grey it out unless we're
    // in Trails mode.
    function updateTrailLenEnabled() {
        if (!panelEl) return;
        const wrap = panelEl.querySelector('[data-trail-len]');
        if (wrap) wrap.classList.toggle('disabled', pathMode !== 'trails');
    }

    // Build the static path FeatureCollection, altitude-coloured. Rather than a
    // feature-per-segment (which round-caps into a string of blobs), consecutive
    // points sharing an altitude colour are merged into one smoothed polyline,
    // so each track reads as a single clean line. The focused flight is drawn
    // brighter; others dim when one is focused. Honours the active path mode:
    // 'full' draws every track, 'trails' keeps only the focused flight's full
    // track, 'off' draws nothing.
    function buildPathFeatures() {
        const features = [];
        if (pathMode === 'off') return { type: 'FeatureCollection', features };
        const anyFocused = !!focusedFlightId;
        for (const fl of flights) {
            const focused = fl.flightId === focusedFlightId;
            if (pathMode === 'trails' && !focused) continue; // trails carry the rest
            const dim = anyFocused && !focused;
            const pts = fl.points;
            if (pts.length < 2) continue;
            let runColor = bandColor(pts[0].altitude);
            let runAlt = Math.round(pts[0].altitude || 0);
            let run = [[pts[0].lon, pts[0].lat]];
            const flush = () => {
                if (run.length < 2) return;
                features.push({
                    type: 'Feature',
                    geometry: { type: 'LineString', coordinates: smoothCoords(run) },
                    properties: { color: runColor, focused, dim, alt: runAlt }
                });
            };
            for (let i = 1; i < pts.length; i++) {
                const c = bandColor(pts[i].altitude);
                run.push([pts[i].lon, pts[i].lat]);
                if (c !== runColor) {
                    flush();
                    // start the next run at this point so the line stays unbroken
                    run = [[pts[i].lon, pts[i].lat]];
                    runColor = c;
                    runAlt = Math.round(pts[i].altitude || 0);
                }
            }
            flush();
        }
        return { type: 'FeatureCollection', features };
    }

    // Comet trails: the slice of each active flight's track within the last
    // TRAIL_WINDOW_MS of session time, Chaikin-smoothed and split into a handful
    // of contiguous bands that step from transparent (oldest) to opaque (at the
    // aircraft). Each band is a real multi-point polyline — not a string of
    // 2-point segments — so the tail curves cleanly and tapers without blobs.
    const TRAIL_FADE_BANDS = 18;

    // Per-frame trail detail, scaled to playback speed. The comet trails are a
    // far heavier GeoJSON than the handful of plane points, and Mapbox parses
    // source data on a worker. At high speed the aircraft jump a long way each
    // frame, so if the trail source takes an extra frame or two to parse it
    // visibly drags behind the plane (whose own source parses near-instantly).
    // Lightening the trail as speed climbs — fewer fade bands, less smoothing,
    // and a capped/subsampled tail — keeps its payload cheap enough to parse
    // within the frame, so the comet stays pinned to the aircraft. Normal-speed
    // playback (≤10×) keeps the full detail unchanged.
    function trailDetail() {
        if (speed >= 240) return { bands: 6,  smooth: 0, maxPts: 48 };
        if (speed >= 60)  return { bands: 10, smooth: 1, maxPts: 96 };
        return { bands: TRAIL_FADE_BANDS, smooth: 2, maxPts: Infinity };
    }

    // Trail rebuild is the heaviest per-frame work, so it's bounded two ways:
    //   • a shared point budget split across every aircraft with a tail this
    //     frame, so a packed sector can't multiply the cost by the traffic count;
    //   • an adaptive multiplier driven by the measured frame cost, so a device
    //     that's falling behind sheds detail before it falls over.
    // Together these are what stop speed-up + heavy traffic from piling up work
    // until the web view is killed.
    const TRAIL_POINT_BUDGET = 3000;          // total in-window tail points / frame (at full load)
    const TRAIL_MAX_PTS_PER_FLIGHT = 256;     // ceiling for any single aircraft's tail

    // First index whose timestamp is >= t (binary search; points are time-sorted).
    // Lets the trail window each track without scanning all of its points.
    function firstIndexAtOrAfter(points, t) {
        let lo = 0, hi = points.length;
        while (lo < hi) {
            const mid = (lo + hi) >> 1;
            if (points[mid].t < t) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    function buildTrailFeatures(absT) {
        const features = [];
        const windowMs = Math.max(1, trailWindowMs);
        const windowStart = absT - windowMs;
        const { bands, smooth, maxPts } = trailDetail();

        // First pass: count the aircraft that actually have a tail in this window
        // (touching only track endpoints) so the point budget can be shared out.
        let activeWindow = 0;
        for (const fl of flights) {
            const pts = fl.points;
            if (pts.length < 2 || absT < pts[0].t || windowStart > pts[pts.length - 1].t) continue;
            activeWindow++;
        }
        if (!activeWindow) return { type: 'FeatureCollection', features };

        // Shrink the budget when frames are running long, then split it evenly so
        // the total tail work is roughly constant no matter how many planes fly.
        const load = Math.max(0.25, Math.min(1, 16 / Math.max(1, frameMsEMA)));
        const budget = Math.max(400, Math.floor(TRAIL_POINT_BUDGET * load));
        const perFlightCap = Math.max(
            8, Math.min(maxPts, TRAIL_MAX_PTS_PER_FLIGHT, Math.floor(budget / activeWindow))
        );

        for (const fl of flights) {
            const pts = fl.points;
            if (pts.length < 2 || absT < pts[0].t || windowStart > pts[pts.length - 1].t) continue;
            const head = positionAt(pts, absT);
            if (!head) continue; // flight isn't airborne at this instant

            // Window the track by binary search instead of filtering every point
            // each frame — the old O(total points) scan was the cost that piled up
            // under speed-up + heavy traffic.
            const startIdx = firstIndexAtOrAfter(pts, windowStart);
            let endIdx = firstIndexAtOrAfter(pts, absT);
            while (endIdx < pts.length && pts[endIdx].t <= absT) endIdx++;
            const count = endIdx - startIdx;
            if (count < 1) continue;

            // In-window slice, subsampled to the per-flight cap. The most recent
            // point is always kept so the tail runs cleanly into the live head.
            let tail;
            if (count <= perFlightCap) {
                tail = pts.slice(startIdx, endIdx);
            } else {
                tail = [];
                const step = count / perFlightCap;
                for (let i = 0; i < perFlightCap; i++) tail.push(pts[startIdx + Math.floor(i * step)]);
                if (tail[tail.length - 1] !== pts[endIdx - 1]) tail.push(pts[endIdx - 1]);
            }
            tail.push(head); // tail is always a fresh array, safe to extend in place
            if (tail.length < 2) continue;

            // augment each vertex with [lon, lat, fade(0..1), altitude] so the
            // fade + altitude smooth in lock-step with the geometry
            const aug = tail.map(p => [
                p.lon, p.lat,
                Math.max(0, Math.min(1, (p.t - windowStart) / windowMs)),
                p.altitude || 0
            ]);
            const sm = smooth > 0 ? smoothCoords(aug, smooth) : aug; // rebuilt every frame — keep it light
            const keyOf = (v) => Math.round(v[2] * bands) + '|' + bandColor(v[3]);
            let group = [sm[0]];
            let key = keyOf(sm[0]);
            const flush = () => {
                if (group.length < 2) return;
                let fmax = 0;
                for (const v of group) fmax = Math.max(fmax, v[2]);
                const mid = group[Math.floor(group.length / 2)];
                features.push({
                    type: 'Feature',
                    geometry: { type: 'LineString', coordinates: group.map(v => [v[0], v[1]]) },
                    // ease so the tail stays readable a touch longer before vanishing
                    properties: { color: bandColor(mid[3]), fade: Math.max(0.05, Math.pow(fmax, 0.8)), alt: Math.round(mid[3]) }
                });
            };
            for (let i = 1; i < sm.length; i++) {
                const k = keyOf(sm[i]);
                group.push(sm[i]);
                if (k !== key) { flush(); group = [sm[i]]; key = k; } // share boundary vertex
            }
            flush();
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
        if (currentMs >= totalDurationMs) {
            if (isLooping) { currentMs = 0; lastTickWall = performance.now(); rafHandle = requestAnimationFrame(tick); }
            else pause();
        } else {
            rafHandle = requestAnimationFrame(tick);
        }
    }

    // Guarded entry point for every frame draw. The replay runs inside a RAF
    // loop and also off scrub/focus events; letting an exception escape here
    // would stop the loop dead (and surface as an uncaught error that, on the
    // iOS web view, can read as a hard crash). Swallow per-frame failures so a
    // single bad frame can't take the whole replay — or the app — down.
    function renderFrame() {
        const t0 = performance.now();
        try { renderFrameUnsafe(); }
        catch (e) { console.warn('[AtcReplay] renderFrame failed:', e); }
        // Track how long the frame actually took so the trail budget can adapt to
        // the device + traffic load (see buildTrailFeatures).
        frameMsEMA = frameMsEMA * 0.9 + (performance.now() - t0) * 0.1;
    }

    function renderFrameUnsafe() {
        const absT = spanStart + currentMs;

        // 1. resolve every flight's current position
        const active = [];
        for (const fl of flights) {
            const pos = positionAt(fl.points, absT);
            const listEl = flightRowEls[fl.flightId];
            if (!pos) {
                if (listEl) { listEl.classList.add('inactive'); listEl.classList.remove('conflict'); }
                continue;
            }
            if (listEl) listEl.classList.remove('inactive');
            active.push({ fl, pos });
        }

        // 2. flag any airborne pairs that have lost separation
        const conflictSet = detectConflicts(active);

        // 3. build the aircraft features
        const features = active.map(({ fl, pos }) => {
            const conflict = conflictSet.has(fl.flightId);
            const listEl = flightRowEls[fl.flightId];
            if (listEl) listEl.classList.toggle('conflict', conflict);
            return {
                type: 'Feature',
                geometry: { type: 'Point', coordinates: [pos.lon, pos.lat] },
                properties: {
                    category: fl.category,
                    heading: pos.track || 0,
                    callsign: fl.callsign,
                    color: getAltColor(pos.altitude),
                    flightId: fl.flightId,
                    conflict,
                    alt: Math.round(pos.altitude || 0),
                    gs: Math.round(pos.groundSpeed || 0)
                }
            };
        });

        if (map && map.getSource(SRC_PLANES)) {
            map.getSource(SRC_PLANES).setData({ type: 'FeatureCollection', features });
        }
        if (pathMode === 'trails' && map && map.getSource(SRC_TRAILS)) {
            map.getSource(SRC_TRAILS).setData(buildTrailFeatures(absT));
        }
        updateConflictPulse(conflictSet.size > 0);
        update3DTraffic(active, conflictSet);

        // follow focused flight if "fit/follow" is engaged
        if (isFollowing && focusedFlightId && map) {
            const fl = flights.find(f => f.flightId === focusedFlightId);
            const pos = fl && positionAt(fl.points, absT);
            if (pos) map.jumpTo({ center: [pos.lon, pos.lat] });
        }

        updateHUD(active.length, conflictSet.size);
        updateFocusStrip(absT);
        updateFreqTimeline(absT);
        if (!isScrubbing) updateScrubber();
    }

    // Pairwise loss-of-separation test for the airborne aircraft in the frame.
    // Candidates are sorted south→north so we can sweep-and-prune: once a later
    // aircraft is more than the conflict radius north of the current one, every
    // aircraft after it is too (the list is sorted), so we stop scanning. That
    // turns the old all-pairs O(n²) scan — which spiked the frame cost on a packed
    // sector — into roughly O(n log n).
    function detectConflicts(active) {
        const set = new Set();
        const air = [];
        for (const a of active) if ((a.pos.altitude || 0) >= 500) air.push(a); // airborne only
        if (air.length < 2) return set;
        air.sort((p, q) => p.pos.lat - q.pos.lat);
        const latGate = CONFLICT_NM / 60; // ° latitude beyond which no conflict is possible
        for (let i = 0; i < air.length; i++) {
            const a = air[i].pos;
            for (let j = i + 1; j < air.length; j++) {
                const b = air[j].pos;
                if (b.lat - a.lat > latGate) break; // sorted: nothing further can be in range
                if (Math.abs((a.altitude || 0) - (b.altitude || 0)) >= CONFLICT_FT) continue;
                const midLat = ((a.lat + b.lat) / 2) * Math.PI / 180;
                const dLat = (a.lat - b.lat) * 60;
                const dLon = (a.lon - b.lon) * 60 * Math.cos(midLat);
                if (Math.hypot(dLat, dLon) < CONFLICT_NM) {
                    set.add(air[i].fl.flightId);
                    set.add(air[j].fl.flightId);
                }
            }
        }
        return set;
    }

    // Gently breathe the conflict rings so they read as a live alert.
    function updateConflictPulse(hasConflicts) {
        if (!map || !map.getLayer(LYR_CONFLICT)) return;
        if (!hasConflicts) return;
        try { map.setPaintProperty(LYR_CONFLICT, 'circle-radius', 14 + 4 * Math.sin(performance.now() / 240)); } catch (_) {}
    }

    // Live readout for the focused flight (altitude / ground speed / heading).
    function updateFocusStrip(absT) {
        if (!panelEl) return;
        const strip = panelEl.querySelector('[data-focus-strip]');
        if (!strip) return;
        if (!focusedFlightId) { strip.style.display = 'none'; return; }
        const fl = flights.find(f => f.flightId === focusedFlightId);
        strip.style.display = 'flex';
        const csEl = strip.querySelector('.ff-cs');
        if (csEl) csEl.textContent = (fl && fl.callsign) || '----';
        const set = (k, v) => { const el = strip.querySelector(`[data-ff="${k}"]`); if (el) el.textContent = v; };
        const pos = fl && positionAt(fl.points, absT);
        if (pos) {
            set('alt', Math.round(pos.altitude || 0).toLocaleString() + ' ft');
            set('gs', Math.round(pos.groundSpeed || 0) + ' kt');
            set('hdg', String(Math.round(pos.track || 0) % 360).padStart(3, '0') + '°');
        } else {
            set('alt', 'not airborne'); set('gs', '—'); set('hdg', '—');
        }
    }

    // Sweep the playhead across the frequency timeline and light up whichever
    // frequencies were staffed at the current replay moment — so the bars read
    // as a live "who was on" strip rather than a static decoration.
    function updateFreqTimeline(absT) {
        if (!panelEl || !freqWinSpan) return;
        const pct = Math.max(0, Math.min(100, ((absT - freqWinStart) / freqWinSpan) * 100));
        const left = pct + '%';
        for (const ph of freqPlayheads) ph.style.left = left;
        for (const b of freqBars) b.el.classList.toggle('on-air', absT >= b.fs && absT <= b.fe);
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
    // Compact label for the path-length slider. At the very top of its range
    // (which is clamped to the session length) the whole flown path is shown,
    // so we call it "Full" rather than a misleading minute count.
    function fmtTrailLen(ms) {
        if (ms >= TRAIL_WINDOW_MAX_MS - 1) return 'Full';
        if (ms >= 60000) {
            const m = ms / 60000;
            return (m >= 10 ? Math.round(m) : m.toFixed(1).replace(/\.0$/, '')) + 'm';
        }
        return Math.round(ms / 1000) + 's';
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
        // remember the timeline span so the playhead can be positioned each frame
        freqWinStart = winStart;
        freqWinSpan = winSpan;
        const freqRows = freqList.map(f => {
            const label = atcTypeLabel(f.type);
            const fs = Math.max(winStart, f.start ?? winStart);
            const fe = Math.min(winEnd, (f.open ? winEnd : (f.end ?? winEnd)));
            const left = ((fs - winStart) / winSpan) * 100;
            const width = Math.max(2, ((fe - fs) / winSpan) * 100);
            return `<div class="atcr-freq-row">
                <span class="atcr-freq-label">${label}</span>
                <span class="atcr-freq-track">
                    <span class="atcr-freq-bar${f.open ? ' open' : ''}" data-fs="${fs}" data-fe="${fe}" style="left:${left}%;width:${width}%;"></span>
                    <span class="atcr-freq-playhead"></span>
                </span>
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
                <span class="atcr-conflict" data-hud="conflict" style="display:none;" title="Aircraft within ${CONFLICT_NM}nm and ${CONFLICT_FT}ft of each other"></span>
                <span class="atcr-enforce" data-hud="enforce" style="display:none;"></span>
                <button class="atcr-collapse" title="Collapse / expand panel"><i class="fa-solid fa-chevron-down"></i></button>
                <button class="atcr-close" title="Close ATC Replay"><i class="fa-solid fa-xmark"></i></button>
            </div>

            ${freqRows ? `<div class="atcr-section-label atcr-freqs-label atcr-collapsible atcr-toggle" data-section="freqs"><i class="fa-solid fa-chevron-down sect-chev"></i> Staffed frequencies <span class="atcr-freqs-hint">— bar = when open · line = now</span></div><div class="atcr-freqs atcr-collapsible" data-section-body="freqs">${freqRows}</div>` : ''}

            <div class="atcr-hud atcr-collapsible">
                <div class="atcr-stat"><label>UTC</label><span data-hud="utc">--:--:--</span><small>z</small></div>
                <div class="atcr-stat"><label>AIRBORNE</label><span data-hud="active">0</span><small>in airspace</small></div>
                <div class="atcr-stat"><label>FLIGHTS</label><span data-hud="total">${flights.length}</span><small>total</small></div>
                <div class="atcr-stat"><label>FIELD OPS</label><span data-hud="field">${flights.filter(f => f.atAirport).length}</span><small>arr/dep</small></div>
            </div>

            <div class="atcr-focus atcr-collapsible" data-focus-strip style="display:none;">
                <i class="fa-solid fa-crosshairs"></i>
                <span class="ff-cs">----</span>
                <span class="ff-stat">ALT <b data-ff="alt">--</b></span>
                <span class="ff-stat">GS <b data-ff="gs">--</b></span>
                <span class="ff-stat">HDG <b data-ff="hdg">--</b></span>
            </div>

            <div class="atcr-controls">
                <button class="atcr-btn atcr-restart" title="Restart"><i class="fa-solid fa-backward-step"></i></button>
                <button class="atcr-btn atcr-play" title="Play / Pause"><i class="fa-solid fa-play"></i></button>
                <button class="atcr-btn atcr-fit" title="Fit airspace / follow focused flight"><i class="fa-solid fa-expand"></i></button>
                <button class="atcr-btn atcr-freelook${isFreeLook ? ' active' : ''}${isProUser() ? '' : ' locked'}" title="${isProUser() ? '3D traffic — orbit &amp; tilt to see aircraft at altitude (V)' : '3D traffic — Inflight Pro feature'}"><i class="fa-solid fa-cube"></i>${isProUser() ? '' : '<i class="fa-solid fa-crown atcr-pro-crown"></i>'}</button>
                <button class="atcr-btn atcr-loop${isLooping ? ' active' : ''}" title="Loop playback"><i class="fa-solid fa-repeat"></i></button>
                <div class="atcr-time" data-hud="elapsed">0:00</div>
                <div class="atcr-scrub-wrap">
                    <input type="range" class="atcr-scrubber" min="0" max="1000" value="0" step="1">
                    <div class="atcr-scrub-marks" data-scrub-marks></div>
                </div>
                <div class="atcr-time atcr-time-total">${fmtClock(totalDurationMs)}</div>
                <div class="atcr-speed-wrap">
                    ${ATC_SPEED_OPTIONS.map(s => `<button class="atcr-speed-btn${s === 1 ? ' active' : ''}" data-speed="${s}">${s}×</button>`).join('')}
                </div>
            </div>

            <div class="atcr-pathmode atcr-collapsible">
                <span class="atcr-pathmode-label">Paths</span>
                <div class="atcr-seg">
                    <button class="atcr-seg-btn${pathMode === 'trails' ? ' active' : ''}" data-pathmode="trails" title="Fading trail behind each aircraft"><i class="fa-solid fa-meteor"></i> Trails</button>
                    <button class="atcr-seg-btn${pathMode === 'full' ? ' active' : ''}" data-pathmode="full" title="Draw every track end-to-end"><i class="fa-solid fa-route"></i> Full</button>
                    <button class="atcr-seg-btn${pathMode === 'off' ? ' active' : ''}" data-pathmode="off" title="Hide flown paths"><i class="fa-solid fa-eye-slash"></i> Off</button>
                </div>
                <div class="atcr-trail-len${pathMode !== 'trails' ? ' disabled' : ''}" data-trail-len title="How much flown history trails behind each aircraft">
                    <i class="fa-solid fa-ruler-horizontal" style="color:#64748b;font-size:11px;"></i>
                    <input type="range" class="atcr-trail-slider" min="${TRAIL_WINDOW_MIN_MS}" max="${TRAIL_WINDOW_MAX_MS}" step="5000" value="${Math.round(trailWindowMs)}">
                    <span class="atcr-trail-val" data-trail-val>${fmtTrailLen(trailWindowMs)}</span>
                </div>
                <div class="atcr-legend" title="Path colour by altitude">
                    <span>0</span>
                    <span class="atcr-legend-bar"></span>
                    <span>40k</span>
                </div>
            </div>

            <div class="atcr-pathmode atcr-collapsible">
                <span class="atcr-pathmode-label">Altitude</span>
                <div class="atcr-seg">
                    <button class="atcr-seg-btn${altBand === 'all' ? ' active' : ''}" data-altband="all">All</button>
                    <button class="atcr-seg-btn${altBand === 'low' ? ' active' : ''}" data-altband="low">0–10k</button>
                    <button class="atcr-seg-btn${altBand === 'mid' ? ' active' : ''}" data-altband="mid">10–25k</button>
                    <button class="atcr-seg-btn${altBand === 'high' ? ' active' : ''}" data-altband="high">25k+</button>
                </div>
            </div>

            ${flightRows ? `<div class="atcr-section-label atcr-collapsible atcr-toggle" data-section="flights"><i class="fa-solid fa-chevron-down sect-chev"></i> Flights in airspace (nearest first)</div><div class="atcr-flights atcr-collapsible" data-section-body="flights">${flightRows}</div>` : '<div class="atcr-section-label atcr-collapsible">No flights recorded in this airspace window.</div>'}
        `;
        document.body.appendChild(panelEl);
        bindPanelEvents();
        // Cache the freq-timeline nodes once so the per-frame playhead sweep in
        // updateFreqTimeline() doesn't re-query (and re-iterate) the DOM 60×/sec.
        freqPlayheads = Array.from(panelEl.querySelectorAll('.atcr-freq-playhead'));
        freqBars = Array.from(panelEl.querySelectorAll('.atcr-freq-bar')).map(bar => ({
            el: bar, fs: Number(bar.dataset.fs), fe: Number(bar.dataset.fe)
        }));
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
                // follow and free-look fight over the camera — drop free-look
                if (isFollowing) { exitFreeLook(false); renderFrame(); }
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
            btn.addEventListener('click', () => { speed = Number(btn.dataset.speed); updateSpeedButtons(); });
        });

        panelEl.querySelectorAll('.atcr-seg-btn[data-pathmode]').forEach(btn => {
            btn.addEventListener('click', () => {
                pathMode = btn.dataset.pathmode;
                try { localStorage.setItem(PATH_MODE_STORAGE_KEY, pathMode); } catch (_) {}
                panelEl.querySelectorAll('.atcr-seg-btn[data-pathmode]').forEach(b => b.classList.toggle('active', b === btn));
                updateTrailLenEnabled();
                applyPathMode();
                renderFrame();
            });
        });

        // path/trail length slider — how far the flown history reaches behind
        // each aircraft. Rebuilds the trails live as you drag.
        const trailSlider = panelEl.querySelector('.atcr-trail-slider');
        if (trailSlider) {
            trailSlider.addEventListener('input', (e) => {
                trailWindowMs = Math.max(TRAIL_WINDOW_MIN_MS, Math.min(TRAIL_WINDOW_MAX_MS, Number(e.target.value) || TRAIL_WINDOW_MS));
                const valEl = panelEl.querySelector('[data-trail-val]');
                if (valEl) valEl.textContent = fmtTrailLen(trailWindowMs);
                try { localStorage.setItem(TRAIL_WINDOW_STORAGE_KEY, String(Math.round(trailWindowMs))); } catch (_) {}
                // 'full' draws whole tracks already; the slider drives the trail
                // comet (and the focused-flight trail) — refresh the live frame.
                renderFrame();
            });
        }

        // flight list → focus a flight (highlight its path, dim the rest)
        flightRowEls = {};
        panelEl.querySelectorAll('.atcr-flight').forEach(row => {
            const fid = row.dataset.fid;
            if (!fid) return;
            flightRowEls[fid] = row;
            row.addEventListener('click', () => focusFlight(fid));
        });

        panelEl.querySelector('.atcr-loop')?.addEventListener('click', toggleLoop);
        panelEl.querySelector('.atcr-freelook')?.addEventListener('click', toggleFreeLook);
        panelEl.querySelector('.atcr-collapse')?.addEventListener('click', () => togglePanelCollapse());

        // altitude-band filter
        panelEl.querySelectorAll('.atcr-seg-btn[data-altband]').forEach(btn => {
            btn.addEventListener('click', () => {
                altBand = btn.dataset.altband;
                try { localStorage.setItem(ALT_BAND_STORAGE_KEY, altBand); } catch (_) {}
                panelEl.querySelectorAll('.atcr-seg-btn[data-altband]').forEach(b => b.classList.toggle('active', b === btn));
                applyAltFilter();
            });
        });

        // click a conflict mark on the scrub bar to jump there; chip jumps too
        panelEl.querySelector('[data-scrub-marks]')?.addEventListener('click', (e) => {
            const mark = e.target.closest('.atcr-scrub-mark');
            if (!mark) return;
            currentMs = Math.max(0, Math.min(totalDurationMs, Number(mark.dataset.jump) || 0));
            renderFrame();
        });
        panelEl.querySelector('.atcr-conflict')?.addEventListener('click', () => jumpToConflict(1));

        // fold individual sections (flights / frequencies) via their headers
        panelEl.querySelectorAll('.atcr-toggle').forEach(lbl => {
            lbl.addEventListener('click', () => {
                const sec = lbl.dataset.section;
                const body = panelEl.querySelector(`[data-section-body="${sec}"]`);
                const collapsed = lbl.classList.toggle('section-collapsed');
                if (body) body.style.display = collapsed ? 'none' : '';
            });
        });
    }

    // Master collapse: shrink the panel to just its header + transport controls
    // so it stops eating half the screen. Remembered across sessions.
    function togglePanelCollapse(force) {
        if (!panelEl) return;
        isCollapsed = (typeof force === 'boolean') ? force : !isCollapsed;
        panelEl.classList.toggle('collapsed', isCollapsed);
        const ic = panelEl.querySelector('.atcr-collapse i');
        if (ic) ic.className = isCollapsed ? 'fa-solid fa-chevron-up' : 'fa-solid fa-chevron-down';
        const btn = panelEl.querySelector('.atcr-collapse');
        if (btn) btn.title = isCollapsed ? 'Expand panel' : 'Collapse panel';
        try { localStorage.setItem(COLLAPSE_STORAGE_KEY, isCollapsed ? '1' : '0'); } catch (_) {}
    }

    // Focus (or un-focus) a flight: highlight its row + full path, dim the rest,
    // and pan to it. Shared by the flight list and map-click.
    function focusFlight(fid) {
        if (!fid) return;
        if (focusedFlightId === fid) {
            focusedFlightId = null;
            isFollowing = false;
            panelEl?.querySelector('.atcr-fit')?.classList.remove('active');
        } else {
            focusedFlightId = fid;
        }
        if (panelEl) panelEl.querySelectorAll('.atcr-flight').forEach(r => r.classList.toggle('focused', r.dataset.fid === focusedFlightId));
        applyPathMode();
        const fl = flights.find(f => f.flightId === focusedFlightId);
        if (fl && map) {
            const pos = positionAt(fl.points, spanStart + currentMs) || fl.points[0];
            if (pos && Number.isFinite(pos.lon) && Number.isFinite(pos.lat)) {
                try {
                    map.easeTo({ center: [pos.lon, pos.lat], zoom: Math.max(map.getZoom(), 8), duration: 600 });
                } catch (e) { console.warn('[AtcReplay] focus camera move failed:', e); }
            }
        }
        renderFrame();
    }

    function toggleLoop() {
        isLooping = !isLooping;
        panelEl?.querySelector('.atcr-loop')?.classList.toggle('active', isLooping);
    }

    function updateHUD(activeCount, conflictCount = 0) {
        if (!panelEl) return;
        const set = (sel, val) => { const el = panelEl.querySelector(sel); if (el) el.textContent = val; };
        set('[data-hud="utc"]', fmtZulu(spanStart + currentMs));
        set('[data-hud="active"]', String(activeCount));
        set('[data-hud="elapsed"]', fmtClock(currentMs));
        const cf = panelEl.querySelector('[data-hud="conflict"]');
        if (cf) {
            if (conflictCount > 0) {
                cf.style.display = 'inline-flex';
                cf.innerHTML = `<i class="fa-solid fa-triangle-exclamation"></i> ${conflictCount} too close`;
            } else {
                cf.style.display = 'none';
            }
        }
    }
    function updateSpeedButtons() {
        if (!panelEl) return;
        panelEl.querySelectorAll('.atcr-speed-btn').forEach(b => b.classList.toggle('active', Number(b.dataset.speed) === speed));
    }
    function cycleSpeed(dir) {
        const i = ATC_SPEED_OPTIONS.indexOf(speed);
        const ni = Math.max(0, Math.min(ATC_SPEED_OPTIONS.length - 1, (i < 0 ? 0 : i) + dir));
        speed = ATC_SPEED_OPTIONS[ni];
        updateSpeedButtons();
    }
    function skip(ms) {
        currentMs = Math.max(0, Math.min(totalDurationMs, currentMs + ms));
        renderFrame();
    }

    // ---------- keyboard shortcuts ----------
    function bindKeys() {
        if (onKeyDown) return;
        onKeyDown = (e) => {
            if (!panelEl) return;
            const tag = (e.target && e.target.tagName) || '';
            // ignore when a form control or panel button has focus, so we don't
            // double-fire alongside the browser's native space/enter activation
            if (/INPUT|TEXTAREA|SELECT|BUTTON/.test(tag) || (e.target && e.target.isContentEditable)) return;
            switch (e.key) {
                case ' ': case 'k': case 'K': e.preventDefault(); isPlaying ? pause() : play(); break;
                case 'ArrowLeft': e.preventDefault(); skip(-10000); break;
                case 'ArrowRight': e.preventDefault(); skip(10000); break;
                case 'ArrowUp': e.preventDefault(); cycleSpeed(1); break;
                case 'ArrowDown': e.preventDefault(); cycleSpeed(-1); break;
                case 'l': case 'L': toggleLoop(); break;
                case 'f': case 'F': panelEl.querySelector('.atcr-fit')?.click(); break;
                case 'v': case 'V': panelEl.querySelector('.atcr-freelook')?.click(); break;
                case 'n': case 'N': jumpToConflict(1); break;
                case 'p': case 'P': jumpToConflict(-1); break;
                case 'Escape': close(); break;
                default: return;
            }
        };
        document.addEventListener('keydown', onKeyDown);
    }
    function unbindKeys() {
        if (onKeyDown) document.removeEventListener('keydown', onKeyDown);
        onKeyDown = null;
    }

    // Shade the scrub bar by how many aircraft were airborne over time, so busy
    // periods of the session are visible at a glance before you even play it.
    function applyDensityGradient() {
        if (!panelEl) return;
        const s = panelEl.querySelector('.atcr-scrubber');
        if (!s || !flights.length || !totalDurationMs) return;
        const B = 60;
        const counts = new Array(B).fill(0);
        for (const fl of flights) {
            if (!fl.points.length) continue;
            const t0 = fl.points[0].t, t1 = fl.points[fl.points.length - 1].t;
            for (let b = 0; b < B; b++) {
                const t = spanStart + ((b + 0.5) / B) * totalDurationMs;
                if (t >= t0 && t <= t1) counts[b]++;
            }
        }
        const max = Math.max(1, ...counts);
        const stops = counts.map((c, b) => {
            const pct = (b / (B - 1)) * 100;
            const a = 0.1 + 0.55 * (c / max);
            return `rgba(125,211,252,${a.toFixed(2)}) ${pct.toFixed(1)}%`;
        });
        s.style.background = `linear-gradient(90deg, ${stops.join(',')})`;
    }

    // ---------- altitude-band filter ----------
    // Show only aircraft / tracks whose altitude sits inside the chosen band by
    // applying a Mapbox filter on the layers (features carry an `alt` property).
    function applyAltFilter() {
        if (!map) return;
        const [mn, mx] = ALT_BANDS[altBand] || ALT_BANDS.all;
        const altExpr = ['all', ['>=', ['coalesce', ['get', 'alt'], 0], mn], ['<', ['coalesce', ['get', 'alt'], 0], mx]];
        const setF = (id, base) => {
            if (!map.getLayer(id)) return;
            let filter = null;
            if (altBand === 'all') filter = base || null;
            else filter = base ? ['all', base, altExpr] : altExpr;
            try { map.setFilter(id, filter); } catch (_) {}
        };
        setF(LYR_PLANES);
        setF(LYR_PLANE_LABELS);
        setF(LYR_TRAILS);
        setF(LYR_PATHS);
        setF(LYR_CONFLICT, ['==', ['get', 'conflict'], true]);
    }

    // ---------- conflict timeline ----------
    // Pre-scan the whole session to find every stretch where separation was lost,
    // so we can mark them on the scrub bar and jump between them.
    function precomputeConflicts() {
        conflictIntervals = [];
        if (!flights.length || !totalDurationMs) return;
        // Fewer probes on a crowded roster so this one-time pre-scan can't stall
        // open() (each probe positions every aircraft + runs the pair check).
        const samples = flights.length > 150 ? 200 : 400;
        const STEP = Math.max(2000, totalDurationMs / samples);
        let curStart = null;
        for (let t = 0; t <= totalDurationMs; t += STEP) {
            const absT = spanStart + t;
            const active = [];
            for (const fl of flights) {
                const pos = positionAt(fl.points, absT);
                if (pos) active.push({ fl, pos });
            }
            const has = detectConflicts(active).size > 0;
            if (has && curStart === null) curStart = t;
            else if (!has && curStart !== null) { conflictIntervals.push({ start: curStart, end: t }); curStart = null; }
        }
        if (curStart !== null) conflictIntervals.push({ start: curStart, end: totalDurationMs });
    }
    function renderScrubMarks() {
        if (!panelEl) return;
        const el = panelEl.querySelector('[data-scrub-marks]');
        if (!el) return;
        el.innerHTML = conflictIntervals.map(iv => {
            const left = (iv.start / totalDurationMs) * 100;
            const width = Math.max(0.6, ((iv.end - iv.start) / totalDurationMs) * 100);
            return `<span class="atcr-scrub-mark" data-jump="${Math.round(iv.start)}" style="left:${left.toFixed(2)}%;width:${width.toFixed(2)}%;" title="Separation loss — click to jump"></span>`;
        }).join('');
    }
    function jumpToConflict(dir) {
        if (!conflictIntervals.length) return;
        if (dir > 0) {
            const next = conflictIntervals.find(iv => iv.start > currentMs + 1);
            if (next) { currentMs = next.start; renderFrame(); }
        } else {
            const prevs = conflictIntervals.filter(iv => iv.start < currentMs - 1);
            if (prevs.length) { currentMs = prevs[prevs.length - 1].start; renderFrame(); }
        }
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

    // Paint the enforcement badge once we know how many violations the
    // controller issued during the session (null = still unknown, hidden).
    function renderEnforcement() {
        if (!panelEl) return;
        const el = panelEl.querySelector('[data-hud="enforce"]');
        if (!el) return;
        if (enforcementCount == null) { el.style.display = 'none'; return; }
        el.style.display = 'inline-flex';
        if (enforcementCount > 0) {
            el.className = 'atcr-enforce issued';
            el.innerHTML = `<i class="fa-solid fa-gavel"></i> ${enforcementCount} issued`;
            el.title = `${enforcementCount} violation(s) issued this session`;
        } else {
            el.className = 'atcr-enforce clean';
            el.innerHTML = `<i class="fa-solid fa-shield-halved"></i> No violations`;
            el.title = 'No violations issued this session';
        }
    }

    // We can't know mid-session whether a controller issued violations — that
    // only lands in their ATC logbook once the session ends. So after the
    // (already-historical) replay loads we reconcile against the controller's
    // logbook, preferring any count baked into the replay payload itself.
    async function loadEnforcement() {
        let count = num(controller?.violationsIssued, currentMeta?.violationsIssued);
        if (count == null) {
            const uid = controller?.userId || currentMeta?.userId;
            const base = currentMeta?.apiBase;
            const icao = (controller && controller.airportName) || currentMeta?.airportName;
            if (uid && base) {
                try {
                    const res = await fetch(`${base}/api/users/${encodeURIComponent(uid)}/atc?page=1`);
                    const json = res.ok ? await res.json() : null;
                    const sessions = (json && (json.data || json.sessions)) || [];
                    // window the replay covers, with a little slack on each side
                    const wStart = (controller?.window?.start ?? spanStart) - 30 * 60000;
                    const wEnd = (controller?.window?.end ?? (spanStart + totalDurationMs)) + 30 * 60000;
                    let best = null, bestDist = Infinity;
                    for (const s of sessions) {
                        const sIcao = s.facility?.airportIcao || s.airportName;
                        if (icao && sIcao && sIcao !== icao) continue;
                        const t = num(s.created, s.start, s.end);
                        if (t == null) continue;
                        if (t < wStart || t > wEnd) continue;
                        const dist = Math.abs(t - (spanStart + totalDurationMs / 2));
                        if (dist < bestDist) { bestDist = dist; best = s; }
                    }
                    if (best) count = num(best.violationsIssued) ?? 0;
                } catch (e) {
                    console.warn('[AtcReplay] enforcement lookup failed:', e);
                }
            }
        }
        enforcementCount = (count == null) ? null : count;
        renderEnforcement();
    }

    function fitToAirspace() {
        if (!map) return;
        try {
            const b = new mapboxgl.LngLatBounds();
            let has = false;
            if (controller && typeof controller.lat === 'number' && typeof controller.lon === 'number') {
                // extend by the full coverage ring so the whole perimeter shows
                const radiusNm = Math.max(DEFAULT_RADIUS_NM, controller.searchRadiusNm || 0);
                for (const c of circleRing(controller.lon, controller.lat, radiusNm, 32)) b.extend(c);
                has = true;
            }
            for (const fl of flights) for (const p of fl.points) { b.extend([p.lon, p.lat]); has = true; }
            if (has) map.fitBounds(b, { padding: 80, maxZoom: 11, duration: 800 });
        } catch (_) {}
    }

    // ---------- 3D traffic (elevated glowing dots) ----------
    // Altitude colour as normalized [r,g,b] for Three.js vertex colours —
    // mirrors getAltColor()'s ramp so the 3D dots match the 2D look.
    function altColor01(alt) {
        const stops = [
            [0, [56, 189, 248]], [10000, [45, 212, 191]], [20000, [163, 230, 53]],
            [30000, [250, 204, 21]], [40000, [244, 63, 94]]
        ];
        const a = Math.max(0, Math.min(40000, alt || 0));
        let s1 = stops[0], s2 = stops[stops.length - 1];
        for (let i = 0; i < stops.length - 1; i++) {
            if (a >= stops[i][0] && a <= stops[i + 1][0]) { s1 = stops[i]; s2 = stops[i + 1]; break; }
        }
        const range = s2[0] - s1[0], f = range === 0 ? 0 : (a - s1[0]) / range;
        return [
            (s1[1][0] + (s2[1][0] - s1[1][0]) * f) / 255,
            (s1[1][1] + (s2[1][1] - s1[1][1]) * f) / 255,
            (s1[1][2] + (s2[1][2] - s1[1][2]) * f) / 255
        ];
    }

    // Soft radial sprite so each point renders as a glowing orb rather than a
    // hard square, tinted per-aircraft by the vertex colour.
    function makeGlowTexture() {
        const THREE = window.THREE;
        const size = 64;
        const c = document.createElement('canvas');
        c.width = c.height = size;
        const ctx = c.getContext('2d');
        const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
        g.addColorStop(0, 'rgba(255,255,255,1)');
        g.addColorStop(0.25, 'rgba(255,255,255,0.85)');
        g.addColorStop(0.6, 'rgba(255,255,255,0.25)');
        g.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, size, size);
        const tex = new THREE.CanvasTexture(c);
        tex.needsUpdate = true;
        return tex;
    }

    // Build the Three.js custom layer once. Two buffers: the dots (THREE.Points,
    // additive glow) and the vertical stems (THREE.LineSegments) connecting each
    // dot to the ground. It renders in the map's own WebGL context, exactly the
    // way flownPath3D.js does, positioning everything in Mercator world space.
    function ensureTraffic3D() {
        if (!map || three || !window.THREE || !window.mapboxgl) return;
        if (map.getLayer(LYR_3D)) return;
        const THREE = window.THREE;
        const self = { visible: false };
        const glowTex = makeGlowTexture();

        const layer = {
            id: LYR_3D, type: 'custom', renderingMode: '3d',
            onAdd(m, gl) {
                self.camera = new THREE.Camera();
                self.scene = new THREE.Scene();

                self.dotGeo = new THREE.BufferGeometry();
                self.dotGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 3), 3));
                self.dotGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 3), 3));
                self.dotMat = new THREE.PointsMaterial({
                    size: DOT_SIZE_PX, sizeAttenuation: false, map: glowTex,
                    vertexColors: true, transparent: true, depthWrite: false,
                    blending: THREE.AdditiveBlending
                });
                self.dots = new THREE.Points(self.dotGeo, self.dotMat);
                self.dots.frustumCulled = false;
                self.scene.add(self.dots);

                self.stemGeo = new THREE.BufferGeometry();
                self.stemGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.stemGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.stemMat = new THREE.LineBasicMaterial({
                    vertexColors: true, transparent: true, opacity: 0.32,
                    depthWrite: false, blending: THREE.AdditiveBlending
                });
                self.stems = new THREE.LineSegments(self.stemGeo, self.stemMat);
                self.stems.frustumCulled = false;
                self.scene.add(self.stems);

                self.renderer = new THREE.WebGLRenderer({ canvas: m.getCanvas(), context: gl, antialias: true });
                self.renderer.autoClear = false;
                self.glowTex = glowTex;
            },
            render(gl, matrix) {
                if (!self.renderer || !self.visible) return;
                self.camera.projectionMatrix = new THREE.Matrix4().fromArray(matrix);
                self.renderer.resetState();
                self.renderer.render(self.scene, self.camera);
            }
        };
        try { map.addLayer(layer); three = self; } catch (e) { console.warn('[AtcReplay] 3D layer add failed:', e); }
    }

    // Refresh the dot + stem buffers from the current frame's aircraft. No-op
    // unless the 3D view is showing, so the flat radar path costs nothing.
    function update3DTraffic(active, conflictSet) {
        if (!three || !three.visible || !map) return;
        const Merc = window.mapboxgl.MercatorCoordinate;
        const [bandMin, bandMax] = ALT_BANDS[altBand] || ALT_BANDS.all;
        const dotPos = three.dotGeo.attributes.position, dotCol = three.dotGeo.attributes.color;
        const stemPos = three.stemGeo.attributes.position, stemCol = three.stemGeo.attributes.color;
        let n = 0;
        for (const { fl, pos } of active) {
            if (n >= MAX_3D_DOTS) break;
            const alt = pos.altitude || 0;
            if (alt < bandMin || alt >= bandMax) continue;
            const m = Merc.fromLngLat([pos.lon, pos.lat], alt * 0.3048 * ALT_EXAGGERATION);
            const focused = focusedFlightId && fl.flightId === focusedFlightId;
            const c = conflictSet.has(fl.flightId) ? [1, 0.27, 0.27] : (focused ? [1, 1, 1] : altColor01(alt));
            dotPos.setXYZ(n, m.x, m.y, m.z);
            dotCol.setXYZ(n, c[0], c[1], c[2]);
            // stem runs from the ground point straight up to the dot
            stemPos.setXYZ(n * 2, m.x, m.y, 0);
            stemPos.setXYZ(n * 2 + 1, m.x, m.y, m.z);
            stemCol.setXYZ(n * 2, c[0], c[1], c[2]);
            stemCol.setXYZ(n * 2 + 1, c[0], c[1], c[2]);
            n++;
        }
        three.dotGeo.setDrawRange(0, n);
        three.stemGeo.setDrawRange(0, n * 2);
        dotPos.needsUpdate = dotCol.needsUpdate = true;
        stemPos.needsUpdate = stemCol.needsUpdate = true;
        map.triggerRepaint();
    }

    // Swap between the flat radar icons and the 3D dot field. Showing the dots
    // hides the ground-locked aircraft symbols/labels so they don't double up.
    function set3DVisible(on) {
        if (three) three.visible = !!on;
        const flatVis = on ? 'none' : 'visible';
        [LYR_PLANES, LYR_PLANE_LABELS].forEach(id => {
            if (map && map.getLayer(id)) { try { map.setLayoutProperty(id, 'visibility', flatVis); } catch (_) {} }
        });
        if (map) map.triggerRepaint();
    }

    function dispose3D() {
        if (!three) return;
        try {
            three.dotGeo && three.dotGeo.dispose();
            three.stemGeo && three.stemGeo.dispose();
            three.dotMat && three.dotMat.dispose();
            three.stemMat && three.stemMat.dispose();
            three.glowTex && three.glowTex.dispose();
        } catch (_) {}
        three = null;
    }

    // ---------- free-look camera ----------
    // Detach the camera from the flat radar / follow behaviour and drop into a
    // cinematic high-pitch oblique view, letting the controller orbit, tilt and
    // pan freely around the historical traffic while it keeps playing — the
    // planes read as a field of glowing contacts against the horizon.
    function toggleFreeLook() {
        if (isFreeLook) { exitFreeLook(true); return; }
        if (!isProUser()) { promptUpgrade(); return; }
        enterFreeLook();
    }

    function enterFreeLook() {
        if (!map || isFreeLook) return;

        // Make sure the elevated-traffic layer exists before we commit to the
        // 3D view. It's normally built in ensureLayers() at open(), but if THREE
        // hadn't finished loading then (it's pulled from a CDN), `three` is still
        // null. Build it now, lazily, the way LiveTraffic3D does. If it still
        // can't be created, stay in the flat radar view and say so — otherwise
        // set3DVisible() would hide the flat planes and leave an empty map, which
        // reads as the button "not working".
        ensureTraffic3D();
        if (!three) {
            showToast('3D traffic is still loading — try again in a moment.', 'error');
            return;
        }

        isFreeLook = true;

        // follow and free-look both fight for the camera — only one wins
        if (isFollowing) {
            isFollowing = false;
            panelEl?.querySelector('.atcr-fit')?.classList.remove('active');
        }

        // snapshot what we're about to change so we can put it back exactly
        const on = (h) => !!(h && h.isEnabled && h.isEnabled());
        preFreeLookCam = {
            center: map.getCenter(), zoom: map.getZoom(),
            pitch: map.getPitch(), bearing: map.getBearing(),
            projection: (map.getProjection && map.getProjection().name) || 'mercator'
        };
        preFreeLookGestures = {
            maxPitch: map.getMaxPitch ? map.getMaxPitch() : 60,
            dragRotate: on(map.dragRotate),
            touchPitch: on(map.touchPitch)
        };

        // mercator keeps the custom-layer matrix correct for the elevated dots
        // and gives the flatter, horizon-lit look the 3D view is going for
        try { if (map.setProjection) map.setProjection('mercator'); } catch (_) {}

        // free the gestures the flat radar view normally keeps locked down
        try { if (map.setMaxPitch) map.setMaxPitch(85); } catch (_) {}
        try { map.dragRotate && map.dragRotate.enable(); } catch (_) {}
        try { map.touchPitch && map.touchPitch.enable(); } catch (_) {}
        try { map.touchZoomRotate && map.touchZoomRotate.enableRotation(); } catch (_) {}
        try { map.keyboard && map.keyboard.enable(); } catch (_) {}

        // raise the traffic into 3D glowing dots at altitude
        set3DVisible(true);
        renderFrame();

        // swing into the oblique angle, framed on the airspace centre
        let center = map.getCenter();
        if (controller && Number.isFinite(controller.lat) && Number.isFinite(controller.lon)) {
            center = [controller.lon, controller.lat];
        }
        try {
            map.easeTo({
                center, zoom: Math.min(map.getZoom(), 9),
                pitch: 72, bearing: map.getBearing(),
                duration: 1100, essential: true
            });
        } catch (_) {}

        panelEl?.querySelector('.atcr-freelook')?.classList.add('active');
        showToast('3D traffic — drag to orbit · two-finger / right-drag to tilt');
    }

    // restoreCamera=false hands the camera straight to whatever's taking over
    // (e.g. follow mode) instead of easing back to the flat view first.
    function exitFreeLook(restoreCamera = true) {
        if (!isFreeLook) return;
        isFreeLook = false;
        panelEl?.querySelector('.atcr-freelook')?.classList.remove('active');
        // drop back to the flat radar icons
        set3DVisible(false);
        if (!map) { preFreeLookCam = null; preFreeLookGestures = null; return; }

        // restore the gesture lockdown the flat view expects
        const g = preFreeLookGestures;
        if (g) {
            try { if (!g.dragRotate && map.dragRotate) map.dragRotate.disable(); } catch (_) {}
            try { if (!g.touchPitch && map.touchPitch) map.touchPitch.disable(); } catch (_) {}
            try { if (map.setMaxPitch) map.setMaxPitch(g.maxPitch); } catch (_) {}
        }
        // restore the projection we swapped away from
        try { if (map.setProjection && preFreeLookCam && preFreeLookCam.projection) map.setProjection(preFreeLookCam.projection); } catch (_) {}
        if (restoreCamera) {
            // ease back to exactly where the camera sat before free-look
            const c = preFreeLookCam;
            try {
                map.easeTo(c
                    ? { center: c.center, zoom: c.zoom, pitch: c.pitch, bearing: c.bearing, duration: 900, essential: true }
                    : { pitch: 0, bearing: 0, duration: 900, essential: true });
            } catch (_) {}
        }
        preFreeLookCam = null; preFreeLookGestures = null;
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

    // Surface a short message. Prefer the app's own notification system
    // (window.showGlobalNotification) so replay messages look and behave like
    // every other notification in the app, instead of a bespoke floating toast.
    // Falls back to a minimal inline element only when the host helper is absent
    // (e.g. the module running standalone outside the app shell).
    function showToast(msg, type = 'info') {
        try {
            if (typeof window.showGlobalNotification === 'function') {
                window.showGlobalNotification(msg, type);
                return;
            }
        } catch (_) {}
        const t = document.createElement('div');
        t.className = 'atc-replay-toast';
        t.textContent = msg;
        document.body.appendChild(t);
        setTimeout(() => t.classList.add('fade-out'), 2400);
        setTimeout(() => t.remove(), 3000);
    }

    // Loading overlay — shown the instant a replay is requested so it's clear
    // the (often multi-MB, server-reconstructed) session is being fetched,
    // rather than leaving the user staring at nothing until the panel appears.
    let loadingEl = null;
    function showLoading(sub) {
        hideLoading();
        loadingEl = document.createElement('div');
        loadingEl.id = 'atc-replay-loading';
        loadingEl.innerHTML = `
            <div class="atcr-spinner"></div>
            <div class="atcr-loading-text">
                <div class="atcr-loading-title">Loading ATC replay…</div>
                <div class="atcr-loading-sub">${sub || 'Reconstructing the session — this can take a moment.'}</div>
            </div>`;
        document.body.appendChild(loadingEl);
    }
    function hideLoading() {
        if (!loadingEl) return;
        const el = loadingEl; loadingEl = null;
        el.classList.add('fade-out');
        setTimeout(() => { try { el.remove(); } catch (_) {} }, 220);
    }

    // ---------- subscription gating ----------
    // The 3D traffic view is an Inflight Pro feature. Source of truth is the
    // app's global helper; if it isn't present we fail closed (locked).
    function isProUser() {
        // Match the rest of the app's Pro gating. Every other Pro control —
        // custom colours, Pro map styles, 3D terrain/buildings, day-night, etc.
        // — unlocks for any *signed-in* user (see flight.js, which gates on
        // `ProfileUI._currentUser`). The 3D-traffic button first tried the strict
        // `window.isInflightPro()` entitlement (a Supabase `profiles.is_pro`
        // lookup that usually stays false), then a localStorage token scan — but
        // that scan misses the real session: supabase-js can chunk the token
        // across `sb-<ref>-auth-token.0/.1` keys (none of which end in
        // `-auth-token`), and native shells may persist it outside localStorage
        // entirely. So a signed-in Pro user sat locked. Use the app's actual
        // source of truth — `ProfileUI._currentUser` — exactly like every other
        // Pro control, with the entitlement + storage probes only as fallbacks.
        try {
            if (typeof window.isInflightPro === 'function' && window.isInflightPro()) return true;
        } catch (_) { /* ignore */ }
        // The canonical signed-in check used across flight.js.
        try {
            if (ProfileUI && ProfileUI._currentUser) return true;
        } catch (_) { /* ProfileUI not ready */ }
        // Loose window-global fallbacks (mirrors MobileSettingsUI's probe) for
        // any context where the module binding above isn't populated yet.
        try {
            if (window.currentUser || window.user || window.isLoggedIn || window.session) return true;
        } catch (_) { /* ignore */ }
        // Last-ditch: a Supabase auth token in localStorage. Match the chunked
        // form (`...-auth-token.0`) too, not just the exact key.
        try {
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (key && (key.includes('supabase.auth.token') ||
                            (key.startsWith('sb-') && key.includes('-auth-token')))) {
                    return true;
                }
            }
        } catch (_) { /* storage unavailable */ }
        return false;
    }

    // Re-paint the free-look button's locked/unlocked state. Pro status is
    // resolved asynchronously (a Supabase lookup), so the panel can be built
    // before the entitlement lands — without this, a Pro user who opened the
    // replay early would stay locked out of 3D until reload. We listen for
    // `proStatusChanged` and re-run this so the crown/lock clears the moment
    // the entitlement resolves.
    function updateFreeLookLock() {
        if (!panelEl) return;
        const btn = panelEl.querySelector('.atcr-freelook');
        if (!btn) return;
        const pro = isProUser();
        btn.classList.toggle('locked', !pro);
        btn.title = pro
            ? '3D traffic — orbit & tilt to see aircraft at altitude (V)'
            : '3D traffic — Inflight Pro feature';
        const crown = btn.querySelector('.atcr-pro-crown');
        if (pro) {
            if (crown) crown.remove();
        } else if (!crown) {
            const i = document.createElement('i');
            i.className = 'fa-solid fa-crown atcr-pro-crown';
            btn.appendChild(i);
        }
    }
    function promptUpgrade() {
        showToast('3D traffic view is an Inflight Pro feature.');
        try {
            window.dispatchEvent(new CustomEvent('pro-upgrade-requested', {
                bubbles: true, cancelable: true, detail: { source: 'atc-replay-3d' }
            }));
        } catch (_) {}
    }

    function close() {
        pause();
        hideLoading();
        unbindKeys();
        unbindMapInteractions();
        if (onProStatusChanged) {
            try { window.removeEventListener('proStatusChanged', onProStatusChanged); } catch (_) {}
            onProStatusChanged = null;
        }
        exitFreeLook(true);
        restoreLiveTraffic();
        if (map) {
            [LYR_3D, LYR_PLANE_LABELS, LYR_PLANES, LYR_CONFLICT, LYR_TRAILS, LYR_PATHS, LYR_RADIUS_LINE, LYR_RADIUS_FILL].forEach(id => {
                if (map.getLayer && map.getLayer(id)) { try { map.removeLayer(id); } catch (_) {} }
            });
            dispose3D();
            [SRC_PLANES, SRC_TRAILS, SRC_PATHS, SRC_RADIUS + '-line', SRC_RADIUS].forEach(id => {
                if (map.getSource && map.getSource(id)) { try { map.removeSource(id); } catch (_) {} }
            });
        }
        if (panelEl) { panelEl.remove(); panelEl = null; }

        controller = null; flights = []; currentMeta = {}; flightRowEls = {};
        freqBars = []; freqPlayheads = [];
        spanStart = 0; totalDurationMs = 0; currentMs = 0; speed = 1;
        frameMsEMA = 16;
        isScrubbing = false; focusedFlightId = null; isFollowing = false;
        isFreeLook = false; preFreeLookCam = null; preFreeLookGestures = null; three = null;
        enforcementCount = null; isLooping = false; isCollapsed = false;
        conflictIntervals = []; altBand = 'all';

        const cb = onCloseCallback; onCloseCallback = null;
        if (typeof cb === 'function') { try { cb(); } catch (e) { console.warn('[AtcReplay] onClose threw:', e); } }
    }

    async function open(opts) {
        if (!opts || !opts.map || !opts.replayUrl) {
            showToast('ATC Replay error: missing map or session.', 'error');
            return false;
        }
        close();
        injectStyles();
        map = opts.map;
        currentMeta = opts.meta || {};
        onCloseCallback = (typeof opts.onClose === 'function') ? opts.onClose : null;

        showLoading();
        let payload = null;
        try {
            const res = await fetch(opts.replayUrl);
            if (res.status === 404) { hideLoading(); showToast('This ATC session has expired (data is kept 48h).', 'error'); close(); return false; }
            payload = res.ok ? await res.json() : null;
        } catch (e) {
            console.warn('[AtcReplay] fetch failed:', e);
        }
        if (!payload || !payload.ok || !payload.controller) {
            hideLoading();
            showToast('Could not load ATC session.', 'error');
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
            hideLoading();
            showToast('No replayable track data in this session window.', 'error');
            close();
            return false;
        }
        spanStart = start;
        totalDurationMs = end - start;
        currentMs = 0;

        // The trail slider tops out at the full session length, so its max ("Full")
        // shows each aircraft's entire flown path as a comet. Clamp the running
        // length into the new range and honour the saved preference.
        TRAIL_WINDOW_MAX_MS = Math.max(TRAIL_WINDOW_MIN_MS + 1, Math.round(totalDurationMs));
        trailWindowMs = Math.max(TRAIL_WINDOW_MIN_MS, Math.min(TRAIL_WINDOW_MAX_MS, TRAIL_WINDOW_MS));

        try {
            const saved = localStorage.getItem(PATH_MODE_STORAGE_KEY);
            if (PATH_MODES.includes(saved)) pathMode = saved;
            const savedAlt = localStorage.getItem(ALT_BAND_STORAGE_KEY);
            if (savedAlt && ALT_BANDS[savedAlt]) altBand = savedAlt;
            const savedTrail = Number(localStorage.getItem(TRAIL_WINDOW_STORAGE_KEY));
            if (Number.isFinite(savedTrail) && savedTrail > 0) {
                trailWindowMs = Math.max(TRAIL_WINDOW_MIN_MS, Math.min(TRAIL_WINDOW_MAX_MS, savedTrail));
            }
        } catch (_) {}

        precomputeConflicts();
        buildPanel();
        hideLoading();
        renderScrubMarks();
        try { if (localStorage.getItem(COLLAPSE_STORAGE_KEY) === '1') togglePanelCollapse(true); } catch (_) {}
        applyDensityGradient();
        loadEnforcement();
        bindKeys();

        // Keep the 3D (free-look) button's lock in sync with the Pro entitlement,
        // which may still be resolving when the panel opens.
        updateFreeLookLock();
        if (!onProStatusChanged) {
            onProStatusChanged = () => updateFreeLookLock();
            window.addEventListener('proStatusChanged', onProStatusChanged);
        }
        // Nudge a re-check in case the entitlement was never loaded this session.
        try { if (window.InflightUser && !window.InflightUser.loaded && typeof window.refreshProStatus === 'function') window.refreshProStatus(); } catch (_) {}

        // Adding the map layers / 3D custom layer can throw (style not ready,
        // WebGL hiccup, missing globals). Guard it so a setup failure surfaces a
        // notification and tears down cleanly instead of crashing the host app.
        const setup = () => {
            try {
                ensureLayers();
                applyAltFilter();
                hideLiveTraffic();
                fitToAirspace();
                renderFrame();
                play();
            } catch (e) {
                console.warn('[AtcReplay] setup failed:', e);
                showToast('Could not start ATC replay on this device.', 'error');
                close();
            }
        };
        if (map.isStyleLoaded && !map.isStyleLoaded()) map.once('idle', setup);
        else setup();
        return true;
    }

    // The whole open() flow is wrapped so any unexpected failure (network, bad
    // payload shape, map state) becomes a graceful notification rather than an
    // uncaught rejection.
    const openUnsafe = open;
    open = async function (opts) {
        try { return await openUnsafe(opts); }
        catch (e) {
            console.warn('[AtcReplay] open failed:', e);
            showToast('Could not open ATC replay.', 'error');
            try { close(); } catch (_) {}
            return false;
        }
    };

    return { open, close, isOpen: () => !!panelEl };
})();
