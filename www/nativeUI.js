// nativeUI.js
// -----------------------------------------------------------------------------
// Native-iOS-styled feedback UI that replaces the old Toastify web toasts.
//
//   • InflightNativeUI.notify(message, type)  → a banner that slides down from
//     the top, styled like an iOS notification/alert (blur material, safe-area
//     aware, icon per type, tap / swipe-up to dismiss, auto-dismiss).
//   • InflightNativeUI.showOffline({ onRetry }) / hideOffline()  → a full "No
//     Internet Connection" page that slides up from the bottom when the map (or
//     the app) can't reach the network. Auto-hides when connectivity returns.
//
// Everything is self-contained: the CSS is injected once on first use and all
// helpers are mirrored onto `window` so non-module callers can reach them too.
// -----------------------------------------------------------------------------

const STYLE_ID = 'inflight-native-ui-styles';
const BANNER_HOST_ID = 'inflight-native-banner-host';
const OFFLINE_ID = 'inflight-native-offline';

// Per-type presentation. `title` mirrors how iOS banners lead with a bold line.
const TYPES = {
    error:   { title: 'Something went wrong', accent: '#ff453a', icon: 'exclamation' },
    warning: { title: 'Heads up',             accent: '#ff9f0a', icon: 'exclamation' },
    success: { title: 'Done',                 accent: '#30d158', icon: 'check' },
    info:    { title: 'Note',                  accent: '#0a84ff', icon: 'info' },
};

function iconSvg(kind) {
    // 24×24 stroke icons so they stay crisp at any size and need no icon font.
    switch (kind) {
        case 'check':
            return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
        case 'info':
            return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="11" x2="12" y2="16"/><circle cx="12" cy="7.5" r="0.6" fill="currentColor" stroke="none"/></svg>';
        case 'exclamation':
        default:
            return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="7" x2="12" y2="13"/><circle cx="12" cy="17" r="0.6" fill="currentColor" stroke="none"/></svg>';
    }
}

function wifiSlashSvg() {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">' +
        '<path d="M5 12.55a11 11 0 0 1 14.08-.03"/><path d="M1.42 9a16 16 0 0 1 6.9-4.28"/>' +
        '<path d="M22.58 9a16 16 0 0 0-6.9-4.28"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/>' +
        '<line x1="12" y1="20" x2="12.01" y2="20"/><line x1="2" y1="2" x2="22" y2="22"/></svg>';
}

