/**
 * ===================================================================
 * firstRunExperience.js
 * -------------------------------------------------------------------
 * First-launch onboarding gate.
 *
 * On the very first launch (and again only if the legal documents are
 * re-versioned) this module:
 *   1. Plays a short cinematic intro animation on the live map — the whole
 *      globe, fully zoomed out, gently spinning (no zooming).
 *   2. Fades in a branded, blocking modal where the user must agree to
 *      the Privacy Policy and Terms before the app becomes usable.
 *
 * Acceptance is persisted to localStorage keyed by LEGAL_VERSION. Bump
 * LEGAL_VERSION whenever privacy.html / terms.html change materially and
 * every existing user will be re-prompted on their next launch.
 *
 * Returning users (already accepted the current version) skip both the
 * animation and the modal — runFirstRunExperience() resolves immediately.
 *
 * Self-contained: injects its own CSS + DOM, depends only on a Mapbox GL
 * map instance (optional — the gate still works without it).
 * ===================================================================
 */

// Bump this string when privacy.html / terms.html are materially updated.
// It mirrors the "Last Updated" date shown in those documents.
const LEGAL_VERSION = '2026-04-25';
const STORAGE_KEY = 'inflight_legal_accepted';

// Key for the one-time "which flight info window?" choice. Its mere presence
// means the user has made the choice at least once; the value records what they
// picked ('simple' | 'standard'). Every user — including ones who accepted the
// legal docs before this step existed — is asked exactly once.
const WINDOW_CHOICE_KEY = 'inflight_window_choice';

const ACCENT = '#38bdf8';

/** Has the user already agreed to the *current* version of the docs? */
export function hasAcceptedLegal() {
    try {
        return localStorage.getItem(STORAGE_KEY) === LEGAL_VERSION;
    } catch (_) {
        // Private mode / storage disabled — fail open so the app is usable,
        // but the gate will simply show again next launch.
        return false;
    }
}

/** Has the user already picked a flight info window at least once? */
export function hasChosenWindow() {
    try {
        return !!localStorage.getItem(WINDOW_CHOICE_KEY);
    } catch (_) {
        return false;
    }
}

function persistAcceptance() {
    try {
        localStorage.setItem(STORAGE_KEY, LEGAL_VERSION);
    } catch (_) { /* storage unavailable; nothing we can do */ }
}

/**
 * Record the flight-window choice and apply it to the live app immediately so
 * the very next aircraft the user taps respects it.
 * @param {boolean} useSimple  true = simple card window, false = standard panel.
 */
function persistWindowChoice(useSimple) {
    try {
        localStorage.setItem(WINDOW_CHOICE_KEY, useSimple ? 'simple' : 'standard');
    } catch (_) { /* storage unavailable */ }

    try {
        if (window.mapFilters) {
            window.mapFilters.useSimpleFlightWindow = useSimple;
            // The simple window only supports the legacy mobile sheet, mirroring
            // the dependency enforced by the in-app settings toggle.
            if (useSimple) {
                try { localStorage.setItem('mobileDisplayMode', 'legacy'); } catch (_) { }
            }
            if (typeof window.saveFiltersToLocalStorage === 'function') {
                window.saveFiltersToLocalStorage();
            } else {
                try { localStorage.setItem('mapFilters', JSON.stringify(window.mapFilters)); } catch (_) { }
            }
        }
        // Keep any already-rendered settings controls in sync with the choice.
        const deskToggle = document.getElementById('filter-toggle-simple-window');
        if (deskToggle) deskToggle.checked = useSimple;
        document.querySelectorAll('input[data-setting="useSimpleFlightWindow"]')
            .forEach((i) => { i.checked = useSimple; });
    } catch (_) { /* applying the choice is best-effort */ }
}

/**
 * Run the first-launch experience.
 *
 * @param {mapboxgl.Map|null} map  Live map instance for the intro animation.
 * @param {Object} [opts]
 * @param {boolean} [opts.force]   Show even if already accepted (debug/testing).
 * @returns {Promise<void>} Resolves once the user has accepted (or immediately
 *                          for returning users).
 */
export async function runFirstRunExperience(map, opts = {}) {
    const needLegal = opts.force || !hasAcceptedLegal();
    const needWindow = opts.force || !hasChosenWindow();

    // Returning users who've done both skip everything.
    if (!needLegal && !needWindow) return;

    injectStyles();

    // Hide the app's UI chrome (top bar, tab bar, HUD, panels, info windows)
    // while the onboarding runs so nothing but the map is visible. The class
    // lives on <body> so it also catches chrome that boot injects *after*
    // onboarding has already started.
    setChromeHidden(true);

    // Step 1 — legal acceptance (plays the cinematic intro for brand-new users).
    // Step 2 — pick a flight info window. Whichever runs last fades the chrome
    // back in beneath its dismissing modal.
    if (needLegal) {
        await runLegalStep(map, { restoreChrome: !needWindow });
    }
    if (needWindow) {
        await runWindowChoiceStep({ restoreChrome: true });
    }
}

