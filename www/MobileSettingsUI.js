/**
 * MobileSettingsUI.js - Mobile-optimized Bottom Sheet for Map & Display Settings
 */

export const MobileSettingsUI = {
    _isOpen: false,

    init() {
        this.injectMobileStyles();
        this.renderMobileContainer();
        this.attachMobileListeners();
    },

renderMobileContainer() {
        const existing = document.getElementById('mobile-settings-nexus');
        if (existing) existing.remove();

        const html = `
            <div id="mobile-settings-nexus" class="mobile-only-ui">
                <div id="mobile-settings-overlay" class="mobile-sheet-overlay"></div>

                <div class="mobile-bottom-sheet">
                    <div class="sheet-handle"></div>
                    
                    <div class="mobile-title">
                        <i class="fa-solid fa-gears"></i>
                        <span>Map & Display Settings</span>
                    </div>

                    <div class="sheet-content custom-scroll">
                        <div class="mobile-section-header">Map Style</div>
                        <div class="settings-mobile-grid">
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="dark">Dark</button>
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="light">Light</button>
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="satellite">Satellite</button>
                        </div>

                        <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>Map Styles</div>
                        <div class="settings-mobile-grid is-pro-feature">
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="outdoors" data-pro="true">Outdoors</button>
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="nav-dark" data-pro="true">Nav Night</button>
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="nav-light" data-pro="true">Nav Day</button>
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="traffic-night" data-pro="true">Trfc Night</button>
                            <button class="m-setting-pill" data-setting="mapStyle" data-value="traffic-day" data-pro="true">Trfc Day</button>
                        </div>

                        <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>3D Environment</div>
                        <div class="m-settings-list">
                            ${this.renderToggle('showTerrain', '3D Terrain (Elevation)', 'fa-mountain', true)}
                            ${this.renderToggle('showBuildings', '3D Buildings', 'fa-city', true)}
                            ${this.renderToggle('showDayNight', 'Day/Night Terminator', 'fa-moon', true)}
                        </div>

                        <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>Base Map Elements</div>
                        <div class="m-settings-list">
                            ${this.renderToggle('showBorders', 'Political Borders', 'fa-earth-americas', true)}
                            ${this.renderToggle('showRoads', 'Roads & Highways', 'fa-road', true)}
                            ${this.renderToggle('showLabels', 'City & Place Labels', 'fa-font', true)}
                            ${this.renderToggle('showPois', 'Points of Interest', 'fa-map-pin', true)}
                            ${this.renderToggle('showWaterLabels', 'Water Labels', 'fa-water', true)}
                            ${this.renderToggle('showAirportLayout', 'Airport Layout', 'fa-plane-arrival', true)}
                            ${this.renderToggle('showLandUse', 'Parks & Forests', 'fa-tree', true)}
                        </div>

                        <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">Pro </span>Aircraft Colors</div>
                        <div class="m-settings-list">
                            <div class="m-setting-row is-pro-feature">
                                <div class="m-row-left">
                                    <i class="fa-solid fa-wand-magic-sparkles" style="color: #38bdf8;"></i>
                                    <span>Custom Plane Color</span>
                                </div>
                                <div class="m-row-right">
                                    <div class="pro-lock-badge"><i class="fa-solid fa-lock" style="font-size:0.6rem; margin-right:4px;"></i>PRO</div>
                                    <input type="color" class="m-color-picker" data-setting="proCustomColor" value="#38bdf8" data-pro="true">
                                </div>
                            </div>
                            <div class="m-setting-row is-pro-feature">
                                <div class="m-row-left">
                                    <i class="fa-solid fa-plane" style="color: #fbbf24;"></i>
                                    <span>Tracked Flight Color</span>
                                </div>
                                <div class="m-row-right">
                                    <div class="pro-lock-badge"><i class="fa-solid fa-lock" style="font-size:0.6rem; margin-right:4px;"></i>PRO</div>
                                    <input type="color" class="m-color-picker" data-setting="userPlaneColor" value="#f97316" data-pro="true">
                                </div>
                            </div>
                            <div class="m-setting-row is-pro-feature">
                                <div class="m-row-left">
                                    <i class="fa-solid fa-eye" style="color: #fbbf24;"></i>
                                    <span>Watchlist Color</span>
                                </div>
                                <div class="m-row-right">
                                    <div class="pro-lock-badge"><i class="fa-solid fa-lock" style="font-size:0.6rem; margin-right:4px;"></i>PRO</div>
                                    <input type="color" class="m-color-picker" data-setting="friendPlaneColor" value="#c084fc" data-pro="true">
                                </div>
                            </div>
                        </div>

                        <div class="mobile-section-header">Visibility</div>
                        <div class="m-settings-list">
                            ${this.renderToggle('showAircraftLabels', 'Aircraft Labels', 'fa-tag')}
                            ${this.renderToggle('show3DPath', '3D Flown Path', 'fa-cube')}
                            ${this.renderToggle('showNatTracks', 'NAT Tracks', 'fa-route')}
                            ${this.renderToggle('showNatLabels', 'NAT Labels', 'fa-font')}
                            ${this.renderToggle('useFlatMap', 'Flat Map Projection', 'fa-map')}
                            ${this.renderToggle('useSimpleFlightWindow', 'Simple Flight Info', 'fa-window-maximize')}
                        </div>

                        <div class="mobile-section-header">Aircraft Filters</div>
                        <div class="m-settings-list">
                            ${this.renderToggle('showStaffOnly', 'Staff Pilots Only', 'fa-shield-check')}
                            ${this.renderToggle('showVaOnly', 'VA Members Only', 'fa-star')}
                            ${this.renderToggle('showGroupFlights', 'Show Group Flights', 'fa-users')}
                            ${this.renderToggle('hideAllAircraft', 'Hide All Aircraft', 'fa-eye-slash')}
                        </div>

                        <div class="mobile-section-header">ATC & Airport Filters</div>
                        <div class="m-settings-list">
                            ${this.renderToggle('showUnstaffedAirports', 'Show Unstaffed', 'fa-circle-dot')}
                            ${this.renderToggle('hideNoAtcMarkers', 'Hide No-ATC Dots', 'fa-location-dot')}
                            ${this.renderToggle('hideAtcMarkers', 'Hide ATC Markers', 'fa-headset')}
                        </div>

                        <div class="mobile-section-header">Flight Plan Display</div>
                        <div class="settings-mobile-grid">
                            <button class="m-setting-pill" data-setting="planDisplayMode" data-value="none">None</button>
                            <button class="m-setting-pill" data-setting="planDisplayMode" data-value="direct">Direct</button>
                            <button class="m-setting-pill" data-setting="planDisplayMode" data-value="full">Full Plan</button>
                        </div>

                        <div class="mobile-section-header">Icon Configuration</div>
                        <div class="m-setting-range-card">
                            <div class="range-header">
                                <span>Plane Icon Size</span>
                                <span id="m-val-planeIconSize">0.05</span>
                            </div>
                            <input type="range" class="m-range-input" data-setting="planeIconSize" min="0.01" max="0.15" step="0.01">
                        </div>

                        <div class="mobile-section-header">Global Icon Color Mode</div>
                        <div class="settings-mobile-grid">
                            <button class="m-setting-pill" data-setting="iconColorMode" data-value="default">White</button>
                            <button class="m-setting-pill" data-setting="iconColorMode" data-value="blue">Blue</button>
                            <button class="m-setting-pill" data-setting="iconColorMode" data-value="orange">Orange</button>
                        </div>
                    </div>

                    <div class="sheet-footer">
                        <button id="mobile-settings-close" class="m-btn m-primary">Done</button>
                    </div>
                </div>
            </div>
        `;

        document.body.insertAdjacentHTML('beforeend', html);
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

refreshProLocks() {
        let isSignedIn = false;
        
        // Comprehensive check for active session/auth state
        if (window.currentUser || window.user || window.isLoggedIn || window.session) {
            isSignedIn = true;
        } else {
            // Deep check for Supabase token in localStorage
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                // Supports both legacy v1 and current v2 Supabase token formats
                if (key && (key.includes('supabase.auth.token') || (key.startsWith('sb-') && key.endsWith('-auth-token')))) {
                    isSignedIn = true;
                    break;
                }
            }
        }

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

    attachMobileListeners() {
        const sheet = document.querySelector('#mobile-settings-nexus .mobile-bottom-sheet');
        const overlay = document.getElementById('mobile-settings-overlay');

        window.addEventListener('openMobileSettings', () => {
            this._isOpen = true;
            this.refreshProLocks(); 
            this.syncUIWithState();
            sheet.classList.add('open');
            overlay.classList.add('visible');
        });

        const closeUI = () => {
            this._isOpen = false;
            sheet.classList.remove('open');
            overlay.classList.remove('visible');
            if (window.saveFiltersToLocalStorage) window.saveFiltersToLocalStorage();
        };

        overlay.addEventListener('click', closeUI);
        document.getElementById('mobile-settings-close').addEventListener('click', closeUI);

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

        // Checkbox Listener
        sheet.querySelectorAll('input[type="checkbox"]').forEach(input => {
            input.addEventListener('change', (e) => {
                if (e.target.closest('.locked')) return; // Extra layer of protection

                const setting = e.target.dataset.setting;
                const isPro = e.target.dataset.pro === 'true';

                if (isPro) {
                    if (!window.mapFilters.proMapConfig) window.mapFilters.proMapConfig = {};
                    window.mapFilters.proMapConfig[setting] = e.target.checked;
                    
                    if (window.updateBaseMapLayerVisibility) window.updateBaseMapLayerVisibility();
                    if (window.updatePro3DLayers) window.updatePro3DLayers();
                } else {
                    window.mapFilters[setting] = e.target.checked;
                }
                
                if (window.updateMapFilters) window.updateMapFilters();
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
                document.getElementById(`m-val-${setting}`).textContent = val;
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });

        // Setting Pills Listener
        sheet.querySelectorAll('.m-setting-pill').forEach(btn => {
            btn.addEventListener('click', () => {
                const setting = btn.dataset.setting;
                const value = btn.dataset.value;
                window.mapFilters[setting] = value;
                btn.parentElement.querySelectorAll('.m-setting-pill').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                if (window.updateMapFilters) window.updateMapFilters();
            });
        });
    },

    syncUIWithState() {
        const filters = window.mapFilters;
        if (!filters) return;
        const container = document.getElementById('mobile-settings-nexus');

        container.querySelectorAll('input[type="checkbox"]').forEach(input => {
            const isPro = input.dataset.pro === 'true';
            if (isPro) {
                input.checked = !!(filters.proMapConfig && filters.proMapConfig[input.dataset.setting]);
            } else {
                input.checked = !!filters[input.dataset.setting];
            }
        });

        container.querySelectorAll('input[type="color"]').forEach(input => {
            const val = filters[input.dataset.setting];
            if (val) input.value = val;
        });

        container.querySelectorAll('.m-range-input').forEach(input => {
            const val = filters[input.dataset.setting];
            input.value = val;
            const label = document.getElementById(`m-val-${input.dataset.setting}`);
            if (label) label.textContent = val;
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
    },

    injectMobileStyles() {
        if (document.getElementById('mobile-settings-styles')) return;
        const css = `
            @media (max-width: 768px) {
                #mobile-settings-nexus {
                    --ms-bg:        #f7f4ee;
                    --ms-surface:   #ffffff;
                    --ms-card:      #ffffff;
                    --ms-card-soft: rgba(26,22,18,0.04);
                    --ms-border:    rgba(26,22,18,0.08);
                    --ms-divider:   rgba(26,22,18,0.06);
                    --ms-text:      #1a1612;
                    --ms-muted:     #6b6258;
                    --ms-tertiary:  #9a9088;
                    --ms-accent:    #b88553;
                    --ms-accent-soft: rgba(184,133,83,0.12);
                    --ms-on-accent: #fffbf3;
                    --ms-pro:       #c8893d;
                    --ms-pro-grad:  linear-gradient(135deg, #d5a059 0%, #b27a28 100%);
                    --ms-shadow:    0 -20px 50px rgba(0,0,0,0.10);
                    --ms-radius:    16px;
                    --ms-font:      'DM Sans', system-ui, -apple-system, sans-serif;
                }
                @media (prefers-color-scheme: dark) {
                    #mobile-settings-nexus {
                        --ms-bg:        #1a1612;
                        --ms-surface:   #221d17;
                        --ms-card:      #2a241d;
                        --ms-card-soft: rgba(255,248,235,0.04);
                        --ms-border:    rgba(255,248,235,0.08);
                        --ms-divider:   rgba(255,248,235,0.06);
                        --ms-text:      #f0e9dd;
                        --ms-muted:     #9a8e7e;
                        --ms-tertiary:  #6e6457;
                        --ms-accent:    #d4a574;
                        --ms-accent-soft: rgba(212,165,116,0.16);
                        --ms-on-accent: #1a1612;
                        --ms-pro:       #d9a563;
                        --ms-shadow:    0 -20px 50px rgba(0,0,0,0.45);
                    }
                }
                html[data-app-theme="dark"] #mobile-settings-nexus,
                html[data-theme="dark"] #mobile-settings-nexus,
                .tactical-ui-root[data-theme="dark"] ~ #mobile-settings-nexus {
                    --ms-bg:        #1a1612;
                    --ms-surface:   #221d17;
                    --ms-card:      #2a241d;
                    --ms-card-soft: rgba(255,248,235,0.04);
                    --ms-border:    rgba(255,248,235,0.08);
                    --ms-divider:   rgba(255,248,235,0.06);
                    --ms-text:      #f0e9dd;
                    --ms-muted:     #9a8e7e;
                    --ms-tertiary:  #6e6457;
                    --ms-accent:    #d4a574;
                    --ms-accent-soft: rgba(212,165,116,0.16);
                    --ms-on-accent: #1a1612;
                    --ms-pro:       #d9a563;
                    --ms-shadow:    0 -20px 50px rgba(0,0,0,0.45);
                }

                #mobile-settings-nexus .mobile-sheet-overlay {
                    position: fixed; inset: 0;
                    background: rgba(0,0,0,0.42);
                    -webkit-backdrop-filter: blur(10px);
                    backdrop-filter: blur(10px);
                    opacity: 0; visibility: hidden;
                    transition: opacity 0.3s ease, visibility 0.3s ease;
                    z-index: 6000;
                }
                #mobile-settings-nexus .mobile-sheet-overlay.visible { opacity: 1; visibility: visible; }

                #mobile-settings-nexus .mobile-bottom-sheet {
                    position: fixed;
                    bottom: 0; left: 0; right: 0;
                    width: 100%;
                    height: 86vh;
                    height: 86dvh;
                    max-height: 92vh;
                    background: var(--ms-bg);
                    color: var(--ms-text);
                    border: none;
                    border-radius: 22px 22px 0 0;
                    z-index: 6001;
                    transform: translateY(100%);
                    transition: transform 0.42s cubic-bezier(0.22, 1, 0.36, 1);
                    display: flex; flex-direction: column;
                    padding-bottom: env(safe-area-inset-bottom);
                    box-shadow: var(--ms-shadow);
                    font-family: var(--ms-font);
                }
                #mobile-settings-nexus .mobile-bottom-sheet.open { transform: translateY(0); }

                #mobile-settings-nexus .sheet-handle {
                    width: 38px; height: 4px;
                    background: var(--ms-border);
                    border-radius: 999px;
                    margin: 10px auto 6px;
                    opacity: 0.85;
                }

                #mobile-settings-nexus .mobile-title {
                    padding: 8px 20px 16px;
                    font-size: 1.18rem;
                    font-weight: 700;
                    letter-spacing: -0.02em;
                    display: flex;
                    align-items: center;
                    gap: 12px;
                    color: var(--ms-text);
                    border-bottom: 1px solid var(--ms-divider);
                }
                #mobile-settings-nexus .mobile-title i {
                    width: 32px; height: 32px;
                    display: grid; place-items: center;
                    background: var(--ms-accent-soft);
                    color: var(--ms-accent);
                    border-radius: 10px;
                    font-size: 0.9rem;
                }

                #mobile-settings-nexus .mobile-section-header {
                    padding: 20px 20px 8px;
                    font-size: 0.62rem;
                    font-weight: 700;
                    color: var(--ms-tertiary);
                    text-transform: uppercase;
                    letter-spacing: 0.12em;
                }
                #mobile-settings-nexus .mobile-section-header.pro-accent {
                    color: var(--ms-pro);
                    display: flex; align-items: center; gap: 6px;
                }
                #mobile-settings-nexus .mobile-section-header.pro-accent i { font-size: 0.65rem; }

                #mobile-settings-nexus .settings-mobile-grid {
                    display: grid;
                    grid-template-columns: repeat(3, 1fr);
                    gap: 8px;
                    padding: 0 16px;
                }
                #mobile-settings-nexus .m-setting-pill {
                    background: var(--ms-card);
                    border: 1px solid var(--ms-border);
                    color: var(--ms-muted);
                    padding: 12px 8px;
                    border-radius: 12px;
                    font-family: var(--ms-font);
                    font-weight: 600;
                    font-size: 0.8rem;
                    letter-spacing: -0.005em;
                    cursor: pointer;
                    transition:
                        background 0.16s ease,
                        color 0.16s ease,
                        border-color 0.16s ease,
                        transform 0.1s ease;
                    box-shadow: inset 0 1px 0 color-mix(in srgb, var(--ms-text) 4%, transparent);
                }
                #mobile-settings-nexus .m-setting-pill:active { transform: scale(0.96); }
                #mobile-settings-nexus .m-setting-pill.active {
                    background: var(--ms-accent-soft);
                    color: var(--ms-accent);
                    border-color: color-mix(in srgb, var(--ms-accent) 35%, transparent);
                    box-shadow: 0 0 0 1px color-mix(in srgb, var(--ms-accent) 25%, transparent);
                }

                #mobile-settings-nexus .m-settings-list {
                    padding: 4px 16px 0;
                    display: flex; flex-direction: column;
                    gap: 1px;
                    background: var(--ms-card);
                    margin: 4px 16px 0;
                    padding: 0;
                    border: 1px solid var(--ms-border);
                    border-radius: var(--ms-radius);
                    overflow: hidden;
                }
                #mobile-settings-nexus .m-setting-row {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    background: var(--ms-card);
                    padding: 14px 16px;
                    border-radius: 0;
                    border-bottom: 1px solid var(--ms-divider);
                    transition: background 0.14s ease;
                }
                #mobile-settings-nexus .m-setting-row:last-child { border-bottom: none; }
                #mobile-settings-nexus .m-setting-row:active { background: var(--ms-card-soft); }
                #mobile-settings-nexus .m-row-left {
                    display: flex; align-items: center; gap: 12px;
                    font-size: 0.92rem;
                    font-weight: 500;
                    color: var(--ms-text);
                    letter-spacing: -0.005em;
                }
                #mobile-settings-nexus .m-row-left i {
                    width: 28px; height: 28px;
                    display: grid; place-items: center;
                    background: var(--ms-accent-soft);
                    color: var(--ms-accent) !important;
                    border-radius: 8px;
                    font-size: 0.82rem;
                }
                #mobile-settings-nexus .m-row-right { display: flex; align-items: center; gap: 10px; }

                /* PRO badges */
                #mobile-settings-nexus .pro-lock-badge {
                    display: none;
                    background: var(--ms-pro-grad);
                    color: #fff;
                    font-size: 0.6rem;
                    font-weight: 800;
                    padding: 4px 8px;
                    border-radius: 999px;
                    letter-spacing: 0.06em;
                    text-transform: uppercase;
                    box-shadow: 0 1px 2px rgba(0,0,0,0.12);
                }
                #mobile-settings-nexus .is-pro-feature.locked { opacity: 0.85; cursor: pointer; }
                #mobile-settings-nexus .is-pro-feature.locked .pro-lock-badge { display: inline-flex; align-items: center; }
                html.ios-native #mobile-settings-nexus .pro-lock-badge,
                html.ios-native #mobile-settings-nexus .is-pro-feature.locked .pro-lock-badge {
                    display: none !important;
                }
                #mobile-settings-nexus .is-pro-feature.locked .m-switch,
                #mobile-settings-nexus .is-pro-feature.locked .m-color-picker {
                    opacity: 0.35;
                    pointer-events: none;
                    filter: grayscale(100%);
                }

                /* Color picker */
                #mobile-settings-nexus .m-color-picker {
                    -webkit-appearance: none;
                    border: none;
                    width: 32px; height: 32px;
                    border-radius: 10px;
                    cursor: pointer;
                    padding: 0;
                    background: transparent;
                }
                #mobile-settings-nexus .m-color-picker::-webkit-color-swatch-wrapper { padding: 0; }
                #mobile-settings-nexus .m-color-picker::-webkit-color-swatch {
                    border: 2px solid var(--ms-border);
                    border-radius: 10px;
                }

                /* Switch */
                #mobile-settings-nexus .m-switch { position: relative; display: inline-block; width: 44px; height: 26px; }
                #mobile-settings-nexus .m-switch input { opacity: 0; width: 0; height: 0; }
                #mobile-settings-nexus .m-slider {
                    position: absolute; cursor: pointer; inset: 0;
                    background: var(--ms-border);
                    transition: background 0.24s cubic-bezier(0.16,1,0.3,1);
                    border-radius: 999px;
                }
                #mobile-settings-nexus .m-slider:before {
                    position: absolute; content: "";
                    height: 22px; width: 22px;
                    left: 2px; bottom: 2px;
                    background: #fff;
                    transition: transform 0.24s cubic-bezier(0.16,1,0.3,1);
                    border-radius: 50%;
                    box-shadow: 0 1px 3px rgba(0,0,0,0.18), 0 1px 1px rgba(0,0,0,0.04);
                }
                #mobile-settings-nexus input:checked + .m-slider { background: var(--ms-accent); }
                #mobile-settings-nexus input:checked + .m-slider:before { transform: translateX(18px); }

                /* Range card */
                #mobile-settings-nexus .m-setting-range-card {
                    margin: 4px 16px 0;
                    background: var(--ms-card);
                    border: 1px solid var(--ms-border);
                    padding: 14px 16px;
                    border-radius: var(--ms-radius);
                }
                #mobile-settings-nexus .range-header {
                    display: flex;
                    justify-content: space-between;
                    font-size: 0.86rem;
                    font-weight: 500;
                    color: var(--ms-text);
                    margin-bottom: 12px;
                }
                #mobile-settings-nexus .range-header span:last-child {
                    font-family: 'JetBrains Mono', ui-monospace, monospace;
                    color: var(--ms-muted);
                    font-weight: 600;
                    font-size: 0.8rem;
                }
                #mobile-settings-nexus .m-range-input {
                    width: 100%;
                    accent-color: var(--ms-accent);
                }

                /* Footer */
                #mobile-settings-nexus .sheet-footer {
                    padding: 14px 16px calc(env(safe-area-inset-bottom, 0px) + 14px);
                    border-top: 1px solid var(--ms-divider);
                    background: color-mix(in srgb, var(--ms-bg) 92%, transparent);
                    -webkit-backdrop-filter: blur(18px);
                    backdrop-filter: blur(18px);
                }
                #mobile-settings-nexus .m-btn {
                    width: 100%;
                    padding: 15px;
                    border-radius: 14px;
                    font-family: var(--ms-font);
                    font-weight: 700;
                    border: none;
                    font-size: 0.98rem;
                    letter-spacing: -0.005em;
                    cursor: pointer;
                    transition: transform 0.1s ease, box-shadow 0.18s ease;
                }
                #mobile-settings-nexus .m-btn:active { transform: scale(0.98); }
                #mobile-settings-nexus .m-primary {
                    background: var(--ms-accent);
                    color: var(--ms-on-accent);
                    box-shadow: 0 6px 18px var(--ms-accent-soft);
                }

                #mobile-settings-nexus .custom-scroll {
                    overflow-y: auto;
                    flex: 1;
                    padding: 0 0 10px;
                    -webkit-overflow-scrolling: touch;
                    scrollbar-width: none;
                }
                #mobile-settings-nexus .custom-scroll::-webkit-scrollbar { display: none; }
            }
        `;
        const style = document.createElement('style');
        style.id = 'mobile-settings-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }
};