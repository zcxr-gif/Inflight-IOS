/**
 * DashboardWidgets.js — Customizable Dashboard for ProfileUI
 *
 * Drag-and-drop widget grid that replaces the static Home tab.
 * Every widget reuses what's already in ProfileUI (WeatherService, _ifData,
 * _watchlist, socketDataHub, _showDrillDown, switchTab) — nothing duplicated.
 *
 *   ┌─────────────────────────────────────────────────────────────┐
 *   │  PUBLIC API                                                  │
 *   ├─────────────────────────────────────────────────────────────┤
 *   │  DashboardWidgets.attach(profile)        once at startup     │
 *   │  DashboardWidgets.injectStyles()         once at startup     │
 *   │  DashboardWidgets.getHTML()              -> dashboard markup │
 *   │  DashboardWidgets.wireListeners()        after DOM insertion │
 *   │  DashboardWidgets.unwire()               before DOM teardown │
 *   └─────────────────────────────────────────────────────────────┘
 *
 *   ┌─────────────────────────────────────────────────────────────┐
 *   │  INTEGRATION INTO profileUI.js (six small patches)           │
 *   ├─────────────────────────────────────────────────────────────┤
 *   │  1. Add at the top:                                          │
 *   │       import { DashboardWidgets } from './DashboardWidgets.js';│
 *   │                                                              │
 *   │  2. In the default `_userPrefs` object, add:                 │
 *   │       dashboard_layout: null,                                │
 *   │       dashboard_notes:  '',                                  │
 *   │       dashboard_goals:  null,                                │
 *   │                                                              │
 *   │  3. In `_inject()`, after this._injectStyles(), add:         │
 *   │       DashboardWidgets.attach(this);                         │
 *   │       DashboardWidgets.injectStyles();                       │
 *   │                                                              │
 *   │  4. In `_getTabContentHTML()`, replace the dashboard branch: │
 *   │       if (this._activeTab === 'dashboard') {                 │
 *   │           return DashboardWidgets.getHTML();                 │
 *   │       }                                                      │
 *   │                                                              │
 *   │  5. In `_attachContentListeners()`, dashboard branch:        │
 *   │       if (this._activeTab === 'dashboard') {                 │
 *   │           DashboardWidgets.wireListeners();                  │
 *   │       }                                                      │
 *   │                                                              │
 *   │  6. At the start of `_renderContentOnly()` AND `switchTab()`,│
 *   │     before the new HTML is written, add:                     │
 *   │       DashboardWidgets.unwire();                             │
 *   └─────────────────────────────────────────────────────────────┘
 *
 *   The custom-accent (hex picker) patch is at the bottom of this file
 *   under "ACCENT_HEX_PATCH" — drop it into your Settings tab markup.
 */

// ─────────────────────────────────────────────────────────────────────────────
// 1. WIDGET REGISTRY
// Each widget declares: label, icon, sizes, optional config schema, a
// renderBody(item, profile) that returns HTML, and an optional init(item,
// rootEl, profile) that hooks intervals / event listeners. init may return
// { tick, intervalMs } and the dashboard will manage the interval lifecycle.
// ─────────────────────────────────────────────────────────────────────────────

const TINTS = {
    none:    null,
    accent:  'var(--pui-accent-soft)',
    warm:    'rgba(212,165,116,0.10)',
    cool:    'rgba(95,168,211,0.10)',
    sage:    'rgba(123,191,145,0.10)',
    rose:    'rgba(224,138,168,0.10)',
    slate:   'rgba(148,163,179,0.10)',
};