/** Reveal an overlay, then resolve once the given trigger fires; handles the
 *  shared fade-in / fade-out + cleanup. `onCommit` runs before the dismiss. */
function dismissOverlay(overlay, restoreChrome, resolve) {
    if (restoreChrome) {
        // Fade the chrome back in underneath the dismissing modal.
        setChromeHidden(false);
    }
    overlay.classList.remove('fre-visible');
    overlay.classList.add('fre-dismissing');
    const cleanup = () => {
        overlay.remove();
        resolve();
    };
    overlay.addEventListener('transitionend', cleanup, { once: true });
    // Safety net in case the transition event never fires.
    setTimeout(cleanup, 600);
}

/** Step 1: branded legal-acceptance gate with the cinematic map intro. */
function runLegalStep(map, { restoreChrome } = {}) {
    return new Promise((resolve) => {
        const { overlay, agreeBtn, checkbox } = buildModal();
        document.body.appendChild(overlay);

        // Kick off the cinematic map intro, then reveal the modal once it
        // settles. If there's no map (or it throws) we just show the modal.
        playIntroAnimation(map).finally(() => {
            requestAnimationFrame(() => overlay.classList.add('fre-visible'));
        });

        checkbox.addEventListener('change', () => {
            agreeBtn.disabled = !checkbox.checked;
        });

        agreeBtn.addEventListener('click', () => {
            if (agreeBtn.disabled) return;
            persistAcceptance();
            dismissOverlay(overlay, restoreChrome, resolve);
        });
    });
}

/**
 * Step 2: one-time "which flight info window?" picker.
 *
 * Preferred path is a hands-on, live demo — we open two real, randomly chosen
 * flights' info windows (one per style) and let the user flip between the
 * Simple and Standard styles before committing, so they *see* each one rather
 * than reading about it. We wait for the live socket to actually deliver
 * flights first. If none arrive (offline, or the feed is empty) we fall back
 * to the self-contained mockup picker so the gate never stalls the boot.
 *
 * Two *different* flights are used deliberately: handleAircraftClick() bails
 * early when asked to re-open the flight that's already showing, so reusing a
 * single flight would make the second style silently fail to render.
 */
async function runWindowChoiceStep({ restoreChrome } = {}) {
    // Wait (reasonably) for the socket to populate live flights before deciding.
    const flights = await waitForLiveFlights(2, 25000);
    if (flights.length >= 2) {
        await runWindowDemoStep(flights[0], flights[1], { restoreChrome });
    } else {
        await runWindowMockupStep({ restoreChrome });
    }
}

/**
 * Live picker: opens a real flight window and lets the user flip between the
 * two styles — Standard backed by one flight, Simple by another.
 */
function runWindowDemoStep(standardFlight, simpleFlight, { restoreChrome } = {}) {
    return new Promise((resolve) => {
        const { overlay, segs, continueBtn } = buildWindowDemoBanner();
        document.body.appendChild(overlay);

        // Don't fight the app's own window system: reveal the full chrome so the
        // real info window opens and animates exactly as it does in normal use,
        // with our control banner floating on top.
        setChromeHidden(false);
        requestAnimationFrame(() => overlay.classList.add('fre-visible'));

        // Default to the Standard window so the user immediately sees a real
        // example; tapping a segment opens the other style's flight live.
        let selected = 'standard';
        let switching = false;

        // Open the chosen style's flight via the real app path. Awaiting the
        // whole call means the in-app loading guard has cleared before we allow
        // the next switch, so taps can't race each other.
        const openStyle = async (useSimple) => {
            if (switching) return;
            switching = true;
            try {
                if (window.mapFilters) window.mapFilters.useSimpleFlightWindow = useSimple;
                const fp = useSimple ? simpleFlight : standardFlight;
                if (typeof window.handleAircraftClick === 'function') {
                    await window.handleAircraftClick(fp);
                }
            } catch (_) { /* best-effort demo */ }
            switching = false;
        };

        segs.forEach((btn) => {
            btn.addEventListener('click', () => {
                if (switching) return;
                segs.forEach((b) => b.classList.toggle('fre-seg-active', b === btn));
                selected = btn.dataset.window;
                openStyle(selected === 'simple');
            });
        });

        openStyle(false);

        continueBtn.addEventListener('click', () => {
            // Tear down the live demo window, then persist the final choice and
            // dismiss.
            try { if (typeof window.closeAircraftWindow === 'function') window.closeAircraftWindow(); } catch (_) { }
            persistWindowChoice(selected === 'simple');
            dismissOverlay(overlay, restoreChrome, resolve);
        });
    });
}