function ensureStyles() {
    if (document.getElementById(STYLE_ID)) return;
    const css = `
    #${BANNER_HOST_ID} {
        position: fixed;
        top: 0; left: 0; right: 0;
        z-index: 2147483646;
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 10px;
        padding: calc(env(safe-area-inset-top, 0px) + 10px) 12px 0;
        pointer-events: none;
        font-family: -apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', Roboto, sans-serif;
    }
    .inf-banner {
        pointer-events: auto;
        width: 100%;
        max-width: 440px;
        display: flex;
        align-items: center;
        gap: 12px;
        padding: 12px 14px;
        border-radius: 18px;
        color: #f5f5f7;
        background: rgba(38, 40, 45, 0.72);
        -webkit-backdrop-filter: saturate(180%) blur(24px);
        backdrop-filter: saturate(180%) blur(24px);
        border: 0.5px solid rgba(255, 255, 255, 0.14);
        box-shadow: 0 12px 34px rgba(0, 0, 0, 0.42), 0 1px 0 rgba(255, 255, 255, 0.05) inset;
        transform: translateY(-140%);
        opacity: 0;
        transition: transform 420ms cubic-bezier(0.16, 1, 0.3, 1), opacity 260ms ease;
        will-change: transform, opacity;
        touch-action: pan-x;
    }
    .inf-banner.is-in { transform: translateY(0); opacity: 1; }
    .inf-banner.is-out { transform: translateY(-140%); opacity: 0; }
    .inf-banner__icon {
        flex: 0 0 auto;
        width: 34px; height: 34px;
        border-radius: 50%;
        display: flex; align-items: center; justify-content: center;
        color: #fff;
    }
    .inf-banner__icon svg { width: 20px; height: 20px; display: block; }
    .inf-banner__text { flex: 1 1 auto; min-width: 0; }
    .inf-banner__title {
        font-size: 14px; font-weight: 600; line-height: 1.25;
        letter-spacing: -0.01em;
    }
    .inf-banner__msg {
        font-size: 13.5px; line-height: 1.3; margin-top: 1px;
        color: rgba(235, 235, 245, 0.72);
        overflow-wrap: anywhere;
    }
    .inf-banner__grip {
        position: absolute; left: 50%; bottom: 5px;
        width: 34px; height: 4px; transform: translateX(-50%);
        border-radius: 2px; background: rgba(235, 235, 245, 0.28);
    }

    /* ---- No-Internet slide-up page ---------------------------------------- */
    #${OFFLINE_ID} {
        position: fixed; inset: 0;
        z-index: 2147483645;
        display: flex; align-items: flex-end;
        justify-content: center;
        pointer-events: none;
    }
    #${OFFLINE_ID} .inf-offline__scrim {
        position: absolute; inset: 0;
        background: rgba(0, 0, 0, 0.4);
        opacity: 0;
        transition: opacity 360ms ease;
    }
    #${OFFLINE_ID}.is-in .inf-offline__scrim { opacity: 1; }
    #${OFFLINE_ID} .inf-offline__sheet {
        position: relative;
        pointer-events: auto;
        width: 100%;
        max-width: 520px;
        box-sizing: border-box;
        padding: 26px 26px calc(env(safe-area-inset-bottom, 0px) + 26px);
        border-radius: 26px 26px 0 0;
        background: rgba(28, 30, 34, 0.9);
        -webkit-backdrop-filter: saturate(180%) blur(30px);
        backdrop-filter: saturate(180%) blur(30px);
        border-top: 0.5px solid rgba(255, 255, 255, 0.14);
        box-shadow: 0 -18px 50px rgba(0, 0, 0, 0.5);
        color: #f5f5f7;
        text-align: center;
        font-family: -apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', Roboto, sans-serif;
        transform: translateY(100%);
        transition: transform 460ms cubic-bezier(0.16, 1, 0.3, 1);
    }
    #${OFFLINE_ID}.is-in .inf-offline__sheet { transform: translateY(0); }
    .inf-offline__grip {
        width: 38px; height: 5px; border-radius: 3px;
        background: rgba(235, 235, 245, 0.28);
        margin: 0 auto 22px;
    }
    .inf-offline__icon {
        width: 76px; height: 76px; margin: 4px auto 18px;
        border-radius: 50%;
        display: flex; align-items: center; justify-content: center;
        color: #ff453a;
        background: rgba(255, 69, 58, 0.14);
    }
    .inf-offline__icon svg { width: 40px; height: 40px; }
    .inf-offline__title {
        font-size: 21px; font-weight: 700; letter-spacing: -0.02em;
        margin: 0 0 8px;
    }
    .inf-offline__body {
        font-size: 15px; line-height: 1.45;
        color: rgba(235, 235, 245, 0.68);
        margin: 0 auto 24px;
        max-width: 320px;
    }
    .inf-offline__retry {
        -webkit-appearance: none; appearance: none; border: none;
        width: 100%; max-width: 340px;
        padding: 15px 20px;
        border-radius: 15px;
        font-size: 16px; font-weight: 600;
        font-family: inherit;
        color: #fff;
        background: #0a84ff;
        cursor: pointer;
        transition: transform 120ms ease, opacity 120ms ease;
    }
    .inf-offline__retry:active { transform: scale(0.97); opacity: 0.9; }
    .inf-offline__spinner {
        display: inline-block; width: 17px; height: 17px;
        border: 2.5px solid rgba(255, 255, 255, 0.45);
        border-top-color: #fff; border-radius: 50%;
        vertical-align: -3px; margin-right: 8px;
        animation: inf-spin 0.7s linear infinite;
    }
    @keyframes inf-spin { to { transform: rotate(360deg); } }

    @media (prefers-reduced-motion: reduce) {
        .inf-banner, #${OFFLINE_ID} .inf-offline__sheet, #${OFFLINE_ID} .inf-offline__scrim {
            transition-duration: 0.001s !important;
        }
    }`;
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = css;
    document.head.appendChild(style);
}

function bannerHost() {
    let host = document.getElementById(BANNER_HOST_ID);
    if (!host) {
        host = document.createElement('div');
        host.id = BANNER_HOST_ID;
        host.setAttribute('role', 'status');
        host.setAttribute('aria-live', 'polite');
        (document.body || document.documentElement).appendChild(host);
    }
    return host;
}