const escapeHtml = (s) => String(s ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

const WIDGET_REGISTRY = {

    // ── Weather (METAR) ────────────────────────────────────────────────────
    weather: {
        label: 'Weather (METAR)',
        icon: 'fa-cloud-sun',
        description: 'Live METAR for any airport.',
        defaultSize: 'medium',
        sizes: ['small', 'medium', 'large'],
        multiple: true,
        defaultConfig: { icao: 'KJFK' },
        configFields: [
            { key: 'icao', label: 'Airport ICAO', placeholder: 'KJFK', maxlength: 4, uppercase: true }
        ],
        renderBody(item) {
            const icao = (item.config?.icao || '').toUpperCase() || '----';
            return `
                <div class="dw-wx" data-wx-icao="${escapeHtml(icao)}">
                    <div class="dw-wx-icao">${escapeHtml(icao)}</div>
                    <div class="dw-wx-skel">
                        <div class="dw-skel" style="width:60%;height:32px;"></div>
                        <div class="dw-skel" style="width:90%;height:14px;margin-top:10px;"></div>
                    </div>
                </div>
            `;
        },
        init(item, root) {
            const icao = (item.config?.icao || '').toUpperCase();
            if (!icao || icao.length < 3) {
                root.innerHTML = `<div class="dw-empty"><i class="fa-solid fa-circle-info"></i> Set an ICAO in settings.</div>`;
                return;
            }
            if (!window.WeatherService) {
                root.innerHTML = `<div class="dw-empty"><i class="fa-solid fa-triangle-exclamation"></i> Weather service unavailable.</div>`;
                return;
            }
            const tick = async () => {
                try {
                    const wx = await window.WeatherService.fetchAndParseMetar(icao);
                    const node = root.querySelector('.dw-wx');
                    if (!node) return;
                    const cond = wx.condition && wx.condition !== '---' ? wx.condition : '';
                    node.innerHTML = `
                        <div class="dw-wx-head">
                            <div class="dw-wx-icao">${escapeHtml(icao)}</div>
                            <div class="dw-wx-stamp">METAR · just now</div>
                        </div>
                        <div class="dw-wx-temp">${escapeHtml(wx.temp)}</div>
                        <div class="dw-wx-pills">
                            <span class="dw-wx-pill"><i class="fa-solid fa-wind"></i> ${escapeHtml(wx.wind)}</span>
                            ${cond ? `<span class="dw-wx-pill">${escapeHtml(cond)}</span>` : ''}
                        </div>
                        <div class="dw-wx-raw" title="${escapeHtml(wx.raw)}">${escapeHtml(wx.raw)}</div>
                    `;
                } catch (err) {
                    console.error('[dw:weather]', err);
                }
            };
            tick();
            return { tick, intervalMs: 5 * 60 * 1000 };
        },
    },

    // ── Zulu Clock ─────────────────────────────────────────────────────────
    zulu: {
        label: 'Zulu Clock',
        icon: 'fa-clock',
        description: 'UTC + your local time.',
        defaultSize: 'small',
        sizes: ['small', 'medium'],
        renderBody() {
            return `
                <div class="dw-zulu">
                    <div class="dw-zulu-utc" data-utc>--:--:--<sup>Z</sup></div>
                    <div class="dw-zulu-local" data-local>—</div>
                </div>
            `;
        },
        init(item, root) {
            const utcEl = root.querySelector('[data-utc]');
            const locEl = root.querySelector('[data-local]');
            if (!utcEl) return;
            const tick = () => {
                const now = new Date();
                utcEl.innerHTML = `${now.toISOString().substring(11, 19)}<sup>Z</sup>`;
                locEl.textContent =
                    now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) +
                    ' · ' +
                    now.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
            };
            tick();
            return { tick, intervalMs: 1000 };
        },
    },

    // ── Career Stats ───────────────────────────────────────────────────────
    stats: {
        label: 'Career Stats',
        icon: 'fa-id-card',
        description: 'Grade, XP, total flights.',
        defaultSize: 'medium',
        sizes: ['medium', 'large'],
        renderBody(item, profile) {
            const ifd = profile?._ifData;
            if (!ifd?.stats) {
                return `<div class="dw-empty"><i class="fa-solid fa-link-slash"></i> Link your Infinite Flight account in Settings.</div>`;
            }
            const grade = ifd.stats.gradeDetails?.gradeIndex ?? '—';
            const xp = (ifd.stats.totalXP ?? 0).toLocaleString();
            const flights = (ifd.logbookTotal ?? 0).toLocaleString();
            return `
                <div class="dw-stats">
                    <button class="dw-stat" data-drill="grade" type="button">
                        <span class="dw-stat-num">${escapeHtml(grade)}</span>
                        <span class="dw-stat-lbl">Grade</span>
                    </button>
                    <button class="dw-stat" data-drill="xp" type="button">
                        <span class="dw-stat-num">${xp}</span>
                        <span class="dw-stat-lbl">XP</span>
                    </button>
                    <button class="dw-stat" data-drill="flights" type="button">
                        <span class="dw-stat-num">${flights}</span>
                        <span class="dw-stat-lbl">Flights</span>
                    </button>
                </div>
            `;
        },
        init(item, root, profile) {
            root.querySelectorAll('[data-drill]').forEach(btn => {
                btn.addEventListener('click', () => {
                    profile?._showDrillDown?.(btn.dataset.drill, {});
                });
            });
        },
    },

    // ── Active Flight ──────────────────────────────────────────────────────
    'active-flight': {
        label: 'Active Flight',
        icon: 'fa-plane',
        description: 'Live progress when you\'re airborne.',
        defaultSize: 'large',
        sizes: ['medium', 'large'],
        renderBody(item, profile) {
            const f = profile?._currentFlight || profile?._ifData?.activeHistory;
            if (!f) {
                return `
                    <div class="dw-empty">
                        <i class="fa-solid fa-plane-departure dw-empty-ico"></i>
                        <div class="dw-empty-title">Not airborne</div>
                        <div class="dw-empty-sub">File a plan to see live progress here.</div>
                        <button class="dw-cta-btn" data-goto-tab="flight-plan">File a plan →</button>
                    </div>
                `;
            }
            return `
                <div class="dw-flight">
                    <div class="dw-flight-route">
                        <span class="dw-flight-icao">${escapeHtml(f.dep || '----')}</span>
                        <span class="dw-flight-line"><i class="fa-solid fa-plane"></i></span>
                        <span class="dw-flight-icao">${escapeHtml(f.arr || '----')}</span>
                    </div>
                    <div class="dw-flight-grid">
                        <div><span class="dw-flight-lbl">ALT</span><span class="dw-flight-val">${escapeHtml(f.altitude ?? '—')}</span></div>
                        <div><span class="dw-flight-lbl">SPD</span><span class="dw-flight-val">${escapeHtml(f.speed ?? '—')}</span></div>
                        <div><span class="dw-flight-lbl">ETA</span><span class="dw-flight-val">${escapeHtml(f.eta ?? '—')}</span></div>
                        <div><span class="dw-flight-lbl">A/C</span><span class="dw-flight-val">${escapeHtml(f.aircraft ?? '—')}</span></div>
                    </div>
                </div>
            `;
        },
        init(item, root, profile) {
            root.querySelector('[data-goto-tab]')?.addEventListener('click', e => {
                profile?.switchTab?.(e.currentTarget.dataset.gotoTab);
            });
        },
    },

    // ── Watchlist Pulse ────────────────────────────────────────────────────
    watchlist: {
        label: 'Watchlist Pulse',
        icon: 'fa-binoculars',
        description: 'Live status of tracked pilots.',
        defaultSize: 'medium',
        sizes: ['medium', 'large'],
        renderBody(item, profile) {
            const list = profile?._watchlist || [];
            if (!list.length) {
                return `
                    <div class="dw-empty">
                        <i class="fa-solid fa-binoculars dw-empty-ico"></i>
                        <div class="dw-empty-title">Nobody on the list</div>
                        <button class="dw-cta-btn" data-goto-tab="watchlist">Add pilots →</button>
                    </div>
                `;
            }
            const status = profile?._watchedPilotStatus || {};
            const rows = list.slice(0, 5).map(p => {
                const s = status[p.username] || {};
                const live = !!s.live;
                return `
                    <li class="dw-wl-item">
                        <span class="dw-wl-dot ${live ? 'live' : ''}"></span>
                        <span class="dw-wl-name">${escapeHtml(p.username)}</span>
                        <span class="dw-wl-status">${escapeHtml(live ? (s.callsign || 'airborne') : 'offline')}</span>
                    </li>
                `;
            }).join('');
            return `
                <ul class="dw-wl">${rows}</ul>
                ${list.length > 5 ? `<button class="dw-cta-link" data-goto-tab="watchlist">+${list.length - 5} more →</button>` : ''}
            `;
        },
        init(item, root, profile) {
            root.querySelector('[data-goto-tab]')?.addEventListener('click', e => {
                profile?.switchTab?.(e.currentTarget.dataset.gotoTab);
            });
        },
    },

    // ── Hub Monitor (compact Traffic) ──────────────────────────────────────
    hub: {
        label: 'Hub Monitor',
        icon: 'fa-tower-broadcast',
        description: 'Compact traffic snapshot for one airport.',
        defaultSize: 'medium',
        sizes: ['small', 'medium', 'large'],
        multiple: true,
        defaultConfig: { icao: 'KJFK' },
        configFields: [
            { key: 'icao', label: 'Airport ICAO', placeholder: 'KJFK', maxlength: 4, uppercase: true }
        ],
        renderBody(item) {
            const icao = (item.config?.icao || '').toUpperCase() || '----';
            return `
                <div class="dw-hub" data-hub-icao="${escapeHtml(icao)}">
                    <div class="dw-hub-icao">${escapeHtml(icao)}</div>
                    <div class="dw-hub-grid">
                        <div><span class="dw-hub-num" data-inbound>—</span><span class="dw-hub-lbl">Inbound</span></div>
                        <div><span class="dw-hub-num" data-outbound>—</span><span class="dw-hub-lbl">Outbound</span></div>
                        <div><span class="dw-hub-num" data-ground>—</span><span class="dw-hub-lbl">Ground</span></div>
                    </div>
                </div>
            `;
        },
        init(item, root, profile) {
            const icao = (item.config?.icao || '').toUpperCase();
            if (!icao) return;
            const tick = () => {
                const all = profile?._currentAllFlights || [];
                let inbound = 0, outbound = 0, ground = 0;
                for (const f of all) {
                    if (!f) continue;
                    if (f.arr === icao) inbound++;
                    if (f.dep === icao) outbound++;
                    const alt = Number(f.altitude);
                    if ((f.dep === icao || f.arr === icao) && (Number.isNaN(alt) || alt < 100)) ground++;
                }
                const i = root.querySelector('[data-inbound]');
                const o = root.querySelector('[data-outbound]');
                const g = root.querySelector('[data-ground]');
                if (i) i.textContent = inbound;
                if (o) o.textContent = outbound;
                if (g) g.textContent = ground;
            };
            tick();
            return { tick, intervalMs: 30 * 1000 };
        },
    },

    // ── Notes ──────────────────────────────────────────────────────────────
    notes: {
        label: 'Notes',
        icon: 'fa-note-sticky',
        description: 'Auto-saving scratchpad.',
        defaultSize: 'medium',
        sizes: ['small', 'medium', 'large'],
        renderBody(item, profile) {
            const text = profile?._userPrefs?.dashboard_notes || '';
            return `<textarea class="dw-notes" data-notes placeholder="Jot anything…">${escapeHtml(text)}</textarea>`;
        },
        init(item, root, profile) {
            const ta = root.querySelector('[data-notes]');
            if (!ta) return;
            let timer;
            ta.addEventListener('input', () => {
                clearTimeout(timer);
                timer = setTimeout(() => {
                    if (profile?._userPrefs) {
                        profile._userPrefs.dashboard_notes = ta.value;
                        profile._persistUserPrefs?.();
                    }
                }, 500);
            });
        },
    },

    // ── Quick Dispatch ─────────────────────────────────────────────────────
    'quick-dispatch': {
        label: 'Quick Dispatch',
        icon: 'fa-route',
        description: 'Shortcut to file a plan.',
        defaultSize: 'small',
        sizes: ['small', 'medium'],
        renderBody() {
            return `
                <button class="dw-cta-tile" data-goto-tab="flight-plan" type="button">
                    <i class="fa-solid fa-route"></i>
                    <span>File a flight</span>
                </button>
            `;
        },
        init(item, root, profile) {
            root.querySelector('[data-goto-tab]')?.addEventListener('click', e => {
                profile?.switchTab?.(e.currentTarget.dataset.gotoTab);
            });
        },
    },

    // ── Pilot Card ─────────────────────────────────────────────────────────
    'pilot-card': {
        label: 'Pilot Card',
        icon: 'fa-id-badge',
        description: 'Your callsign, grade, bio.',
        defaultSize: 'medium',
        sizes: ['medium', 'large'],
        renderBody(item, profile) {
            const u = profile?._currentUser;
            const name = u?.user_metadata?.full_name || u?.user_metadata?.name || 'Captain';
            const ifu = u?.user_metadata?.if_username || '—';
            const bio = profile?._bio || 'Set a bio in Settings →';
            const grade = profile?._ifData?.stats?.gradeDetails?.gradeIndex ?? '—';
            return `
                <div class="dw-card-pilot">
                    <div class="dw-card-row">
                        <div class="dw-card-name">${escapeHtml(name)}</div>
                        <div class="dw-card-grade">Grade ${escapeHtml(grade)}</div>
                    </div>
                    <div class="dw-card-handle">@${escapeHtml(ifu)}</div>
                    <div class="dw-card-bio">${escapeHtml(bio)}</div>
                </div>
            `;
        },
    },

    // ── Goals & Streaks ────────────────────────────────────────────────────
    goals: {
        label: 'Goals & Streaks',
        icon: 'fa-bullseye',
        description: 'Personal targets with progress bars.',
        defaultSize: 'medium',
        sizes: ['medium', 'large'],
        renderBody(item, profile) {
            const goals = profile?._userPrefs?.dashboard_goals || [
                { id: 'g1', label: 'Hours this month', current: 0, target: 20 },
                { id: 'g2', label: 'New airports', current: 0, target: 5 },
                { id: 'g3', label: 'Days flown (streak)', current: 0, target: 7 },
            ];
            return `
                <ul class="dw-goals">
                    ${goals.map(g => {
                        const pct = Math.min(100, Math.max(0, Math.round((g.current / Math.max(1, g.target)) * 100)));
                        return `
                            <li class="dw-goal">
                                <div class="dw-goal-row">
                                    <span>${escapeHtml(g.label)}</span>
                                    <span class="dw-goal-num">${g.current}/${g.target}</span>
                                </div>
                                <div class="dw-goal-bar"><div class="dw-goal-fill" style="width:${pct}%"></div></div>
                            </li>
                        `;
                    }).join('')}
                </ul>
            `;
        },
    },
};

