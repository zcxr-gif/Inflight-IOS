/*
 * =====================================================================
 * ⚠️  LEGACY / PARTIALLY DEPRECATED — sector-ops-mobile-ui.js
 * =====================================================================
 * This is the OLD mobile UI handler ("Sector Ops"). It is NOT the
 * current landing / map chrome.
 *
 * The CURRENT mobile UI is driven by:
 *   - landingUI.js                  (LandingUI — tactical header + search)
 *   - MobileLandingChromeUI.js      (iOS bottom tab bar: Inflight / Weather
 *                                     / Filters / Settings — the live HUD)
 *   - MobileSettingsUI.js           (the current mobile settings panel,
 *                                     opened from the Settings tab)
 *
 * Only a few helpers in THIS file are still live and called externally:
 *   isMobile(), isTablet(), openWindow(), closeActiveWindow(),
 *   openServerSheet() — used to present the aircraft/airport sheets.
 *
 * The floating HUD action stack built by injectMobileHudControls()
 * below (Server pill / Search / Weather / Filters buttons) is LEGACY and
 * is no longer injected — those controls now live in
 * MobileLandingChromeUI.js. Do NOT add new map controls (e.g. the 3D
 * Traffic toggle) here; add them to the current chrome / MobileSettingsUI
 * instead, or they will never render.
 * =====================================================================
 */