/** Fallback picker: static mockups when there are no live flights to demo. */
function runWindowMockupStep({ restoreChrome } = {}) {
    return new Promise((resolve) => {
        const { overlay, continueBtn, choices } = buildWindowChoiceModal();
        document.body.appendChild(overlay);
        requestAnimationFrame(() => overlay.classList.add('fre-visible'));

        let selected = null;
        choices.forEach((btn) => {
            btn.addEventListener('click', () => {
                choices.forEach((b) => b.classList.toggle('fre-choice-selected', b === btn));
                selected = btn.dataset.window;
                continueBtn.disabled = false;
            });
        });

        continueBtn.addEventListener('click', () => {
            if (continueBtn.disabled || !selected) return;
            persistWindowChoice(selected === 'simple');
            dismissOverlay(overlay, restoreChrome, resolve);
        });
    });
}

/**
 * Pick up to `count` distinct random live flights' properties (the shape
 * handleAircraftClick wants). Prefers en-route flights with a full
 * origin→destination route for the richest-looking example.
 */
function pickRandomLiveFlights(count) {
    let flights = [];
    try {
        if (typeof window.getLiveFlightData === 'function') {
            flights = window.getLiveFlightData() || [];
        }
    } catch (_) {
        return [];
    }
    if (!flights.length) return [];

    // getLiveFlightData() returns GeoJSON features. Mapbox stores nested
    // properties as JSON *strings*, so feature.properties.aircraft /
    // .position arrive serialized. The real map-click handlers parse those
    // back into objects before calling handleAircraftClick — we must do the
    // same here, otherwise the Standard window's aircraft type/livery come
    // back empty and its community plane photo never loads in the demo.
    const props = flights
        .map((f) => (f && f.properties) ? f.properties : f)
        .filter((p) => p && p.flightId)
        .map((p) => {
            try {
                return {
                    ...p,
                    position: typeof p.position === 'string' ? JSON.parse(p.position) : p.position,
                    aircraft: typeof p.aircraft === 'string' ? JSON.parse(p.aircraft) : p.aircraft
                };
            } catch (_) {
                return p;
            }
        });
    if (!props.length) return [];

    // Prefer en-route flights (full route) up front, then top up with any others.
    const enroute = props.filter((p) => p.departureIcao && p.arrivalIcao);
    const others = props.filter((p) => !(p.departureIcao && p.arrivalIcao));
    const ordered = shuffle(enroute).concat(shuffle(others));

    // De-dupe by flightId so the two demo flights are genuinely different.
    const picked = [];
    const seen = new Set();
    for (const p of ordered) {
        if (seen.has(p.flightId)) continue;
        seen.add(p.flightId);
        picked.push(p);
        if (picked.length >= count) break;
    }
    return picked;
}

/** Fisher–Yates shuffle (returns a new array). */
function shuffle(arr) {
    const a = arr.slice();
    for (let i = a.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [a[i], a[j]] = [a[j], a[i]];
    }
    return a;
}

/**
 * Resolve with up to `minCount` distinct live flights, polling while the live
 * socket fills in. Resolves early as soon as `minCount` are available, and
 * resolves with whatever it has (possibly fewer, possibly none) at timeout.
 */
function waitForLiveFlights(minCount, timeoutMs) {
    return new Promise((resolve) => {
        const start = Date.now();
        const tick = () => {
            const flights = pickRandomLiveFlights(minCount);
            if (flights.length >= minCount) { resolve(flights); return; }
            if (Date.now() - start >= timeoutMs) { resolve(flights); return; }
            setTimeout(tick, 400);
        };
        tick();
    });
}

/**
 * Toggle the intro chrome-hidden state on <body>. When hiding, also marks the
 * body as "chrome-managed" so the fade transition is in effect; when showing,
 * the managed class is removed shortly after so our overrides don't linger.
 */
function setChromeHidden(hidden) {
    const body = document.body;
    if (!body) return;
    if (hidden) {
        body.classList.add('fre-chrome-managed', 'fre-intro-active');
    } else {
        body.classList.remove('fre-intro-active');
        // Drop the managed class once the fade-in has finished so our
        // transition override no longer applies to normal app usage.
        setTimeout(() => body.classList.remove('fre-chrome-managed'), 750);
    }
}

// ---------------------------------------------------------------------------
// Map intro animation
// ---------------------------------------------------------------------------

/**
 * Cinematic intro: frame the globe at a comfortable, partly-zoomed-in level
 * and gently spin the world beneath the onboarding modal. No zooming during
 * the animation — the camera holds its zoom and we only rotate the globe's
 * longitude, slowly, for a brief beat. Resolves when the spin finishes (or
 * after a hard timeout so we never hang the gate).
 */
