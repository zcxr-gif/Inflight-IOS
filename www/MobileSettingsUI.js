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
                        ${this.renderNotificationsSection()}

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

    renderNotificationsSection() {
        // Render unconditionally so we can verify from a screenshot whether
        // the build picked up these changes. The button is a no-op on
        // non-iOS (handled in the click listener) but the section header
        // serves as a visible build-stamp.
        return `
            <div class="mobile-section-header">Notifications <span class="m-build-tag">v5</span></div>
            <div class="m-settings-list">
                <div class="m-setting-row" id="m-notif-row">
                    <div class="m-row-left">
                        <i class="fa-solid fa-bell" style="color:#38bdf8;"></i>
                        <span>Push & Live Activity Alerts</span>
                    </div>
                    <div class="m-row-right">
                        <span id="m-notif-status" class="m-notif-status" data-status="loading">Checking…</span>
                        <button id="m-notif-enable" class="m-btn m-primary m-notif-cta" type="button">Enable</button>
                    </div>
                </div>
                <p class="m-notif-help" id="m-notif-help">Required for lock-screen flight tracking ("this is my flight") and push alerts.</p>
                <div class="m-notif-diag" id="m-notif-diag"></div>
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
            this.refreshNotificationStatus();
            sheet.classList.add('open');
            overlay.classList.add('visible');
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

    async refreshNotificationStatus() {
        const pill = document.getElementById('m-notif-status');
        const btn = document.getElementById('m-notif-enable');
        const diag = document.getElementById('m-notif-diag');
        if (!pill || !btn) return;

        // Always render the diagnostic — it's tiny and tells us at a glance
        // whether the Capacitor bridge is actually wired up.
        if (diag && window.InflightLiveActivity?.diagnose) {
            try {
                const d = window.InflightLiveActivity.diagnose();
                diag.textContent = `Bridge: ${d.capacitor} • plugin=${d.plugin}` +
                    (d.pluginMethods ? ` • methods: ${d.pluginMethods}` : '');
            } catch (e) {
                diag.textContent = 'Bridge: diagnose threw ' + (e && e.message || e);
            }
        }

        const hasBridge = !!(window.InflightLiveActivity &&
            typeof window.InflightLiveActivity.getNotificationPermissionStatus === 'function');
        if (!hasBridge) {
            pill.dataset.status = 'unsupported';
            pill.textContent = 'No bridge';
            btn.textContent = 'Enable';
            return;
        }

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
                #mobile-settings-nexus .mobile-sheet-overlay {
                    position: fixed; inset: 0; background: rgba(0,0,0,0.7); 
                    backdrop-filter: blur(4px); opacity: 0; visibility: hidden; transition: 0.3s; z-index: 6000;
                }
                #mobile-settings-nexus .mobile-sheet-overlay.visible { opacity: 1; visibility: visible; }
                
                #mobile-settings-nexus .mobile-bottom-sheet {
                    position: fixed; bottom: -100%; left: 0; width: 100%; height: 75vh;
                    background: #0a0a0b; border-top: 1px solid rgba(255,255,255,0.1);
                    border-radius: 24px 24px 0 0; z-index: 6001; transition: 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                    display: flex; flex-direction: column; color: white; padding-bottom: env(safe-area-inset-bottom);
                }
                #mobile-settings-nexus .mobile-bottom-sheet.open { bottom: 0; }
                
                .sheet-handle { width: 40px; height: 5px; background: rgba(255,255,255,0.2); border-radius: 10px; margin: 12px auto; }
                .mobile-title { padding: 0 20px 15px; font-size: 1.2rem; font-weight: 800; display: flex; align-items: center; gap: 12px; }
                
                .mobile-section-header { padding: 15px 20px 8px; font-size: 0.7rem; font-weight: 900; color: #71717a; text-transform: uppercase; letter-spacing: 1px; }
                .mobile-section-header.pro-accent { color: #fbbf24; display: flex; align-items: center; gap: 6px; }
                
                .settings-mobile-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; padding: 0 20px; }
                .m-setting-pill { 
                    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); 
                    color: #a1a1aa; padding: 10px; border-radius: 12px; font-weight: 600; font-size: 0.8rem;
                }
                .m-setting-pill.active { background: #38bdf8; color: black; border-color: #38bdf8; }
                
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
                .m-build-tag {
                    font-size: 0.65rem; padding: 2px 6px; margin-left: 6px;
                    background: rgba(56,189,248,0.18); color: #38bdf8;
                    border-radius: 999px; letter-spacing: 0.04em;
                }
                .m-notif-diag {
                    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    font-size: 0.65rem; color: #64748b;
                    background: rgba(148,163,184,0.08);
                    padding: 8px 10px; margin: 4px 4px 14px;
                    border-radius: 8px; word-break: break-all;
                    line-height: 1.4;
                }

                .custom-scroll { overflow-y: auto; flex: 1; }
            }
        `;
        const style = document.createElement('style');
        style.id = 'mobile-settings-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }
};