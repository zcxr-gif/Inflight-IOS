/**
 * MobileSettingsUI.js - Mobile-optimized Bottom Sheet for Map & Display Settings
 *
 * Redesigned as a tabbed settings experience:
 *   • Map      — visual map-style preview cards + projection/3D + base detail
 *   • Aircraft — icon size/color + 3D options + custom colors (pro)
 *   • Labels   — live label designer: pick the rows, size, and color theme
 *   • Filters  — traffic / ATC / overlays
 *   • General  — flight window, notifications, legal
 */

import { openLegalDoc } from './firstRunExperience.js';

// Maps each map-style value to its Mapbox style owner/id so we can request a
// real static thumbnail for the preview cards. Mirrors the style constants in
// flight.js (MAP_STYLE_*).
const MAP_STYLE_DEFS = {
    'dark':          { owner: 'mapbox',     id: 'dark-v11',              label: 'Dark',       fallback: 'linear-gradient(135deg,#0b1220,#1e293b)' },
    'light':         { owner: 'servernoob', id: 'cmg3wq7an002p01s17kbx7lqk', label: 'Light',  fallback: 'linear-gradient(135deg,#e2e8f0,#cbd5e1)' },
    'satellite':     { owner: 'mapbox',     id: 'satellite-streets-v12', label: 'Satellite',  fallback: 'linear-gradient(135deg,#1a2e1a,#3b5e3b)' },
    'outdoors':      { owner: 'mapbox',     id: 'outdoors-v12',          label: 'Outdoors',   fallback: 'linear-gradient(135deg,#2d4a32,#6b8e4e)', pro: true },
    'nav-dark':      { owner: 'mapbox',     id: 'navigation-night-v1',   label: 'Nav Night',  fallback: 'linear-gradient(135deg,#0a0f1f,#1d2b53)', pro: true },
    'nav-light':     { owner: 'mapbox',     id: 'navigation-day-v1',     label: 'Nav Day',    fallback: 'linear-gradient(135deg,#dbeafe,#93c5fd)', pro: true },
    'traffic-night': { owner: 'mapbox',     id: 'traffic-night-v2',      label: 'Traffic Night', fallback: 'linear-gradient(135deg,#100a1f,#3b1d53)', pro: true },
    'traffic-day':   { owner: 'mapbox',     id: 'traffic-day-v2',        label: 'Traffic Day',   fallback: 'linear-gradient(135deg,#fef3c7,#fcd34d)', pro: true }
};

// The rows the user can stack into the on-map aircraft label. `key` matches
// the flags read by getAircraftLabelTextField() in flight.js.
const LABEL_FIELD_DEFS = [
    { key: 'airlineLogo',  label: 'Airline Logo',  icon: 'fa-building' },
    { key: 'callsign',     label: 'Callsign',      icon: 'fa-hashtag' },
    { key: 'aircraftType', label: 'Aircraft Type', icon: 'fa-plane' },
    { key: 'altSpeed',     label: 'Altitude & Speed', icon: 'fa-gauge-high' },
    { key: 'route',        label: 'Route (DEP → ARR)', icon: 'fa-route' },
    { key: 'registration', label: 'Registration',  icon: 'fa-id-card' },
    { key: 'pilot',        label: 'Pilot Name',    icon: 'fa-user' }
];

// Sample flight used to render the live label preview.
const LABEL_PREVIEW_SAMPLE = {
    // Real wordmark banner for the sample flight's airline (UAL), same source
    // the map loader uses — the preview hides it gracefully if the fetch fails.
    airlineLogo: 'https://raw.githubusercontent.com/Jxck-S/airline-logos/main/radarbox_banners/UAL.png',
    callsign: 'UAL482',
    aircraftType: 'Boeing 787-9',
    altSpeed: '36,000 ft · 482 kts',
    route: 'KSFO  →  EGLL',
    registration: 'N38950',
    pilot: 'Capt. Reyes'
};

// Defaults for the PRO custom active-ATC tag designer
// (mapFilters.atcTagConfig). Mirrors the fallbacks in
// getAtcTagAppearance() in flight.js, which is also where the Pro
// entitlement is actually enforced.
const ATC_TAG_DEFAULTS = {
    enabled: false,
    style: 'classic',   // one of ATC_TAG_STYLE_DEFS values (mirrors ATC_TAG_STYLES in flight.js)
    bg: '#0a0f19',
    text: '#ffffff',
    border: '#ffffff',
    opacity: 0.9,
    showFreqs: true,
    showPulse: true
};

// Tag shapes the designer offers. Values must mirror ATC_TAG_STYLES in
// flight.js, which owns the CSS for each shape.
const ATC_TAG_STYLE_DEFS = [
    { value: 'classic', label: 'Classic' },
    { value: 'chip',    label: 'Chip' },
    { value: 'pill',    label: 'Pill' },
    { value: 'outline', label: 'Outline' },
    { value: 'neon',    label: 'Neon' },
    { value: 'glass',   label: 'Glass' },
    { value: 'flag',    label: 'Flag' },
    { value: 'mono',    label: 'Mono' }
];

// Ready-made tag designs for the preset roulette. Each one is a complete
// atcTagConfig payload (minus `enabled`); applying a preset stamps its name
// into cfg.preset so the roulette window can show what's active. Any manual
// tweak afterwards clears the name (the design becomes "Custom").
const ATC_TAG_PRESETS = [
    { name: 'Midnight',     style: 'classic', bg: '#0a0f19', text: '#ffffff', border: '#ffffff', opacity: 0.9,  showFreqs: true,  showPulse: true  },
    { name: 'Neon Cyan',    style: 'neon',    bg: '#020617', text: '#7dd3fc', border: '#38bdf8', opacity: 0.85, showFreqs: true,  showPulse: true  },
    { name: 'Radar Green',  style: 'mono',    bg: '#02180a', text: '#22c55e', border: '#16a34a', opacity: 0.92, showFreqs: true,  showPulse: true  },
    { name: 'Amber Ops',    style: 'flag',    bg: '#1c1206', text: '#fbbf24', border: '#f59e0b', opacity: 0.92, showFreqs: true,  showPulse: true  },
    { name: 'Tower Orange', style: 'pill',    bg: '#7c2d12', text: '#ffedd5', border: '#fb923c', opacity: 0.95, showFreqs: false, showPulse: true  },
    { name: 'Ice',          style: 'glass',   bg: '#e0f2fe', text: '#0c4a6e', border: '#bae6fd', opacity: 0.55, showFreqs: false, showPulse: false },
    { name: 'Blackout',     style: 'chip',    bg: '#000000', text: '#ffffff', border: '#3f3f46', opacity: 1,    showFreqs: false, showPulse: false },
    { name: 'Royal',        style: 'pill',    bg: '#1e1b4b', text: '#c7d2fe', border: '#818cf8', opacity: 0.92, showFreqs: true,  showPulse: true  },
    { name: 'Hot Pink',     style: 'neon',    bg: '#1a0412', text: '#f9a8d4', border: '#ec4899', opacity: 0.85, showFreqs: false, showPulse: true  },
    { name: 'Paper',        style: 'outline', bg: '#f8fafc', text: '#f1f5f9', border: '#e2e8f0', opacity: 0.95, showFreqs: false, showPulse: false },
    { name: 'Ghost',        style: 'glass',   bg: '#0b1220', text: '#e2e8f0', border: '#94a3b8', opacity: 0.4,  showFreqs: false, showPulse: false },
    { name: 'Crimson',      style: 'flag',    bg: '#1f0a0a', text: '#fecaca', border: '#ef4444', opacity: 0.92, showFreqs: true,  showPulse: true  },
    { name: 'Forest',       style: 'classic', bg: '#052e16', text: '#bbf7d0', border: '#22c55e', opacity: 0.92, showFreqs: true,  showPulse: false },
    { name: 'Gold Leaf',    style: 'glass',   bg: '#451a03', text: '#fde68a', border: '#fbbf24', opacity: 0.7,  showFreqs: true,  showPulse: true  },
    { name: 'Violet Storm', style: 'neon',    bg: '#11041d', text: '#e9d5ff', border: '#a855f7', opacity: 0.88, showFreqs: true,  showPulse: true  },
    { name: 'Slate Mono',   style: 'mono',    bg: '#0f172a', text: '#cbd5e1', border: '#475569', opacity: 1,    showFreqs: true,  showPulse: false }
];

// Label color themes. `mono` + `default` are free; the rest are pro.
const LABEL_THEME_DEFS = [
    { value: 'default',  label: 'White',    text: '#ffffff', halo: 'rgba(15,23,42,0.92)' },
    { value: 'mono',     label: 'Mono',     text: '#e4e4e7', halo: 'rgba(0,0,0,0.85)' },
    { value: 'cyan',     label: 'Cyan',     text: '#7dd3fc', halo: 'rgba(8,47,73,0.92)',  pro: true },
    { value: 'amber',    label: 'Amber',    text: '#fcd34d', halo: 'rgba(69,26,3,0.92)',  pro: true },
    { value: 'contrast', label: 'Contrast', text: '#0b1120', halo: 'rgba(226,232,240,0.95)', pro: true }
];

// --- Filter preset catalogues -------------------------------------------
// All of these feed combobox dropdowns where the user can either pick a
// preset or free-type their own value. Values are written into
// mapFilters.tactical.* and consumed by updateAircraftLayerFilter() in
// flight.js. Substring matches (type/airline/callsign) just need to appear
// anywhere in the corresponding aircraft property.

const AIRCRAFT_TYPE_PRESETS = [
    { label: 'Airbus A320', value: 'A320' }, { label: 'Airbus A321', value: 'A321' },
    { label: 'Airbus A319', value: 'A319' }, { label: 'Airbus A330', value: 'A330' },
    { label: 'Airbus A350', value: 'A350' }, { label: 'Airbus A380', value: 'A380' },
    { label: 'Boeing 737', value: '737' },   { label: 'Boeing 747', value: '747' },
    { label: 'Boeing 757', value: '757' },   { label: 'Boeing 767', value: '767' },
    { label: 'Boeing 777', value: '777' },   { label: 'Boeing 787', value: '787' },
    { label: 'Embraer E-Jet', value: 'E1' }, { label: 'Bombardier CRJ', value: 'CRJ' },
    { label: 'Cessna 172', value: 'C172' },  { label: 'Cessna Citation', value: 'Citation' },
    { label: 'Concorde', value: 'Concorde' }
];

const AIRLINE_PRESETS = [
    { label: 'Delta', value: 'Delta' }, { label: 'United', value: 'United' },
    { label: 'American', value: 'American' }, { label: 'Southwest', value: 'Southwest' },
    { label: 'JetBlue', value: 'JetBlue' }, { label: 'Alaska', value: 'Alaska' },
    { label: 'British Airways', value: 'British' }, { label: 'Lufthansa', value: 'Lufthansa' },
    { label: 'Air France', value: 'Air France' }, { label: 'KLM', value: 'KLM' },
    { label: 'Emirates', value: 'Emirates' }, { label: 'Qatar Airways', value: 'Qatar' },
    { label: 'Etihad', value: 'Etihad' }, { label: 'Singapore', value: 'Singapore' },
    { label: 'Qantas', value: 'Qantas' }, { label: 'Ryanair', value: 'Ryanair' },
    { label: 'easyJet', value: 'easyJet' }, { label: 'Turkish', value: 'Turkish' },
    { label: 'ANA', value: 'ANA' }, { label: 'Japan Airlines', value: 'Japan Airlines' }
];

const AIRPORT_PRESETS = [
    { label: 'KJFK — New York', value: 'KJFK' }, { label: 'KLAX — Los Angeles', value: 'KLAX' },
    { label: 'KSFO — San Francisco', value: 'KSFO' }, { label: 'KORD — Chicago', value: 'KORD' },
    { label: 'KATL — Atlanta', value: 'KATL' }, { label: 'KMIA — Miami', value: 'KMIA' },
    { label: 'EGLL — London Heathrow', value: 'EGLL' }, { label: 'LFPG — Paris CDG', value: 'LFPG' },
    { label: 'EHAM — Amsterdam', value: 'EHAM' }, { label: 'EDDF — Frankfurt', value: 'EDDF' },
    { label: 'LEMD — Madrid', value: 'LEMD' }, { label: 'LIRF — Rome', value: 'LIRF' },
    { label: 'OMDB — Dubai', value: 'OMDB' }, { label: 'OTHH — Doha', value: 'OTHH' },
    { label: 'VHHH — Hong Kong', value: 'VHHH' }, { label: 'RJTT — Tokyo Haneda', value: 'RJTT' },
    { label: 'WSSS — Singapore', value: 'WSSS' }, { label: 'YSSY — Sydney', value: 'YSSY' }
];

const COUNTRY_PRESETS = [
    { label: 'United States', value: 'United States (N)' },
    { label: 'United Kingdom', value: 'United Kingdom (G)' },
    { label: 'Germany', value: 'Germany (D)' },
    { label: 'France', value: 'France (F)' },
    { label: 'Canada', value: 'Canada (C)' },
    { label: 'Australia', value: 'Australia (VH)' },
    { label: 'Japan', value: 'Japan (JA)' },
    { label: 'China', value: 'China (B)' },
    { label: 'Brazil', value: 'Brazil (PP)' },
    { label: 'Netherlands', value: 'Netherlands (PH)' },
    { label: 'Ireland', value: 'Ireland (EI)' },
    { label: 'Spain', value: 'Spain (EC)' },
    { label: 'Italy', value: 'Italy (I)' },
    { label: 'UAE', value: 'UAE (A6)' }
];

const CATEGORY_OPTIONS = [
    { label: 'Heavy', value: 'Heavy' }, { label: 'Widebody', value: 'Widebody' },
    { label: 'Narrowbody', value: 'Narrowbody' }, { label: 'GA', value: 'GA' }
];

