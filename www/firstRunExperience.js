/**
 * ===================================================================
 * firstRunExperience.js
 * -------------------------------------------------------------------
 * First-launch onboarding gate.
 *
 * On the very first launch (and again only if the legal documents are
 * re-versioned) this module:
 *   1. Plays a short cinematic intro animation on the live map — a
 *      globe-level pull-back that flies in toward the user's hub.
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

function persistAcceptance() {
    try {
        localStorage.setItem(STORAGE_KEY, LEGAL_VERSION);
    } catch (_) { /* storage unavailable; nothing we can do */ }
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
export function runFirstRunExperience(map, opts = {}) {
    if (!opts.force && hasAcceptedLegal()) {
        return Promise.resolve();
    }

    injectStyles();

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
            overlay.classList.remove('fre-visible');
            overlay.classList.add('fre-dismissing');
            const cleanup = () => {
                overlay.remove();
                resolve();
            };
            overlay.addEventListener('transitionend', cleanup, { once: true });
            // Safety net in case the transition event never fires.
            setTimeout(cleanup, 600);
        });
    });
}

// ---------------------------------------------------------------------------
// Map intro animation
// ---------------------------------------------------------------------------

/**
 * Cinematic intro: snap the camera out to a globe-level view, then fly it
 * back in to the map's intended target with a gentle rotation. Resolves when
 * the move finishes (or after a hard timeout so we never hang the gate).
 */
function playIntroAnimation(map) {
    return new Promise((resolve) => {
        if (!map || typeof map.flyTo !== 'function') {
            resolve();
            return;
        }

        let settled = false;
        const done = () => {
            if (settled) return;
            settled = true;
            resolve();
        };

        try {
            const target = {
                center: map.getCenter(),
                zoom: map.getZoom(),
                bearing: 0,
                pitch: 0
            };

            // Pull way out and offset the bearing so the globe visibly
            // rotates as we descend toward the hub.
            map.jumpTo({
                center: [target.center.lng, Math.min(target.center.lat + 18, 70)],
                zoom: 0.4,
                bearing: -32,
                pitch: 0
            });

            map.once('moveend', done);
            // Hard ceiling: never let the gate wait on the map for too long.
            setTimeout(done, 5200);

            // Small beat so the globe is visible before we dive in.
            setTimeout(() => {
                if (settled) return;
                try {
                    map.flyTo({
                        ...target,
                        duration: 4200,
                        curve: 1.5,
                        speed: 0.6,
                        essential: true
                    });
                } catch (_) {
                    done();
                }
            }, 350);
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

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

function injectStyles() {
    if (document.getElementById('fre-styles')) return;
    const style = document.createElement('style');
    style.id = 'fre-styles';
    style.textContent = `
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