const DEFAULT_LAYOUT = [
    { id: 'zulu-1',     type: 'zulu',           size: 'small',  config: {},               tint: 'none' },
    { id: 'stats-1',    type: 'stats',          size: 'medium', config: {},               tint: 'accent' },
    { id: 'wx-1',       type: 'weather',        size: 'medium', config: { icao: 'KJFK' }, tint: 'cool' },
    { id: 'flight-1',   type: 'active-flight',  size: 'large',  config: {},               tint: 'none' },
    { id: 'watch-1',    type: 'watchlist',      size: 'medium', config: {},               tint: 'none' },
    { id: 'hub-1',      type: 'hub',            size: 'medium', config: { icao: 'KJFK' }, tint: 'sage' },
    { id: 'goals-1',    type: 'goals',          size: 'medium', config: {},               tint: 'warm' },
    { id: 'notes-1',    type: 'notes',          size: 'small',  config: {},               tint: 'rose' },
    { id: 'dispatch-1', type: 'quick-dispatch', size: 'small',  config: {},               tint: 'accent' },
];

// ─────────────────────────────────────────────────────────────────────────────
// 2. THE MODULE
// ─────────────────────────────────────────────────────────────────────────────

export const DashboardWidgets = {
    _profile: null,
    _layout: [],
    _editMode: false,
    _draggedId: null,
    _intervals: new Map(),
    _stylesInjected: false,
    _registry: WIDGET_REGISTRY,
    _activeModal: null,

    // ── lifecycle ──────────────────────────────────────────────────────────
    attach(profile) {
        this._profile = profile;
        this._loadLayout();
    },

    _loadLayout() {
        const stored = this._profile?._userPrefs?.dashboard_layout;
        if (Array.isArray(stored) && stored.length) {
            this._layout = stored.map(it => ({ tint: 'none', ...it }));
        } else {
            this._layout = JSON.parse(JSON.stringify(DEFAULT_LAYOUT));
        }
    },

    _persistLayout() {
        if (!this._profile?._userPrefs) return;
        this._profile._userPrefs.dashboard_layout = JSON.parse(JSON.stringify(this._layout));
        this._profile._persistUserPrefs?.();
    },

    // ── rendering ──────────────────────────────────────────────────────────
    getHTML() {
        const items = this._layout.map(item => this._renderWidgetShell(item)).join('');
        const subtitle = this._editMode
            ? 'Drag tiles to rearrange. Use the controls to remove, resize, or recolor.'
            : 'Your live flight deck.';

        return `
            <div class="dw-root pui-fade-in" data-edit="${this._editMode ? 'true' : 'false'}">
                <header class="dw-bar">
                    <div class="dw-bar-title">
                        <h2>Home</h2>
                        <p>${subtitle}</p>
                    </div>
                    <div class="dw-bar-actions">
                        ${this._editMode ? `
                            <button class="dw-btn dw-btn-ghost" data-dw-action="reset" type="button"><i class="fa-solid fa-rotate-left"></i> Reset</button>
                            <button class="dw-btn dw-btn-ghost" data-dw-action="add"   type="button"><i class="fa-solid fa-plus"></i> Add tile</button>
                            <button class="dw-btn dw-btn-primary" data-dw-action="done"  type="button"><i class="fa-solid fa-check"></i> Done</button>
                        ` : `
                            <button class="dw-btn dw-btn-ghost" data-dw-action="edit" type="button"><i class="fa-solid fa-table-cells-large"></i> Customize</button>
                        `}
                    </div>
                </header>

                <div class="dw-grid" data-dw-grid>
                    ${items || `<div class="dw-empty-grid"><i class="fa-solid fa-puzzle-piece"></i> No tiles. <button class="dw-link" data-dw-action="add" type="button">Add one →</button></div>`}
                </div>

                <div data-dw-modal-mount></div>
            </div>
        `;
    },

    _renderWidgetShell(item) {
        const def = this._registry[item.type];
        if (!def) {
            return `
                <article class="dw-widget dw-widget-error" data-widget-id="${item.id}" data-size="${item.size}">
                    <div class="dw-widget-body">Unknown widget type: ${escapeHtml(item.type)}</div>
                </article>
            `;
        }
        const tint = TINTS[item.tint] || null;
        const tintStyle = tint ? `style="background:${tint};"` : '';
        const sizeBadge = (item.size || 'medium').charAt(0).toUpperCase();
        const showSettings = (def.configFields?.length || def.multiple) && this._editMode;

        return `
            <article class="dw-widget"
                     data-widget-id="${escapeHtml(item.id)}"
                     data-widget-type="${escapeHtml(item.type)}"
                     data-size="${escapeHtml(item.size)}"
                     ${tintStyle}
                     draggable="${this._editMode ? 'true' : 'false'}">
                <header class="dw-widget-header">
                    <span class="dw-widget-title">
                        <i class="fa-solid ${def.icon}"></i>
                        <span>${escapeHtml(def.label)}</span>
                    </span>
                    <div class="dw-widget-tools" ${this._editMode ? '' : 'hidden'}>
                        ${this._editMode ? `
                            <button class="dw-widget-tool" data-tool="up"          title="Move up"   type="button"><i class="fa-solid fa-chevron-up"></i></button>
                            <button class="dw-widget-tool" data-tool="down"        title="Move down" type="button"><i class="fa-solid fa-chevron-down"></i></button>
                            <button class="dw-widget-tool" data-tool="size-cycle"  title="Resize"    type="button">${sizeBadge}</button>
                            ${showSettings ? `<button class="dw-widget-tool" data-tool="settings" title="Settings" type="button"><i class="fa-solid fa-gear"></i></button>` : ''}
                            <button class="dw-widget-tool" data-tool="tint"        title="Color"     type="button"><i class="fa-solid fa-palette"></i></button>
                            <button class="dw-widget-tool dw-widget-tool-danger" data-tool="remove" title="Remove" type="button"><i class="fa-solid fa-xmark"></i></button>
                        ` : ''}
                    </div>
                </header>
                <div class="dw-widget-body" data-widget-body>
                    ${def.renderBody(item, this._profile) || ''}
                </div>
            </article>
        `;
    },

    // ── listeners ──────────────────────────────────────────────────────────
    wireListeners() {
        const root = document.querySelector('.dw-root');
        if (!root) return;

        // Toolbar actions (edit / done / add / reset)
        root.querySelectorAll('[data-dw-action]').forEach(btn => {
            btn.addEventListener('click', e => {
                e.preventDefault();
                this._onBarAction(e.currentTarget.dataset.dwAction);
            });
        });

        // Per-widget initializers
        for (const item of this._layout) this._initWidget(item);

        // Edit-mode interactions
        if (this._editMode) this._wireEditMode(root);
    },

    _initWidget(item) {
        const root = document.querySelector(`[data-widget-id="${cssEscape(item.id)}"] [data-widget-body]`);
        if (!root) return;
        const def = this._registry[item.type];
        if (!def?.init) return;
        try {
            const result = def.init(item, root, this._profile);
            if (result && typeof result.tick === 'function' && result.intervalMs) {
                const id = setInterval(() => {
                    const node = document.querySelector(`[data-widget-id="${cssEscape(item.id)}"]`);
                    if (!node) return;
                    try { result.tick(); } catch (err) { console.error(`[dw:${item.type}] tick`, err); }
                }, result.intervalMs);
                this._intervals.set(item.id, id);
            }
        } catch (err) {
            console.error(`[dw:${item.type}] init failed`, err);
        }
    },

    unwire() {
        for (const id of this._intervals.values()) clearInterval(id);
        this._intervals.clear();
        this._closeModal();
    },

    // ── bar actions ────────────────────────────────────────────────────────
    _onBarAction(action) {
        switch (action) {
            case 'edit':  this._setEditMode(true); break;
            case 'done':  this._setEditMode(false); this._persistLayout(); break;
            case 'add':   this._openAddPalette(); break;
            case 'reset': this._confirmReset(); break;
        }
    },

    _setEditMode(on) {
        this._editMode = on;
        this._rerender();
    },

    _rerender() {
        this.unwire();
        // Defer to ProfileUI so the whole content area stays in sync
        if (typeof this._profile?._renderContentOnly === 'function') {
            this._profile._renderContentOnly();
        } else {
            // Fallback: re-render in place
            const root = document.querySelector('.dw-root');
            if (root) {
                root.outerHTML = this.getHTML();
                this.wireListeners();
            }
        }
    },

    _confirmReset() {
        if (!confirm('Reset the dashboard to its default layout?')) return;
        this._layout = JSON.parse(JSON.stringify(DEFAULT_LAYOUT));
        this._persistLayout();
        this._rerender();
    },

    // ── edit-mode wiring (DnD + tool buttons) ──────────────────────────────
    _wireEditMode(root) {
        const grid = root.querySelector('[data-dw-grid]');
        if (!grid) return;

        // ── HTML5 drag-and-drop (desktop) ──
        grid.addEventListener('dragstart', e => {
            const w = e.target.closest('.dw-widget');
            if (!w) return;
            this._draggedId = w.dataset.widgetId;
            w.classList.add('dw-dragging');
            try {
                e.dataTransfer.effectAllowed = 'move';
                e.dataTransfer.setData('text/plain', this._draggedId);
            } catch (_) {}
        });

        grid.addEventListener('dragover', e => {
            const target = e.target.closest('.dw-widget');
            if (!target) return;
            e.preventDefault();
            if (target.dataset.widgetId === this._draggedId) return;
            grid.querySelectorAll('.dw-drag-over').forEach(n => n.classList.remove('dw-drag-over'));
            target.classList.add('dw-drag-over');
        });

        grid.addEventListener('dragleave', e => {
            const target = e.target.closest('.dw-widget');
            if (target) target.classList.remove('dw-drag-over');
        });

        grid.addEventListener('drop', e => {
            const target = e.target.closest('.dw-widget');
            if (!target || !this._draggedId) return;
            e.preventDefault();
            if (target.dataset.widgetId === this._draggedId) return;
            this._moveItem(this._draggedId, target.dataset.widgetId);
        });

        grid.addEventListener('dragend', () => {
            grid.querySelectorAll('.dw-drag-over, .dw-dragging').forEach(n =>
                n.classList.remove('dw-drag-over', 'dw-dragging')
            );
            this._draggedId = null;
        });

        // ── Tool buttons (delegated) ──
        grid.addEventListener('click', e => {
            const tool = e.target.closest('[data-tool]');
            if (!tool) return;
            const widget = tool.closest('.dw-widget');
            if (!widget) return;
            e.stopPropagation();
            const id = widget.dataset.widgetId;
            const action = tool.dataset.tool;
            switch (action) {
                case 'remove':     this._removeItem(id); break;
                case 'size-cycle': this._cycleSize(id); break;
                case 'settings':   this._openSettings(id); break;
                case 'tint':       this._openTintPicker(id, tool); break;
                case 'up':         this._nudge(id, -1); break;
                case 'down':       this._nudge(id, +1); break;
            }
        });
    },

    // ── layout mutators ────────────────────────────────────────────────────
    _moveItem(fromId, toId) {
        const fromIdx = this._layout.findIndex(i => i.id === fromId);
        const toIdx = this._layout.findIndex(i => i.id === toId);
        if (fromIdx < 0 || toIdx < 0) return;
        const [moved] = this._layout.splice(fromIdx, 1);
        this._layout.splice(toIdx, 0, moved);
        this._rerender();
    },

    _nudge(id, delta) {
        const idx = this._layout.findIndex(i => i.id === id);
        if (idx < 0) return;
        const newIdx = Math.max(0, Math.min(this._layout.length - 1, idx + delta));
        if (newIdx === idx) return;
        const [moved] = this._layout.splice(idx, 1);
        this._layout.splice(newIdx, 0, moved);
        this._rerender();
    },

    _removeItem(id) {
        this._layout = this._layout.filter(i => i.id !== id);
        this._rerender();
    },

    _cycleSize(id) {
        const item = this._layout.find(i => i.id === id);
        if (!item) return;
        const def = this._registry[item.type];
        const sizes = def?.sizes || ['small', 'medium', 'large'];
        const cur = sizes.indexOf(item.size);
        item.size = sizes[(cur + 1) % sizes.length];
        this._rerender();
    },

    _setTint(id, tintKey) {
        const item = this._layout.find(i => i.id === id);
        if (!item) return;
        item.tint = tintKey;
        this._rerender();
    },

    // ── modal helpers ──────────────────────────────────────────────────────
    _openModal(html, onWire) {
        this._closeModal();
        const mount = document.querySelector('[data-dw-modal-mount]');
        if (!mount) return;
        mount.innerHTML = `<div class="dw-modal-backdrop" data-dw-close-modal>${html}</div>`;
        const backdrop = mount.querySelector('[data-dw-close-modal]');
        backdrop.addEventListener('click', e => {
            if (e.target === backdrop) this._closeModal();
        });
        this._activeModal = backdrop;
        if (typeof onWire === 'function') onWire(backdrop);
    },

    _closeModal() {
        const mount = document.querySelector('[data-dw-modal-mount]');
        if (mount) mount.innerHTML = '';
        this._activeModal = null;
    },

    _openAddPalette() {
        const used = new Set(this._layout.map(i => i.type));
        const items = Object.entries(this._registry).map(([type, def]) => {
            const disabled = used.has(type) && !def.multiple;
            return `
                <li class="dw-palette-item ${disabled ? 'is-disabled' : ''}">
                    <div class="dw-palette-icon"><i class="fa-solid ${def.icon}"></i></div>
                    <div class="dw-palette-text">
                        <strong>${escapeHtml(def.label)}</strong>
                        <span>${escapeHtml(def.description || '')}</span>
                    </div>
                    <button class="dw-btn dw-btn-primary dw-btn-sm" data-add-type="${escapeHtml(type)}" ${disabled ? 'disabled' : ''} type="button">
                        ${disabled ? 'Added' : 'Add'}
                    </button>
                </li>
            `;
        }).join('');

        const html = `
            <div class="dw-modal" role="dialog" aria-label="Add tile">
                <header class="dw-modal-head">
                    <h3>Add a tile</h3>
                    <button class="dw-modal-close" data-dw-close-modal type="button"><i class="fa-solid fa-xmark"></i></button>
                </header>
                <ul class="dw-palette">${items}</ul>
            </div>
        `;

        this._openModal(html, (backdrop) => {
            backdrop.querySelectorAll('[data-add-type]').forEach(btn => {
                btn.addEventListener('click', () => {
                    this._addItem(btn.dataset.addType);
                    this._closeModal();
                });
            });
            backdrop.querySelector('[data-dw-close-modal]')?.addEventListener('click', () => this._closeModal());
        });
    },

    _addItem(type) {
        const def = this._registry[type];
        if (!def) return;
        const id = `${type}-${Date.now().toString(36)}`;
        this._layout.push({
            id,
            type,
            size: def.defaultSize || 'medium',
            config: { ...(def.defaultConfig || {}) },
            tint: 'none',
        });
        this._rerender();
    },

    _openSettings(id) {
        const item = this._layout.find(i => i.id === id);
        if (!item) return;
        const def = this._registry[item.type];
        if (!def?.configFields?.length) return;

        const fields = def.configFields.map(f => {
            const v = item.config?.[f.key] ?? '';
            return `
                <label class="dw-field">
                    <span>${escapeHtml(f.label)}</span>
                    <input type="text"
                           data-cfg-key="${escapeHtml(f.key)}"
                           value="${escapeHtml(v)}"
                           placeholder="${escapeHtml(f.placeholder || '')}"
                           ${f.maxlength ? `maxlength="${f.maxlength}"` : ''}
                           ${f.uppercase ? 'data-uppercase' : ''}>
                </label>
            `;
        }).join('');

        const html = `
            <div class="dw-modal" role="dialog" aria-label="${escapeHtml(def.label)} settings">
                <header class="dw-modal-head">
                    <h3>${escapeHtml(def.label)} settings</h3>
                    <button class="dw-modal-close" data-dw-close-modal type="button"><i class="fa-solid fa-xmark"></i></button>
                </header>
                <div class="dw-modal-body">${fields}</div>
                <footer class="dw-modal-foot">
                    <button class="dw-btn dw-btn-ghost"   data-dw-close-modal type="button">Cancel</button>
                    <button class="dw-btn dw-btn-primary" data-cfg-save     type="button">Save</button>
                </footer>
            </div>
        `;

        this._openModal(html, (backdrop) => {
            backdrop.querySelectorAll('[data-uppercase]').forEach(inp => {
                inp.addEventListener('input', () => { inp.value = inp.value.toUpperCase(); });
            });
            backdrop.querySelector('[data-cfg-save]')?.addEventListener('click', () => {
                const next = { ...(item.config || {}) };
                backdrop.querySelectorAll('[data-cfg-key]').forEach(inp => {
                    next[inp.dataset.cfgKey] = inp.value.trim();
                });
                item.config = next;
                this._closeModal();
                this._rerender();
            });
            backdrop.querySelectorAll('[data-dw-close-modal]').forEach(b =>
                b.addEventListener('click', () => this._closeModal())
            );
        });
    },

    _openTintPicker(id, anchorBtn) {
        const item = this._layout.find(i => i.id === id);
        if (!item) return;
        const swatches = Object.keys(TINTS).map(k => `
            <button class="dw-tint-swatch ${item.tint === k ? 'is-active' : ''}"
                    data-tint="${k}"
                    title="${k}"
                    type="button"
                    style="background:${TINTS[k] || 'transparent'};"></button>
        `).join('');

        const html = `
            <div class="dw-modal dw-modal-narrow" role="dialog" aria-label="Choose tile color">
                <header class="dw-modal-head">
                    <h3>Tile color</h3>
                    <button class="dw-modal-close" data-dw-close-modal type="button"><i class="fa-solid fa-xmark"></i></button>
                </header>
                <div class="dw-modal-body">
                    <div class="dw-tint-grid">${swatches}</div>
                </div>
            </div>
        `;

        this._openModal(html, (backdrop) => {
            backdrop.querySelectorAll('[data-tint]').forEach(sw => {
                sw.addEventListener('click', () => {
                    this._setTint(id, sw.dataset.tint);
                    this._closeModal();
                });
            });
            backdrop.querySelector('[data-dw-close-modal]')?.addEventListener('click', () => this._closeModal());
        });
    },

    // ── styles ─────────────────────────────────────────────────────────────
    injectStyles() {
        if (this._stylesInjected) return;
        const style = document.createElement('style');
        style.id = 'dw-styles';
        style.textContent = DASHBOARD_CSS;
        document.head.appendChild(style);
        this._stylesInjected = true;
    },
};