const MobileUIHandler = {
    // --- CONFIGURATION ---
    CONFIG: {
        breakpoint: 992, // The max-width in pixels to trigger mobile view
        defaultMode: 'legacy', // Default is 'legacy' sheet
        legacyPeekHeight: 320, // Height of the "peek" state for legacy sheet
        simplePeekHeight: 240, // Shorter peek for the simple flight window (hugs its compact bar)
    },

    // --- STATE ---
    isMobile: () => window.innerWidth <= MobileUIHandler.CONFIG.breakpoint,
    // True for iPad / tablet-class devices. iPadOS 13+ masquerades as a Mac,
    // so fall back to the touch-points heuristic; Android tablets drop the
    // "Mobile" token from their UA string.
    isTablet: () => {
        const ua = navigator.userAgent || '';
        if (/iPad/.test(ua)) return true;
        if (/Macintosh/.test(ua) && (navigator.maxTouchPoints || 0) > 1) return true;
        if (/Android/.test(ua) && !/Mobile/.test(ua)) return true;
        return false;
    },
    // The compact "peek" bar is a phone-only affordance; iPads jump straight to
    // the expanded "second state" of the simple flight window.
    isSimpleSheetExpandedOnly() {
        return this.isSimpleSheet() && this.isTablet();
    },
    activeWindow: null, // The *original* hidden info window
    activeMode: 'legacy', // Defaults to legacy
    topWindowEl: null, // HUD Mode: Top window
    overlayEl: null, // Shared: Overlay
    serverSheetEl: null, // Server Switcher Sheet
    closeTimer: null,
    
    // [HUD] Island elements
    miniIslandEl: null,
    peekIslandEl: null,
    expandedIslandEl: null,
    
    contentObserver: null,
    drawerState: 0, // HUD Mode: 0 = Mini, 1 = Peek, 2 = Expanded
    
    // [LEGACY] Sheet state
    legacySheetState: {
        isDragging: false,
        touchStartY: 0,
        currentSheetY: 0,
        startSheetY: 0,
        currentState: 'peek', // 'peek' or 'expanded'
    },
    
    swipeState: { // HUD Mode
        touchStartY: 0,
        isDragging: false,
    },

    // [NEW] Bound event handlers for document listeners
    boundHudTouchEnd: null,
    boundLegacyTouchMove: null,
    boundLegacyTouchEnd: null,

    /**
     * [MODIFIED] Restores the main map UI controls
     */
    restoreMapControls() {
        const mapContainer = document.getElementById('sector-ops-map-fullscreen');
        if (mapContainer) {
            mapContainer.classList.remove('mobile-ui-active'); // For general mobile state
            mapContainer.classList.remove('mobile-window-open'); // [FIX] Specific flag for open windows
        }
    },

    /**
     * Initializes the handler by injecting the new HUD styles.
     */
    init() {
        this.injectMobileStyles();

        // [NEW] Pre-bind document-level handlers
        this.boundHudTouchEnd = this.handleHudTouchEnd.bind(this);
        this.boundLegacyTouchMove = this.handleLegacyTouchMove.bind(this);
        this.boundLegacyTouchEnd = this.handleLegacyTouchEnd.bind(this);
        

window.addEventListener('resize', () => {
    if (this.isMobile()) {
        // Keep this empty or only handle logic NOT related to the HUD buttons
    } else {
        if (this.activeWindow) {
            this.closeActiveWindow(true); 
        }
        this.restoreMapControls();
    }
});
        
        // Listen for clicks outside search to close it (if active)
        document.addEventListener('click', (e) => {
            if (this.isMobile()) {
                const searchContainer = document.getElementById('sector-ops-search-container');
                const searchBtn = document.getElementById('mobile-btn-search');
                const mapContainer = document.getElementById('sector-ops-map-fullscreen');
                
                // If search is open
                if (mapContainer && mapContainer.classList.contains('mobile-search-open')) {
                    // If click is NOT inside search container AND NOT on the search button
                    if (searchContainer && !searchContainer.contains(e.target) && (!searchBtn || !searchBtn.contains(e.target))) {
                        this.toggleMobileSearch(false);
                    }
                }
            }
        });

        console.log("Mobile UI Handler (HUD Rehaul v9.8 - Airport Fixes) Initialized.");
    },

    /**
 * Completely disables and removes all Mobile HUD controls.
 * This prevents the Server Pill, Search, Weather, and Filter buttons from appearing.
 */
disableHudControls() {
    // 1. Remove the container from DOM if it exists
    const hud = document.getElementById('mobile-hud-controls');
    if (hud) hud.remove();

    // 2. Clear out the injection function so it can't be called again
    this.injectMobileHudControls = () => {
        console.log("Mobile UI: HUD Controls are disabled and will not be injected.");
    };

    // 3. Ensure map container classes are cleaned up
    const mapContainer = document.getElementById('sector-ops-map-fullscreen');
    if (mapContainer) {
        mapContainer.classList.remove('mobile-search-open');
    }

    // 4. Re-enable Desktop Server Pill (optional: only if you want it back on mobile)
    const desktopServerPill = document.getElementById('server-selector-container');
    if (desktopServerPill) desktopServerPill.style.display = '';
},

    /**
     * [LEGACY — NO LONGER CALLED] Injects the floating Server Pill (Top-Left)
     * and Action Stack (Top-Right: Search / Weather / Filters).
     *
     * Superseded by MobileLandingChromeUI.js, which renders the current iOS
     * bottom tab bar. This method is retained only for reference and is not
     * wired into the boot path. Add new map controls to the current chrome /
     * MobileSettingsUI.js, not here.
     */
    injectMobileHudControls() {
        const mapContainer = document.getElementById('sector-ops-map-fullscreen');
        if (!mapContainer || document.getElementById('mobile-hud-controls')) return;

        // Hide Desktop Controls specifically
        const desktopServerPill = document.getElementById('server-selector-container');
        if (desktopServerPill) desktopServerPill.style.display = 'none';

        // --- 1. Create Container ---
        const controlsContainer = document.createElement('div');
        controlsContainer.id = 'mobile-hud-controls';
        
        // --- 2. Top Left: Server Status Pill ---
        // Reads current server from local storage or defaults
        const currentServer = localStorage.getItem('preferredServer') || 'Expert Server';
        const shortServerName = currentServer.split(' ')[0]; // "Expert"

        const serverPillHTML = `
            <div id="mobile-server-pill" class="mobile-glass-pill">
                <div class="status-dot"></div>
                <span id="mobile-server-name">${shortServerName}</span>
                <i class="fa-solid fa-chevron-down" style="font-size: 0.7rem; opacity: 0.7;"></i>
            </div>
        `;

        // --- 3. Top Right: Action Stack (Search, Weather, Filters) ---
        // [UPDATED] Added Search Button here
        const actionStackHTML = `
            <div class="mobile-action-stack">
                <button id="mobile-btn-search" class="mobile-glass-sq-btn">
                    <i class="fa-solid fa-magnifying-glass"></i>
                </button>
                <button id="mobile-btn-weather" class="mobile-glass-sq-btn">
                    <i class="fa-solid fa-cloud-sun"></i>
                </button>
                <button id="mobile-btn-filters" class="mobile-glass-sq-btn">
                    <i class="fa-solid fa-layer-group"></i>
                </button>
            </div>
        `;

        controlsContainer.innerHTML = serverPillHTML + actionStackHTML;
        mapContainer.appendChild(controlsContainer);

        // --- 4. Wire Events ---
        
        // Server Switcher
        document.getElementById('mobile-server-pill').addEventListener('click', () => {
            this.openServerSheet();
        });

        // [NEW] Mobile Search Toggle
        document.getElementById('mobile-btn-search').addEventListener('click', (e) => {
            e.stopPropagation(); // Prevent document click from closing it immediately
            this.toggleMobileSearch(true);
        });

        // Weather
        document.getElementById('mobile-btn-weather').addEventListener('click', () => {
            const btn = document.getElementById('open-weather-settings-btn'); // Trigger desktop logic
            if (btn) btn.click();
        });

        // Filters
        document.getElementById('mobile-btn-filters').addEventListener('click', () => {
            const btn = document.getElementById('open-filter-settings-btn'); // Trigger desktop logic
            if (btn) btn.click();
        });
    },

    /**
     * [NEW] Focuses the canonical blade-search input. The search overlay
     * itself lives in the tactical header (landingUI.js) — this method
     * just acts as a programmatic shortcut from the HUD button.
     */
    toggleMobileSearch(show) {
        const bladeInput = document.getElementById('blade-search-input');
        if (show) {
            if (bladeInput) {
                bladeInput.focus();
                // iOS: scroll the input into view above the keyboard.
                try { bladeInput.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (_) {}
            }
        } else {
            if (bladeInput) {
                bladeInput.value = '';
                bladeInput.blur();
            }
            if (window.LandingUI && typeof window.LandingUI._closeBladeSearch === 'function') {
                window.LandingUI._closeBladeSearch();
            }
        }
    },

    /**
     * [UPDATED] Opens a bottom sheet to select the server
     * Now fetches and displays live user counts instead of static text.
     */
    openServerSheet() {
        const mapContainer = document.getElementById('sector-ops-map-fullscreen');
        
        // Remove existing if any
        const existing = document.getElementById('mobile-server-sheet');
        if (existing) existing.remove();

        const sheet = document.createElement('div');
        sheet.id = 'mobile-server-sheet';
        sheet.className = 'mobile-server-sheet';
        
        const current = localStorage.getItem('preferredServer') || 'Expert Server';

        // Helper to generate the loading state HTML
        const loadingState = `<span class="s-desc" style="color: var(--hud-accent);"><i class="fa-solid fa-circle-notch fa-spin"></i> Loading...</span>`;

        sheet.innerHTML = `
            <div class="sheet-header">
                <span>Select Server</span>
                <button id="close-server-sheet"><i class="fa-solid fa-xmark"></i></button>
            </div>
            <div class="server-options-list">
                
                <button class="server-opt-btn ${current === 'Expert Server' ? 'active' : ''}" data-server="Expert Server">
                    <div class="server-icon expert"><i class="fa-solid fa-trophy"></i></div>
                    <div class="server-info">
                        <span class="s-name">Expert Server</span>
                        <span class="s-desc" id="cnt-expert">${loadingState}</span>
                    </div>
                    ${current === 'Expert Server' ? '<i class="fa-solid fa-check"></i>' : ''}
                </button>

                <button class="server-opt-btn ${current === 'Training Server' ? 'active' : ''}" data-server="Training Server">
                    <div class="server-icon training"><i class="fa-solid fa-graduation-cap"></i></div>
                    <div class="server-info">
                        <span class="s-name">Training Server</span>
                        <span class="s-desc" id="cnt-training">${loadingState}</span>
                    </div>
                    ${current === 'Training Server' ? '<i class="fa-solid fa-check"></i>' : ''}
                </button>

                <button class="server-opt-btn ${current === 'Casual Server' ? 'active' : ''}" data-server="Casual Server">
                    <div class="server-icon casual"><i class="fa-solid fa-plane-arrival"></i></div>
                    <div class="server-info">
                        <span class="s-name">Casual Server</span>
                        <span class="s-desc" id="cnt-casual">${loadingState}</span>
                    </div>
                    ${current === 'Casual Server' ? '<i class="fa-solid fa-check"></i>' : ''}
                </button>
            </div>
        `;

        // Overlay
        const overlay = document.createElement('div');
        overlay.id = 'server-sheet-overlay';
        overlay.addEventListener('click', () => {
            sheet.classList.remove('visible');
            overlay.classList.remove('visible');
            setTimeout(() => { sheet.remove(); overlay.remove(); }, 300);
        });

        mapContainer.appendChild(overlay);
        mapContainer.appendChild(sheet);

        // Animate In
        requestAnimationFrame(() => {
            overlay.classList.add('visible');
            sheet.classList.add('visible');
        });

        // Close Event
        sheet.querySelector('#close-server-sheet').addEventListener('click', () => overlay.click());

        // Selection Event
        sheet.querySelectorAll('.server-opt-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const newServer = btn.dataset.server;       // e.g. "Expert Server"
                const shortName = newServer.split(' ')[0];   // e.g. "Expert"

                // Keep any legacy pill text in sync (no-op if absent)
                const pillText = document.getElementById('mobile-server-name');
                if (pillText) pillText.textContent = shortName;

                // Update LandingUI's top-bar label + internal state
                const landingName = document.getElementById('landing-server-name');
                if (landingName) landingName.textContent = `${shortName.toUpperCase()} SERVER`;
                if (window.LandingUI) window.LandingUI._currentServer = shortName;

                // Drive the canonical server switch (mapped + switchServer in flight.js)
                window.dispatchEvent(new CustomEvent('serverChange', { detail: { server: shortName } }));

                overlay.click(); // Close
            });
        });

        // --- NEW: Fetch Live User Counts ---
        fetch('https://site--acars-backend--6dmjph8ltlhv.code.run/if-sessions')
            .then(res => res.json())
            .then(data => {
                if (data && Array.isArray(data.sessions)) {
                    
                    const updateCount = (elementId, serverNamePart) => {
                        const el = document.getElementById(elementId);
                        if (!el) return;

                        // Find session by partial name match
                        const session = data.sessions.find(s => s.name.toLowerCase().includes(serverNamePart));
                        
                        if (session) {
                            el.innerHTML = `<i class="fa-solid fa-users" style="margin-right: 6px;"></i> ${session.userCount.toLocaleString()} Online`;
                            el.style.color = "#94a3b8"; // Reset color
                        } else {
                            el.textContent = "Offline";
                        }
                    };

                    updateCount('cnt-expert', 'expert');
                    updateCount('cnt-training', 'training');
                    updateCount('cnt-casual', 'casual');
                }
            })
            .catch(err => {
                console.warn("Failed to load server counts:", err);
                // Fallback text on error
                ['cnt-expert', 'cnt-training', 'cnt-casual'].forEach(id => {
                    const el = document.getElementById(id);
                    if (el) el.textContent = "Status Unknown";
                });
            });
    },

    /**
     * [MODIFIED] Injects all the CSS for the new HUD-themed floating islands.
     */
    injectMobileStyles() {
        const styleId = 'mobile-sector-ops-styles';
        if (document.getElementById(styleId)) document.getElementById(styleId).remove();

        const css = `
            :root {
                --hud-bg: rgba(15, 20, 35, 0.85);
                --hud-blur: 20px;
                --hud-top-window-height: 50px;
                --hud-border: rgba(255, 255, 255, 0.1);
                --hud-accent: #38bdf8;
                --hud-glow: 0 0 15px rgba(0, 168, 255, 0.5);
                --hud-text: #fff;
                
                --drawer-peek-content-height: 200px;
                --island-bottom-margin: env(safe-area-inset-bottom, 15px);
                --island-side-margin: 10px;

                /* --- [NEW] Legacy Sheet Config --- */
                --legacy-peek-height: ${this.CONFIG.legacyPeekHeight}px;
                /* Give the drag handle clearance below the device status bar / notch
                   even on devices that report no safe-area-inset (most Android),
                   so the handle never ends up jammed under the URL bar when the
                   sheet is fully expanded. */
                --legacy-top-offset: calc(env(safe-area-inset-top, 0px) + 40px);
            }
            
            /* --- [FIX] Target the map container instead of 'view-rosters' --- */
            #sector-ops-map-fullscreen.mobile-ui-active {
                position: relative;
                overflow: hidden;
            }

            /* --- [CRITICAL FIX] Hide Clutter when Mobile Window (or Search) is Open --- */
            /* This effectively clears the "other icons" the user complained about */
            
            /* Update this block in your injectMobileStyles function */
#sector-ops-map-fullscreen.mobile-window-open > *:not(.landing-ui-container):not(.mobile-aircraft-view):not(.mobile-island-bottom) {
    /* Only hide things that aren't the window or your landing UI */
}
                display: none !important;
                opacity: 0 !important;
                pointer-events: none !important;
            }

            /* Also hide controls when SEARCH is open */
            /* Update this block in your injectMobileStyles function */
#sector-ops-map-fullscreen.mobile-window-open > *:not(.la/* Find this in your code and ensure your UI class isn't targeted */
#sector-ops-map-fullscreen.mobile-search-open .your-landing-ui-class {
    display: flex !important; /* Force visibility */
    opacity: 1 !important;
    pointer-events: auto !important;
}nding-ui-container):not(.mobile-aircraft-view):not(.mobile-island-bottom) {
    /* Only hide things that aren't the window or your landing UI */
}
                display: none !important;
            }

            @media (max-width: ${this.CONFIG.breakpoint}px) {
                #server-selector-container { display: none !important; }
                
                /* [FIX] Hide the old desktop toolbar on mobile */
                .dashboard-toolbar { display: none !important; } 

                /* Hide Mapbox controls by default on mobile if you want a clean HUD look */
                .mapboxgl-ctrl-bottom-left, 
                .mapboxgl-ctrl-bottom-right { 
                    /* optional: display: none; */ 
                }

                /* [FIX] Ensure Airport Window logic mirrors Aircraft logic for hiding */
                #aircraft-info-window:not(.mobile-legacy-sheet), 
                #airport-info-window:not(.mobile-legacy-sheet) {
                    display: none !important;
                }
            }

            /* ====================================================================
            --- [START] NEW MOBILE HUD CONTROLS ---
            ==================================================================== */
            
            #mobile-hud-controls {
                position: absolute;
                inset: 0;
                pointer-events: none; /* Let clicks pass through to map */
                z-index: 1020;
                transition: opacity 0.3s ease;
            }

            /* --- 1. Top Left Server Pill --- */
            .mobile-glass-pill {
                position: absolute;
                top: calc(env(safe-area-inset-top, 20px) + 15px);
                left: 15px;
                pointer-events: auto;
                
                background: var(--hud-bg);
                backdrop-filter: blur(var(--hud-blur));
                -webkit-backdrop-filter: blur(var(--hud-blur));
                border: 1px solid var(--hud-border);
                border-radius: 30px;
                
                padding: 8px 14px;
                display: flex;
                align-items: center;
                gap: 8px;
                
                color: var(--hud-text);
                font-family: 'Inter', sans-serif;
                font-weight: 600;
                font-size: 0.85rem;
                box-shadow: 0 4px 15px rgba(0,0,0,0.3);
                transition: transform 0.2s ease, opacity 0.2s;
            }
            .mobile-glass-pill:active { transform: scale(0.95); }

            .status-dot {
                width: 8px; height: 8px;
                background: #22c55e; /* Green */
                border-radius: 50%;
                box-shadow: 0 0 8px rgba(34, 197, 94, 0.6);
            }

            /* --- 2. Top Right Action Stack --- */
            .mobile-action-stack {
                position: absolute;
                top: calc(env(safe-area-inset-top, 20px) + 15px);
                right: 15px;
                display: flex;
                flex-direction: column;
                gap: 10px;
                pointer-events: auto;
                transition: opacity 0.2s;
            }

            .mobile-glass-sq-btn {
                width: 44px; height: 44px;
                background: var(--hud-bg);
                backdrop-filter: blur(var(--hud-blur));
                -webkit-backdrop-filter: blur(var(--hud-blur));
                border: 1px solid var(--hud-border);
                border-radius: 12px;
                
                color: #94a3b8; /* Muted icon color */
                font-size: 1.1rem;
                display: flex;
                align-items: center;
                justify-content: center;
                
                box-shadow: 0 4px 15px rgba(0,0,0,0.3);
                transition: all 0.2s ease;
            }
            .mobile-glass-sq-btn:active {
                transform: scale(0.95);
                background: rgba(56, 189, 248, 0.2);
                color: #fff;
                border-color: rgba(56, 189, 248, 0.5);
            }

            /* --- 3. Server Switcher Sheet --- */
            #server-sheet-overlay {
                position: absolute; inset: 0;
                background: rgba(0,0,0,0.6);
                backdrop-filter: blur(4px);
                z-index: 2000;
                opacity: 0; transition: opacity 0.3s ease;
                pointer-events: none;
            }
            #server-sheet-overlay.visible { opacity: 1; pointer-events: auto; }

            .mobile-server-sheet {
                position: absolute;
                bottom: 0; left: 0; right: 0;
                background: #18181b; /* Zinc 900 */
                border-top: 1px solid #333;
                border-radius: 20px 20px 0 0;
                padding: 20px;
                z-index: 2001;
                transform: translateY(100%);
                transition: transform 0.3s cubic-bezier(0.16, 1, 0.3, 1);
                padding-bottom: calc(20px + env(safe-area-inset-bottom, 20px));
            }
            .mobile-server-sheet.visible { transform: translateY(0); }

            .sheet-header {
                display: flex; justify-content: space-between; align-items: center;
                margin-bottom: 20px;
                color: #fff; font-weight: 700; font-size: 1.1rem;
            }
            #close-server-sheet {
                background: rgba(255,255,255,0.1); border: none; color: #ccc;
                width: 30px; height: 30px; border-radius: 50%;
                display: grid; place-items: center;
            }

            .server-options-list { display: flex; flex-direction: column; gap: 10px; }
            
            .server-opt-btn {
                background: rgba(255,255,255,0.03);
                border: 1px solid rgba(255,255,255,0.05);
                border-radius: 12px;
                padding: 15px;
                display: flex; align-items: center; gap: 15px;
                color: #fff; text-align: left;
                transition: all 0.2s;
            }
            .server-opt-btn.active {
                background: rgba(56, 189, 248, 0.1);
                border-color: rgba(56, 189, 248, 0.3);
            }
            
            .server-icon {
                width: 40px; height: 40px; border-radius: 10px;
                display: grid; place-items: center; font-size: 1.2rem;
            }
            .server-icon.expert { background: rgba(234, 179, 8, 0.1); color: #eab308; }
            .server-icon.training { background: rgba(168, 85, 247, 0.1); color: #a855f7; }
            .server-icon.casual { background: rgba(34, 197, 94, 0.1); color: #22c55e; }

            .server-info { flex-grow: 1; display: flex; flex-direction: column; }
            .s-name { font-weight: 600; font-size: 1rem; }
            .s-desc { font-size: 0.8rem; color: #94a3b8; }

            /* The canonical mobile search bar lives in the tactical header
               (landingUI.js .search-blade). The HUD search button just
               focuses it programmatically — no separate overlay needed. */

            /* --- [MODIFIED] Overlay (now shared) --- */
            #mobile-window-overlay {
                position: absolute;
                inset: 0;
                background: rgba(0, 0, 0, 0.7);
                backdrop-filter: blur(5px);
                z-index: 1040;
                opacity: 0;
                transition: opacity 0.4s ease;
                pointer-events: none;
            }
            #mobile-window-overlay.visible { opacity: 1; pointer-events: auto; }

            
            /* ====================================================================
            --- [START] CSS for "HUD" (Island) Mode ---
            ==================================================================== */

            /* --- Base Island Class (Used by Top Window) --- */
            .mobile-aircraft-view {
                position: absolute;
                background: var(--hud-bg);
                backdrop-filter: blur(var(--hud-blur));
                -webkit-backdrop-filter: blur(var(--hud-blur));
                border: 1px solid var(--hud-border);
                z-index: 1045;
                transition: transform 0.45s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.4s ease;
                will-change: transform, opacity;
                box-shadow: 0 10px 40px rgba(0,0,0,0.5), var(--hud-glow);
                color: #e8eaf6;
                border-radius: 16px;
                overflow: hidden;
            }

            /* --- Top Floating Window --- */
            #mobile-aircraft-top-window {
                top: env(safe-area-inset-top, 15px);
                left: var(--island-side-margin);
                right: var(--island-side-margin);
                max-height: 250px;
                transform: translateY(-250%);
                opacity: 0;
            }
            #mobile-aircraft-top-window.visible {
                transform: translateY(0);
                opacity: 1;
            }

            /* --- [NEW] Base Class for Bottom Islands --- */
            .mobile-island-bottom {
                position: absolute;
                left: var(--island-side-margin);
                right: var(--island-side-margin);
                
                /* Visuals */
                background: var(--hud-bg);
                backdrop-filter: blur(var(--hud-blur));
                -webkit-backdrop-filter: blur(var(--hud-blur));
                border: 1px solid var(--hud-border);
                box-shadow: 0 10px 40px rgba(0,0,0,0.5), var(--hud-glow);
                color: #e8eaf6;
                border-radius: 16px;
                
                display: flex;
                flex-direction: column;
                
                /* Animation */
                transition: transform 0.45s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.4s ease;
                will-change: transform, opacity;
                
                /* Default Off-Screen State */
                transform: translateY(120%);
                opacity: 0;
                z-index: 1045;
                
                overflow: hidden;
            }
            
            /* Active State for ALL Bottom Islands */
            .mobile-island-bottom.island-active {
                transform: translateY(0);
                opacity: 1;
            }

            /* --- State 0: Mini Island --- */
            #mobile-island-mini {
                bottom: var(--island-bottom-margin);
                height: auto; 
                display: flex;
                flex-direction: column; 
            }
            
            /* --- State 1: Peek Island --- */
            #mobile-island-peek {
                bottom: var(--island-bottom-margin);
                height: auto; 
            }
            
            /* --- State 2: Expanded Island --- */
            #mobile-island-expanded {
                top: 280px; /* Sits below the top window */
                bottom: var(--island-bottom-margin);
                height: auto; /* Fills the space */
            }

            /* --- Route Summary Bar Styling (Mobile HUD) --- */
            .route-summary-wrapper-mobile {
                flex-shrink: 0;
                overflow: hidden;
                border-top-left-radius: 16px;
                border-top-right-radius: 16px;
                
                /* Handle properties */
                cursor: grab;
                touch-action: none;
                user-select: none;
                position: relative;
                
                background: var(--hud-bg);
            }
            
            /* Add the pill visual */
            .route-summary-wrapper-mobile::before {
                content: '';
                position: absolute;
                left: 50%;
                transform: translateX(-50%);
                top: 8px; 
                width: 40px; 
                height: 4px; 
                background: var(--hud-border);
                border-radius: 2px; 
                opacity: 0.5;
            }
            
            #mobile-island-mini .route-summary-wrapper-mobile::before {
                opacity: 0.3;
            }

            /* Override desktop styles for the route bar on mobile */
            .route-summary-wrapper-mobile .route-summary-overlay {
                position: relative; 
                margin-bottom: 0;
                background: var(--hud-bg);
                border-radius: 0;
                padding: 12px 15px 12px 15px; 
                grid-template-columns: auto 1fr auto;
                gap: 12px;
            }
            .route-summary-wrapper-mobile .route-summary-airport .icao {
                font-size: 1.0rem;
            }
            .route-summary-wrapper-mobile .route-summary-airport .time {
                font-size: 0.75rem;
                margin-top: 2px;
            }
            .route-summary-wrapper-mobile .route-summary-airport .country-flag {
                width: 16px;
            }
            .route-summary-wrapper-mobile .flight-phase-indicator {
                padding: 3px 10px;
                font-size: 0.7rem;
            }
            #mobile-island-mini .route-summary-wrapper-mobile .progress-bar-fill,
            #mobile-island-peek .route-summary-wrapper-mobile .progress-bar-fill {
                display: none;
            }
            #mobile-island-mini .route-summary-wrapper-mobile .route-progress-bar-container,
            #mobile-island-peek .route-summary-wrapper-mobile .route-progress-bar-container {
                 background: rgba(10, 12, 26, 0.4);
            }

            /* --- Drawer Content (Used in Peek & Expanded) --- */
            .drawer-content {
                overflow-y: auto;
                flex-grow: 1;
                padding-bottom: env(safe-area-inset-bottom, 0);
                height: var(--drawer-peek-content-height);
            }
            #mobile-island-peek .drawer-content {
                overflow: hidden;
            }
            #mobile-island-expanded .drawer-content {
                height: auto;
            }
            
            .drawer-content::-webkit-scrollbar { width: 6px; }
            .drawer-content::-webkit-scrollbar-track { background: transparent; }
            .drawer-content::-webkit-scrollbar-thumb { background-color: var(--hud-accent); border-radius: 10px; }

            /* --- State 1: "Peek" Stacked Data Layout (Replaces PFD) --- */
            #mobile-island-peek .drawer-content {
                padding: 10px;
                box-sizing: border-box;
                height: var(--drawer-peek-content-height); /* 200px */
                display: flex;
                flex-direction: column;
            }
            
            #mobile-island-peek .unified-display-main-content {
                padding: 0 !important;
                gap: 10px;
                height: 100%;
                overflow: hidden;
            }

            #mobile-island-peek .pfd-main-panel { display: none !important; }
            #mobile-island-peek .ac-profile-card-new { display: none !important; }
            #mobile-island-peek .vsd-disclaimer { display: none !important; }
            #mobile-island-peek #vsd-panel { display: none !important; }

            #mobile-island-peek #location-data-panel {
                padding: 10px;
                flex-shrink: 0;
                border-top-width: 0;
                background: rgba(10, 12, 26, 0.5) !important;
            }
            #mobile-island-peek #location-data-panel .data-value {
                font-size: 1.0rem;
                margin-top: 4px;
            }
            #mobile-island-peek .flight-data-bar {
                padding: 10px;
                gap: 8px;
                grid-template-columns: repeat(auto-fit, minmax(70px, 1fr));
                flex-grow: 1;
                overflow: hidden;
                border-top-width: 0;
            }
            #mobile-island-peek .flight-data-bar .data-label { font-size: 0.6rem; }
            #mobile-island-peek .flight-data-bar .data-value { font-size: 1.1rem; }
            #mobile-island-peek .flight-data-bar .data-value .unit { font-size: 0.7rem; }


            /* --- State 2: "Expanded" Stacked Layout --- */
            #mobile-island-expanded .unified-display-main-content {
                display: flex !important;
                flex-direction: column;
                gap: 16px;
                height: auto;
                overflow: hidden;
                padding: 16px;
            }
            #mobile-island-expanded .pfd-main-panel {
                display: flex !important;
                margin: 0 auto !important;
                max-width: 400px !important;
            }
             #mobile-island-expanded .ac-profile-card-new {
                display: flex !important;
            }
            #mobile-island-expanded .vsd-disclaimer {
                display: block !important;
            }
            #mobile-island-expanded .live-data-panel {
                justify-content: space-around !important;
                background: rgba(10, 12, 26, 0.5) !important;
                border-radius: 12px !important;
                padding: 16px !important;
            }
            #mobile-island-expanded .live-data-item .data-label { font-size: 0.7rem; }
            #mobile-island-expanded .live-data-item .data-value { font-size: 1.5rem; }
            #mobile-island-expanded .live-data-item .data-value .unit { font-size: 0.8rem; }
            #mobile-island-expanded .live-data-item .data-value-ete { font-size: 1.7rem; }
            
            #mobile-island-expanded .pilot-stats-toggle-btn {
                display: flex;
                background: rgba(10, 12, 26, 0.5);
                border-radius: 12px;
                padding: 16px;
                box-sizing: border-box;
                justify-content: center;
                align-items: center;
                text-decoration: none;
                color: var(--hud-accent);
                font-weight: 600;
                font-size: 1rem;
                margin-top: 16px;
            }

            /* ====================================================================
            --- [END] CSS for "HUD" (Island) Mode ---
            ==================================================================== */


            /* ====================================================================
            --- [START] NEW CSS for "Legacy Sheet" Mode ---
            ==================================================================== */

            /* This class is applied to the original info-window.
               The motion rules are scoped as .info-window.mobile-legacy-sheet
               so they always out-rank the desktop .info-window /
               .info-window.visible entrance rules in flight.js regardless of
               which stylesheet gets injected later. Without that the cascade
               was order-dependent: when the desktop rules won, the sheet
               inherited their fade + top-right translate/scale entrance and
               visibly dragged in from the top-right corner before settling
               at the bottom. The sheet's motion is one axis only — it slides
               up from below the bottom edge, and back down to close.
               transform/transition deliberately carry NO !important: the drag
               handlers track the finger with inline transform/transition
               while a gesture is in progress, and inline styles must win. */
            .info-window.mobile-legacy-sheet {
                /* --- [CRITICAL] Override desktop styles --- */
                display: flex !important; /* Use flex (from desktop) */
                position: absolute !important;
                top: auto !important; /* Unset top */
                bottom: 0 !important;
                left: 0 !important;
                right: 0 !important;
                width: 100% !important;
                max-width: 100% !important;
                /* Use dynamic viewport height so the sheet doesn't extend
                   behind iOS Safari's URL bar when expanded — that was
                   pushing the drag handle off-screen. vh fallback first
                   for browsers without dvh support. */
                max-height: calc(100vh - var(--legacy-top-offset)) !important;
                max-height: calc(100dvh - var(--legacy-top-offset)) !important;
                z-index: 1045 !important;
                border-radius: 16px 16px 0 0 !important;
                box-shadow: 0 -5px 30px rgba(0,0,0,0.4) !important;

                /* --- Neutralize the desktop entrance. The sheet is always
                   fully opaque and interactive; "hidden" is expressed purely
                   by the translateY parking it below the viewport. --- */
                opacity: 1;
                transform-origin: center bottom;
                pointer-events: auto;

                /* --- Animation & State --- */
                will-change: transform;
                /* Resting (closed) state: parked just below the bottom edge */
                transform: translateY(100%);
                transition: transform 0.45s cubic-bezier(0.16, 1, 0.3, 1);
            }

            /* "Peek" State (Default visible state) */
            .info-window.mobile-legacy-sheet.visible.peek {
                transform: translateY(calc(100% - var(--legacy-peek-height)));
            }

            /* "Expanded" State. No !important here — while a drag is in
               progress the gesture handler positions the sheet with an
               inline transform, which must out-rank this rule or the sheet
               won't follow the finger down from the expanded state. */
            .info-window.mobile-legacy-sheet.visible:not(.peek) {
                transform: translateY(0);
            }
            
            /* --- [NEW] Drag Handle for Legacy Sheet --- */
            .legacy-sheet-handle {
                position: relative;
                flex-shrink: 0;
                cursor: grab;
                touch-action: none;
                user-select: none;
                /* This handle is a wrapper, so no visual styles by default */
            }
            /* Add the pill visual */
            .legacy-sheet-handle::before {
                content: '';
                position: absolute;
                left: 50%;
                transform: translateX(-50%);
                top: 8px; 
                width: 40px; 
                height: 4px; 
                background: var(--hud-border);
                border-radius: 2px; 
                opacity: 0.5;
                z-index: 10; /* Above content */
            }

            /* --- Simple-mode iframe: stretch the sheet + iframe fully ---
               The default .mobile-legacy-sheet has max-height but no
               explicit height, so it sizes to its content. The simple
               window's only child is an iframe with no height attribute
               or style, which collapses to the browser's ~150px default.
               Force the sheet to claim the full available viewport and
               the iframe to fill it, otherwise peek/expanded never
               stretch out. */
            .mobile-legacy-sheet:has(> #simple-flight-window-frame) {
                height: calc(100vh - var(--legacy-top-offset)) !important;
                height: calc(100dvh - var(--legacy-top-offset)) !important;
                /* Shorter peek so the compact bar isn't followed by a big
                   chunk of empty space. Kept in sync with CONFIG.simplePeekHeight. */
                --legacy-peek-height: 240px;
            }
            .mobile-legacy-sheet > #simple-flight-window-frame {
                width: 100% !important;
                height: 100% !important;
                flex: 1 1 0% !important;
                min-height: 0 !important;
                display: block !important;
                border: none !important;
                border-radius: 16px 16px 0 0 !important;
            }

            /* --- iPad / tablet: present the simple flight window as a centered
               floating card instead of an edge-to-edge bar. The window's content
               is laid out for a phone (~380px); stretched across a 768px+ iPad it
               looked broken — sparse, with truncated route cities and oversized
               media. Constraining the host to a phone-width card restores the
               intended layout and matches iPadOS's centered form-sheet style. --- */
            @media (min-width: 700px) and (max-width: 1024px) {
                .mobile-legacy-sheet:has(> #simple-flight-window-frame) {
                    left: 0 !important;
                    right: 0 !important;
                    width: min(540px, 92vw) !important;
                    max-width: 540px !important;
                    margin-left: auto !important;
                    margin-right: auto !important;
                    bottom: max(env(safe-area-inset-bottom, 0px), 14px) !important;
                    height: min(82dvh, 860px) !important;
                    max-height: min(82dvh, 860px) !important;
                    border-radius: 24px !important;
                    box-shadow: 0 24px 70px rgba(0, 0, 0, 0.55) !important;
                }
                .mobile-legacy-sheet:has(> #simple-flight-window-frame) > #simple-flight-window-frame {
                    border-radius: 24px !important;
                }
                .mobile-legacy-sheet:has(> #simple-flight-window-frame) .legacy-sheet-handle.simple-mode {
                    border-radius: 24px 24px 0 0 !important;
                }
            }

            /* --- [UPDATED] Specific styling for SIMPLE MODE handle (Seamless Overlay) --- */
            /* We also use this for AIRPORTS now, as a floating handle */
            .legacy-sheet-handle.simple-mode {
                position: absolute !important; /* Float over the iframe */
                top: 0 !important;
                left: 0 !important;
                width: 100% !important;
                height: 40px !important; /* Visual height */
                /* Large invisible touch area downwards for easier grabbing */
                padding-bottom: 40px !important; 
                
                /* Seamless Gradient Background (instead of solid block) */
                background: linear-gradient(to bottom, rgba(0,0,0,0.7) 0%, transparent 100%) !important;
                
                border: none !important;
                border-radius: 16px 16px 0 0 !important;
                
                display: flex !important;
                justify-content: center !important;
                flex-shrink: 0 !important;
                
                z-index: 2000 !important; /* On top of iframe */
                box-sizing: content-box !important;
                pointer-events: auto !important; /* Ensure it captures swipes */
            }
            
            .legacy-sheet-handle.simple-mode::before {
                top: 8px !important; /* Center the pill near the top edge */
                width: 60px !important; /* Wider pill */
                height: 5px !important; /* Thicker pill */
                background: rgba(255, 255, 255, 0.4) !important;
                box-shadow: 0 1px 4px rgba(0,0,0,0.5) !important;
            }

            /* --- Content Scrolling --- */
            .mobile-legacy-sheet .info-window-content {
                overflow-y: auto !important;
                /* Add padding for the bottom safe area */
                padding-bottom: env(safe-area-inset-bottom, 20px);
            }

            /* --- Header / Image / Route Bar Overrides --- */
            /* Show the whole aircraft (nose to tail) on the mobile legacy
               sheet — the inline style on .ac-header-modern in flight.js
               sets background-size: cover, which over-scales typical
               16:9 photos in a wider 200 px-tall hero and crops the tail
               and the back of the plane. !important is required to beat
               that inline declaration. The image is also anchored to the
               TOP of the panel so the letterboxed dead space lives at the
               bottom only — that's where the AC bar sits, so the dead
               space can fade into the bar instead of being split top/
               bottom around the photo. */
            .mobile-legacy-sheet .aircraft-overview-panel,
            .mobile-legacy-sheet .ac-header-modern {
                background-size: contain !important;
                background-repeat: no-repeat !important;
                background-position: top center !important;
                background-color: #1c1c1f !important;
            }

            /* Replace the hero's bottom gradient overlay. The inline
               default fades to rgba(15,23,42,0.85) (dark navy), which
               leaves a visible navy band right above the AC bar. Fade
               instead transparent → gray → AC-bar gray (#3a3a3a) so the
               bottom of the hero merges into the bar as one continuous
               low-gray band. */
            .mobile-legacy-sheet .ac-header-overlay {
                background: linear-gradient(
                    to bottom,
                    transparent 0%,
                    transparent 45%,
                    rgba(58, 58, 58, 0.55) 72%,
                    rgba(58, 58, 58, 0.95) 100%
                ) !important;
            }

            /* The blue/navy seam directly under the AC bar is the window
               itself: .info-window uses rgba(45,45,45,0.9) + a 40 px
               backdrop blur, which picks up the blue tint of the map
               underneath and reads as navy through any transparent
               child. .ac-info-window-tabs has no background of its own,
               so the blurred window shows through that strip. Plug it
               with the AC bar's own gray so the strip between the bar
               and the tab buttons continues the bar visually instead of
               stepping down to a darker zinc. */
            .mobile-legacy-sheet .ac-info-window-tabs {
                background: #3a3a3a !important;
            }
            /* Keep the top-right action buttons (pin / bell / replay / share)
               clickable in legacy mode. The drag handle wrapper sits at
               z-index 2000 across the middle 50% of the sheet, and on
               narrow phones the buttons extend left into that zone, so
               their taps would get swallowed by the handle's grab area. */
            .mobile-legacy-sheet .overview-actions {
                z-index: 2001 !important;
            }
            .mobile-legacy-sheet .route-summary-overlay {
                /* The handle will wrap this */
            }

            
        `;
        const style = document.createElement('style');
        style.id = styleId;
        style.type = 'text/css';
        style.appendChild(document.createTextNode(css));
        document.head.appendChild(style);
    },

    openWindow(windowElement) {
        if (!this.isMobile()) return;

        if (this.activeWindow) {
            this.closeActiveWindow(true); 
        }

        const mapContainer = document.getElementById('sector-ops-map-fullscreen');
        if (mapContainer) {
            mapContainer.classList.add('mobile-ui-active');
            mapContainer.classList.add('mobile-window-open'); 
        }

        const hudControls = document.getElementById('mobile-hud-controls');
        if (hudControls) hudControls.style.opacity = '0';

        const burgerMenu = document.getElementById('mobile-sidebar-toggle');
        const mapToolbar = document.getElementById('toolbar-toggle-panel-btn')?.parentElement;
        const searchBar = document.getElementById('sector-ops-search-container');
        
        if (burgerMenu) burgerMenu.style.display = 'none';
        if (mapToolbar) mapToolbar.style.display = 'none';
        if (searchBar) searchBar.style.display = 'none';

        // --- UPDATED ROUTER LOGIC ---
        // Accept BOTH Aircraft and Airport windows
        if (windowElement.id === 'aircraft-info-window' || windowElement.id === 'airport-info-window') {
            
            // 1. Check for Simple Mode (iframe existence)
            const isSimpleMode = !!windowElement.querySelector('#simple-flight-window-frame');

            // 2. Get user preference
            let userMode = localStorage.getItem('mobileDisplayMode') || this.CONFIG.defaultMode;

            // 3. FORCE Legacy mode if it's the Airport Window OR Simple Mode is active
            if (isSimpleMode || windowElement.id === 'airport-info-window') {
                userMode = 'legacy';
            }

            this.activeMode = userMode;
            this.activeWindow = windowElement;

            if (userMode === 'legacy') {
                this.createLegacySheetUI();
                this.observeOriginalWindow(windowElement);
            } else {
                this.createSplitViewUI(); 
                this.observeOriginalWindow(windowElement);
            }
        }
    },

    /**
     * [MODIFIED] Creates the DOM for the "Legacy Sheet" mode.
     * This is much simpler: just an overlay.
     */
    createLegacySheetUI() {
        // --- [FIX] Target the new map container instead of 'view-rosters' ---
        const viewContainer = document.getElementById('sector-ops-map-fullscreen');
        if (!viewContainer) return;

        // 1. Overlay
        this.overlayEl = document.createElement('div');
        this.overlayEl.id = 'mobile-window-overlay';
        viewContainer.appendChild(this.overlayEl);
        
        // 2. Add class to the *original* window. Strip any stale visibility
        // state first (the desktop path can re-add 'visible' before routing
        // here, e.g. on trip-card exit) so the sheet always presents from
        // its parked position below the bottom edge instead of popping in
        // already expanded.
        this.activeWindow.classList.remove('visible', 'peek');
        this.activeWindow.classList.add('mobile-legacy-sheet');
        this.activeWindow.style.display = 'flex';
        
        // 3. Animate it in [REMOVED]
        // We now wait for the observer to populate content *before* animating.
    },

    /**
     * [MODIFIED] Creates the new DOM structure for the HUD.
     * Includes a dedicated slot for the tab buttons in the Expanded Island.
     */
    createSplitViewUI() {
        // --- [FIX] Target the new map container instead of 'view-rosters' ---
        const viewContainer = document.getElementById('sector-ops-map-fullscreen');
        if (!viewContainer) return;

        // 1. Overlay
        this.overlayEl = document.createElement('div');
        this.overlayEl.id = 'mobile-window-overlay';
        viewContainer.appendChild(this.overlayEl);
        
        // 2. Top Window
        this.topWindowEl = document.createElement('div');
        this.topWindowEl.id = 'mobile-aircraft-top-window';
        this.topWindowEl.className = 'mobile-aircraft-view';
        viewContainer.appendChild(this.topWindowEl);

        // 3. Bottom Island - State 0 (Mini)
        this.miniIslandEl = document.createElement('div');
        this.miniIslandEl.id = 'mobile-island-mini';
        this.miniIslandEl.className = 'mobile-island-bottom';
        this.miniIslandEl.innerHTML = `<div class="route-summary-wrapper-mobile"></div>`;
        viewContainer.appendChild(this.miniIslandEl);

        // 4. Bottom Island - State 1 (Peek)
        this.peekIslandEl = document.createElement('div');
        this.peekIslandEl.id = 'mobile-island-peek';
        this.peekIslandEl.className = 'mobile-island-bottom';
        this.peekIslandEl.innerHTML = `
            <div class="route-summary-wrapper-mobile"></div>
            <div class="drawer-content"></div>
        `;
        viewContainer.appendChild(this.peekIslandEl);
        
        // 5. Bottom Island - State 2 (Expanded)
        this.expandedIslandEl = document.createElement('div');
        this.expandedIslandEl.id = 'mobile-island-expanded';
        this.expandedIslandEl.className = 'mobile-island-bottom';
        this.expandedIslandEl.innerHTML = `
            <div class="route-summary-wrapper-mobile"></div>
            <div id="expanded-tabs-slot"></div>
            <div class="drawer-content"></div>
        `;
        viewContainer.appendChild(this.expandedIslandEl);
    },

    /**
     * [MODIFIED] Observes the original window for content.
     * Now calls the correct "populate" function based on the active mode
     * AND triggers the animation *after* population is complete.
     */
    observeOriginalWindow(windowElement) {
        if (this.contentObserver) this.contentObserver.disconnect();

        // Populates the active sheet/HUD once the window's content is ready and
        // animates it in. Returns true once it has run so the caller can stop
        // waiting. Factored out of the observer below so it can ALSO be fired
        // for windows whose content is already present. Guarded so it only
        // ever populates once per observe() call.
        let populated = false;
        const tryPopulate = () => {
            if (populated) return true;
            const mainContent = windowElement.querySelector('.unified-display-main-content');
            const attitudeGroup = mainContent?.querySelector('#attitude_group');

            // --- [NEW CHECK] For Simple Window (Iframe) ---
            const simpleIframe = windowElement.querySelector('#simple-flight-window-frame');

            // --- [NEW CHECK] For Airport Window ---
            const isAirportWindow = windowElement.id === 'airport-info-window';
            // Airports might have .airport-overview-panel or similar, but generally if they have children, they are ready.
            const isAirportReady = isAirportWindow && windowElement.children.length > 0;

            // Condition 1: Standard PFD is built
            const isStandardReady = mainContent && attitudeGroup && attitudeGroup.dataset.initialized === 'true';
            // Condition 2: Simple Iframe is present
            const isSimpleReady = !!simpleIframe;

            if (!(isStandardReady || isSimpleReady || isAirportReady)) return false;

            populated = true;

            // --- [NEW] Router ---
            if (this.activeMode === 'legacy') {
                // 1. Populate first (while off-screen)
                this.populateLegacySheet(windowElement);

                // 2. NOW, animate it in
                if (this.activeWindow) {
                    setTimeout(() => {
                        if (this.isSimpleSheetExpandedOnly()) {
                            // iPad: skip the phone-only peek bar and open
                            // straight into the expanded "second state".
                            this.setLegacySheetState('expanded');
                        } else {
                            // Size the peek detent to the simple window's saved
                            // preset (primed on the host before open) so the bar
                            // opens at the right height immediately.
                            if (this.isSimpleSheet()) {
                                this.activeWindow.style.setProperty('--legacy-peek-height', this.getPeekHeight() + 'px');
                            }
                            this.activeWindow.classList.add('visible', 'peek');
                            this.legacySheetState.currentState = 'peek';
                        }
                    }, 10);
                }

            } else { // 'hud' mode
                // 1. Populate first (while off-screen)
                this.populateSplitView(windowElement);

                // 2. NOW, animate them in
                setTimeout(() => {
                    if (this.topWindowEl) this.topWindowEl.classList.add('visible');
                    if (this.miniIslandEl) this.miniIslandEl.classList.add('island-active');
                    this.drawerState = 0; // Set initial state
                }, 10);
            }

            return true;
        };

        this.contentObserver = new MutationObserver((mutationsList, obs) => {
            if (tryPopulate()) {
                obs.disconnect();
                this.contentObserver = null;
            }
        });

        this.contentObserver.observe(windowElement, {
            childList: true,
            subtree: true,
            attributes: true
        });

        // Safety net for the return-from-overlay case (replay / trip card),
        // where the window's content — notably the simple-window iframe — is
        // already in the DOM and will NOT mutate again (the simple window pushes
        // live updates into the iframe rather than mutating the host), so the
        // observer above would wait forever and the sheet would never re-animate.
        //
        // Deferred to the next frame rather than run synchronously: callers that
        // are about to rebuild the window (e.g. switching aircraft) reset
        // innerHTML to a spinner right after openWindow() returns. Running now
        // would populate against that stale content and prepend a drag handle
        // that the imminent innerHTML reset would wipe — leaving the sheet
        // tap-only with no slide handle. By waiting a frame, any such reset (and
        // the MutationObserver it triggers) wins first; we only step in if the
        // content is genuinely already settled and the observer never fired.
        requestAnimationFrame(() => {
            if (populated || this.activeWindow !== windowElement) return;
            if (tryPopulate() && this.contentObserver) {
                this.contentObserver.disconnect();
                this.contentObserver = null;
            }
        });
    },