function playIntroAnimation(map) {
    return new Promise((resolve) => {
        if (!map || typeof map.jumpTo !== 'function') {
            resolve();
            return;
        }

        let settled = false;
        const done = () => {
            if (settled) return;
            settled = true;
            resolve();
        };

        // Tuning: a closer framing than the whole-earth view, a gentle spin,
        // and a short overall duration.
        const SPIN_ZOOM = 2.1;     // closer than zoom 0 (whole globe) but still clearly a globe
        const SPIN_DEGREES = 40;   // how far the world turns — small, so the spin reads as slow
        const SPIN_MS = 3200;      // ~12.5°/s — roughly half the previous speed
        const START_BEAT_MS = 200; // let the jumpTo settle before the spin starts

        try {
            // Keep the hub's longitude as the starting point so the spin
            // begins from a familiar slice of the world.
            let startLon = 0;
            try { startLon = map.getCenter().lng; } catch (_) { startLon = 0; }

            // Frame the globe at the spin zoom. Bearing/pitch flat so it reads
            // as a clean, upright planet.
            map.jumpTo({
                center: [startLon, 20],
                zoom: SPIN_ZOOM,
                bearing: 0,
                pitch: 0
            });

            // Resolve on the spin's moveend (the jumpTo above fires its own
            // moveend synchronously, before this listener is attached, so the
            // one we catch is the rotation's).
            map.once('moveend', done);
            // Hard ceiling: never let the gate wait on the map for too long.
            setTimeout(done, START_BEAT_MS + SPIN_MS + 1200);

            // Spin the globe — longitude only, zoom locked — with a steady,
            // constant-speed rotation. A short beat first lets the jumpTo
            // settle so the spin starts smoothly.
            setTimeout(() => {
                if (settled) return;
                try {
                    map.easeTo({
                        center: [startLon + SPIN_DEGREES, 20],
                        zoom: SPIN_ZOOM,
                        bearing: 0,
                        pitch: 0,
                        duration: SPIN_MS,
                        easing: (t) => t,
                        essential: true
                    });
                } catch (_) {
                    done();
                }
            }, START_BEAT_MS);
        } catch (_) {
            done();
        }
    });
}

// ---------------------------------------------------------------------------
// Modal construction
// ---------------------------------------------------------------------------

function buildModal() {
    const overlay = document.createElement('div');
    overlay.id = 'fre-overlay';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-labelledby', 'fre-title');

    overlay.innerHTML = `
        <div class="fre-card" role="document">
            <div class="fre-logo-wrap">
                <img src="Images/InflightPro.png" alt="" class="fre-logo">
            </div>
            <h1 id="fre-title" class="fre-title">Welcome to Inflight</h1>
            <p class="fre-sub">Live flight tracking for the simulation community.</p>

            <div class="fre-body">
                <p>Before you take off, please review how we handle your data. Inflight
                   tracks publicly available flight-sim network data and stores a few
                   local preferences on your device.</p>
                <p>By continuing you confirm that you have read and agree to our
                   <button type="button" class="fre-link" data-doc="privacy.html">Privacy&nbsp;Policy</button>
                   and
                   <button type="button" class="fre-link" data-doc="terms.html">Terms&nbsp;of&nbsp;Service</button>.</p>
            </div>

            <label class="fre-consent">
                <input type="checkbox" id="fre-consent-check">
                <span>I have read and agree to the Privacy Policy and Terms of Service.</span>
            </label>

            <button type="button" id="fre-agree" class="fre-agree" disabled>
                Agree &amp; Continue
            </button>
        </div>
    `;

    const agreeBtn = overlay.querySelector('#fre-agree');
    const checkbox = overlay.querySelector('#fre-consent-check');

    // Wire up the in-app legal document viewer for the inline links.
    overlay.querySelectorAll('.fre-link').forEach((link) => {
        link.addEventListener('click', () => openDocViewer(link.dataset.doc, link.textContent.trim()));
    });

    return { overlay, agreeBtn, checkbox };
}