// ─────────────────────────────────────────────────────────────────────────────
// 3. UTIL
// ─────────────────────────────────────────────────────────────────────────────

// CSS.escape polyfill-ish — needed because widget IDs may contain dashes/digits
function cssEscape(s) {
    if (typeof CSS !== 'undefined' && CSS.escape) return CSS.escape(s);
    return String(s).replace(/[^a-zA-Z0-9_-]/g, ch => '\\' + ch);
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. STYLES
// All variables prefixed --pui-* are inherited from the host ProfileUI styles.
// The widgets cleanly fall back to neutral defaults if a host var is missing.
// ─────────────────────────────────────────────────────────────────────────────

const DASHBOARD_CSS = `
.dw-root {
    display: flex;
    flex-direction: column;
    gap: 18px;
}

.dw-bar {
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    gap: 16px;
    flex-wrap: wrap;
}
.dw-bar-title h2 {
    margin: 0 0 4px;
    font-size: 1.55rem;
    font-weight: 700;
    letter-spacing: -0.01em;
    color: var(--pui-text-primary, #232323);
}
.dw-bar-title p {
    margin: 0;
    font-size: 0.88rem;
    color: var(--pui-text-secondary, #6b6b6b);
}
.dw-bar-actions { display: flex; gap: 8px; }

.dw-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 9px 14px;
    border-radius: 10px;
    border: 1px solid transparent;
    font-size: 0.84rem;
    font-weight: 600;
    font-family: inherit;
    cursor: pointer;
    transition: background-color 120ms ease, transform 120ms ease, border-color 120ms ease;
    background: transparent;
}
.dw-btn-sm { padding: 6px 10px; font-size: 0.78rem; }
.dw-btn-ghost {
    background: var(--pui-bg-surface, #f3efe9);
    color: var(--pui-text-primary, #232323);
    border-color: var(--pui-border-light, rgba(0,0,0,0.06));
}
.dw-btn-ghost:hover { background: var(--pui-bg-card, #fff); }
.dw-btn-primary {
    background: var(--pui-accent, #b88553);
    color: #fff;
    box-shadow: 0 2px 6px rgba(0,0,0,0.12);
}
.dw-btn-primary:hover { background: var(--pui-accent-hover, #a87543); }
.dw-btn:active { transform: translateY(1px); }
.dw-btn[disabled] { opacity: .5; cursor: not-allowed; }

.dw-link {
    background: none;
    border: 0;
    color: var(--pui-accent, #b88553);
    font: inherit;
    cursor: pointer;
    padding: 0;
}

/* ── grid ────────────────────────────────────────────────────────────── */
.dw-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 14px;
    grid-auto-rows: minmax(140px, auto);
}
.dw-empty-grid {
    grid-column: 1 / -1;
    padding: 40px;
    text-align: center;
    color: var(--pui-text-secondary, #6b6b6b);
    border: 1px dashed var(--pui-border, rgba(0,0,0,0.08));
    border-radius: 14px;
}
.dw-empty-grid i { margin-right: 6px; }

/* ── widget shell ────────────────────────────────────────────────────── */
.dw-widget {
    position: relative;
    background: var(--pui-bg-card, #fff);
    border: 1px solid var(--pui-border, rgba(0,0,0,0.06));
    border-radius: 14px;
    padding: 14px 14px 12px;
    box-shadow: 0 1px 2px rgba(0,0,0,0.04);
    display: flex;
    flex-direction: column;
    gap: 10px;
    overflow: hidden;
    transition: box-shadow 140ms ease, transform 140ms ease, border-color 140ms ease, opacity 140ms ease;
}
.dw-widget:hover { box-shadow: 0 4px 14px rgba(0,0,0,0.06); }
.dw-widget[data-size="small"]  { grid-column: span 1; }
.dw-widget[data-size="medium"] { grid-column: span 2; }
.dw-widget[data-size="large"]  { grid-column: span 4; }

.dw-widget[draggable="true"] { cursor: grab; }
.dw-widget.dw-dragging { opacity: .35; }
.dw-widget.dw-drag-over {
    border-color: var(--pui-accent, #b88553);
    box-shadow: 0 0 0 3px var(--pui-accent-soft, rgba(184,133,83,0.18));
}

.dw-root[data-edit="true"] .dw-widget {
    border-style: dashed;
}

.dw-widget-error { background: rgba(220, 60, 60, 0.06); }

.dw-widget-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    min-height: 22px;
}
.dw-widget-title {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 0.82rem;
    font-weight: 600;
    color: var(--pui-text-secondary, #6b6b6b);
    letter-spacing: 0.01em;
}
.dw-widget-title i { color: var(--pui-accent, #b88553); }

.dw-widget-tools {
    display: flex;
    gap: 4px;
    align-items: center;
}
.dw-widget-tool {
    width: 28px;
    height: 28px;
    border-radius: 8px;
    border: 1px solid var(--pui-border-light, rgba(0,0,0,0.06));
    background: var(--pui-bg-surface, #f3efe9);
    color: var(--pui-text-secondary, #6b6b6b);
    font-size: 0.72rem;
    font-weight: 700;
    cursor: pointer;
    display: grid;
    place-items: center;
    transition: background 120ms ease, color 120ms ease;
}
.dw-widget-tool:hover {
    background: var(--pui-accent-soft, rgba(184,133,83,0.18));
    color: var(--pui-accent, #b88553);
}
.dw-widget-tool-danger:hover {
    background: rgba(220, 60, 60, 0.12);
    color: rgb(180, 40, 40);
}

.dw-widget-body {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 8px;
    min-height: 0;
}

/* ── empty / cta ─────────────────────────────────────────────────────── */
.dw-empty {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 6px;
    color: var(--pui-text-secondary, #6b6b6b);
    text-align: center;
    padding: 16px 8px;
}
.dw-empty-ico {
    font-size: 1.6rem;
    color: var(--pui-text-secondary, #6b6b6b);
    opacity: .7;
}
.dw-empty-title { font-weight: 600; color: var(--pui-text-primary, #232323); }
.dw-empty-sub { font-size: 0.82rem; }
.dw-cta-btn {
    margin-top: 6px;
    border: 0;
    background: var(--pui-accent, #b88553);
    color: #fff;
    font-family: inherit;
    font-weight: 600;
    font-size: 0.84rem;
    padding: 8px 14px;
    border-radius: 9px;
    cursor: pointer;
}
.dw-cta-btn:hover { background: var(--pui-accent-hover, #a87543); }
.dw-cta-link {
    margin-top: 8px;
    background: none;
    border: 0;
    color: var(--pui-accent, #b88553);
    font: inherit;
    font-weight: 600;
    cursor: pointer;
    padding: 0;
    text-align: left;
}
.dw-cta-tile {
    flex: 1;
    border: 0;
    background: var(--pui-accent, #b88553);
    color: #fff;
    border-radius: 12px;
    cursor: pointer;
    font: inherit;
    font-weight: 600;
    display: flex;
    flex-direction: column;
    gap: 8px;
    align-items: center;
    justify-content: center;
}
.dw-cta-tile i { font-size: 1.5rem; }

/* ── skeleton ────────────────────────────────────────────────────────── */
.dw-skel {
    background: var(--pui-bg-surface, #f3efe9);
    border-radius: 6px;
    animation: dw-pulse 1.4s ease-in-out infinite;
}
@keyframes dw-pulse { 0%, 100% { opacity: 1; } 50% { opacity: .55; } }

/* ── weather widget ──────────────────────────────────────────────────── */
.dw-wx { display: flex; flex-direction: column; gap: 6px; height: 100%; }
.dw-wx-head { display: flex; justify-content: space-between; align-items: baseline; }
.dw-wx-icao { font-family: var(--pui-font-mono, monospace); font-size: 1.1rem; font-weight: 700; letter-spacing: 0.02em; color: var(--pui-text-primary, #232323); }
.dw-wx-stamp { font-size: 0.72rem; color: var(--pui-text-secondary, #6b6b6b); }
.dw-wx-temp { font-size: 1.85rem; font-weight: 700; color: var(--pui-text-primary, #232323); line-height: 1; }
.dw-wx-pills { display: flex; gap: 6px; flex-wrap: wrap; }
.dw-wx-pill {
    display: inline-flex; gap: 5px; align-items: center;
    padding: 3px 9px;
    background: var(--pui-bg-surface, #f3efe9);
    border-radius: 999px;
    font-size: 0.74rem;
    font-weight: 500;
    color: var(--pui-text-secondary, #6b6b6b);
    font-family: var(--pui-font-mono, monospace);
}
.dw-wx-raw {
    margin-top: auto;
    font-family: var(--pui-font-mono, monospace);
    font-size: 0.66rem;
    color: var(--pui-text-secondary, #6b6b6b);
    opacity: .75;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

/* ── zulu clock ──────────────────────────────────────────────────────── */
.dw-zulu { display: flex; flex-direction: column; gap: 4px; align-items: center; justify-content: center; flex: 1; }
.dw-zulu-utc { font-family: var(--pui-font-mono, monospace); font-size: 1.85rem; font-weight: 700; color: var(--pui-text-primary, #232323); letter-spacing: 0.02em; }
.dw-zulu-utc sup { font-size: 0.55em; color: var(--pui-accent, #b88553); margin-left: 2px; }
.dw-zulu-local { font-size: 0.78rem; color: var(--pui-text-secondary, #6b6b6b); text-align: center; }

/* ── stats ──────────────────────────────────────────────────────────── */
.dw-stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; flex: 1; }
.dw-stat {
    display: flex;
    flex-direction: column;
    gap: 4px;
    align-items: center;
    justify-content: center;
    padding: 10px 6px;
    background: var(--pui-bg-surface, #f3efe9);
    border: 1px solid var(--pui-border-light, rgba(0,0,0,0.06));
    border-radius: 10px;
    cursor: pointer;
    font: inherit;
    color: inherit;
    transition: background 120ms ease, transform 120ms ease;
}
.dw-stat:hover { background: var(--pui-accent-soft, rgba(184,133,83,0.18)); }
.dw-stat:active { transform: translateY(1px); }
.dw-stat-num { font-size: 1.3rem; font-weight: 700; color: var(--pui-text-primary, #232323); }
.dw-stat-lbl { font-size: 0.7rem; color: var(--pui-text-secondary, #6b6b6b); text-transform: uppercase; letter-spacing: 0.05em; }

/* ── active flight ───────────────────────────────────────────────────── */
.dw-flight { display: flex; flex-direction: column; gap: 14px; flex: 1; }
.dw-flight-route {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 14px;
    padding: 8px 0;
}
.dw-flight-icao { font-family: var(--pui-font-mono, monospace); font-size: 1.6rem; font-weight: 700; color: var(--pui-text-primary, #232323); letter-spacing: 0.02em; }
.dw-flight-line {
    flex: 1;
    max-width: 200px;
    height: 1px;
    background: var(--pui-border, rgba(0,0,0,0.08));
    position: relative;
}
.dw-flight-line i {
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    color: var(--pui-accent, #b88553);
    background: var(--pui-bg-card, #fff);
    padding: 0 6px;
}
.dw-flight-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 8px;
}
.dw-flight-grid > div {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 8px;
    background: var(--pui-bg-surface, #f3efe9);
    border-radius: 8px;
    text-align: center;
}
.dw-flight-lbl { font-size: 0.66rem; color: var(--pui-text-secondary, #6b6b6b); letter-spacing: 0.06em; }
.dw-flight-val { font-size: 0.95rem; font-weight: 700; color: var(--pui-text-primary, #232323); font-family: var(--pui-font-mono, monospace); }

/* ── watchlist ──────────────────────────────────────────────────────── */
.dw-wl { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 6px; flex: 1; }
.dw-wl-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 8px;
    background: var(--pui-bg-surface, #f3efe9);
    border-radius: 8px;
    font-size: 0.82rem;
}
.dw-wl-dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--pui-text-secondary, #6b6b6b);
    opacity: .4;
    flex-shrink: 0;
}
.dw-wl-dot.live {
    background: #2e9e5f;
    opacity: 1;
    box-shadow: 0 0 0 3px rgba(46, 158, 95, 0.18);
    animation: dw-pulse 2s ease-in-out infinite;
}
.dw-wl-name { flex: 1; font-weight: 600; color: var(--pui-text-primary, #232323); }
.dw-wl-status { font-size: 0.72rem; color: var(--pui-text-secondary, #6b6b6b); font-family: var(--pui-font-mono, monospace); }

/* ── hub ─────────────────────────────────────────────────────────────── */
.dw-hub { display: flex; flex-direction: column; gap: 10px; flex: 1; }
.dw-hub-icao { font-family: var(--pui-font-mono, monospace); font-size: 1.1rem; font-weight: 700; color: var(--pui-text-primary, #232323); }
.dw-hub-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; flex: 1; align-items: stretch; }
.dw-hub-grid > div {
    display: flex; flex-direction: column; gap: 2px; align-items: center; justify-content: center;
    padding: 10px 6px;
    background: var(--pui-bg-surface, #f3efe9);
    border-radius: 8px;
}
.dw-hub-num { font-size: 1.3rem; font-weight: 700; color: var(--pui-text-primary, #232323); font-family: var(--pui-font-mono, monospace); }
.dw-hub-lbl { font-size: 0.66rem; color: var(--pui-text-secondary, #6b6b6b); letter-spacing: 0.05em; text-transform: uppercase; }

/* ── notes ───────────────────────────────────────────────────────────── */
.dw-notes {
    flex: 1;
    width: 100%;
    min-height: 100px;
    border: 1px solid var(--pui-border-light, rgba(0,0,0,0.06));
    border-radius: 10px;
    background: var(--pui-bg-surface, #f3efe9);
    padding: 10px 12px;
    font-family: inherit;
    font-size: 0.86rem;
    color: var(--pui-text-primary, #232323);
    resize: none;
    transition: border-color 120ms ease;
}
.dw-notes:focus { border-color: var(--pui-accent, #b88553); outline: none; }

/* ── pilot card ──────────────────────────────────────────────────────── */
.dw-card-pilot { display: flex; flex-direction: column; gap: 6px; flex: 1; justify-content: center; }
.dw-card-row { display: flex; justify-content: space-between; align-items: baseline; }
.dw-card-name { font-size: 1.1rem; font-weight: 700; color: var(--pui-text-primary, #232323); }
.dw-card-grade {
    background: var(--pui-accent, #b88553);
    color: #fff;
    border-radius: 999px;
    padding: 2px 10px;
    font-size: 0.72rem;
    font-weight: 600;
}
.dw-card-handle { font-family: var(--pui-font-mono, monospace); font-size: 0.78rem; color: var(--pui-text-secondary, #6b6b6b); }
.dw-card-bio { font-size: 0.82rem; color: var(--pui-text-secondary, #6b6b6b); margin-top: 4px; line-height: 1.4; }

/* ── goals ───────────────────────────────────────────────────────────── */
.dw-goals { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 10px; flex: 1; }
.dw-goal { display: flex; flex-direction: column; gap: 4px; }
.dw-goal-row { display: flex; justify-content: space-between; font-size: 0.82rem; color: var(--pui-text-primary, #232323); }
.dw-goal-num { font-family: var(--pui-font-mono, monospace); font-weight: 600; color: var(--pui-text-secondary, #6b6b6b); }
.dw-goal-bar { height: 5px; background: var(--pui-bg-surface, #f3efe9); border-radius: 999px; overflow: hidden; }
.dw-goal-fill { height: 100%; background: var(--pui-accent, #b88553); border-radius: 999px; transition: width 320ms ease; }

/* ── modal ───────────────────────────────────────────────────────────── */
.dw-modal-backdrop {
    position: fixed; inset: 0;
    background: rgba(0, 0, 0, 0.35);
    display: grid;
    place-items: center;
    z-index: 9999;
    padding: 20px;
    animation: dw-fade 140ms ease;
}
@keyframes dw-fade { from { opacity: 0; } to { opacity: 1; } }

.dw-modal {
    background: var(--pui-bg-card, #fff);
    border-radius: 14px;
    width: 100%;
    max-width: 520px;
    max-height: 85vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    box-shadow: 0 20px 60px rgba(0,0,0,0.25);
}
.dw-modal-narrow { max-width: 320px; }
.dw-modal-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 16px;
    border-bottom: 1px solid var(--pui-border-light, rgba(0,0,0,0.06));
}
.dw-modal-head h3 { margin: 0; font-size: 1rem; font-weight: 700; color: var(--pui-text-primary, #232323); }
.dw-modal-close {
    width: 30px; height: 30px;
    border-radius: 8px;
    border: 0; background: var(--pui-bg-surface, #f3efe9);
    color: var(--pui-text-secondary, #6b6b6b);
    cursor: pointer;
    font-size: 0.85rem;
    display: grid; place-items: center;
}
.dw-modal-close:hover { background: var(--pui-accent-soft, rgba(184,133,83,0.18)); color: var(--pui-accent, #b88553); }
.dw-modal-body { padding: 16px; overflow-y: auto; display: flex; flex-direction: column; gap: 12px; }
.dw-modal-foot {
    padding: 12px 16px;
    border-top: 1px solid var(--pui-border-light, rgba(0,0,0,0.06));
    display: flex;
    justify-content: flex-end;
    gap: 8px;
}

.dw-field { display: flex; flex-direction: column; gap: 5px; }
.dw-field span { font-size: 0.78rem; font-weight: 600; color: var(--pui-text-secondary, #6b6b6b); }
.dw-field input {
    padding: 9px 12px;
    border: 1px solid var(--pui-border-light, rgba(0,0,0,0.06));
    border-radius: 9px;
    background: var(--pui-bg-surface, #f3efe9);
    color: var(--pui-text-primary, #232323);
    font: inherit;
    font-size: 0.86rem;
    transition: border-color 120ms ease;
}
.dw-field input:focus { border-color: var(--pui-accent, #b88553); outline: none; }

/* ── add palette ─────────────────────────────────────────────────────── */
.dw-palette { list-style: none; padding: 8px; margin: 0; display: flex; flex-direction: column; gap: 4px; overflow-y: auto; max-height: 60vh; }
.dw-palette-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border-radius: 10px;
    transition: background 120ms ease;
}
.dw-palette-item:hover:not(.is-disabled) { background: var(--pui-bg-surface, #f3efe9); }
.dw-palette-item.is-disabled { opacity: .55; }
.dw-palette-icon {
    width: 36px; height: 36px;
    border-radius: 9px;
    background: var(--pui-accent-soft, rgba(184,133,83,0.18));
    color: var(--pui-accent, #b88553);
    display: grid; place-items: center;
    flex-shrink: 0;
}
.dw-palette-text { flex: 1; display: flex; flex-direction: column; gap: 1px; min-width: 0; }
.dw-palette-text strong { font-size: 0.88rem; color: var(--pui-text-primary, #232323); }
.dw-palette-text span { font-size: 0.76rem; color: var(--pui-text-secondary, #6b6b6b); }

/* ── tint picker ─────────────────────────────────────────────────────── */
.dw-tint-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 10px;
}
.dw-tint-swatch {
    aspect-ratio: 1 / 1;
    border-radius: 12px;
    border: 2px solid var(--pui-border-light, rgba(0,0,0,0.06));
    cursor: pointer;
    transition: transform 120ms ease, border-color 120ms ease;
    background-color: transparent;
}
.dw-tint-swatch:hover { transform: scale(1.05); }
.dw-tint-swatch.is-active {
    border-color: var(--pui-accent, #b88553);
    box-shadow: 0 0 0 3px var(--pui-accent-soft, rgba(184,133,83,0.18));
}

/* ── responsive ──────────────────────────────────────────────────────── */
@media (max-width: 1100px) {
    .dw-grid { grid-template-columns: repeat(3, 1fr); }
    .dw-widget[data-size="large"] { grid-column: span 3; }
}
@media (max-width: 800px) {
    .dw-grid { grid-template-columns: repeat(2, 1fr); }
    .dw-widget[data-size="large"]  { grid-column: span 2; }
    .dw-widget[data-size="medium"] { grid-column: span 2; }
    .dw-widget[data-size="small"]  { grid-column: span 1; }
    .dw-flight-grid { grid-template-columns: repeat(2, 1fr); }
}
@media (max-width: 500px) {
    .dw-grid { grid-template-columns: 1fr; }
    .dw-widget[data-size="small"],
    .dw-widget[data-size="medium"],
    .dw-widget[data-size="large"] { grid-column: span 1; }
    .dw-bar { flex-direction: column; align-items: flex-start; }
    .dw-bar-actions { width: 100%; }
}

@media (prefers-reduced-motion: reduce) {
    .dw-widget, .dw-modal-backdrop, .dw-skel, .dw-wl-dot.live, .dw-goal-fill {
        animation: none !important;
        transition: none !important;
    }
}
`;

// ─────────────────────────────────────────────────────────────────────────────
// 5. ACCENT_HEX_PATCH — drop into your Settings tab markup to add a custom
// hex-color accent that lives alongside your existing _ACCENT_PRESETS swatches.
// Wire `setAccent('custom')` after storing the chosen hex into _ACCENT_PRESETS.
// ─────────────────────────────────────────────────────────────────────────────
//
//   <label class="pui-field">
//     <span>Custom accent</span>
//     <input type="color" id="pui-accent-custom" value="#b88553">
//   </label>
//
//   document.getElementById('pui-accent-custom').addEventListener('input', e => {
//     const hex = e.target.value;
//     // alpha helpers
//     const hexA = (h, a) => {
//       const n = parseInt(h.slice(1), 16);
//       const r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
//       return `rgba(${r},${g},${b},${a})`;
//     };
//     const darken = (h, p = 0.85) => {
//       const n = parseInt(h.slice(1), 16);
//       const r = Math.round(((n >> 16) & 255) * p);
//       const g = Math.round(((n >> 8)  & 255) * p);
//       const b = Math.round((n & 255) * p);
//       return '#' + ((r << 16) | (g << 8) | b).toString(16).padStart(6, '0');
//     };
//     ProfileUI._ACCENT_PRESETS.custom = {
//       label: 'Custom',
//       light: { c: hex, h: darken(hex, 0.85), s: hexA(hex, 0.10), g: hexA(hex, 0.18) },
//       dark:  { c: hex, h: darken(hex, 1.10), s: hexA(hex, 0.14), g: hexA(hex, 0.22) },
//     };
//     ProfileUI.setAccent('custom', true);
//   });