populateLegacySheet(sourceWindow) {
        // ALWAYS inject a dedicated, absolute-positioned handle overlay.
        const handleWrapper = document.createElement('div');
        handleWrapper.className = 'legacy-sheet-handle simple-mode universal-handle'; 
        
        // [THE FIX]: Override the 100% CSS width. Shrink the grab zone strictly to the middle 50%.
        // This leaves a 25% gap on the left and right, completely uncovering the top-right 
        // buttons so they can be clicked normally without the drag handle intercepting them.
        handleWrapper.style.setProperty('width', '50%', 'important');
        handleWrapper.style.setProperty('left', '25%', 'important');
        // Bigger grab zone so the handle stays draggable even when the sheet
        // is fully expanded and the very top of the sheet hugs the device chrome.
        handleWrapper.style.setProperty('height', '55px', 'important');
        handleWrapper.style.setProperty('padding-bottom', '0', 'important');
        handleWrapper.style.setProperty('background', 'transparent', 'important');
        
        sourceWindow.prepend(handleWrapper);
        sourceWindow.style.position = 'relative'; 
        
        // Push the original content down just enough so the visual pill doesn't overlap text,
        // but keeps the buttons nicely aligned.
        const overviewPanel = sourceWindow.querySelector('.aircraft-overview-panel');
        if (overviewPanel) {
            overviewPanel.style.paddingTop = '25px';
        }

        this.wireUpLegacySheetInteractions(sourceWindow, handleWrapper);
    },

    /**
     * [MODIFIED] Moves content from the original window into the new island components.
     * Now clones the tab container into the expanded island.
     */
    populateSplitView(sourceWindow) {
        if (!this.topWindowEl || !this.miniIslandEl || !this.peekIslandEl || !this.expandedIslandEl) return;

        // Find content containers
        const miniRouteContainer = this.miniIslandEl.querySelector('.route-summary-wrapper-mobile');
        const peekRouteContainer = this.peekIslandEl.querySelector('.route-summary-wrapper-mobile');
        const expandedRouteContainer = this.expandedIslandEl.querySelector('.route-summary-wrapper-mobile');
        
        const peekContentContainer = this.peekIslandEl.querySelector('.drawer-content');
        const expandedContentContainer = this.expandedIslandEl.querySelector('.drawer-content');
        const expandedTabsSlot = this.expandedIslandEl.querySelector('#expanded-tabs-slot');

        if (!peekContentContainer || !expandedContentContainer || !miniRouteContainer || !peekRouteContainer || !expandedRouteContainer || !expandedTabsSlot) return; 

        // Find original content pieces
        const topOverviewPanel = sourceWindow.querySelector('.aircraft-overview-panel');
        const routeSummaryBar = sourceWindow.querySelector('.route-summary-overlay');
        const tabContainer = sourceWindow.querySelector('.ac-info-window-tabs');
        const mainFlightContent = sourceWindow.querySelector('.unified-display-main-content');
        
        // 1. Move Top Panel
        if (topOverviewPanel) {
            this.topWindowEl.appendChild(topOverviewPanel);
        }
        
        // 2. Clone and Move Route Summary Bar to ALL three islands
        if (routeSummaryBar) {
            const clonedRouteBar1 = routeSummaryBar.cloneNode(true);
            const clonedRouteBar2 = routeSummaryBar.cloneNode(true);
            const clonedRouteBar3 = routeSummaryBar.cloneNode(true);
            
            miniRouteContainer.appendChild(clonedRouteBar1);
            peekRouteContainer.appendChild(clonedRouteBar2);
            expandedRouteContainer.appendChild(clonedRouteBar3);
        }
        
        // 3. Clone and Move Main Content & Tabs
        if (mainFlightContent && tabContainer) {
            // A. Move the original, full content to the Expanded Island
            expandedContentContainer.appendChild(mainFlightContent);
            
            // B. Clone and move the original tab bar to the dedicated slot
            expandedTabsSlot.appendChild(tabContainer);
            
            // C. Create a streamlined copy for the Peek Island
            const peekContentClone = document.createElement('div');
            peekContentClone.className = 'unified-display-main-content'; // Match container class

            // Clone and append PFD/Location Grid
            const pfdLocationGrid = mainFlightContent.querySelector('.pfd-and-location-grid')?.cloneNode(true);
            if (pfdLocationGrid) {
                 peekContentClone.appendChild(pfdLocationGrid);
            }

            // Clone and append Data Bar
            const dataBar = mainFlightContent.querySelector('.flight-data-bar')?.cloneNode(true);
            if (dataBar) {
                 peekContentClone.appendChild(dataBar);
            }
            
            // Append the streamlined clone to the Peek drawer
            peekContentContainer.appendChild(peekContentClone);
        }
        
        this.wireUpHudInteractions();
    },