const PHASE_OPTIONS = [
    { label: 'Ground', value: 'Ground' }, { label: 'Climb', value: 'Climb' },
    { label: 'Cruise', value: 'Cruise' }, { label: 'Enroute', value: 'Enroute' },
    { label: 'Descent', value: 'Descent' }
];

// Tactical keys persisted under mapFilters.tactical — used for the active
// filter count badge and the Reset action.
const TACTICAL_KEYS = ['type', 'livery', 'airline', 'category', 'phase',
    'departureIcao', 'arrivalIcao', 'callsign', 'country', 'altitude', 'speed'];

export const MobileSettingsUI = {
    _isOpen: false,
    _activeTab: 'map',

    // Read-only accessors so other hosts (the desktop Global Settings modal in
    // flight.js) can build their own label designer / style picker from the
    // same definitions instead of duplicating them.
    getLabelFieldDefs() { return LABEL_FIELD_DEFS; },
    getLabelThemeDefs() { return LABEL_THEME_DEFS; },
    getLabelPreviewSample() { return LABEL_PREVIEW_SAMPLE; },

    init() {
        this.injectMobileStyles();
        this.renderMobileContainer();
        this.attachMobileListeners();
    },

    // Builds a Mapbox Static Images URL for a style preview. Falls back to a
    // CSS gradient (handled in renderMapStyleCards) when no token is present.
    getStylePreviewUrl(value) {
        const def = MAP_STYLE_DEFS[value];
        const token = (typeof mapboxgl !== 'undefined' && mapboxgl.accessToken) || window.MAPBOX_ACCESS_TOKEN;
        if (!def || !token) return null;
        // Centered over the North Atlantic at a low zoom — recognisable land +
        // water so each style's palette reads clearly in the thumbnail.
        const view = '-30,40,1.6,0';
        return `https://api.mapbox.com/styles/v1/${def.owner}/${def.id}/static/${view}/240x150@2x` +
               `?access_token=${token}&attribution=false&logo=false`;
    },

    renderMapStyleCards(values) {
        return values.map(value => {
            const def = MAP_STYLE_DEFS[value];
            const url = this.getStylePreviewUrl(value);
            // Layer the real thumbnail over the gradient so a failed/blocked
            // image request degrades gracefully to the style's color identity.
            const bg = url
                ? `background-image:url('${url}'), ${def.fallback}; background-size:cover; background-position:center;`
                : `background:${def.fallback};`;
            return `
                <button class="m-style-card ${def.pro ? 'is-pro-feature' : ''}"
                        data-setting="mapStyle" data-value="${value}" ${def.pro ? 'data-pro="true"' : ''} type="button">
                    <span class="m-style-thumb" style="${bg}">
                        ${def.pro ? '<span class="m-style-pro"><i class="fa-solid fa-lock"></i></span>' : ''}
                        <span class="m-style-check"><i class="fa-solid fa-check"></i></span>
                    </span>
                    <span class="m-style-name">${def.label}</span>
                </button>
            `;
        }).join('');
    },

    renderMobileContainer() {
        const existing = document.getElementById('mobile-settings-nexus');
        if (existing) existing.remove();

        const html = `
            <div id="mobile-settings-nexus" class="mobile-only-ui">
                <div id="mobile-settings-overlay" class="mobile-sheet-overlay"></div>

                <div class="mobile-bottom-sheet">
                    <div class="sheet-handle"></div>
                    <button class="sheet-close-btn" id="mobile-settings-close" type="button" aria-label="Close">
                        <i class="fa-solid fa-xmark"></i>
                    </button>

                    <div class="mobile-title">
                        <i class="fa-solid fa-sliders"></i>
                        <span>Settings</span>
                    </div>

                    <!-- Segmented tab bar -->
                    <div class="m-tabbar" role="tablist">
                        <button class="m-tab active" data-tab="map" type="button"><i class="fa-solid fa-map"></i><span>Map</span></button>
                        <button class="m-tab" data-tab="aircraft" type="button"><i class="fa-solid fa-plane-up"></i><span>Aircraft</span></button>
                        <button class="m-tab" data-tab="labels" type="button"><i class="fa-solid fa-tag"></i><span>Labels</span></button>
                        <button class="m-tab" data-tab="filters" type="button"><i class="fa-solid fa-layer-group"></i><span>Overlays</span></button>
                        <button class="m-tab" data-tab="general" type="button"><i class="fa-solid fa-gear"></i><span>More</span></button>
                    </div>

                    <div class="sheet-content custom-scroll">

                        <!-- ====================== MAP ====================== -->
                        <div class="m-panel active" data-panel="map">
                            <div class="mobile-section-header">Map Style</div>
                            <div class="m-style-grid">
                                ${this.renderMapStyleCards(['dark', 'light', 'satellite'])}
                            </div>

                            <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>Premium Styles</div>
                            <div class="m-style-grid">
                                ${this.renderMapStyleCards(['outdoors', 'nav-dark', 'nav-light', 'traffic-night', 'traffic-day'])}
                            </div>

                            <div class="mobile-section-header">Projection &amp; 3D</div>
                            <div class="m-settings-list">
                                ${this.renderToggle('useFlatMap', 'Flat Map Projection', 'fa-map')}
                                ${this.renderToggle('showTerrain', '3D Terrain (Elevation)', 'fa-mountain', true)}
                                ${this.renderToggle('showBuildings', '3D Buildings', 'fa-city', true)}
                                ${this.renderToggle('showDayNight', 'Day/Night Terminator', 'fa-moon', true)}
                            </div>

                            <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>Base Map Detail</div>
                            <div class="m-settings-list">
                                ${this.renderToggle('showBorders', 'Political Borders', 'fa-earth-americas', true)}
                                ${this.renderToggle('showRoads', 'Roads & Highways', 'fa-road', true)}
                                ${this.renderToggle('showLabels', 'City & Place Labels', 'fa-font', true)}
                                ${this.renderToggle('showPois', 'Points of Interest', 'fa-map-pin', true)}
                                ${this.renderToggle('showWaterLabels', 'Water Labels', 'fa-water', true)}
                                ${this.renderToggle('showAirportLayout', 'Airport Layout', 'fa-plane-arrival', true)}
                                ${this.renderToggle('showLandUse', 'Parks & Forests', 'fa-tree', true)}
                            </div>
                        </div>

                        <!-- ====================== AIRCRAFT ====================== -->
                        <div class="m-panel" data-panel="aircraft">
                            <div class="mobile-section-header">Plane Icon Size</div>
                            <div class="m-setting-range-card">
                                <div class="range-header">
                                    <span>Size</span>
                                    <span id="m-val-planeIconSize">0.05</span>
                                </div>
                                <input type="range" class="m-range-input" data-setting="planeIconSize" min="0.01" max="0.15" step="0.01">
                            </div>

                            <div class="mobile-section-header">Icon Color</div>
                            <div class="settings-mobile-grid">
                                <button class="m-setting-pill" data-setting="iconColorMode" data-value="default">White</button>
                                <button class="m-setting-pill" data-setting="iconColorMode" data-value="blue">Blue</button>
                                <button class="m-setting-pill" data-setting="iconColorMode" data-value="orange">Orange</button>
                            </div>

                            <div class="mobile-section-header">Display</div>
                            <div class="m-settings-list">
                                ${this.renderToggle('live3DTraffic', '3D Live Traffic', 'fa-cubes')}
                                ${this.renderToggle('show3DPath', '3D Flown Path', 'fa-cube')}
                            </div>

                            <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>Custom Colors</div>
                            <div class="m-settings-list">
                                ${this.renderColorRow('proCustomColor', 'Custom Plane Color', 'fa-wand-magic-sparkles', '#38bdf8')}
                                ${this.renderColorRow('userPlaneColor', 'Tracked Flight Color', 'fa-plane', '#f97316')}
                                ${this.renderColorRow('friendPlaneColor', 'Watchlist Color', 'fa-eye', '#c084fc')}
                            </div>
                        </div>

                        <!-- ====================== LABELS ====================== -->
                        <div class="m-panel" data-panel="labels">
                            ${this.renderLabelDesigner()}
                        </div>

                        <!-- ====================== FILTERS ====================== -->
                        <div class="m-panel" data-panel="filters">
                            ${this.renderFiltersPanel()}
                        </div>

                        <!-- ====================== GENERAL ====================== -->
                        <div class="m-panel" data-panel="general">
                            <div class="mobile-section-header">Flight Window</div>
                            <div class="m-settings-list">
                                ${this.renderToggle('useSimpleFlightWindow', 'Simple Flight Info', 'fa-window-maximize')}
                            </div>

                            ${this.renderNotificationsSection()}

                            ${this.renderLegalSection()}
                        </div>
                    </div>
                </div>
            </div>
        `;

        document.body.insertAdjacentHTML('beforeend', html);
    },

    // ---- Settings "Overlays" tab ----------------------------------------
    // The non-tactical map overlays that stay in Settings. The tactical filter
    // board (aircraft/route/performance/etc.) now lives in the bottom-bar
    // Filters tab — see renderTacticalBoard(), rendered by MobileLandingUI.
    renderFiltersPanel() {
        return `
            <div class="mobile-section-header">ATC &amp; Airports</div>
            <div class="m-settings-list">
                ${this.renderToggle('showAtcBoundaries', 'ATC Boundaries', 'fa-draw-polygon')}
                ${this.renderToggle('useClassicAirportTags', 'Classic Airport Tags', 'fa-tags')}
                ${this.renderToggle('showUnstaffedAirports', 'Show Unstaffed', 'fa-circle-dot')}
                ${this.renderToggle('hideNoAtcMarkers', 'Hide No-ATC Dots', 'fa-location-dot')}
                ${this.renderToggle('hideAtcMarkers', 'Hide ATC Markers', 'fa-headset')}
            </div>

            <div class="mobile-section-header">Terrain Awareness</div>
            <div class="m-settings-list">
                ${this.renderToggle('showTerrainMode', 'Terrain Elevation Map', 'fa-mountain-sun')}
                ${this.renderToggle('terrainTawsEnabled', 'Altitude Coloring (TAWS)', 'fa-triangle-exclamation')}
            </div>
            <div class="m-setting-range-card">
                <div class="range-header">
                    <span>Planned Altitude</span>
                    <span id="m-val-terrainTawsAltitude">10,000 ft</span>
                </div>
                <input type="range" class="m-range-input" data-setting="terrainTawsAltitude" min="0" max="45000" step="500">
            </div>

            ${this.renderAtcTagStudio()}

            <div class="mobile-section-header">Flight Plan Routes</div>
            <div class="settings-mobile-grid">
                <button class="m-setting-pill" data-setting="planDisplayMode" data-value="none">None</button>
                <button class="m-setting-pill" data-setting="planDisplayMode" data-value="direct">Direct</button>
                <button class="m-setting-pill" data-setting="planDisplayMode" data-value="full">Full Plan</button>
            </div>

            <div class="mobile-section-header">Oceanic Tracks</div>
            <div class="m-settings-list">
                ${this.renderToggle('showNatTracks', 'NAT Tracks', 'fa-route')}
                ${this.renderToggle('showNatLabels', 'NAT Labels', 'fa-font')}
            </div>
        `;
    },

    // ---- Tactical filter board (shared) ----------------------------------
    // The full tactical filter board: quick toggles + combobox/pill/range
    // controls + the airport-proximity filter. All controls write into
    // mapFilters.tactical and re-run the live map filter. Rendered into the
    // bottom-bar Filters sheet (MobileLandingUI) and wired with
    // attachTacticalHandlers(root) / syncTacticalControls(root) so a single
    // implementation drives the board wherever it's hosted.
    renderTacticalBoard() {
        return `
            <div class="m-filter-bar">
                <span class="m-filter-count" id="m-filter-count">No filters active</span>
                <button class="m-filter-reset" id="m-filter-reset" type="button">
                    <i class="fa-solid fa-rotate-left"></i> Reset
                </button>
            </div>

            <div class="mobile-section-header">Traffic</div>
            <div class="m-settings-list">
                ${this.renderToggle('showStaffOnly', 'Staff Pilots Only', 'fa-shield-check')}
                ${this.renderToggle('showVaOnly', 'VA Members Only', 'fa-star')}
                ${this.renderVaFilterRow()}
                ${this.renderToggle('showGroupFlights', 'Show Group Flights', 'fa-users')}
                ${this.renderToggle('hideAllAircraft', 'Hide All Aircraft', 'fa-eye-slash')}
            </div>

            <div class="mobile-section-header">Aircraft &amp; Airline</div>
            <div class="m-combo-list">
                ${this.renderCombo('type', 'Aircraft Type', 'fa-plane', 'e.g. A320, 787…', AIRCRAFT_TYPE_PRESETS)}
                ${this.renderCombo('livery', 'Airline / Livery', 'fa-building', 'e.g. Delta, Emirates…', AIRLINE_PRESETS)}
                ${this.renderCombo('airline', 'Callsign Prefix', 'fa-hashtag', 'e.g. DAL, BAW…', [])}
            </div>

            <div class="mobile-section-header">Category</div>
            ${this.renderTacticalPills('category', CATEGORY_OPTIONS)}

            <div class="mobile-section-header">Flight Phase</div>
            ${this.renderTacticalPills('phase', PHASE_OPTIONS)}

            <div class="mobile-section-header">Route</div>
            <div class="m-combo-list">
                ${this.renderCombo('departureIcao', 'Departure', 'fa-plane-departure', 'ICAO e.g. KJFK', AIRPORT_PRESETS)}
                ${this.renderCombo('arrivalIcao', 'Arrival', 'fa-plane-arrival', 'ICAO e.g. EGLL', AIRPORT_PRESETS)}
            </div>

            <div class="mobile-section-header">Proximity</div>
            <div class="m-combo-list">
                ${this.renderAirportRadius()}
            </div>

            <div class="mobile-section-header">Performance</div>
            <div class="m-combo-list">
                ${this.renderRangeRow('altitude', 'Altitude', 'fa-gauge-high', 'ft')}
                ${this.renderRangeRow('speed', 'Ground Speed', 'fa-wind', 'kts')}
            </div>

            <div class="mobile-section-header">Identity</div>
            <div class="m-combo-list">
                ${this.renderCombo('callsign', 'Callsign Search', 'fa-magnifying-glass', 'e.g. UAL482', [])}
                ${this.renderCombo('country', 'Registration Country', 'fa-flag', 'Pick a country…', COUNTRY_PRESETS, true)}
            </div>
        `;
    },

    // Airport-proximity control: an ICAO combobox (free-type or pick a preset)
    // plus a radius in nautical miles. Together they write
    // mapFilters.tactical.airportRadius = { icao, radiusNm }.
    renderAirportRadius() {
        const opts = AIRPORT_PRESETS.map(p =>
            `<button class="m-combo-opt" type="button" data-value="${p.value}">${p.label}</button>`
        ).join('');
        return `
            <div class="m-combo m-apt-radius-combo" data-airport-radius>
                <div class="m-combo-label"><i class="fa-solid fa-location-crosshairs"></i><span>Within Radius of Airport</span></div>
                <div class="m-combo-control">
                    <input type="text" class="m-combo-input m-apt-radius-icao" placeholder="ICAO e.g. KJFK"
                           autocomplete="off" autocorrect="off" autocapitalize="characters" spellcheck="false">
                    <button class="m-combo-caret" type="button" tabindex="-1"><i class="fa-solid fa-chevron-down"></i></button>
                    <button class="m-combo-clear" type="button" tabindex="-1"><i class="fa-solid fa-xmark"></i></button>
                    <div class="m-combo-menu">${opts}</div>
                </div>
            </div>
            <div class="m-range-row m-apt-radius-row">
                <div class="m-combo-label"><i class="fa-solid fa-ruler-horizontal"></i><span>Radius <small>(nm)</small></span></div>
                <div class="m-range-inputs">
                    <input type="number" inputmode="numeric" class="m-range-num m-apt-radius-num" placeholder="e.g. 50">
                </div>
            </div>
        `;
    },

    // A combobox: free-type input + a tap-to-pick preset dropdown. When
    // `presetOnly` is true the input is read-only and values come solely from
    // the menu (used for Country, whose value must carry a "(PREFIX)").
    renderCombo(key, label, icon, placeholder, presets, presetOnly = false) {
        const opts = presets.map(p =>
            `<button class="m-combo-opt" type="button" data-value="${p.value}">${p.label}</button>`
        ).join('');
        const hasMenu = presets.length > 0;
        return `
            <div class="m-combo ${presetOnly ? 'is-preset-only' : ''}" data-tactical="${key}">
                <div class="m-combo-label"><i class="fa-solid ${icon}"></i><span>${label}</span></div>
                <div class="m-combo-control">
                    <input type="text" class="m-combo-input" data-tactical="${key}"
                           placeholder="${placeholder}" ${presetOnly ? 'readonly' : ''}
                           autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                    ${hasMenu ? '<button class="m-combo-caret" type="button" tabindex="-1"><i class="fa-solid fa-chevron-down"></i></button>' : ''}
                    <button class="m-combo-clear" type="button" tabindex="-1"><i class="fa-solid fa-xmark"></i></button>
                    ${hasMenu ? `<div class="m-combo-menu">${opts}</div>` : ''}
                </div>
            </div>
        `;
    },

    // Pill row for enum tactical filters (category, phase). The leading "All"
    // pill clears the filter.
    renderTacticalPills(key, options) {
        const pills = [`<button class="m-tac-pill active" data-tactical="${key}" data-value="" type="button">All</button>`]
            .concat(options.map(o =>
                `<button class="m-tac-pill" data-tactical="${key}" data-value="${o.value}" type="button">${o.label}</button>`
            )).join('');
        return `<div class="m-tac-pill-row">${pills}</div>`;
    },

    // Min/Max numeric range written to mapFilters.tactical[key] = {min, max}.
    renderRangeRow(key, label, icon, unit) {
        return `
            <div class="m-range-row" data-tactical-range="${key}">
                <div class="m-combo-label"><i class="fa-solid ${icon}"></i><span>${label} <small>(${unit})</small></span></div>
                <div class="m-range-inputs">
                    <input type="number" inputmode="numeric" class="m-range-num" data-bound="min" placeholder="Min">
                    <span class="m-range-dash">–</span>
                    <input type="number" inputmode="numeric" class="m-range-num" data-bound="max" placeholder="Max">
                </div>
            </div>
        `;
    },

    // The aircraft-label designer: master toggle, a live preview that mirrors
    // exactly what getAircraftLabelTextField() will draw, per-row toggles, a
    // size slider, and color themes (some pro).
    renderLabelDesigner() {
        const fieldRows = LABEL_FIELD_DEFS.map(f => `
            <div class="m-setting-row m-label-field-row" data-label-field="${f.key}">
                <div class="m-row-left">
                    <i class="fa-solid ${f.icon}"></i>
                    <span>${f.label}</span>
                </div>
                <div class="m-row-right">
                    <label class="m-switch">
                        <input type="checkbox" class="m-label-field-input" data-label-field="${f.key}">
                        <span class="m-slider"></span>
                    </label>
                </div>
            </div>
        `).join('');

        const themePills = LABEL_THEME_DEFS.map(t => `
            <button class="m-theme-pill ${t.pro ? 'is-pro-feature' : ''}"
                    data-label-theme="${t.value}" ${t.pro ? 'data-pro="true"' : ''} type="button">
                <span class="m-theme-swatch" style="color:${t.text}; background:${t.halo};">Aa</span>
                <span class="m-theme-name">${t.label}</span>
                ${t.pro ? '<span class="m-theme-lock"><i class="fa-solid fa-lock"></i></span>' : ''}
            </button>
        `).join('');

        return `
            <div class="mobile-section-header">Aircraft Labels</div>
            <div class="m-settings-list">
                ${this.renderToggle('showAircraftLabels', 'Show Labels on Map', 'fa-tag')}
            </div>

            <div class="mobile-section-header">Live Preview</div>
            <div class="m-label-preview-stage">
                <div class="m-label-plane"><i class="fa-solid fa-plane" style="transform:rotate(45deg)"></i></div>
                <div id="m-label-preview" class="m-label-preview"></div>
            </div>

            <div class="mobile-section-header">Label Rows</div>
            <div class="m-settings-list" id="m-label-fields">
                ${fieldRows}
            </div>
            <div class="m-label-disclaimer">
                <i class="fa-solid fa-circle-info"></i>
                <span>Airline names &amp; logos are trademarks of their respective owners, shown for
                entertainment only to represent the airline of your virtual flight. Inflight is not
                affiliated with, endorsed by, or sponsored by any airline. Airline representatives can
                request a logo's removal at
                <a href="mailto:inflightcustomer@gmail.com">inflightcustomer@gmail.com</a>.</span>
            </div>

            <div class="mobile-section-header">Label Size</div>
            <div class="m-setting-range-card">
                <div class="range-header">
                    <span>Scale</span>
                    <span id="m-val-labelScale">1.0×</span>
                </div>
                <input type="range" class="m-range-input m-label-scale" data-setting="labelScale" min="0.8" max="1.4" step="0.1">
            </div>

            <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>Label Theme</div>
            <div class="m-theme-grid">
                ${themePills}
            </div>
        `;
    },

    // ---- PRO: ATC Tag Studio ---------------------------------------------
    // Designer for the active-ATC airport tags: live preview, a roulette of
    // ready-made preset designs, eight tag shapes, colors, background
    // opacity, and the frequency-badge / pulse extras. Writes
    // mapFilters.atcTagConfig, which the map side (flight.js) applies
    // directly — like the other studio features, the sign-in lock on these
    // controls is the gate.
    renderAtcTagStudio() {
        const d = ATC_TAG_DEFAULTS;
        return `
            <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>ATC Tag Studio</div>
            <div class="m-atc-stage">
                <div id="m-atc-tag-preview"></div>
            </div>
            <div class="m-settings-list">
                <div class="m-setting-row is-pro-feature">
                    <div class="m-row-left">
                        <i class="fa-solid fa-wand-magic-sparkles" style="color:#fbbf24;"></i>
                        <span>Custom ATC Tags</span>
                    </div>
                    <div class="m-row-right">
                        <div class="pro-lock-badge"><i class="fa-solid fa-lock" style="font-size:0.6rem; margin-right:4px;"></i>PRO</div>
                        <label class="m-switch">
                            <input type="checkbox" class="m-atc-input" data-atc-tag="enabled">
                            <span class="m-slider"></span>
                        </label>
                    </div>
                </div>
            </div>
            <div id="m-atc-tag-options">
                <div class="mobile-section-header pro-accent"><i class="fa-solid fa-dice"></i> Preset Designs</div>
                <div class="m-atc-roulette is-pro-feature">
                    <button class="m-atc-roulette-arrow" data-atc-roulette="prev" type="button" aria-label="Previous preset">
                        <i class="fa-solid fa-chevron-left"></i>
                    </button>
                    <div class="m-atc-roulette-window">
                        <div class="m-atc-roulette-name" id="m-atc-preset-name">Midnight</div>
                        <div class="m-atc-roulette-count" id="m-atc-preset-count">1 / ${ATC_TAG_PRESETS.length}</div>
                    </div>
                    <button class="m-atc-roulette-arrow" data-atc-roulette="next" type="button" aria-label="Next preset">
                        <i class="fa-solid fa-chevron-right"></i>
                    </button>
                </div>
                <button class="m-atc-spin is-pro-feature" id="m-atc-spin" type="button">
                    <i class="fa-solid fa-dice"></i> Spin the Roulette
                </button>
                <div class="m-settings-list">
                    <div class="m-setting-row m-atc-style-row is-pro-feature">
                        <div class="m-row-left">
                            <i class="fa-solid fa-shapes" style="color:#fbbf24;"></i>
                            <span>Tag Style</span>
                        </div>
                        <div class="m-atc-style-pills">
                            ${ATC_TAG_STYLE_DEFS.map(s =>
                                `<button class="m-atc-pill" data-atc-style="${s.value}" type="button">${s.label}</button>`
                            ).join('')}
                        </div>
                    </div>
                    <div class="m-setting-row is-pro-feature">
                        <div class="m-row-left">
                            <i class="fa-solid fa-fill-drip" style="color:#fbbf24;"></i>
                            <span>Background</span>
                        </div>
                        <div class="m-row-right">
                            <input type="color" class="m-color-picker m-atc-input" data-atc-tag="bg" value="${d.bg}">
                        </div>
                    </div>
                    <div class="m-setting-row is-pro-feature">
                        <div class="m-row-left">
                            <i class="fa-solid fa-font" style="color:#fbbf24;"></i>
                            <span>Letters</span>
                        </div>
                        <div class="m-row-right">
                            <input type="color" class="m-color-picker m-atc-input" data-atc-tag="text" value="${d.text}">
                        </div>
                    </div>
                    <div class="m-setting-row is-pro-feature">
                        <div class="m-row-left">
                            <i class="fa-solid fa-border-all" style="color:#fbbf24;"></i>
                            <span>Border</span>
                        </div>
                        <div class="m-row-right">
                            <input type="color" class="m-color-picker m-atc-input" data-atc-tag="border" value="${d.border}">
                        </div>
                    </div>
                </div>
                <div class="m-setting-range-card is-pro-feature" style="margin-top:8px;">
                    <div class="range-header">
                        <span>Background Opacity</span>
                        <span id="m-val-atcTagOpacity">90%</span>
                    </div>
                    <input type="range" class="m-range-input m-atc-input" data-atc-tag="opacity" min="0.2" max="1" step="0.05">
                </div>
                <div class="m-settings-list" style="margin-top:8px;">
                    <div class="m-setting-row is-pro-feature">
                        <div class="m-row-left">
                            <i class="fa-solid fa-tower-broadcast" style="color:#fbbf24;"></i>
                            <span>Frequency Badges</span>
                        </div>
                        <div class="m-row-right">
                            <label class="m-switch">
                                <input type="checkbox" class="m-atc-input" data-atc-tag="showFreqs">
                                <span class="m-slider"></span>
                            </label>
                        </div>
                    </div>
                    <div class="m-setting-row is-pro-feature">
                        <div class="m-row-left">
                            <i class="fa-solid fa-circle-notch" style="color:#fbbf24;"></i>
                            <span>Approach Pulse Ring</span>
                        </div>
                        <div class="m-row-right">
                            <label class="m-switch">
                                <input type="checkbox" class="m-atc-input" data-atc-tag="showPulse">
                                <span class="m-slider"></span>
                            </label>
                        </div>
                    </div>
                </div>
            </div>
        `;
    },

    // Current designer config, creating it on mapFilters the first time a
    // control writes to it.
    getAtcTagConfig() {
        if (!window.mapFilters) return { ...ATC_TAG_DEFAULTS };
        if (!window.mapFilters.atcTagConfig) window.mapFilters.atcTagConfig = { ...ATC_TAG_DEFAULTS };
        return window.mapFilters.atcTagConfig;
    },

    setAtcTag(key, value) {
        const cfg = this.getAtcTagConfig();
        cfg[key] = value;
        // A manual tweak means the design no longer matches a preset.
        if (key !== 'enabled') delete cfg.preset;
        this.syncAtcTagControls();
        if (window.refreshAtcTagAppearance) window.refreshAtcTagAppearance();
        if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
    },

    // --- Preset roulette ---------------------------------------------------
    _atcPresetIndex: 0,
    _atcSpinActive: false,

    // Applies preset `index` (wrapping) to the live config. `commit: false`
    // only repaints the studio preview/controls — the roulette spin uses it
    // for its intermediate ticks so the map isn't re-rendered 20× per spin.
    applyAtcTagPreset(index, commit = true) {
        const n = ATC_TAG_PRESETS.length;
        this._atcPresetIndex = ((index % n) + n) % n;
        const p = ATC_TAG_PRESETS[this._atcPresetIndex];
        const cfg = this.getAtcTagConfig();
        Object.assign(cfg, {
            preset: p.name,
            style: p.style,
            bg: p.bg,
            text: p.text,
            border: p.border,
            opacity: p.opacity,
            showFreqs: p.showFreqs,
            showPulse: p.showPulse
        });
        this.syncAtcTagControls();
        if (commit) {
            if (window.refreshAtcTagAppearance) window.refreshAtcTagAppearance();
            if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
        }
    },

    // Roulette spin: at least one full revolution, then a random landing
    // slot, with the tick delay easing out like a slowing wheel. The live
    // preview repaints on every tick; the map + storage commit on landing.
    spinAtcTagRoulette() {
        if (this._atcSpinActive) return;
        this._atcSpinActive = true;
        const n = ATC_TAG_PRESETS.length;
        const steps = n + 4 + Math.floor(Math.random() * n);
        let step = 0;
        const tick = () => {
            step++;
            const last = step >= steps;
            this.applyAtcTagPreset(this._atcPresetIndex + 1, last);
            window.InflightHaptics?.select?.();
            if (last) {
                this._atcSpinActive = false;
                return;
            }
            const t = step / steps;
            setTimeout(tick, 40 + 380 * t * t);
        };
        tick();
    },

    attachAtcTagHandlers(sheet) {
        sheet.querySelectorAll('.m-atc-input[type="checkbox"]').forEach(input => {
            input.addEventListener('change', (e) => {
                if (e.target.closest('.locked')) return;
                window.InflightHaptics?.select?.();
                this.setAtcTag(e.target.dataset.atcTag, e.target.checked);
            });
        });
        sheet.querySelectorAll('.m-atc-input[type="color"]').forEach(input => {
            input.addEventListener('input', (e) => {
                if (e.target.closest('.locked')) return;
                this.setAtcTag(e.target.dataset.atcTag, e.target.value);
            });
        });
        const range = sheet.querySelector('.m-atc-input[type="range"]');
        if (range) {
            range.addEventListener('input', (e) => {
                if (e.target.closest('.locked')) return;
                this.setAtcTag('opacity', parseFloat(e.target.value));
            });
        }
        sheet.querySelectorAll('.m-atc-pill').forEach(btn => {
            btn.addEventListener('click', () => {
                if (btn.closest('.locked')) return;
                window.InflightHaptics?.select?.();
                this.setAtcTag('style', btn.dataset.atcStyle);
            });
        });
        sheet.querySelectorAll('[data-atc-roulette]').forEach(btn => {
            btn.addEventListener('click', () => {
                if (btn.closest('.locked') || this._atcSpinActive) return;
                window.InflightHaptics?.select?.();
                this.applyAtcTagPreset(this._atcPresetIndex + (btn.dataset.atcRoulette === 'prev' ? -1 : 1));
            });
        });
        const spin = sheet.querySelector('#m-atc-spin');
        if (spin) {
            spin.addEventListener('click', () => {
                if (spin.classList.contains('locked')) return;
                window.InflightHaptics?.select?.();
                this.spinAtcTagRoulette();
            });
        }
    },

    // Reflect mapFilters.atcTagConfig into the studio's controls + preview.
    syncAtcTagControls() {
        const container = document.getElementById('mobile-settings-nexus');
        if (!container) return;
        const cfg = { ...ATC_TAG_DEFAULTS, ...((window.mapFilters && window.mapFilters.atcTagConfig) || {}) };

        container.querySelectorAll('.m-atc-input[type="checkbox"]').forEach(input => {
            input.checked = !!cfg[input.dataset.atcTag];
        });
        container.querySelectorAll('.m-atc-input[type="color"]').forEach(input => {
            const val = cfg[input.dataset.atcTag];
            if (val) input.value = val;
        });
        const range = container.querySelector('.m-atc-input[type="range"]');
        if (range) range.value = cfg.opacity;
        const opacityLabel = document.getElementById('m-val-atcTagOpacity');
        if (opacityLabel) opacityLabel.textContent = `${Math.round(cfg.opacity * 100)}%`;
        container.querySelectorAll('.m-atc-pill').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.atcStyle === cfg.style);
        });

        // Preset roulette window: show the active preset (and track its index
        // so the arrows continue from it), or "Custom" after manual tweaks.
        const presetIdx = ATC_TAG_PRESETS.findIndex(p => p.name === cfg.preset);
        if (presetIdx >= 0) this._atcPresetIndex = presetIdx;
        const presetName = document.getElementById('m-atc-preset-name');
        if (presetName) presetName.textContent = presetIdx >= 0 ? cfg.preset : 'Custom';
        const presetCount = document.getElementById('m-atc-preset-count');
        if (presetCount) {
            presetCount.textContent = presetIdx >= 0
                ? `${presetIdx + 1} / ${ATC_TAG_PRESETS.length}`
                : `${ATC_TAG_PRESETS.length} presets`;
        }

        const options = document.getElementById('m-atc-tag-options');
        if (options) options.classList.toggle('is-off', !cfg.enabled);

        this.updateAtcTagPreview();
    },

    // Renders a static replica of an active-ATC tag using the map's own
    // .apt-live-tag styles (flight.js injects them globally), so the preview
    // is exactly what the map will draw.
    updateAtcTagPreview() {
        const host = document.getElementById('m-atc-tag-preview');
        if (!host) return;
        const cfg = { ...ATC_TAG_DEFAULTS, ...((window.mapFilters && window.mapFilters.atcTagConfig) || {}) };
        const custom = cfg.enabled;

        const hexToRgba = (hex, alpha) => {
            const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || '').trim());
            if (!m) return hex;
            const n = parseInt(m[1], 16);
            return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
        };

        const cls = ['apt-live-tag'];
        if (custom) {
            cls.push('atc-tag-custom');
            if (cfg.style && cfg.style !== 'classic') cls.push(`atc-tag-${cfg.style}`);
            if (!cfg.showFreqs) cls.push('atc-tag-no-freqs');
            if (!cfg.showPulse) cls.push('atc-tag-no-pulse');
        }
        const vars = custom
            ? `--atc-tag-bg:${hexToRgba(cfg.bg, cfg.opacity)};--atc-tag-text:${cfg.text};--atc-tag-border:${cfg.border};`
            : '';

        host.innerHTML = `
            <div class="${cls.join(' ')}" style="${vars}">
                <div class="tag-pulse-aura"></div>
                <div class="apt-tag-base">
                    <div class="apt-tag-ident">KLAX</div>
                    <div class="apt-tag-freqs">
                        <div class="freq-mini-badge f-atis">A</div>
                        <div class="freq-mini-badge f-gnd">G</div>
                        <div class="freq-mini-badge f-twr">T</div>
                        <div class="freq-mini-badge f-app">R</div>
                    </div>
                </div>
            </div>
        `;
    },

    renderColorRow(setting, label, icon, value) {
        return `
            <div class="m-setting-row is-pro-feature">
                <div class="m-row-left">
                    <i class="fa-solid ${icon}" style="color:#fbbf24;"></i>
                    <span>${label}</span>
                </div>
                <div class="m-row-right">
                    <div class="pro-lock-badge"><i class="fa-solid fa-lock" style="font-size:0.6rem; margin-right:4px;"></i>PRO</div>
                    <input type="color" class="m-color-picker" data-setting="${setting}" value="${value}" data-pro="true">
                </div>
            </div>
        `;
    },

    renderNotificationsSection() {
        // Hidden automatically on platforms without the native bridge (see
        // refreshNotificationStatus), so it only appears in the iOS app.
        return `
            <div id="m-notif-section">
                <div class="mobile-section-header">Notifications</div>
                <div class="m-settings-list">
                    <div class="m-setting-row" id="m-notif-row">
                        <div class="m-row-left">
                            <i class="fa-solid fa-bell" style="color:#38bdf8;"></i>
                            <span>Push &amp; Live Activity Alerts</span>
                        </div>
                        <div class="m-row-right">
                            <span id="m-notif-status" class="m-notif-status" data-status="loading">Checking…</span>
                            <button id="m-notif-enable" class="m-btn m-primary m-notif-cta" type="button">Enable</button>
                        </div>
                    </div>
                    <p class="m-notif-help">Shows your live flight on the lock screen and sends arrival alerts.</p>
                </div>
            </div>
        `;
    },

    // Dropdown that filters the map to a single Virtual Airline (by callsign
    // code). Options come from window.IFVA_DATABASE (the IFVARB directory).
    renderVaFilterRow() {
        const options = (window.IFVA_DATABASE || [])
            .map(va => `<option value="${va.code}">${va.name}${va.approx ? ' *' : ''}</option>`)
            .join('');
        return `
            <div class="m-setting-row">
                <div class="m-row-left">
                    <i class="fa-solid fa-plane-circle-check"></i>
                    <span>Show VA</span>
                </div>
                <div class="m-row-right">
                    <select class="m-select" data-setting="vaFilter" style="max-width: 150px; background: rgba(0,0,0,0.3); color: #fff; border: 1px solid rgba(255,255,255,0.15); border-radius: 8px; padding: 6px 8px; font-size: 0.8rem;">
                        <option value="">All Airlines</option>
                        ${options}
                    </select>
                </div>
            </div>
        `;
    },

    // Legal documents — the Privacy Policy and Terms of Service. Surfaced here
    // so users can revisit what they agreed to during onboarding at any time.
    // Each row opens the doc in the shared in-app slide-over viewer.
    renderLegalSection() {
        return `
            <div class="mobile-section-header">Legal</div>
            <div class="m-settings-list">
                <div class="m-setting-row m-legal-row" data-doc="privacy.html" data-title="Privacy Policy">
                    <div class="m-row-left">
                        <i class="fa-solid fa-shield-halved"></i>
                        <span>Privacy Policy</span>
                    </div>
                    <div class="m-row-right"><i class="fa-solid fa-chevron-right m-legal-chevron"></i></div>
                </div>
                <div class="m-setting-row m-legal-row" data-doc="terms.html" data-title="Terms of Service">
                    <div class="m-row-left">
                        <i class="fa-solid fa-file-contract"></i>
                        <span>Terms of Service</span>
                    </div>
                    <div class="m-row-right"><i class="fa-solid fa-chevron-right m-legal-chevron"></i></div>
                </div>
            </div>
        `;
    },

    // Formats a range slider's numeric value for its value label.
    formatRangeValue(setting, val) {
        if (setting === 'labelScale') return `${(parseFloat(val) || 1).toFixed(1)}×`;
        if (setting === 'terrainTawsAltitude') return `${(parseInt(val, 10) || 0).toLocaleString()} ft`;
        return `${val}`;
    },

    renderToggle(id, label, icon, isPro = false) {
        return `
            <div class="m-setting-row ${isPro ? 'is-pro-feature' : ''}">
                <div class="m-row-left">
                    <i class="fa-solid ${icon}" ${isPro ? 'style="color: #fbbf24;"' : ''}></i>
                    <span>${label}</span>
                </div>
                <div class="m-row-right">
                    ${isPro ? '<div class="pro-lock-badge"><i class="fa-solid fa-lock" style="font-size:0.6rem; margin-right:4px;"></i>PRO</div>' : ''}
                    <label class="m-switch">
                        <input type="checkbox" data-setting="${id}" ${isPro ? 'data-pro="true"' : ''}>
                        <span class="m-slider"></span>
                    </label>
                </div>
            </div>
        `;
    },

    isSignedIn() {
        if (window.currentUser || window.user || window.isLoggedIn || window.session) return true;
        for (let i = 0; i < localStorage.length; i++) {
            const key = localStorage.key(i);
            // Supports both legacy v1 and current v2 Supabase token formats
            if (key && (key.includes('supabase.auth.token') || (key.startsWith('sb-') && key.endsWith('-auth-token')))) {
                return true;
            }
        }
        return false;
    },

    refreshProLocks() {
        const isSignedIn = this.isSignedIn();
        const container = document.getElementById('mobile-settings-nexus');
        if (!container) return;

        container.querySelectorAll('.is-pro-feature').forEach(row => {
            if (!isSignedIn) {
                row.classList.add('locked');
            } else {
                row.classList.remove('locked');
            }
        });
    },

    switchTab(tab) {
        if (!tab) return;
        this._activeTab = tab;
        const container = document.getElementById('mobile-settings-nexus');
        if (!container) return;
        container.querySelectorAll('.m-tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
        container.querySelectorAll('.m-panel').forEach(p => p.classList.toggle('active', p.dataset.panel === tab));
        const content = container.querySelector('.sheet-content');
        if (content) content.scrollTop = 0;
    },

    // Writes (or clears) a single tactical filter and re-runs the live map
    // filter + persistence + badge refresh.
    setTactical(key, value) {
        if (!window.mapFilters) return;
        if (!window.mapFilters.tactical) window.mapFilters.tactical = {};
        const v = (value || '').trim();
        if (v === '') {
            delete window.mapFilters.tactical[key];
        } else {
            window.mapFilters.tactical[key] = v;
        }
        if (window.updateMapFilters) window.updateMapFilters();
        if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
        this.updateFilterBadge();
    },

    // Min/Max range tactical filter — stored as { min, max } with '' meaning
    // "unbounded" (matches the parser in updateAircraftLayerFilter).
    setTacticalRange(key, bound, value) {
        if (!window.mapFilters) return;
        if (!window.mapFilters.tactical) window.mapFilters.tactical = {};
        const t = window.mapFilters.tactical;
        if (!t[key]) t[key] = { min: '', max: '' };
        t[key][bound] = (value === null || value === undefined) ? '' : String(value).trim();
        // Drop the object entirely once both bounds are clear so it doesn't
        // count as an active filter.
        if (t[key].min === '' && t[key].max === '') delete t[key];
        if (window.updateMapFilters) window.updateMapFilters();
        if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
        this.updateFilterBadge();
    },

    // Counts active tactical filters and reflects it in the tab badge + the
    // in-panel summary line.
    countActiveTactical() {
        const t = (window.mapFilters && window.mapFilters.tactical) || {};
        let n = 0;
        TACTICAL_KEYS.forEach(k => {
            const v = t[k];
            if (v === undefined || v === null) return;
            if (typeof v === 'object') {
                if ((v.min !== undefined && v.min !== '') || (v.max !== undefined && v.max !== '')) n++;
            } else if (String(v).trim() !== '') {
                n++;
            }
        });
        // Airport-proximity filter counts as one active rule.
        if (t.airportRadius && t.airportRadius.icao && t.airportRadius.radiusNm) n++;
        return n;
    },

    updateFilterBadge() {
        const n = this.countActiveTactical();
        // Class-based lookups: the tactical board is hosted both in the mobile
        // Filters sheet and the desktop Global Settings modal, so the count /
        // reset elements can exist more than once.
        document.querySelectorAll('.m-filter-count').forEach(count => {
            count.textContent = n === 0 ? 'No filters active'
                : `${n} active filter${n === 1 ? '' : 's'}`;
            count.classList.toggle('has-filters', n > 0);
        });
        document.querySelectorAll('.m-filter-reset').forEach(reset => {
            reset.classList.toggle('visible', n > 0);
        });

        // Keep the bottom-bar Filters tab dot in sync (the board now writes
        // mapFilters.tactical directly rather than via the old landing engine).
        const dot = document.getElementById('ios-tab-filter-dot');
        if (dot) {
            dot.textContent = n > 9 ? '9+' : String(n);
            dot.classList.toggle('is-on', n > 0);
        }
        // Desktop landing chrome's Filters orb dot, when present (it is
        // shown/hidden via opacity — see .active-pulse-dot in landingUI.js).
        const deskDot = document.getElementById('filter-active-dot');
        if (deskDot) deskDot.style.opacity = n > 0 ? '1' : '0';
    },

    resetTacticalFilters(root) {
        if (window.mapFilters) window.mapFilters.tactical = {};
        const container = root || document.getElementById('mobile-tactical-nexus');
        if (container) {
            container.querySelectorAll('.m-combo-input').forEach(i => { i.value = ''; });
            container.querySelectorAll('.m-range-num').forEach(i => { i.value = ''; });
            container.querySelectorAll('.m-tac-pill').forEach(p => {
                p.classList.toggle('active', p.dataset.value === '');
            });
            container.querySelectorAll('.m-combo').forEach(c => c.classList.remove('has-value'));
        }
        if (window.updateMapFilters) window.updateMapFilters();
        if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
        this.updateFilterBadge();
    },

    // Read the proximity inputs out of `root` and commit (or clear)
    // mapFilters.tactical.airportRadius, then re-run the live filter.
    commitAirportRadius(root) {
        if (!root) return;
        if (!window.mapFilters) return;
        if (!window.mapFilters.tactical) window.mapFilters.tactical = {};
        const icaoInput = root.querySelector('.m-apt-radius-icao');
        const numInput = root.querySelector('.m-apt-radius-num');
        const icao = ((icaoInput && icaoInput.value) || '').trim().toUpperCase();
        const radiusNm = parseFloat(numInput && numInput.value);

        if (icao && radiusNm > 0) {
            window.mapFilters.tactical.airportRadius = { icao, radiusNm };
        } else {
            delete window.mapFilters.tactical.airportRadius;
        }
        if (window.updateMapFilters) window.updateMapFilters();
        if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
        this.updateFilterBadge();
    },

    // Wire every control in the tactical board, scoped to `root` so the same
    // board works wherever it's hosted (the bottom-bar Filters sheet). Bound
    // once per root — guarded against double-binding.
    attachTacticalHandlers(root) {
        if (!root || root.dataset.tacticalBound === '1') return;
        root.dataset.tacticalBound = '1';

        // Traffic quick toggles (write mapFilters[setting] directly).
        root.querySelectorAll('input[type="checkbox"][data-setting]').forEach(input => {
            input.addEventListener('change', (e) => {
                if (e.target.closest('.locked')) return;
                window.InflightHaptics?.select?.();
                window.mapFilters[e.target.dataset.setting] = e.target.checked;
                if (window.updateMapFilters) window.updateMapFilters();
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
                this.updateFilterBadge();
            });
        });

        // VA dropdown (and any other select[data-setting]).
        root.querySelectorAll('select[data-setting]').forEach(sel => {
            sel.addEventListener('change', (e) => {
                window.mapFilters[e.target.dataset.setting] = e.target.value;
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });

        // Tactical comboboxes (free-type + preset menu).
        root.querySelectorAll('.m-combo[data-tactical]').forEach(combo => {
            const key = combo.dataset.tactical;
            const input = combo.querySelector('.m-combo-input');
            const menu = combo.querySelector('.m-combo-menu');
            const caret = combo.querySelector('.m-combo-caret');
            const clear = combo.querySelector('.m-combo-clear');
            const presetOnly = combo.classList.contains('is-preset-only');
            const markValue = () => combo.classList.toggle('has-value', !!input.value.trim());
            const filterMenu = () => {
                if (!menu) return;
                const q = input.value.trim().toLowerCase();
                menu.querySelectorAll('.m-combo-opt').forEach(opt => {
                    const match = !q || opt.textContent.toLowerCase().includes(q) ||
                        (opt.dataset.value || '').toLowerCase().includes(q);
                    opt.style.display = match ? '' : 'none';
                });
            };
            const openMenu = () => { if (menu) { filterMenu(); combo.classList.add('open'); } };
            const closeMenu = () => combo.classList.remove('open');

            if (!presetOnly) {
                input.addEventListener('input', () => {
                    markValue(); filterMenu(); combo.classList.add('open');
                    this.setTactical(key, input.value);
                });
            }
            input.addEventListener('focus', openMenu);
            input.addEventListener('blur', () => setTimeout(closeMenu, 180));
            if (caret) caret.addEventListener('mousedown', (e) => {
                e.preventDefault();
                combo.classList.contains('open') ? closeMenu() : (input.focus(), openMenu());
            });
            if (clear) clear.addEventListener('click', () => {
                input.value = ''; markValue(); this.setTactical(key, ''); closeMenu();
            });
            if (menu) menu.querySelectorAll('.m-combo-opt').forEach(opt => {
                opt.addEventListener('mousedown', (e) => {
                    e.preventDefault();
                    window.InflightHaptics?.select?.();
                    input.value = opt.dataset.value; markValue();
                    this.setTactical(key, opt.dataset.value); closeMenu();
                });
            });
        });

        // Tactical pill rows (category / phase).
        root.querySelectorAll('.m-tac-pill').forEach(pill => {
            pill.addEventListener('click', () => {
                window.InflightHaptics?.select?.();
                pill.parentElement.querySelectorAll('.m-tac-pill').forEach(p => p.classList.remove('active'));
                pill.classList.add('active');
                this.setTactical(pill.dataset.tactical, pill.dataset.value);
            });
        });

        // Tactical numeric ranges (altitude / speed).
        root.querySelectorAll('.m-range-row[data-tactical-range]').forEach(row => {
            const key = row.dataset.tacticalRange;
            row.querySelectorAll('.m-range-num').forEach(num => {
                num.addEventListener('input', () => this.setTacticalRange(key, num.dataset.bound, num.value));
            });
        });

        // Airport-proximity combobox + radius.
        const aptCombo = root.querySelector('.m-apt-radius-combo');
        if (aptCombo) {
            const input = aptCombo.querySelector('.m-apt-radius-icao');
            const menu = aptCombo.querySelector('.m-combo-menu');
            const caret = aptCombo.querySelector('.m-combo-caret');
            const clear = aptCombo.querySelector('.m-combo-clear');
            const markValue = () => aptCombo.classList.toggle('has-value', !!input.value.trim());
            const filterMenu = () => {
                if (!menu) return;
                const q = input.value.trim().toLowerCase();
                menu.querySelectorAll('.m-combo-opt').forEach(opt => {
                    const match = !q || opt.textContent.toLowerCase().includes(q) ||
                        (opt.dataset.value || '').toLowerCase().includes(q);
                    opt.style.display = match ? '' : 'none';
                });
            };
            const openMenu = () => { if (menu) { filterMenu(); aptCombo.classList.add('open'); } };
            const closeMenu = () => aptCombo.classList.remove('open');

            input.addEventListener('input', () => {
                markValue(); filterMenu(); aptCombo.classList.add('open');
                this.commitAirportRadius(root);
            });
            input.addEventListener('focus', openMenu);
            input.addEventListener('blur', () => setTimeout(closeMenu, 180));
            if (caret) caret.addEventListener('mousedown', (e) => {
                e.preventDefault();
                aptCombo.classList.contains('open') ? closeMenu() : (input.focus(), openMenu());
            });
            if (clear) clear.addEventListener('click', () => {
                input.value = ''; markValue(); this.commitAirportRadius(root); closeMenu();
            });
            if (menu) menu.querySelectorAll('.m-combo-opt').forEach(opt => {
                opt.addEventListener('mousedown', (e) => {
                    e.preventDefault();
                    window.InflightHaptics?.select?.();
                    input.value = opt.dataset.value; markValue();
                    this.commitAirportRadius(root); closeMenu();
                });
            });
        }
        const aptNum = root.querySelector('.m-apt-radius-num');
        if (aptNum) aptNum.addEventListener('input', () => this.commitAirportRadius(root));

        // Reset.
        const resetBtn = root.querySelector('#m-filter-reset');
        if (resetBtn) resetBtn.addEventListener('click', () => {
            window.InflightHaptics?.select?.();
            this.resetTacticalFilters(root);
        });
    },

    // Reflect the current mapFilters/tactical state into the board's controls.
    syncTacticalControls(root) {
        if (!root) return;
        const filters = window.mapFilters || {};
        const tactical = filters.tactical || {};

        root.querySelectorAll('input[type="checkbox"][data-setting]').forEach(input => {
            input.checked = !!filters[input.dataset.setting];
        });
        root.querySelectorAll('select[data-setting]').forEach(sel => {
            sel.value = filters[sel.dataset.setting] || '';
        });
        root.querySelectorAll('.m-combo[data-tactical]').forEach(combo => {
            const input = combo.querySelector('.m-combo-input');
            const val = tactical[combo.dataset.tactical];
            if (input) {
                input.value = (val !== undefined && val !== null && typeof val !== 'object') ? val : '';
                combo.classList.toggle('has-value', !!input.value.trim());
            }
        });
        root.querySelectorAll('.m-tac-pill').forEach(pill => {
            const current = tactical[pill.dataset.tactical] || '';
            pill.classList.toggle('active', pill.dataset.value === current);
        });
        root.querySelectorAll('.m-range-row[data-tactical-range]').forEach(row => {
            const range = tactical[row.dataset.tacticalRange] || {};
            row.querySelectorAll('.m-range-num').forEach(num => {
                const b = num.dataset.bound;
                num.value = (range[b] !== undefined && range[b] !== null) ? range[b] : '';
            });
        });

        // Airport-proximity inputs.
        const ar = tactical.airportRadius || {};
        const aptIcao = root.querySelector('.m-apt-radius-icao');
        const aptNum = root.querySelector('.m-apt-radius-num');
        if (aptIcao) {
            aptIcao.value = ar.icao || '';
            const c = root.querySelector('.m-apt-radius-combo');
            if (c) c.classList.toggle('has-value', !!aptIcao.value.trim());
        }
        if (aptNum) aptNum.value = (ar.radiusNm !== undefined && ar.radiusNm !== null) ? ar.radiusNm : '';

        this.updateFilterBadge();
    },

    attachMobileListeners() {
        const sheet = document.querySelector('#mobile-settings-nexus .mobile-bottom-sheet');
        const overlay = document.getElementById('mobile-settings-overlay');

        window.addEventListener('openMobileSettings', () => {
            this._isOpen = true;
            this.refreshProLocks();
            this.syncUIWithState();
            this.refreshNotificationStatus();
            sheet.classList.add('open');
            overlay.classList.add('visible');
        });

        // Tab switching
        sheet.querySelectorAll('.m-tab').forEach(tab => {
            tab.addEventListener('click', () => {
                window.InflightHaptics?.select?.();
                this.switchTab(tab.dataset.tab);
            });
        });

        const notifBtn = document.getElementById('m-notif-enable');
        if (notifBtn) {
            notifBtn.addEventListener('click', async () => {
                const pill = document.getElementById('m-notif-status');
                const isBlocked = pill && pill.dataset.status === 'denied';
                notifBtn.disabled = true;
                const prevLabel = notifBtn.textContent;
                notifBtn.textContent = '…';
                try {
                    if (!window.InflightLiveActivity || typeof window.InflightLiveActivity.requestNotificationPermission !== 'function') {
                        window.showNotification?.('Native bridge missing. Reinstall the latest TestFlight build.', 'error');
                        return;
                    }
                    if (isBlocked) {
                        await window.InflightLiveActivity.openSystemSettings?.();
                    } else {
                        const res = await window.InflightLiveActivity.requestNotificationPermission({ force: true });
                        console.log('[Notifications] requestNotificationPermission ->', res);
                        if (!res || res.ok === false) {
                            const reason = (res && res.reason) ? String(res.reason) : 'no response';
                            window.showNotification?.(`Permission request failed: ${reason}`, 'error');
                        } else if (res.granted === true) {
                            window.showNotification?.('Notifications enabled.', 'success');
                        } else if (res.granted === false && res.prompted === false && res.status === 'denied') {
                            // Already denied — deep-link to Settings on this same tap.
                            await window.InflightLiveActivity.openSystemSettings?.();
                        } else if (res.granted === false && res.prompted === true) {
                            window.showNotification?.('You tapped Don\'t Allow. Re-enable in iOS Settings › Inflight.', 'info');
                        }
                    }
                } catch (err) {
                    console.error('[Notifications] click handler error:', err);
                    window.showNotification?.(`Error: ${err && err.message || err}`, 'error');
                }
                await this.refreshNotificationStatus();
                notifBtn.disabled = false;
                if (notifBtn.textContent === '…') notifBtn.textContent = prevLabel;
            });
        }

        const closeUI = () => {
            this._isOpen = false;
            sheet.classList.remove('open');
            overlay.classList.remove('visible');
            if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
        };

        overlay.addEventListener('click', closeUI);
        document.getElementById('mobile-settings-close').addEventListener('click', closeUI);
        this.attachSwipeToDismiss(sheet, closeUI);

        // --- Pro Feature Intercept Logic ---
        const iosNative = (typeof window !== 'undefined' && window.isIOSNative && window.isIOSNative());
        sheet.querySelectorAll('.is-pro-feature').forEach(row => {
            row.addEventListener('click', (e) => {
                if (row.classList.contains('locked')) {
                    e.preventDefault();
                    e.stopPropagation();

                    if (iosNative) {
                        // App Store compliance: no in-app upgrade path. The lock
                        // remains visible but the click is a no-op.
                        return;
                    }

                    closeUI(); // Smoothly dismiss the settings sheet

                    setTimeout(() => {
                        if (window.initInflightPro) {
                            window.initInflightPro();
                        } else if (window.AuthUI) {
                            window.AuthUI.open('signup');
                        } else {
                            const proTrigger = document.getElementById('pro-signup-trigger');
                            if (proTrigger) proTrigger.click();
                        }
                    }, 350);
                }
            }, true); // Capture phase to prevent inner inputs from firing
        });

        // ATC Tag Studio controls (write into mapFilters.atcTagConfig).
        this.attachAtcTagHandlers(sheet);

        // Checkbox Listener (skips label-field and ATC-tag rows, handled separately)
        sheet.querySelectorAll('input[type="checkbox"]:not(.m-label-field-input):not(.m-atc-input)').forEach(input => {
            input.addEventListener('change', (e) => {
                if (e.target.closest('.locked')) return; // Extra layer of protection

                window.InflightHaptics?.select?.();
                const setting = e.target.dataset.setting;
                const isPro = e.target.dataset.pro === 'true';

                if (isPro) {
                    if (!window.mapFilters.proMapConfig) window.mapFilters.proMapConfig = {};
                    window.mapFilters.proMapConfig[setting] = e.target.checked;

                    if (window.updateBaseMapLayerVisibility) window.updateBaseMapLayerVisibility();
                    if (window.updatePro3DLayers) window.updatePro3DLayers();
                } else if (setting === 'live3DTraffic' && window.setLive3DTraffic) {
                    // The 3D live-traffic dot field needs more than a flag flip:
                    // it swaps the flat icon layers for the THREE dot field,
                    // persists the preference, and keeps the desktop controls in
                    // sync. Route through the canonical toggle to do all of that.
                    window.setLive3DTraffic(e.target.checked);
                    return;
                } else {
                    window.mapFilters[setting] = e.target.checked;
                }

                if (setting === 'showAircraftLabels') this.updateLabelPreview();
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });

        // Aircraft-label row toggles — update mapFilters.labelConfig, refresh
        // the live preview, and re-apply the on-map label style.
        sheet.querySelectorAll('.m-label-field-input').forEach(input => {
            input.addEventListener('change', (e) => {
                window.InflightHaptics?.select?.();
                const key = e.target.dataset.labelField;
                if (!window.mapFilters.labelConfig) window.mapFilters.labelConfig = {};
                window.mapFilters.labelConfig[key] = e.target.checked;
                this.updateLabelPreview();
                if (window.applyAircraftLabelStyle) window.applyAircraftLabelStyle();
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
            });
        });

        // Label color theme pills
        sheet.querySelectorAll('.m-theme-pill').forEach(btn => {
            btn.addEventListener('click', () => {
                if (btn.classList.contains('locked')) return; // pro intercept handles upsell
                window.InflightHaptics?.select?.();
                const theme = btn.dataset.labelTheme;
                window.mapFilters.labelTheme = theme;
                sheet.querySelectorAll('.m-theme-pill').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                this.updateLabelPreview();
                if (window.applyAircraftLabelStyle) window.applyAircraftLabelStyle();
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
            });
        });

        // Map-style preview cards
        sheet.querySelectorAll('.m-style-card').forEach(card => {
            card.addEventListener('click', () => {
                if (card.classList.contains('locked')) return; // pro intercept handles upsell
                window.InflightHaptics?.select?.();
                const value = card.dataset.value;
                window.mapFilters.mapStyle = value;
                sheet.querySelectorAll('.m-style-card').forEach(c => c.classList.remove('active'));
                card.classList.add('active');
                if (window.updateMapFilters) window.updateMapFilters();
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
            });
        });

        // Color Picker Listener (ATC-tag pickers carry data-atc-tag instead
        // of data-setting and are handled by attachAtcTagHandlers)
        sheet.querySelectorAll('input[type="color"][data-setting]').forEach(input => {
            input.addEventListener('input', (e) => {
                if (e.target.closest('.locked')) return;
                const setting = e.target.dataset.setting;
                window.mapFilters[setting] = e.target.value;
                // Picking the global custom color switches into the dedicated
                // 'custom' mode so it actually recolors every other aircraft
                // (those planes move onto the tintable SDF layer).
                if (setting === 'proCustomColor') {
                    window.mapFilters.iconColorMode = 'custom';
                }
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });

        // Range Slider Listener (the ATC-tag opacity slider has no
        // data-setting; attachAtcTagHandlers owns it)
        sheet.querySelectorAll('.m-range-input[data-setting]').forEach(input => {
            input.addEventListener('input', (e) => {
                const setting = e.target.dataset.setting;
                const val = e.target.value;
                window.mapFilters[setting] = parseFloat(val);
                const label = document.getElementById(`m-val-${setting}`);
                if (label) {
                    label.textContent = this.formatRangeValue(setting, val);
                }
                if (setting === 'labelScale') {
                    this.updateLabelPreview();
                    if (window.applyAircraftLabelStyle) window.applyAircraftLabelStyle();
                    if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
                } else if (window.updateMapFilters) {
                    window.updateMapFilters();
                }
            });
        });

        // Setting Pills Listener
        sheet.querySelectorAll('.m-setting-pill').forEach(btn => {
            btn.addEventListener('click', () => {
                window.InflightHaptics?.select?.();
                const setting = btn.dataset.setting;
                const value = btn.dataset.value;
                window.mapFilters[setting] = value;
                btn.parentElement.querySelectorAll('.m-setting-pill').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });

        // ---- Tactical filter combobox inputs ----
        sheet.querySelectorAll('.m-combo').forEach(combo => {
            const key = combo.dataset.tactical;
            const input = combo.querySelector('.m-combo-input');
            const menu = combo.querySelector('.m-combo-menu');
            const caret = combo.querySelector('.m-combo-caret');
            const clear = combo.querySelector('.m-combo-clear');
            const presetOnly = combo.classList.contains('is-preset-only');

            const markValue = () => combo.classList.toggle('has-value', !!input.value.trim());

            const filterMenu = () => {
                if (!menu) return;
                const q = input.value.trim().toLowerCase();
                menu.querySelectorAll('.m-combo-opt').forEach(opt => {
                    const match = !q || opt.textContent.toLowerCase().includes(q) ||
                        (opt.dataset.value || '').toLowerCase().includes(q);
                    opt.style.display = match ? '' : 'none';
                });
            };
            const openMenu = () => { if (menu) { filterMenu(); combo.classList.add('open'); } };
            const closeMenu = () => combo.classList.remove('open');

            if (!presetOnly) {
                input.addEventListener('input', () => {
                    markValue();
                    filterMenu();
                    combo.classList.add('open');
                    this.setTactical(key, input.value);
                });
            }
            input.addEventListener('focus', openMenu);
            // Delay so an option tap registers before the menu collapses.
            input.addEventListener('blur', () => setTimeout(closeMenu, 180));

            if (caret) caret.addEventListener('mousedown', (e) => {
                e.preventDefault();
                combo.classList.contains('open') ? closeMenu() : (input.focus(), openMenu());
            });

            if (clear) clear.addEventListener('click', () => {
                input.value = '';
                markValue();
                this.setTactical(key, '');
                closeMenu();
            });

            if (menu) menu.querySelectorAll('.m-combo-opt').forEach(opt => {
                // mousedown fires before the input blur, so the value sticks.
                opt.addEventListener('mousedown', (e) => {
                    e.preventDefault();
                    window.InflightHaptics?.select?.();
                    input.value = opt.dataset.value;
                    markValue();
                    this.setTactical(key, opt.dataset.value);
                    closeMenu();
                });
            });
        });

        // ---- Tactical pill rows (category / phase) ----
        sheet.querySelectorAll('.m-tac-pill').forEach(pill => {
            pill.addEventListener('click', () => {
                window.InflightHaptics?.select?.();
                const key = pill.dataset.tactical;
                const value = pill.dataset.value;
                pill.parentElement.querySelectorAll('.m-tac-pill').forEach(p => p.classList.remove('active'));
                pill.classList.add('active');
                this.setTactical(key, value);
            });
        });

        // ---- Tactical numeric ranges (altitude / speed) ----
        sheet.querySelectorAll('.m-range-row').forEach(row => {
            const key = row.dataset.tacticalRange;
            row.querySelectorAll('.m-range-num').forEach(num => {
                num.addEventListener('input', () => {
                    this.setTacticalRange(key, num.dataset.bound, num.value);
                });
            });
        });

        // ---- Reset all tactical filters ----
        const resetBtn = document.getElementById('m-filter-reset');
        if (resetBtn) resetBtn.addEventListener('click', () => {
            window.InflightHaptics?.select?.();
            this.resetTacticalFilters();
        });

        // Legal document rows — open privacy.html / terms.html in the shared
        // in-app viewer (layers above this sheet; its back button returns here).
        sheet.querySelectorAll('.m-legal-row').forEach(row => {
            row.addEventListener('click', () => {
                const doc = row.dataset.doc;
                const title = row.dataset.title || 'Document';
                if (typeof openLegalDoc === 'function') {
                    openLegalDoc(doc, title);
                }
            });
        });

        // Dropdown Listener (e.g. Virtual Airline filter)
        sheet.querySelectorAll('select[data-setting]').forEach(sel => {
            sel.addEventListener('change', (e) => {
                const setting = e.target.dataset.setting;
                window.mapFilters[setting] = e.target.value;
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });
    },

    // Re-renders the live label preview from the current mapFilters config so
    // it always matches what the map will draw.
    updateLabelPreview() {
        const preview = document.getElementById('m-label-preview');
        if (!preview) return;
        const filters = window.mapFilters || {};
        const cfg = filters.labelConfig || {};

        const lines = [];
        if (cfg.callsign)     lines.push({ text: LABEL_PREVIEW_SAMPLE.callsign, cls: 'l-callsign' });
        if (cfg.pilot)        lines.push({ text: LABEL_PREVIEW_SAMPLE.pilot, cls: 'l-sub' });
        if (cfg.aircraftType) lines.push({ text: LABEL_PREVIEW_SAMPLE.aircraftType, cls: 'l-sub' });
        if (cfg.registration) lines.push({ text: LABEL_PREVIEW_SAMPLE.registration, cls: 'l-sub' });
        if (cfg.route)        lines.push({ text: LABEL_PREVIEW_SAMPLE.route, cls: 'l-sub' });
        if (cfg.altSpeed)     lines.push({ text: LABEL_PREVIEW_SAMPLE.altSpeed, cls: 'l-sub' });
        if (!lines.length)    lines.push({ text: LABEL_PREVIEW_SAMPLE.callsign, cls: 'l-callsign' });

        const theme = LABEL_THEME_DEFS.find(t => t.value === (filters.labelTheme || 'default')) || LABEL_THEME_DEFS[0];
        const scale = Math.min(1.4, Math.max(0.8, parseFloat(filters.labelScale) || 1));

        // The on-map logo badge floats above the plane, but the preview stacks
        // it on top of the text rows — same visual recipe (white badge chip).
        const logoLine = cfg.airlineLogo
            ? `<img class="m-label-logo" src="${LABEL_PREVIEW_SAMPLE.airlineLogo}" alt="" onerror="this.style.display='none'">`
            : '';

        preview.style.color = theme.text;
        preview.style.textShadow = `0 0 3px ${theme.halo}, 0 1px 2px ${theme.halo}, 0 0 4px ${theme.halo}`;
        preview.style.fontSize = `${0.95 * scale}rem`;
        preview.innerHTML = logoLine + lines.map(l => `<div class="${l.cls}">${l.text}</div>`).join('');
        preview.style.opacity = filters.showAircraftLabels ? '1' : '0.35';
    },

    async refreshNotificationStatus() {
        const pill = document.getElementById('m-notif-status');
        const btn = document.getElementById('m-notif-enable');
        const section = document.getElementById('m-notif-section');
        if (!pill || !btn) return;

        const hasBridge = !!(window.InflightLiveActivity &&
            typeof window.InflightLiveActivity.getNotificationPermissionStatus === 'function');
        if (!hasBridge) {
            // No native bridge (e.g. web preview) — notifications don't apply
            // here, so hide the whole section rather than show an error state.
            if (section) section.style.display = 'none';
            return;
        }
        if (section) section.style.display = '';

        let status = 'unknown';
        let granted = false;
        try {
            const res = await window.InflightLiveActivity.getNotificationPermissionStatus();
            console.log('[Notifications] status ->', res);
            if (res) { status = res.status || 'unknown'; granted = !!res.granted; }
        } catch (err) {
            console.warn('[Notifications] status failed:', err);
            status = 'error';
        }
        pill.dataset.status = status;
        if (granted) {
            pill.textContent = 'Allowed';
            btn.textContent = 'Re-prompt';
        } else if (status === 'denied') {
            pill.textContent = 'Blocked in iOS';
            btn.textContent = 'Open Settings';
        } else if (status === 'notDetermined' || status === 'unknown') {
            pill.textContent = 'Not enabled';
            btn.textContent = 'Enable';
        } else {
            pill.textContent = status;
            btn.textContent = 'Enable';
        }
    },

    syncUIWithState() {
        const filters = window.mapFilters;
        if (!filters) return;
        const container = document.getElementById('mobile-settings-nexus');

        container.querySelectorAll('input[type="checkbox"]:not(.m-label-field-input):not(.m-atc-input)').forEach(input => {
            const isPro = input.dataset.pro === 'true';
            if (isPro) {
                input.checked = !!(filters.proMapConfig && filters.proMapConfig[input.dataset.setting]);
            } else {
                input.checked = !!filters[input.dataset.setting];
            }
        });

        // Label field row toggles
        const cfg = filters.labelConfig || {};
        container.querySelectorAll('.m-label-field-input').forEach(input => {
            input.checked = !!cfg[input.dataset.labelField];
        });

        // Label theme pills
        const activeTheme = filters.labelTheme || 'default';
        container.querySelectorAll('.m-theme-pill').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.labelTheme === activeTheme);
        });

        // Map-style preview cards
        const activeStyle = filters.mapStyle || 'dark';
        container.querySelectorAll('.m-style-card').forEach(card => {
            card.classList.toggle('active', card.dataset.value === activeStyle);
        });

        container.querySelectorAll('input[type="color"][data-setting]').forEach(input => {
            const val = filters[input.dataset.setting];
            if (val) input.value = val;
        });

        // Sync Dropdowns (e.g. Virtual Airline filter)
        container.querySelectorAll('select[data-setting]').forEach(sel => {
            const setting = sel.dataset.setting;
            if (setting) sel.value = filters[setting] || '';
        });

        container.querySelectorAll('.m-range-input[data-setting]').forEach(input => {
            const setting = input.dataset.setting;
            const val = filters[setting];
            if (val !== undefined && val !== null) input.value = val;
            const label = document.getElementById(`m-val-${setting}`);
            if (label && val !== undefined && val !== null) {
                label.textContent = this.formatRangeValue(setting, val);
            }
        });

        container.querySelectorAll('.m-setting-pill').forEach(btn => {
            const setting = btn.dataset.setting;
            const value = btn.dataset.value;
            if (filters[setting] === value) {
                btn.classList.add('active');
            } else {
                btn.classList.remove('active');
            }
        });

        // Tactical filters → comboboxes, pills, ranges
        const tactical = filters.tactical || {};
        container.querySelectorAll('.m-combo').forEach(combo => {
            const key = combo.dataset.tactical;
            const input = combo.querySelector('.m-combo-input');
            const val = tactical[key];
            if (input) {
                input.value = (val !== undefined && val !== null && typeof val !== 'object') ? val : '';
                combo.classList.toggle('has-value', !!input.value.trim());
            }
        });
        container.querySelectorAll('.m-tac-pill').forEach(pill => {
            const key = pill.dataset.tactical;
            const current = tactical[key] || '';
            pill.classList.toggle('active', pill.dataset.value === current);
        });
        container.querySelectorAll('.m-range-row').forEach(row => {
            const key = row.dataset.tacticalRange;
            const range = tactical[key] || {};
            row.querySelectorAll('.m-range-num').forEach(num => {
                const b = num.dataset.bound;
                num.value = (range[b] !== undefined && range[b] !== null) ? range[b] : '';
            });
        });
        this.updateFilterBadge();

        this.updateLabelPreview();
        this.syncAtcTagControls();
    },

    // iOS-style swipe-down-to-dismiss. The user can drag from the grabber or
    // the title bar to flick the sheet away — the native gesture that replaces
    // the old explicit "Done" button.
    attachSwipeToDismiss(sheet, closeUI) {
        const grabbers = sheet.querySelectorAll('.sheet-handle, .mobile-title');
        let startY = 0, delta = 0, dragging = false;
        const start = (e) => {
            startY = e.touches ? e.touches[0].clientY : e.clientY;
            delta = 0; dragging = true;
            sheet.style.transition = 'none';
        };
        const move = (e) => {
            if (!dragging) return;
            const y = e.touches ? e.touches[0].clientY : e.clientY;
            delta = Math.max(0, y - startY);
            sheet.style.transform = `translateY(${delta}px)`;
        };
        const end = () => {
            if (!dragging) return;
            dragging = false;
            sheet.style.transition = '';
            sheet.style.transform = '';
            if (delta > 110) closeUI();
        };
        grabbers.forEach(g => {
            g.addEventListener('touchstart', start, { passive: true });
            g.addEventListener('touchmove', move, { passive: true });
            g.addEventListener('touchend', end);
            g.addEventListener('touchcancel', end);
        });
    },

    injectMobileStyles() {
        if (document.getElementById('mobile-settings-styles')) return;
        const css = `
            @media (max-width: 768px) {
                #mobile-settings-nexus .mobile-sheet-overlay {
                    position: fixed; inset: 0; background: rgba(0,0,0,0.7);
                    backdrop-filter: blur(4px); opacity: 0; visibility: hidden; transition: 0.3s; z-index: 6000;
                }
                #mobile-settings-nexus .mobile-sheet-overlay.visible { opacity: 1; visibility: visible; }

                #mobile-settings-nexus .mobile-bottom-sheet {
                    position: fixed; bottom: -100%; left: 0; width: 100%; height: 82vh;
                    background: #0a0a0b; border-top: 1px solid rgba(255,255,255,0.1);
                    border-radius: 24px 24px 0 0; z-index: 6001; transition: 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                    display: flex; flex-direction: column; color: white; padding-bottom: env(safe-area-inset-bottom);
                }
                #mobile-settings-nexus .mobile-bottom-sheet.open { bottom: 0; }

                .sheet-handle { width: 40px; height: 5px; background: rgba(255,255,255,0.2); border-radius: 10px; margin: 12px auto 6px; }
                .mobile-title { padding: 4px 20px 12px; font-size: 1.35rem; font-weight: 800; display: flex; align-items: center; gap: 12px; letter-spacing: -0.02em; }
                .mobile-title i { color: #38bdf8; }

                /* iOS-style circular close button (replaces the old "Done" button) */
                #mobile-settings-nexus .sheet-close-btn {
                    position: absolute; top: 14px; right: 14px;
                    width: 30px; height: 30px; border-radius: 50%; padding: 0;
                    display: flex; align-items: center; justify-content: center;
                    background: rgba(120,120,128,0.32); color: rgba(235,235,245,0.65);
                    border: none; font-size: 14px; z-index: 5;
                    -webkit-tap-highlight-color: transparent;
                    transition: transform 0.15s ease, background-color 0.15s ease;
                }
                #mobile-settings-nexus .sheet-close-btn:active {
                    transform: scale(0.92); background: rgba(120,120,128,0.5);
                }

                /* Segmented tab bar */
                .m-tabbar {
                    display: flex; gap: 4px; margin: 0 16px 6px; padding: 4px;
                    background: rgba(255,255,255,0.05); border-radius: 14px;
                }
                .m-tab {
                    flex: 1; display: flex; flex-direction: column; align-items: center; gap: 3px;
                    background: transparent; border: none; color: #71717a;
                    padding: 8px 2px; border-radius: 10px; font-size: 0.62rem; font-weight: 700;
                    letter-spacing: 0.02em; transition: 0.2s; -webkit-tap-highlight-color: transparent;
                }
                .m-tab i { font-size: 0.95rem; }
                .m-tab.active { background: #18181b; color: #fff; box-shadow: 0 1px 4px rgba(0,0,0,0.4); }
                .m-tab.active i { color: #38bdf8; }

                .m-panel { display: none; padding-bottom: 24px; animation: mFade 0.25s ease; }
                .m-panel.active { display: block; }
                @keyframes mFade { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }

                .mobile-section-header { padding: 16px 20px 8px; font-size: 0.7rem; font-weight: 900; color: #71717a; text-transform: uppercase; letter-spacing: 1px; }
                .mobile-section-header.pro-accent { color: #fbbf24; display: flex; align-items: center; gap: 6px; }

                .settings-mobile-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; padding: 0 20px; }
                .m-setting-pill {
                    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1);
                    color: #a1a1aa; padding: 10px; border-radius: 12px; font-weight: 600; font-size: 0.8rem;
                }
                .m-setting-pill.active { background: #38bdf8; color: black; border-color: #38bdf8; }

                /* ---- Map style preview cards ---- */
                .m-style-grid {
                    display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; padding: 0 20px;
                }
                .m-style-card {
                    background: transparent; border: none; padding: 0; cursor: pointer;
                    display: flex; flex-direction: column; gap: 6px; -webkit-tap-highlight-color: transparent;
                }
                .m-style-thumb {
                    position: relative; display: block; width: 100%; aspect-ratio: 16 / 10;
                    border-radius: 12px; border: 2px solid rgba(255,255,255,0.12);
                    background-color: #18181b; overflow: hidden; transition: 0.2s;
                }
                .m-style-card.active .m-style-thumb {
                    border-color: #38bdf8; box-shadow: 0 0 0 2px rgba(56,189,248,0.35);
                }
                .m-style-card:active .m-style-thumb { transform: scale(0.96); }
                .m-style-name { font-size: 0.72rem; font-weight: 600; color: #a1a1aa; text-align: center; }
                .m-style-card.active .m-style-name { color: #fff; }
                .m-style-check {
                    position: absolute; top: 5px; right: 5px; width: 20px; height: 20px;
                    border-radius: 50%; background: #38bdf8; color: #000; display: none;
                    align-items: center; justify-content: center; font-size: 0.65rem;
                }
                .m-style-card.active .m-style-check { display: flex; }
                .m-style-pro {
                    position: absolute; top: 5px; left: 5px; width: 20px; height: 20px;
                    border-radius: 50%; background: linear-gradient(135deg,#fbbf24,#d97706); color: #000;
                    display: flex; align-items: center; justify-content: center; font-size: 0.55rem;
                }
                html.ios-native .m-style-pro { display: none !important; }

                .m-settings-list { padding: 0 20px; display: flex; flex-direction: column; gap: 8px; }
                .m-setting-row {
                    display: flex; justify-content: space-between; align-items: center;
                    background: rgba(255,255,255,0.03); padding: 14px; border-radius: 14px; transition: 0.2s;
                }
                .m-row-left { display: flex; align-items: center; gap: 12px; font-size: 0.9rem; }
                .m-row-left i { color: #38bdf8; width: 16px; text-align: center; }

                .m-row-right { display: flex; align-items: center; gap: 10px; }

                /* Premium Pro Lock Styles */
                .pro-lock-badge {
                    display: none;
                    background: linear-gradient(135deg, #fbbf24 0%, #d97706 100%);
                    color: #000;
                    font-size: 0.65rem;
                    font-weight: 800;
                    padding: 4px 8px;
                    border-radius: 6px;
                    letter-spacing: 0.5px;
                    text-transform: uppercase;
                    box-shadow: 0 2px 4px rgba(0,0,0,0.3);
                }
                .is-pro-feature.locked {
                    opacity: 0.75;
                    cursor: pointer;
                }
                .is-pro-feature.locked .pro-lock-badge {
                    display: flex; align-items: center;
                }
                /* App Store compliance: never surface PRO tier labels in iOS. */
                html.ios-native .pro-lock-badge,
                html.ios-native .is-pro-feature.locked .pro-lock-badge {
                    display: none !important;
                }
                .is-pro-feature.locked .m-switch,
                .is-pro-feature.locked .m-color-picker {
                    opacity: 0.3;
                    pointer-events: none;
                    filter: grayscale(100%);
                }
                .m-theme-pill.is-pro-feature.locked .m-theme-lock { display: flex; }

                /* Custom Color Picker Styles */
                .m-color-picker {
                    -webkit-appearance: none;
                    border: none;
                    width: 36px;
                    height: 36px;
                    border-radius: 10px;
                    cursor: pointer;
                    padding: 0;
                    background: transparent;
                }
                .m-color-picker::-webkit-color-swatch-wrapper { padding: 0; }
                .m-color-picker::-webkit-color-swatch { border: 2px solid rgba(255,255,255,0.2); border-radius: 10px; }

                .m-switch { position: relative; display: inline-block; width: 46px; height: 24px; }
                .m-switch input { opacity: 0; width: 0; height: 0; }
                .m-slider { position: absolute; cursor: pointer; inset: 0; background-color: #27272a; transition: .4s; border-radius: 34px; }
                .m-slider:before { position: absolute; content: ""; height: 18px; width: 18px; left: 3px; bottom: 3px; background-color: white; transition: .4s; border-radius: 50%; }
                input:checked + .m-slider { background-color: #38bdf8; }
                input:checked + .m-slider:before { transform: translateX(22px); }

                .m-setting-range-card { margin: 0 20px; background: rgba(255,255,255,0.03); padding: 16px; border-radius: 14px; }
                .range-header { display: flex; justify-content: space-between; font-size: 0.85rem; margin-bottom: 12px; }
                .m-range-input { width: 100%; accent-color: #38bdf8; }

                /* ---- Aircraft label live preview ---- */
                .m-label-preview-stage {
                    margin: 0 20px; padding: 22px 16px; border-radius: 16px;
                    background:
                        radial-gradient(circle at 30% 30%, rgba(56,189,248,0.10), transparent 60%),
                        repeating-linear-gradient(0deg, rgba(255,255,255,0.04) 0 1px, transparent 1px 26px),
                        repeating-linear-gradient(90deg, rgba(255,255,255,0.04) 0 1px, transparent 1px 26px),
                        #0c1322;
                    border: 1px solid rgba(255,255,255,0.08);
                    display: flex; flex-direction: column; align-items: center; gap: 8px; min-height: 120px;
                    justify-content: center;
                }
                .m-label-plane { color: #38bdf8; font-size: 1.4rem; filter: drop-shadow(0 2px 6px rgba(56,189,248,0.5)); }
                .m-label-preview { text-align: center; line-height: 1.35; font-weight: 600; transition: 0.2s; }
                .m-label-preview .l-callsign { font-weight: 800; letter-spacing: 0.02em; }
                .m-label-preview .l-sub { font-size: 0.82em; font-weight: 600; opacity: 0.95; }
                .m-label-preview .m-label-logo {
                    display: block; height: 26px; width: auto; max-width: 110px; margin: 0 auto 5px;
                    padding: 4px 8px; border-radius: 8px; background: #fff; object-fit: contain;
                    border: 1px solid rgba(15,23,42,0.35); box-shadow: 0 1px 5px rgba(0,0,0,0.45);
                    box-sizing: border-box;
                }

                /* Trademark / non-affiliation note for the airline-logo label row. */
                .m-label-disclaimer {
                    display: flex; gap: 10px; align-items: flex-start;
                    margin: 10px 20px 0; padding: 11px 13px; border-radius: 12px;
                    background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.07);
                    font-size: 0.7rem; line-height: 1.5; color: #71717a;
                }
                .m-label-disclaimer i { color: #38bdf8; font-size: 0.75rem; margin-top: 2px; flex-shrink: 0; }
                .m-label-disclaimer a { color: #7dd3fc; text-decoration: none; word-break: break-all; }

                /* ---- Label color theme grid ---- */
                .m-theme-grid {
                    display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; padding: 0 20px;
                }
                .m-theme-pill {
                    position: relative; background: rgba(255,255,255,0.04); border: 1.5px solid rgba(255,255,255,0.1);
                    border-radius: 12px; padding: 8px 4px 6px; display: flex; flex-direction: column;
                    align-items: center; gap: 5px; cursor: pointer; -webkit-tap-highlight-color: transparent;
                }
                .m-theme-pill.active { border-color: #38bdf8; background: rgba(56,189,248,0.12); }
                .m-theme-swatch {
                    width: 34px; height: 26px; border-radius: 7px; display: flex; align-items: center;
                    justify-content: center; font-size: 0.72rem; font-weight: 800;
                }
                .m-theme-name { font-size: 0.6rem; font-weight: 700; color: #a1a1aa; }
                .m-theme-pill.active .m-theme-name { color: #fff; }
                .m-theme-lock {
                    display: none; position: absolute; top: 4px; right: 4px; width: 15px; height: 15px;
                    border-radius: 50%; background: linear-gradient(135deg,#fbbf24,#d97706); color: #000;
                    align-items: center; justify-content: center; font-size: 0.45rem;
                }
                html.ios-native .m-theme-lock { display: none !important; }

                /* ---- ATC Tag Studio ---- */
                .m-atc-stage {
                    margin: 0 20px 8px; padding: 22px 16px; border-radius: 16px;
                    background:
                        radial-gradient(circle at 30% 30%, rgba(251,191,36,0.08), transparent 60%),
                        repeating-linear-gradient(0deg, rgba(255,255,255,0.04) 0 1px, transparent 1px 26px),
                        repeating-linear-gradient(90deg, rgba(255,255,255,0.04) 0 1px, transparent 1px 26px),
                        #0c1322;
                    border: 1px solid rgba(255,255,255,0.08);
                    display: flex; align-items: center; justify-content: center; min-height: 74px;
                }
                /* The replica uses the map's own .apt-live-tag styles
                   (injected globally by flight.js); it just needs its own
                   positioning context for the pulse ring + a bump in size
                   so it reads as a preview, not a speck. */
                .m-atc-stage .apt-live-tag {
                    position: relative; transform: scale(1.5); transform-origin: center;
                    cursor: default; pointer-events: none;
                }
                .m-atc-style-row { flex-direction: column; align-items: stretch; gap: 10px; }
                .m-atc-style-pills { display: flex; flex-wrap: wrap; gap: 8px; }
                .m-atc-pill {
                    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1);
                    color: #a1a1aa; padding: 8px 12px; border-radius: 10px; font-weight: 700;
                    font-size: 0.75rem; -webkit-tap-highlight-color: transparent;
                }
                .m-atc-pill.active { background: #38bdf8; color: #000; border-color: #38bdf8; }
                #m-atc-tag-options { transition: opacity 0.2s; }
                #m-atc-tag-options.is-off { opacity: 0.45; pointer-events: none; }
                .is-pro-feature.locked .m-atc-pill,
                .is-pro-feature.locked .m-range-input {
                    opacity: 0.3; pointer-events: none; filter: grayscale(100%);
                }

                /* ---- ATC Tag Studio: preset roulette ---- */
                .m-atc-roulette {
                    display: flex; align-items: stretch; gap: 8px; margin: 0 20px 8px;
                }
                .m-atc-roulette-arrow {
                    width: 42px; border-radius: 12px; border: 1px solid rgba(255,255,255,0.1);
                    background: rgba(255,255,255,0.05); color: #a1a1aa; font-size: 0.85rem;
                    -webkit-tap-highlight-color: transparent;
                }
                .m-atc-roulette-arrow:active { background: rgba(56,189,248,0.18); color: #fff; }
                .m-atc-roulette-window {
                    flex: 1; text-align: center; padding: 9px 8px; border-radius: 12px;
                    background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1);
                }
                .m-atc-roulette-name { font-size: 0.92rem; font-weight: 800; color: #fff; }
                .m-atc-roulette-count {
                    font-size: 0.6rem; font-weight: 700; color: #71717a;
                    text-transform: uppercase; letter-spacing: 0.08em; margin-top: 2px;
                }
                .m-atc-spin {
                    display: flex; align-items: center; justify-content: center; gap: 8px;
                    margin: 0 20px 4px; width: calc(100% - 40px); padding: 12px;
                    border-radius: 12px; border: none; font-size: 0.85rem; font-weight: 800;
                    background: linear-gradient(135deg, #fbbf24, #d97706); color: #000;
                    -webkit-tap-highlight-color: transparent; transition: transform 0.15s ease;
                }
                .m-atc-spin:active { transform: scale(0.97); }
                .is-pro-feature.locked .m-atc-roulette-arrow,
                .m-atc-spin.locked {
                    opacity: 0.3; pointer-events: none; filter: grayscale(100%);
                }

                .sheet-footer { padding: 20px; border-top: 1px solid rgba(255,255,255,0.05); }
                .m-btn { width: 100%; padding: 16px; border-radius: 14px; font-weight: 700; border: none; font-size: 1rem; }
                .m-primary { background: #38bdf8; color: #000; }

                .m-notif-cta { width: auto; padding: 8px 14px; font-size: 0.85rem; border-radius: 999px; }
                .m-notif-cta[disabled] { opacity: 0.6; }
                .m-notif-status {
                    font-size: 0.75rem; font-weight: 600; padding: 4px 10px;
                    border-radius: 999px; margin-right: 8px; letter-spacing: 0.02em;
                    background: rgba(148,163,184,0.18); color: #cbd5e1;
                }
                .m-notif-status[data-status="authorized"],
                .m-notif-status[data-status="provisional"],
                .m-notif-status[data-status="ephemeral"] {
                    background: rgba(34,197,94,0.18); color: #4ade80;
                }
                .m-notif-status[data-status="denied"] {
                    background: rgba(239,68,68,0.18); color: #f87171;
                }
                .m-notif-help {
                    font-size: 0.78rem; color: #94a3b8;
                    margin: 6px 4px 14px; line-height: 1.4;
                }
                .m-legal-row { cursor: pointer; }
                .m-legal-row:active { background: rgba(255,255,255,0.07); }
                .m-legal-chevron { color: #52525b; font-size: 0.85rem; }

                /* ---- Filters tab ---- */
                .m-tab { position: relative; }
                .m-tab-badge {
                    display: none; position: absolute; top: 2px; right: calc(50% - 22px);
                    min-width: 15px; height: 15px; padding: 0 4px; border-radius: 999px;
                    background: #38bdf8; color: #000; font-size: 0.58rem; font-weight: 900;
                    align-items: center; justify-content: center; line-height: 15px;
                }
                .m-tab-badge.visible { display: flex; }

                .m-filter-bar {
                    display: flex; align-items: center; justify-content: space-between;
                    margin: 4px 20px 0; padding: 10px 14px; border-radius: 12px;
                    background: rgba(56,189,248,0.08); border: 1px solid rgba(56,189,248,0.18);
                }
                .m-filter-count { font-size: 0.78rem; font-weight: 700; color: #71717a; }
                .m-filter-count.has-filters { color: #7dd3fc; }
                .m-filter-reset {
                    background: rgba(255,255,255,0.06); border: none; color: #f87171;
                    font-size: 0.75rem; font-weight: 700; padding: 6px 12px; border-radius: 999px;
                    opacity: 0; pointer-events: none; transition: 0.2s; -webkit-tap-highlight-color: transparent;
                }
                .m-filter-reset.visible { opacity: 1; pointer-events: auto; }
                .m-filter-reset i { margin-right: 4px; }

                .m-combo-list { padding: 0 20px; display: flex; flex-direction: column; gap: 10px; }

                .m-combo { position: relative; }
                .m-combo-label, .m-range-row .m-combo-label {
                    display: flex; align-items: center; gap: 10px; font-size: 0.78rem;
                    font-weight: 600; color: #d4d4d8; margin-bottom: 6px;
                }
                .m-combo-label i { color: #38bdf8; width: 15px; text-align: center; }
                .m-combo-label small { color: #71717a; font-weight: 500; }

                .m-combo-control { position: relative; }
                .m-combo-input {
                    width: 100%; box-sizing: border-box; padding: 12px 64px 12px 14px;
                    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.12);
                    border-radius: 12px; color: #fff; font-size: 0.9rem; font-weight: 600;
                    -webkit-appearance: none;
                }
                .m-combo-input::placeholder { color: #52525b; font-weight: 500; }
                .m-combo.has-value .m-combo-input { border-color: rgba(56,189,248,0.5); }
                .m-combo-input:focus { outline: none; border-color: #38bdf8; background: rgba(56,189,248,0.06); }

                .m-combo-caret, .m-combo-clear {
                    position: absolute; top: 50%; transform: translateY(-50%);
                    background: transparent; border: none; color: #71717a;
                    width: 28px; height: 28px; border-radius: 8px; font-size: 0.8rem;
                    display: flex; align-items: center; justify-content: center;
                }
                .m-combo-caret { right: 6px; transition: transform 0.2s; }
                .m-combo.open .m-combo-caret { transform: translateY(-50%) rotate(180deg); }
                .m-combo-clear { right: 34px; display: none; color: #a1a1aa; }
                .m-combo.has-value .m-combo-clear { display: flex; }
                .m-combo.is-preset-only .m-combo-input { padding-right: 64px; }

                .m-combo-menu {
                    display: none; position: absolute; top: calc(100% + 4px); left: 0; right: 0;
                    max-height: 210px; overflow-y: auto; z-index: 20;
                    background: #18181b; border: 1px solid rgba(255,255,255,0.14);
                    border-radius: 12px; padding: 6px; box-shadow: 0 12px 30px rgba(0,0,0,0.55);
                }
                .m-combo.open .m-combo-menu { display: block; }
                .m-combo-opt {
                    display: block; width: 100%; text-align: left; background: transparent;
                    border: none; color: #d4d4d8; padding: 10px 12px; border-radius: 8px;
                    font-size: 0.85rem; font-weight: 600; -webkit-tap-highlight-color: transparent;
                }
                .m-combo-opt:active { background: rgba(56,189,248,0.18); color: #fff; }

                .m-tac-pill-row {
                    display: flex; flex-wrap: wrap; gap: 8px; padding: 0 20px;
                }
                .m-tac-pill {
                    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1);
                    color: #a1a1aa; padding: 9px 16px; border-radius: 999px; font-weight: 700;
                    font-size: 0.8rem; -webkit-tap-highlight-color: transparent;
                }
                .m-tac-pill.active { background: #38bdf8; color: #000; border-color: #38bdf8; }

                .m-range-row { }
                .m-range-inputs { display: flex; align-items: center; gap: 10px; }
                .m-range-num {
                    flex: 1; min-width: 0; box-sizing: border-box; padding: 11px 12px;
                    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.12);
                    border-radius: 12px; color: #fff; font-size: 0.9rem; font-weight: 600;
                    text-align: center; -webkit-appearance: none;
                }
                .m-range-num::placeholder { color: #52525b; font-weight: 500; }
                .m-range-num:focus { outline: none; border-color: #38bdf8; background: rgba(56,189,248,0.06); }
                .m-range-dash { color: #52525b; font-weight: 700; }

                .custom-scroll { overflow-y: auto; flex: 1; }
            }
        `;
        const style = document.createElement('style');
        style.id = 'mobile-settings-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }
};