/** One-time picker letting the user choose their flight info window style. */
function buildWindowChoiceModal() {
    const overlay = document.createElement('div');
    overlay.id = 'fre-overlay';
    overlay.classList.add('fre-overlay-choice');
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-labelledby', 'fre-window-title');

    overlay.innerHTML = `
        <div class="fre-card" role="document">
            <h1 id="fre-window-title" class="fre-title">Choose your flight window</h1>
            <p class="fre-sub">How should flight details look when you tap an aircraft? You can change this anytime in Settings.</p>

            <div class="fre-choices">
                <button type="button" class="fre-choice" data-window="simple">
                    <span class="fre-preview fre-preview-simple" aria-hidden="true">
                        <span class="pv-s-top">
                            <span class="pv-s-id"><span class="pv-s-call"></span><span class="pv-s-sub"></span></span>
                            <span class="pv-s-thumb"></span>
                        </span>
                        <span class="pv-s-route">
                            <span class="pv-s-icao"></span>
                            <i class="fa-solid fa-plane pv-s-plane"></i>
                            <span class="pv-s-icao"></span>
                        </span>
                        <span class="pv-s-bar"><span></span></span>
                    </span>
                    <span class="fre-choice-head">
                        <i class="fa-solid fa-window-maximize fre-choice-ic"></i>
                        <span class="fre-choice-name">Simple</span>
                    </span>
                    <span class="fre-choice-desc">A clean, card-style window with the key flight info at a glance.</span>
                </button>
                <button type="button" class="fre-choice" data-window="standard">
                    <span class="fre-preview fre-preview-standard" aria-hidden="true">
                        <span class="pv-d-head"></span>
                        <span class="pv-d-body">
                            <span class="pv-d-adi"></span>
                            <span class="pv-d-tiles"><span></span><span></span><span></span><span></span></span>
                        </span>
                        <span class="pv-d-tabs"><span></span><span></span><span></span><span></span></span>
                    </span>
                    <span class="fre-choice-head">
                        <i class="fa-solid fa-gauge-high fre-choice-ic"></i>
                        <span class="fre-choice-name">Standard</span>
                    </span>
                    <span class="fre-choice-desc">The full avionics panel with detailed instruments and tabs.</span>
                </button>
            </div>

            <button type="button" id="fre-window-continue" class="fre-agree" disabled>
                Continue
            </button>
        </div>
    `;

    const continueBtn = overlay.querySelector('#fre-window-continue');
    const choices = Array.from(overlay.querySelectorAll('.fre-choice'));
    return { overlay, continueBtn, choices };
}

/**
 * Compact, top-docked control banner for the live window demo. It floats above
 * the real (open) flight info window without covering it — only the card itself
 * is interactive, so the user can still poke at the live example underneath.
 */
function buildWindowDemoBanner() {
    const overlay = document.createElement('div');
    overlay.id = 'fre-window-demo';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-labelledby', 'fre-demo-title');

    overlay.innerHTML = `
        <div class="fre-demo-card" role="document">
            <h2 id="fre-demo-title" class="fre-demo-title">Choose your flight window</h2>
            <p class="fre-demo-sub">This is a live example. Tap each style to compare, then continue — you can change it anytime in Settings.</p>
            <div class="fre-seg" role="group" aria-label="Flight window style">
                <button type="button" class="fre-seg-btn fre-seg-active" data-window="standard">
                    <i class="fa-solid fa-gauge-high" aria-hidden="true"></i><span>Standard</span>
                </button>
                <button type="button" class="fre-seg-btn" data-window="simple">
                    <i class="fa-solid fa-window-maximize" aria-hidden="true"></i><span>Simple</span>
                </button>
            </div>
            <button type="button" id="fre-demo-continue" class="fre-agree">Continue</button>
        </div>
    `;

    const segs = Array.from(overlay.querySelectorAll('.fre-seg-btn'));
    const continueBtn = overlay.querySelector('#fre-demo-continue');
    return { overlay, segs, continueBtn };
}

/**
 * Full-screen in-app viewer that loads privacy.html / terms.html in an
 * iframe. Using an in-app overlay (rather than window.open / target=_blank)
 * keeps everything inside the Capacitor webview where new tabs aren't
 * reliable. Layered above the consent modal and fully self-dismissing.
 */
function openDocViewer(src, title) {
    const viewer = document.createElement('div');
    viewer.className = 'fre-doc-viewer';
    viewer.innerHTML = `
        <div class="fre-doc-bar">
            <button type="button" class="fre-doc-back" aria-label="Back">&#8249;</button>
            <span class="fre-doc-title"></span>
        </div>
        <iframe class="fre-doc-frame" title="" loading="lazy"></iframe>
    `;
    viewer.querySelector('.fre-doc-title').textContent = title || 'Document';
    const frame = viewer.querySelector('.fre-doc-frame');
    frame.setAttribute('title', title || 'Document');
    frame.setAttribute('src', src);

    const close = () => {
        viewer.classList.remove('fre-doc-open');
        viewer.addEventListener('transitionend', () => viewer.remove(), { once: true });
        setTimeout(() => viewer.remove(), 400);
    };
    viewer.querySelector('.fre-doc-back').addEventListener('click', close);

    document.body.appendChild(viewer);
    requestAnimationFrame(() => viewer.classList.add('fre-doc-open'));
}

/**
 * Open a legal document (privacy.html / terms.html) in the same in-app
 * slide-over viewer the onboarding gate uses. Exported so Settings can offer
 * the docs too. Safe to call at any time — it injects the viewer styles on
 * demand (returning users never ran the gate, so the styles may be absent).
 */