wireUpLegacySheetInteractions(sheetElement, handleElement) {
        handleElement.addEventListener('touchstart', this.handleLegacyTouchStart.bind(this), { passive: false });
        
        document.addEventListener('touchmove', this.boundLegacyTouchMove, { passive: false });
        document.addEventListener('touchend', this.boundLegacyTouchEnd);
        document.addEventListener('touchcancel', this.boundLegacyTouchEnd);
        
        if (this.overlayEl) {
            this.overlayEl.addEventListener('click', () => {
                if (this.legacySheetState.currentState === 'expanded'
                    && !this.isSimpleSheetExpandedOnly()) {
                    this.setLegacySheetState('peek');
                } else {
                    // iPad has no peek state to fall back to — dismiss instead.
                    this.closeActiveWindow();
                }
            });
        }
        
        // --- Intercept Takeover Buttons to clear the sheet gracefully ---
        const interceptTakeovers = (e) => {
            const actionBtn = e.target.closest('.aircraft-window-share-btn, .aircraft-window-replay-btn');
            if (actionBtn && this.activeWindow) {
                this.closeActiveWindow(); // Move the UI out of the way natively
            }
        };
        sheetElement.addEventListener('click', interceptTakeovers, { capture: true });
        
        const closeBtn = sheetElement.querySelector('.aircraft-window-close-btn, .close-btn, button[class*="close"]');
        const hideBtn = sheetElement.querySelector('.aircraft-window-hide-btn');
        
        if(closeBtn) {
            closeBtn.addEventListener('click', (e) => {
                e.preventDefault(); e.stopPropagation();
                this.closeActiveWindow();
            });
        }
        if(hideBtn) {
            hideBtn.addEventListener('click', (e) => {
                e.preventDefault(); e.stopPropagation();
                this.closeActiveWindow(); 
                
                const recallBtn = document.getElementById('aircraft-recall-btn');
                if (recallBtn) {
                    recallBtn.classList.add('visible', 'palpitate');
                    setTimeout(() => recallBtn.classList.remove('palpitate'), 1000);
                }
            });
        }
    },

    /**
     * [MODIFIED] Wires up interactions for HUD mode.
     */
    wireUpHudInteractions() {
        if (!this.miniIslandEl || !this.peekIslandEl || !this.expandedIslandEl) return;

        // Get the new unified handles
        const miniHandle = this.miniIslandEl.querySelector('.route-summary-wrapper-mobile');
        const peekHandle = this.peekIslandEl.querySelector('.route-summary-wrapper-mobile');
        const expandedHandle = this.expandedIslandEl.querySelector('.route-summary-wrapper-mobile');
        const tabsInSlot = this.expandedIslandEl.querySelector('.ac-info-window-tabs'); 

        if (!miniHandle || !peekHandle || !expandedHandle || !tabsInSlot) return;

        // --- Click Interactions (Drawer State) ---
        miniHandle.addEventListener('click', (e) => {
            if (this.swipeState.isDragging) return;
            this.setDrawerState(1);
        });
        peekHandle.addEventListener('click', (e) => {
            if (this.swipeState.isDragging) return;
            this.setDrawerState(2);
        });
        expandedHandle.addEventListener('click', (e) => {
            if (this.swipeState.isDragging) return;
            this.setDrawerState(1);
        });
        
        if (this.overlayEl) {
            this.overlayEl.addEventListener('click', () => this.setDrawerState(0));
        }

        // --- Swipe Interactions ---
        miniHandle.addEventListener('touchstart', this.handleHudTouchStart.bind(this), { passive: false });
        peekHandle.addEventListener('touchstart', this.handleHudTouchStart.bind(this), { passive: false });
        expandedHandle.addEventListener('touchstart', this.handleHudTouchStart.bind(this), { passive: false });
        
        document.addEventListener('touchend', this.boundHudTouchEnd);

        // --- [NEW] Proxy missing desktop buttons ---
        // Since elements were moved from the activeWindow to the HUD DOM, their native click
        // handlers attached via event delegation to activeWindow will no longer fire.
        const handleDesktopProxyClick = (e) => {
            // The bell is special: clone-and-click doesn't work because the
            // handler swaps the icon class on the clicked node, and a hidden
            // clone won't reflect that to the user. Call the extracted bell
            // handler directly against the visible in-island button.
            const bellBtn = e.target.closest('.aircraft-window-trackme-btn');
            if (bellBtn && typeof window.handleTrackmeBellClick === 'function') {
                e.preventDefault();
                e.stopPropagation();
                window.handleTrackmeBellClick(bellBtn);
                return;
            }

            const actionBtn = e.target.closest('.aircraft-window-pin-btn, .aircraft-window-share-btn, .aircraft-window-replay-btn, #plan-this-flight-btn, .profile-toggle-btn');

            if (actionBtn && this.activeWindow) {
                e.preventDefault();
                e.stopPropagation();

                // If opening Trip Card or Replay, temporarily hide HUD so it doesn't overlap
                if (actionBtn.classList.contains('aircraft-window-share-btn') || actionBtn.classList.contains('aircraft-window-replay-btn')) {
                    this.closeActiveWindow();
                }

                // Trigger the desktop event listener by cloning the button into the original window
                const clone = actionBtn.cloneNode(true);
                clone.style.display = 'none';
                this.activeWindow.appendChild(clone);
                clone.click();
                clone.remove();
            }
        };

        // --- Re-wire desktop buttons ---
        this.topWindowEl.addEventListener('click', (e) => {
            const closeBtn = e.target.closest('.aircraft-window-close-btn');
            const hideBtn = e.target.closest('.aircraft-window-hide-btn');

            if (closeBtn) {
                this.closeActiveWindow();
                return;
            }
            
            if (hideBtn) {
                this.topWindowEl.classList.remove('visible');
                this.setDrawerState(0);
                this.miniIslandEl?.classList.remove('island-active');
                this.peekIslandEl?.classList.remove('island-active');
                this.expandedIslandEl?.classList.remove('island-active');
                this.overlayEl.classList.remove('visible');
                
                const recallBtn = document.getElementById('aircraft-recall-btn');
                if (recallBtn) {
                    recallBtn.classList.add('visible', 'palpitate');
                    setTimeout(() => recallBtn.classList.remove('palpitate'), 1000);
                }
                return;
            }
            
            // If it wasn't a standard UI close/hide action, push the click to the proxy
            handleDesktopProxyClick(e);
        });
        
        // Also capture proxy clicks originating from deep inside the expanded HUD layout
        this.expandedIslandEl.addEventListener('click', (e) => {
            handleDesktopProxyClick(e);
        });

        // --- Dedicated Tab Switching Logic ---
        tabsInSlot.addEventListener('click', async (e) => {
            const tabBtn = e.target.closest('.ac-info-tab-btn');

            if (tabBtn) {
                e.preventDefault();
                e.stopPropagation();
                
                const tabId = tabBtn.dataset.tab;
                if (!tabId || tabBtn.classList.contains('active')) {
                    return;
                }
                
                const islandContent = this.expandedIslandEl;
                if (!islandContent) return;

                // Deactivate old tab/pane
                islandContent.querySelector('.ac-info-tab-btn.active')?.classList.remove('active');
                islandContent.querySelector('.ac-tab-pane.active')?.classList.remove('active');

                // Activate new tab/pane
                tabBtn.classList.add('active');
                const newPane = islandContent.querySelector(`#${tabId}`);
                if (newPane) {
                    newPane.classList.add('active');
                }
                
                if (tabId === 'ac-tab-pilot-report') {
                    const statsDisplay = newPane?.querySelector('#pilot-stats-display');
                    if (statsDisplay) { 
                        const userId = tabBtn.dataset.userId;
                        const username = tabBtn.dataset.username;
                        
                        if (userId && window.displayPilotStats) { 
                            await window.displayPilotStats(userId, username); 
                            
                            const accordionHeaders = statsDisplay.querySelectorAll('.accordion-header');
                            accordionHeaders.forEach(header => {
                                const item = header.closest('.accordion-item');
                                if (item.classList.contains('active')) {
                                    const content = header.nextElementSibling;
                                    content.style.maxHeight = content.scrollHeight + 'px';
                                }
                            });
                        } else {
                            statsDisplay.innerHTML = `<p class="error-text" style="padding: 1rem;">Could not load pilot data. Missing userId or helper function.</p>`;
                        }
                    }
                }
            }
        });
    },
    
    /**
     * [HUD] Sets the drawer to a specific state (0, 1, or 2).
     */
    setDrawerState(targetState) {
        if (targetState === this.drawerState || !this.miniIslandEl) return;
        
        this.drawerState = targetState;

        this.miniIslandEl.classList.toggle('island-active', this.drawerState === 0);
        this.peekIslandEl.classList.toggle('island-active', this.drawerState === 1);
        this.expandedIslandEl.classList.toggle('island-active', this.drawerState === 2);
        
        const isFullyExpanded = (this.drawerState === 2);
        if (this.overlayEl) this.overlayEl.classList.toggle('visible', isFullyExpanded);
    },

    /**
     * [NEW] Sets the "Legacy Sheet" to a specific state.
     */
    // Is the simple flight-info iframe the active legacy sheet?
    isSimpleSheet() {
        return !!(this.activeWindow && this.activeWindow.querySelector
            && this.activeWindow.querySelector('#simple-flight-window-frame'));
    },

    // The simple window hugs its compact bar, so it gets a shorter peek.
    getPeekHeight() {
        return this.isSimpleSheet() ? this.CONFIG.simplePeekHeight : this.CONFIG.legacyPeekHeight;
    },

    // Locks/unlocks the sheet drag gesture while the simple window is in
    // layout-edit mode (so in-iframe block dragging doesn't drag the sheet).
    editLocked: false,
    setEditLock(active) {
        this.editLocked = !!active;
        if (active) this.legacySheetState.isDragging = false;
    },

    // The simple window's peek preset (Minimal/Standard/Rich) reports the height
    // its collapsed bar needs. Update the detent + the CSS var that positions the
    // peek transform, and re-snap if we're currently peeking so it's instant.
    setSimplePeekHeight(px) {
        const h = Math.max(120, Math.min(parseInt(px, 10) || this.CONFIG.simplePeekHeight, Math.round(window.innerHeight * 0.85)));
        this.CONFIG.simplePeekHeight = h;
        if (this.isSimpleSheet() && this.activeWindow) {
            // Inline custom property wins over the stylesheet's --legacy-peek-height.
            this.activeWindow.style.setProperty('--legacy-peek-height', h + 'px');
            if (this.legacySheetState.currentState === 'peek' && !this.isSimpleSheetExpandedOnly()) {
                this.setLegacySheetState('peek');
            }
        }
    },

    // Keep the iframe's content phase in sync with the host sheet so dragging
    // the sheet up/down morphs small <-> big info (no tap required).
    syncSimpleIframePhase(targetState) {
        if (!this.isSimpleSheet()) return;
        const iframe = this.activeWindow.querySelector('#simple-flight-window-frame');
        if (iframe && iframe.contentWindow) {
            try {
                iframe.contentWindow.postMessage({
                    type: 'SET_PHASE',
                    phase: targetState === 'expanded' ? 'expanded' : 'collapsed'
                }, '*');
            } catch (e) {}
        }
    },

    setLegacySheetState(targetState) { // 'peek', 'expanded', or 'closed'
        if (!this.activeWindow) return;

        this.legacySheetState.currentState = targetState;
        this.activeWindow.style.transition = 'transform 0.45s cubic-bezier(0.16, 1, 0.3, 1)';
        this.activeWindow.style.transform = ''; // Remove inline style from dragging

        if (targetState === 'expanded') {
            this.activeWindow.classList.add('visible');
            this.activeWindow.classList.remove('peek');
            if (this.overlayEl) this.overlayEl.classList.add('visible');

            const topOffset = parseInt(getComputedStyle(document.documentElement)
            .getPropertyValue('--hud-top-window-height')) || 280;
            const expandedY = topOffset;

            this.legacySheetState.currentSheetY = expandedY;
            this.syncSimpleIframePhase('expanded');

        } else if (targetState === 'peek') {
            // Keep the CSS var that drives the peek transform in sync with the
            // current detent (the simple window's preset can change it live).
            if (this.isSimpleSheet()) {
                this.activeWindow.style.setProperty('--legacy-peek-height', this.getPeekHeight() + 'px');
            }
            this.activeWindow.classList.add('visible', 'peek');
            if (this.overlayEl) this.overlayEl.classList.remove('visible');

            const peekY = window.innerHeight - this.getPeekHeight();
            this.legacySheetState.currentSheetY = peekY;
            this.syncSimpleIframePhase('collapsed');

        } else if (targetState === 'closed') {
            this.activeWindow.classList.remove('visible', 'peek');
            if (this.overlayEl) this.overlayEl.classList.remove('visible');
            this.legacySheetState.currentSheetY = window.innerHeight + 100;
        }
    },

