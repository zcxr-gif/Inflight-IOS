const MobileUIHandler = {
    // --- CONFIGURATION ---
    CONFIG: {
        breakpoint: 992, // The max-width in pixels to trigger mobile view
        defaultMode: 'legacy', // [UPDATED] Default is now 'legacy' sheet instead of HUD
        legacyPeekHeight: 280, // Height of the "peek" state for legacy sheet
    },

    // --- STATE ---
    isMobile: () => window.innerWidth <= MobileUIHandler.CONFIG.breakpoint,
    activeWindow: null, // The *original* hidden info window
    activeMode: 'legacy', // [UPDATED] Defaults to legacy
    topWindowEl: null, // HUD Mode: Top window
    overlayEl: null, // Shared: Overlay
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
     * and clears any inline styles that were set.
     */
    restoreMapControls() {
        const burgerMenu = document.getElementById('mobile-sidebar-toggle');
        // Find the map toolbar by finding the parent of one of its buttons
        const mapToolbar = document.getElementById('toolbar-toggle-panel-btn')?.parentElement;
        const searchBar = document.getElementById('sector-ops-search-container');
        
        // Revert to stylesheet defaults
        if (burgerMenu) burgerMenu.style.display = ''; 
        if (mapToolbar) mapToolbar.style.display = '';
        if (searchBar) searchBar.style.display = '';
        
        // --- [FIX] Remove 'mobile-ui-active' class from the map container ---
        const mapContainer = document.getElementById('sector-ops-map-fullscreen');
        if (mapContainer) mapContainer.classList.remove('mobile-ui-active');
        // --- [END FIX] ---
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
        
        console.log("Mobile UI Handler (HUD Rehaul v8.0 / Legacy Mode) Initialized.");
    },

    /**
     * [MODIFIED] Injects all the CSS for the new HUD-themed floating islands.
     * Includes improved styling for the mobile search bar.
     */
    injectMobileStyles() {
        const styleId = 'mobile-sector-ops-styles';
        if (document.getElementById(styleId)) document.getElementById(styleId).remove();

        const css = `
            :root {
                --hud-bg: rgba(10, 15, 28, 0.85);
                --hud-blur: 15px;
                --hud-top-window-height: 50px;
                --hud-border: rgba(0, 168, 255, 0.3);
                --hud-accent: #00a8ff;
                --hud-glow: 0 0 15px rgba(0, 168, 255, 0.5);
                
                --drawer-peek-content-height: 200px;
                --island-bottom-margin: env(safe-area-inset-bottom, 15px);
                --island-side-margin: 10px;

                /* --- [NEW] Legacy Sheet Config --- */
                --legacy-peek-height: ${this.CONFIG.legacyPeekHeight}px;
                --legacy-top-offset: env(safe-area-inset-top, 15px);
            }
            
            /* --- [FIX] Target the map container instead of 'view-rosters' --- */
            #sector-ops-map-fullscreen.mobile-ui-active {
                position: relative;
                overflow: hidden;
            }

            /* ====================================================================
            --- [START] UPDATED: Search Bar Mobile Positioning (Glass Pill) ---
            ==================================================================== */
            @media (max-width: ${this.CONFIG.breakpoint}px) {
                #sector-ops-search-container {
                    position: absolute !important;
                    /* Sits lower to clear the notch/status bar gracefully */
                    top: calc(env(safe-area-inset-top, 20px) + 10px) !important; 
                    left: 50% !important;
                    transform: translateX(-50%) !important;
                    /* Slightly narrower than full width for the floating look */
                    width: calc(100% - 32px) !important; 
                    max-width: 450px !important;
                    z-index: 1030 !important;
                    pointer-events: auto !important;
                }

                #sector-ops-search-container .search-bar-container {
                    display: flex !important;
                    align-items: center !important;
                    /* Darker, richer background for better contrast */
                    background: rgba(15, 20, 35, 0.90) !important;
                    backdrop-filter: blur(20px) !important;
                    -webkit-backdrop-filter: blur(20px) !important;
                    
                    border: 1px solid rgba(255, 255, 255, 0.1) !important;
                    /* Full pill shape */
                    border-radius: 50px !important; 
                    
                    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5) !important;
                    padding: 0 6px !important; /* Padding for the icons */
                    height: 50px !important;
                    transition: all 0.3s ease !important;
                }
                
                /* Focus state glow */
                #sector-ops-search-container:focus-within .search-bar-container {
                    border-color: var(--hud-accent) !important;
                    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.6), 0 0 15px rgba(0, 168, 255, 0.2) !important;
                }

                /* Search Icon */
                #sector-ops-search-container .search-icon-label {
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                    width: 40px !important;
                    height: 40px !important;
                    margin: 0 !important;
                    color: var(--hud-accent) !important;
                    opacity: 0.8;
                }

                /* Input Field */
                #sector-ops-search-input {
                    flex-grow: 1 !important;
                    height: 100% !important;
                    background: transparent !important;
                    border: none !important;
                    color: #fff !important;
                    font-family: 'Segoe UI', sans-serif !important;
                    font-weight: 500 !important;
                    font-size: 16px !important; /* Prevents iOS zoom */
                    padding: 0 8px !important;
                    outline: none !important;
                    border-radius: 0 !important;
                    -webkit-appearance: none !important;
                }
                
                #sector-ops-search-input::placeholder {
                    color: rgba(255, 255, 255, 0.4) !important;
                }

                /* Clear Button */
                #sector-ops-search-clear {
                    background: rgba(255, 255, 255, 0.1) !important;
                    color: #fff !important;
                    border: none !important;
                    border-radius: 50% !important;
                    width: 28px !important;
                    height: 28px !important;
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                    margin-right: 6px !important;
                    cursor: pointer !important;
                    font-size: 0.9rem !important;
                }
                
                /* Results Dropdown - Floating Card Style */
                #search-results-dropdown {
                    margin-top: 12px !important; /* Gap between bar and results */
                    width: 100% !important;
                    background: rgba(15, 20, 35, 0.95) !important;
                    backdrop-filter: blur(25px) !important;
                    -webkit-backdrop-filter: blur(25px) !important;
                    border: 1px solid rgba(255, 255, 255, 0.08) !important;
                    border-radius: 16px !important;
                    overflow: hidden !important;
                    box-shadow: 0 15px 50px rgba(0, 0, 0, 0.6) !important;
                    max-height: 60vh !important;
                    overflow-y: auto !important;
                }
                
                /* Result Items */
                .search-result-item {
                    padding: 14px 20px !important;
                    border-bottom: 1px solid rgba(255, 255, 255, 0.05) !important;
                    display: flex !important;
                    align-items: center !important;
                    gap: 15px !important;
                }
                
                .search-result-item i {
                    color: var(--hud-accent) !important;
                    font-size: 1.1rem !important;
                    opacity: 0.8;
                }
                
                .search-result-info strong {
                    font-size: 1rem !important;
                    color: #fff !important;
                }
                
                .search-result-info small {
                    font-size: 0.85rem !important;
                    color: #9fa8da !important;
                }
                
                .search-result-item:active {
                    background: rgba(0, 168, 255, 0.15) !important;
                }
            }
            /* ====================================================================
            --- [END] Search Bar Mobile Positioning ---
            ==================================================================== */

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

            /* This class is applied to the original info-window */
            .mobile-legacy-sheet {
                /* --- [CRITICAL] Override desktop styles --- */
                display: flex !important; /* Use flex (from desktop) */
                position: absolute !important;
                top: auto !important; /* Unset top */
                bottom: 0 !important;
                left: 0 !important;
                right: 0 !important;
                width: 100% !important;
                max-width: 100% !important;
                max-height: calc(100vh - var(--legacy-top-offset)) !important;
                z-index: 1045 !important;
                border-radius: 16px 16px 0 0 !important;
                box-shadow: 0 -5px 30px rgba(0,0,0,0.4) !important;
                
                /* --- Animation & State --- */
                will-change: transform;
                /* Start off-screen */
                transform: translateY(100%); 
                transition: transform 0.45s cubic-bezier(0.16, 1, 0.3, 1);
            }

            /* "Peek" State (Default visible state) */
            .mobile-legacy-sheet.visible.peek {
                transform: translateY(calc(100% - var(--legacy-peek-height)));
            }

            /* "Expanded" State */
            .mobile-legacy-sheet.visible:not(.peek) {
                transform: translateY(var(--hud-top-window-height));
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

            /* --- [UPDATED] Specific styling for SIMPLE MODE handle (Seamless Overlay) --- */
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
            .mobile-legacy-sheet .aircraft-overview-panel {
                /* The handle will wrap this */
            }
            .mobile-legacy-sheet .route-summary-overlay {
                /* The handle will wrap this */
            }

            @media (max-width: ${this.CONFIG.breakpoint}px) {
                #aircraft-info-window:not(.mobile-legacy-sheet), 
                #airport-info-window {
                    display: none !important;
                }
            }
        `;
        const style = document.createElement('style');
        style.id = styleId;
        style.type = 'text/css';
        style.appendChild(document.createTextNode(css));
        document.head.appendChild(style);
    },

    /**
     * [MODIFIED] Intercepts the window open command.
     * This now acts as a ROUTER, checking the user's preferred mode.
     * **NEW: Forces 'Legacy' mode if the Simple Flight Window is active.**
     */
    openWindow(windowElement) {
        if (!this.isMobile()) return;

        if (this.activeWindow) {
            this.closeActiveWindow(true); // 'true' = force close
        }

        // --- [FIX] Add 'mobile-ui-active' class to the correct map container ---
        const mapContainer = document.getElementById('sector-ops-map-fullscreen');
        if (mapContainer) mapContainer.classList.add('mobile-ui-active');
        // --- [END FIX] ---

        if (windowElement.id === 'aircraft-info-window') {
            // --- Hide map controls ---
            const burgerMenu = document.getElementById('mobile-sidebar-toggle');
            const mapToolbar = document.getElementById('toolbar-toggle-panel-btn')?.parentElement;
            const searchBar = document.getElementById('sector-ops-search-container');
            
            if (burgerMenu) burgerMenu.style.display = 'none';
            if (mapToolbar) mapToolbar.style.display = 'none';
            if (searchBar) searchBar.style.display = 'none';

            // --- [NEW] The Router Logic ---
            // 1. Check for Simple Mode (iframe existence)
            const isSimpleMode = !!windowElement.querySelector('#simple-flight-window-frame');

            // 2. Get user preference (defaulting to legacy)
            let userMode = localStorage.getItem('mobileDisplayMode') || this.CONFIG.defaultMode;

            // 3. FORCE Legacy mode if Simple Flight Window is active
            if (isSimpleMode) {
                userMode = 'legacy';
                // Optional: We can update local storage here if we want the preference to persist
                // even after they switch simple mode off, or just override it temporarily.
                // For now, we just override the active session variable.
            }

            this.activeMode = userMode;
            this.activeWindow = windowElement;

            if (userMode === 'legacy') {
                // --- Path 1: "Legacy Sheet" Mode ---
                this.createLegacySheetUI();
                this.observeOriginalWindow(windowElement);

            } else {
                // --- Path 2: "HUD" Mode ---
                this.createSplitViewUI(); // Build our new island containers
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
        
        // 2. Add class to the *original* window
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
        
        this.contentObserver = new MutationObserver((mutationsList, obs) => {
            const mainContent = windowElement.querySelector('.unified-display-main-content');
            const attitudeGroup = mainContent?.querySelector('#attitude_group');
            
            // --- [NEW CHECK] For Simple Window (Iframe) ---
            const simpleIframe = windowElement.querySelector('#simple-flight-window-frame');

            // Condition 1: Standard PFD is built
            const isStandardReady = mainContent && attitudeGroup && attitudeGroup.dataset.initialized === 'true';
            // Condition 2: Simple Iframe is present
            const isSimpleReady = !!simpleIframe;
            
            if (isStandardReady || isSimpleReady) {
                
                // --- [NEW] Router ---
                if (this.activeMode === 'legacy') {
                    // 1. Populate first (while off-screen)
                    this.populateLegacySheet(windowElement);
                    
                    // 2. NOW, animate it in
                    if (this.activeWindow) {
                        setTimeout(() => {
                            this.activeWindow.classList.add('visible', 'peek');
                            this.legacySheetState.currentState = 'peek';
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
                
                obs.disconnect();
                this.contentObserver = null;
            }
        });
        
        this.contentObserver.observe(windowElement, { 
            childList: true, 
            subtree: true,
            attributes: true
        });
    },

    /**
     * [MODIFIED] Wires up interactions for the "Legacy Sheet" mode.
     * Now handles both STANDARD (wrap content) and SIMPLE (prepend handle) modes.
     */
    populateLegacySheet(sourceWindow) {
        // --- 1. Check for Simple Mode (Iframe) ---
        const simpleIframe = sourceWindow.querySelector('#simple-flight-window-frame');
        
        const handleWrapper = document.createElement('div');
        handleWrapper.className = 'legacy-sheet-handle';

        if (simpleIframe) {
            // --- SIMPLE MODE LOGIC ---
            // The iframe occupies the whole window.
            // We create a distinct "pill bar" handle and put it at the very top.
            handleWrapper.classList.add('simple-mode'); 
            
            // Insert handle at the top of the window
            sourceWindow.prepend(handleWrapper);
            
            // Ensure source window is relative so absolute handle positions correctly
            sourceWindow.style.position = 'relative'; // Should be redundant due to flex class but good for safety
            
        } else {
            // --- STANDARD MODE LOGIC ---
            const overviewPanel = sourceWindow.querySelector('.aircraft-overview-panel');
            const routeSummaryBar = sourceWindow.querySelector('.route-summary-overlay');

            if (overviewPanel && routeSummaryBar) {
                // Wrap the existing header elements with the handle
                sourceWindow.prepend(handleWrapper);
                handleWrapper.appendChild(overviewPanel);
                handleWrapper.appendChild(routeSummaryBar);
            } else {
                console.warn("Legacy Sheet UI: Could not find header elements for standard mode.");
            }
        }
        
        // Wire up interactions
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

    /**
     * [NEW] Wires up all interactions for the "Legacy Sheet" mode.
     */
    wireUpLegacySheetInteractions(sheetElement, handleElement) {
        
        handleElement.addEventListener('touchstart', this.handleLegacyTouchStart.bind(this), { passive: false });
        
        // [MODIFIED] Use document-level listeners for move and end
        document.addEventListener('touchmove', this.boundLegacyTouchMove, { passive: false });
        document.addEventListener('touchend', this.boundLegacyTouchEnd);
        document.addEventListener('touchcancel', this.boundLegacyTouchEnd);
        
        // --- Close Handlers ---
        if (this.overlayEl) {
            this.overlayEl.addEventListener('click', () => {
                if (this.legacySheetState.currentState === 'expanded') {
                    this.setLegacySheetState('peek');
                } else {
                    this.closeActiveWindow();
                }
            });
        }
        
        // --- [NEW] Stop drag from starting on button tap (in Standard Mode) ---
        const buttonContainer = sheetElement.querySelector('.overview-actions');
        if (buttonContainer) {
            buttonContainer.addEventListener('touchstart', (e) => {
                e.stopPropagation();
            }, { passive: true });
        }
        
        // Find desktop buttons (Standard Mode only usually)
        const closeBtn = sheetElement.querySelector('.aircraft-window-close-btn');
        const hideBtn = sheetElement.querySelector('.aircraft-window-hide-btn');
        
        if(closeBtn) {
            closeBtn.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                this.closeActiveWindow();
            });
        }
        if(hideBtn) {
            hideBtn.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
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

        // --- Re-wire desktop buttons ---
        this.topWindowEl.addEventListener('click', (e) => {
            const closeBtn = e.target.closest('.aircraft-window-close-btn');
            const hideBtn = e.target.closest('.aircraft-window-hide-btn');

            if (closeBtn) this.closeActiveWindow();
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
            }
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

        } else if (targetState === 'peek') {
            this.activeWindow.classList.add('visible', 'peek');
            if (this.overlayEl) this.overlayEl.classList.remove('visible');
            
            const peekY = window.innerHeight - this.CONFIG.legacyPeekHeight;
            this.legacySheetState.currentSheetY = peekY;

        } else if (targetState === 'closed') {
            this.activeWindow.classList.remove('visible', 'peek');
            if (this.overlayEl) this.overlayEl.classList.remove('visible');
            this.legacySheetState.currentSheetY = window.innerHeight + 100;
        }
    },

    // --- [HUD] Swipe Gesture Handlers ---
    handleHudTouchStart(e) {
        if (this.activeMode !== 'hud') return;
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
        
        const handle = e.target.closest('.legacy-sheet-handle');
        if (!handle) {
             this.legacySheetState.isDragging = false;
             return;
        }
        
        e.preventDefault();
        
        this.legacySheetState.isDragging = true;
        this.legacySheetState.touchStartY = e.touches[0].clientY;
        
        // Get the current computed Y position
        const rect = this.activeWindow.getBoundingClientRect();
        this.legacySheetState.currentSheetY = rect.top;
        this.legacySheetState.startSheetY = rect.top;
        
        this.activeWindow.style.transition = 'none'; // Allow live dragging
    },

    handleLegacyTouchMove(e) {
        if (this.activeMode !== 'legacy' || !this.legacySheetState.isDragging) return;
        
        e.preventDefault();
        const touchCurrentY = e.touches[0].clientY;
        let deltaY = touchCurrentY - this.legacySheetState.touchStartY;

        // Calculate new Y, but don't let it be dragged higher than the top stop
        const topStop = parseInt(getComputedStyle(document.documentElement)
        .getPropertyValue('--hud-top-window-height')) || 50;

        let newY = this.legacySheetState.startSheetY + deltaY;
        
        // Add resistance when dragging *above* the top stop
        if (newY < topStop) {
            const overdrag = topStop - newY;
            newY = topStop - (overdrag * 0.3); // Resistance
        }
        
        this.activeWindow.style.transform = `translateY(${newY}px)`;
        this.legacySheetState.currentSheetY = newY; // Store last position
    },

    handleLegacyTouchEnd(e) {
        if (this.activeMode !== 'legacy' || !this.legacySheetState.isDragging) return;
        
        this.legacySheetState.isDragging = false;
        
        const deltaY = this.legacySheetState.currentSheetY - this.legacySheetState.startSheetY;

        // Snap logic
        if (this.legacySheetState.currentState === 'peek') {
            if (deltaY < -100) { // Swiped up
                this.setLegacySheetState('expanded');
            } else if (deltaY > 100) { // Swiped down to close
                this.closeActiveWindow();
            } else { // Snap back
                this.setLegacySheetState('peek');
            }
        } else { // Was 'expanded'
            if (deltaY > 100) { // Swiped down
                this.setLegacySheetState('peek');
            } else { // Snap back
                this.setLegacySheetState('expanded');
            }
        }
        
        // Clear inline styles
        this.activeWindow.style.transition = '';
        this.activeWindow.style.transform = '';
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

        const animationDuration = force ? 0 : 500;
        
        // --- Fork the teardown logic ---
        if (this.activeMode === 'hud') {
            this.teardownHudView(force, animationDuration);
        } else {
            this.teardownLegacySheetView(force, animationDuration);
        }
    },

    /**
     * [NEW] Teardown logic for Legacy Sheet mode.
     */
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

        if (force) {
            overlayToRemove?.remove();
            if (sheetToClose) {
                sheetToClose.style.display = 'none';
                sheetToClose.classList.remove('mobile-legacy-sheet', 'visible', 'peek');
                
                // [MODIFIED] Handle cleanup: un-wrap OR remove custom handle
                const handle = sheetToClose.querySelector('.legacy-sheet-handle');
                if (handle) {
                    if (handle.classList.contains('simple-mode')) {
                        // Simple Mode: Just remove the bar
                        handle.remove();
                    } else {
                        // Standard Mode: Un-wrap content
                        const overview = sheetToClose.querySelector('.aircraft-overview-panel');
                        const routeBar = sheetToClose.querySelector('.route-summary-overlay');
                        if (overview) sheetToClose.prepend(overview);
                        if (routeBar) sheetToClose.insertBefore(routeBar, overview.nextSibling);
                        handle.remove();
                    }
                }
            }
            this.restoreMapControls();
            resetState();
        } else {
            // Animate out
            this.setLegacySheetState('closed');
            
            this.closeTimer = setTimeout(() => {
                overlayToRemove?.remove();
                if (sheetToClose) {
                    sheetToClose.style.display = 'none';
                    sheetToClose.classList.remove('mobile-legacy-sheet', 'peek');
                    
                    // [MODIFIED] Handle cleanup
                    const handle = sheetToClose.querySelector('.legacy-sheet-handle');
                    if (handle) {
                        if (handle.classList.contains('simple-mode')) {
                            handle.remove();
                        } else {
                            const overview = sheetToClose.querySelector('.aircraft-overview-panel');
                            const routeBar = sheetToClose.querySelector('.route-summary-overlay');
                            if (overview) sheetToClose.prepend(overview);
                            if (routeBar) sheetToClose.insertBefore(routeBar, overview.nextSibling);
                            handle.remove();
                        }
                    }
                }
                
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
        if (this.activeWindow && this.topWindowEl && this.miniIslandEl && this.peekIslandEl && this.expandedIslandEl) {
            const topOverviewPanel = this.topWindowEl.querySelector('.aircraft-overview-panel');
            const mainFlightContent = this.expandedIslandEl.querySelector('.unified-display-main-content');
            const tabContainer = this.expandedIslandEl.querySelector('.ac-info-window-tabs');
            const clonedFlightContent = this.peekIslandEl.querySelector('.unified-display-main-content');
            
            if (topOverviewPanel) this.activeWindow.appendChild(topOverviewPanel);
            if (mainFlightContent) this.activeWindow.appendChild(mainFlightContent);
            if (tabContainer) this.activeWindow.querySelector('.info-window-content').prepend(tabContainer);
            clonedFlightContent?.remove();
        }

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