export function openLegalDoc(src, title) {
    injectStyles();
    openDocViewer(src, title);
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

function injectStyles() {
    if (document.getElementById('fre-styles')) return;
    const style = document.createElement('style');
    style.id = 'fre-styles';
    style.textContent = `
        /* Intro chrome management: smoothly fade the app's UI overlays out
           while the map intro animation plays, then back in on accept. The
           transition is only applied while .fre-chrome-managed is on <body>,
           so it never affects normal app behaviour afterwards. */
        body.fre-chrome-managed #inflight-tactical-ui,
        body.fre-chrome-managed #mobile-hud-controls,
        body.fre-chrome-managed #ios-landing-topbar,
        body.fre-chrome-managed #ios-landing-tabbar,
        body.fre-chrome-managed #sector-ops-floating-panel,
        body.fre-chrome-managed #aircraft-info-window,
        body.fre-chrome-managed #airport-info-window {
            transition: opacity 600ms ease !important;
        }
        body.fre-intro-active #inflight-tactical-ui,
        body.fre-intro-active #mobile-hud-controls,
        body.fre-intro-active #ios-landing-topbar,
        body.fre-intro-active #ios-landing-tabbar,
        body.fre-intro-active #sector-ops-floating-panel,
        body.fre-intro-active #aircraft-info-window,
        body.fre-intro-active #airport-info-window {
            opacity: 0 !important;
            pointer-events: none !important;
        }

        #fre-overlay {
            position: fixed;
            inset: 0;
            z-index: 2147483000;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 24px;
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            color: #e8eaf6;
            background:
                radial-gradient(ellipse at 50% 36%, rgba(56, 189, 248, 0.16) 0%, transparent 62%),
                rgba(5, 10, 24, 0.55);
            -webkit-backdrop-filter: blur(14px);
            backdrop-filter: blur(14px);
            opacity: 0;
            transition: opacity 360ms ease;
            -webkit-font-smoothing: antialiased;
            /* Hard gate: block all interaction with the app underneath. */
        }
        #fre-overlay.fre-visible { opacity: 1; }
        #fre-overlay.fre-dismissing { opacity: 0; }

        #fre-overlay .fre-card {
            position: relative;
            width: 100%;
            max-width: 420px;
            max-height: calc(100vh - 48px);
            overflow-y: auto;
            -webkit-overflow-scrolling: touch;
            display: flex;
            flex-direction: column;
            align-items: center;
            text-align: center;
            padding: 32px 26px 26px;
            border-radius: 24px;
            background: linear-gradient(180deg, #0e1a36 0%, #070d1f 100%);
            border: 1px solid rgba(56, 189, 248, 0.18);
            box-shadow: 0 24px 70px rgba(0, 0, 0, 0.6),
                        inset 0 1px 0 rgba(255, 255, 255, 0.05);
            transform: translateY(18px) scale(0.98);
            transition: transform 420ms cubic-bezier(0.16, 1, 0.3, 1);
        }
        #fre-overlay.fre-visible .fre-card { transform: translateY(0) scale(1); }

        #fre-overlay .fre-logo-wrap {
            position: relative;
            width: 84px;
            height: 84px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin-bottom: 18px;
        }
        #fre-overlay .fre-logo-wrap::before {
            content: '';
            position: absolute;
            inset: -22px;
            border-radius: 50%;
            background: radial-gradient(circle, rgba(56, 189, 248, 0.30) 0%, transparent 70%);
            filter: blur(6px);
            pointer-events: none;
        }
        #fre-overlay .fre-logo {
            position: relative;
            height: 72px;
            width: auto;
            filter: drop-shadow(0 8px 24px rgba(56, 189, 248, 0.35));
        }

        #fre-overlay .fre-title {
            font-size: 1.6rem;
            font-weight: 700;
            margin: 0 0 4px;
            background: linear-gradient(180deg, #ffffff 0%, #c7d2fe 100%);
            -webkit-background-clip: text;
            background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        #fre-overlay .fre-sub {
            font-size: 0.9rem;
            color: rgba(199, 210, 254, 0.7);
            margin: 0 0 20px;
        }

        #fre-overlay .fre-body {
            font-size: 0.9rem;
            line-height: 1.55;
            color: rgba(226, 234, 246, 0.82);
            text-align: left;
        }
        #fre-overlay .fre-body p { margin: 0 0 12px; }

        #fre-overlay .fre-link {
            background: none;
            border: none;
            padding: 0;
            margin: 0;
            font: inherit;
            color: ${ACCENT};
            font-weight: 600;
            text-decoration: underline;
            text-underline-offset: 2px;
            cursor: pointer;
        }
        #fre-overlay .fre-link:active { opacity: 0.7; }

        #fre-overlay .fre-consent {
            display: flex;
            align-items: flex-start;
            gap: 11px;
            text-align: left;
            font-size: 0.85rem;
            line-height: 1.45;
            color: rgba(226, 234, 246, 0.9);
            margin: 6px 0 22px;
            cursor: pointer;
        }
        #fre-overlay .fre-consent input {
            flex: 0 0 auto;
            width: 22px;
            height: 22px;
            margin: 0;
            accent-color: ${ACCENT};
            cursor: pointer;
        }

        #fre-overlay .fre-agree {
            width: 100%;
            padding: 15px 18px;
            border: none;
            border-radius: 14px;
            font-size: 1rem;
            font-weight: 700;
            color: #04111f;
            background: linear-gradient(180deg, #5cc8ff 0%, ${ACCENT} 100%);
            box-shadow: 0 10px 26px rgba(56, 189, 248, 0.35);
            cursor: pointer;
            transition: transform 120ms ease, opacity 200ms ease, box-shadow 200ms ease;
        }
        #fre-overlay .fre-agree:active { transform: scale(0.98); }
        #fre-overlay .fre-agree:disabled {
            opacity: 0.4;
            box-shadow: none;
            cursor: not-allowed;
        }

        /* Flight info window picker */
        #fre-overlay .fre-choices {
            display: flex;
            flex-direction: column;
            gap: 12px;
            width: 100%;
            margin: 4px 0 22px;
        }
        #fre-overlay .fre-choice {
            display: flex;
            flex-direction: column;
            gap: 9px;
            text-align: left;
            width: 100%;
            padding: 12px;
            border-radius: 16px;
            background: rgba(255, 255, 255, 0.03);
            border: 1.5px solid rgba(255, 255, 255, 0.10);
            color: inherit;
            font: inherit;
            cursor: pointer;
            transition: border-color 160ms ease, background 160ms ease, transform 120ms ease;
        }
        #fre-overlay .fre-choice:active { transform: scale(0.99); }
        #fre-overlay .fre-choice-selected {
            border-color: ${ACCENT};
            background: rgba(56, 189, 248, 0.10);
            box-shadow: 0 0 0 1px ${ACCENT}, 0 10px 26px rgba(56, 189, 248, 0.18);
        }
        #fre-overlay .fre-choice-head {
            display: flex;
            align-items: center;
            gap: 9px;
        }
        #fre-overlay .fre-choice-ic {
            font-size: 0.9rem;
            color: ${ACCENT};
        }
        #fre-overlay .fre-choice-name {
            font-size: 1rem;
            font-weight: 700;
            color: #fff;
        }
        #fre-overlay .fre-choice-desc {
            font-size: 0.8rem;
            line-height: 1.4;
            color: rgba(199, 210, 254, 0.72);
        }

        /* --- Mini mockups: a tiny live-ish preview of each window style --- */
        #fre-overlay .fre-preview {
            display: flex;
            flex-direction: column;
            width: 100%;
            height: 104px;
            padding: 11px;
            border-radius: 11px;
            background: linear-gradient(150deg, #18181b, #0c1322);
            border: 1px solid rgba(255, 255, 255, 0.07);
            overflow: hidden;
        }

        /* Simple: roomy card — id + thumb, big route, progress bar */
        #fre-overlay .fre-preview-simple { gap: 9px; justify-content: center; }
        #fre-overlay .pv-s-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
        #fre-overlay .pv-s-id { display: flex; flex-direction: column; gap: 4px; }
        #fre-overlay .pv-s-call { width: 52px; height: 9px; border-radius: 3px; background: #ffffff; }
        #fre-overlay .pv-s-sub { width: 34px; height: 5px; border-radius: 3px; background: rgba(255,255,255,0.35); }
        #fre-overlay .pv-s-thumb { width: 46px; height: 26px; border-radius: 6px; background: rgba(56,189,248,0.22); border: 1px solid rgba(255,255,255,0.12); }
        #fre-overlay .pv-s-route { display: flex; align-items: center; justify-content: space-between; }
        #fre-overlay .pv-s-icao { width: 40px; height: 13px; border-radius: 3px; background: rgba(255,255,255,0.85); }
        #fre-overlay .pv-s-plane { color: ${ACCENT}; font-size: 11px; }
        #fre-overlay .pv-s-bar { position: relative; height: 4px; border-radius: 2px; background: rgba(255,255,255,0.14); }
        #fre-overlay .pv-s-bar > span { position: absolute; inset: 0 55% 0 0; border-radius: 2px; background: ${ACCENT}; }

        /* Standard: dense avionics — header, attitude dial + gauge tiles, tab bar */
        #fre-overlay .fre-preview-standard { gap: 7px; }
        #fre-overlay .pv-d-head { height: 11px; border-radius: 3px; background: rgba(255,255,255,0.10); }
        #fre-overlay .pv-d-body { flex: 1; display: flex; gap: 7px; }
        #fre-overlay .pv-d-adi {
            width: 40px; border-radius: 6px; flex: 0 0 auto;
            background: radial-gradient(circle at 50% 38%, #38bdf8 0 42%, #1d4ed8 42% 50%, #7c5e2a 50% 58%, #b45309 58% 100%);
            border: 1px solid rgba(255,255,255,0.18);
        }
        #fre-overlay .pv-d-tiles { flex: 1; display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; gap: 5px; }
        #fre-overlay .pv-d-tiles > span { border-radius: 5px; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.06); }
        #fre-overlay .pv-d-tabs { display: flex; gap: 5px; }
        #fre-overlay .pv-d-tabs > span { flex: 1; height: 8px; border-radius: 3px; background: rgba(255,255,255,0.10); }
        #fre-overlay .pv-d-tabs > span:first-child { background: ${ACCENT}; }

        /* --- Live window demo (Step 2 preferred path) --- */
        /* The demo restores the full app chrome and lets the real info window
           open normally, with this top-docked banner floating above it. The
           banner is non-blocking — only the card itself captures input. */
        #fre-window-demo {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            z-index: 2147483000;
            display: flex;
            justify-content: center;
            padding: calc(env(safe-area-inset-top, 0px) + 12px) 14px 0;
            pointer-events: none;
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            color: #e8eaf6;
            opacity: 0;
            transform: translateY(-14px);
            transition: opacity 320ms ease, transform 320ms cubic-bezier(0.16, 1, 0.3, 1);
            -webkit-font-smoothing: antialiased;
        }
        #fre-window-demo.fre-visible { opacity: 1; transform: translateY(0); }
        #fre-window-demo.fre-dismissing { opacity: 0; transform: translateY(-14px); }

        #fre-window-demo .fre-demo-card {
            pointer-events: auto;
            width: 100%;
            max-width: 460px;
            padding: 15px 18px 17px;
            border-radius: 20px;
            text-align: center;
            background: linear-gradient(180deg, #0e1a36 0%, #070d1f 100%);
            border: 1px solid rgba(56, 189, 248, 0.22);
            box-shadow: 0 18px 50px rgba(0, 0, 0, 0.55),
                        inset 0 1px 0 rgba(255, 255, 255, 0.05);
        }
        #fre-window-demo .fre-demo-title {
            font-size: 1.12rem;
            font-weight: 700;
            margin: 0 0 4px;
            color: #fff;
        }
        #fre-window-demo .fre-demo-sub {
            font-size: 0.8rem;
            line-height: 1.4;
            color: rgba(199, 210, 254, 0.72);
            margin: 0 0 13px;
        }
        #fre-window-demo .fre-seg {
            display: flex;
            gap: 6px;
            padding: 5px;
            margin: 0 0 13px;
            border-radius: 14px;
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid rgba(255, 255, 255, 0.08);
        }
        #fre-window-demo .fre-seg-btn {
            flex: 1;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 7px;
            padding: 10px 8px;
            border: none;
            border-radius: 10px;
            background: transparent;
            color: rgba(226, 234, 246, 0.78);
            font: inherit;
            font-size: 0.92rem;
            font-weight: 600;
            cursor: pointer;
            transition: background 160ms ease, color 160ms ease, box-shadow 160ms ease;
        }
        #fre-window-demo .fre-seg-btn i { font-size: 0.85rem; color: ${ACCENT}; }
        #fre-window-demo .fre-seg-btn.fre-seg-active {
            color: #04111f;
            background: linear-gradient(180deg, #5cc8ff 0%, ${ACCENT} 100%);
            box-shadow: 0 6px 16px rgba(56, 189, 248, 0.32);
        }
        #fre-window-demo .fre-seg-btn.fre-seg-active i { color: #04111f; }
        #fre-window-demo .fre-agree {
            width: 100%;
            padding: 13px 18px;
            border: none;
            border-radius: 13px;
            font-size: 0.98rem;
            font-weight: 700;
            color: #04111f;
            background: linear-gradient(180deg, #5cc8ff 0%, ${ACCENT} 100%);
            box-shadow: 0 10px 26px rgba(56, 189, 248, 0.35);
            cursor: pointer;
            transition: transform 120ms ease, box-shadow 200ms ease;
        }
        #fre-window-demo .fre-agree:active { transform: scale(0.98); }

        /* In-app legal document viewer */
        .fre-doc-viewer {
            position: fixed;
            inset: 0;
            z-index: 2147483001;
            display: flex;
            flex-direction: column;
            background: #0b1530;
            transform: translateX(100%);
            transition: transform 360ms cubic-bezier(0.16, 1, 0.3, 1);
        }
        .fre-doc-viewer.fre-doc-open { transform: translateX(0); }
        .fre-doc-bar {
            flex: 0 0 auto;
            display: flex;
            align-items: center;
            gap: 8px;
            padding: calc(env(safe-area-inset-top, 0px) + 10px) 14px 10px;
            background: #0e1a36;
            border-bottom: 1px solid rgba(255, 255, 255, 0.08);
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        }
        .fre-doc-back {
            font-size: 1.8rem;
            line-height: 1;
            background: none;
            border: none;
            color: ${ACCENT};
            padding: 0 8px;
            cursor: pointer;
        }
        .fre-doc-title {
            font-size: 1rem;
            font-weight: 600;
            color: #fff;
        }
        .fre-doc-frame {
            flex: 1 1 auto;
            width: 100%;
            border: none;
            background: #0b1530;
        }
    `;
    document.head.appendChild(style);
}