// --- [HUD] Swipe Gesture Handlers ---
    handleHudTouchStart(e) {
        if (this.activeMode !== 'hud') return;
        
        // --- [CRITICAL FIX] Do not start dragging if the user is touching an action button ---
        if (e.target.closest('button, a, .aircraft-window-pin-btn, .aircraft-window-share-btn, .aircraft-window-replay-btn, .aircraft-window-trackme-btn, .close-btn, .overview-actions, [role="button"]')) {
            return; // Let the click event fire naturally
        }

        const handle = e.target.closest('.route-summary-wrapper-mobile');
        if (!handle) {
             this.swipeState.isDragging = false;
             return;
        }
        e.preventDefault();
        this.swipeState.isDragging = true;
        this.swipeState.touchStartY = e.touches[0].clientY;
    },
    handleHudTouchEnd(e) {
        if (this.activeMode !== 'hud' || !this.swipeState.isDragging) return;
        
        setTimeout(() => {
            this.swipeState.isDragging = false;
            this.swipeState.touchStartY = 0;
        }, 50);

        const touchEndY = e.changedTouches[0].clientY;
        const deltaY = touchEndY - this.swipeState.touchStartY;
        const currentState = this.drawerState;

        if (deltaY > 150 && currentState === 0) {
             this.closeActiveWindow();
             return;
        }
        
        let newState = currentState;
        if (deltaY < -50) { // Swiped up
             newState = Math.min(2, currentState + 1);
        } else if (deltaY > 50) { // Swiped down
             newState = Math.max(0, currentState - 1);
        }
        this.setDrawerState(newState);
    },