/**
 * Show a native-iOS-style banner. Drop-in replacement for the old toast:
 * signature is (message, type) where type ∈ error|warning|success|info.
 */
export function notify(message, type = 'info', opts = {}) {
    if (!message || typeof document === 'undefined') return;
    try { ensureStyles(); } catch (_) { return; }

    const cfg = TYPES[type] || TYPES.info;
    const host = bannerHost();

    const el = document.createElement('div');
    el.className = 'inf-banner';
    el.innerHTML =
        `<div class="inf-banner__icon" style="background:${cfg.accent}">${iconSvg(cfg.icon)}</div>` +
        `<div class="inf-banner__text">` +
            `<div class="inf-banner__title">${cfg.title}</div>` +
            `<div class="inf-banner__msg"></div>` +
        `</div>` +
        `<div class="inf-banner__grip"></div>`;
    // Assign the message as text (never HTML) so caller strings can't inject markup.
    el.querySelector('.inf-banner__msg').textContent = String(message);
    host.appendChild(el);

    // Longer dwell for errors/warnings so they can actually be read.
    const duration = opts.duration != null
        ? opts.duration
        : (type === 'error' || type === 'warning') ? 4600 : 3200;

    let dismissed = false;
    let hideTimer = null;
    const remove = () => { try { el.remove(); } catch (_) {} };
    const dismiss = () => {
        if (dismissed) return;
        dismissed = true;
        clearTimeout(hideTimer);
        el.classList.remove('is-in');
        el.classList.add('is-out');
        el.addEventListener('transitionend', remove, { once: true });
        setTimeout(remove, 600); // fallback if transitionend is missed
    };

    // Swipe-up / tap to dismiss.
    let startY = null;
    el.addEventListener('touchstart', (e) => { startY = e.touches[0].clientY; }, { passive: true });
    el.addEventListener('touchmove', (e) => {
        if (startY == null) return;
        const dy = e.touches[0].clientY - startY;
        if (dy < -8) { el.style.transform = `translateY(${dy}px)`; el.style.opacity = String(Math.max(0, 1 + dy / 90)); }
    }, { passive: true });
    el.addEventListener('touchend', (e) => {
        const dy = (e.changedTouches[0]?.clientY ?? startY) - (startY ?? 0);
        startY = null;
        if (dy < -34) dismiss();
        else { el.style.transform = ''; el.style.opacity = ''; }
    });
    el.addEventListener('click', dismiss);

    // Enter on the next frame so the transition runs.
    requestAnimationFrame(() => requestAnimationFrame(() => el.classList.add('is-in')));
    hideTimer = setTimeout(dismiss, duration);

    return dismiss;
}

// -----------------------------------------------------------------------------
// No-Internet slide-up page
// -----------------------------------------------------------------------------
// App-supplied recovery hook (e.g. rebuild the map if it never loaded). It's
// invoked whenever connectivity is restored. Kept separate from showOffline so
// a generic "you're offline" trigger never clears a meaningful recovery action.
let _offlineRecovery = null;
let _connectivityInstalled = false;

/** Register what to do when the connection comes back (safe to call repeatedly). */
export function setOfflineRecovery(fn) {
    _offlineRecovery = (typeof fn === 'function') ? fn : null;
}

function runRecovery() {
    try { if (_offlineRecovery) _offlineRecovery(); } catch (_) { /* non-fatal */ }
}

export function showOffline(options = {}) {
    if (typeof document === 'undefined') return;
    try { ensureStyles(); } catch (_) { return; }

    // Only (re)set the recovery hook when the caller actually supplies one, so
    // a bare showOffline() from the connectivity monitor can't wipe it.
    if (options && typeof options.onRetry === 'function') _offlineRecovery = options.onRetry;

    let root = document.getElementById(OFFLINE_ID);
    if (!root) {
        root = document.createElement('div');
        root.id = OFFLINE_ID;
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        root.setAttribute('aria-label', 'No internet connection');
        root.innerHTML =
            `<div class="inf-offline__scrim"></div>` +
            `<div class="inf-offline__sheet">` +
                `<div class="inf-offline__grip"></div>` +
                `<div class="inf-offline__icon">${wifiSlashSvg()}</div>` +
                `<h2 class="inf-offline__title">No Internet Connection</h2>` +
                `<p class="inf-offline__body">Inflight needs a connection for the live map and traffic. Check your Wi-Fi or cellular signal — this will clear itself the moment you’re back online.</p>` +
                `<button type="button" class="inf-offline__retry">Try Again</button>` +
            `</div>`;
        (document.body || document.documentElement).appendChild(root);

        root.querySelector('.inf-offline__retry').addEventListener('click', () => runRetry(root));
    } else {
        // Re-shown after a failed retry — restore the button to its idle state.
        const btn = root.querySelector('.inf-offline__retry');
        if (btn) { btn.disabled = false; btn.textContent = 'Try Again'; }
    }

    requestAnimationFrame(() => requestAnimationFrame(() => root.classList.add('is-in')));
}

