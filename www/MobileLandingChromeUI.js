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

const SERVER_META = {
    Expert:   { icon: 'fa-shield-halved', color: '#30d158', desc: 'Strict rules, realistic ops' },
    Training: { icon: 'fa-graduation-cap', color: '#ffd60a', desc: 'Practice with relaxed rules' },
    Casual:   { icon: 'fa-couch',          color: '#0a84ff', desc: 'Fly freely, no enforcement' },
};

const WEATHER_LAYERS = [
    { id: 'precip',  label: 'Precipitation', sub: 'Live radar + intensity', icon: 'fa-satellite-dish' },
    { id: 'sigmets', label: 'SIGMETs',       sub: 'Significant weather',    icon: 'fa-triangle-exclamation' },
    { id: 'clouds',  label: 'Clouds',        sub: 'Coverage overlay',       icon: 'fa-cloud' },
    { id: 'wind',    label: 'Winds Aloft',   sub: 'Direction + speed',      icon: 'fa-wind' },
];

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
        this._applyServerVisual(this.parent?._currentServer || 'Expert');
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
        const initialServer = (this.parent?._currentServer || 'Expert');
        topBar.innerHTML = `
            <div class="ios-topbar-inner">
                <button type="button" class="ios-server-pill" id="ios-server-pill" aria-label="Server: ${initialServer}">
                    <span class="ios-server-initial" id="ios-server-initial">${initialServer.charAt(0).toUpperCase()}</span>
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
                    <span class="ios-tab-iconwrap">
                        <i class="fa-solid fa-sliders"></i>
                        <span class="ios-tab-badge" id="ios-tab-filter-dot">0</span>
                    </span>
                    <span class="ios-tab-label">Filters</span>
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
                <div class="ios-sheet-title">Choose Server</div>
                <div class="ios-sheet-group">
                    ${Object.entries(SERVER_META).map(([name, meta]) => `
                        <button type="button" class="ios-sheet-row" data-server="${name}">
                            <span class="ios-sheet-row-icon" style="background:${meta.color}1f;color:${meta.color};">
                                <i class="fa-solid ${meta.icon}"></i>
                            </span>
                            <span class="ios-sheet-row-text">
                                <span class="ios-sheet-row-label">${name}</span>
                                <span class="ios-sheet-row-sub">${meta.desc}</span>
                            </span>
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
                <div class="ios-popover-header">
                    <span class="ios-popover-eyebrow">Map Overlays</span>
                    <span class="ios-popover-heading">Weather</span>
                </div>
                <div class="ios-popover-list">
                ${WEATHER_LAYERS.map(w => `
                    <button type="button" class="ios-popover-row" data-weather="${w.id}">
                        <span class="ios-popover-icon"><i class="fa-solid ${w.icon}"></i></span>
                        <span class="ios-popover-text">
                            <span class="ios-popover-label">${w.label}</span>
                            <span class="ios-popover-sub">${w.sub}</span>
                        </span>
                        <span class="ios-popover-switch" aria-hidden="true"></span>
                    </button>
                `).join('')}
                </div>
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
        // Open via pointerup (fires before click on iOS, avoids the synthetic
        // delay) and fall back to click for accessibility tooling. Wrapped in
        // try/catch so a failure surfaces instead of silently dying.
        const openProfile = (ev) => {
            ev?.preventDefault?.();
            ev?.stopPropagation?.();
            try {
                if (window.AuthUI && typeof window.AuthUI.open === 'function') {
                    Promise.resolve(window.AuthUI.open()).catch(err =>
                        console.error('AuthUI.open failed:', err));
                } else {
                    import('./authUI.js')
                        .then(m => m.AuthUI.open())
                        .catch(err => console.error('Failed to load AuthUI:', err));
                }
            } catch (err) {
                console.error('Profile button handler error:', err);
            }
        };
        profileBtn?.addEventListener('pointerup', openProfile);
        profileBtn?.addEventListener('click', openProfile);

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
            this._applyServerVisual(name);
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
        document.querySelectorAll('#ios-landing-tabbar .ios-tab').forEach(t => t.classList.remove('is-pressed'));
        btn?.classList.add('is-pressed');
        setTimeout(() => btn?.classList.remove('is-pressed'), 320);
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
        this._applyServerVisual(name);
        const oldLabel = document.getElementById('landing-server-name');
        if (oldLabel) oldLabel.textContent = `${name.toUpperCase()} SERVER`;
        this._refreshServerSheetChecks(name);
        window.dispatchEvent(new CustomEvent('serverChange', { detail: { server: name } }));
    },
    _applyServerVisual(name) {
        const meta = SERVER_META[name] || SERVER_META.Expert;
        const pill = document.getElementById('ios-server-pill');
        const initial = document.getElementById('ios-server-initial');
        if (initial) initial.textContent = name.charAt(0).toUpperCase();
        if (pill) {
            pill.setAttribute('aria-label', `Server: ${name}`);
            pill.style.setProperty('--server-tint', meta.color);
        }
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
        const count = (this.parent && this.parent._activeFilters)
            ? Object.keys(this.parent._activeFilters).length
            : 0;
        dot.textContent = count > 9 ? '9+' : String(count);
        dot.classList.toggle('is-on', count > 0);
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

            /* ============ SHARED — NATIVE GLASS TOKENS ============
               Let backdrop-filter do the work. One hairline, one shadow.
               No fake sheens, no multi-edge inset highlights. */
            .ios-chrome,
            .ios-sheet-root,
            .ios-popover-root {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                -webkit-font-smoothing: antialiased;
                color: #fff;
                --ios-bg: rgba(30, 30, 32, 0.55);
                --ios-bg-elev: rgba(40, 40, 44, 0.70);
                --ios-bg-deep: rgba(48, 48, 52, 0.82);
                --ios-stroke: rgba(255, 255, 255, 0.14);
                --ios-stroke-soft: rgba(255, 255, 255, 0.08);
                --ios-fill: rgba(255, 255, 255, 0.08);
                --ios-fill-strong: rgba(255, 255, 255, 0.14);
                --ios-text: #ffffff;
                --ios-text-2: rgba(255, 255, 255, 0.90);
                --ios-text-3: rgba(235, 235, 245, 0.60);
                --ios-text-4: rgba(235, 235, 245, 0.30);
                --ios-accent: #0a84ff;
                --ios-success: #30d158;
                --ios-warning: #ffd60a;
                /* iOS Material.regular ≈ blur(30) + saturate(180%) */
                --ios-blur: saturate(180%) blur(30px);
                --ios-inner-hi: none;
                --ios-shadow: 0 4px 18px rgba(0, 0, 0, 0.25);
            }
            .ios-chrome[data-theme="light"],
            .ios-sheet-root[data-theme="light"],
            .ios-popover-root[data-theme="light"] {
                color: #000;
                --ios-bg: rgba(245, 245, 247, 0.72);
                --ios-bg-elev: rgba(250, 250, 252, 0.82);
                --ios-bg-deep: rgba(252, 252, 254, 0.90);
                --ios-stroke: rgba(0, 0, 0, 0.08);
                --ios-stroke-soft: rgba(0, 0, 0, 0.05);
                --ios-fill: rgba(0, 0, 0, 0.05);
                --ios-fill-strong: rgba(0, 0, 0, 0.10);
                --ios-text: #000;
                --ios-text-2: rgba(0, 0, 0, 0.88);
                --ios-text-3: rgba(60, 60, 67, 0.6);
                --ios-text-4: rgba(60, 60, 67, 0.3);
                --ios-accent: #007aff;
                --ios-shadow: 0 4px 18px rgba(0, 0, 0, 0.10);
            }

            /* ============ TOP BAR — bare positioning frame ============
               No wrapper card. Each child below is its own glass bead. */
            #ios-landing-topbar {
                position: fixed;
                top: calc(env(safe-area-inset-top, 0px) + 2px);
                left: 8px;
                right: 8px;
                z-index: 1500;
                background: transparent;
                border: none;
                box-shadow: none;
                padding: 7px 0;
                pointer-events: none; /* let map gestures through the gaps */
                visibility: visible;
            }
            #ios-landing-topbar .ios-topbar-inner > * { pointer-events: auto; }
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

            /* Server pill — standalone glass bead */
            .ios-server-pill {
                flex: 0 0 auto;
                display: grid;
                place-items: center;
                width: 38px;
                height: 38px;
                padding: 0;
                border: 0.5px solid var(--ios-stroke);
                background: var(--ios-bg);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                color: var(--server-tint, var(--ios-text));
                border-radius: 50%;
                cursor: pointer;
                box-shadow: var(--ios-shadow);
                transition:
                    transform 0.22s cubic-bezier(0.16,1,0.3,1),
                    background-color 0.22s ease,
                    color 0.25s ease;
                -webkit-tap-highlight-color: transparent;
            }
            .ios-server-pill:active {
                transform: scale(0.9);
                background: var(--ios-fill-strong);
            }
            .ios-server-initial {
                font-family: inherit;
                font-size: 15px;
                font-weight: 700;
                line-height: 1;
                color: inherit;
            }

            /* Search shell — standalone glass capsule */
            .ios-search-shell {
                flex: 1 1 auto;
                min-width: 0;
                height: 38px;
                padding: 0 14px;
                display: flex;
                align-items: center;
                gap: 8px;
                background: var(--ios-bg);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                border: 0.5px solid var(--ios-stroke);
                border-radius: 999px;
                box-shadow: var(--ios-shadow);
                transition: background-color 0.22s ease;
            }
            .ios-search-shell.is-active { background: var(--ios-bg-elev); }
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

            /* Profile orb — standalone glass bead */
            .ios-profile-btn {
                flex: 0 0 auto;
                width: 38px; height: 38px;
                border: 0.5px solid var(--ios-stroke);
                border-radius: 50%;
                background: var(--ios-bg);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                color: var(--ios-text);
                font-size: 15px;
                display: grid;
                place-items: center;
                cursor: pointer;
                box-shadow: var(--ios-shadow);
                position: relative;
                z-index: 2;
                touch-action: manipulation;
                -webkit-user-select: none;
                user-select: none;
                transition:
                    transform 0.22s cubic-bezier(0.16,1,0.3,1),
                    background-color 0.22s ease,
                    opacity 0.2s ease;
                -webkit-tap-highlight-color: transparent;
            }
            /* Invisible 44pt tap target that overflows the visual bead — meets
               Apple's HIG minimum hit area without growing the chrome. */
            .ios-profile-btn::after {
                content: "";
                position: absolute;
                inset: -6px;
                border-radius: 50%;
            }
            .ios-profile-btn:active { transform: scale(0.9); background: var(--ios-bg-elev); }

            /* Cancel button — slides in over the profile orb */
            .ios-cancel-btn {
                position: absolute;
                top: 0; right: 4px;
                height: 38px;
                padding: 0 2px 0 8px;
                border: none;
                background: transparent;
                color: var(--ios-accent);
                font-family: inherit;
                font-size: 16px;
                font-weight: 500;
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
                left: 0; right: 64px; top: 0;
                width: auto;
                height: 38px;
            }

            /* ============ SEARCH RESULTS — floating glass card ============
               Matches the search capsule above: same margins, hairline,
               backdrop-filter, and corner radius. Sits as a contained
               sheet under the search bead, not a full-bleed page. */
            #inflight-tactical-ui #blade-search-results {
                position: fixed !important;
                top: calc(env(safe-area-inset-top, 0px) + 54px) !important;
                left: 8px !important;
                right: 8px !important;
                width: auto !important;
                max-height: calc(100dvh - env(safe-area-inset-top, 0px) - max(env(safe-area-inset-bottom, 0px), 4px) - 80px) !important;
                height: auto !important;
                margin: 0 !important;
                padding: 6px !important;
                border: 0.5px solid var(--ios-stroke) !important;
                border-radius: 22px !important;
                background: var(--ios-bg-deep) !important;
                -webkit-backdrop-filter: var(--ios-blur) !important;
                backdrop-filter: var(--ios-blur) !important;
                box-shadow: var(--ios-shadow) !important;
                overflow-y: auto !important;
                -webkit-overflow-scrolling: touch !important;
                overscroll-behavior: contain !important;
                z-index: 1499 !important;
                pointer-events: auto !important;
                visibility: visible !important;
            }
            #inflight-tactical-ui[data-theme="light"] #blade-search-results {
                background: var(--ios-bg-deep) !important;
            }
            /* Hide native scrollbar — iOS aesthetic. */
            #inflight-tactical-ui #blade-search-results::-webkit-scrollbar {
                width: 0 !important;
                background: transparent !important;
            }

            /* Section divider between result groups — clean hairline, no padding noise. */
            #inflight-tactical-ui .blade-results-section + .blade-results-section {
                border-top: 0.5px solid var(--ios-stroke-soft) !important;
                margin-top: 6px !important;
                padding-top: 4px !important;
            }
            /* Section header — small uppercase label inside the glass card. */
            #inflight-tactical-ui .blade-results-header {
                position: static !important;
                background: transparent !important;
                padding: 10px 12px 4px !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 11px !important;
                font-weight: 600 !important;
                text-transform: uppercase !important;
                letter-spacing: 0.5px !important;
                color: var(--ios-text-3) !important;
                display: flex !important;
                align-items: center !important;
                justify-content: space-between !important;
            }
            #inflight-tactical-ui .blade-results-count {
                font-family: inherit !important;
                font-size: 11px !important;
                font-weight: 500 !important;
                color: var(--ios-text-4) !important;
                letter-spacing: 0 !important;
            }

            /* Result rows — flush inside the rounded card, gentle press feedback. */
            #inflight-tactical-ui .premium-result-item {
                min-height: 56px !important;
                padding: 10px 12px !important;
                gap: 12px !important;
                margin: 0 !important;
                border: none !important;
                border-radius: 14px !important;
                background: transparent !important;
                transition: background-color 0.15s ease !important;
            }
            #inflight-tactical-ui .premium-result-item + .premium-result-item {
                margin-top: 1px !important;
            }
            #inflight-tactical-ui .premium-result-item:active,
            #inflight-tactical-ui .premium-result-item.selected {
                background: var(--ios-fill) !important;
            }

            /* Result row typography & inner chip — iOS palette */
            #inflight-tactical-ui .premium-result-item .res-callsign {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 15px !important;
                font-weight: 600 !important;
                letter-spacing: -0.2px !important;
                color: var(--ios-text) !important;
            }
            #inflight-tactical-ui .premium-result-item .res-secondary-row,
            #inflight-tactical-ui .premium-result-item .res-pilot {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 12.5px !important;
                font-weight: 400 !important;
                color: var(--ios-text-3) !important;
            }
            #inflight-tactical-ui .premium-result-item .res-pill {
                background: var(--ios-fill) !important;
                color: var(--ios-text-2) !important;
                font-size: 10px !important;
                font-weight: 600 !important;
                padding: 2px 7px !important;
                border-radius: 6px !important;
                letter-spacing: 0.02em !important;
            }
            #inflight-tactical-ui .premium-result-item .res-altitude {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 13px !important;
                font-weight: 600 !important;
                color: var(--ios-text) !important;
            }
            #inflight-tactical-ui .premium-result-item .res-altitude span {
                color: var(--ios-text-3) !important;
                font-weight: 400 !important;
            }
            #inflight-tactical-ui .premium-highlight {
                color: var(--ios-accent) !important;
                font-weight: 700 !important;
            }
            #inflight-tactical-ui .premium-empty-state {
                padding: 28px 16px !important;
                color: var(--ios-text-3) !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 14px !important;
            }

            /* ============ BOTTOM TAB BAR — native glass stadium ============ */
            #ios-landing-tabbar {
                position: fixed;
                left: 8px;
                right: 8px;
                bottom: max(env(safe-area-inset-bottom, 0px), 4px);
                z-index: 1500;
                background: var(--ios-bg);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                border: 0.5px solid var(--ios-stroke);
                border-radius: 28px;
                box-shadow: var(--ios-shadow);
                pointer-events: auto;
                visibility: visible;
                transition: transform 0.34s cubic-bezier(0.16,1,0.3,1), opacity 0.2s ease;
            }
            .ios-tabbar-inner {
                display: flex;
                align-items: stretch;
                justify-content: space-around;
                width: 100%;
                height: 56px;
                padding: 4px;
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
                padding: 0;
                background: transparent;
                border: none;
                border-radius: 18px;
                color: var(--ios-text-2);
                font-family: inherit;
                cursor: pointer;
                transition:
                    color 0.22s ease,
                    background-color 0.18s ease,
                    transform 0.18s cubic-bezier(0.16,1,0.3,1);
                -webkit-tap-highlight-color: transparent;
            }
            .ios-tab i {
                font-size: 20px;
                line-height: 1;
                color: inherit;
            }
            .ios-tab .ios-tab-label {
                font-size: 10.5px;
                font-weight: 600;
                letter-spacing: 0.05px;
                line-height: 1.1;
                color: inherit;
            }
            .ios-tab:active {
                background: var(--ios-fill);
                transform: scale(0.96);
            }
            .ios-tab.is-pressed { color: var(--ios-accent); }
            .ios-tab-iconwrap {
                position: relative;
                display: grid;
                place-items: center;
                line-height: 0;
            }
            .ios-tab-iconwrap i { font-size: 20px; line-height: 1; }

            /* Filter icon wrapper so the badge can anchor relative to the icon */
            .ios-tab-iconwrap {
                position: relative;
                display: grid;
                place-items: center;
                line-height: 0;
            }
            .ios-tab-iconwrap i {
                font-size: 20px;
                line-height: 1;
            }

            /* Filter count badge */
            .ios-tab-badge {
                position: absolute;
                top: -6px;
                right: -10px;
                min-width: 16px;
                height: 16px;
                padding: 0 4px;
                border-radius: 999px;
                background: #ff453a;
                color: #fff;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif;
                font-size: 10px;
                font-weight: 700;
                line-height: 16px;
                text-align: center;
                box-shadow: 0 1px 3px rgba(255, 69, 58, 0.45);
                opacity: 0;
                transform: scale(0.4);
                transition:
                    opacity 0.22s ease,
                    transform 0.28s cubic-bezier(0.16,1,0.3,1);
                pointer-events: none;
            }
            .ios-tab-badge.is-on { opacity: 1; transform: scale(1); }

            /* Hide tab bar when searching or a detail sheet is up */
            #inflight-tactical-ui.mobile-search-active #ios-landing-tabbar,
            #sector-ops-map-fullscreen:has(.mobile-island-bottom.island-active) #inflight-tactical-ui #ios-landing-tabbar {
                transform: translateY(140%);
                opacity: 0;
                pointer-events: none;
            }

            /* ============ SERVER BOTTOM SHEET (iOS Action Sheet) ============ */
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
                background: rgba(0, 0, 0, 0.35);
                -webkit-backdrop-filter: blur(2px);
                backdrop-filter: blur(2px);
            }
            .ios-sheet-card {
                position: absolute;
                left: 10px; right: 10px; bottom: 10px;
                padding: 0;
                transform: translateY(24px);
                opacity: 0;
                transition:
                    transform 0.4s cubic-bezier(0.16,1,0.3,1),
                    opacity 0.28s ease;
            }
            .ios-sheet-root.is-open .ios-sheet-card { transform: translateY(0); opacity: 1; }
            .ios-sheet-grip { display: none; }
            .ios-sheet-title {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif;
                font-size: 13px;
                font-weight: 600;
                color: var(--ios-text-3);
                text-align: center;
                padding: 16px 16px 12px;
                background: var(--ios-bg-deep);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                border-radius: 16px 16px 0 0;
                box-shadow: var(--ios-inner-hi);
                letter-spacing: 0.2px;
                text-transform: uppercase;
            }
            .ios-sheet-group {
                background: var(--ios-bg-deep);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                border-radius: 0 0 16px 16px;
                overflow: hidden;
                box-shadow: var(--ios-shadow);
            }
            .ios-sheet-row {
                position: relative;
                display: flex;
                align-items: center;
                gap: 14px;
                width: 100%;
                padding: 14px 18px;
                background: transparent;
                border: none;
                color: var(--ios-text);
                font-family: inherit;
                font-size: 17px;
                font-weight: 400;
                text-align: left;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
                transition: background-color 0.18s ease;
            }
            .ios-sheet-row + .ios-sheet-row {
                border-top: 0.5px solid var(--ios-stroke);
            }
            .ios-sheet-row:active { background: rgba(255, 255, 255, 0.08); }
            .ios-sheet-row-icon {
                flex: 0 0 auto;
                display: grid;
                place-items: center;
                width: 34px;
                height: 34px;
                border-radius: 10px;
                font-size: 15px;
                box-shadow: inset 0 0.5px 0 rgba(255,255,255,0.15);
            }
            .ios-sheet-row-text {
                flex: 1 1 auto;
                min-width: 0;
                display: flex;
                flex-direction: column;
                gap: 2px;
            }
            .ios-sheet-row-label {
                font-size: 16px;
                font-weight: 600;
                letter-spacing: -0.2px;
                color: var(--ios-text);
            }
            .ios-sheet-row-sub {
                font-size: 12.5px;
                font-weight: 400;
                color: var(--ios-text-3);
                letter-spacing: -0.1px;
            }
            .ios-sheet-row-check {
                flex: 0 0 auto;
                color: var(--ios-accent);
                font-size: 17px;
                font-weight: 700;
                opacity: 0;
                transform: scale(0.7);
                transition: opacity 0.2s ease, transform 0.25s cubic-bezier(0.16,1,0.3,1);
            }
            .ios-sheet-row.is-selected { background: rgba(10, 132, 255, 0.10); }
            .ios-sheet-row.is-selected .ios-sheet-row-check { opacity: 1; transform: scale(1); }
            .ios-sheet-cancel {
                display: block;
                width: 100%;
                margin-top: 8px;
                padding: 16px;
                background: var(--ios-bg-deep);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                border: none;
                border-radius: 14px;
                color: var(--ios-accent);
                font-family: inherit;
                font-size: 17px;
                font-weight: 600;
                cursor: pointer;
                box-shadow: var(--ios-inner-hi);
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
                bottom: calc(max(env(safe-area-inset-bottom, 0px), 4px) + 72px);
                max-width: 340px;
                margin: 0 auto;
                padding: 6px;
                background: var(--ios-bg-deep);
                -webkit-backdrop-filter: var(--ios-blur);
                backdrop-filter: var(--ios-blur);
                border: 0.5px solid var(--ios-stroke);
                border-radius: 20px;
                box-shadow: var(--ios-inner-hi), var(--ios-shadow);
                transform: translateY(12px) scale(0.96);
                transform-origin: bottom center;
                opacity: 0;
                transition:
                    transform 0.32s cubic-bezier(0.16,1,0.3,1),
                    opacity 0.22s ease;
            }
            .ios-popover-root.is-open .ios-popover-card {
                transform: translateY(0) scale(1);
                opacity: 1;
            }
            .ios-popover-header {
                display: flex;
                flex-direction: column;
                gap: 2px;
                padding: 10px 14px 10px;
                border-bottom: 0.5px solid var(--ios-stroke-soft);
                margin-bottom: 4px;
            }
            .ios-popover-eyebrow {
                font-size: 10.5px;
                font-weight: 600;
                color: var(--ios-text-3);
                text-transform: uppercase;
                letter-spacing: 0.6px;
            }
            .ios-popover-heading {
                font-size: 19px;
                font-weight: 700;
                letter-spacing: -0.4px;
                color: var(--ios-text);
            }
            .ios-popover-list {
                display: flex;
                flex-direction: column;
                gap: 2px;
                padding: 2px;
            }
            .ios-popover-row {
                display: flex;
                align-items: center;
                gap: 12px;
                width: 100%;
                padding: 10px 10px;
                background: transparent;
                border: none;
                border-radius: 12px;
                color: var(--ios-text);
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif;
                font-size: 15px;
                font-weight: 500;
                text-align: left;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
                transition: background-color 0.18s ease;
            }
            .ios-popover-row:active { background: rgba(255, 255, 255, 0.06); }
            .ios-popover-icon {
                flex: 0 0 auto;
                display: grid;
                place-items: center;
                width: 32px;
                height: 32px;
                border-radius: 9px;
                background: var(--ios-fill);
                box-shadow: inset 0 0.5px 0 rgba(255,255,255,0.15);
                color: var(--ios-text-2);
                font-size: 14px;
                transition: background-color 0.22s ease, color 0.22s ease;
            }
            .ios-popover-icon i { line-height: 1; }
            .ios-popover-text {
                flex: 1 1 auto;
                min-width: 0;
                display: flex;
                flex-direction: column;
                gap: 1px;
            }
            .ios-popover-label {
                font-size: 15px;
                font-weight: 600;
                letter-spacing: -0.2px;
                color: var(--ios-text);
            }
            .ios-popover-sub {
                font-size: 11.5px;
                font-weight: 400;
                color: var(--ios-text-3);
                letter-spacing: -0.1px;
            }
            .ios-popover-switch {
                flex: 0 0 auto;
                width: 40px;
                height: 24px;
                border-radius: 12px;
                background: rgba(120, 120, 128, 0.32);
                position: relative;
                transition: background-color 0.25s ease;
                box-shadow: inset 0 1px 2px rgba(0,0,0,0.18);
            }
            .ios-popover-switch::after {
                content: "";
                position: absolute;
                top: 2px; left: 2px;
                width: 20px; height: 20px;
                border-radius: 50%;
                background: #fff;
                box-shadow:
                    0 2px 4px rgba(0,0,0,0.28),
                    0 0 1px rgba(0,0,0,0.18);
                transition: transform 0.28s cubic-bezier(0.4, 0, 0.2, 1);
            }
            .ios-popover-row.is-on .ios-popover-icon {
                background: color-mix(in srgb, var(--ios-accent) 22%, transparent);
                color: var(--ios-accent);
            }
            .ios-popover-row.is-on .ios-popover-switch { background: var(--ios-success); }
            .ios-popover-row.is-on .ios-popover-switch::after { transform: translateX(16px); }

            /* ============================================================
               UNIFIED iOS GLASS — Filter sheet + Settings sheet
               Re-skins the existing #mobile-tactical-nexus and
               #mobile-settings-nexus markup to match the new chrome.
               ============================================================ */
            #mobile-tactical-nexus,
            #mobile-settings-nexus {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                color: #fff;
                --ios-bg: rgba(22, 22, 26, 0.52);
                --ios-bg-elev: rgba(28, 28, 32, 0.62);
                --ios-bg-deep: rgba(36, 36, 40, 0.78);
                --ios-stroke: rgba(255, 255, 255, 0.12);
                --ios-stroke-soft: rgba(255, 255, 255, 0.06);
                --ios-fill: rgba(120, 120, 128, 0.28);
                --ios-fill-strong: rgba(120, 120, 128, 0.4);
                --ios-text: #ffffff;
                --ios-text-2: rgba(255, 255, 255, 0.88);
                --ios-text-3: rgba(255, 255, 255, 0.62);
                --ios-text-4: rgba(255, 255, 255, 0.42);
                --ios-accent: #0a84ff;
                --ios-success: #30d158;
                --ios-blur: saturate(200%) blur(40px);
                --ios-inner-hi: inset 0 0.5px 0 rgba(255, 255, 255, 0.18);
                --ios-shadow: 0 16px 40px rgba(0, 0, 0, 0.55);
            }

            /* Softer dim instead of heavy black */
            #mobile-tactical-nexus .mobile-sheet-overlay,
            #mobile-settings-nexus .mobile-sheet-overlay {
                background: rgba(0, 0, 0, 0.32) !important;
                -webkit-backdrop-filter: blur(2px) !important;
                backdrop-filter: blur(2px) !important;
            }

            /* The sheet itself — frosted glass */
            #mobile-tactical-nexus .mobile-bottom-sheet,
            #mobile-settings-nexus .mobile-bottom-sheet {
                background: var(--ios-bg-deep) !important;
                -webkit-backdrop-filter: var(--ios-blur) !important;
                backdrop-filter: var(--ios-blur) !important;
                border-top: 0.5px solid var(--ios-stroke) !important;
                border-radius: 18px 18px 0 0 !important;
                box-shadow: var(--ios-inner-hi), 0 -10px 40px rgba(0, 0, 0, 0.55) !important;
                color: #fff !important;
            }

            /* Grip handle */
            #mobile-tactical-nexus .sheet-handle,
            #mobile-settings-nexus .sheet-handle {
                width: 36px !important;
                height: 5px !important;
                background: rgba(255, 255, 255, 0.32) !important;
                border-radius: 3px !important;
                margin: 10px auto 8px !important;
            }

            /* Title */
            #mobile-tactical-nexus .mobile-title,
            #mobile-settings-nexus .mobile-title {
                padding: 4px 20px 14px !important;
                font-family: inherit !important;
                font-size: 17px !important;
                font-weight: 600 !important;
                letter-spacing: -0.2px !important;
                color: #fff !important;
                text-transform: none !important;
                display: flex !important;
                align-items: center !important;
                justify-content: center !important;
                gap: 10px !important;
            }
            #mobile-tactical-nexus .mobile-title i,
            #mobile-settings-nexus .mobile-title i {
                color: var(--ios-accent) !important;
                font-size: 16px !important;
            }

            /* Section headers — iOS grouped list style */
            #mobile-tactical-nexus .mobile-section-header,
            #mobile-settings-nexus .mobile-section-header {
                padding: 22px 22px 8px !important;
                font-family: inherit !important;
                font-size: 12px !important;
                font-weight: 500 !important;
                letter-spacing: 0.3px !important;
                color: var(--ios-text-3) !important;
                text-transform: uppercase !important;
                margin: 0 !important;
            }
            #mobile-settings-nexus .mobile-section-header.pro-accent {
                color: var(--ios-warning, #ffd60a) !important;
            }

            /* ---- FILTER SHEET — grid items + active cards ---- */
            #mobile-tactical-nexus .mobile-filter-grid {
                padding: 0 16px !important;
                gap: 8px !important;
            }
            #mobile-tactical-nexus .m-grid-item {
                background: var(--ios-fill) !important;
                border: none !important;
                border-radius: 14px !important;
                box-shadow: var(--ios-inner-hi) !important;
                color: var(--ios-text) !important;
                padding: 12px 4px !important;
                gap: 6px !important;
                transition: transform 0.15s ease, background-color 0.15s ease !important;
                -webkit-tap-highlight-color: transparent !important;
            }
            #mobile-tactical-nexus .m-grid-item i {
                font-size: 16px !important;
                color: var(--ios-text-2) !important;
            }
            #mobile-tactical-nexus .m-grid-item span {
                font-size: 11px !important;
                font-weight: 500 !important;
                color: var(--ios-text-2) !important;
            }
            #mobile-tactical-nexus .m-grid-item:active {
                transform: scale(0.96) !important;
                background: var(--ios-fill-strong) !important;
            }

            #mobile-tactical-nexus #mobile-active-rules-container {
                padding: 0 16px !important;
            }
            #mobile-tactical-nexus .m-active-card {
                background: var(--ios-bg-elev) !important;
                border: none !important;
                border-radius: 14px !important;
                box-shadow: var(--ios-inner-hi) !important;
                padding: 16px !important;
                margin-bottom: 8px !important;
                color: #fff !important;
            }
            #mobile-tactical-nexus .m-card-info {
                color: var(--ios-text) !important;
                font-weight: 600 !important;
                font-size: 15px !important;
            }
            #mobile-tactical-nexus .m-card-info i {
                color: var(--ios-accent) !important;
            }
            #mobile-tactical-nexus .m-card-remove {
                color: var(--ios-text-3) !important;
                opacity: 1 !important;
            }
            #mobile-tactical-nexus .m-card-remove:active {
                color: #ff453a !important;
            }
            #mobile-tactical-nexus .m-card-input-wrapper .row-input,
            #mobile-tactical-nexus .m-card-input-wrapper .row-input-select,
            #mobile-tactical-nexus .m-card-input-wrapper .range-pill-container,
            #mobile-tactical-nexus .m-card-input-wrapper .range-input {
                background: var(--ios-fill) !important;
                border: none !important;
                border-radius: 10px !important;
                color: #fff !important;
                font-family: inherit !important;
            }
            #mobile-tactical-nexus .m-empty-text {
                color: var(--ios-text-3) !important;
                font-style: normal !important;
                font-size: 14px !important;
            }

            /* ---- SETTINGS SHEET — pills, rows, toggles, range ---- */
            #mobile-settings-nexus .settings-mobile-grid {
                padding: 0 16px !important;
                gap: 8px !important;
            }
            #mobile-settings-nexus .m-setting-pill {
                background: var(--ios-fill) !important;
                border: none !important;
                border-radius: 12px !important;
                box-shadow: var(--ios-inner-hi) !important;
                color: var(--ios-text-2) !important;
                padding: 11px 8px !important;
                font-family: inherit !important;
                font-size: 13px !important;
                font-weight: 600 !important;
                transition: transform 0.15s ease, background-color 0.15s ease !important;
                -webkit-tap-highlight-color: transparent !important;
            }
            #mobile-settings-nexus .m-setting-pill:active {
                transform: scale(0.96) !important;
                background: var(--ios-fill-strong) !important;
            }
            #mobile-settings-nexus .m-setting-pill.active {
                background: var(--ios-accent) !important;
                color: #fff !important;
                border-color: transparent !important;
            }

            #mobile-settings-nexus .m-settings-list {
                padding: 0 16px !important;
                gap: 0 !important;
                background: var(--ios-bg-elev) !important;
                border-radius: 14px !important;
                box-shadow: var(--ios-inner-hi) !important;
                overflow: hidden !important;
                margin: 0 16px !important;
                padding: 0 !important;
            }
            #mobile-settings-nexus .m-setting-row {
                background: transparent !important;
                border-radius: 0 !important;
                padding: 13px 16px !important;
                border-bottom: 0.5px solid var(--ios-stroke) !important;
            }
            #mobile-settings-nexus .m-setting-row:last-child {
                border-bottom: none !important;
            }
            #mobile-settings-nexus .m-row-left {
                color: var(--ios-text) !important;
                font-size: 15px !important;
                font-weight: 400 !important;
                gap: 14px !important;
            }
            #mobile-settings-nexus .m-row-left i {
                color: var(--ios-accent) !important;
                font-size: 15px !important;
                width: 20px !important;
            }
            #mobile-settings-nexus .m-row-right { gap: 10px !important; }

            /* iOS-style toggle switch */
            #mobile-settings-nexus .m-switch {
                width: 51px !important;
                height: 31px !important;
            }
            #mobile-settings-nexus .m-slider {
                background-color: rgba(120, 120, 128, 0.36) !important;
                border-radius: 31px !important;
                transition: background-color 0.22s ease !important;
            }
            #mobile-settings-nexus .m-slider:before {
                height: 27px !important;
                width: 27px !important;
                left: 2px !important;
                bottom: 2px !important;
                background-color: #fff !important;
                box-shadow: 0 2px 4px rgba(0, 0, 0, 0.25), 0 0 1px rgba(0, 0, 0, 0.2) !important;
                transition: transform 0.22s cubic-bezier(0.4, 0, 0.2, 1) !important;
            }
            #mobile-settings-nexus input:checked + .m-slider {
                background-color: var(--ios-success) !important;
            }
            #mobile-settings-nexus input:checked + .m-slider:before {
                transform: translateX(20px) !important;
            }

            /* Range / pickers */
            #mobile-settings-nexus .m-setting-range-card {
                background: var(--ios-bg-elev) !important;
                border-radius: 14px !important;
                box-shadow: var(--ios-inner-hi) !important;
                padding: 14px 16px !important;
                margin: 0 16px !important;
            }
            #mobile-settings-nexus .range-header {
                font-size: 14px !important;
                color: var(--ios-text) !important;
            }
            #mobile-settings-nexus .m-range-input {
                accent-color: var(--ios-accent) !important;
            }
            #mobile-settings-nexus .m-color-picker::-webkit-color-swatch {
                border: 0.5px solid var(--ios-stroke) !important;
                border-radius: 10px !important;
            }

            /* Footer buttons */
            #mobile-tactical-nexus .sheet-footer,
            #mobile-settings-nexus .sheet-footer {
                padding: 14px 16px calc(env(safe-area-inset-bottom, 0px) + 12px) !important;
                background: transparent !important;
                border-top: 0.5px solid var(--ios-stroke) !important;
                gap: 10px !important;
            }
            #mobile-tactical-nexus .m-btn,
            #mobile-settings-nexus .m-btn {
                border-radius: 12px !important;
                font-family: inherit !important;
                font-size: 16px !important;
                font-weight: 600 !important;
                letter-spacing: -0.2px !important;
                padding: 14px !important;
                border: none !important;
                box-shadow: var(--ios-inner-hi) !important;
                -webkit-tap-highlight-color: transparent !important;
                transition: transform 0.15s ease, background-color 0.15s ease !important;
            }
            #mobile-tactical-nexus .m-primary,
            #mobile-settings-nexus .m-primary {
                background: var(--ios-accent) !important;
                color: #fff !important;
            }
            #mobile-tactical-nexus .m-primary:active,
            #mobile-settings-nexus .m-primary:active {
                transform: scale(0.98) !important;
                background: #0066d1 !important;
            }
            #mobile-tactical-nexus .m-secondary {
                background: var(--ios-fill) !important;
                color: var(--ios-text) !important;
            }
            #mobile-tactical-nexus .m-secondary:active {
                transform: scale(0.98) !important;
                background: var(--ios-fill-strong) !important;
            }

            /* ============================================================
               FLIGHT INFO WINDOW — iOS reskin
               Re-skins the HUD island and legacy sheet that wrap the
               aircraft/airport info content, without touching flight.js
               or sector-ops-mobile-ui.js.
               ============================================================ */

            /* Override the HUD CSS tokens defined at :root so every
               consumer (.mobile-island-bottom, .mobile-glass-pill, the
               route-summary handles, etc.) inherits the iOS palette. */
            :root {
                /* Match the native iOS Material.regular opacity (~80%) so
                   the island reads as a solid surface, not see-through. */
                --hud-bg: rgba(28, 28, 32, 0.82) !important;
                --hud-blur: 30px !important;
                --hud-border: rgba(255, 255, 255, 0.12) !important;
                --hud-accent: #0a84ff !important;
                --hud-glow: none !important;
                --hud-text: #ffffff !important;
            }

            /* The bottom island itself — vibrancy + inner highlight */
            .mobile-island-bottom {
                background: var(--hud-bg) !important;
                -webkit-backdrop-filter: saturate(200%) blur(40px) !important;
                backdrop-filter: saturate(200%) blur(40px) !important;
                border: 0.5px solid var(--hud-border) !important;
                border-radius: 18px !important;
                box-shadow:
                    inset 0 0.5px 0 rgba(255, 255, 255, 0.18),
                    0 12px 36px rgba(0, 0, 0, 0.55) !important;
                color: #fff !important;
            }

            /* Drag handle pills — taller, brighter, iOS-spec */
            .route-summary-wrapper-mobile::before,
            .legacy-sheet-handle::before {
                width: 36px !important;
                height: 5px !important;
                background: rgba(255, 255, 255, 0.4) !important;
                border-radius: 3px !important;
                opacity: 1 !important;
                top: 8px !important;
            }

            /* Top-left server glass pill (when present) */
            .mobile-glass-pill {
                background: var(--hud-bg) !important;
                -webkit-backdrop-filter: saturate(200%) blur(40px) !important;
                backdrop-filter: saturate(200%) blur(40px) !important;
                border: 0.5px solid var(--hud-border) !important;
                box-shadow:
                    inset 0 0.5px 0 rgba(255, 255, 255, 0.18),
                    0 6px 16px rgba(0, 0, 0, 0.35) !important;
                color: #fff !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
            }

            /* Info-window chrome (when shown as the legacy mobile sheet) */
            #aircraft-info-window.mobile-legacy-sheet,
            #airport-info-window.mobile-legacy-sheet {
                background: var(--hud-bg) !important;
                -webkit-backdrop-filter: saturate(200%) blur(40px) !important;
                backdrop-filter: saturate(200%) blur(40px) !important;
                border: none !important;
                border-top: 0.5px solid var(--hud-border) !important;
                box-shadow:
                    inset 0 0.5px 0 rgba(255, 255, 255, 0.18),
                    0 -10px 40px rgba(0, 0, 0, 0.55) !important;
                color: #fff !important;
            }

            /* Header inside the info window */
            .info-window .info-window-header,
            .mobile-island-bottom .info-window-header {
                background: transparent !important;
                border-bottom: 0.5px solid var(--hud-border) !important;
                padding: 14px 16px !important;
            }
            .info-window .info-window-header h3,
            .mobile-island-bottom .info-window-header h3 {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                color: #fff !important;
                font-size: 17px !important;
                font-weight: 600 !important;
                letter-spacing: -0.2px !important;
            }
            .info-window .info-window-actions button,
            .mobile-island-bottom .info-window-actions button {
                background: rgba(120, 120, 128, 0.28) !important;
                border: none !important;
                color: rgba(235, 235, 245, 0.85) !important;
                width: 32px !important;
                height: 32px !important;
                border-radius: 50% !important;
                box-shadow: inset 0 0.5px 0 rgba(255, 255, 255, 0.18) !important;
                transition: transform 0.12s ease, background-color 0.15s ease !important;
            }
            .info-window .info-window-actions button:active,
            .mobile-island-bottom .info-window-actions button:active {
                transform: scale(0.92) !important;
                background: rgba(120, 120, 128, 0.4) !important;
                color: #fff !important;
            }

            /* ============ AC INFO TAB BAR — iOS segmented control ============
               Structure (rendered by flight.js with hardcoded inline styles):
                 .ac-info-window-tabs
                   .modern-view-switcher
                     .ac-info-tab-btn (Flight Display)
                     .ac-info-tab-btn.pilot-tab-btn (Pilot Report)
                     .switcher-highlight (sliding indicator)
                   #ac-dock-toggle-btn
               We restyle every layer to read as a real iOS segmented control. */

            /* Outer tab container — kill the inline dark fill, give it
               sensible padding and no bottom underline. */
            .info-window .ac-info-window-tabs,
            .mobile-island-bottom .ac-info-window-tabs {
                background: transparent !important;
                border-bottom: 0.5px solid var(--hud-border) !important;
                padding: 10px 12px !important;
                height: auto !important;
                gap: 10px !important;
            }

            /* Segmented-control track */
            .info-window .modern-view-switcher,
            .mobile-island-bottom .modern-view-switcher {
                background: rgba(118, 118, 128, 0.24) !important;
                border: 0.5px solid var(--ios-stroke, rgba(255,255,255,0.10)) !important;
                border-radius: 9px !important;
                padding: 2px !important;
                height: 32px !important;
                box-shadow: inset 0 0.5px 0 rgba(255,255,255,0.10) !important;
            }

            /* Sliding indicator behind the active segment */
            .info-window .switcher-highlight,
            .mobile-island-bottom .switcher-highlight {
                top: 2px !important;
                left: 2px !important;
                width: calc(50% - 2px) !important;
                height: calc(100% - 4px) !important;
                background: rgba(255, 255, 255, 0.22) !important;
                border: 0.5px solid rgba(255, 255, 255, 0.18) !important;
                border-radius: 7px !important;
                box-shadow:
                    0 1px 2px rgba(0, 0, 0, 0.18),
                    inset 0 0.5px 0 rgba(255, 255, 255, 0.20) !important;
                transition: transform 0.28s cubic-bezier(0.16, 1, 0.3, 1) !important;
            }

            /* Segment buttons — sentence case, SF Pro, no letterspacing */
            .info-window .ac-info-tab-btn,
            .mobile-island-bottom .ac-info-tab-btn {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 13px !important;
                font-weight: 600 !important;
                font-style: normal !important;
                letter-spacing: -0.08px !important;
                text-transform: none !important;
                color: rgba(235, 235, 245, 0.66) !important;
                background: transparent !important;
                border: none !important;
                border-bottom: none !important;
                border-radius: 7px !important;
                padding: 0 10px !important;
                gap: 7px !important;
                text-shadow: none !important;
                transition: color 0.22s ease !important;
            }
            .info-window .ac-info-tab-btn i,
            .mobile-island-bottom .ac-info-tab-btn i {
                color: inherit !important;
                font-size: 12px !important;
            }
            .info-window .ac-info-tab-btn.active,
            .mobile-island-bottom .ac-info-tab-btn.active {
                color: #ffffff !important;
                border-bottom-color: transparent !important;
                text-shadow: none !important;
            }
            .info-window .ac-info-tab-btn.active i,
            .mobile-island-bottom .ac-info-tab-btn.active i {
                color: #ffffff !important;
            }
            /* Pilot tab: keep amber accent in the icon for recognizability,
               but match the segmented look — selected = white text on the
               slider, idle = dim white. */
            .info-window .ac-info-tab-btn.pilot-tab-btn,
            .mobile-island-bottom .ac-info-tab-btn.pilot-tab-btn {
                color: rgba(235, 235, 245, 0.66) !important;
                font-weight: 600 !important;
                letter-spacing: -0.08px !important;
            }
            .info-window .ac-info-tab-btn.pilot-tab-btn i,
            .mobile-island-bottom .ac-info-tab-btn.pilot-tab-btn i {
                color: #ffd60a !important;
            }
            .info-window .ac-info-tab-btn.pilot-tab-btn.active,
            .mobile-island-bottom .ac-info-tab-btn.pilot-tab-btn.active {
                color: #ffffff !important;
                border-bottom-color: transparent !important;
            }
            .info-window .ac-info-tab-btn.pilot-tab-btn.active i,
            .mobile-island-bottom .ac-info-tab-btn.pilot-tab-btn.active i {
                color: #ffd60a !important;
            }

            /* Hide the desktop "dock" toggle button on mobile — there's no
               docking on a phone, and it crowds the segmented control. */
            .info-window #ac-dock-toggle-btn,
            .mobile-island-bottom #ac-dock-toggle-btn,
            .info-window .ac-dock-toggle-btn,
            .mobile-island-bottom .ac-dock-toggle-btn {
                display: none !important;
            }

            /* Drawer scrollbars — iOS-thin and white */
            .drawer-content::-webkit-scrollbar { width: 3px !important; }
            .drawer-content::-webkit-scrollbar-thumb {
                background-color: rgba(255, 255, 255, 0.3) !important;
                border-radius: 3px !important;
            }

            /* Aircraft overview hero — keep image, brighten the type */
            .info-window .aircraft-overview-panel,
            .mobile-island-bottom .aircraft-overview-panel {
                color: #fff !important;
            }
            .info-window .overview-col-left h3,
            .mobile-island-bottom .overview-col-left h3 {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Inter', sans-serif !important;
                font-size: 22px !important;
                font-weight: 700 !important;
                letter-spacing: -0.4px !important;
                text-shadow: 0 4px 12px rgba(0, 0, 0, 0.85) !important;
            }
            .info-window .overview-col-left p,
            .mobile-island-bottom .overview-col-left p {
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                color: rgba(255, 255, 255, 0.88) !important;
                font-size: 15px !important;
                font-weight: 500 !important;
            }

            /* Inner data cards (location panel, live data, pilot stats) —
               trade the harsh dark fill for the iOS grouped-card look. */
            #mobile-island-peek #location-data-panel,
            #mobile-island-peek .flight-data-bar,
            #mobile-island-expanded .live-data-panel,
            #mobile-island-expanded .pilot-stats-toggle-btn {
                background: rgba(255, 255, 255, 0.06) !important;
                border: none !important;
                border-radius: 14px !important;
                box-shadow: inset 0 0.5px 0 rgba(255, 255, 255, 0.12) !important;
                color: #fff !important;
            }
            #mobile-island-expanded .pilot-stats-toggle-btn {
                color: var(--hud-accent) !important;
            }

            /* Flight-data text inside those cards — brighter labels/values */
            .info-window .data-label,
            .mobile-island-bottom .data-label {
                color: rgba(255, 255, 255, 0.62) !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 10.5px !important;
                font-weight: 500 !important;
                letter-spacing: 0.4px !important;
                text-transform: uppercase !important;
            }
            .info-window .data-value,
            .mobile-island-bottom .data-value {
                color: #fff !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-weight: 600 !important;
                letter-spacing: -0.2px !important;
            }

            /* Simple-mode iframe wrapper inherits the glass + iOS handle.
               Lift the handle hit area a touch on iOS so it's not jammed
               against the device status bar. */
            .mobile-legacy-sheet.simple-mode {
                background: var(--hud-bg) !important;
                -webkit-backdrop-filter: saturate(200%) blur(40px) !important;
                backdrop-filter: saturate(200%) blur(40px) !important;
            }
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