// --- [NEW] Legacy Sheet Swipe Handlers ---
    handleLegacyTouchStart(e) {
        if (this.activeMode !== 'legacy' || !this.activeWindow) return;
        // While the simple window is in layout-edit mode, the sheet gesture is
        // locked so dragging blocks inside the iframe doesn't move the sheet.
        if (this.editLocked) return;

        // Prevent drag if touching a button so clicks work perfectly
        const interactiveSelectors = [
            '.overview-actions', '.close-btn', 'button', 'a', '[role="button"]', 
            '.aircraft-window-pin-btn', '.aircraft-window-share-btn', '.aircraft-window-replay-btn',
            '.aircraft-window-trackme-btn',
            '.ac-info-tab-btn'
        ];
        if (e.target.closest(interactiveSelectors.join(', '))) {
             return; 
        }
        
        const handle = e.target.closest('.legacy-sheet-handle');
        if (!handle) return;
        
        this.legacySheetState.isDragging = true;
        this.legacySheetState.touchStartY = e.touches[0].clientY;
        
        // [THE NEW FIX]: WebKitCSSMatrix fails on mobile when reading `calc()` percentages.
        // Instead, we mathematically calculate the exact starting pixel translation using the element's actual rendered height.
        const rect = this.activeWindow.getBoundingClientRect();
        if (this.legacySheetState.currentState === 'peek') {
            // Translate Y is exactly the total height minus the visible peek area
            this.legacySheetState.startTranslateY = rect.height - this.getPeekHeight();
        } else {
            // Expanded is always at 0 translation
            this.legacySheetState.startTranslateY = 0;
        }
        
        // Initialize current state to prevent NaN errors on pure taps
        this.legacySheetState.currentTranslateY = this.legacySheetState.startTranslateY;
        
        // Stop CSS transitions so it follows your finger instantly without jumping
        this.activeWindow.style.transition = 'none'; 
    },

    handleLegacyTouchMove(e) {
        if (this.activeMode !== 'legacy' || !this.legacySheetState.isDragging || !this.activeWindow) return;
        
        e.preventDefault(); // Stop the whole page from scrolling
        
        const touchCurrentY = e.touches[0].clientY;
        const deltaY = touchCurrentY - this.legacySheetState.touchStartY;

        // Calculate live drag position
        let newTranslateY = this.legacySheetState.startTranslateY + deltaY;
        
        // Add resistance if they try to drag it higher than fully expanded (translateY: 0)
        if (newTranslateY < 0) {
            newTranslateY = newTranslateY * 0.2; // Rubber band effect
        }
        
        // Apply live tracking
        this.activeWindow.style.transform = `translateY(${newTranslateY}px)`;
        this.legacySheetState.currentTranslateY = newTranslateY; 
    },

    handleLegacyTouchEnd(e) {
        if (this.activeMode !== 'legacy' || !this.legacySheetState.isDragging || !this.activeWindow) return;
        
        this.legacySheetState.isDragging = false;
        
        // Clear the live drag styles so CSS can handle the smooth snap animation
        this.activeWindow.style.transition = '';
        this.activeWindow.style.transform = ''; 
        
        // Determine how far the user physically dragged it
        const deltaY = this.legacySheetState.currentTranslateY - this.legacySheetState.startTranslateY;

        // --- SNAPPING LOGIC ---
        // Pulling up/down brings the two phases back and forth into one another.
        // We never close just because the sheet was pulled down from expanded;
        // closing is reserved for a deliberate large pull from the peek state.
        if (this.legacySheetState.currentState === 'peek') {
            if (deltaY < -40) {
                // Swiped UP -> grow peek into the full window
                this.setLegacySheetState('expanded');
            } else if (deltaY > 140) {
                // Deliberate large swipe DOWN from peek -> close the window
                this.closeActiveWindow();
            } else {
                // Not far enough -> snap back to peek
                this.setLegacySheetState('peek');
            }
        } else if (this.isSimpleSheetExpandedOnly()) {
            // iPad: there is no peek bar to collapse into, so a deliberate large
            // swipe DOWN dismisses the window; anything smaller snaps back.
            if (deltaY > 140) {
                this.closeActiveWindow();
            } else {
                this.setLegacySheetState('expanded');
            }
        } else { // Was in 'expanded' state
            if (deltaY > 60) {
                // Swiped DOWN -> shrink the full window back into the peek bar
                // (never close from expanded — pulling just brings peek back)
                this.setLegacySheetState('peek');
            } else {
                // Not far enough -> snap back to expanded
                this.setLegacySheetState('expanded');
            }
        }
    },


    /**
     * [MODIFIED] Closes whichever UI is active.
     */
    closeActiveWindow(force = false) {
        if (this.contentObserver) this.contentObserver.disconnect();
        
        if (this.closeTimer) {
            clearTimeout(this.closeTimer);
            this.closeTimer = null;
        }
        
        if (window.activePfdUpdateInterval) {
             clearInterval(window.activePfdUpdateInterval);
             window.activePfdUpdateInterval = null;
        }

        // Show HUD controls again
        const hudControls = document.getElementById('mobile-hud-controls');
        if (hudControls) hudControls.style.opacity = '1';

        const animationDuration = force ? 0 : 500;
        
        // --- Fork the teardown logic ---
        if (this.activeMode === 'hud') {
            this.teardownHudView(force, animationDuration);
        } else {
            this.teardownLegacySheetView(force, animationDuration);
        }
    },

