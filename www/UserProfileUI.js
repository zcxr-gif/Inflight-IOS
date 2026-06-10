/**
 * UserProfileUI.js
 *
 * Full-page pilot profile for any searched user — live OR offline.
 * Opened from the global search (Pilots section, or the pilot link inside an
 * expanded flight result) via UserProfileUI.open({ username, userId }).
 *
 * Resolution order:
 *   1. If the user is currently flying, their live flight feature provides
 *      userId + the "current flight" card.
 *   2. Otherwise the backend resolves the exact community username
 *      (POST /users), which is what makes offline lookups work.
 *
 * Data shown: grade, XP, flight time, landings, violations, ATC rank,
 * current flight (with Show on map), and the recent-flights logbook with
 * pagination. Mobile-first iOS sheet; presents as a centered dialog >768px.
 */

const ATC_RANK_MAP = {
    0: 'Observer', 1: 'Trainee', 2: 'Apprentice', 3: 'Specialist',
    4: 'Officer', 5: 'Supervisor', 6: 'Recruiter', 7: 'Manager',
};

export const UserProfileUI = {
    _backendUrl: (typeof window !== 'undefined' && window.APP_CONFIG?.backendUrl) || 'https://site--acars-backend--6dmjph8ltlhv.code.run',
    _stylesInjected: false,
    _shellBuilt: false,
    _isOpen: false,
    _loadToken: 0,

    // Metadata (aircraft/livery id → name) is global, fetch it once per session.
    _metaPromise: null,
    _aircraftMap: new Map(),
    _liveryMap: new Map(),

    _data: null,

    /* ─────────────────────────── Public API ─────────────────────────── */

    open({ username, userId = null } = {}) {
        if (!username) return;
        this._injectStyles();
        this._buildShell();

        this._data = {
            username: String(username).trim(),
            userId,
            loading: true,
            error: null,
            stats: null,
            logbook: [],
            logbookTotal: 0,
            logbookPage: 1,
            logbookTotalPages: 1,
            loadingMore: false,
            liveFeature: null,
        };

        const root = document.getElementById('user-profile-sheet');
        root.setAttribute('data-theme', localStorage.getItem('pui-theme') || 'dark');
        root.classList.add('is-open');
        document.documentElement.classList.add('ups-lock-scroll');
        this._isOpen = true;
        try { window.InflightHaptics?.select?.(); } catch (_) {}

        this._render();
        this._load();
    },

    close() {
        const root = document.getElementById('user-profile-sheet');
        root?.classList.remove('is-open');
        document.documentElement.classList.remove('ups-lock-scroll');
        this._isOpen = false;
        this._loadToken++; // invalidate any in-flight fetches
    },

    /* ─────────────────────────── Data layer ─────────────────────────── */

    _findLiveFlight(username) {
        if (typeof window.getLiveFlightData !== 'function') return null;
        const lower = username.toLowerCase();
        return window.getLiveFlightData().find(
            f => f?.properties?.username?.toLowerCase() === lower
        ) || null;
    },

    _fetchMetadata() {
        if (!this._metaPromise) {
            this._metaPromise = fetch(`${this._backendUrl}/api/metadata`)
                .then(r => r.json())
                .then(json => {
                    if (json?.ok) {
                        this._aircraftMap = new Map((json.aircraft || []).map(a => [String(a.id).toLowerCase(), a.name]));
                        this._liveryMap = new Map((json.liveries || []).map(l => [
                            String(l.id).toLowerCase(),
                            { liveryName: l.name, aircraftName: l.aircraftName },
                        ]));
                    }
                })
                .catch(() => { this._metaPromise = null; });
        }
        return this._metaPromise;
    },

    async _load() {
        const d = this._data;
        const token = ++this._loadToken;
        const stale = () => token !== this._loadToken || !this._isOpen;

        try {
            // 1. Live flight (also the cheapest way to get a userId).
            d.liveFeature = this._findLiveFlight(d.username);
            if (!d.userId && d.liveFeature) d.userId = d.liveFeature.properties.userId || null;

            // 2. Offline resolution through the backend (exact community name).
            if (!d.userId) {
                const res = await fetch(`${this._backendUrl}/users`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ discourseNames: [d.username], userHashes: [d.username] }),
                });
                const json = await res.json();
                if (stale()) return;
                const u = json?.users?.[0];
                d.userId = u?.userId || null;
                // Prefer the canonical community spelling once resolved.
                if (u?.discourseUsername) d.username = u.discourseUsername;
            }

            if (!d.userId) {
                d.loading = false;
                d.error = 'not-found';
                this._render();
                return;
            }

            // 3. Stats + logbook + metadata in parallel.
            const [statsJson, flightsJson] = await Promise.all([
                fetch(`${this._backendUrl}/api/users/${d.userId}/stats`).then(r => r.json()).catch(() => null),
                fetch(`${this._backendUrl}/api/users/${d.userId}/flights?page=1`).then(r => r.json()).catch(() => null),
                this._fetchMetadata(),
            ]);
            if (stale()) return;

            d.stats = (statsJson?.ok && (statsJson.stats || statsJson.gradeInfo)) || null;
            if (flightsJson?.ok) {
                d.logbook = flightsJson.flights || [];
                d.logbookTotal = flightsJson.totalCount || d.logbook.length;
                d.logbookTotalPages = flightsJson.totalPages || 1;
            }
            d.loading = false;
            d.error = d.stats ? null : (d.error || 'no-stats');
        } catch (err) {
            if (stale()) return;
            console.error('[UserProfileUI] load failed:', err);
            d.loading = false;
            d.error = 'network';
        }
        this._render();
    },

    async loadMoreFlights() {
        const d = this._data;
        if (!d || d.loadingMore || d.logbookPage >= d.logbookTotalPages) return;
        d.loadingMore = true;
        const token = this._loadToken;
        this._render();
        try {
            const page = d.logbookPage + 1;
            const json = await fetch(`${this._backendUrl}/api/users/${d.userId}/flights?page=${page}`).then(r => r.json());
            if (token !== this._loadToken) return;
            if (json?.ok && Array.isArray(json.flights)) {
                d.logbook = [...d.logbook, ...json.flights];
                d.logbookPage = page;
                d.logbookTotalPages = json.totalPages || d.logbookTotalPages;
            }
        } catch (_) {
        } finally {
            if (token === this._loadToken) {
                d.loadingMore = false;
                this._render();
            }
        }
    },

    /* ─────────────────────────── Actions ─────────────────────────── */

    showOnMap() {
        const f = this._data?.liveFeature;
        if (!f) return;
        const fid = f.properties?.flightId;
        const lat = f.geometry?.coordinates?.[1];
        const lon = f.geometry?.coordinates?.[0];
        this.close();
        try { window.InflightHaptics?.select?.(); } catch (_) {}
        if (fid != null && typeof window.onSearchResultClick === 'function') {
            window.onSearchResultClick(fid, lat, lon);
        }
    },

    /* ─────────────────────────── Helpers ─────────────────────────── */

    _esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    },

    _initials(name) {
        const parts = String(name || '?').trim().split(/[\s_\-.]+/).filter(Boolean);
        if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
        return String(name || '?').slice(0, 2).toUpperCase();
    },

    _formatMinutes(min) {
        const m = Math.max(0, Math.round(min || 0));
        return `${Math.floor(m / 60)}h ${m % 60}m`;
    },

    _formatDate(iso) {
        if (!iso) return '—';
        const dt = new Date(iso.endsWith('Z') ? iso : iso + 'Z');
        if (isNaN(dt)) return '—';
        return dt.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
    },

    _resolveAircraft(flight) {
        const lId = String(flight.liveryId || flight.liveryID || '').toLowerCase();
        const aId = String(flight.aircraftId || flight.aircraftID || '').toLowerCase();
        const liv = this._liveryMap.get(lId);
        if (liv) {
            return { aircraft: liv.aircraftName || this._aircraftMap.get(aId) || '', livery: liv.liveryName || '' };
        }
        return { aircraft: this._aircraftMap.get(aId) || '', livery: '' };
    },

    _parseAircraftProps(p) {
        let ac = p.aircraft;
        if (typeof ac === 'string') { try { ac = JSON.parse(ac); } catch { ac = {}; } }
        return ac || {};
    },

    _safePosition(p) {
        let pos = p.position;
        if (typeof pos === 'string') { try { pos = JSON.parse(pos); } catch { pos = {}; } }
        return pos || {};
    },

    _liveStatus(pos, altitude) {
        const gs = Math.round(pos.gs_kt || pos.speed || 0);
        const vs = Math.round(pos.vs_fpm || 0);
        const alt = Math.round(altitude || pos.alt_ft || 0);
        const altLabel = alt >= 18000 ? `FL${Math.round(alt / 100)}` : `${alt.toLocaleString()} ft`;
        if (gs < 40) return { label: 'On the ground', cls: 'is-ground' };
        if (vs > 300) return { label: `Climbing through ${altLabel}`, cls: 'is-climb' };
        if (vs < -300) return { label: `Descending through ${altLabel}`, cls: 'is-descent' };
        return { label: `Cruising at ${altLabel}`, cls: 'is-cruise' };
    },

    /* ─────────────────────────── Rendering ─────────────────────────── */

    _render() {
        const body = document.getElementById('ups-body');
        const head = document.getElementById('ups-head-identity');
        if (!body || !head || !this._data) return;
        const d = this._data;

        // ── Header (always available: name + avatar + live state) ──
        const isLive = !!d.liveFeature;
        head.innerHTML = `
            <span class="ups-avatar">${this._esc(this._initials(d.username))}</span>
            <span class="ups-head-text">
                <span class="ups-head-name">${this._esc(d.username)}</span>
                <span class="ups-status-pill ${isLive ? 'is-live' : 'is-offline'}">
                    <span class="ups-status-dot"></span>${isLive ? 'LIVE — FLYING NOW' : 'OFFLINE'}
                </span>
            </span>
        `;

        if (d.loading) {
            body.innerHTML = `
                <div class="ups-skeleton-stack">
                    <div class="ups-skeleton" style="height: 120px;"></div>
                    <div class="ups-skeleton" style="height: 86px;"></div>
                    <div class="ups-skeleton" style="height: 180px;"></div>
                </div>
            `;
            return;
        }

        if (d.error === 'not-found') {
            body.innerHTML = `
                <div class="ups-empty">
                    <i class="fa-solid fa-user-slash"></i>
                    <h3>Pilot not found</h3>
                    <p>No Infinite Flight account matches &ldquo;${this._esc(d.username)}&rdquo;.
                       Offline lookups need the pilot's <strong>exact</strong> community username.</p>
                </div>
            `;
            return;
        }
        if (d.error === 'network') {
            body.innerHTML = `
                <div class="ups-empty">
                    <i class="fa-solid fa-satellite-dish"></i>
                    <h3>Connection problem</h3>
                    <p>Could not reach the stats service. Check your connection and try again.</p>
                </div>
            `;
            return;
        }

        body.innerHTML = [
            this._renderLiveCard(),
            this._renderStatsSection(),
            this._renderLogbookSection(),
            `<a class="ups-community-link" href="https://community.infiniteflight.com/u/${encodeURIComponent(d.username)}/summary" target="_blank" rel="noopener">
                <i class="fa-solid fa-globe"></i>
                <span>View community profile</span>
                <i class="fa-solid fa-arrow-up-right-from-square ups-community-ext"></i>
            </a>`,
        ].join('');
    },

    _renderLiveCard() {
        const f = this._data?.liveFeature;
        if (!f) return '';
        const p = f.properties || {};
        const ac = this._parseAircraftProps(p);
        const pos = this._safePosition(p);
        const alt = Math.round(p.altitude || pos.alt_ft || 0);
        const gs = Math.round(pos.gs_kt || pos.speed || 0);
        const dep = (p.departureIcao || '—').toUpperCase();
        const arr = (p.arrivalIcao || '—').toUpperCase();
        const status = this._liveStatus(pos, alt);
        const acName = ac.aircraftName || p.aircraftName || '';
        const livName = ac.liveryName || p.liveryName || '';

        return `
            <div class="ups-section">
                <div class="ups-section-title">Current flight</div>
                <div class="ups-live-card">
                    <div class="ups-live-top">
                        <span class="ups-live-callsign">${this._esc(p.callsign || 'N/A')}</span>
                        ${acName ? `<span class="ups-chip">${this._esc(acName)}</span>` : ''}
                        <span class="ups-live-badge"><i class="fa-solid fa-plane"></i> LIVE</span>
                    </div>
                    ${livName ? `<div class="ups-live-livery">${this._esc(livName)}</div>` : ''}
                    <div class="ups-live-route">
                        <span class="ups-live-icao">${this._esc(dep)}</span>
                        <span class="ups-live-track"><span></span><i class="fa-solid fa-plane"></i><span></span></span>
                        <span class="ups-live-icao">${this._esc(arr)}</span>
                    </div>
                    <div class="ups-live-stats">
                        <span class="ups-live-stat"><em>${alt.toLocaleString()}</em> ft</span>
                        <span class="ups-live-stat"><em>${gs}</em> kt</span>
                        <span class="ups-live-status ${status.cls}">${status.label}</span>
                    </div>
                    <button type="button" class="ups-live-mapbtn" onclick="UserProfileUI.showOnMap()">
                        <i class="fa-solid fa-location-arrow"></i> Show on map
                    </button>
                </div>
            </div>
        `;
    },

    _renderStatsSection() {
        const stats = this._data?.stats;
        if (!stats) {
            return `
                <div class="ups-section">
                    <div class="ups-section-title">Career stats</div>
                    <div class="ups-empty is-inline"><p>Stats are unavailable for this pilot right now.</p></div>
                </div>
            `;
        }

        const gradeIdx = stats.gradeDetails?.gradeIndex;
        const gradeName = stats.gradeDetails?.grades?.[gradeIdx]?.name?.replace('Grade ', '');
        const grade = gradeName ?? (typeof stats.grade === 'number' ? stats.grade : '—');
        const xp = stats.totalXP ?? stats.xp ?? 0;
        const flightTimeMin = stats.flightTime || 0;
        const hours = (flightTimeMin / 60).toLocaleString(undefined, { maximumFractionDigits: 1 });
        const landings = stats.landingCount ?? '—';
        const violations = stats.violations ??
            ((stats.violationCountByLevel?.level1 || 0) + (stats.violationCountByLevel?.level2 || 0) + (stats.violationCountByLevel?.level3 || 0));
        const atcRank = ATC_RANK_MAP[stats.atcRank] || '—';
        const atcOps = stats.atcOperations ?? '—';
        const totalFlights = this._data.logbookTotal || stats.onlineFlights || '—';

        const cell = (label, value, accent = '') => `
            <div class="ups-stat-cell">
                <span class="ups-stat-value ${accent}">${value}</span>
                <span class="ups-stat-label">${label}</span>
            </div>
        `;

        return `
            <div class="ups-section">
                <div class="ups-section-title">Career stats</div>
                <div class="ups-hero-strip">
                    <div class="ups-grade-badge">
                        <span class="ups-grade-label">GRADE</span>
                        <span class="ups-grade-value">${this._esc(String(grade))}</span>
                    </div>
                    <div class="ups-hero-kpis">
                        ${cell('Total XP', Number(xp).toLocaleString())}
                        ${cell('Flight time', `${hours}<small> hrs</small>`)}
                        ${cell('Flights', typeof totalFlights === 'number' ? totalFlights.toLocaleString() : totalFlights)}
                    </div>
                </div>
                <div class="ups-stat-grid">
                    ${cell('Landings', typeof landings === 'number' ? landings.toLocaleString() : landings)}
                    ${cell('Violations', Number(violations || 0).toLocaleString(), Number(violations) > 0 ? 'is-warn' : 'is-good')}
                    ${cell('ATC rank', this._esc(atcRank))}
                    ${cell('ATC operations', typeof atcOps === 'number' ? atcOps.toLocaleString() : atcOps)}
                </div>
            </div>
        `;
    },

    _renderLogbookSection() {
        const d = this._data;
        const flights = d?.logbook || [];
        if (!flights.length) {
            return `
                <div class="ups-section">
                    <div class="ups-section-title">Recent flights</div>
                    <div class="ups-empty is-inline"><p>No logged flights found.</p></div>
                </div>
            `;
        }

        const rows = flights.map(fl => {
            const { aircraft, livery } = this._resolveAircraft(fl);
            const dep = (fl.originAirport || '—').toUpperCase();
            const arr = (fl.destinationAirport || '—').toUpperCase();
            const sub = [aircraft, livery].filter(Boolean).join(' · ') || (fl.server || '');
            return `
                <div class="ups-log-row">
                    <div class="ups-log-route">
                        <span class="ups-log-icaos">${this._esc(dep)} <i class="fa-solid fa-arrow-right-long"></i> ${this._esc(arr)}</span>
                        <span class="ups-log-sub">${this._esc(fl.callsign || '')}${sub ? ' · ' + this._esc(sub) : ''}</span>
                    </div>
                    <div class="ups-log-meta">
                        <span class="ups-log-time">${this._formatMinutes(fl.totalTime)}</span>
                        <span class="ups-log-date">${this._formatDate(fl.created)}</span>
                    </div>
                </div>
            `;
        }).join('');

        const hasMore = d.logbookPage < d.logbookTotalPages;
        return `
            <div class="ups-section">
                <div class="ups-section-title">Recent flights
                    <span class="ups-section-count">${(d.logbookTotal || flights.length).toLocaleString()}</span>
                </div>
                <div class="ups-log-list">${rows}</div>
                ${hasMore ? `
                    <button type="button" class="ups-loadmore" onclick="UserProfileUI.loadMoreFlights()" ${d.loadingMore ? 'disabled' : ''}>
                        ${d.loadingMore ? 'Loading…' : 'Load more flights'}
                    </button>` : ''}
            </div>
        `;
    },

    /* ─────────────────────────── Shell + styles ─────────────────────────── */

    _buildShell() {
        if (this._shellBuilt) return;
        this._shellBuilt = true;

        const root = document.createElement('div');
        root.id = 'user-profile-sheet';
        root.className = 'ups-root';
        root.innerHTML = `
            <div class="ups-backdrop"></div>
            <div class="ups-card">
                <div class="ups-grip" id="ups-grip"></div>
                <div class="ups-head" id="ups-head">
                    <div class="ups-head-identity" id="ups-head-identity"></div>
                    <button type="button" class="ups-close" id="ups-close" aria-label="Close">
                        <i class="fa-solid fa-xmark"></i>
                    </button>
                </div>
                <div class="ups-body" id="ups-body"></div>
            </div>
        `;
        document.body.appendChild(root);

        root.querySelector('.ups-backdrop').addEventListener('click', () => this.close());
        root.querySelector('#ups-close').addEventListener('click', () => this.close());

        // Theme follow (same event the rest of the chrome listens to).
        window.addEventListener('puiThemeChanged', (e) => {
            root.setAttribute('data-theme', e.detail?.theme || 'dark');
        });

        this._wireSwipeDismiss(root);
    },

    // Drag-to-dismiss from the grip/header, mirroring the app's other sheets.
    _wireSwipeDismiss(root) {
        const card = root.querySelector('.ups-card');
        const zones = [root.querySelector('#ups-grip'), root.querySelector('#ups-head')];
        let startY = 0, dy = 0, dragging = false;

        const onMove = (e) => {
            if (!dragging) return;
            dy = Math.max(0, e.touches[0].clientY - startY);
            card.style.transition = 'none';
            card.style.transform = `translateY(${dy}px)`;
        };
        const onEnd = () => {
            if (!dragging) return;
            dragging = false;
            card.style.transition = '';
            card.style.transform = '';
            if (dy > 110) this.close();
            dy = 0;
        };

        zones.forEach(zone => {
            zone?.addEventListener('touchstart', (e) => {
                if (e.target.closest('.ups-close')) return;
                dragging = true;
                startY = e.touches[0].clientY;
                dy = 0;
            }, { passive: true });
        });
        window.addEventListener('touchmove', onMove, { passive: true });
        window.addEventListener('touchend', onEnd, { passive: true });
    },

    _injectStyles() {
        if (this._stylesInjected) return;
        this._stylesInjected = true;

        const style = document.createElement('style');
        style.id = 'user-profile-ui-styles';
        style.textContent = `
            .ups-lock-scroll, .ups-lock-scroll body { overflow: hidden; }

            .ups-root {
                position: fixed;
                inset: 0;
                z-index: 6000;
                opacity: 0;
                visibility: hidden;
                transition: opacity 0.25s ease, visibility 0.25s;
                font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Inter', sans-serif;
                -webkit-font-smoothing: antialiased;
                --ups-bg: rgba(28, 28, 32, 0.97);
                --ups-stroke: rgba(255, 255, 255, 0.14);
                --ups-stroke-soft: rgba(255, 255, 255, 0.08);
                --ups-fill: rgba(255, 255, 255, 0.08);
                --ups-fill-strong: rgba(255, 255, 255, 0.14);
                --ups-text: #ffffff;
                --ups-text-2: rgba(255, 255, 255, 0.90);
                --ups-text-3: rgba(235, 235, 245, 0.60);
                --ups-text-4: rgba(235, 235, 245, 0.30);
                --ups-accent: #0a84ff;
                --ups-success: #30d158;
                --ups-warning: #ffd60a;
                --ups-danger: #ff453a;
            }
            .ups-root[data-theme="light"] {
                --ups-bg: rgba(250, 250, 252, 0.98);
                --ups-stroke: rgba(0, 0, 0, 0.10);
                --ups-stroke-soft: rgba(0, 0, 0, 0.06);
                --ups-fill: rgba(0, 0, 0, 0.05);
                --ups-fill-strong: rgba(0, 0, 0, 0.10);
                --ups-text: #000;
                --ups-text-2: rgba(0, 0, 0, 0.88);
                --ups-text-3: rgba(60, 60, 67, 0.6);
                --ups-text-4: rgba(60, 60, 67, 0.3);
                --ups-accent: #007aff;
                --ups-success: #34c759;
            }
            .ups-root.is-open { opacity: 1; visibility: visible; }

            .ups-backdrop {
                position: absolute;
                inset: 0;
                background: rgba(0, 0, 0, 0.4);
                -webkit-backdrop-filter: blur(3px);
                backdrop-filter: blur(3px);
            }

            .ups-card {
                position: absolute;
                left: 0; right: 0; bottom: 0;
                height: min(90dvh, 860px);
                display: flex;
                flex-direction: column;
                border-radius: 22px 22px 0 0;
                background: var(--ups-bg);
                -webkit-backdrop-filter: saturate(180%) blur(30px);
                backdrop-filter: saturate(180%) blur(30px);
                box-shadow: 0 -10px 44px rgba(0, 0, 0, 0.5);
                transform: translateY(101%);
                transition: transform 0.42s cubic-bezier(0.16, 1, 0.3, 1);
                overflow: hidden;
                color: var(--ups-text);
            }
            .ups-root.is-open .ups-card { transform: translateY(0); }

            /* Desktop: centered dialog instead of a bottom sheet. */
            @media (min-width: 769px) {
                .ups-card {
                    left: 50%; right: auto; bottom: auto; top: 50%;
                    width: 520px;
                    height: min(82vh, 780px);
                    border-radius: 22px;
                    transform: translate(-50%, calc(-50% + 24px));
                    opacity: 0;
                    transition: transform 0.34s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.25s ease;
                }
                .ups-root.is-open .ups-card { transform: translate(-50%, -50%); opacity: 1; }
                .ups-grip { display: none; }
            }

            .ups-grip {
                flex: 0 0 auto;
                width: 38px; height: 5px;
                border-radius: 10px;
                background: var(--ups-fill-strong);
                margin: 9px auto 2px;
                touch-action: none;
            }

            .ups-head {
                flex: 0 0 auto;
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 12px;
                padding: 10px 18px 14px;
                border-bottom: 0.5px solid var(--ups-stroke-soft);
            }
            .ups-head-identity {
                display: flex;
                align-items: center;
                gap: 12px;
                min-width: 0;
            }
            .ups-avatar {
                flex: 0 0 auto;
                display: grid;
                place-items: center;
                width: 46px; height: 46px;
                border-radius: 50%;
                background: linear-gradient(135deg, #3b82f6, #8b5cf6);
                color: #fff;
                font-size: 16px;
                font-weight: 800;
                letter-spacing: 0.03em;
            }
            .ups-head-text { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
            .ups-head-name {
                font-size: 21px;
                font-weight: 800;
                letter-spacing: -0.4px;
                line-height: 1.05;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .ups-status-pill {
                display: inline-flex;
                align-items: center;
                gap: 5px;
                align-self: flex-start;
                font-size: 9.5px;
                font-weight: 800;
                letter-spacing: 0.07em;
                padding: 2.5px 8px;
                border-radius: 999px;
            }
            .ups-status-dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
            .ups-status-pill.is-live { color: #052e14; background: linear-gradient(135deg, #4ade80, #22c55e); }
            .ups-status-pill.is-live .ups-status-dot { background: #052e14; }
            .ups-status-pill.is-offline { color: var(--ups-text-3); background: var(--ups-fill); }
            .ups-close {
                flex: 0 0 auto;
                width: 30px; height: 30px;
                border-radius: 50%;
                border: none;
                display: grid;
                place-items: center;
                background: var(--ups-fill);
                color: var(--ups-text-2);
                font-size: 15px;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
                transition: transform 0.15s ease, background-color 0.15s ease;
            }
            .ups-close:active { transform: scale(0.9); background: var(--ups-fill-strong); }

            .ups-body {
                flex: 1 1 auto;
                min-height: 0;
                overflow-y: auto;
                -webkit-overflow-scrolling: touch;
                overscroll-behavior: contain;
                padding: 14px 16px max(env(safe-area-inset-bottom, 0px), 22px);
            }
            .ups-body::-webkit-scrollbar { width: 0; background: transparent; }

            /* ── Sections ── */
            .ups-section { margin-bottom: 18px; }
            .ups-section-title {
                display: flex;
                align-items: center;
                justify-content: space-between;
                font-size: 11px;
                font-weight: 700;
                letter-spacing: 0.6px;
                text-transform: uppercase;
                color: var(--ups-text-3);
                padding: 0 4px 8px;
            }
            .ups-section-count { font-weight: 500; color: var(--ups-text-4); }

            /* ── Live flight card ── */
            .ups-live-card {
                position: relative;
                border: 0.5px solid var(--ups-stroke);
                border-radius: 16px;
                padding: 14px 14px 12px;
                background:
                    radial-gradient(120% 140% at 0% 0%, rgba(48, 209, 88, 0.16), transparent 55%),
                    var(--ups-fill);
                overflow: hidden;
            }
            .ups-live-top { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
            .ups-live-callsign { font-size: 19px; font-weight: 800; letter-spacing: -0.2px; }
            .ups-chip {
                font-size: 10px;
                font-weight: 700;
                padding: 2.5px 8px;
                border-radius: 6px;
                background: var(--ups-fill-strong);
                color: var(--ups-text-2);
            }
            .ups-live-badge {
                margin-left: auto;
                display: inline-flex;
                align-items: center;
                gap: 4px;
                font-size: 9px;
                font-weight: 800;
                letter-spacing: 0.06em;
                color: #052e14;
                background: linear-gradient(135deg, #4ade80, #22c55e);
                padding: 2.5px 8px;
                border-radius: 999px;
            }
            .ups-live-livery { font-size: 12px; color: var(--ups-text-3); margin-top: 3px; }
            .ups-live-route {
                display: flex;
                align-items: center;
                gap: 12px;
                margin: 12px 0 10px;
            }
            .ups-live-icao { font-size: 22px; font-weight: 800; letter-spacing: 0.02em; }
            .ups-live-track {
                flex: 1 1 auto;
                display: flex;
                align-items: center;
                gap: 6px;
                color: var(--ups-text-4);
            }
            .ups-live-track > span {
                flex: 1 1 auto;
                height: 1px;
                background: linear-gradient(90deg, transparent, var(--ups-stroke), transparent);
            }
            .ups-live-track > i { font-size: 12px; color: var(--ups-success); }
            .ups-live-stats {
                display: flex;
                align-items: center;
                gap: 14px;
                flex-wrap: wrap;
                margin-bottom: 12px;
            }
            .ups-live-stat { font-size: 11.5px; color: var(--ups-text-3); }
            .ups-live-stat em { font-style: normal; font-size: 14px; font-weight: 700; color: var(--ups-text); }
            .ups-live-status { font-size: 11.5px; font-weight: 700; color: var(--ups-success); }
            .ups-live-status.is-climb { color: #64d2ff; }
            .ups-live-status.is-descent { color: var(--ups-warning); }
            .ups-live-status.is-ground { color: var(--ups-text-3); }
            .ups-live-mapbtn {
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
                width: 100%;
                padding: 11px;
                border: none;
                border-radius: 12px;
                background: var(--ups-accent);
                color: #fff;
                font-family: inherit;
                font-size: 14px;
                font-weight: 700;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
                transition: transform 0.12s ease, filter 0.15s ease;
            }
            .ups-live-mapbtn:active { transform: scale(0.98); filter: brightness(1.12); }

            /* ── Stats ── */
            .ups-hero-strip {
                display: flex;
                align-items: stretch;
                gap: 10px;
                margin-bottom: 10px;
            }
            .ups-grade-badge {
                flex: 0 0 auto;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                gap: 2px;
                width: 86px;
                border-radius: 16px;
                background: linear-gradient(160deg, rgba(10, 132, 255, 0.22), rgba(10, 132, 255, 0.06));
                border: 0.5px solid rgba(10, 132, 255, 0.35);
            }
            .ups-grade-label { font-size: 9px; font-weight: 800; letter-spacing: 0.12em; color: var(--ups-text-3); }
            .ups-grade-value { font-size: 30px; font-weight: 800; line-height: 1; color: var(--ups-accent); }
            .ups-hero-kpis {
                flex: 1 1 auto;
                display: grid;
                grid-template-columns: repeat(3, minmax(0, 1fr));
                gap: 6px;
            }
            .ups-stat-cell {
                display: flex;
                flex-direction: column;
                justify-content: center;
                gap: 3px;
                padding: 10px 10px;
                border-radius: 14px;
                background: var(--ups-fill);
                border: 0.5px solid var(--ups-stroke-soft);
                min-width: 0;
            }
            .ups-stat-value {
                font-size: 16px;
                font-weight: 800;
                letter-spacing: -0.2px;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .ups-stat-value small { font-size: 10px; font-weight: 600; color: var(--ups-text-3); }
            .ups-stat-value.is-warn { color: var(--ups-danger); }
            .ups-stat-value.is-good { color: var(--ups-success); }
            .ups-stat-label {
                font-size: 10px;
                font-weight: 600;
                letter-spacing: 0.03em;
                text-transform: uppercase;
                color: var(--ups-text-3);
            }
            .ups-stat-grid {
                display: grid;
                grid-template-columns: repeat(2, minmax(0, 1fr));
                gap: 6px;
            }

            /* ── Logbook ── */
            .ups-log-list {
                border: 0.5px solid var(--ups-stroke-soft);
                border-radius: 16px;
                overflow: hidden;
                background: var(--ups-fill);
            }
            .ups-log-row {
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 12px;
                padding: 11px 14px;
            }
            .ups-log-row + .ups-log-row { border-top: 0.5px solid var(--ups-stroke-soft); }
            .ups-log-route { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
            .ups-log-icaos { font-size: 14px; font-weight: 700; letter-spacing: 0.01em; }
            .ups-log-icaos > i { font-size: 10px; color: var(--ups-text-4); margin: 0 3px; }
            .ups-log-sub {
                font-size: 11px;
                color: var(--ups-text-3);
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .ups-log-meta {
                flex: 0 0 auto;
                display: flex;
                flex-direction: column;
                align-items: flex-end;
                gap: 2px;
            }
            .ups-log-time { font-size: 12.5px; font-weight: 700; }
            .ups-log-date { font-size: 10.5px; color: var(--ups-text-4); }
            .ups-loadmore {
                display: block;
                width: 100%;
                margin-top: 8px;
                padding: 12px;
                border: 0.5px solid var(--ups-stroke-soft);
                border-radius: 14px;
                background: var(--ups-fill);
                color: var(--ups-accent);
                font-family: inherit;
                font-size: 14px;
                font-weight: 600;
                cursor: pointer;
                -webkit-tap-highlight-color: transparent;
            }
            .ups-loadmore:disabled { opacity: 0.5; }
            .ups-loadmore:active { background: var(--ups-fill-strong); }

            /* ── Community link ── */
            .ups-community-link {
                display: flex;
                align-items: center;
                gap: 12px;
                padding: 13px 14px;
                border: 0.5px solid var(--ups-stroke-soft);
                border-radius: 14px;
                background: var(--ups-fill);
                color: var(--ups-text);
                font-size: 14px;
                font-weight: 600;
                text-decoration: none;
            }
            .ups-community-link > i:first-child { color: var(--ups-accent); }
            .ups-community-link span { flex: 1 1 auto; }
            .ups-community-ext { font-size: 11px; color: var(--ups-text-4); }

            /* ── Empty / error / skeleton ── */
            .ups-empty {
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 8px;
                text-align: center;
                padding: 44px 28px;
                color: var(--ups-text-3);
            }
            .ups-empty > i { font-size: 28px; opacity: 0.5; }
            .ups-empty h3 { margin: 4px 0 0; font-size: 17px; font-weight: 700; color: var(--ups-text); }
            .ups-empty p { margin: 0; font-size: 13px; line-height: 1.5; max-width: 300px; }
            .ups-empty.is-inline { padding: 18px; }
            .ups-skeleton-stack { display: flex; flex-direction: column; gap: 10px; }
            .ups-skeleton {
                border-radius: 16px;
                background: linear-gradient(100deg, var(--ups-fill) 40%, var(--ups-fill-strong) 50%, var(--ups-fill) 60%);
                background-size: 200% 100%;
                animation: ups-shimmer 1.4s ease infinite;
            }
            @keyframes ups-shimmer {
                from { background-position: 120% 0; }
                to { background-position: -80% 0; }
            }
        `;
        document.head.appendChild(style);
    },
};

// Expose globally for inline handlers + non-module callers.
if (typeof window !== 'undefined') {
    window.UserProfileUI = UserProfileUI;
    window.openUserProfile = (username, userId) => UserProfileUI.open({ username, userId });
}