function runRetry(root) {
    if (!root) return;
    const btn = root.querySelector('.inf-offline__retry');

    // Still no connection — give brief feedback and let the user try again,
    // rather than pointlessly reloading into another offline state.
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
        if (btn) {
            btn.disabled = true;
            btn.textContent = 'Still offline…';
            setTimeout(() => { btn.disabled = false; btn.textContent = 'Try Again'; }, 1300);
        }
        return;
    }

    if (btn) {
        btn.disabled = true;
        btn.innerHTML = '<span class="inf-offline__spinner"></span>Reconnecting…';
    }
    // Back online: nudge the app to recover (rebuild the map if it never
    // loaded), then dismiss. If nothing else takes the page down, hide it.
    runRecovery();
    setTimeout(() => { hideOffline(); }, 500);
}

export function hideOffline() {
    const root = document.getElementById(OFFLINE_ID);
    if (!root) return;
    root.classList.remove('is-in');
    const sheet = root.querySelector('.inf-offline__sheet');
    const done = () => { try { root.remove(); } catch (_) {} };
    if (sheet) sheet.addEventListener('transitionend', done, { once: true });
    setTimeout(done, 600);
}

export function isOfflineShown() {
    return !!document.getElementById(OFFLINE_ID);
}

// Reconcile the offline page with the current connectivity state. Shown when
// offline, dismissed (and recovery nudged) when back online. Idempotent, so
// it's safe to call from every connectivity/resume signal.
function refreshConnectivityUI() {
    const online = (typeof navigator === 'undefined') || navigator.onLine !== false;
    if (!online) {
        showOffline();
    } else if (isOfflineShown()) {
        hideOffline();
        runRecovery();
    }
}

/**
 * Wire the global connectivity monitor. Slides the "No Internet" page up when
 * the connection drops mid-session, when the app is resumed/returned-to while
 * offline, or when it launches with no connection — and slides it away the
 * moment the connection is back. Safe to call more than once.
 */
export function installConnectivityMonitor() {
    if (_connectivityInstalled || typeof window === 'undefined') return;
    _connectivityInstalled = true;

    // Direct connection transitions.
    window.addEventListener('offline', () => showOffline());
    window.addEventListener('online', () => { hideOffline(); runRecovery(); });

    // Returning to the app (tab re-shown, window refocused, bfcache restore).
    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') refreshConnectivityUI();
    });
    window.addEventListener('pageshow', () => refreshConnectivityUI());
    window.addEventListener('focus', () => refreshConnectivityUI());

    // Native iOS resume via Capacitor's App plugin, when present — fires when
    // the user brings Inflight back to the foreground.
    try {
        const App = window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.App;
        if (App && typeof App.addListener === 'function') {
            App.addListener('appStateChange', (state) => {
                if (state && state.isActive) refreshConnectivityUI();
            });
            App.addListener('resume', () => refreshConnectivityUI());
        }
    } catch (_) { /* App plugin not installed — DOM events still cover it */ }

    // Reconcile shortly after launch (not instantly): a cold-start WKWebView
    // can briefly report offline before its network stack is ready, and we
    // don't want to flash the page. The listeners above handle everything after.
    setTimeout(() => refreshConnectivityUI(), 1500);
}

// Mirror onto window so non-module callers (and the whole existing
// showNotification / showGlobalNotification surface) resolve to the native UI.
if (typeof window !== 'undefined') {
    window.InflightNativeUI = {
        notify, showOffline, hideOffline, isOfflineShown,
        setOfflineRecovery, installConnectivityMonitor,
    };
    // Canonical notification entry points used across the app.
    window.showGlobalNotification = notify;
    window.showNotification = notify;

    // Auto-start the connectivity monitor once the DOM is ready.
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', installConnectivityMonitor, { once: true });
        } else {
            installConnectivityMonitor();
        }
    }
}