teardownLegacySheetView(force, duration) {
        const overlayToRemove = this.overlayEl;
        const sheetToClose = this.activeWindow;
        
        // Remove document listeners
        document.removeEventListener('touchmove', this.boundLegacyTouchMove);
        document.removeEventListener('touchend', this.boundLegacyTouchEnd);
        document.removeEventListener('touchcancel', this.boundLegacyTouchEnd);
        
        const resetState = () => {
            this.activeWindow = null;
            this.overlayEl = null;
            this.activeMode = 'legacy'; // Reset to default
            this.legacySheetState.isDragging = false;
        };

        const cleanupSheetDOM = () => {
             if (sheetToClose) {
                sheetToClose.style.display = 'none';
                sheetToClose.classList.remove('mobile-legacy-sheet', 'visible', 'peek');
                
                try {
                    // 1. Remove the universal floating handle
                    const universalHandle = sheetToClose.querySelector('.universal-handle');
                    if (universalHandle) universalHandle.remove();
                    
                    // 2. Remove the padding we added to the overview panel
                    const overviewPanel = sheetToClose.querySelector('.aircraft-overview-panel');
                    if (overviewPanel) {
                        overviewPanel.style.paddingTop = '';
                    }
                } catch (e) {
                    console.warn("Mobile UI: Error cleaning up legacy sheet DOM", e);
                }
            }
        };

        if (force) {
            overlayToRemove?.remove();
            cleanupSheetDOM();
            this.restoreMapControls();
            resetState();
        } else {
            // Animate out
            this.setLegacySheetState('closed');
            
            this.closeTimer = setTimeout(() => {
                overlayToRemove?.remove();
                cleanupSheetDOM();
                this.restoreMapControls();
                
                if (this.activeWindow === sheetToClose) {
                    resetState();
                }
                this.closeTimer = null;
            }, duration);
        }
    },

    /**
     * [NEW] Teardown logic for HUD mode.
     */
    teardownHudView(force, duration) {
        
        const cleanupHudDOM = () => {
             if (this.activeWindow && this.topWindowEl && this.miniIslandEl && this.peekIslandEl && this.expandedIslandEl) {
                try {
                    const topOverviewPanel = this.topWindowEl.querySelector('.aircraft-overview-panel');
                    const mainFlightContent = this.expandedIslandEl.querySelector('.unified-display-main-content');
                    const tabContainer = this.expandedIslandEl.querySelector('.ac-info-window-tabs');
                    const clonedFlightContent = this.peekIslandEl.querySelector('.unified-display-main-content');
                    
                    if (topOverviewPanel) this.activeWindow.appendChild(topOverviewPanel);
                    if (mainFlightContent) this.activeWindow.appendChild(mainFlightContent);
                    
                    // [FIX] Safe prepend for tabs
                    if (tabContainer) {
                        const contentContainer = this.activeWindow.querySelector('.info-window-content');
                        if (contentContainer) contentContainer.prepend(tabContainer);
                        else this.activeWindow.prepend(tabContainer); // Fallback
                    }
                    
                    clonedFlightContent?.remove();
                } catch (e) {
                     console.warn("Mobile UI: Error cleaning up HUD DOM", e);
                }
            }
        };

        document.removeEventListener('touchend', this.boundHudTouchEnd);

        const overlayToRemove = this.overlayEl;
        const topWindowToRemove = this.topWindowEl;
        const miniIslandToRemove = this.miniIslandEl;
        const peekIslandToRemove = this.peekIslandEl;
        const expandedIslandToRemove = this.expandedIslandEl;

        const resetState = () => {
            this.activeWindow = null;
            this.contentObserver = null;
            this.topWindowEl = null;
            this.overlayEl = null;
            this.miniIslandEl = null;
            this.peekIslandEl = null;
            this.expandedIslandEl = null;
            this.drawerState = 0;
            this.swipeState.isDragging = false;
        };

        if (force) {
            cleanupHudDOM();
            
            overlayToRemove?.remove();
            topWindowToRemove?.remove();
            miniIslandToRemove?.remove();
            peekIslandToRemove?.remove();
            expandedIslandToRemove?.remove();
            
            this.restoreMapControls();
            resetState();
        } else {
            if (overlayToRemove) overlayToRemove.classList.remove('visible');
            if (topWindowToRemove) topWindowToRemove.classList.remove('visible');
            if (miniIslandToRemove) miniIslandToRemove.classList.remove('island-active');
            if (peekIslandToRemove) peekIslandToRemove.classList.remove('island-active');
            if (expandedIslandToRemove) expandedIslandToRemove.classList.remove('island-active');

            this.closeTimer = setTimeout(() => {
                cleanupHudDOM();
                
                overlayToRemove?.remove();
                topWindowToRemove?.remove();
                miniIslandToRemove?.remove();
                peekIslandToRemove?.remove();
                expandedIslandToRemove?.remove();
                
                this.restoreMapControls();

                if (this.topWindowEl === topWindowToRemove) {
                    resetState();
                }
                this.closeTimer = null;
            }, duration);
        }
    }
};

/**
 * Initialize the Mobile UI Handler when the DOM is ready.
 */
document.addEventListener('DOMContentLoaded', () => {
    MobileUIHandler.init();
    window.MobileUIHandler = MobileUIHandler; // Make it globally accessible
});