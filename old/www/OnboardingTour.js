/**
 * OnboardingTour — 30-second guided tour for first-time pilots.
 *
 * Self-contained spotlight + tooltip system. Walks the user through:
 *   1. The ProfileUI dock (each tab gets ~3 seconds of explanation)
 *   2. Key map controls after the dashboard closes
 *
 * Design:
 * • Inert SVG mask cuts a hole around the target — no expensive backdrop-filter
 * • Tooltip auto-positions (top/bottom/left/right) based on viewport space
 * • Single rAF-driven reposition loop while open (handles scrolls / resizes)
 * • Persists completion to Supabase user_metadata.onboarding_tour_complete
 *
 * Integration (see integration-patches.md):
 * • Imported by profileUI.js, kicked off after onboarding-complete-btn finishes
 * • Bridges to flight.js via the optional onMapPhase() callback, which closes
 *   ProfileUI before the map-control steps run
 *
 * Public API:
 *   OnboardingTour.start({ supabase, onMapPhase, onComplete })
 *   OnboardingTour.skip()
 *   OnboardingTour.isComplete(user)   // helper for gating
 */

export const OnboardingTour = {
    _active: false,
    _stepIndex: 0,
    _steps: [],
    _supabase: null,
    _onComplete: null,
    _onMapPhase: null,
    _rafId: null,
    _resizeHandler: null,
    _keyHandler: null,

    // ---------- Step definitions ----------
    // Two phases: 'dock' steps run while ProfileUI is open. The first 'map'
    // step triggers a phase transition (ProfileUI closes, map becomes visible).

    _DOCK_STEPS: [
        {
            phase: 'dock',
            selector: '.pui-dock',
            title: 'This is your flight deck.',
            body: 'Six tools sit in the dock. Drag to reorder them — your layout, your rules.',
            placement: 'top',
        },
        {
            phase: 'dock',
            selector: '.pui-dock-item[data-tab="dashboard"]',
            title: 'Dashboard',
            body: 'At-a-glance trends, comparative stats, and your personal records.',
            placement: 'top',
        },
        {
            phase: 'dock',
            selector: '.pui-dock-item[data-tab="career-deep-dive"]',
            title: 'Pilot Dossier',
            body: 'Deep career analytics — hours, grade history, fleet mix, route map.',
            placement: 'top',
        },
        {
            phase: 'dock',
            selector: '.pui-dock-item[data-tab="airspace-intel"]',
            title: 'Traffic',
            body: 'Live predictive telemetry across busy hubs. Add ICAOs you fly often.',
            placement: 'top',
        },
        {
            phase: 'dock',
            selector: '.pui-dock-item[data-tab="flight-plan"]',
            title: 'Dispatch',
            body: 'File flight plans with predictive EET. Edit or delete anytime.',
            placement: 'top',
        },
        {
            phase: 'dock',
            selector: '.pui-dock-item[data-tab="watchlist"]',
            title: 'Watchlist',
            body: 'Pin pilots to follow. The badge lights up when they go airborne.',
            placement: 'top',
        },
        {
            phase: 'dock',
            selector: '#pui-theme-btn',
            title: 'Tweak the look.',
            body: 'Toggle theme here, or change density and accent in Settings.',
            placement: 'bottom',
        },
    ],

    _MAP_STEPS: [
        {
            phase: 'map',
            selector: '#sector-ops-search-container, #sector-ops-search-input',
            title: 'Find any pilot or airport.',
            body: 'Search by callsign, username, or ICAO. Results stream in live.',
            placement: 'bottom',
        },
        {
            phase: 'map',
            selector: '#filters-settings-btn, #open-filter-settings-btn',
            title: 'Filters & quick search.',
            body: 'Narrow the map — by aircraft, server, route, ATC presence, group flights.',
            placement: 'bottom',
        },
        {
            phase: 'map',
            selector: '#open-weather-settings-btn',
            title: 'Weather & layers.',
            body: 'METAR, SIGMET, wind, NAT tracks, day/night terminator — toggle what you need.',
            placement: 'bottom',
        },
        {
            phase: 'map',
            selector: '#leaderboard-list, #sector-ops-floating-panel',
            title: 'Live leaderboard.',
            body: 'Top pilots in the air right now. Click a name to jump to their aircraft.',
            placement: 'left',
        },
        {
            phase: 'map',
            selector: '#profile-picture',
            title: 'You\'re cleared for departure.',
            body: 'Your profile button is here whenever you want to come back to the deck. Have fun out there.',
            placement: 'left',
            isLast: true,
        },
    ],

    // ---------- Public API ----------

    isComplete(user) {
        return !!user?.user_metadata?.onboarding_tour_complete;
    },

    start({ supabase, onMapPhase, onComplete } = {}) {
        if (this._active) return;
        this._active = true;
        this._stepIndex = 0;
        this._supabase = supabase || null;
        this._onComplete = onComplete || null;
        this._onMapPhase = onMapPhase || null;
        this._steps = [...this._DOCK_STEPS, ...this._MAP_STEPS];

        this._injectStyles();
        this._buildShell();
        this._renderStep();

        this._resizeHandler = () => this._positionTooltip();
        window.addEventListener('resize', this._resizeHandler);
        window.addEventListener('scroll', this._resizeHandler, true);

        this._keyHandler = (e) => {
            if (!this._active) return;
            if (e.key === 'Escape') this.skip();
            else if (e.key === 'ArrowRight' || e.key === 'Enter') this._next();
            else if (e.key === 'ArrowLeft') this._back();
        };
        document.addEventListener('keydown', this._keyHandler);

        // Reposition continuously for the first 600ms to handle layout settle
        const t0 = performance.now();
        const tick = (now) => {
            if (!this._active) return;
            this._positionTooltip();
            if (now - t0 < 600) this._rafId = requestAnimationFrame(tick);
        };
        this._rafId = requestAnimationFrame(tick);
    },

    skip() {
        this._finish(false);
    },

    // ---------- Internals ----------

    _next() {
        const step = this._steps[this._stepIndex];
        if (step?.isLast) return this._finish(true);
        this._stepIndex++;
        // Phase transition: leaving last dock step, entering first map step
        const prev = this._steps[this._stepIndex - 1];
        const cur = this._steps[this._stepIndex];
        if (prev?.phase === 'dock' && cur?.phase === 'map') {
            this._transitionToMapPhase();
        } else {
            this._renderStep();
        }
    },

    _back() {
        if (this._stepIndex === 0) return;
        this._stepIndex--;
        // Reverse phase transition is uncommon (user already saw the dock close);
        // we just skip back without re-opening ProfileUI to keep things simple.
        const cur = this._steps[this._stepIndex];
        if (cur?.phase === 'dock' && this._mapPhaseEntered) {
            this._stepIndex++; // bounce forward, no re-open
        }
        this._renderStep();
    },

    _transitionToMapPhase() {
        this._mapPhaseEntered = true;
        // Hide the spotlight while the dashboard slides away
        this._setShellHidden(true);
        if (typeof this._onMapPhase === 'function') {
            // Caller (profileUI) closes itself; give it 350ms to animate out
            this._onMapPhase();
        }
        setTimeout(() => {
            this._setShellHidden(false);
            this._renderStep();
        }, 380);
    },

    _finish(completed) {
        this._active = false;
        if (this._rafId) cancelAnimationFrame(this._rafId);
        if (this._resizeHandler) {
            window.removeEventListener('resize', this._resizeHandler);
            window.removeEventListener('scroll', this._resizeHandler, true);
        }
        if (this._keyHandler) document.removeEventListener('keydown', this._keyHandler);

        const root = document.getElementById('ot-root');
        if (root) {
            root.classList.add('ot-fade-out');
            setTimeout(() => root.remove(), 250);
        }

        if (completed && this._supabase) {
            // Fire-and-forget — non-blocking
            this._supabase.auth.updateUser({
                data: { onboarding_tour_complete: true },
            }).catch(err => console.warn('[OnboardingTour] persist failed:', err));
        }

        if (typeof this._onComplete === 'function') {
            this._onComplete(completed);
        }
    },

    // ---------- DOM ----------

    _buildShell() {
        const existing = document.getElementById('ot-root');
        if (existing) existing.remove();

        const root = document.createElement('div');
        root.id = 'ot-root';
        root.innerHTML = `
            <svg id="ot-mask-svg" aria-hidden="true">
                <defs>
                    <mask id="ot-mask">
                        <rect width="100%" height="100%" fill="white"></rect>
                        <rect id="ot-mask-cutout" x="0" y="0" width="0" height="0" rx="12" ry="12" fill="black"></rect>
                    </mask>
                </defs>
                <rect width="100%" height="100%" fill="rgba(7,9,15,0.72)" mask="url(#ot-mask)"></rect>
            </svg>
            <div id="ot-highlight-ring" aria-hidden="true"></div>
            <div id="ot-tooltip" role="dialog" aria-live="polite">
                <div class="ot-tooltip-arrow" data-arrow></div>
                <div class="ot-tooltip-progress">
                    <span data-step-current>1</span><span class="ot-tooltip-progress-sep">/</span><span data-step-total>${this._steps.length}</span>
                </div>
                <h3 class="ot-tooltip-title" data-title>—</h3>
                <p class="ot-tooltip-body" data-body>—</p>
                <div class="ot-tooltip-controls">
                    <button class="ot-btn ot-btn-ghost" data-action="skip">Skip tour</button>
                    <div class="ot-tooltip-controls-right">
                        <button class="ot-btn ot-btn-ghost" data-action="back">Back</button>
                        <button class="ot-btn ot-btn-primary" data-action="next">Next</button>
                    </div>
                </div>
            </div>
        `;
        document.body.appendChild(root);

        root.querySelector('[data-action="next"]').addEventListener('click', () => this._next());
        root.querySelector('[data-action="back"]').addEventListener('click', () => this._back());
        root.querySelector('[data-action="skip"]').addEventListener('click', () => this.skip());
    },

    _setShellHidden(hidden) {
        const root = document.getElementById('ot-root');
        if (root) root.classList.toggle('ot-hidden', hidden);
    },

    _renderStep() {
        const step = this._steps[this._stepIndex];
        if (!step) return this._finish(true);

        const root = document.getElementById('ot-root');
        if (!root) return;

        root.querySelector('[data-title]').textContent = step.title;
        root.querySelector('[data-body]').textContent = step.body;
        root.querySelector('[data-step-current]').textContent = this._stepIndex + 1;
        root.querySelector('[data-step-total]').textContent = this._steps.length;

        const nextBtn = root.querySelector('[data-action="next"]');
        nextBtn.textContent = step.isLast ? 'Got it' : 'Next';
        const backBtn = root.querySelector('[data-action="back"]');
        backBtn.style.visibility = this._stepIndex === 0 ? 'hidden' : 'visible';

        this._positionTooltip();
    },

    _findTarget(selectors) {
        // Allow comma-separated fallback selectors — useful when a control is
        // optional (e.g. landing card) or mounted lazily.
        const list = String(selectors || '').split(',').map(s => s.trim()).filter(Boolean);
        for (const sel of list) {
            const el = document.querySelector(sel);
            if (el && el.getBoundingClientRect) {
                const r = el.getBoundingClientRect();
                if (r.width > 0 && r.height > 0) return el;
            }
        }
        return null;
    },

    _positionTooltip() {
        const step = this._steps[this._stepIndex];
        if (!step) return;
        const target = this._findTarget(step.selector);
        const tooltip = document.getElementById('ot-tooltip');
        const cutout = document.getElementById('ot-mask-cutout');
        const ring = document.getElementById('ot-highlight-ring');
        if (!tooltip) return;

        if (!target) {
            // Target not present — hide spotlight and center the tooltip with a soft note
            cutout?.setAttribute('width', '0');
            cutout?.setAttribute('height', '0');
            if (ring) ring.style.opacity = '0';
            tooltip.style.left = '50%';
            tooltip.style.top = '50%';
            tooltip.style.transform = 'translate(-50%, -50%)';
            tooltip.dataset.placement = 'center';
            return;
        }

        const r = target.getBoundingClientRect();
        const pad = 8;
        const cx = r.left - pad;
        const cy = r.top - pad;
        const cw = r.width + pad * 2;
        const ch = r.height + pad * 2;

        cutout?.setAttribute('x', cx);
        cutout?.setAttribute('y', cy);
        cutout?.setAttribute('width', cw);
        cutout?.setAttribute('height', ch);

        if (ring) {
            ring.style.left = `${cx}px`;
            ring.style.top = `${cy}px`;
            ring.style.width = `${cw}px`;
            ring.style.height = `${ch}px`;
            ring.style.opacity = '1';
        }

        // Pick the best placement given viewport room
        const tw = tooltip.offsetWidth || 340;
        const th = tooltip.offsetHeight || 180;
        const vw = window.innerWidth;
        const vh = window.innerHeight;
        const gap = 18;

        const room = {
            top: r.top,
            bottom: vh - r.bottom,
            left: r.left,
            right: vw - r.right,
        };

        let placement = step.placement || 'bottom';
        // If the requested side doesn't fit, fall back to the side with the most room
        const fits = {
            top: room.top >= th + gap,
            bottom: room.bottom >= th + gap,
            left: room.left >= tw + gap,
            right: room.right >= tw + gap,
        };
        if (!fits[placement]) {
            placement = Object.entries(room).sort((a, b) => b[1] - a[1])[0][0];
        }

        let left, top;
        switch (placement) {
            case 'top':
                left = r.left + r.width / 2 - tw / 2;
                top = r.top - th - gap;
                break;
            case 'bottom':
                left = r.left + r.width / 2 - tw / 2;
                top = r.bottom + gap;
                break;
            case 'left':
                left = r.left - tw - gap;
                top = r.top + r.height / 2 - th / 2;
                break;
            case 'right':
                left = r.right + gap;
                top = r.top + r.height / 2 - th / 2;
                break;
        }

        // Clamp to viewport
        left = Math.max(12, Math.min(left, vw - tw - 12));
        top = Math.max(12, Math.min(top, vh - th - 12));

        tooltip.style.left = `${left}px`;
        tooltip.style.top = `${top}px`;
        tooltip.style.transform = 'none';
        tooltip.dataset.placement = placement;

        // Position the arrow toward the target's center
        const arrow = tooltip.querySelector('[data-arrow]');
        if (arrow) {
            const targetCx = r.left + r.width / 2;
            const targetCy = r.top + r.height / 2;
            if (placement === 'top' || placement === 'bottom') {
                const ax = Math.max(16, Math.min(targetCx - left, tw - 16));
                arrow.style.left = `${ax}px`;
                arrow.style.top = '';
            } else {
                const ay = Math.max(16, Math.min(targetCy - top, th - 16));
                arrow.style.top = `${ay}px`;
                arrow.style.left = '';
            }
        }
    },

    // ---------- Styles ----------

    _injectStyles() {
        if (document.getElementById('ot-styles')) return;
        const style = document.createElement('style');
        style.id = 'ot-styles';
        style.textContent = `
            #ot-root {
                position: fixed;
                inset: 0;
                z-index: 2147483600;
                pointer-events: none;
                font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                opacity: 0;
                animation: otFadeIn 0.25s ease forwards;
            }
            #ot-root.ot-hidden { opacity: 0; transition: opacity 0.2s ease; }
            #ot-root.ot-fade-out { opacity: 0; transition: opacity 0.25s ease; }
            @keyframes otFadeIn { to { opacity: 1; } }

            #ot-mask-svg {
                position: absolute;
                inset: 0;
                width: 100%;
                height: 100%;
                pointer-events: auto;
            }

            #ot-highlight-ring {
                position: fixed;
                border-radius: 12px;
                pointer-events: none;
                box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.9), 0 0 24px 4px rgba(56, 189, 248, 0.35);
                transition: all 0.32s cubic-bezier(0.16, 1, 0.3, 1);
                opacity: 0;
            }

            #ot-tooltip {
                position: fixed;
                width: 340px;
                max-width: calc(100vw - 24px);
                background: #18181b;
                color: #fafafa;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 16px;
                padding: 18px 20px 16px;
                box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6), 0 0 0 1px rgba(255, 255, 255, 0.02);
                pointer-events: auto;
                transition: left 0.32s cubic-bezier(0.16, 1, 0.3, 1),
                            top 0.32s cubic-bezier(0.16, 1, 0.3, 1);
                z-index: 1;
            }

            .ot-tooltip-arrow {
                position: absolute;
                width: 12px;
                height: 12px;
                background: #18181b;
                border: 1px solid rgba(255, 255, 255, 0.08);
                transform: rotate(45deg);
                pointer-events: none;
            }
            #ot-tooltip[data-placement="top"]    .ot-tooltip-arrow { bottom: -7px; border-top: none; border-left: none; }
            #ot-tooltip[data-placement="bottom"] .ot-tooltip-arrow { top: -7px;    border-bottom: none; border-right: none; }
            #ot-tooltip[data-placement="left"]   .ot-tooltip-arrow { right: -7px;  border-bottom: none; border-left: none; }
            #ot-tooltip[data-placement="right"]  .ot-tooltip-arrow { left: -7px;   border-top: none; border-right: none; }
            #ot-tooltip[data-placement="center"] .ot-tooltip-arrow { display: none; }

            .ot-tooltip-progress {
                font-size: 0.72rem;
                font-weight: 600;
                color: #38bdf8;
                letter-spacing: 0.6px;
                text-transform: uppercase;
                margin-bottom: 10px;
            }
            .ot-tooltip-progress-sep { opacity: 0.5; margin: 0 4px; }

            .ot-tooltip-title {
                margin: 0 0 8px 0;
                font-size: 1.05rem;
                font-weight: 700;
                letter-spacing: -0.2px;
                color: #fafafa;
            }
            .ot-tooltip-body {
                margin: 0 0 16px 0;
                font-size: 0.85rem;
                line-height: 1.5;
                color: #cbd5e1;
            }

            .ot-tooltip-controls {
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 8px;
            }
            .ot-tooltip-controls-right { display: flex; gap: 8px; }

            .ot-btn {
                font-family: inherit;
                font-size: 0.8rem;
                font-weight: 600;
                padding: 8px 14px;
                border-radius: 8px;
                border: 1px solid transparent;
                cursor: pointer;
                transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease, transform 0.1s ease;
            }
            .ot-btn:active { transform: translateY(1px); }
            .ot-btn-ghost {
                background: transparent;
                color: #94a3b8;
                border-color: rgba(255, 255, 255, 0.08);
            }
            .ot-btn-ghost:hover { color: #fafafa; border-color: rgba(255, 255, 255, 0.18); }
            .ot-btn-primary {
                background: #38bdf8;
                color: #0b1220;
                border-color: #38bdf8;
            }
            .ot-btn-primary:hover { background: #7dd3fc; border-color: #7dd3fc; }
        `;
        document.head.appendChild(style);
    },
};
