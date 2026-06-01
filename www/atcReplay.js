/**
 * atcReplay.js
 * --------------------------------------------------------------------------
 * ATC Controller Replay — a coverage + traffic replay for a controller's
 * frequency timeline at an airport, joined against recorded flight paths.
 *
 * This is a self-contained full-screen overlay with its own Mapbox GL map so
 * it never tangles with the live sector-ops map state. It talks to the
 * backend's plain REST endpoints:
 *
 *   GET /api/atc/sessions?user=&userId=&sessionId=&since=&limit=
 *   GET /api/atc/sessions/recent?sessionId=&limit=
 *   GET /api/atc/replay?key=<session.key>
 *
 * IMPORTANT framing (surfaced in the UI, not just comments):
 *   - Replay only covers the last 48h; expired sessions 404 and are removed.
 *   - Flight<->controller association is inferred by spatial+temporal
 *     proximity, NOT a real frequency assignment. We label flights as
 *     "aircraft in the controlled airspace", never "aircraft this controller
 *     talked to". Actual ATC instructions are not available.
 *
 * All timestamps from the backend are epoch ms UTC. 1 nm = 1852 m.
 */
export const ATCReplay = (() => {
    const BACKEND = (typeof window !== 'undefined' && window.APP_CONFIG?.backendUrl)
        || 'https://site--acars-backend--6dmjph8ltlhv.code.run';
    const NM_TO_M = 1852;

    // ---- module state -----------------------------------------------------
    let rootEl = null;          // full-screen overlay root
    let map = null;             // this overlay's own mapbox map
    let searchTimer = null;     // debounce handle for the search box
    let searchSeq = 0;          // guards against out-of-order search responses

    // Player state (populated by selectSession)
    let replay = null;          // full /api/atc/replay payload
    let timelineStart = 0;
    let timelineEnd = 0;
    let playhead = 0;           // current scrub time (epoch ms)
    let playing = false;
    let speed = 5;              // playback multiplier of real time
    let lastFrameWall = 0;      // wall-clock of previous rAF
    let rafId = null;
    const flightMarkers = new Map(); // flightId -> mapboxgl.Marker

    // =======================================================================
    // Styles
    // =======================================================================
    function injectStyles() {
        if (document.getElementById('atc-replay-styles')) return;
        const css = `
        .atcr-overlay{position:fixed;inset:0;z-index:100000;background:#0b1018;
            color:#e6edf6;font-family:Inter,system-ui,sans-serif;display:flex;
            flex-direction:column;animation:atcrFade .18s ease;}
        @keyframes atcrFade{from{opacity:0}to{opacity:1}}
        .atcr-header{display:flex;align-items:center;gap:12px;padding:14px 16px;
            padding-top:calc(14px + env(safe-area-inset-top,0px));
            background:rgba(11,16,24,.92);border-bottom:1px solid rgba(255,255,255,.08);}
        .atcr-title{font-weight:700;font-size:1.05rem;letter-spacing:.2px;flex:0 0 auto;}
        .atcr-title i{color:#38bdf8;margin-right:7px;}
        .atcr-close{margin-left:auto;background:rgba(255,255,255,.06);border:none;
            color:#e6edf6;width:36px;height:36px;border-radius:50%;font-size:1rem;
            cursor:pointer;}
        .atcr-close:active{background:rgba(255,255,255,.14);}
        .atcr-search-wrap{position:relative;flex:1 1 auto;max-width:420px;}
        .atcr-search{width:100%;box-sizing:border-box;background:rgba(0,0,0,.35);
            border:1px solid rgba(255,255,255,.14);border-radius:10px;color:#fff;
            padding:9px 12px 9px 34px;font-size:.9rem;outline:none;}
        .atcr-search:focus{border-color:#38bdf8;}
        .atcr-search-wrap > i{position:absolute;left:11px;top:50%;transform:translateY(-50%);
            color:#7d8aa0;font-size:.85rem;pointer-events:none;}
        .atcr-body{flex:1 1 auto;min-height:0;display:flex;flex-direction:column;}
        /* --- session list --- */
        .atcr-list{flex:1 1 auto;overflow-y:auto;padding:12px;display:flex;
            flex-direction:column;gap:10px;-webkit-overflow-scrolling:touch;}
        .atcr-card{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.07);
            border-radius:14px;padding:13px 14px;cursor:pointer;transition:.12s;}
        .atcr-card:active{background:rgba(56,189,248,.12);border-color:rgba(56,189,248,.5);}
        .atcr-card-top{display:flex;align-items:center;gap:8px;margin-bottom:4px;}
        .atcr-card-user{font-weight:700;font-size:.98rem;}
        .atcr-live{font-size:.62rem;font-weight:800;letter-spacing:.6px;color:#0b1018;
            background:#22c55e;padding:2px 6px;border-radius:5px;}
        .atcr-card-airport{color:#aab6c8;font-size:.84rem;margin-bottom:6px;}
        .atcr-chips{display:flex;flex-wrap:wrap;gap:5px;margin-bottom:6px;}
        .atcr-chip{font-size:.7rem;font-weight:600;background:rgba(56,189,248,.14);
            color:#7fd4ff;border:1px solid rgba(56,189,248,.25);padding:2px 8px;border-radius:999px;}
        .atcr-card-meta{display:flex;gap:14px;color:#7d8aa0;font-size:.74rem;}
        .atcr-empty{margin:auto;text-align:center;color:#7d8aa0;padding:40px 24px;max-width:320px;}
        .atcr-empty i{font-size:2rem;color:#3a4760;display:block;margin-bottom:12px;}
        .atcr-spinner{width:26px;height:26px;border:3px solid rgba(255,255,255,.15);
            border-top-color:#38bdf8;border-radius:50%;animation:atcrSpin .8s linear infinite;
            margin:30px auto;}
        @keyframes atcrSpin{to{transform:rotate(360deg)}}
        /* --- player --- */
        .atcr-player{flex:1 1 auto;min-height:0;display:flex;flex-direction:column;}
        .atcr-map{flex:1 1 auto;min-height:0;}
        .atcr-disclaimer{font-size:.68rem;color:#9aa6b8;background:rgba(0,0,0,.35);
            padding:7px 14px;border-top:1px solid rgba(255,255,255,.06);line-height:1.35;}
        .atcr-freqbar{display:flex;flex-wrap:wrap;gap:6px;padding:10px 14px;
            background:rgba(11,16,24,.9);border-top:1px solid rgba(255,255,255,.06);}
        .atcr-freq{font-size:.74rem;font-weight:600;padding:4px 10px;border-radius:8px;
            background:rgba(255,255,255,.06);color:#6b7689;border:1px solid transparent;transition:.15s;}
        .atcr-freq.on{background:rgba(34,197,94,.18);color:#7ef0a6;border-color:rgba(34,197,94,.4);}
        .atcr-controls{padding:12px 14px calc(14px + env(safe-area-inset-bottom,0px));
            background:rgba(11,16,24,.95);border-top:1px solid rgba(255,255,255,.08);}
        .atcr-scrub-row{display:flex;align-items:center;gap:10px;}
        .atcr-play{background:#38bdf8;border:none;color:#06121f;width:42px;height:42px;
            border-radius:50%;font-size:1rem;cursor:pointer;flex:0 0 auto;}
        .atcr-play:active{filter:brightness(.9);}
        .atcr-scrub{flex:1 1 auto;accent-color:#38bdf8;height:6px;}
        .atcr-time{font-variant-numeric:tabular-nums;font-size:.74rem;color:#aab6c8;
            min-width:58px;text-align:center;}
        .atcr-bottom-row{display:flex;align-items:center;justify-content:space-between;margin-top:10px;}
        .atcr-speeds{display:flex;gap:6px;}
        .atcr-speed{font-size:.74rem;font-weight:700;background:rgba(255,255,255,.06);
            border:1px solid rgba(255,255,255,.1);color:#aab6c8;padding:5px 10px;border-radius:8px;cursor:pointer;}
        .atcr-speed.on{background:#38bdf8;color:#06121f;border-color:#38bdf8;}
        .atcr-flightcount{font-size:.74rem;color:#7d8aa0;}
        .atcr-back{background:rgba(255,255,255,.06);border:none;color:#e6edf6;
            border-radius:8px;padding:6px 12px;font-size:.8rem;cursor:pointer;}
        /* map markers */
        .atcr-fac-marker{width:18px;height:18px;border-radius:50%;background:#38bdf8;
            border:3px solid #0b1018;box-shadow:0 0 0 2px #38bdf8;}
        .atcr-plane{font-size:18px;color:#fff;text-shadow:0 0 3px #000,0 0 6px #000;
            transform-origin:center;will-change:transform;}
        .atcr-plane.arr{color:#fbbf24;}
        .atcr-toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);
            background:rgba(0,0,0,.85);color:#fff;padding:10px 16px;border-radius:10px;
            font-size:.85rem;z-index:100001;border:1px solid rgba(255,255,255,.12);}
        `;
        const el = document.createElement('style');
        el.id = 'atc-replay-styles';
        el.textContent = css;
        document.head.appendChild(el);
    }

    function toast(msg) {
        const t = document.createElement('div');
        t.className = 'atcr-toast';
        t.textContent = msg;
        document.body.appendChild(t);
        setTimeout(() => t.remove(), 2600);
    }

    // =======================================================================
    // Formatting helpers
    // =======================================================================
    function fmtTime(ms) {
        try {
            return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        } catch { return ''; }
    }
    function fmtRange(start, end) {
        return `${fmtTime(start)}–${fmtTime(end)}`;
    }
    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"]/g, c =>
            ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    }

    // GeoJSON polygon approximating a circle of `radiusNm` around [lon,lat].
    function circlePolygon(lon, lat, radiusNm, steps = 96) {
        const coords = [];
        const radM = radiusNm * NM_TO_M;
        const earth = 6378137;
        const latR = lat * Math.PI / 180;
        for (let i = 0; i <= steps; i++) {
            const theta = (i / steps) * 2 * Math.PI;
            const dx = radM * Math.cos(theta);
            const dy = radM * Math.sin(theta);
            const dLon = (dx / (earth * Math.cos(latR))) * 180 / Math.PI;
            const dLat = (dy / earth) * 180 / Math.PI;
            coords.push([lon + dLon, lat + dLat]);
        }
        return { type: 'Feature', geometry: { type: 'Polygon', coordinates: [coords] }, properties: {} };
    }

    // =======================================================================
    // Networking
    // =======================================================================
    async function fetchSessions(query) {
        const params = new URLSearchParams();
        if (query) params.set('user', query);
        params.set('limit', '60');
        const url = query
            ? `${BACKEND}/api/atc/sessions?${params}`
            : `${BACKEND}/api/atc/sessions/recent?limit=50`;
        const res = await fetch(url);
        if (!res.ok) throw new Error(`sessions ${res.status}`);
        const json = await res.json();
        return Array.isArray(json.sessions) ? json.sessions : [];
    }

    async function fetchReplay(key) {
        const res = await fetch(`${BACKEND}/api/atc/replay?key=${encodeURIComponent(key)}`);
        if (res.status === 404) { const e = new Error('expired'); e.code = 404; throw e; }
        if (!res.ok) throw new Error(`replay ${res.status}`);
        return res.json();
    }

    // =======================================================================
    // Search screen
    // =======================================================================
    function renderSearchShell() {
        rootEl.querySelector('.atcr-body').innerHTML = `
            <div class="atcr-list" id="atcr-list">
                <div class="atcr-spinner"></div>
            </div>`;
    }

    function sessionCard(s) {
        const freqs = (s.frequencies || []).join(' + ') || 'ATC';
        const live = s.open ? `<span class="atcr-live">LIVE</span>` : '';
        return `
            <div class="atcr-card" data-key="${esc(s.key)}">
                <div class="atcr-card-top">
                    <span class="atcr-card-user">${esc(s.username || s.userId || 'Controller')}</span>
                    ${live}
                </div>
                <div class="atcr-card-airport"><i class="fa-solid fa-tower-control" style="margin-right:6px;color:#7d8aa0;"></i>${esc(s.airportName || 'Unknown airport')}</div>
                <div class="atcr-chips">
                    ${(s.frequencies || []).map(f => `<span class="atcr-chip">${esc(f)}</span>`).join('') || `<span class="atcr-chip">${esc(freqs)}</span>`}
                </div>
                <div class="atcr-card-meta">
                    <span><i class="fa-regular fa-clock"></i> ${fmtRange(s.start, s.open ? Date.now() : s.end)}</span>
                    <span><i class="fa-solid fa-hourglass-half"></i> ${s.durationMin != null ? s.durationMin + ' min' : ''}</span>
                </div>
            </div>`;
    }

    async function runSearch(query) {
        const seq = ++searchSeq;
        const list = rootEl.querySelector('#atcr-list');
        if (!list) return;
        list.innerHTML = `<div class="atcr-spinner"></div>`;
        let sessions = [];
        try {
            sessions = await fetchSessions(query);
        } catch (err) {
            if (seq !== searchSeq) return;
            list.innerHTML = `<div class="atcr-empty"><i class="fa-solid fa-triangle-exclamation"></i>
                Couldn't reach the replay service. Check your connection and try again.</div>`;
            return;
        }
        if (seq !== searchSeq) return; // a newer search superseded this one
        if (!sessions.length) {
            list.innerHTML = `<div class="atcr-empty"><i class="fa-solid fa-satellite-dish"></i>
                No recorded sessions${query ? ' for "' + esc(query) + '"' : ''}.<br>
                <span style="font-size:.78rem;">Replay covers the last 48 hours.</span></div>`;
            return;
        }
        list.innerHTML = sessions.map(sessionCard).join('');
        list.querySelectorAll('.atcr-card').forEach(card => {
            card.addEventListener('click', () => selectSession(card.dataset.key, card));
        });
    }

    // =======================================================================
    // Replay player
    // =======================================================================
    async function selectSession(key, cardEl) {
        let payload;
        try {
            payload = await fetchReplay(key);
        } catch (err) {
            if (err.code === 404) {
                toast('This session expired (outside the 48h window).');
                if (cardEl) cardEl.remove();
            } else {
                toast('Could not load replay.');
            }
            return;
        }
        replay = payload;
        buildPlayer();
    }

    function buildPlayer() {
        const c = replay.controller;
        const win = c.window || {};
        timelineStart = win.start;
        timelineEnd = c.open ? Date.now() : win.end;
        playhead = timelineStart;
        playing = false;

        rootEl.querySelector('.atcr-body').innerHTML = `
            <div class="atcr-player">
                <div class="atcr-map" id="atcr-map"></div>
                <div class="atcr-disclaimer">
                    Showing <strong>${replay.flightCount || 0}</strong> aircraft within
                    ${c.searchRadiusNm} nm of ${esc(c.airportName || 'the facility')} during this session.
                    These are aircraft <em>in the controlled airspace</em> — inferred by proximity,
                    not a record of who the controller talked to. Actual ATC instructions aren't available.
                </div>
                <div class="atcr-freqbar" id="atcr-freqbar"></div>
                <div class="atcr-controls">
                    <div class="atcr-scrub-row">
                        <button class="atcr-play" id="atcr-play"><i class="fa-solid fa-play"></i></button>
                        <span class="atcr-time" id="atcr-time-start">${fmtTime(timelineStart)}</span>
                        <input type="range" class="atcr-scrub" id="atcr-scrub" min="0" max="1000" value="0">
                        <span class="atcr-time" id="atcr-time-end">${fmtTime(timelineEnd)}</span>
                    </div>
                    <div class="atcr-bottom-row">
                        <button class="atcr-back" id="atcr-back"><i class="fa-solid fa-arrow-left"></i> Sessions</button>
                        <span class="atcr-flightcount">${replay.flightCount || 0} aircraft</span>
                        <div class="atcr-speeds">
                            ${[1, 5, 30].map(s => `<button class="atcr-speed ${s === speed ? 'on' : ''}" data-speed="${s}">${s}×</button>`).join('')}
                        </div>
                    </div>
                </div>
            </div>`;

        // header title -> controller summary; hide the search box while playing
        const searchWrap = rootEl.querySelector('.atcr-search-wrap');
        if (searchWrap) searchWrap.style.display = 'none';

        renderFreqBar();
        wirePlayerControls();
        initMap();
    }

    function wirePlayerControls() {
        rootEl.querySelector('#atcr-back').addEventListener('click', showSearch);
        const playBtn = rootEl.querySelector('#atcr-play');
        playBtn.addEventListener('click', togglePlay);
        const scrub = rootEl.querySelector('#atcr-scrub');
        scrub.addEventListener('input', () => {
            const f = Number(scrub.value) / 1000;
            playhead = timelineStart + f * (timelineEnd - timelineStart);
            renderFrame();
        });
        rootEl.querySelectorAll('.atcr-speed').forEach(btn => {
            btn.addEventListener('click', () => {
                speed = Number(btn.dataset.speed);
                rootEl.querySelectorAll('.atcr-speed').forEach(b => b.classList.toggle('on', b === btn));
            });
        });
    }

    function togglePlay() {
        playing = !playing;
        const icon = rootEl.querySelector('#atcr-play i');
        if (icon) icon.className = playing ? 'fa-solid fa-pause' : 'fa-solid fa-play';
        if (playing) {
            // Loop back to start if we're parked at the very end.
            if (playhead >= timelineEnd) playhead = timelineStart;
            lastFrameWall = performance.now();
            rafId = requestAnimationFrame(tick);
        } else if (rafId) {
            cancelAnimationFrame(rafId);
            rafId = null;
        }
    }

    function tick(now) {
        if (!playing) return;
        const dtWall = now - lastFrameWall;
        lastFrameWall = now;
        playhead += dtWall * speed; // advance scaled real time
        if (playhead >= timelineEnd) {
            playhead = timelineEnd;
            renderFrame();
            togglePlay(); // auto-pause at the end
            return;
        }
        renderFrame();
        rafId = requestAnimationFrame(tick);
    }

    // ---- map --------------------------------------------------------------
    function initMap() {
        const c = replay.controller;
        if (typeof mapboxgl === 'undefined') {
            toast('Map library unavailable.');
            return;
        }
        if (!mapboxgl.accessToken) {
            mapboxgl.accessToken = window.CONFIG?.MAPBOX_TOKEN || '';
        }
        map = new mapboxgl.Map({
            container: 'atcr-map',
            style: 'mapbox://styles/mapbox/dark-v11',
            center: [c.lon, c.lat],
            zoom: c.searchRadiusNm > 100 ? 5 : c.searchRadiusNm > 30 ? 7 : 9,
            attributionControl: false
        });

        map.on('load', () => {
            // coverage ring
            map.addSource('atcr-ring', { type: 'geojson', data: circlePolygon(c.lon, c.lat, c.searchRadiusNm) });
            map.addLayer({ id: 'atcr-ring-fill', type: 'fill', source: 'atcr-ring',
                paint: { 'fill-color': '#38bdf8', 'fill-opacity': 0.07 } });
            map.addLayer({ id: 'atcr-ring-line', type: 'line', source: 'atcr-ring',
                paint: { 'line-color': '#38bdf8', 'line-width': 1.5, 'line-opacity': 0.6 } });

            // facility marker
            const facEl = document.createElement('div');
            facEl.className = 'atcr-fac-marker';
            new mapboxgl.Marker({ element: facEl }).setLngLat([c.lon, c.lat]).addTo(map);

            // fit to the ring
            try {
                const ring = circlePolygon(c.lon, c.lat, c.searchRadiusNm).geometry.coordinates[0];
                const b = ring.reduce((bb, p) => bb.extend(p),
                    new mapboxgl.LngLatBounds(ring[0], ring[0]));
                map.fitBounds(b, { padding: 40, duration: 0 });
            } catch { /* keep default center */ }

            renderFrame();
        });
    }

    // Interpolate one flight's position at time t (epoch ms). Returns null if
    // the flight wasn't present yet / had already left.
    function flightAt(flight, t) {
        const pts = flight.path;
        if (!pts || !pts.length) return null;
        if (t < pts[0].time || t > pts[pts.length - 1].time) return null;
        let i = 0;
        while (i < pts.length - 1 && pts[i + 1].time < t) i++;
        const a = pts[i], b = pts[Math.min(i + 1, pts.length - 1)];
        const f = b.time === a.time ? 0 : (t - a.time) / (b.time - a.time);
        return {
            lat: a.lat + (b.lat - a.lat) * f,
            lon: a.lon + (b.lon - a.lon) * f,
            heading: a.hdg
        };
    }

    function renderFrame() {
        // clamp + scrub + clock
        playhead = Math.max(timelineStart, Math.min(timelineEnd, playhead));
        const span = timelineEnd - timelineStart || 1;
        const scrub = rootEl.querySelector('#atcr-scrub');
        if (scrub) scrub.value = String(Math.round(((playhead - timelineStart) / span) * 1000));
        const startLbl = rootEl.querySelector('#atcr-time-start');
        if (startLbl) startLbl.textContent = fmtTime(playhead);

        // frequency chips
        const bar = rootEl.querySelector('#atcr-freqbar');
        if (bar) {
            (replay.controller.frequencies || []).forEach((fr, idx) => {
                const chip = bar.children[idx];
                if (!chip) return;
                const end = fr.end || Date.now();
                chip.classList.toggle('on', fr.start <= playhead && playhead <= end);
            });
        }

        if (!map || !map.loaded()) return;

        // flights
        (replay.flights || []).forEach(flight => {
            const pos = flightAt(flight, playhead);
            let marker = flightMarkers.get(flight.flightId);
            if (!pos) {
                if (marker) { marker.remove(); flightMarkers.delete(flight.flightId); }
                return;
            }
            if (!marker) {
                const el = document.createElement('div');
                el.className = 'atcr-plane' + (flight.atAirport ? ' arr' : '');
                el.innerHTML = '<i class="fa-solid fa-plane-up"></i>';
                el.title = flight.callsign || flight.flightId;
                marker = new mapboxgl.Marker({ element: el, rotationAlignment: 'map' });
                marker.setLngLat([pos.lon, pos.lat]).addTo(map);
                flightMarkers.set(flight.flightId, marker);
            }
            marker.setLngLat([pos.lon, pos.lat]);
            marker.setRotation((pos.heading || 0));
        });
    }

    function renderFreqBar() {
        const bar = rootEl.querySelector('#atcr-freqbar');
        if (!bar) return;
        bar.innerHTML = (replay.controller.frequencies || [])
            .map(fr => `<span class="atcr-freq">${esc(fr.type)}</span>`).join('')
            || `<span class="atcr-freq">No frequency intervals</span>`;
    }

    function clearMarkers() {
        flightMarkers.forEach(m => m.remove());
        flightMarkers.clear();
    }

    function destroyPlayer() {
        if (rafId) { cancelAnimationFrame(rafId); rafId = null; }
        playing = false;
        clearMarkers();
        if (map) { try { map.remove(); } catch { /* noop */ } map = null; }
        replay = null;
    }

    // =======================================================================
    // Screen switching
    // =======================================================================
    function showSearch() {
        destroyPlayer();
        const searchWrap = rootEl.querySelector('.atcr-search-wrap');
        if (searchWrap) searchWrap.style.display = '';
        const input = rootEl.querySelector('.atcr-search');
        renderSearchShell();
        runSearch(input ? input.value.trim() : '');
    }

    // =======================================================================
    // Public: open / close
    // =======================================================================
    function open() {
        if (rootEl) return;
        injectStyles();
        rootEl = document.createElement('div');
        rootEl.className = 'atcr-overlay';
        rootEl.innerHTML = `
            <div class="atcr-header">
                <div class="atcr-title"><i class="fa-solid fa-headset"></i>ATC Replay</div>
                <div class="atcr-search-wrap">
                    <i class="fa-solid fa-magnifying-glass"></i>
                    <input class="atcr-search" type="search" placeholder="Search controller (e.g. delta)…"
                        autocomplete="off" autocapitalize="off" spellcheck="false">
                </div>
                <button class="atcr-close" aria-label="Close"><i class="fa-solid fa-xmark"></i></button>
            </div>
            <div class="atcr-body"></div>`;
        document.body.appendChild(rootEl);

        rootEl.querySelector('.atcr-close').addEventListener('click', close);
        const input = rootEl.querySelector('.atcr-search');
        input.addEventListener('input', () => {
            clearTimeout(searchTimer);
            searchTimer = setTimeout(() => runSearch(input.value.trim()), 280);
        });

        renderSearchShell();
        runSearch(''); // recent sessions feed
    }

    function close() {
        if (!rootEl) return;
        clearTimeout(searchTimer);
        destroyPlayer();
        rootEl.remove();
        rootEl = null;
    }

    return { open, close, isOpen: () => !!rootEl };
})();

if (typeof window !== 'undefined') window.ATCReplay = ATCReplay;
