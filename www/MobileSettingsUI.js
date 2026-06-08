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
    { key: 'callsign',     label: 'Callsign',      icon: 'fa-hashtag' },
    { key: 'aircraftType', label: 'Aircraft Type', icon: 'fa-plane' },
    { key: 'altSpeed',     label: 'Altitude & Speed', icon: 'fa-gauge-high' },
    { key: 'route',        label: 'Route (DEP → ARR)', icon: 'fa-route' },
    { key: 'registration', label: 'Registration',  icon: 'fa-id-card' },
    { key: 'pilot',        label: 'Pilot Name',    icon: 'fa-user' }
];

// Sample flight used to render the live label preview.
const LABEL_PREVIEW_SAMPLE = {
    callsign: 'UAL482',
    aircraftType: 'Boeing 787-9',
    altSpeed: '36,000 ft · 482 kts',
    route: 'KSFO  →  EGLL',
    registration: 'N38950',
    pilot: 'Capt. Reyes'
};

// Label color themes. `mono` + `default` are free; the rest are pro.
const LABEL_THEME_DEFS = [
    { value: 'default',  label: 'White',    text: '#ffffff', halo: 'rgba(15,23,42,0.92)' },
    { value: 'mono',     label: 'Mono',     text: '#e4e4e7', halo: 'rgba(0,0,0,0.85)' },
    { value: 'cyan',     label: 'Cyan',     text: '#7dd3fc', halo: 'rgba(8,47,73,0.92)',  pro: true },
    { value: 'amber',    label: 'Amber',    text: '#fcd34d', halo: 'rgba(69,26,3,0.92)',  pro: true },
    { value: 'contrast', label: 'Contrast', text: '#0b1120', halo: 'rgba(226,232,240,0.95)', pro: true }
];

export const MobileSettingsUI = {
    _isOpen: false,
    _activeTab: 'map',

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
                        <button class="m-tab" data-tab="filters" type="button"><i class="fa-solid fa-filter"></i><span>Filters</span></button>
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
                            <div class="mobile-section-header">Traffic</div>
                            <div class="m-settings-list">
                                ${this.renderToggle('showStaffOnly', 'Staff Pilots Only', 'fa-shield-check')}
                                ${this.renderToggle('showVaOnly', 'VA Members Only', 'fa-star')}
                                ${this.renderVaFilterRow()}
                                ${this.renderToggle('showGroupFlights', 'Show Group Flights', 'fa-users')}
                                ${this.renderToggle('hideAllAircraft', 'Hide All Aircraft', 'fa-eye-slash')}
                            </div>

                            <div class="mobile-section-header">ATC &amp; Airports</div>
                            <div class="m-settings-list">
                                ${this.renderToggle('useClassicAirportTags', 'Classic Airport Tags', 'fa-tags')}
                                ${this.renderToggle('showUnstaffedAirports', 'Show Unstaffed', 'fa-circle-dot')}
                                ${this.renderToggle('hideNoAtcMarkers', 'Hide No-ATC Dots', 'fa-location-dot')}
                                ${this.renderToggle('hideAtcMarkers', 'Hide ATC Markers', 'fa-headset')}
                            </div>

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

        // Checkbox Listener (skips label-field rows, handled separately)
        sheet.querySelectorAll('input[type="checkbox"]:not(.m-label-field-input)').forEach(input => {
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

        // Color Picker Listener
        sheet.querySelectorAll('input[type="color"]').forEach(input => {
            input.addEventListener('input', (e) => {
                if (e.target.closest('.locked')) return;
                const setting = e.target.dataset.setting;
                window.mapFilters[setting] = e.target.value;
                // Picking a custom global color implies Default mode — otherwise
                // a stale Blue/Orange preset would silently override it.
                if (setting === 'proCustomColor') {
                    window.mapFilters.iconColorMode = 'default';
                }
                if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });

        // Range Slider Listener
        sheet.querySelectorAll('.m-range-input').forEach(input => {
            input.addEventListener('input', (e) => {
                const setting = e.target.dataset.setting;
                const val = e.target.value;
                window.mapFilters[setting] = parseFloat(val);
                const label = document.getElementById(`m-val-${setting}`);
                if (label) {
                    label.textContent = setting === 'labelScale' ? `${parseFloat(val).toFixed(1)}×` : val;
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

        preview.style.color = theme.text;
        preview.style.textShadow = `0 0 3px ${theme.halo}, 0 1px 2px ${theme.halo}, 0 0 4px ${theme.halo}`;
        preview.style.fontSize = `${0.95 * scale}rem`;
        preview.innerHTML = lines.map(l => `<div class="${l.cls}">${l.text}</div>`).join('');
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

        container.querySelectorAll('input[type="checkbox"]:not(.m-label-field-input)').forEach(input => {
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

        container.querySelectorAll('input[type="color"]').forEach(input => {
            const val = filters[input.dataset.setting];
            if (val) input.value = val;
        });

        // Sync Dropdowns (e.g. Virtual Airline filter)
        container.querySelectorAll('select[data-setting]').forEach(sel => {
            const setting = sel.dataset.setting;
            if (setting) sel.value = filters[setting] || '';
        });

        container.querySelectorAll('.m-range-input').forEach(input => {
            const setting = input.dataset.setting;
            const val = filters[setting];
            if (val !== undefined && val !== null) input.value = val;
            const label = document.getElementById(`m-val-${setting}`);
            if (label) {
                label.textContent = setting === 'labelScale'
                    ? `${(parseFloat(val) || 1).toFixed(1)}×`
                    : val;
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

        this.updateLabelPreview();
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

                .custom-scroll { overflow-y: auto; flex: 1; }
            }
        `;
        const style = document.createElement('style');
        style.id = 'mobile-settings-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }
};
