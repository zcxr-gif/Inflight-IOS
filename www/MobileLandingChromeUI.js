/**
 * MobileLandingChromeUI.js
 *
 * iOS-native styling for the LandingUI top header and bottom tab bar.
 * Lives outside landingUI.js so the web build is untouched — this module
 * only injects styles once a mobile viewport is detected and is loaded by
 * landingUI.js#applyMobileOptimizations.
 *
 * The styles in this file are written with higher specificity than the
 * mobile rules already embedded in landingUI.js so they reliably win the
 * cascade without requiring landingUI.js to be edited beyond the import.
 */

export const MobileLandingChromeUI = {
    _injected: false,

    init() {
        if (this._injected) return;
        if (typeof window === 'undefined' || window.innerWidth > 768) return;

        this._injectStyles();
        this._injected = true;
    },

    _injectStyles() {
        const css = `
        @media (max-width: 768px) {
            /* =========================================================
               iOS NATIVE CHROME — TOP HEADER
               Single frosted navigation bar pinned under the status bar.
               Search fills the width; profile orb sits trailing while idle,
               and Cancel slides in over it during the search state.
               ========================================================= */
            #inflight-tactical-ui .tactical-header {
                position: fixed !important;
                top: 0 !important;
                left: 0 !important;
                right: 0 !important;
                width: 100% !important;
                height: auto !important;
                min-height: calc(env(safe-area-inset-top, 0px) + 56px) !important;
                padding: calc(env(safe-area-inset-top, 0px) + 10px) 12px 10px 12px !important;
                background: rgba(10, 10, 11, 0.78) !important;
                -webkit-backdrop-filter: saturate(180%) blur(28px) !important;
                backdrop-filter: saturate(180%) blur(28px) !important;
                border-bottom: 0.5px solid rgba(255, 255, 255, 0.08) !important;
                display: flex !important;
                align-items: center !important;
                justify-content: flex-start !important;
                gap: 10px !important;
                pointer-events: none !important;
                z-index: 1500 !important;
                box-shadow: 0 1px 0 rgba(0, 0, 0, 0.2) !important;
            }
            #inflight-tactical-ui[data-theme="light"] .tactical-header {
                background: rgba(248, 248, 250, 0.82) !important;
                border-bottom-color: rgba(0, 0, 0, 0.08) !important;
            }

            /* Hide the server pill from the header — it lives in the tab bar */
            #inflight-tactical-ui .tactical-header .top-branding.dropdown {
                display: none !important;
            }

            #inflight-tactical-ui .top-right-actions {
                position: static !important;
                flex: 1 1 auto !important;
                width: auto !important;
                max-width: none !important;
                margin: 0 !important;
                padding: 0 !important;
                display: flex !important;
                align-items: center !important;
                justify-content: stretch !important;
                pointer-events: auto !important;
                background: transparent !important;
                border: none !important;
                box-shadow: none !important;
                -webkit-backdrop-filter: none !important;
                backdrop-filter: none !important;
            }

            /* The search field itself — iOS rounded rect */
            #inflight-tactical-ui .search-blade {
                position: relative !important;
                width: 100% !important;
                height: 38px !important;
                padding: 0 12px !important;
                margin-right: 50px !important; /* reserve room for profile orb */
                background: rgba(118, 118, 128, 0.22) !important;
                border: none !important;
                border-radius: 10px !important;
                display: flex !important;
                align-items: center !important;
                gap: 8px !important;
                box-shadow: none !important;
                transition: background-color 0.2s ease, margin 0.25s cubic-bezier(0.16,1,0.3,1) !important;
            }
            #inflight-tactical-ui[data-theme="light"] .search-blade {
                background: rgba(118, 118, 128, 0.12) !important;
            }
            #inflight-tactical-ui .search-blade .search-icon {
                color: rgba(235, 235, 245, 0.6) !important;
                font-size: 14px !important;
                flex: 0 0 auto !important;
            }
            #inflight-tactical-ui[data-theme="light"] .search-blade .search-icon {
                color: rgba(60, 60, 67, 0.6) !important;
            }
            #inflight-tactical-ui #blade-search-input {
                flex: 1 1 auto !important;
                min-width: 0 !important;
                width: auto !important;
                height: 100% !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 17px !important; /* iOS body size; >=16px prevents auto-zoom */
                font-weight: 400 !important;
                letter-spacing: -0.2px !important;
                color: #fff !important;
                background: transparent !important;
                border: none !important;
                outline: none !important;
                padding: 0 !important;
                -webkit-appearance: none !important;
                appearance: none !important;
            }
            #inflight-tactical-ui[data-theme="light"] #blade-search-input { color: #000 !important; }
            #inflight-tactical-ui #blade-search-input::placeholder {
                color: rgba(235, 235, 245, 0.5) !important;
                font-weight: 400 !important;
            }
            #inflight-tactical-ui[data-theme="light"] #blade-search-input::placeholder {
                color: rgba(60, 60, 67, 0.5) !important;
            }
            #inflight-tactical-ui .search-shortcut { display: none !important; }

            /* Inline clear button (the small ✕) */
            #inflight-tactical-ui .search-clear-btn {
                display: none;
                background: none !important;
                border: none !important;
                padding: 0 !important;
                margin: 0 !important;
                color: rgba(235, 235, 245, 0.5) !important;
                font-size: 16px !important;
                line-height: 1 !important;
                flex: 0 0 auto !important;
                cursor: pointer;
            }
            #inflight-tactical-ui .search-blade.has-text .search-clear-btn { display: block !important; }

            /* Profile orb — trailing edge of the nav bar */
            #inflight-tactical-ui .auth-nexus {
                position: fixed !important;
                top: calc(env(safe-area-inset-top, 0px) + 10px) !important;
                right: 12px !important;
                left: auto !important;
                bottom: auto !important;
                width: 38px !important;
                height: 38px !important;
                z-index: 1601 !important;
                pointer-events: auto !important;
                transition: opacity 0.2s ease !important;
            }
            #inflight-tactical-ui .auth-nexus .orb-btn {
                width: 38px !important;
                height: 38px !important;
                border-radius: 50% !important;
                background: rgba(118, 118, 128, 0.22) !important;
                border: none !important;
                color: #fff !important;
                font-size: 15px !important;
                box-shadow: none !important;
                display: grid !important;
                place-items: center !important;
                transition: transform 0.15s ease, background-color 0.15s ease !important;
            }
            #inflight-tactical-ui[data-theme="light"] .auth-nexus .orb-btn {
                background: rgba(118, 118, 128, 0.12) !important;
                color: #000 !important;
            }
            #inflight-tactical-ui .auth-nexus .orb-btn:active {
                transform: scale(0.92) !important;
                background: rgba(118, 118, 128, 0.36) !important;
            }

            /* Cancel button — slides in during active search */
            #inflight-tactical-ui .search-cancel-btn {
                display: block !important;
                position: fixed !important;
                top: calc(env(safe-area-inset-top, 0px) + 10px) !important;
                right: 12px !important;
                height: 38px !important;
                padding: 0 4px !important;
                background: none !important;
                border: none !important;
                color: #0a84ff !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 17px !important;
                font-weight: 400 !important;
                letter-spacing: -0.2px !important;
                cursor: pointer;
                opacity: 0 !important;
                pointer-events: none !important;
                transform: translateX(8px) !important;
                transition: opacity 0.2s ease, transform 0.2s ease !important;
                z-index: 1602 !important;
            }
            #inflight-tactical-ui.mobile-search-active .search-cancel-btn {
                opacity: 1 !important;
                pointer-events: auto !important;
                transform: translateX(0) !important;
            }
            #inflight-tactical-ui.mobile-search-active .auth-nexus {
                opacity: 0 !important;
                pointer-events: none !important;
            }
            /* When searching, the field can expand into the profile/cancel slot */
            #inflight-tactical-ui.mobile-search-active .search-blade,
            #inflight-tactical-ui .search-blade:focus-within {
                margin-right: 62px !important;
                background: rgba(118, 118, 128, 0.28) !important;
            }

            /* Results sheet — full-bleed under the nav bar */
            #inflight-tactical-ui .search-results-dropdown {
                position: fixed !important;
                top: calc(env(safe-area-inset-top, 0px) + 60px) !important;
                left: 0 !important;
                right: 0 !important;
                width: 100vw !important;
                height: calc(100dvh - env(safe-area-inset-top, 0px) - 60px) !important;
                max-height: none !important;
                border: none !important;
                border-radius: 0 !important;
                padding: 0 0 calc(env(safe-area-inset-bottom, 0px) + 16px) !important;
                background: rgba(10, 10, 11, 0.96) !important;
                -webkit-backdrop-filter: blur(20px) !important;
                backdrop-filter: blur(20px) !important;
                box-shadow: none !important;
                -webkit-overflow-scrolling: touch !important;
                overscroll-behavior: contain !important;
            }
            #inflight-tactical-ui[data-theme="light"] .search-results-dropdown {
                background: rgba(248, 248, 250, 0.98) !important;
            }
            #inflight-tactical-ui .blade-results-header {
                position: sticky !important;
                top: 0 !important;
                z-index: 1 !important;
                background: inherit !important;
                padding: 16px 16px 6px !important;
                font-size: 11px !important;
                font-weight: 600 !important;
                text-transform: uppercase !important;
                letter-spacing: 0.6px !important;
                color: rgba(235, 235, 245, 0.6) !important;
            }
            #inflight-tactical-ui[data-theme="light"] .blade-results-header {
                color: rgba(60, 60, 67, 0.6) !important;
            }
            #inflight-tactical-ui .premium-result-item {
                min-height: 60px !important;
                padding: 10px 16px !important;
                gap: 14px !important;
                margin: 0 !important;
                border-radius: 0 !important;
                border-bottom: 0.5px solid rgba(255, 255, 255, 0.08) !important;
            }
            #inflight-tactical-ui[data-theme="light"] .premium-result-item {
                border-bottom-color: rgba(0, 0, 0, 0.08) !important;
            }
            #inflight-tactical-ui .premium-result-item:active {
                background: rgba(255, 255, 255, 0.06) !important;
            }

            /* =========================================================
               iOS NATIVE CHROME — BOTTOM TAB BAR
               Floating pill of glass; safe-area aware; SF-style icons +
               labels stacked. Avoids the small, cramped look of round
               orbs by giving each tab a real touch target.
               ========================================================= */
            #inflight-tactical-ui .utility-nexus {
                position: fixed !important;
                left: 50% !important;
                right: auto !important;
                top: auto !important;
                bottom: calc(env(safe-area-inset-bottom, 0px) + 12px) !important;
                transform: translateX(-50%) !important;
                width: auto !important;
                max-width: calc(100vw - 24px) !important;
                pointer-events: none !important;
                z-index: 1500 !important;
                transition: transform 0.32s cubic-bezier(0.16,1,0.3,1), opacity 0.2s ease !important;
            }

            #inflight-tactical-ui .orb-row {
                display: flex !important;
                align-items: stretch !important;
                justify-content: center !important;
                gap: 2px !important;
                padding: 6px !important;
                background: rgba(28, 28, 30, 0.72) !important;
                -webkit-backdrop-filter: saturate(180%) blur(30px) !important;
                backdrop-filter: saturate(180%) blur(30px) !important;
                border: 0.5px solid rgba(255, 255, 255, 0.1) !important;
                border-radius: 26px !important;
                box-shadow:
                    0 1px 0 rgba(255, 255, 255, 0.06) inset,
                    0 14px 36px rgba(0, 0, 0, 0.55) !important;
                pointer-events: auto !important;
            }
            #inflight-tactical-ui[data-theme="light"] .orb-row {
                background: rgba(248, 248, 250, 0.82) !important;
                border-color: rgba(0, 0, 0, 0.08) !important;
                box-shadow:
                    0 1px 0 rgba(255, 255, 255, 0.7) inset,
                    0 14px 36px rgba(0, 0, 0, 0.18) !important;
            }

            /* Reveal the mobile-only Server tab */
            #inflight-tactical-ui .mobile-only-tab { display: block !important; }
            #inflight-tactical-ui .nexus-orb-wrapper { position: relative !important; }

            /* Each tab — icon stacked over a small SF-style label */
            #inflight-tactical-ui .orb-row .orb-btn {
                position: relative !important;
                width: 68px !important;
                height: auto !important;
                min-height: 50px !important;
                padding: 7px 4px 6px !important;
                border-radius: 18px !important;
                background: transparent !important;
                border: none !important;
                box-shadow: none !important;
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                justify-content: center !important;
                gap: 3px !important;
                color: rgba(235, 235, 245, 0.62) !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 18px !important;
                transition: background-color 0.15s ease, color 0.15s ease, transform 0.15s ease !important;
                -webkit-tap-highlight-color: transparent !important;
            }
            #inflight-tactical-ui[data-theme="light"] .orb-row .orb-btn {
                color: rgba(60, 60, 67, 0.7) !important;
            }
            #inflight-tactical-ui .orb-row .orb-btn:hover,
            #inflight-tactical-ui .orb-row .orb-btn:active {
                transform: none !important;
                background: rgba(255, 255, 255, 0.06) !important;
                color: #fff !important;
            }
            #inflight-tactical-ui[data-theme="light"] .orb-row .orb-btn:hover,
            #inflight-tactical-ui[data-theme="light"] .orb-row .orb-btn:active {
                background: rgba(0, 0, 0, 0.05) !important;
                color: #000 !important;
            }
            #inflight-tactical-ui .orb-row .orb-btn i {
                font-size: 18px !important;
                line-height: 1 !important;
            }
            #inflight-tactical-ui .orb-row .tab-label {
                display: block !important;
                font-size: 10px !important;
                font-weight: 500 !important;
                letter-spacing: 0.1px !important;
                line-height: 1.1 !important;
                margin-top: 2px !important;
            }
            #inflight-tactical-ui .orb-row .active-pulse-dot {
                position: absolute !important;
                top: 6px !important;
                right: 12px !important;
                bottom: auto !important;
                left: auto !important;
                width: 6px !important;
                height: 6px !important;
                border-radius: 50% !important;
                background: #0a84ff !important;
                box-shadow: 0 0 8px rgba(10, 132, 255, 0.7) !important;
            }

            /* Weather submenu — popover above the Weather tab */
            #inflight-tactical-ui .weather-nexus-container {
                position: relative !important;
                flex-direction: column !important;
                gap: 0 !important;
            }
            #inflight-tactical-ui .weather-spread {
                position: absolute !important;
                bottom: calc(100% + 10px) !important;
                left: 50% !important;
                transform: translateX(-50%) translateY(8px) !important;
                display: flex !important;
                flex-direction: column !important;
                gap: 4px !important;
                padding: 6px !important;
                background: rgba(28, 28, 30, 0.92) !important;
                -webkit-backdrop-filter: saturate(180%) blur(30px) !important;
                backdrop-filter: saturate(180%) blur(30px) !important;
                border: 0.5px solid rgba(255, 255, 255, 0.1) !important;
                border-radius: 18px !important;
                box-shadow: 0 10px 30px rgba(0, 0, 0, 0.55) !important;
                opacity: 0 !important;
                visibility: hidden !important;
                pointer-events: none !important;
                transition: opacity 0.2s ease, transform 0.2s ease, visibility 0.2s !important;
                z-index: 1600 !important;
            }
            #inflight-tactical-ui[data-theme="light"] .weather-spread {
                background: rgba(248, 248, 250, 0.95) !important;
                border-color: rgba(0, 0, 0, 0.08) !important;
            }
            #inflight-tactical-ui .weather-nexus-container.expanded .weather-spread {
                opacity: 1 !important;
                visibility: visible !important;
                pointer-events: auto !important;
                transform: translateX(-50%) translateY(0) !important;
            }
            #inflight-tactical-ui .spread-opt {
                display: flex !important;
                align-items: center !important;
                gap: 10px !important;
                width: 100% !important;
                min-width: 140px !important;
                padding: 8px 12px !important;
                background: transparent !important;
                border: none !important;
                border-radius: 12px !important;
                color: rgba(235, 235, 245, 0.85) !important;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif !important;
                font-size: 14px !important;
                font-weight: 500 !important;
                text-align: left !important;
                transition: background-color 0.15s ease !important;
            }
            #inflight-tactical-ui[data-theme="light"] .spread-opt {
                color: #000 !important;
            }
            #inflight-tactical-ui .spread-opt i {
                font-size: 14px !important;
                width: 18px !important;
                text-align: center !important;
                color: rgba(235, 235, 245, 0.6) !important;
            }
            #inflight-tactical-ui[data-theme="light"] .spread-opt i {
                color: rgba(60, 60, 67, 0.6) !important;
            }
            #inflight-tactical-ui .spread-opt:active {
                background: rgba(255, 255, 255, 0.08) !important;
            }
            #inflight-tactical-ui .spread-opt.active {
                background: rgba(10, 132, 255, 0.18) !important;
                color: #0a84ff !important;
            }
            #inflight-tactical-ui .spread-opt.active i { color: #0a84ff !important; }
            #inflight-tactical-ui .spread-label {
                display: inline-block !important;
                font-size: 14px !important;
                font-weight: 500 !important;
            }

            /* Hide the tab bar (and profile) while the search is active or a
               detail sheet is open — same hooks landingUI.js already toggles. */
            #inflight-tactical-ui.mobile-search-active .utility-nexus,
            #sector-ops-map-fullscreen:has(.mobile-island-bottom.island-active) .utility-nexus {
                opacity: 0 !important;
                transform: translateX(-50%) translateY(160%) !important;
                pointer-events: none !important;
            }
        }

        /* Extra breathing room for older / smaller iPhones (SE-class) */
        @media (max-width: 380px) {
            #inflight-tactical-ui .orb-row .orb-btn {
                width: 60px !important;
                padding: 6px 2px 5px !important;
            }
            #inflight-tactical-ui .orb-row .tab-label { font-size: 9.5px !important; }
        }
        `;

        const styleId = 'mobile-landing-chrome-ui-css';
        const existing = document.getElementById(styleId);
        if (existing) existing.remove();

        const style = document.createElement('style');
        style.id = styleId;
        style.textContent = css;
        // Append last so we win same-specificity cascades against landingUI.js
        document.head.appendChild(style);
    },
};

if (typeof window !== 'undefined') {
    window.MobileLandingChromeUI = MobileLandingChromeUI;
}
