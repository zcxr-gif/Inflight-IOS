// flightReplay.js
// Self-contained flight replay/playback. Animates a marker along a flight's
// historical track on the main mapbox-gl map, with play/pause/scrub/speed UI.
// Includes a premium interactive, zoomable, multi-axis telemetry chart.
//
// Public API:
//   FlightReplay.open({ map, flightId, points?, meta?, historyUrl? })
//   FlightReplay.close()
//   FlightReplay.isOpen()

const SPEED_OPTIONS = [1, 2, 5, 10, 30, 60];

export const FlightReplay = (() => {
    // ---------- state ----------
    let map = null;
    let currentFlightId = null;
    let currentMeta = null;
    let points = [];                
    let totalDurationMs = 0;
    let currentMs = 0;              
    let speed = 1;
    let isPlaying = false;
    let isScrubbing = false;
    let lastTickWall = 0;
    let rafHandle = null;
    let marker = null;
    let panelEl = null;
    let pathSourceId = null;
    let pathLayerId = null;

    // Chart & Camera State
    let chartExpanded = false;
    let chartViewStart = 0;
    let chartViewEnd = 0;
    let isChartPanning = false;
    let isCameraLocked = false;

    // Traffic-hiding state (hides every other live aircraft on the map while
    // a replay is active so the user can focus on the replayed flight).
    let isTrafficHidden = false;
    let prevTrafficFilters = null;   // { layerId: <previous mapbox filter or null> }
    let onCloseCallback = null;      // fired after close() finishes cleanup

    // Live flown-path hiding state. Independent of the toggle above — this
    // suppresses the *replayed* flight's own live trail (and live icon, via
    // the filter logic) so the replay's re-drawn path stands alone.
    let liveFlownPathHidden = false;
    let prevLiveFlownPathVisibility = null;

    // Layer IDs we manage when hiding/showing other live flights. Kept here
    // (rather than hardcoded inline) so the list stays easy to maintain.
    const TRAFFIC_LAYER_IDS = [
        'sector-ops-live-flights-layer',
        'sector-ops-live-flights-hover-layer',
        'sector-ops-live-flights-labels'
    ];

    // ---------- premium color mapping ----------
    function getAltColor(alt) {
        const stops = [
            [0,     [56, 189, 248]],   // Sky Blue
            [10000, [45, 212, 191]],   // Teal
            [20000, [163, 230, 53]],   // Lime
            [30000, [250, 204, 21]],   // Amber
            [40000, [244, 63, 94]]     // Rose
        ];
        const clampAlt = Math.max(0, Math.min(40000, alt || 0));
        let s1 = stops[0], s2 = stops[stops.length - 1];
        
        for (let i = 0; i < stops.length - 1; i++) {
            if (clampAlt >= stops[i][0] && clampAlt <= stops[i+1][0]) {
                s1 = stops[i];
                s2 = stops[i+1];
                break;
            }
        }
        
        const range = s2[0] - s1[0];
        const f = range === 0 ? 0 : (clampAlt - s1[0]) / range;
        const r = Math.round(s1[1][0] + (s2[1][0] - s1[1][0]) * f);
        const g = Math.round(s1[1][1] + (s2[1][1] - s1[1][1]) * f);
        const b = Math.round(s1[1][2] + (s2[1][2] - s1[1][2]) * f);
        
        return `rgb(${r}, ${g}, ${b})`;
    }

    // ---------- styles (injected once) ----------
    function injectStyles() {
        if (document.getElementById('flight-replay-styles')) return;
        const style = document.createElement('style');
        style.id = 'flight-replay-styles';
        style.textContent = `
            #flight-replay-panel {
                position: fixed;
                left: 50%;
                bottom: 24px;
                transform: translateX(-50%);
                width: min(740px, calc(100vw - 32px));
                background: rgba(30, 31, 32, 0.94);
                border: 1px solid rgba(255, 255, 255, 0.15);
                border-radius: 16px;
                backdrop-filter: blur(18px);
                -webkit-backdrop-filter: blur(18px);
                box-shadow: 0 20px 60px rgba(0, 0, 0, 0.6), 0 0 40px rgba(255, 255, 255, 0.05);
                color: #ffffff;
                font-family: 'Inter', system-ui, -apple-system, sans-serif;
                z-index: 9000;
                padding: 14px 18px 12px;
                display: flex;
                flex-direction: column;
                gap: 10px;
                transition: width 0.35s cubic-bezier(0.4, 0, 0.2, 1);
                animation: replay-slide-up 220ms ease-out;
            }
            #flight-replay-panel.panel-maximized {
                width: min(1000px, calc(100vw - 32px));
            }
            @keyframes replay-slide-up {
                from { transform: translate(-50%, 24px); opacity: 0; }
                to   { transform: translate(-50%, 0);    opacity: 1; }
            }
            #flight-replay-panel .replay-header {
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 12px;
            }
            #flight-replay-panel .replay-title {
                display: flex;
                align-items: center;
                gap: 10px;
                font-weight: 700;
                font-size: 13px;
                letter-spacing: 0.3px;
            }
            #flight-replay-panel .replay-title i {
                color: #ffffff;
                font-size: 14px;
            }
            #flight-replay-panel .replay-callsign {
                color: #ffffff;
                font-family: 'JetBrains Mono', ui-monospace, monospace;
            }
            #flight-replay-panel .replay-route {
                color: #9aa0a6;
                font-size: 11px;
                font-weight: 500;
                font-family: 'JetBrains Mono', ui-monospace, monospace;
            }
            #flight-replay-panel .replay-close {
                background: rgba(255, 255, 255, 0.06);
                border: 1px solid rgba(255, 255, 255, 0.12);
                color: #e8eaed;
                width: 28px;
                height: 28px;
                border-radius: 50%;
                cursor: pointer;
                display: grid;
                place-items: center;
                transition: all 0.15s ease;
            }
            #flight-replay-panel .replay-close:hover {
                background: rgba(255, 255, 255, 0.15);
                color: #ffffff;
                border-color: rgba(255, 255, 255, 0.3);
            }
            #flight-replay-panel .replay-hud {
                display: grid;
                grid-template-columns: repeat(4, 1fr);
                gap: 8px;
                padding: 8px 0 4px;
            }
            #flight-replay-panel .hud-stat {
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 2px;
                padding: 6px 4px;
                background: rgba(0, 0, 0, 0.3);
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 8px;
            }
            #flight-replay-panel .hud-stat label {
                font-size: 9px;
                font-weight: 700;
                letter-spacing: 0.8px;
                color: #9aa0a6;
            }
            #flight-replay-panel .hud-stat span {
                font-family: 'JetBrains Mono', ui-monospace, monospace;
                font-size: 16px;
                font-weight: 700;
                color: #ffffff;
                line-height: 1;
            }
            #flight-replay-panel .hud-stat small {
                font-size: 9px;
                color: #9aa0a6;
                font-weight: 600;
            }
            #flight-replay-panel .replay-controls {
                display: flex;
                align-items: center;
                gap: 10px;
            }
            #flight-replay-panel .replay-btn {
                background: rgba(255, 255, 255, 0.08);
                border: 1px solid rgba(255, 255, 255, 0.2);
                color: #ffffff;
                width: 34px;
                height: 34px;
                border-radius: 50%;
                cursor: pointer;
                display: grid;
                place-items: center;
                transition: all 0.15s ease;
                flex-shrink: 0;
            }
            #flight-replay-panel .replay-btn:hover {
                background: rgba(255, 255, 255, 0.15);
                transform: scale(1.05);
            }
            #flight-replay-panel .replay-play-pause {
                background: #ffffff;
                color: #1e1f20;
                width: 38px;
                height: 38px;
                border-color: #ffffff;
            }
            #flight-replay-panel .replay-play-pause:hover {
                background: #e8eaed;
            }
            #flight-replay-panel .camera-lock-toggle.active,
            #flight-replay-panel .hide-traffic-toggle.active {
                background: #ffffff;
                color: #1e1f20;
                border-color: #ffffff;
                box-shadow: 0 0 10px rgba(255, 255, 255, 0.5);
            }
            #flight-replay-panel .chart-toggle {
                background: rgba(255, 255, 255, 0.08);
                border: 1px solid rgba(255, 255, 255, 0.2);
                color: #ffffff;
            }
            #flight-replay-panel .chart-toggle:hover,
            #flight-replay-panel .chart-toggle.active {
                background: #ffffff;
                border-color: #ffffff;
                color: #1e1f20;
            }
            #flight-replay-panel .replay-time {
                font-family: 'JetBrains Mono', ui-monospace, monospace;
                font-size: 11px;
                font-weight: 600;
                color: #e8eaed;
                min-width: 44px;
                text-align: center;
            }
            #flight-replay-panel .replay-time-total { color: #9aa0a6; }
            #flight-replay-panel .replay-scrubber {
                flex: 1;
                -webkit-appearance: none;
                appearance: none;
                height: 4px;
                background: rgba(255, 255, 255, 0.15);
                border-radius: 4px;
                outline: none;
                cursor: pointer;
            }
            #flight-replay-panel .replay-scrubber::-webkit-slider-thumb {
                -webkit-appearance: none;
                appearance: none;
                width: 14px;
                height: 14px;
                border-radius: 50%;
                background: #ffffff;
                box-shadow: 0 0 8px rgba(255, 255, 255, 0.6);
                cursor: grab;
            }
            #flight-replay-panel .replay-scrubber::-moz-range-thumb {
                width: 14px;
                height: 14px;
                border-radius: 50%;
                background: #ffffff;
                box-shadow: 0 0 8px rgba(255, 255, 255, 0.6);
                cursor: grab;
                border: none;
            }
            #flight-replay-panel .replay-speed-wrap {
                display: flex;
                gap: 2px;
                background: rgba(0, 0, 0, 0.3);
                border-radius: 8px;
                padding: 2px;
                flex-shrink: 0;
            }
            #flight-replay-panel .replay-speed-btn {
                background: transparent;
                border: none;
                color: #9aa0a6;
                font-size: 10px;
                font-weight: 700;
                font-family: 'JetBrains Mono', ui-monospace, monospace;
                padding: 4px 6px;
                border-radius: 6px;
                cursor: pointer;
                transition: all 0.12s ease;
                min-width: 26px;
            }
            #flight-replay-panel .replay-speed-btn:hover { color: #ffffff; }
            #flight-replay-panel .replay-speed-btn.active {
                background: rgba(255, 255, 255, 0.15);
                color: #ffffff;
            }

            /* Expandable Chart Drawer */
            #flight-replay-panel .replay-chart-drawer {
                height: 0px;
                opacity: 0;
                overflow: hidden;
                transition: height 0.35s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.2s ease, margin 0.3s ease;
                display: flex;
                flex-direction: column;
                position: relative;
            }
            #flight-replay-panel .replay-chart-drawer.expanded {
                height: 140px; /* Squeezed View */
                opacity: 1;
                margin-top: 8px;
                border-top: 1px solid rgba(255, 255, 255, 0.1);
            }
            #flight-replay-panel .replay-chart-drawer.expanded.maximized {
                height: 300px; /* Expanded View */
            }

            /* Size Toggle Button */
            #flight-replay-panel .chart-size-btn {
                position: absolute;
                top: 12px;
                right: 6px;
                background: rgba(255, 255, 255, 0.05);
                border: 1px solid rgba(255, 255, 255, 0.15);
                color: #9aa0a6;
                width: 26px;
                height: 26px;
                border-radius: 6px;
                cursor: pointer;
                display: grid;
                place-items: center;
                z-index: 10;
                font-size: 12px;
                transition: all 0.15s ease;
            }
            #flight-replay-panel .chart-size-btn:hover {
                background: rgba(255, 255, 255, 0.15);
                color: #fff;
            }
            
            #flight-replay-panel .replay-chart-canvas {
                width: 100%;
                height: 100%;
                cursor: grab;
                display: block;
                border-radius: 6px;
                margin-top: 4px; 
            }
            #flight-replay-panel .replay-chart-canvas:active {
                cursor: grabbing;
            }

            #flight-replay-panel .chart-legend {
                position: absolute;
                top: 16px;
                left: 8px;
                display: flex;
                gap: 14px;
                font-size: 9px;
                font-weight: 700;
                font-family: 'JetBrains Mono', monospace;
                pointer-events: none;
                text-shadow: 0 1px 3px rgba(0,0,0,0.9);
            }
            #flight-replay-panel .legend-alt { 
                background: linear-gradient(90deg, #38bdf8, #a3e635, #f43f5e);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
            }
            #flight-replay-panel .legend-spd { color: rgba(255, 255, 255, 0.5); }
            #flight-replay-panel .legend-hdg { color: rgba(255, 255, 255, 0.25); }
            #flight-replay-panel .legend-hint { 
                position: absolute;
                bottom: 8px;
                right: 8px;
                color: #9aa0a6; 
                font-style: italic;
                font-weight: 500;
                font-size: 9px;
                font-family: 'Inter', sans-serif;
                pointer-events: none;
            }

            /* Marker */
            .flight-replay-marker {
                width: 36px;
                height: 36px;
                pointer-events: none;
                position: relative;
            }
            .flight-replay-marker .replay-pulse {
                position: absolute;
                inset: 0;
                border-radius: 50%;
                background: rgba(255, 255, 255, 0.25);
                animation: replay-pulse 1.6s ease-out infinite;
            }
            @keyframes replay-pulse {
                0%   { transform: scale(0.6); opacity: 0.8; }
                100% { transform: scale(1.8); opacity: 0; }
            }
            .flight-replay-marker .replay-plane {
                position: absolute;
                inset: 0;
                display: grid;
                place-items: center;
                color: #ffffff;
                font-size: 18px;
                filter: drop-shadow(0 0 6px rgba(255, 255, 255, 0.9));
            }

            /* Toast */
            .flight-replay-toast {
                position: fixed;
                top: 24px;
                left: 50%;
                transform: translateX(-50%);
                background: rgba(30, 31, 32, 0.95);
                border: 1px solid rgba(255, 255, 255, 0.2);
                color: #ffffff;
                padding: 10px 18px;
                border-radius: 10px;
                font-family: 'Inter', sans-serif;
                font-size: 13px;
                font-weight: 600;
                z-index: 9001;
                box-shadow: 0 10px 30px rgba(0,0,0,0.5);
                transition: opacity 0.4s ease, transform 0.4s ease;
            }
            .flight-replay-toast.fade-out {
                opacity: 0;
                transform: translate(-50%, -8px);
            }

            /* ============================================================
               Mobile / narrow-screen layout
               --------------------------------------------------------------
               Re-flows the controls into two rows so all 5 transport
               buttons + the speed picker remain reachable on a phone
               without making the buttons "gigantic". Touch targets stay
               in the 30–34px range — small but comfortably tappable.
               ============================================================ */
            @media (max-width: 640px) {
                #flight-replay-panel {
                    /* Pin to the side gutters instead of horizontally
                       centering — lets us reclaim the slack the desktop
                       layout gives up to translateX(-50%). */
                    left: 8px;
                    right: 8px;
                    bottom: calc(8px + env(safe-area-inset-bottom, 0px));
                    transform: none;
                    width: auto;
                    padding: 10px 12px;
                    gap: 8px;
                    border-radius: 14px;
                    /* Override the desktop slide-up that animates
                       translate(-50%, …) — that math doesn't apply here. */
                    animation: replay-slide-up-mobile 220ms ease-out;
                }
                /* The maximized state doesn't widen the panel on mobile —
                   we're already at the full available width. */
                #flight-replay-panel.panel-maximized { width: auto; }

                @keyframes replay-slide-up-mobile {
                    from { transform: translateY(24px); opacity: 0; }
                    to   { transform: translateY(0);    opacity: 1; }
                }

                /* Header — drop the route, keep the callsign */
                #flight-replay-panel .replay-title { font-size: 12px; gap: 8px; }
                #flight-replay-panel .replay-title i { font-size: 13px; }
                #flight-replay-panel .replay-route { display: none; }
                #flight-replay-panel .replay-close { width: 26px; height: 26px; }

                /* HUD — keep all 4 stats visible, just tighter type & padding */
                #flight-replay-panel .replay-hud {
                    gap: 6px;
                    padding: 4px 0 2px;
                }
                #flight-replay-panel .hud-stat {
                    padding: 5px 2px;
                    gap: 1px;
                }
                #flight-replay-panel .hud-stat label {
                    font-size: 8px;
                    letter-spacing: 0.6px;
                }
                #flight-replay-panel .hud-stat span { font-size: 13px; }
                #flight-replay-panel .hud-stat small { font-size: 8px; }

                /* Controls — switch from a single flex row to a 2-row CSS
                   grid so the scrubber gets its own dedicated full-width
                   track and the 5 transport buttons line up underneath
                   with the speed picker pushed to the right.

                       Row 1:  [elapsed] [—— scrubber ——] [total]
                       Row 2:  [back][play][cam][traf][chart] … [speed]

                   Col 6 is a 1fr spring that absorbs slack between the
                   button cluster and the speed picker. */
                #flight-replay-panel .replay-controls {
                    display: grid;
                    grid-template-columns: auto auto auto auto auto 1fr auto;
                    gap: 8px 6px;
                    align-items: center;
                }
                #flight-replay-panel .replay-time[data-hud="elapsed"] {
                    grid-row: 1; grid-column: 1;
                }
                #flight-replay-panel .replay-scrubber {
                    grid-row: 1; grid-column: 2 / 7;
                    height: 6px; /* a touch fatter for thumb precision */
                }
                #flight-replay-panel .replay-time-total {
                    grid-row: 1; grid-column: 7;
                }
                #flight-replay-panel .replay-restart       { grid-row: 2; grid-column: 1; }
                #flight-replay-panel .replay-play-pause    { grid-row: 2; grid-column: 2; }
                #flight-replay-panel .camera-lock-toggle   { grid-row: 2; grid-column: 3; }
                #flight-replay-panel .hide-traffic-toggle  { grid-row: 2; grid-column: 4; }
                #flight-replay-panel .chart-toggle         { grid-row: 2; grid-column: 5; }
                #flight-replay-panel .replay-speed-wrap {
                    grid-row: 2; grid-column: 7;
                    justify-self: end;
                }

                /* Buttons — compact but still comfortably tappable.
                   Deliberately NOT inflated for "mobile" — the goal is a
                   tidy panel, not a wall of giant chunky buttons. */
                #flight-replay-panel .replay-btn {
                    width: 32px;
                    height: 32px;
                }
                #flight-replay-panel .replay-play-pause {
                    width: 34px;
                    height: 34px;
                }

                /* Slightly larger scrubber thumb so a fingertip can grab it
                   reliably without the button growing visually huge. */
                #flight-replay-panel .replay-scrubber::-webkit-slider-thumb {
                    width: 18px;
                    height: 18px;
                }
                #flight-replay-panel .replay-scrubber::-moz-range-thumb {
                    width: 18px;
                    height: 18px;
                }

                /* Speed picker — keep all 6 options on one row, just tighter.
                   (The original mobile rule hid this entirely, which dropped
                   speed control on the floor — we keep it accessible.) */
                #flight-replay-panel .replay-speed-wrap { padding: 1px; gap: 1px; }
                #flight-replay-panel .replay-speed-btn {
                    font-size: 9px;
                    padding: 3px 4px;
                    min-width: 20px;
                }

                #flight-replay-panel .replay-time {
                    font-size: 10px;
                    min-width: 36px;
                }

                /* Chart drawer — shorter so it doesn't dominate the screen */
                #flight-replay-panel .replay-chart-drawer.expanded { height: 120px; }
                #flight-replay-panel .replay-chart-drawer.expanded.maximized { height: 220px; }
                #flight-replay-panel .chart-size-btn {
                    width: 24px; height: 24px;
                    top: 10px; right: 4px;
                    font-size: 11px;
                }
                #flight-replay-panel .chart-legend {
                    font-size: 8px;
                    gap: 10px;
                    top: 14px;
                    left: 6px;
                }
                #flight-replay-panel .legend-hint { display: none; }

                /* Let the JS pan/zoom listeners fully own touch on the chart
                   instead of the browser hijacking it for native scrolling. */
                #flight-replay-panel .replay-chart-canvas {
                    touch-action: none;
                }
            }

            /* ============================================================
               Sub-380px (iPhone SE-class). The 7-column grid above gets
               cramped when both the button cluster and the 6-option speed
               picker have to fit on one row — so on the very narrowest
               phones we drop the speed picker onto its own centered row.
               ============================================================ */
            @media (max-width: 380px) {
                #flight-replay-panel .hud-stat span { font-size: 12px; }
                #flight-replay-panel .hud-stat label { font-size: 7px; }

                #flight-replay-panel .replay-controls {
                    grid-template-columns: auto auto auto auto auto;
                    gap: 6px 4px;
                }
                #flight-replay-panel .replay-scrubber    { grid-column: 2 / 5; }
                #flight-replay-panel .replay-time-total  { grid-column: 5; }
                #flight-replay-panel .replay-restart      { grid-row: 2; grid-column: 1; }
                #flight-replay-panel .replay-play-pause   { grid-row: 2; grid-column: 2; }
                #flight-replay-panel .camera-lock-toggle  { grid-row: 2; grid-column: 3; }
                #flight-replay-panel .hide-traffic-toggle { grid-row: 2; grid-column: 4; }
                #flight-replay-panel .chart-toggle        { grid-row: 2; grid-column: 5; }
                #flight-replay-panel .replay-speed-wrap {
                    grid-row: 3;
                    grid-column: 1 / -1;
                    justify-self: center;
                    margin-top: 2px;
                }

                #flight-replay-panel .replay-btn        { width: 30px; height: 30px; }
                #flight-replay-panel .replay-play-pause { width: 32px; height: 32px; }
            }
        `;
        document.head.appendChild(style);
    }

    // ---------- map interaction breaker ----------
    function handleUserMapInteraction(e) {
        // Break lock only if interaction is driven by the user (has an original event)
        if (e.originalEvent && isCameraLocked) {
            isCameraLocked = false;
            if (panelEl) {
                const btn = panelEl.querySelector('.camera-lock-toggle');
                if (btn) btn.classList.remove('active');
            }
        }
    }

    // ---------- traffic visibility helpers ----------
    // While the replay is on screen, the *live* presence of the replayed
    // aircraft (its real-time icon, its trailing flown path) is suppressed
    // — the replay's own marker and re-drawn path stand in for them.
    //
    // The user-facing toggle ("hide other aircraft") only controls whether
    // *every other* live flight on the map is hidden too; the replayed
    // flight's own live icon is hidden in either state of that toggle.
    //
    //  Toggle ON  (default): filter shows nothing at all.
    //  Toggle OFF:           filter shows everything except the replayed flight.
    //
    // The original filter on each managed layer is captured the first time
    // we touch it and put back verbatim on close, so any tactical filters
    // the user had set up before opening the replay survive untouched.

    // Build the mapbox filter expression that matches "everything except the
    // replayed flight". If the user already had a filter on the layer, we
    // preserve it by AND-ing the two together — that way an existing
    // tactical filter (e.g. "Delta only") still takes effect, just minus
    // the replayed plane.
    function buildExcludeReplayedFilter(prevFilter) {
        const exclude = ['!=', ['get', 'flightId'], currentFlightId];
        if (!prevFilter) return exclude;
        return ['all', prevFilter, exclude];
    }

    // Filter that matches no flight at all. We use a sentinel rather than
    // setLayoutProperty(visibility=none) because Mapbox's hover/symbol
    // pickers behave more predictably when a layer is filter-empty than
    // when it's marked invisible.
    const HIDE_ALL_FILTER = ['==', ['get', 'flightId'], '__none__'];

    // Apply the right filter to every managed layer based on whether the
    // user has the toggle set to hide other planes too. Saves the previous
    // filter on first call so we can restore it when the replay closes.
    function applyTrafficFilter() {
        if (!map || !currentFlightId) return;

        // First-time entry: capture each layer's pre-replay filter so we can
        // put it back exactly as-is in restoreOtherTraffic().
        if (!prevTrafficFilters) {
            prevTrafficFilters = {};
            TRAFFIC_LAYER_IDS.forEach(id => {
                if (!map.getLayer || !map.getLayer(id)) return;
                try {
                    prevTrafficFilters[id] = map.getFilter(id) || null;
                } catch (_) {
                    prevTrafficFilters[id] = null;
                }
            });
        }

        TRAFFIC_LAYER_IDS.forEach(id => {
            if (!map.getLayer || !map.getLayer(id)) return;
            try {
                const filter = isTrafficHidden
                    ? HIDE_ALL_FILTER
                    : buildExcludeReplayedFilter(prevTrafficFilters[id]);
                map.setFilter(id, filter);
            } catch (err) {
                console.warn(`[FlightReplay] Could not apply traffic filter on ${id}:`, err);
            }
        });
    }

    // Hide every live flight on the map except the one we're replaying — and
    // since the replayed flight's live icon is suppressed independently, in
    // practice this hides every live aircraft for the duration of the
    // replay. Idempotent: safe to call repeatedly.
    function hideOtherTraffic() {
        if (!map || !currentFlightId) return;
        isTrafficHidden = true;
        applyTrafficFilter();
    }

    // Toggle off the "hide all" mode but leave the replayed flight's own
    // live icon hidden (so the replay marker doesn't compete with a live
    // icon for the same flight).
    function showOtherTraffic() {
        if (!map || !currentFlightId) return;
        isTrafficHidden = false;
        applyTrafficFilter();
    }

    // Reverse of any traffic filtering: put each layer's filter back to
    // whatever it was before we touched it. If the previous filter was
    // undefined/null, we clear our sentinel filter entirely.
    function restoreOtherTraffic() {
        if (!map || !prevTrafficFilters) return;

        TRAFFIC_LAYER_IDS.forEach(id => {
            if (!map.getLayer || !map.getLayer(id)) return;
            try {
                map.setFilter(id, prevTrafficFilters[id] || null);
            } catch (err) {
                console.warn(`[FlightReplay] Could not restore traffic on layer ${id}:`, err);
            }
        });

        prevTrafficFilters = null;
        isTrafficHidden = false;
    }

    // ---------- live flown-path visibility ----------
    // The host page renders a multi-coloured "flown path" trail behind the
    // live aircraft on a layer named `flown-path-<flightId>`. While replay
    // is up, that trail would compete with the replay's own re-drawn path,
    // so we hide it via the layer's `visibility` layout property and put it
    // back when the replay closes.
    function hideLiveFlownPath() {
        if (!map || !currentFlightId || liveFlownPathHidden) return;
        const layerId = `flown-path-${currentFlightId}`;
        if (!map.getLayer || !map.getLayer(layerId)) return;
        try {
            // Save current visibility (default is 'visible' if unset).
            prevLiveFlownPathVisibility = map.getLayoutProperty(layerId, 'visibility') || 'visible';
            map.setLayoutProperty(layerId, 'visibility', 'none');
            liveFlownPathHidden = true;
        } catch (err) {
            console.warn(`[FlightReplay] Could not hide live flown path:`, err);
        }
    }

    function restoreLiveFlownPath() {
        if (!map || !currentFlightId || !liveFlownPathHidden) return;
        const layerId = `flown-path-${currentFlightId}`;
        if (map.getLayer && map.getLayer(layerId)) {
            try {
                map.setLayoutProperty(layerId, 'visibility', prevLiveFlownPathVisibility || 'visible');
            } catch (err) {
                console.warn(`[FlightReplay] Could not restore live flown path:`, err);
            }
        }
        prevLiveFlownPathVisibility = null;
        liveFlownPathHidden = false;
    }

    // ---------- data normalization ----------
    function normalizePoints(raw) {
        let rejected = 0;
        const norm = (raw || []).map(p => {
            if (!p || typeof p !== 'object') { rejected++; return null; }
            const pos = (p.position && typeof p.position === 'object') ? p.position : p;

            const pickNum = (...candidates) => {
                for (const v of candidates) if (typeof v === 'number' && !isNaN(v)) return v;
                return null;
            };

            const lat = pickNum(pos.lat, pos.latitude, p.lat, p.latitude);
            const lon = pickNum(pos.lon, pos.longitude, p.lon, p.longitude);
            const altitude = pickNum(pos.alt, pos.altitude, pos.alt_ft, p.alt, p.altitude, p.alt_ft);
            const groundSpeed = pickNum(pos.gs, pos.groundSpeed, pos.gs_kt, p.gs, p.groundSpeed, p.gs_kt);
            const track = pickNum(pos.hdg, pos.heading, pos.track, pos.heading_deg, p.hdg, p.heading, p.track, p.heading_deg);

            let t = NaN;
            const timeCandidates = [
                pos.time, pos.lastReportMs, pos.timeMs,
                p.time,   p.lastReportMs,   p.timeMs,
                pos.date, pos.timestamp, pos.lastReport,
                p.date,   p.timestamp,   p.lastReport
            ];
            for (const v of timeCandidates) {
                if (typeof v === 'number' && !isNaN(v)) { t = v; break; }
                if (typeof v === 'string' && v) {
                    const parsed = Date.parse(v);
                    if (!isNaN(parsed)) { t = parsed; break; }
                }
            }

            if (typeof lat !== 'number' || typeof lon !== 'number' || isNaN(t)) {
                rejected++;
                return null;
            }
            return { lat, lon, altitude, groundSpeed, track, t };
        }).filter(Boolean);

        norm.sort((a, b) => a.t - b.t);

        const out = [];
        for (const p of norm) {
            if (!out.length || p.t !== out[out.length - 1].t) out.push(p);
        }
        if (rejected > 0) {
            console.warn(`[FlightReplay] Rejected ${rejected} of ${(raw || []).length} points during normalization.`);
        }
        return out;
    }

    // ---------- interpolation ----------
    function pointAtSimulatedMs(simMs) {
        if (!points.length) return null;
        const baseT = points[0].t;
        const targetT = baseT + simMs;
        if (targetT <= points[0].t) return { ...points[0] };
        if (targetT >= points[points.length - 1].t) return { ...points[points.length - 1] };

        let lo = 0, hi = points.length - 1;
        while (lo + 1 < hi) {
            const mid = (lo + hi) >> 1;
            if (points[mid].t <= targetT) lo = mid; else hi = mid;
        }
        const a = points[lo], b = points[hi];
        const span = b.t - a.t || 1;
        const f = (targetT - a.t) / span;

        let track = a.track;
        if (typeof a.track === 'number' && typeof b.track === 'number') {
            let delta = b.track - a.track;
            if (delta > 180) delta -= 360;
            else if (delta < -180) delta += 360;
            track = (a.track + delta * f + 360) % 360;
        } else if (typeof b.track === 'number') {
            track = b.track;
        }

        const lerp = (x, y) => (typeof x === 'number' && typeof y === 'number')
            ? x + (y - x) * f
            : (typeof y === 'number' ? y : x);

        return {
            lat: a.lat + (b.lat - a.lat) * f,
            lon: a.lon + (b.lon - a.lon) * f,
            altitude: lerp(a.altitude, b.altitude),
            groundSpeed: lerp(a.groundSpeed, b.groundSpeed),
            track,
            t: targetT
        };
    }

    // ---------- map layers ----------
    function ensurePathLayer() {
        if (!map) return;
        pathSourceId = `replay-path-source-${currentFlightId}`;
        pathLayerId = `replay-path-layer-${currentFlightId}`;
        if (!map.getSource(pathSourceId)) {
            map.addSource(pathSourceId, {
                type: 'geojson',
                data: { type: 'FeatureCollection', features: [] }
            });
        }
        if (!map.getLayer(pathLayerId)) {
            map.addLayer({
                id: pathLayerId,
                type: 'line',
                source: pathSourceId,
                layout: { 'line-cap': 'round', 'line-join': 'round' },
                paint: {
                    'line-color': ['get', 'color'],
                    'line-width': 4,
                    'line-opacity': 0.95
                }
            });
        }
    }

    function updatePathTo(simMs) {
        if (!map || !pathSourceId) return;
        const src = map.getSource(pathSourceId);
        if (!src) return;
        
        const cutoff = points[0].t + simMs;
        const features = [];
        
        for (let i = 0; i < points.length - 1; i++) {
            const p1 = points[i];
            if (p1.t > cutoff) break;
            
            let p2 = points[i+1];
            let isLastSegment = false;
            
            if (p2.t > cutoff) {
                p2 = pointAtSimulatedMs(simMs);
                if (!p2) break;
                isLastSegment = true;
            }

            features.push({
                type: 'Feature',
                geometry: {
                    type: 'LineString',
                    coordinates: [[p1.lon, p1.lat], [p2.lon, p2.lat]]
                },
                properties: {
                    color: getAltColor(p1.altitude)
                }
            });

            if (isLastSegment) break;
        }

        src.setData({
            type: 'FeatureCollection',
            features: features
        });
    }

    function ensureMarker() {
        if (!map.getSource('flight-replay-plane-source')) {
            map.addSource('flight-replay-plane-source', {
                type: 'geojson',
                data: {
                    type: 'Feature',
                    geometry: { type: 'Point', coordinates: [points[0].lon, points[0].lat] },
                    properties: { heading: points[0].track || points[0].heading_deg || 0 }
                }
            });
        }

        if (!map.getLayer('flight-replay-plane-layer')) {
            const cat = currentMeta?.category || 'B737';
            map.addLayer({
                id: 'flight-replay-plane-layer',
                type: 'symbol',
                source: 'flight-replay-plane-source',
                layout: {
                    'icon-image': `icon-${cat}`, 
                    'icon-rotate': ['get', 'heading'],
                    'icon-rotation-alignment': 'map',
                    'icon-allow-overlap': true,
                    'icon-ignore-placement': true,
                    'icon-size': window.mapFilters?.planeIconSize || 0.15 
                },
                paint: {
                    'icon-color': '#ffffff' 
                }
            });
        }

        if (!marker) {
            const el = document.createElement('div');
            el.className = 'flight-replay-marker';
            el.innerHTML = `<div class="replay-pulse"></div>`; 
            marker = new mapboxgl.Marker({ element: el, rotationAlignment: 'map' })
                .setLngLat([points[0].lon, points[0].lat])
                .addTo(map);
        }
    }

    function setMarkerTo(p) {
        if (!marker || !p) return;
        
        marker.setLngLat([p.lon, p.lat]);
        if (typeof p.track === 'number') marker.setRotation(p.track);

        if (map && map.getSource('flight-replay-plane-source')) {
            map.getSource('flight-replay-plane-source').setData({
                type: 'Feature',
                geometry: { type: 'Point', coordinates: [p.lon, p.lat] },
                properties: { heading: p.track || 0 }
            });
        }
    }

    // ---------- Chart Utilities ----------
    function clampChartView() {
        const span = chartViewEnd - chartViewStart;
        if (chartViewStart < 0) {
            chartViewStart = 0;
            chartViewEnd = Math.min(totalDurationMs, span);
        }
        if (chartViewEnd > totalDurationMs) {
            chartViewEnd = totalDurationMs;
            chartViewStart = Math.max(0, chartViewEnd - span);
        }
    }

    function drawChart() {
        if (!panelEl || !chartExpanded) return;
        const drawer = panelEl.querySelector('.replay-chart-drawer');
        if (!drawer.classList.contains('expanded')) return;

        const canvas = panelEl.querySelector('.replay-chart-canvas');
        const ctx = canvas.getContext('2d');
        const dpr = window.devicePixelRatio || 1;
        const rect = canvas.getBoundingClientRect();

        canvas.width = rect.width * dpr;
        canvas.height = rect.height * dpr;
        ctx.scale(dpr, dpr);

        const w = rect.width;
        const h = rect.height;

        ctx.clearRect(0, 0, w, h);

        if (!points || points.length < 2) return;

        // 1. Identify bounds within the zoomed view
        const absStart = points[0].t + chartViewStart;
        const absEnd = points[0].t + chartViewEnd;

        let minAlt = Infinity, maxAlt = -Infinity;
        let minSpd = Infinity, maxSpd = -Infinity;

        let startIndex = points.findIndex(p => p.t >= absStart) - 1;
        if (startIndex < 0) startIndex = 0;
        let endIndex = points.findIndex(p => p.t > absEnd);
        if (endIndex === -1) endIndex = points.length - 1;

        const viewPoints = points.slice(startIndex, endIndex + 1);
        if (viewPoints.length === 0) return;

        for (const p of viewPoints) {
            if (p.altitude < minAlt) minAlt = p.altitude;
            if (p.altitude > maxAlt) maxAlt = p.altitude;
            if (p.groundSpeed < minSpd) minSpd = p.groundSpeed;
            if (p.groundSpeed > maxSpd) maxSpd = p.groundSpeed;
        }

        // Add padding
        const altPad = Math.max(100, (maxAlt - minAlt) * 0.1);
        minAlt = Math.max(0, minAlt - altPad);
        maxAlt += altPad;

        const spdPad = Math.max(20, (maxSpd - minSpd) * 0.1);
        minSpd = Math.max(0, minSpd - spdPad);
        maxSpd += spdPad;

        // Scaling Helpers
        const timeToX = (t) => (((t - points[0].t) - chartViewStart) / (chartViewEnd - chartViewStart)) * w;
        const altToY = (a) => h - ((a - minAlt) / (maxAlt - minAlt || 1)) * (h - 10) - 5;
        const spdToY = (s) => h - ((s - minSpd) / (maxSpd - minSpd || 1)) * (h - 10) - 5;
        const hdgToY = (hdg) => h - (hdg / 360) * h;

        // 2. Draw Subtle Fill underneath Altitude
        ctx.beginPath();
        ctx.moveTo(timeToX(viewPoints[0].t), h);
        for (const p of viewPoints) {
            ctx.lineTo(timeToX(p.t), altToY(p.altitude));
        }
        ctx.lineTo(timeToX(viewPoints[viewPoints.length-1].t), h);
        ctx.closePath();

        const altGrad = ctx.createLinearGradient(0, 0, 0, h);
        altGrad.addColorStop(0, 'rgba(255, 255, 255, 0.08)');
        altGrad.addColorStop(1, 'rgba(255, 255, 255, 0.0)');
        ctx.fillStyle = altGrad;
        ctx.fill();

        // 3. Draw Altitude Segmented Line (Mapped to Color)
        ctx.lineWidth = 2;
        ctx.lineJoin = 'round';
        ctx.lineCap = 'round';
        for (let i = 0; i < viewPoints.length - 1; i++) {
            const p1 = viewPoints[i];
            const p2 = viewPoints[i+1];
            ctx.beginPath();
            ctx.moveTo(timeToX(p1.t), altToY(p1.altitude));
            ctx.lineTo(timeToX(p2.t), altToY(p2.altitude));
            ctx.strokeStyle = getAltColor(p1.altitude);
            ctx.stroke();
        }

        // 4. Draw Heading (Smart wrapping around 360)
        ctx.beginPath();
        for (let i = 0; i < viewPoints.length; i++) {
            const p = viewPoints[i];
            const x = timeToX(p.t);
            const y = hdgToY(p.track || p.heading_deg || 0);

            if (i === 0) {
                ctx.moveTo(x, y);
            } else {
                const prev = viewPoints[i-1];
                const diff = Math.abs((p.track || 0) - (prev.track || 0));
                if (diff > 180) ctx.moveTo(x, y); 
                else ctx.lineTo(x, y);
            }
        }
        ctx.strokeStyle = 'rgba(255, 255, 255, 0.25)'; 
        ctx.lineWidth = 1.5;
        ctx.setLineDash([3, 4]); 
        ctx.stroke();
        ctx.setLineDash([]);

        // 5. Draw Speed Line
        ctx.beginPath();
        for (const p of viewPoints) {
            ctx.lineTo(timeToX(p.t), spdToY(p.groundSpeed));
        }
        ctx.strokeStyle = 'rgba(255, 255, 255, 0.5)'; 
        ctx.lineWidth = 1.5;
        ctx.lineJoin = 'round';
        ctx.stroke();

        // 6. Draw the Playhead / Tracker
        const playX = timeToX(points[0].t + currentMs);
        if (playX >= 0 && playX <= w) {
            ctx.beginPath();
            ctx.moveTo(playX, 0);
            ctx.lineTo(playX, h);
            ctx.strokeStyle = 'rgba(255, 255, 255, 0.8)';
            ctx.lineWidth = 1;
            ctx.stroke();

            const curPoint = pointAtSimulatedMs(currentMs);
            if (curPoint) {
                const curAltY = altToY(curPoint.altitude);
                ctx.beginPath();
                ctx.arc(playX, curAltY, 4.5, 0, Math.PI * 2);
                ctx.fillStyle = '#fff';
                ctx.fill();
                ctx.shadowBlur = 10;
                ctx.shadowColor = getAltColor(curPoint.altitude);
                ctx.stroke();
                ctx.shadowBlur = 0; 
            }
        }

        // 7. Y-Axis Grid labels
        ctx.fillStyle = 'rgba(255, 255, 255, 0.4)';
        ctx.font = '9px "JetBrains Mono", monospace';
        ctx.textAlign = 'right';
        ctx.fillText(Math.round(maxAlt) + 'ft', w - 4, 12); 
        ctx.fillText(Math.round(minAlt) + 'ft', w - 4, h - 6);
    }

    // ---------- animation loop ----------
    function tick() {
        rafHandle = null;
        if (!isPlaying) return;
        const now = performance.now();
        const dt = now - lastTickWall;
        lastTickWall = now;
        currentMs = Math.min(totalDurationMs, currentMs + dt * speed);

        renderFrame();

        if (currentMs >= totalDurationMs) {
            pause();
        } else {
            rafHandle = requestAnimationFrame(tick);
        }
    }

    function renderFrame() {
        const cur = pointAtSimulatedMs(currentMs);
        if (!cur) return;
        setMarkerTo(cur);
        updatePathTo(currentMs);
        updateHUD(cur);

        // Map lock-on logic
        if (isCameraLocked && map) {
            map.jumpTo({ center: [cur.lon, cur.lat] });
        }
        
        if (!isScrubbing) {
            updateScrubber();
        }

        if (chartExpanded) {
            if (isPlaying && !isChartPanning) {
                const span = chartViewEnd - chartViewStart;
                if (currentMs > chartViewEnd - span * 0.05) {
                    chartViewStart += span * 0.2;
                    chartViewEnd += span * 0.2;
                    clampChartView();
                } else if (currentMs < chartViewStart) {
                    chartViewStart = currentMs - span * 0.1;
                    chartViewEnd = chartViewStart + span;
                    clampChartView();
                }
            }
            drawChart();
        }
    }

    // ---------- formatting ----------
    function fmtClock(ms) {
        const totalSec = Math.max(0, Math.floor(ms / 1000));
        const h = Math.floor(totalSec / 3600);
        const m = Math.floor((totalSec % 3600) / 60);
        const s = totalSec % 60;
        return h > 0
            ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
            : `${m}:${String(s).padStart(2, '0')}`;
    }

    function fmtZulu(epochMs) {
        const d = new Date(epochMs);
        const hh = String(d.getUTCHours()).padStart(2, '0');
        const mm = String(d.getUTCMinutes()).padStart(2, '0');
        const ss = String(d.getUTCSeconds()).padStart(2, '0');
        return `${hh}:${mm}:${ss}Z`;
    }

    // ---------- panel ----------
    function buildPanel() {
        if (panelEl) return panelEl;
        panelEl = document.createElement('div');
        panelEl.id = 'flight-replay-panel';
        const callsign = (currentMeta && currentMeta.callsign) || 'REPLAY';
        const dep = (currentMeta && currentMeta.depIcao) || '----';
        const arr = (currentMeta && currentMeta.arrIcao) || '----';
        panelEl.innerHTML = `
            <div class="replay-header">
                <div class="replay-title">
                    <i class="fa-solid fa-circle-play"></i>
                    <span class="replay-callsign">${callsign}</span>
                    <span class="replay-route">${dep} → ${arr}</span>
                </div>
                <button class="replay-close" title="Close Replay">
                    <i class="fa-solid fa-xmark"></i>
                </button>
            </div>
            <div class="replay-hud">
                <div class="hud-stat"><label>ALT</label><span data-hud="alt">--</span><small>ft</small></div>
                <div class="hud-stat"><label>GS</label><span data-hud="gs">--</span><small>kt</small></div>
                <div class="hud-stat"><label>HDG</label><span data-hud="hdg">--</span><small>°</small></div>
                <div class="hud-stat"><label>UTC</label><span data-hud="utc">--:--</span><small>z</small></div>
            </div>
            <div class="replay-controls">
                <button class="replay-btn replay-restart" title="Restart">
                    <i class="fa-solid fa-backward-step"></i>
                </button>
                <button class="replay-btn replay-play-pause" title="Play / Pause">
                    <i class="fa-solid fa-play"></i>
                </button>
                <button class="replay-btn camera-lock-toggle" title="Follow Plane">
                    <i class="fa-solid fa-crosshairs"></i>
                </button>
                <button class="replay-btn hide-traffic-toggle active" title="Hide Other Aircraft">
                    <i class="fa-solid fa-eye-slash"></i>
                </button>
                <button class="replay-btn chart-toggle" title="Toggle Stats Chart">
                    <i class="fa-solid fa-chart-area"></i>
                </button>
                <div class="replay-time" data-hud="elapsed">0:00</div>
                <input type="range" class="replay-scrubber" min="0" max="1000" value="0" step="1">
                <div class="replay-time replay-time-total" data-hud="total">0:00</div>
                <div class="replay-speed-wrap">
                    ${SPEED_OPTIONS.map(s =>
                        `<button class="replay-speed-btn${s === 1 ? ' active' : ''}" data-speed="${s}">${s}×</button>`
                    ).join('')}
                </div>
            </div>
            <div class="replay-chart-drawer">
                <button class="chart-size-btn" title="Toggle Size">
                    <i class="fa-solid fa-expand"></i>
                </button>
                <div class="chart-legend">
                    <span class="legend-alt">■ ALT</span>
                    <span class="legend-spd">■ SPD</span>
                    <span class="legend-hdg">■ HDG</span>
                </div>
                <canvas class="replay-chart-canvas"></canvas>
                <span class="legend-hint">Scroll to Zoom, Drag to Pan</span>
            </div>
        `;
        document.body.appendChild(panelEl);

        // Core Event Listeners
        panelEl.querySelector('.replay-close').addEventListener('click', () => close());
        panelEl.querySelector('.replay-play-pause').addEventListener('click', () => {
            isPlaying ? pause() : play();
        });
        panelEl.querySelector('.replay-restart').addEventListener('click', () => {
            currentMs = 0;
            renderFrame();
        });

        // Camera Lock Toggle Button
        const lockBtn = panelEl.querySelector('.camera-lock-toggle');
        lockBtn.addEventListener('click', () => {
            isCameraLocked = !isCameraLocked;
            lockBtn.classList.toggle('active', isCameraLocked);
            if (isCameraLocked && map) {
                const cur = pointAtSimulatedMs(currentMs);
                if (cur) map.flyTo({ center: [cur.lon, cur.lat], duration: 800, zoom: Math.max(map.getZoom(), 8) });
            }
        });

        // Hide Other Traffic Toggle Button
        // Defaults to ON when the replay opens (set up in `open()`); clicking
        // it toggles whether every other live aircraft is hidden from the
        // map. The replayed flight's own live icon stays hidden in either
        // state — the replay marker takes its place.
        const hideTrafficBtn = panelEl.querySelector('.hide-traffic-toggle');
        hideTrafficBtn.addEventListener('click', () => {
            if (isTrafficHidden) {
                showOtherTraffic();
                hideTrafficBtn.classList.remove('active');
                hideTrafficBtn.title = 'Hide Other Aircraft';
                hideTrafficBtn.querySelector('i').className = 'fa-solid fa-eye-slash';
            } else {
                hideOtherTraffic();
                hideTrafficBtn.classList.add('active');
                hideTrafficBtn.title = 'Show Other Aircraft';
                hideTrafficBtn.querySelector('i').className = 'fa-solid fa-eye';
            }
        });

        // HTML Range Scrubber (for seeking)
        const slider = panelEl.querySelector('.replay-scrubber');
        slider.addEventListener('pointerdown', () => { isScrubbing = true; });
        const endScrub = () => { isScrubbing = false; };
        slider.addEventListener('pointerup', endScrub);
        slider.addEventListener('pointercancel', endScrub);
        slider.addEventListener('input', (e) => {
            const ratio = Number(e.target.value) / 1000;
            currentMs = Math.max(0, Math.min(totalDurationMs, ratio * totalDurationMs));
            renderFrame();
        });

        // Speed Buttons
        panelEl.querySelectorAll('.replay-speed-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                speed = Number(btn.dataset.speed);
                panelEl.querySelectorAll('.replay-speed-btn').forEach(b =>
                    b.classList.toggle('active', b === btn)
                );
            });
        });

        // Chart Toggle Button
        const toggleBtn = panelEl.querySelector('.chart-toggle');
        const drawer = panelEl.querySelector('.replay-chart-drawer');
        toggleBtn.addEventListener('click', () => {
            chartExpanded = !chartExpanded;
            toggleBtn.classList.toggle('active', chartExpanded);
            drawer.classList.toggle('expanded', chartExpanded);
            if (chartExpanded) {
                setTimeout(() => drawChart(), 350); 
            }
        });

        // Chart Size Toggle Button (Height + Width Expansion)
        const sizeBtn = panelEl.querySelector('.chart-size-btn');
        sizeBtn.addEventListener('click', () => {
            drawer.classList.toggle('maximized');
            panelEl.classList.toggle('panel-maximized'); // Squeeze/Expand sides
            const icon = sizeBtn.querySelector('i');
            if (drawer.classList.contains('maximized')) {
                icon.className = 'fa-solid fa-compress';
            } else {
                icon.className = 'fa-solid fa-expand';
            }
            setTimeout(() => drawChart(), 350);
        });

        // Initialize Chart Events (Zoom, Pan)
        bindChartEvents();

        window.addEventListener('resize', handleWindowResize);

        return panelEl;
    }

    function handleWindowResize() {
        if (chartExpanded) drawChart();
    }
    
    function bindChartEvents() {
        const canvas = panelEl.querySelector('.replay-chart-canvas');
        let panStartX = 0;
        let panStartChartStart = 0;
        let panStartChartEnd = 0;
        
        // 1. Zoom (Squeeze/Expand timeline horizontally)
        canvas.addEventListener('wheel', (e) => {
            e.preventDefault();
            const rect = canvas.getBoundingClientRect();
            const mouseRatio = (e.clientX - rect.left) / rect.width;
            const mouseMs = chartViewStart + mouseRatio * (chartViewEnd - chartViewStart);

            const zoomFactor = e.deltaY > 0 ? 1.25 : 0.8;
            let span = (chartViewEnd - chartViewStart) * zoomFactor;
            
            // Constrain zoom levels (min 10s, max total duration)
            span = Math.max(10000, Math.min(totalDurationMs, span)); 

            chartViewStart = mouseMs - mouseRatio * span;
            chartViewEnd = chartViewStart + span;
            
            clampChartView();
            drawChart();
        });

        // 2. Drag to Pan Left/Right
        canvas.addEventListener('pointerdown', (e) => {
            isChartPanning = true;
            panStartX = e.clientX;
            panStartChartStart = chartViewStart;
            panStartChartEnd = chartViewEnd;
            canvas.setPointerCapture(e.pointerId);
        });

        canvas.addEventListener('pointermove', (e) => {
            if (!isChartPanning) return;
            const rect = canvas.getBoundingClientRect();
            const dx = e.clientX - panStartX;
            
            // how many ms does 1 pixel represent?
            const msPerPx = (panStartChartEnd - panStartChartStart) / rect.width;
            const msShift = dx * msPerPx;
            
            chartViewStart = panStartChartStart - msShift;
            chartViewEnd = panStartChartEnd - msShift;
            
            clampChartView();
            drawChart();
        });

        const stopPan = (e) => {
            if (!isChartPanning) return;
            isChartPanning = false;
            canvas.releasePointerCapture(e.pointerId);
        };

        canvas.addEventListener('pointerup', stopPan);
        canvas.addEventListener('pointercancel', stopPan);
    }

    function updateHUD(cur) {
        if (!panelEl || !cur) return;
        panelEl.querySelector('[data-hud="alt"]').textContent =
            (typeof cur.altitude === 'number') ? Math.round(cur.altitude).toLocaleString() : '--';
        panelEl.querySelector('[data-hud="gs"]').textContent =
            (typeof cur.groundSpeed === 'number') ? Math.round(cur.groundSpeed) : '--';
        panelEl.querySelector('[data-hud="hdg"]').textContent =
            (typeof cur.track === 'number') ? String(Math.round(cur.track)).padStart(3, '0') : '--';
        panelEl.querySelector('[data-hud="utc"]').textContent = fmtZulu(cur.t);
    }

    function updateScrubber() {
        if (!panelEl) return;
        const ratio = totalDurationMs > 0 ? currentMs / totalDurationMs : 0;
        const slider = panelEl.querySelector('.replay-scrubber');
        slider.value = String(Math.round(ratio * 1000));
        panelEl.querySelector('[data-hud="elapsed"]').textContent = fmtClock(currentMs);
    }

    function setPlayPauseIcon() {
        if (!panelEl) return;
        const ic = panelEl.querySelector('.replay-play-pause i');
        if (ic) ic.className = isPlaying ? 'fa-solid fa-pause' : 'fa-solid fa-play';
    }

    // ---------- public API ----------
    function play() {
        if (!points.length) return;
        if (currentMs >= totalDurationMs) currentMs = 0;
        isPlaying = true;
        lastTickWall = performance.now();
        setPlayPauseIcon();
        if (!rafHandle) rafHandle = requestAnimationFrame(tick);
    }

    function pause() {
        isPlaying = false;
        if (rafHandle) {
            cancelAnimationFrame(rafHandle);
            rafHandle = null;
        }
        setPlayPauseIcon();
    }

    function close() {
        pause();
        window.removeEventListener('resize', handleWindowResize);

        // Restore everything we changed on the host map BEFORE we tear down
        // the replay's own map bits — these need `map` to still be valid.
        restoreOtherTraffic();
        restoreLiveFlownPath();

        if (map) {
            // Remove breakaway listeners
            map.off('mousedown', handleUserMapInteraction);
            map.off('touchstart', handleUserMapInteraction);
            map.off('wheel', handleUserMapInteraction);

            if (pathLayerId && map.getLayer && map.getLayer(pathLayerId)) {
                try { map.removeLayer(pathLayerId); } catch (_) {}
            }
            if (pathSourceId && map.getSource && map.getSource(pathSourceId)) {
                try { map.removeSource(pathSourceId); } catch (_) {}
            }
            if (map.getLayer && map.getLayer('flight-replay-plane-layer')) {
                try { map.removeLayer('flight-replay-plane-layer'); } catch (_) {}
            }
            if (map.getSource && map.getSource('flight-replay-plane-source')) {
                try { map.removeSource('flight-replay-plane-source'); } catch (_) {}
            }
        }

        if (marker) {
            try { marker.remove(); } catch (_) {}
            marker = null;
        }

        pathLayerId = null;
        pathSourceId = null;
        if (panelEl) {
            panelEl.remove();
            panelEl = null;
        }
        currentFlightId = null;
        currentMeta = null;
        points = [];
        totalDurationMs = 0;
        currentMs = 0;
        speed = 1;
        isScrubbing = false;
        isChartPanning = false;
        isCameraLocked = false;
        isTrafficHidden = false;
        prevTrafficFilters = null;
        liveFlownPathHidden = false;
        prevLiveFlownPathVisibility = null;

        // Fire the consumer's onClose hook last, so the host page can restore
        // its own UI (e.g. re-open the flight info window) only after the
        // replay has fully torn itself down. We null the reference first so
        // a callback that itself triggers another open/close cannot recurse.
        const cb = onCloseCallback;
        onCloseCallback = null;
        if (typeof cb === 'function') {
            try { cb(); } catch (err) {
                console.warn('[FlightReplay] onClose callback threw:', err);
            }
        }
    }

    function showToast(msg) {
        const t = document.createElement('div');
        t.className = 'flight-replay-toast';
        t.textContent = msg;
        document.body.appendChild(t);
        setTimeout(() => t.classList.add('fade-out'), 2400);
        setTimeout(() => t.remove(), 3000);
    }

    async function open(opts) {
        if (!opts || !opts.map || !opts.flightId) {
            showToast('Replay error: missing map or flight ID.');
            return false;
        }
        close();
        injectStyles();

        map = opts.map;
        currentFlightId = opts.flightId;
        currentMeta = opts.meta || {};
        // Stash any caller-supplied close hook. It fires from close() once
        // teardown is finished — this is how the host UI knows it can pop
        // the flight info window back open and restore any hidden chrome.
        onCloseCallback = (typeof opts.onClose === 'function') ? opts.onClose : null;

        let backendPoints = [];
        if (opts.historyUrl) {
            try {
                const res = await fetch(opts.historyUrl);
                const json = res.ok ? await res.json() : null;
                if (json && json.ok) {
                    backendPoints = json.path || json.route || [];
                } else if (json) {
                    console.warn('[FlightReplay] Backend history responded not-ok:', json);
                }
            } catch (e) {
                console.warn('[FlightReplay] Failed to fetch backend history:', e);
            }
        }

        const memoryPoints = Array.isArray(opts.points) ? opts.points : [];
        console.log(`[FlightReplay] Sources for ${currentFlightId}: backend=${backendPoints.length}, memory=${memoryPoints.length}`);

        const merged = backendPoints.concat(memoryPoints);
        points = normalizePoints(merged);

        if (points.length < 2) {
            console.warn(`[FlightReplay] Not enough valid points.`);
            showToast('Not enough position data to replay this flight yet.');
            close();
            return false;
        }

        console.log(`[FlightReplay] Ready: ${points.length} points spanning ${Math.round((points[points.length-1].t - points[0].t) / 1000)}s`);

        totalDurationMs = points[points.length - 1].t - points[0].t;
        currentMs = 0;
        
        chartViewStart = 0;
        chartViewEnd = totalDurationMs;
        chartExpanded = false; 
        isCameraLocked = false;

        buildPanel();

        // Bind breakaway map listeners
        map.on('mousedown', handleUserMapInteraction);
        map.on('touchstart', handleUserMapInteraction);
        map.on('wheel', handleUserMapInteraction);

        panelEl.querySelector('[data-hud="total"]').textContent = fmtClock(totalDurationMs);

        const setupMapBits = () => {
            ensurePathLayer();
            ensureMarker();
            renderFrame();
            // Hide every other live aircraft by default — the user explicitly
            // asked for this behaviour, and the toggle button in the panel
            // already starts in its "active" visual state to match.
            hideOtherTraffic();
            // Hide the *replayed* flight's own live trail so the replay's
            // re-drawn path stands alone.
            hideLiveFlownPath();
            try {
                const start = points[0];
                map.easeTo({
                    center: [start.lon, start.lat],
                    zoom: Math.max(map.getZoom(), 5),
                    duration: 800
                });
            } catch (_) {}
            play();
        };
        if (map.isStyleLoaded && !map.isStyleLoaded()) {
            map.once('idle', setupMapBits);
        } else {
            setupMapBits();
        }
        return true;
    }

    return {
        open,
        close,
        isOpen: () => !!panelEl
    };
})();