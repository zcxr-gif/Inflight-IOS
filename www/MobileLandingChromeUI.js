/**
 * MobileLandingChromeUI.js
 *
 * Full iOS-native rehaul of the LandingUI chrome (top header + bottom tab
 * bar). The original `.tactical-header`, `.auth-nexus`, and `.utility-nexus`
 * elements rendered by landingUI.js are hidden on mobile; this module
 * inserts a brand new structure and re-hosts the existing search input +
 * results dropdown so every LandingUI handler keeps working untouched.
 *
 * Web (>768px) is unaffected — this file is only loaded by
 * landingUI.js#applyMobileChrome when the viewport is mobile.
 */

export const MobileLandingChromeUI = {
    parent: null,
    _initialized: false,
    _serverSheetOpen: false,
    _weatherSheetOpen: false,
    _searchActive: false,

    init(parentUI) {
        if (this._initialized) return;
        if (typeof window === 'undefined' || window.innerWidth > 768) return;

        this.parent = parentUI;
        this._initialized = true;

        this._injectStyles();
        this._renderChrome();
        this._wireEvents();
        this._syncFilterDot();
    },

    /* ===========================================================
       DOM — new top nav + bottom tab bar
       =========================================================== */
    _renderChrome() {
        const root = document.getElementById('inflight-tactical-ui');
        const mapHost = document.getElementById('sector-ops-map-fullscreen');
        if (!root || !mapHost) return;

        // --- Top nav bar ---
        const topBar = document.createElement('div');
        topBar.id = 'ios-landing-topbar';
        topBar.className = 'ios-chrome';
        topBar.setAttribute('data-theme', this.parent?._theme || 'dark');
        topBar.innerHTML = `
            <div class="ios-topbar-inner">
                <button type="button" class="ios-server-pill" id="ios-server-pill" aria-label="Server">
                    <span class="ios-status-dot"></span>
                    <span class="ios-server-name" id="ios-server-name">${(this.parent?._currentServer || 'Expert').toUpperCase()}</span>
                </button>

                <div class="ios-search-shell" id="ios-search-shell">
                    <i class="fa-solid fa-magnifying-glass ios-search-glyph"></i>
                    <div class="ios-search-slot" id="ios-search-slot">
                        <!-- #blade-search-input + #blade-search-clear are moved in here -->
                    </div>
                </div>

                <button type="button" class="ios-profile-btn" id="ios-profile-btn" aria-label="Profile">
                    <i class="fa-solid fa-user-astronaut"></i>
                </button>

                <button type="button" class="ios-cancel-btn" id="ios-cancel-btn">Cancel</button>
            </div>
        `;

        // --- Bottom tab bar ---
        const bottomBar = document.createElement('nav');
        bottomBar.id = 'ios-landing-tabbar';
        bottomBar.className = 'ios-chrome';
        bottomBar.setAttribute('data-theme', this.parent?._theme || 'dark');
        bottomBar.innerHTML = `
            <div class="ios-tabbar-inner">
                <button type="button" class="ios-tab" data-action="server">
                    <i class="fa-solid fa-server"></i>
                    <span class="ios-tab-label">Server</span>
                </button>
                <button type="button" class="ios-tab" data-action="weather">
                    <i class="fa-solid fa-cloud-sun-rain"></i>
                    <span class="ios-tab-label">Weather</span>
                </button>
                <button type="button" class="ios-tab" data-action="filters">
                    <i class="fa-solid fa-sliders"></i>
                    <span class="ios-tab-label">Filters</span>
                    <span class="ios-tab-dot" id="ios-tab-filter-dot"></span>
                </button>
                <button type="button" class="ios-tab" data-action="settings">
                    <i class="fa-solid fa-gear"></i>
                    <span class="ios-tab-label">Settings</span>
                </button>
            </div>
        `;

        // --- Server bottom sheet ---
        const serverSheet = document.createElement('div');
        serverSheet.id = 'ios-server-sheet';
        serverSheet.className = 'ios-sheet-root';
        serverSheet.innerHTML = `
            <div class="ios-sheet-backdrop" data-dismiss="server"></div>
            <div class="ios-sheet-card">
                <div class="ios-sheet-grip"></div>
                <div class="ios-sheet-title">Server</div>
                <div class="ios-sheet-group">
                    ${['Expert', 'Training', 'Casual'].map(s => `
                        <button type="button" class="ios-sheet-row" data-server="${s}">
                            <span class="ios-sheet-row-label">${s}</span>
                            <i class="fa-solid fa-check ios-sheet-row-check"></i>
                        </button>
                    `).join('')}
                </div>
                <button type="button" class="ios-sheet-cancel" data-dismiss="server">Cancel</button>
            </div>
        `;

        // --- Weather popover (anchored above the Weather tab) ---
        const weatherPop = document.createElement('div');
        weatherPop.id = 'ios-weather-pop';
        weatherPop.className = 'ios-popover-root';
        weatherPop.innerHTML = `
            <div class="ios-popover-backdrop" data-dismiss="weather"></div>
            <div class="ios-popover-card">
                <div class="ios-popover-title">Weather Layers</div>
                ${[
                    { id: 'precip', label: 'Radar', icon: 'fa-satellite-dish' },
                    { id: 'sigmets', label: 'SIGMETs', icon: 'fa-triangle-exclamation' },
                    { id: 'clouds', label: 'Clouds', icon: 'fa-cloud' },
                    { id: 'wind', label: 'Wind', icon: 'fa-wind' },
                ].map(w => `
                    <button type="button" class="ios-popover-row" data-weather="${w.id}">
                        <i class="fa-solid ${w.icon}"></i>
                        <span>${w.label}</span>
                        <span class="ios-popover-switch" aria-hidden="true"></span>
                    </button>
                `).join('')}
            </div>
        `;

        root.appendChild(topBar);
        root.appendChild(bottomBar);
        mapHost.appendChild(serverSheet);
        mapHost.appendChild(weatherPop);

        // Move existing search input + clear button into the new shell so
        // every LandingUI handler stays bound.
        const slot = topBar.querySelector('#ios-search-slot');
        const originalInput = document.getElementById('blade-search-input');
        const originalClear = document.getElementById('blade-search-clear');
        const originalResults = document.getElementById('blade-search-results');
        if (originalInput) slot.appendChild(originalInput);
        if (originalClear) slot.appendChild(originalClear);
        // Results dropdown lives at the LandingUI root so it can full-bleed.
        if (originalResults) root.appendChild(originalResults);
    },

    /* ===========================================================
       Event wiring
       =========================================================== */
    _wireEvents() {
        const topBar = document.getElementById('ios-landing-topbar');
        const tabBar = document.getElementById('ios-landing-tabbar');
        const serverSheet = document.getElementById('ios-server-sheet');
        const weatherPop = document.getElementById('ios-weather-pop');
        const profileBtn = document.getElementById('ios-profile-btn');
        const cancelBtn = document.getElementById('ios-cancel-btn');
        const serverPill = document.getElementById('ios-server-pill');
        const searchInput = document.getElementById('blade-search-input');
        const searchShell = document.getElementById('ios-search-shell');
        const root = document.getElementById('inflight-tactical-ui');

        // --- Theme follow ---
        window.addEventListener('puiThemeChanged', (e) => {
            const t = e.detail?.theme || 'dark';
            topBar?.setAttribute('data-theme', t);
            tabBar?.setAttribute('data-theme', t);
            serverSheet?.setAttribute('data-theme', t);
            weatherPop?.setAttribute('data-theme', t);
        });

        // --- Profile ---
        profileBtn?.addEventListener('click', () => {
            if (window.AuthUI) {
                window.AuthUI.open();
            } else {
                import('./authUI.js').then(m => m.AuthUI.open())
                    .catch(err => console.error('Failed to load AuthUI:', err));
            }
        });

        // --- Search focus state (drives Cancel + tab-bar hiding) ---
        const enterSearch = () => {
            this._searchActive = true;
            root?.classList.add('mobile-search-active');
            searchShell?.classList.add('is-active');
        };
        const exitSearch = () => {
            this._searchActive = false;
            root?.classList.remove('mobile-search-active');
            searchShell?.classList.remove('is-active');
        };

        searchInput?.addEventListener('focus', enterSearch);
        searchInput?.addEventListener('blur', () => {
            setTimeout(() => {
                if (!searchInput.value && document.activeElement !== searchInput) {
                    exitSearch();
                }
            }, 140);
        });

        cancelBtn?.addEventListener('pointerdown', (e) => {
            e.preventDefault();
            if (searchInput) {
                searchInput.value = '';
                searchInput.blur();
            }
            this.parent?.handleLocalSearch?.('');
            this.parent?._syncSearchActive?.();
            exitSearch();
        });

        // --- Server pill (top) → bottom sheet ---
        serverPill?.addEventListener('click', () => this._openServerSheet());

        // --- Tab bar ---
        tabBar?.addEventListener('click', (e) => {
            const tab = e.target.closest('.ios-tab');
            if (!tab) return;
            this._handleTab(tab.dataset.action, tab);
        });

        // --- Server sheet selection ---
        serverSheet?.addEventListener('click', (e) => {
            if (e.target.closest('[data-dismiss="server"]')) {
                this._closeServerSheet();
                return;
            }
            const row = e.target.closest('[data-server]');
            if (row) {
                const val = row.dataset.server;
                this._selectServer(val);
                this._closeServerSheet();
            }
        });

        // --- Weather popover selection ---
        weatherPop?.addEventListener('click', (e) => {
            if (e.target.closest('[data-dismiss="weather"]')) {
                this._closeWeatherSheet();
                return;
            }
            const row = e.target.closest('[data-weather]');
            if (row) {
                const type = row.dataset.weather;
                const nowActive = !row.classList.contains('is-on');
                row.classList.toggle('is-on', nowActive);
                window.dispatchEvent(new CustomEvent('weatherToggle', { detail: { type, isActive: nowActive } }));
            }
        });

        // --- Server sync (in case other code dispatches serverChange) ---
        window.addEventListener('serverChange', (e) => {
            const name = (e.detail?.server || this.parent?._currentServer || 'Expert');
            const label = document.getElementById('ios-server-name');
            if (label) label.textContent = name.toUpperCase();
            this._refreshServerSheetChecks(name);
        });

        // --- Filter active dot sync ---
        const observerTarget = document.getElementById('filter-active-dot');
        if (observerTarget) {
            const mo = new MutationObserver(() => this._syncFilterDot());
            mo.observe(observerTarget, { attributes: true, attributeFilter: ['style', 'class'] });
        }
        // Also re-sync on filter updates dispatched by LandingUI.
        window.addEventListener('filterUpdate', () => this._syncFilterDot());

        // Initial server check sync
        this._refreshServerSheetChecks(this.parent?._currentServer || 'Expert');
    },

    /* ===========================================================
       Tab actions
       =========================================================== */
    _handleTab(action, btn) {
        this._setActiveTab(btn);
        switch (action) {
            case 'server':
                this._openServerSheet();
                break;
            case 'weather':
                this._toggleWeatherSheet();
                break;
            case 'filters':
                window.dispatchEvent(new CustomEvent('openMobileUI'));
                break;
            case 'settings':
                window.dispatchEvent(new CustomEvent('openSettings'));
                break;
        }
    },

    _setActiveTab(btn) {
        document.querySelectorAll('#ios-landing-tabbar .ios-tab').forEach(t => t.classList.remove('is-active'));
        btn?.classList.add('is-active');
        setTimeout(() => btn?.classList.remove('is-active'), 280);
    },

    /* ===========================================================
       Server sheet
       =========================================================== */
    _openServerSheet() {
        const sheet = document.getElementById('ios-server-sheet');
        if (!sheet) return;
        this._serverSheetOpen = true;
        sheet.classList.add('is-open');
        document.body.style.overflow = 'hidden';
    },
    _closeServerSheet() {
        const sheet = document.getElementById('ios-server-sheet');
        if (!sheet) return;
        this._serverSheetOpen = false;
        sheet.classList.remove('is-open');
        document.body.style.overflow = '';
    },
    _selectServer(name) {
        if (!name) return;
        if (this.parent) this.parent._currentServer = name;
        const topLabel = document.getElementById('ios-server-name');
        if (topLabel) topLabel.textContent = name.toUpperCase();
        const oldLabel = document.getElementById('landing-server-name');
        if (oldLabel) oldLabel.textContent = `${name.toUpperCase()} SERVER`;
        this._refreshServerSheetChecks(name);
        window.dispatchEvent(new CustomEvent('serverChange', { detail: { server: name } }));
    },
    _refreshServerSheetChecks(name) {
        document.querySelectorAll('#ios-server-sheet [data-server]').forEach(row => {
            row.classList.toggle('is-selected', row.dataset.server === name);
        });
    },

    /* ===========================================================
       Weather popover
       =========================================================== */
    _toggleWeatherSheet() {
        this._weatherSheetOpen ? this._closeWeatherSheet() : this._openWeatherSheet();
    },
    _openWeatherSheet() {
        const pop = document.getElementById('ios-weather-pop');
        if (!pop) return;
        this._weatherSheetOpen = true;
        pop.classList.add('is-open');
    },
    _closeWeatherSheet() {
        const pop = document.getElementById('ios-weather-pop');
        if (!pop) return;
        this._weatherSheetOpen = false;
        pop.classList.remove('is-open');
    },

    /* ===========================================================
       Filter activity indicator
       =========================================================== */
    _syncFilterDot() {
        const dot = document.getElementById('ios-tab-filter-dot');
        if (!dot) return;
        const hasActive = !!(this.parent && this.parent._activeFilters && Object.keys(this.parent._activeFilters).length > 0);
        dot.classList.toggle('is-on', hasActive);
    },

    /* ===========================================================
       Styles
       =========================================================== */
    _injectStyles() {
        const css = `
        @media (max-width: 768px) {
            /* Kill the old chrome — every replacement lives below */
            #inflight-tactical-ui .tactical-header,
            #inflight-tactical-ui .auth-nexus,
            #inflight-tactical-ui .utility-nexus,
            #inflight-tactical-ui .search-cancel-btn {
                display: none !important;
            }

            /* ============ SHARED ============ */
            .ios-chrome {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                -webkit-font-smoothing: antialiased;
                color: #fff;
                --ios-bg: rgba(20, 20, 22, 0.78);
                --ios-stroke: rgba(255, 255, 255, 0.08);
                --ios-fill: rgba(118, 118, 128, 0.24);
                --ios-fill-strong: rgba(118, 118, 128, 0.36);
                --ios-text: #fff;
                --ios-text-2: rgba(235, 235, 245, 0.6);
                --ios-text-3: rgba(235, 235, 245, 0.4);
                --ios-accent: #0a84ff;
                --ios-success: #30d158;
            }
            .ios-chrome[data-theme="light"] {
                color: #000;
                --ios-bg: rgba(248, 248, 250, 0.82);
                --ios-stroke: rgba(0, 0, 0, 0.08);
                --ios-fill: rgba(118, 118, 128, 0.12);
                --ios-fill-strong: rgba(118, 118, 128, 0.2);
                --ios-text: #000;
                --ios-text-2: rgba(60, 60, 67, 0.6);
                --ios-text-3: rgba(60, 60, 67, 0.4);
                --ios-accent: #007aff;
            }

            /* ============ TOP BAR ============ */
            #ios-landing-topbar {
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                z-index: 1500;
                background: var(--ios-bg);
                -webkit-backdrop-filter: saturate(180%) blur(28px);
                backdrop-filter: saturate(180%) blur(28px);
                border-bottom: 0.5px solid var(--ios-stroke);
                padding: calc(env(safe-area-inset-top, 0px) + 8px) 12px 10px 12px;
                pointer-events: auto;
                visibility: visible;
            }
            /* Tactical-ui root starts hidden/inactive; reveal our chrome
               only once it's been activated by flight.js. */
            #inflight-tactical-ui:not(.active) #ios-landing-topbar,
            #inflight-tactical-ui:not(.active) #ios-landing-tabbar {
                visibility: hidden;
                pointer-events: none;
                opacity: 0;
            }
            .ios-topbar-inner {
                position: relative;
                display: flex;
                align-items: center;
                gap: 8px;
                width: 100%;
                height: 38px;
            }

            /* Server pill */
            .ios-server-pill {
                flex: 0 0 auto;
                display: inline-flex;
                align-items: center;
                gap: 6px;
                height: 38px;
                padding: 0 12px;
                border: none;
                background: var(--ios-fill);
                color: var(--ios-text);
                border-radius: 19px;
                font-size: 13px;
                font-weight: 600;
                letter-spacing: 0.2px;
                cursor: pointer;
                transition: transform 0.15s ease, background-color 0.15s ease;
                -webkit-tap-highlight-color: transparent;
            }
            .ios-server-pill:active { transform: scale(0.96); background: var(--ios-fill-strong); }
            .ios-server-pill .ios-status-dot {
                width: 7px; height: 7px; border-radius: 50%;
                background: var(--ios-success);
                box-shadow: 0 0 6px rgba(48, 209, 88, 0.7);
            }
            .ios-server-name { line-height: 1; }

            /* Search shell */
            .ios-search-shell {
                flex: 1 1 auto;
                min-width: 0;
                height: 38px;
                padding: 0 10px;
                display: flex;
                align-items: center;
                gap: 7px;
                background: var(--ios-fill);
                border-radius: 10px;
                transition: background-color 0.2s ease;
            }
            .ios-search-shell.is-active { background: var(--ios-fill-strong); }
            .ios-search-glyph {
                color: var(--ios-text-2);
                font-size: 14px;
                flex: 0 0 auto;
            }
            .ios-search-slot {
                flex: 1 1 auto;
                min-width: 0;
                display: flex;
                align-items: center;
                gap: 6px;
                height: 100%;
            }
            #ios-landing-topbar #blade-search-input {
                flex: 1 1 auto !important;
                min-width: 0 !important;
                width: auto !important;
                height: 100% !important;
                margin: 0 !important;
                padding: 0 !important;
                border: none !important;
                outline: none !important;
                background: transparent !important;
                color: var(--ios-text) !important;
                font-family: inherit !important;
                font-size: 17px !important;
                font-weight: 400 !important;
                letter-spacing: -0.2px !important;
                -webkit-appearance: none !important;
                appearance: none !important;
                box-shadow: none !important;
            }
            #ios-landing-topbar #blade-search-input::placeholder {
                color: var(--ios-text-3) !important;
                font-weight: 400 !important;
            }
            #ios-landing-topbar #blade-search-clear {
                display: none;
                flex: 0 0 auto;
                width: 20px; height: 20px;
                padding: 0; margin: 0;
                border: none;
                background: transparent;
                color: var(--ios-text-3);
                font-size: 18px;
                line-height: 1;
                cursor: pointer;
            }
            #ios-landing-topbar #blade-search-input:not(:placeholder-shown) ~ #blade-search-clear,
            #ios-landing-topbar .has-text #blade-search-clear { display: inline-flex; align-items: center; justify-content: center; }

            /* Profile orb */
            .ios-profile-btn {
                flex: 0 0 auto;
                width: 38px; height: 38px;
                border: none;
                border-radius: 50%;
                background: var(--ios-fill);
                color: var(--ios-text);
                font-size: 15px;
                display: grid;
                place-items: center;
                cursor: pointer;
                transition: transform 0.15s ease, background-color 0.15s ease, opacity 0.2s ease;
                -webkit-tap-highlight-color: transparent;
            }
            .ios-profile-btn:active { transform: scale(0.92); background: var(--ios-fill-strong); }

            /* Cancel button — slides in over the profile orb */
            .ios-cancel-btn {
                position: absolute;
                top: 0; right: 0;
                height: 38px;
                padding: 0 2px 0 8px;
                border: none;
                background: transparent;
                color: var(--ios-accent);
                font-family: inherit;
                font-size: 17px;
                font-weight: 400;
                letter-spacing: -0.2px;
                cursor: pointer;
                opacity: 0;
                pointer-events: none;
                transform: translateX(8px);
                transition: opacity 0.2s ease, transform 0.2s ease;
            }
            #inflight-tactical-ui.mobile-search-active #ios-cancel-btn {
                opacity: 1; pointer-events: auto; transform: translateX(0);
            }
            #inflight-tactical-ui.mobile-search-active .ios-profile-btn,
            #inflight-tactical-ui.mobile-search-active .ios-server-pill {
                opacity: 0; pointer-events: none;
                transition: opacity 0.18s ease;
            }
            /* During search, the search field stretches across the bar */
            #inflight-tactical-ui.mobile-search-active .ios-search-shell {
                position: absolute;
                left: 0; right: 60px; top: 0;
                width: auto;
                height: 38px;
            }

            /* Search results — full-bleed sheet below the nav bar */
            #inflight-tactical-ui #blade-search-results {
                position: fixed !important;
                top: calc(env(safe-area-inset-top, 0px) + 56px) !important;
                left: 0 !important;
                right: 0 !important;
                width: 100vw !important;
                height: calc(100dvh - env(safe-area-inset-top, 0px) - 56px) !important;
                max-height: none !important;
                margin: 0 !important;
                padding: 0 0 calc(env(safe-area-inset-bottom, 0px) + 16px) !important;
                border: none !important;
                border-radius: 0 !important;
                background: rgba(10, 10, 11, 0.97) !important;
                -webkit-backdrop-filter: blur(20px) !important;
                backdrop-filter: blur(20px) !important;
                box-shadow: none !important;
                z-index: 1499 !important;
                pointer-events: auto !important;
                visibility: visible !important;
            }
            #inflight-tactical-ui[data-theme="light"] #blade-search-results {
                background: rgba(248, 248, 250, 0.98) !important;
            }
            #inflight-tactical-ui .blade-results-header {
                position: sticky !important;
                top: 0 !important;
                background: inherit !important;
                padding: 16px 16px 6px !important;
                font-size: 11px !important;
                font-weight: 600 !important;
                text-transform: uppercase !important;
                letter-spacing: 0.6px !important;
                color: var(--ios-text-2, rgba(235,235,245,0.6)) !important;
                z-index: 1 !important;
            }
            #inflight-tactical-ui .premium-result-item {
                min-height: 60px !important;
                padding: 12px 16px !important;
                gap: 14px !important;
                margin: 0 !important;
                border-radius: 0 !important;
                border-bottom: 0.5px solid rgba(255,255,255,0.08) !important;
            }
            #inflight-tactical-ui[data-theme="light"] .premium-result-item {
                border-bottom-color: rgba(0,0,0,0.08) !important;
            }
            #inflight-tactical-ui .premium-result-item:active {
                background: rgba(255,255,255,0.06) !important;
            }

            /* ============ BOTTOM TAB BAR ============ */
            #ios-landing-tabbar {
                position: fixed;
                left: 0; right: 0; bottom: 0;
                z-index: 1500;
                background: var(--ios-bg);
                -webkit-backdrop-filter: saturate(180%) blur(28px);
                backdrop-filter: saturate(180%) blur(28px);
                border-top: 0.5px solid var(--ios-stroke);
                padding-bottom: env(safe-area-inset-bottom, 0px);
                pointer-events: auto;
                visibility: visible;
                transition: transform 0.32s cubic-bezier(0.16,1,0.3,1), opacity 0.2s ease;
            }
            .ios-tabbar-inner {
                display: flex;
                align-items: stretch;
                justify-content: space-around;
                width: 100%;
                height: 52px;
                padding: 2px 4px 0;
            }
            .ios-tab {
                position: relative;
                flex: 1 1 0;
                min-width: 0;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                gap: 3px;
                padding: 4px 2px 6px;
                background: transparent;
                border: none;
                color: var(--ios-text-2);
                font-family: inherit;
                cursor: pointer;
                transition: color 0.15s ease, transform 0.15s ease;
                -webkit-tap-highlight-color: transparent;
            }
            .ios-tab i {
                font-size: 22px;
                line-height: 1;
            }
            .ios-tab .ios-tab-label {
                font-size: 10px;
                font-weight: 500;
                letter-spacing: 0.1px;
                line-height: 1.1;
            }
            .ios-tab:active { transform: scale(0.94); color: var(--ios-text); }
            .ios-tab.is-active { color: var(--ios-accent); }
            .ios-tab-dot {
                position: absolute;
                top: 4px;
                right: 22%;
                width: 8px; height: 8px;
                border-radius: 50%;
                background: var(--ios-accent);
                box-shadow: 0 0 6px rgba(10, 132, 255, 0.8);
                opacity: 0;
                transform: scale(0.6);
                transition: opacity 0.2s ease, transform 0.2s ease;
            }
            .ios-tab-dot.is-on { opacity: 1; transform: scale(1); }

            /* Hide tab bar when searching or a detail sheet is up */
            #inflight-tactical-ui.mobile-search-active #ios-landing-tabbar,
            #sector-ops-map-fullscreen:has(.mobile-island-bottom.island-active) #inflight-tactical-ui #ios-landing-tabbar {
                transform: translateY(120%);
                opacity: 0;
                pointer-events: none;
            }

            /* ============ SERVER BOTTOM SHEET ============ */
            .ios-sheet-root {
                position: fixed;
                inset: 0;
                z-index: 5000;
                opacity: 0;
                visibility: hidden;
                transition: opacity 0.25s ease, visibility 0.25s;
            }
            .ios-sheet-root.is-open { opacity: 1; visibility: visible; }
            .ios-sheet-backdrop {
                position: absolute;
                inset: 0;
                background: rgba(0, 0, 0, 0.45);
                -webkit-backdrop-filter: blur(2px);
                backdrop-filter: blur(2px);
            }
            .ios-sheet-card {
                position: absolute;
                left: 8px; right: 8px; bottom: 8px;
                padding: 8px 8px calc(env(safe-area-inset-bottom, 0px) + 8px);
                transform: translateY(20px);
                opacity: 0;
                transition: transform 0.32s cubic-bezier(0.16,1,0.3,1), opacity 0.25s ease;
            }
            .ios-sheet-root.is-open .ios-sheet-card { transform: translateY(0); opacity: 1; }
            .ios-sheet-grip {
                width: 36px; height: 5px;
                background: rgba(235, 235, 245, 0.3);
                border-radius: 3px;
                margin: 0 auto 8px;
                display: none; /* iOS action sheet doesn't use a grip */
            }
            .ios-sheet-title {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif;
                font-size: 13px;
                font-weight: 500;
                color: rgba(235, 235, 245, 0.6);
                text-align: center;
                padding: 14px 16px 10px;
                background: rgba(36, 36, 38, 0.88);
                -webkit-backdrop-filter: blur(40px);
                backdrop-filter: blur(40px);
                border-radius: 14px 14px 0 0;
            }
            .ios-sheet-group {
                background: rgba(36, 36, 38, 0.88);
                -webkit-backdrop-filter: blur(40px);
                backdrop-filter: blur(40px);
                border-radius: 0 0 14px 14px;
                overflow: hidden;
            }
            .ios-sheet-row {
                position: relative;
                display: flex;
                align-items: center;
                justify-content: space-between;
                width: 100%;
                padding: 16px 18px;
                background: transparent;
                border: none;
                color: #fff;
                font-family: inherit;
                font-size: 17px;
                font-weight: 400;
                text-align: left;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
            }
            .ios-sheet-row + .ios-sheet-row {
                border-top: 0.5px solid rgba(255, 255, 255, 0.1);
            }
            .ios-sheet-row:active { background: rgba(255, 255, 255, 0.06); }
            .ios-sheet-row-check {
                color: var(--ios-accent, #0a84ff);
                font-size: 16px;
                opacity: 0;
            }
            .ios-sheet-row.is-selected .ios-sheet-row-check { opacity: 1; }
            .ios-sheet-cancel {
                display: block;
                width: 100%;
                margin-top: 8px;
                padding: 16px;
                background: rgba(36, 36, 38, 0.95);
                -webkit-backdrop-filter: blur(40px);
                backdrop-filter: blur(40px);
                border: none;
                border-radius: 14px;
                color: var(--ios-accent, #0a84ff);
                font-family: inherit;
                font-size: 17px;
                font-weight: 600;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
            }
            .ios-sheet-cancel:active { background: rgba(50, 50, 52, 0.95); }

            /* ============ WEATHER POPOVER ============ */
            .ios-popover-root {
                position: fixed;
                inset: 0;
                z-index: 4900;
                opacity: 0;
                visibility: hidden;
                transition: opacity 0.2s ease, visibility 0.2s;
            }
            .ios-popover-root.is-open { opacity: 1; visibility: visible; }
            .ios-popover-backdrop {
                position: absolute;
                inset: 0;
                background: rgba(0, 0, 0, 0.25);
            }
            .ios-popover-card {
                position: absolute;
                left: 12px;
                right: 12px;
                bottom: calc(env(safe-area-inset-bottom, 0px) + 70px);
                max-width: 320px;
                margin: 0 auto;
                padding: 6px;
                background: rgba(36, 36, 38, 0.92);
                -webkit-backdrop-filter: saturate(180%) blur(40px);
                backdrop-filter: saturate(180%) blur(40px);
                border: 0.5px solid rgba(255, 255, 255, 0.1);
                border-radius: 16px;
                box-shadow: 0 14px 40px rgba(0, 0, 0, 0.5);
                transform: translateY(10px) scale(0.98);
                transform-origin: bottom center;
                opacity: 0;
                transition: transform 0.22s cubic-bezier(0.16,1,0.3,1), opacity 0.18s ease;
            }
            .ios-popover-root.is-open .ios-popover-card {
                transform: translateY(0) scale(1);
                opacity: 1;
            }
            .ios-popover-title {
                font-size: 11px;
                font-weight: 600;
                color: rgba(235, 235, 245, 0.6);
                text-transform: uppercase;
                letter-spacing: 0.6px;
                padding: 8px 12px 6px;
            }
            .ios-popover-row {
                display: flex;
                align-items: center;
                gap: 12px;
                width: 100%;
                padding: 12px;
                background: transparent;
                border: none;
                border-radius: 12px;
                color: #fff;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif;
                font-size: 15px;
                font-weight: 500;
                text-align: left;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
            }
            .ios-popover-row:active { background: rgba(255, 255, 255, 0.06); }
            .ios-popover-row i {
                flex: 0 0 auto;
                width: 22px;
                text-align: center;
                font-size: 15px;
                color: rgba(235, 235, 245, 0.7);
            }
            .ios-popover-row span:not(.ios-popover-switch) {
                flex: 1 1 auto;
            }
            .ios-popover-switch {
                flex: 0 0 auto;
                width: 36px;
                height: 22px;
                border-radius: 11px;
                background: rgba(120, 120, 128, 0.32);
                position: relative;
                transition: background-color 0.22s ease;
            }
            .ios-popover-switch::after {
                content: "";
                position: absolute;
                top: 2px; left: 2px;
                width: 18px; height: 18px;
                border-radius: 50%;
                background: #fff;
                box-shadow: 0 2px 4px rgba(0, 0, 0, 0.25);
                transition: transform 0.22s cubic-bezier(0.4, 0, 0.2, 1);
            }
            .ios-popover-row.is-on { color: #fff; }
            .ios-popover-row.is-on i { color: var(--ios-accent, #0a84ff); }
            .ios-popover-row.is-on .ios-popover-switch { background: #30d158; }
            .ios-popover-row.is-on .ios-popover-switch::after { transform: translateX(14px); }
        }
        `;

        const id = 'mobile-landing-chrome-ui-css';
        const old = document.getElementById(id);
        if (old) old.remove();
        const style = document.createElement('style');
        style.id = id;
        style.textContent = css;
        document.head.appendChild(style);
    },
};

if (typeof window !== 'undefined') {
    window.MobileLandingChromeUI = MobileLandingChromeUI;
}
