export const LandingUI = {
    _isVisible: false,
    _modalOpen: false,
    _weatherMenuOpen: false,
    _activeFilters: {}, 
    _currentServer: 'Expert', 
    _searchCursorIndex: -1,
    _currentMatches: [],
    _currentResults: { flights: [], users: [], airports: [], airlines: [] },
    _theme: localStorage.getItem('pui-theme') || 'dark',

    filterGroups: {
        flight: {
            label: "Flight Data",
            filters: [
                { id: 'phase', label: 'Flight Phase', icon: 'fa-plane-circle-check', type: 'select', options: ['Ground', 'Climb', 'Cruise', 'Descent'] },
                { id: 'altitude', label: 'Altitude (ft)', icon: 'fa-arrow-up-right-dots', type: 'range', min: 0, max: 60000, step: 1000 },
                { id: 'speed', label: 'Speed (GS)', icon: 'fa-gauge-high', type: 'range', min: 0, max: 1200, step: 50 },
                { id: 'vspeed', label: 'Vert. Speed', icon: 'fa-angles-up', type: 'range', min: -6000, max: 6000, step: 500 }
            ]
        },
        aircraft: {
            label: "Aircraft Info",
            filters: [
                { id: 'category', label: 'Category', icon: 'fa-shapes', type: 'select', options: ['Heavy', 'Widebody', 'Narrowbody', 'Regional', 'GA', 'Military', 'Fighter'] },
                { id: 'type', label: 'Aircraft Type', icon: 'fa-plane', type: 'autocomplete', placeholder: 'e.g. B737, A320' },
                { id: 'livery', label: 'Livery', icon: 'fa-paint-roller', type: 'autocomplete', placeholder: 'e.g. United, FedEx' },
                { id: 'country', label: 'Country Registry', icon: 'fa-globe', type: 'select', options: [] },
                { id: 'airline', label: 'Airline Code', icon: 'fa-building', type: 'text', placeholder: 'e.g. UAL, BAW' }
            ]
        },
        route: {
            label: "Route & Network",
            filters: [
                { id: 'departureIcao', label: 'Departure', icon: 'fa-plane-departure', type: 'text', placeholder: 'ICAO' },
                { id: 'arrivalIcao', label: 'Arrival', icon: 'fa-plane-arrival', type: 'text', placeholder: 'ICAO' },
                { id: 'callsign', label: 'Callsign', icon: 'fa-id-badge', type: 'text', placeholder: 'Search...' },
                { id: 'group', label: 'Group Flight', icon: 'fa-users', type: 'boolean' } 
            ]
        }
    },

    async init() {
        window.LandingUI = this;

        // Idempotent guard — flight.js calls LandingUI.init() twice (once inside
        // initializeSectorOpsView, once at the bootstrap level). Without this,
        // the entire UI markup gets injected twice, producing duplicate IDs
        // (#tile-settings, etc.) and breaking every click handler bound by id.
        if (this._initialized) {
            return;
        }
        this._initialized = true;

        // Fetch theme again just in case it loaded late
        this._theme = localStorage.getItem('pui-theme') || 'dark';

        await this.loadPrefixData();
        this.injectStyles();
        this.applyMobileOptimizations();
        this.render();
        this.attachListeners();
        this.applyMobileChrome();
    },

    applyMobileOptimizations() {
        if (window.innerWidth <= 768) {
            import('./MobileLandingUI.js').then(m => {
                m.MobileLandingUI.init(this);
            }).catch(err => console.error("Failed to load Mobile UI:", err));
        }
    },

    applyMobileChrome() {
        if (window.innerWidth <= 768) {
            // Full rehaul of the LandingUI top header + bottom tab bar with
            // native iOS chrome. Runs AFTER render() so it can re-host the
            // already-wired search input + results dropdown.
            import('./MobileLandingChromeUI.js').then(m => {
                m.MobileLandingChromeUI.init(this);
            }).catch(err => console.error("Failed to load Mobile Chrome UI:", err));
        }
    },

    async loadPrefixData() {
        try {
            const response = await fetch('prefix.json');
            const data = await response.json();
            const countryFilter = this.filterGroups.aircraft.filters.find(f => f.id === 'country');
            if (countryFilter) {
                countryFilter.options = [
                    'All Countries', 
                    ...data.map(p => `${p.country} (${p.prefix[0]})`)
                ];
            }
        } catch (e) {
            console.error("Error loading prefix.json:", e);
        }
    },

    handleLocalSearch(query) {
        const resultsContainer = document.getElementById('blade-search-results');
        const searchBlade = document.querySelector('.search-blade');

        if (!query || query.length < 2) {
            this._currentMatches = [];
            this._currentResults = { flights: [], users: [], airports: [], airlines: [] };
            this._searchCursorIndex = -1;
            if (resultsContainer) {
                resultsContainer.innerHTML = '';
                resultsContainer.classList.remove('visible');
                if (searchBlade) searchBlade.classList.remove('has-results');
            }
            return;
        }

        const results = (typeof window.runGlobalSearch === 'function')
            ? window.runGlobalSearch(query)
            : { flights: [], users: [], airports: [], airlines: [] };

        this._currentResults = results;
        // Keep flight matches around for keyboard nav (arrows + Enter).
        this._currentMatches = (results.flights || []).map(r => r.feature);
        this._searchCursorIndex = -1;

        // The Pilots section always carries the offline network-lookup row, so
        // the dropdown stays open (with that row) even when nothing live matches.
        if (searchBlade) searchBlade.classList.add('has-results');

        this.renderSearchResults(query);
    },

    highlightText(text, query) {
        if (!query || !text) return text;
        const regex = new RegExp(`(${query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi');
        return text.replace(regex, '<span class="premium-highlight">$1</span>');
    },

    // Parse the `position` blob (it can arrive as a JSON string or object) so the
    // expanded detail can show live speed/heading without re-querying the map.
    _safePosition(p) {
        const pos = (typeof p.position === 'string')
            ? (() => { try { return JSON.parse(p.position); } catch { return {}; } })()
            : (p.position || {});
        return pos || {};
    },

    // Minimal HTML escape for live-data strings (usernames, liveries) rendered
    // into the dropdown markup.
    _esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    },

    // Two-letter avatar monogram for a username.
    _initials(name) {
        const parts = String(name || '?').trim().split(/[\s_\-.]+/).filter(Boolean);
        if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
        return String(name || '?').slice(0, 2).toUpperCase();
    },

    // Coarse flight phase from live telemetry — enough for the status line.
    _flightStatus(pos, altitude) {
        const gs = Math.round(pos.gs_kt || pos.speed || 0);
        const vs = Math.round(pos.vs_fpm || 0);
        const alt = Math.round(altitude || pos.alt_ft || 0);
        const altLabel = alt >= 18000 ? `FL${Math.round(alt / 100)}` : `${alt.toLocaleString()} ft`;
        if (gs < 40) return { label: 'On the ground', icon: 'fa-plane-circle-exclamation', cls: 'is-ground' };
        if (vs > 300) return { label: `Climbing through ${altLabel}`, icon: 'fa-plane-up', cls: 'is-climb' };
        if (vs < -300) return { label: `Descending through ${altLabel}`, icon: 'fa-plane-arrival', cls: 'is-descent' };
        return { label: `Cruising at ${altLabel}`, icon: 'fa-plane', cls: 'is-cruise' };
    },

    _renderFlightRow(entry, idx, query) {
        const f = entry.feature;
        const p = f.properties || {};
        const acData = (typeof p.aircraft === 'string') ? (() => { try { return JSON.parse(p.aircraft); } catch { return {}; } })() : (p.aircraft || {});
        const acName = acData.aircraftName || p.aircraftName || '---';
        const lat = f.geometry?.coordinates?.[1];
        const lon = f.geometry?.coordinates?.[0];

        // Extra detail surfaced when the row is expanded.
        const pos = this._safePosition(p);
        const username = p.username || 'Anonymous';
        const livName = acData.liveryName || p.liveryName || '';
        const reg = acData.registration || p.registration || '';
        const dep = (p.departureIcao || '').toUpperCase();
        const arr = (p.arrivalIcao || '').toUpperCase();
        const spd = Math.round(pos.gs_kt || pos.speed || 0);
        const hdg = Math.round(pos.heading ?? pos.hdg ?? p.heading ?? 0);
        const vs = Math.round(pos.vs_fpm || 0);
        const alt = Math.round(p.altitude || pos.alt_ft || 0);
        const fid = p.flightId;
        const status = this._flightStatus(pos, alt);
        // Escaped form for inline string args (callsign/username can contain quotes).
        const usernameArg = this._esc(String(username).replace(/'/g, "\\'"));

        const detailItem = (k, v) => `<div class="res-dt"><span class="res-dt-k">${k}</span><span class="res-dt-v">${v}</span></div>`;

        return `
            <div class="premium-flight-wrap" data-flight-wrap="${fid}">
                <div class="premium-result-item premium-flight-row ${this._searchCursorIndex === idx ? 'selected' : ''}"
                     data-index="${idx}"
                     onclick="LandingUI.executeSearchClick('${fid}', ${lat}, ${lon})">
                    <div class="res-meta-icon"><i class="fa-solid fa-circle"></i></div>
                    <div class="res-info-main">
                        <div class="res-primary-row">
                            <span class="res-callsign">${this.highlightText(this._esc(p.callsign || 'N/A'), query)}</span>
                            <span class="res-pill">${this.highlightText(this._esc(acName), query)}</span>
                            ${reg ? `<span class="res-pill res-pill-reg">${this.highlightText(this._esc(reg), query)}</span>` : ''}
                        </div>
                        <div class="res-secondary-row">
                            <span class="res-pilot">${this.highlightText(this._esc(username), query)}</span>
                        </div>
                    </div>
                    <div class="res-stats">
                        <span class="res-live-pill"><i class="fa-solid fa-plane"></i> LIVE</span>
                        <span class="res-altitude">${alt.toLocaleString()}<span>ft</span></span>
                    </div>
                    <button type="button" class="res-expand-btn" aria-label="More info" aria-expanded="false"
                            onclick="LandingUI.toggleResultDetail(event)">
                        <i class="fa-solid fa-chevron-down"></i>
                    </button>
                </div>
                <div class="res-detail">
                    <div class="res-detail-inner">
                        ${reg ? `<div class="res-photo" data-photo-reg="${this._esc(reg)}" hidden>
                            <img alt="${this._esc(acName)} ${this._esc(reg)}" />
                            <span class="res-photo-credit"></span>
                        </div>` : ''}
                        <div class="res-route-banner">
                            <div class="res-route-ep">
                                <span class="res-route-code">${this._esc(dep || '—')}</span>
                                <span class="res-route-name">${this._esc(entry.depName || 'Departure')}</span>
                            </div>
                            <div class="res-route-mid">
                                <span class="res-route-line"></span>
                                <i class="fa-solid fa-plane"></i>
                                <span class="res-route-line"></span>
                            </div>
                            <div class="res-route-ep is-arr">
                                <span class="res-route-code">${this._esc(arr || '—')}</span>
                                <span class="res-route-name">${this._esc(entry.arrName || 'Arrival')}</span>
                            </div>
                        </div>
                        <div class="res-status-line ${status.cls}">
                            <i class="fa-solid ${status.icon}"></i>
                            <span>${status.label}</span>
                        </div>
                        <div class="res-detail-grid">
                            ${detailItem('Altitude', `${alt.toLocaleString()} <span class="res-dt-u">ft</span>`)}
                            ${detailItem('Ground speed', `${spd} <span class="res-dt-u">kt</span>`)}
                            ${detailItem('Heading', `${hdg}<span class="res-dt-u">°</span>`)}
                            ${detailItem('Vert. speed', `${vs.toLocaleString()} <span class="res-dt-u">fpm</span>`)}
                            ${livName ? detailItem('Airline / Livery', this._esc(livName)) : ''}
                            ${detailItem('Aircraft', this._esc(acName))}
                        </div>
                        <button type="button" class="res-pilot-link" onclick="LandingUI.openUserProfileFromFlight(event, ${idx})">
                            <span class="res-user-avatar">${this._esc(this._initials(username))}</span>
                            <span class="res-pilot-link-text">
                                <span class="res-pilot-link-name">${this._esc(username)}</span>
                                <span class="res-pilot-link-sub">View pilot profile &amp; stats</span>
                            </span>
                            <i class="fa-solid fa-chevron-right res-pilot-link-chev"></i>
                        </button>
                        <div class="res-action-bar">
                            <button type="button" class="res-action-btn is-primary"
                                    onclick="LandingUI.executeSearchClick('${fid}', ${lat}, ${lon})">
                                <i class="fa-solid fa-location-arrow"></i>
                                <span>Show on map</span>
                            </button>
                            <button type="button" class="res-action-btn"
                                    onclick="LandingUI.replayUserFlight(event, '${fid}', '${usernameArg}')">
                                <i class="fa-solid fa-clock-rotate-left"></i>
                                <span>Replay</span>
                                <span class="res-pro-badge"><i class="fa-solid fa-crown"></i> PRO</span>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        `;
    },

    _renderUserRow(entry, idx, query) {
        const p = entry.feature?.properties || {};
        const acData = (typeof p.aircraft === 'string') ? (() => { try { return JSON.parse(p.aircraft); } catch { return {}; } })() : (p.aircraft || {});
        const acName = acData.aircraftName || p.aircraftName || '';
        const callsign = p.callsign || '';
        const sub = callsign
            ? `Flying ${this._esc(callsign)}${acName ? ' · ' + this._esc(acName) : ''}`
            : 'Connected to the network';

        return `
            <div class="premium-result-item res-user-row" onclick="LandingUI.openUserProfileFromResult(event, ${idx})">
                <span class="res-user-avatar">${this._esc(this._initials(entry.username))}</span>
                <div class="res-info-main">
                    <div class="res-primary-row">
                        <span class="res-callsign">${this.highlightText(this._esc(entry.username), query)}</span>
                        <span class="res-live-pill"><i class="fa-solid fa-plane"></i> LIVE</span>
                    </div>
                    <div class="res-secondary-row">
                        <span class="res-pilot">${sub}</span>
                    </div>
                </div>
                <i class="fa-solid fa-chevron-right res-user-chev"></i>
            </div>
        `;
    },

    // Persistent footer row of the Pilots section: looks the typed name up on
    // the network (works for OFFLINE users too — resolved via the backend).
    _renderUserLookupRow(query) {
        return `
            <div class="premium-result-item res-user-lookup-row" onclick="LandingUI.lookupUserProfile(event)">
                <span class="res-user-avatar is-lookup"><i class="fa-solid fa-magnifying-glass"></i></span>
                <div class="res-info-main">
                    <div class="res-primary-row">
                        <span class="res-callsign">Search &ldquo;${this._esc(query)}&rdquo; on the network</span>
                    </div>
                    <div class="res-secondary-row">
                        <span class="res-pilot">Find offline pilots by exact community username</span>
                    </div>
                </div>
                <i class="fa-solid fa-chevron-right res-user-chev"></i>
            </div>
        `;
    },

    // Expand/collapse a flight result's detail drawer. Stops propagation so the
    // chevron tap doesn't also fire the row's fly-to handler.
    toggleResultDetail(event) {
        event.stopPropagation();
        const wrap = event.currentTarget.closest('.premium-flight-wrap');
        if (!wrap) return;
        const open = wrap.classList.toggle('detail-open');
        const btn = wrap.querySelector('.res-expand-btn');
        if (btn) btn.setAttribute('aria-expanded', open ? 'true' : 'false');
        if (open) this._hydrateResultPhoto(wrap);
    },

    // Lazily resolve a real aircraft photo for an expanded flight result; reveal
    // the slot only on a hit so misses leave no broken-image gap.
    _hydrateResultPhoto(wrap) {
        const slot = wrap.querySelector('.res-photo[data-photo-reg]');
        if (!slot || slot.dataset.photoLoaded) return;
        if (typeof window.InflightAircraftPhoto?.get !== 'function') return;
        slot.dataset.photoLoaded = '1';
        const reg = slot.getAttribute('data-photo-reg');
        window.InflightAircraftPhoto.get(reg).then(photo => {
            if (!photo) return;
            // Renders a single image, or a swipeable carousel when the airframe
            // has more than one photo on file.
            if (window.InflightAircraftPhoto.render(slot, photo)) slot.hidden = false;
        });
    },

    _isPro() {
        return (typeof window !== 'undefined' && typeof window.isInflightPro === 'function')
            ? window.isInflightPro()
            : false;
    },

    // Open the standard Pro upsell flow (mirrors the rest of the app: AuthUI
    // modal + a broadcast event other surfaces can hook).
    _requestProUpgrade(source) {
        try {
            window.dispatchEvent(new CustomEvent('pro-upgrade-requested', {
                bubbles: true, cancelable: true, detail: { source }
            }));
        } catch (_) {}
        try {
            if (window.AuthUI && typeof window.AuthUI.open === 'function') window.AuthUI.open();
        } catch (_) {}
    },

    // Replay a specific pilot's flight straight from the search result.
    // PRO-gated. The underlying per-user replay capability does not exist yet,
    // so this is the wired-up entry point: it gates on Pro and hands off to
    // `window.startUserFlightReplay` once that function is implemented.
    replayUserFlight(event, flightId, username) {
        event.stopPropagation();
        if (!this._isPro()) {
            this._requestProUpgrade('search-result-replay');
            return;
        }
        // TODO: wire up once per-user flight replay exists. Intended behaviour:
        // load and play back `username`'s flight `flightId`.
        if (typeof window.startUserFlightReplay === 'function') {
            window.startUserFlightReplay(flightId, username);
            this._closeBladeSearch();
        } else if (typeof window.showNotification === 'function') {
            window.showNotification(`Flight replay for ${username || 'this pilot'} is coming soon.`, 'info');
        }
    },

    _renderAirportRow(entry, query) {
        const a = entry.airport;
        return `
            <div class="premium-result-item"
                 onclick="LandingUI.executeAirportClick('${a.icao}', ${a.lat}, ${a.lon})">
                <div class="res-meta-icon" style="color: var(--lui-accent);"><i class="fa-solid fa-tower-control" style="font-size: 14px;"></i></div>
                <div class="res-info-main">
                    <div class="res-primary-row">
                        <span class="res-callsign">${this.highlightText(a.icao, query)}</span>
                        <span class="res-pill">${this.highlightText(a.country || '', query)}</span>
                    </div>
                    <div class="res-secondary-row">
                        <span class="res-pilot">${this.highlightText(a.name || '', query)}</span>
                    </div>
                </div>
            </div>
        `;
    },

    _renderAirlineRow(entry, query) {
        const safeName = (entry.name || '').replace(/'/g, "\\'");
        return `
            <div class="premium-result-item"
                 onclick="LandingUI.executeAirlineClick('${safeName}')">
                <div class="res-meta-icon" style="color: #c084fc;"><i class="fa-solid fa-plane-departure" style="font-size: 14px;"></i></div>
                <div class="res-info-main">
                    <div class="res-primary-row">
                        <span class="res-callsign">${this.highlightText(entry.name, query)}</span>
                    </div>
                    <div class="res-secondary-row">
                        <span class="res-pilot">${entry.count} active flight${entry.count === 1 ? '' : 's'}</span>
                    </div>
                </div>
            </div>
        `;
    },

    _renderSection(title, rows) {
        if (!rows.length) return '';
        return `
            <div class="blade-results-section">
                <div class="blade-results-header">${title}<span class="blade-results-count">${rows.length}</span></div>
                ${rows.join('')}
            </div>
        `;
    },

    renderSearchResults(query) {
        const container = document.getElementById('blade-search-results');
        if (!container) return;

        const r = this._currentResults || { flights: [], users: [], airports: [], airlines: [] };
        const total = (r.flights?.length || 0) + (r.users?.length || 0) + (r.airports?.length || 0) + (r.airlines?.length || 0);

        // Pilots section always ends with the offline network-lookup row, so
        // even a zero-hit query still offers a way forward.
        const pilotRows = [
            ...(r.users || []).map((e, i) => this._renderUserRow(e, i, query)),
            this._renderUserLookupRow(query),
        ];

        if (total === 0) {
            container.innerHTML = [
                `<div class="premium-empty-state"><p>No live matches found</p></div>`,
                this._renderSection('Pilots', pilotRows),
            ].join('');
        } else {
            container.innerHTML = [
                this._renderSection('Live flights', (r.flights || []).map((e, i) => this._renderFlightRow(e, i, query))),
                this._renderSection('Pilots', pilotRows),
                this._renderSection('Airports', (r.airports || []).map(e => this._renderAirportRow(e, query))),
                this._renderSection('Airlines', (r.airlines || []).map(e => this._renderAirlineRow(e, query))),
            ].join('');
        }
        container.classList.add('visible');
    },

    // ─── Pilot profile entry points ─────────────────────────────────────────

    // Open the full user-profile page for a username (live or offline).
    openUserProfile(username, userId = null) {
        if (!username) return;
        try { window.InflightHaptics?.select?.(); } catch (_) {}
        this._closeBladeSearch();
        import('./UserProfileUI.js')
            .then(m => m.UserProfileUI.open({ username, userId }))
            .catch(err => console.error('Failed to load UserProfileUI:', err));
    },

    // From a Pilots-section row (index into the current users results).
    openUserProfileFromResult(event, idx) {
        event.stopPropagation();
        const entry = this._currentResults?.users?.[idx];
        if (entry) this.openUserProfile(entry.username, entry.userId);
    },

    // From the pilot link inside an expanded flight result.
    openUserProfileFromFlight(event, idx) {
        event.stopPropagation();
        const p = this._currentResults?.flights?.[idx]?.feature?.properties;
        if (p?.username) this.openUserProfile(p.username, p.userId || null);
    },

    // The "Search <query> on the network" row — works for offline users; the
    // profile page resolves the name via the backend and shows a not-found
    // state if it doesn't exist.
    lookupUserProfile(event) {
        event?.stopPropagation?.();
        const q = (document.getElementById('blade-search-input')?.value || '').trim();
        if (q) this.openUserProfile(q);
    },

    _closeBladeSearch() {
        const searchInput = document.getElementById('blade-search-input');
        const resultsDropdown = document.getElementById('blade-search-results');
        const searchBlade = document.querySelector('.search-blade');
        if (searchInput) {
            searchInput.value = '';
            searchInput.blur();
        }
        if (resultsDropdown) resultsDropdown.classList.remove('visible');
        if (searchBlade) searchBlade.classList.remove('has-results');
        document.getElementById('inflight-tactical-ui')?.classList.remove('mobile-search-active');
        this._syncSearchActive();
        this._currentMatches = [];
        this._currentResults = { flights: [], users: [], airports: [], airlines: [] };
        this._searchCursorIndex = -1;
    },

    // Toggle the inline clear (✕) button based on whether the field has text.
    _syncSearchActive() {
        const searchBlade = document.querySelector('.search-blade');
        const searchInput = document.getElementById('blade-search-input');
        if (searchBlade) {
            searchBlade.classList.toggle('has-text', !!(searchInput && searchInput.value));
        }
    },

    executeSearchClick(id, lat, lon) {
        if (typeof window.onSearchResultClick === 'function') {
            window.onSearchResultClick(id, lat, lon);
        }
        this._closeBladeSearch();
    },

    executeAirportClick(icao, lat, lon) {
        this._closeBladeSearch();
        if (typeof window.onAirportSearchResultClick === 'function') {
            window.onAirportSearchResultClick({ icao, lat, lon });
        }
    },

    executeAirlineClick(livery) {
        this._closeBladeSearch();
        if (typeof window.onAirlineSearchResultClick === 'function') {
            window.onAirlineSearchResultClick(livery);
        }
    },

    render() {
        const existing = document.getElementById('inflight-tactical-ui');
        if (existing) existing.remove();

        this.allFilters = [];
        Object.values(this.filterGroups).forEach(group => this.allFilters.push(...group.filters));

        const html = `
            <div id="inflight-tactical-ui" class="tactical-ui-root" data-theme="${this._theme}">
                <header class="tactical-header">
                    <div class="top-branding dropdown" id="server-selector">
                        <div class="status-dot"></div>
                        <div class="branding-content">
                            <span id="landing-server-name">${this._currentServer.toUpperCase()} SERVER</span>
                            <i class="fa-solid fa-chevron-down dropdown-arrow"></i>
                        </div>
                        <div class="server-menu">
                            <div class="server-option" data-val="Expert">Expert</div>
                            <div class="server-option" data-val="Training">Training</div>
                            <div class="server-option" data-val="Casual">Casual</div>
                        </div>
                    </div>

                    <div class="top-right-actions">
                        <div class="search-blade">
                            <i class="fa-solid fa-magnifying-glass search-icon"></i>
                            <input type="text" id="blade-search-input" placeholder="Search flights, pilots, airports"
                                   autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
                                   inputmode="search" enterkeyhint="search">
                            <button type="button" id="blade-search-clear" class="search-clear-btn" aria-label="Clear search"><i class="fa-solid fa-circle-xmark"></i></button>
                            <div class="search-shortcut"></div>
                            <div id="blade-search-results" class="search-results-dropdown custom-scroll"></div>
                        </div>
                    </div>

                    <button type="button" id="mobile-search-cancel" class="search-cancel-btn">Cancel</button>
                </header>

                <div id="filter-modal-overlay" class="modal-overlay">
                    <div class="filter-modal">
                        <div class="modal-header">
                            <div class="header-main">
                                <div class="header-icon-box"><i class="fa-solid fa-sliders-h"></i></div>
                                <div class="header-text">
                                    <h2>Tactical Filters</h2>
                                    <span>Refine airspace visualization</span>
                                </div>
                            </div>
                            <button class="close-modal" id="close-filter-modal">&times;</button>
                        </div>
                        <div class="modal-body">
                            <div class="filter-selection-pane custom-scroll">
                                ${Object.entries(this.filterGroups).map(([key, group]) => `
                                    <div class="filter-group-wrapper">
                                        <div class="filter-group-header">${group.label}</div>
                                        <div class="filter-options-list">
                                            ${group.filters.map(f => `
                                                <button class="nexus-item" data-filter-id="${f.id}">
                                                    <div class="nexus-icon"><i class="fa-solid ${f.icon}"></i></div>
                                                    <span class="nexus-label">${f.label}</span>
                                                    <i class="fa-solid fa-plus nexus-add"></i>
                                                </button>
                                            `).join('')}
                                        </div>
                                    </div>
                                `).join('')}
                            </div>
                            <div class="filter-config-pane">
                                <div class="config-header">
                                    <label>Active Rules</label>
                                    <span id="active-count-badge">0 Active</span>
                                </div>
                                <div id="modal-active-filters" class="modal-active-list custom-scroll">
                                    <div class="empty-state">
                                        <div class="empty-icon-circle"><i class="fa-solid fa-filter"></i></div>
                                        <p>No active filters</p>
                                        <span>Select parameters from the left sidebar to configure rules.</span>
                                    </div>
                                </div>
                                <div class="modal-footer-embedded">
                                    <button class="modal-btn secondary" id="clear-filters-btn">Reset</button>
                                    <button class="modal-btn primary" id="apply-filters-btn">Apply Changes</button>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="auth-nexus" id="auth-nexus-container">
                    <button class="orb-btn" id="open-auth-btn" aria-label="Profile">
                        <i class="fa-solid fa-user-astronaut"></i>
                    </button>
                </div>

                <div class="utility-nexus">
                    <div class="orb-row">
                        <div class="nexus-orb-wrapper mobile-only-tab">
                            <button class="orb-btn" id="mobile-server-tab" aria-label="Server">
                                <i class="fa-solid fa-server"></i>
                                <span class="tab-label">Server</span>
                            </button>
                        </div>

                        <div class="weather-nexus-container" id="weather-menu-wrapper">
                            <div class="weather-spread">
                                <button class="spread-opt" data-weather="precip"><i class="fa-solid fa-satellite-dish"></i><span class="spread-label">Radar</span></button>
                                <button class="spread-opt" data-weather="sigmets"><i class="fa-solid fa-triangle-exclamation"></i><span class="spread-label">SIGMETs</span></button>
                                <button class="spread-opt" data-weather="clouds"><i class="fa-solid fa-cloud"></i><span class="spread-label">Clouds</span></button>
                                <button class="spread-opt" data-weather="wind"><i class="fa-solid fa-wind"></i><span class="spread-label">Wind</span></button>
                            </div>
                            <button class="orb-btn" id="tile-weather" aria-label="Weather"><i class="fa-solid fa-cloud-sun-rain"></i><span class="tab-label">Weather</span></button>
                        </div>

                        <div class="nexus-orb-wrapper">
                            <div class="nexus-preview-tooltip" id="filters-preview-tooltip"></div>
                            <button class="orb-btn nexus-trigger" id="toggle-filter-modal" aria-label="Filters">
                                <i class="fa-solid fa-filter"></i>
                                <span class="tab-label">Filters</span>
                                <div id="filter-active-dot" class="active-pulse-dot"></div>
                            </button>
                        </div>

                        <div class="nexus-orb-wrapper desktop-only-tab">
                            <button class="orb-btn" id="tile-atc" aria-label="Active ATC">
                                <i class="fa-solid fa-tower-broadcast"></i>
                                <span class="tab-label">ATC</span>
                                <div id="atc-active-dot" class="active-pulse-dot"></div>
                            </button>
                        </div>

                        <div class="nexus-orb-wrapper">
                            <div class="nexus-preview-tooltip" id="settings-preview-tooltip"></div>
                            <button class="orb-btn" id="tile-settings" aria-label="Settings">
                                <i class="fa-solid fa-gear"></i>
                                <span class="tab-label">Settings</span>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        `;

        const container = document.getElementById('sector-ops-map-fullscreen');
        if (container) container.insertAdjacentHTML('beforeend', html);
    },

    attachListeners() {
        const modalOverlay = document.getElementById('filter-modal-overlay');
        const filterBtn = document.getElementById('toggle-filter-modal');
        const settingsBtn = document.getElementById('tile-settings');
        const searchInput = document.getElementById('blade-search-input');
        const searchResults = document.getElementById('blade-search-results');
        const serverSelector = document.getElementById('server-selector');
        const weatherTrigger = document.getElementById('tile-weather');
        const weatherWrapper = document.getElementById('weather-menu-wrapper');
        const authBtn = document.getElementById('open-auth-btn');
        
        // Listen for live theme updates from profileUI.js
        window.addEventListener('puiThemeChanged', (e) => {
            this._theme = e.detail.theme;
            const root = document.getElementById('inflight-tactical-ui');
            if (root) {
                root.setAttribute('data-theme', this._theme);
            }
        });

        const toggleModal = (state) => {
            this._modalOpen = state;
            modalOverlay?.classList.toggle('open', state);
            if (state) {
                this.refreshUI();
                document.body.style.overflow = 'hidden';
            } else {
                document.body.style.overflow = '';
                document.activeElement?.blur();
            }
        };

        authBtn?.addEventListener('click', () => {
            if (window.AuthUI) {
                window.AuthUI.open();
            } else {
                import('./authUI.js').then(module => {
                    module.AuthUI.open();
                }).catch(err => console.error("Failed to load AuthUI:", err));
            }
        });

        filterBtn?.addEventListener('click', () => {
            if (window.innerWidth <= 768) {
                window.dispatchEvent(new CustomEvent('openMobileUI'));
            } else {
                // Desktop: the tactical filter board now lives in the Global
                // Settings modal's Filters tab (same board as mobile).
                window.dispatchEvent(new CustomEvent('openSettings', { detail: { category: 'airspace' } }));
            }
        });

        settingsBtn?.addEventListener('click', () => {
            window.dispatchEvent(new CustomEvent('openSettings'));
        });

        // Desktop Active ATC board (mirrors the mobile bottom-bar ATC tab).
        const atcBtn = document.getElementById('tile-atc');
        atcBtn?.addEventListener('click', () => {
            window.dispatchEvent(new CustomEvent('openAtcBoard'));
        });
        window.addEventListener('activeAtcUpdated', (e) => {
            const dot = document.getElementById('atc-active-dot');
            if (dot) dot.style.opacity = (e.detail && e.detail.count > 0) ? '1' : '0';
        });

        window.addEventListener('keydown', (e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
                e.preventDefault();
                searchInput?.focus();
            }
            if (searchResults?.classList.contains('visible')) {
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    this._searchCursorIndex = Math.min(this._searchCursorIndex + 1, this._currentMatches.length - 1);
                    this.renderSearchResults(searchInput.value);
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    this._searchCursorIndex = Math.max(this._searchCursorIndex - 1, 0);
                    this.renderSearchResults(searchInput.value);
                } else if (e.key === 'Enter' && this._searchCursorIndex >= 0) {
                    const selected = this._currentMatches[this._searchCursorIndex];
                    this.executeSearchClick(selected.properties.flightId, selected.geometry.coordinates[1], selected.geometry.coordinates[0]);
                }
            }
        });

        searchInput?.addEventListener('input', (e) => {
            this.handleLocalSearch(e.target.value);
            this._syncSearchActive();
        });

        // Mobile: drive the search-active layout off focus (so the Cancel
        // button can appear and the dropdown can take over the screen).
        const root = document.getElementById('inflight-tactical-ui');
        searchInput?.addEventListener('focus', () => {
            root?.classList.add('mobile-search-active');
        });
        // If the field is blurred while still empty (e.g. a tap on the map),
        // collapse back to the resting bar. A non-empty query stays open so
        // the keyboard can drop while the user scrolls the results.
        searchInput?.addEventListener('blur', () => {
            setTimeout(() => {
                if (!searchInput.value && document.activeElement !== searchInput) {
                    this._closeBladeSearch();
                }
            }, 120);
        });

        // Cancel button — use pointerdown so it fires before the input blur
        // steals the tap, then fully tear the search down.
        const cancelBtn = document.getElementById('mobile-search-cancel');
        cancelBtn?.addEventListener('pointerdown', (e) => {
            e.preventDefault();
            this._closeBladeSearch();
        });

        // Inline clear (the small ✕ inside the field) — keep focus so the
        // keyboard stays up and the user can immediately retype.
        const clearBtn = document.getElementById('blade-search-clear');
        clearBtn?.addEventListener('pointerdown', (e) => {
            e.preventDefault();
            if (searchInput) {
                searchInput.value = '';
                searchInput.focus();
            }
            this.handleLocalSearch('');
            this._syncSearchActive();
        });

        filterBtn?.addEventListener('mouseenter', () => this.showPreview('filters'));
        filterBtn?.addEventListener('mouseleave', () => this.hidePreview('filters'));
        settingsBtn?.addEventListener('mouseenter', () => this.showPreview('settings'));
        settingsBtn?.addEventListener('mouseleave', () => this.hidePreview('settings'));

        weatherTrigger?.addEventListener('click', (e) => {
            e.stopPropagation();
            this._weatherMenuOpen = !this._weatherMenuOpen;
            weatherWrapper?.classList.toggle('expanded', this._weatherMenuOpen);
        });

        document.querySelectorAll('.spread-opt').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const isActive = btn.classList.toggle('active');
                window.dispatchEvent(new CustomEvent('weatherToggle', { detail: { type: btn.dataset.weather, isActive } }));
            });
        });

        serverSelector?.addEventListener('click', (e) => {
            e.stopPropagation();
            serverSelector.classList.toggle('open');
        });

        // Mobile bottom-bar Server tab → reuse the polished server bottom sheet
        document.getElementById('mobile-server-tab')?.addEventListener('click', (e) => {
            e.stopPropagation();
            if (window.MobileUIHandler && typeof window.MobileUIHandler.openServerSheet === 'function') {
                window.MobileUIHandler.openServerSheet();
            } else {
                serverSelector?.classList.toggle('open');
            }
        });

        document.querySelectorAll('.server-option').forEach(opt => {
            opt.addEventListener('click', (e) => {
                const val = e.target.dataset.val;
                this._currentServer = val;
                document.getElementById('landing-server-name').textContent = `${val.toUpperCase()} SERVER`;
                window.dispatchEvent(new CustomEvent('serverChange', { detail: { server: val } }));
            });
        });

        document.addEventListener('click', () => {
            serverSelector?.classList.remove('open');
            weatherWrapper?.classList.remove('expanded');
            this._weatherMenuOpen = false;
        });

        document.getElementById('close-filter-modal')?.addEventListener('click', () => toggleModal(false));
        document.getElementById('apply-filters-btn')?.addEventListener('click', () => {
            this.dispatchFilterUpdate();
            toggleModal(false);
        });
        document.getElementById('clear-filters-btn')?.addEventListener('click', () => {
            this._activeFilters = {};
            this.refreshUI();
            this.dispatchFilterUpdate();
        });

        modalOverlay?.addEventListener('click', (e) => { if (e.target === modalOverlay) toggleModal(false); });
        document.querySelectorAll('.nexus-item').forEach(item => {
            item.addEventListener('click', () => this.activateFilter(item.dataset.filterId));
        });
    },

    showPreview(type) {
        const tooltip = document.getElementById(`${type}-preview-tooltip`);
        if (!tooltip) return;

        let content = '';
        if (type === 'filters') {
            const activeKeys = Object.keys(this._activeFilters);
            content = activeKeys.length === 0 ? `<div class="preview-empty">No active filters</div>` : activeKeys.map(id => {
                const def = this.allFilters.find(f => f.id === id);
                const val = this._activeFilters[id];
                let displayVal = def.type === 'range' ? `${val.min || 0} - ${val.max || 'Max'}` : (def.type === 'boolean' ? 'ON' : (val || 'Any'));
                return `<div class="preview-line"><i class="fa-solid ${def.icon}"></i><span class="preview-label">${def.label}:</span><span class="preview-value">${displayVal}</span></div>`;
            }).join('');
        } else {
            content = `<div class="preview-line"><i class="fa-solid fa-server"></i><span class="preview-label">Server:</span><span class="preview-value">${this._currentServer}</span></div>`;
        }

        tooltip.innerHTML = `<div class="preview-header">${type.toUpperCase()} STATUS</div><div class="preview-body">${content}</div><div class="preview-footer">Click icon to manage full settings</div>`;
        tooltip.classList.add('visible');
    },

    hidePreview(type) { document.getElementById(`${type}-preview-tooltip`)?.classList.remove('visible'); },

    activateFilter(id) {
        if (!this._activeFilters[id]) {
            const def = this.allFilters.find(f => f.id === id);
            if (def.type === 'range') this._activeFilters[id] = { min: '', max: '' };
            else if (def.type === 'boolean') this._activeFilters[id] = true;
            else if (def.type === 'select') this._activeFilters[id] = def.options[0];
            else this._activeFilters[id] = '';
        }
        this.refreshUI();
        this.dispatchFilterUpdate();
    },

    removeFilter(id) {
        delete this._activeFilters[id];
        this.refreshUI();
        this.dispatchFilterUpdate();
    },

    updateFilterValue(id, value, subKey = null) {
        if (subKey) this._activeFilters[id] = { ...this._activeFilters[id], [subKey]: value };
        else this._activeFilters[id] = value;
        this.dispatchFilterUpdate();
    },

    refreshUI() {
        const container = document.getElementById('modal-active-filters');
        const badge = document.getElementById('active-count-badge');
        const activeDot = document.getElementById('filter-active-dot');
        if (!container) return;

        const activeEntries = Object.entries(this._activeFilters);
        if (badge) badge.textContent = `${activeEntries.length} Active Rule${activeEntries.length !== 1 ? 's' : ''}`;
        if (activeDot) activeDot.style.opacity = activeEntries.length > 0 ? '1' : '0';

        document.querySelectorAll('.nexus-item').forEach(item => item.classList.toggle('active', !!this._activeFilters[item.dataset.filterId]));

        if (activeEntries.length === 0) {
            container.innerHTML = `<div class="empty-state"><div class="empty-icon-circle"><i class="fa-solid fa-filter"></i></div><p>No active filters</p><span>Select parameters from the left sidebar to configure rules.</span></div>`;
            return;
        }

        container.innerHTML = activeEntries.map(([id, value]) => {
            const def = this.allFilters.find(f => f.id === id);
            return `
                <div class="modal-filter-card slide-in">
                    <div class="card-left-strip"></div>
                    <div class="card-content">
                        <div class="row-header" style="display:flex; justify-content:space-between; align-items:center;">
                            <div class="row-label"><i class="fa-solid ${def.icon}"></i><span>${def.label}</span></div>
                            <button class="row-remove js-remove-filter" data-id="${id}" style="background:none; border:none; color:#ef4444; cursor:pointer;"><i class="fa-solid fa-trash-can"></i></button>
                        </div>
                        <div class="row-control">${this.renderInputControl(id, value)}</div>
                    </div>
                </div>
            `;
        }).join('');

        container.querySelectorAll('.js-remove-filter').forEach(btn => btn.addEventListener('click', (e) => this.removeFilter(e.currentTarget.dataset.id)));
        container.querySelectorAll('.data-input').forEach(input => input.addEventListener('input', (e) => this.updateFilterValue(e.target.dataset.id, e.target.value)));
        container.querySelectorAll('.data-input-min').forEach(input => input.addEventListener('input', (e) => this.updateFilterValue(e.target.dataset.id, e.target.value, 'min')));
        container.querySelectorAll('.data-input-max').forEach(input => input.addEventListener('input', (e) => this.updateFilterValue(e.target.dataset.id, e.target.value, 'max')));
    },

    getUniqueValues(property) {
        const flights = window.getLiveFlightData ? window.getLiveFlightData() : [];
        const values = new Set();
        
        flights.forEach(f => {
            const val = f.properties[property];
            if (val) values.add(val);
        });
        
        return Array.from(values).sort();
    },

    handleAutocomplete(id, query) {
        const suggestionsContainer = document.getElementById(`suggestions-${id}`);
        if (!suggestionsContainer) return;

        if (!query || query.length < 1) {
            suggestionsContainer.innerHTML = '';
            suggestionsContainer.style.display = 'none';
            return;
        }

        const propMap = { 'type': 'aircraftName', 'livery': 'liveryName' };
        const allOptions = this.getUniqueValues(propMap[id] || id);
        
        const matches = allOptions.filter(opt => 
            opt.toUpperCase().includes(query.toUpperCase())
        ).slice(0, 8);

        if (matches.length > 0) {
            suggestionsContainer.innerHTML = matches.map(match => `
                <div class="autocomplete-item" 
                     onmousedown="LandingUI.applySuggestion('${id}', '${match.replace(/'/g, "\\'")}')">
                    ${this.highlightText(match, query)}
                </div>
            `).join('');
            suggestionsContainer.style.display = 'block';
        } else {
            suggestionsContainer.style.display = 'none';
        }
    },

    applySuggestion(id, value) {
        const input = document.querySelector(`input[data-id="${id}"]`);
        if (input) {
            input.value = value;
            this.updateFilterValue(id, value);
            const suggestionsContainer = document.getElementById(`suggestions-${id}`);
            if (suggestionsContainer) suggestionsContainer.style.display = 'none';
        }
    },

    renderInputControl(id, value) {
        const def = this.allFilters.find(f => f.id === id);
        if (def.type === 'select') return `<div class="input-wrapper select-wrapper"><select class="row-input-select data-input" data-id="${id}">${def.options.map(opt => `<option value="${opt}" ${value === opt ? 'selected' : ''}>${opt}</option>`).join('')}</select></div>`;
        if (def.type === 'range') return `<div class="range-pill-container"><div class="range-half"><span class="range-label">MIN</span><input type="number" class="range-input data-input-min" data-id="${id}" placeholder="0" value="${value.min || ''}"></div><div class="range-divider"></div><div class="range-half"><span class="range-label">MAX</span><input type="number" class="range-input data-input-max" data-id="${id}" placeholder="Max" value="${value.max || ''}"></div></div>`;
        if (def.type === 'boolean') return `<div class="bool-indicator" style="font-size:0.8rem; color:#10b981; font-weight:600;"><i class="fa-solid fa-check"></i> Active Policy Enabled</div>`;
        if (def.type === 'autocomplete') {
            return `
                <div class="input-wrapper autocomplete-wrapper">
                    <input type="text" class="row-input data-input autocomplete-input" 
                           data-id="${id}" 
                           placeholder="${def.placeholder || 'Search...'}" 
                           value="${value}"
                           oninput="LandingUI.handleAutocomplete('${id}', this.value)"
                           onfocus="LandingUI.handleAutocomplete('${id}', this.value)"
                           onblur="setTimeout(() => { document.getElementById('suggestions-${id}').style.display='none'; }, 200)">
                    <div id="suggestions-${id}" class="autocomplete-suggestions custom-scroll"></div>
                </div>`;
        }
        return `<div class="input-wrapper"><input type="text" class="row-input data-input" data-id="${id}" placeholder="${def.placeholder || 'Search value...'}" value="${value}"></div>`;
    },

    dispatchFilterUpdate() {
        const quickSearch = document.getElementById('blade-search-input')?.value || '';
        window.dispatchEvent(new CustomEvent('filterUpdate', { detail: { filters: { ...this._activeFilters }, quickSearch } }));
    },

    update(isActive) {
        const el = document.getElementById('inflight-tactical-ui');
        if (el) isActive ? el.classList.add('active') : el.classList.remove('active');
    },

    injectStyles() {
        const css = `
            @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');

            :root {
                --lui-bg-main: #0a0a0b;
                --lui-bg-card: #141416;
                --lui-bg-input: #1c1c1f;
                --lui-bg-panel: #0d0d0e;
                --lui-bg-menu: #18181b;

                --lui-text-main: #fff;
                --lui-text-muted: rgba(255, 255, 255, 0.4);
                --lui-text-dim: rgba(255, 255, 255, 0.3);
                --lui-text-inverse: #000;
                --lui-text-gray-1: #a1a1aa;
                --lui-text-gray-2: #71717a;
                --lui-text-gray-3: #3f3f46;

                --lui-border-light: rgba(255, 255, 255, 0.05);
                --lui-border-base: rgba(255, 255, 255, 0.08);
                --lui-border-strong: rgba(255, 255, 255, 0.15);
                --lui-border-solid: #2d2d30;
                --lui-border-menu: #3f3f46;

                --lui-hover-bg: rgba(255, 255, 255, 0.05);
                --lui-active-bg: rgba(255, 255, 255, 0.12);

                --lui-accent: #38bdf8;
                --lui-accent-hover: rgba(56, 189, 248, 0.1);
                --lui-accent-active: rgba(56, 189, 248, 0.2);

                --lui-glass-bg: rgba(10, 10, 10, 0.85);
                --lui-glass-heavy: rgba(0, 0, 0, 0.85);
                --lui-glass-btn: rgba(15, 15, 15, 0.7);
            }

            .tactical-ui-root[data-theme="light"] {
                --lui-bg-main: #f3f4f6;
                --lui-bg-card: #ffffff;
                --lui-bg-input: #ffffff;
                --lui-bg-panel: #e5e7eb;
                --lui-bg-menu: #ffffff;

                --lui-text-main: #111827;
                --lui-text-muted: rgba(0, 0, 0, 0.5);
                --lui-text-dim: rgba(0, 0, 0, 0.4);
                --lui-text-inverse: #ffffff;
                --lui-text-gray-1: #4b5563;
                --lui-text-gray-2: #6b7280;
                --lui-text-gray-3: #9ca3af;

                --lui-border-light: rgba(0, 0, 0, 0.05);
                --lui-border-base: rgba(0, 0, 0, 0.08);
                --lui-border-strong: rgba(0, 0, 0, 0.15);
                --lui-border-solid: #d1d5db;
                --lui-border-menu: #e5e7eb;

                --lui-hover-bg: rgba(0, 0, 0, 0.05);
                --lui-active-bg: rgba(0, 0, 0, 0.08);

                --lui-accent: #0284c7;
                --lui-accent-hover: rgba(2, 132, 199, 0.1);
                --lui-accent-active: rgba(2, 132, 199, 0.2);

                --lui-glass-bg: rgba(255, 255, 255, 0.85);
                --lui-glass-heavy: rgba(243, 244, 246, 0.85);
                --lui-glass-btn: rgba(255, 255, 255, 0.7);
            }

            .modal-filter-card {
                background: var(--lui-bg-card);
                border: 1px solid var(--lui-border-base);
                border-radius: 20px;
                display: flex;
                overflow: visible !important; 
                box-shadow: 0 8px 30px rgba(0,0,0,0.3);
                position: relative;
            }

            .modal-filter-card:focus-within {
                z-index: 10;
                border-color: var(--lui-accent);
            }

            .card-content {
                flex: 1;
                padding: 24px;
                overflow: visible !important;
            }

            .autocomplete-wrapper {
                position: relative;
                width: 100%;
            }

            .autocomplete-suggestions {
                position: absolute;
                top: calc(100% + 5px);
                left: 0;
                right: 0;
                background: var(--lui-bg-input);
                border: 1px solid var(--lui-accent);
                border-radius: 12px;
                z-index: 9999;
                max-height: 200px;
                overflow-y: auto;
                display: none;
                box-shadow: 0 10px 25px rgba(0,0,0,0.5);
            }

            .autocomplete-item {
                padding: 12px 16px;
                cursor: pointer;
                font-size: 0.9rem;
                color: var(--lui-text-main);
                border-bottom: 1px solid var(--lui-border-light);
            }

            .autocomplete-item:hover {
                background: var(--lui-accent);
                color: var(--lui-text-inverse);
            }

            .premium-highlight {
                color: var(--lui-accent);
                font-weight: 700;
            }
            
            .tactical-ui-root {
                position: absolute;
                inset: 0;
                z-index: 3;
                pointer-events: none;
                opacity: 0;
                visibility: hidden;
                transition: opacity 0.5s ease;
                font-family: 'Inter', sans-serif;
            }
            .tactical-ui-root.active {
                opacity: 1;
                visibility: visible;
            }

            .top-right-actions {
                position: absolute;
                top: 30px;
                right: 40px;
                pointer-events: none;
            }

            .tactical-header {
                position: absolute;
                top: 0;
                left: 0;
                width: 100%;
                pointer-events: none;
                z-index: 2001;
            }

            .top-branding.dropdown {
                position: absolute;
                top: 30px;
                left: 40px;
                pointer-events: auto;
                background: var(--lui-glass-btn);
                padding: 10px 24px;
                border-radius: 100px;
                backdrop-filter: blur(15px);
                border: 1px solid var(--lui-border-base);
                cursor: pointer;
                color: var(--lui-text-main);
                display: flex;
                align-items: center;
                gap: 12px;
                box-shadow: 0 10px 20px rgba(0,0,0,0.3);
                transition: all 0.3s;
                white-space: nowrap;
            }

            .search-blade {
                background: var(--lui-glass-bg);
                backdrop-filter: blur(20px);
                border: 1px solid var(--lui-border-strong);
                border-radius: 100px;
                height: 44px;
                width: 240px;
                display: flex;
                align-items: center;
                padding: 0 18px;
                transition: width 0.25s ease, background 0.3s ease, border-color 0.3s ease, box-shadow 0.3s ease;
                position: relative;
                box-shadow: 0 10px 30px rgba(0,0,0,0.4);
                z-index: 1002;
                pointer-events: auto;
            }

            .search-blade:focus-within {
                width: 380px;
                border-color: var(--lui-accent);
                background: var(--lui-bg-main);
                box-shadow: 0 15px 40px rgba(0,0,0,0.6), 0 0 0 1px var(--lui-accent-hover);
            }
            
            .search-blade.has-results {
                border-bottom-left-radius: 0 !important;
                border-bottom-right-radius: 0 !important;
                border-top-left-radius: 20px !important;
                border-top-right-radius: 20px !important;
            }
            #blade-search-input {
                flex: 1;
                background: none;
                border: none;
                color: var(--lui-text-main);
                margin-left: 10px;
                outline: none;
                font-size: 15px;
                font-weight: 500;
            }
            .search-icon {
                color: var(--lui-text-muted);
                font-size: 14px;
            }
            .search-shortcut {
                background: var(--lui-border-base);
                padding: 3px 8px;
                border-radius: 6px;
                font-size: 0.65rem;
                color: var(--lui-text-muted);
                font-weight: 800;
                margin-left: 10px;
            }

            /* The inline clear (✕) and the Cancel button are mobile-only. */
            .search-clear-btn { display: none; }
            .search-cancel-btn { display: none; }

            .search-results-dropdown {
                position: absolute;
                top: calc(100% + 8px);
                left: 0;
                width: 100%;
                background: var(--lui-bg-main);
                border: 1px solid var(--lui-border-base);
                border-radius: 12px;
                max-height: 440px;
                overflow-y: auto;
                display: none;
                z-index: 1001;
                box-shadow: 0 20px 50px rgba(0,0,0,0.8), 0 0 0 1px var(--lui-border-light);
                padding: 6px;
            }

            .search-results-dropdown.visible { display: block; }

            .premium-result-item {
                display: flex;
                align-items: center;
                padding: 12px 16px;
                gap: 16px;
                cursor: pointer;
                border-radius: 8px;
                transition: all 0.15s ease;
                margin-bottom: 2px;
            }

            .premium-result-item:hover, 
            .premium-result-item.selected {
                background: var(--lui-hover-bg);
            }

            .res-meta-icon {
                font-size: 6px;
                color: var(--lui-text-dim);
                transition: color 0.2s;
            }
            .premium-result-item:hover .res-meta-icon,
            .premium-result-item.selected .res-meta-icon {
                color: var(--lui-text-main);
            }

            .res-info-main { flex: 1; }

            .res-primary-row {
                display: flex;
                align-items: center;
                gap: 10px;
                margin-bottom: 4px;
            }

            .res-callsign {
                font-size: 14px;
                font-weight: 600;
                color: var(--lui-text-main);
            }

            .res-pill {
                font-size: 10px;
                font-weight: 700;
                text-transform: uppercase;
                background: var(--lui-hover-bg);
                color: var(--lui-text-muted);
                padding: 2px 6px;
                border-radius: 4px;
                letter-spacing: 0.02em;
            }

            .res-secondary-row {
                font-size: 12px;
                color: var(--lui-text-muted);
            }

            .res-stats { text-align: right; }

            .res-altitude {
                font-family: 'Inter', sans-serif;
                font-weight: 600;
                font-size: 13px;
                color: var(--lui-text-main);
            }

            .res-altitude span {
                font-size: 10px;
                font-weight: 400;
                color: var(--lui-text-dim);
                margin-left: 2px;
            }

            .premium-empty-state {
                padding: 32px;
                text-align: center;
                color: var(--lui-text-dim);
                font-size: 13px;
            }

            /* ---- Expandable flight result drawer ---- */
            .premium-flight-wrap { border-radius: 8px; }
            .premium-flight-wrap + .premium-flight-wrap { margin-top: 2px; }
            .premium-flight-row { position: relative; }
            .res-expand-btn {
                flex: 0 0 auto;
                width: 30px;
                height: 30px;
                display: flex;
                align-items: center;
                justify-content: center;
                margin-left: 4px;
                border: none;
                border-radius: 8px;
                background: var(--lui-hover-bg);
                color: var(--lui-text-muted);
                cursor: pointer;
                transition: transform 0.2s ease, background 0.15s ease, color 0.15s ease;
            }
            .res-expand-btn:hover { color: var(--lui-text-main); }
            .premium-flight-wrap.detail-open .res-expand-btn { transform: rotate(180deg); color: var(--lui-text-main); }

            .res-detail {
                display: grid;
                grid-template-rows: 0fr;
                overflow: hidden;
                transition: grid-template-rows 0.22s ease;
            }
            .res-detail > * { min-height: 0; }
            .premium-flight-wrap.detail-open .res-detail { grid-template-rows: 1fr; }

            .res-detail-grid {
                display: grid;
                grid-template-columns: repeat(2, minmax(0, 1fr));
                gap: 8px 14px;
                padding: 6px 16px 10px 38px;
            }
            .res-dt { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
            .res-dt-k {
                font-size: 9.5px;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--lui-text-dim);
            }
            .res-dt-v {
                font-size: 13px;
                font-weight: 600;
                color: var(--lui-text-main);
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .res-dt-u { font-weight: 400; color: var(--lui-text-dim); font-size: 11px; }
            .res-dt-arrow { font-size: 10px; color: var(--lui-text-dim); margin: 0 2px; }

            .res-replay-btn {
                display: flex;
                align-items: center;
                gap: 10px;
                margin: 0 8px 8px 38px;
                padding: 9px 12px;
                border: 1px solid var(--lui-border-light);
                border-radius: 10px;
                background: var(--lui-hover-bg);
                color: var(--lui-text-main);
                font-size: 13px;
                font-weight: 600;
                cursor: pointer;
                transition: background 0.15s ease, transform 0.1s ease;
            }
            .res-replay-btn:active { transform: scale(0.98); }
            .res-replay-btn > i { color: var(--lui-accent); font-size: 13px; }
            .res-replay-label { flex: 1 1 auto; text-align: left; }
            .res-pro-badge {
                display: inline-flex;
                align-items: center;
                gap: 4px;
                font-size: 9.5px;
                font-weight: 800;
                letter-spacing: 0.04em;
                color: #1a1205;
                background: linear-gradient(135deg, #fbbf24, #f59e0b);
                padding: 2px 7px;
                border-radius: 999px;
            }
            .res-pro-badge > i { font-size: 8.5px; }

            /* ---- Rich flight detail card (route banner + status + actions) ---- */
            .res-detail-inner { display: flex; flex-direction: column; }
            .res-photo {
                position: relative;
                margin: 6px 14px 2px 38px;
                aspect-ratio: 16 / 9;
                border-radius: 12px;
                overflow: hidden;
                background: var(--lui-hover-bg);
            }
            .res-photo img { width: 100%; height: 100%; object-fit: cover; display: block; }
            .res-photo-credit {
                position: absolute;
                right: 7px;
                bottom: 6px;
                font-size: 9px;
                font-weight: 600;
                color: rgba(255, 255, 255, 0.85);
                background: rgba(0, 0, 0, 0.45);
                padding: 2px 6px;
                border-radius: 999px;
            }
            .res-pill-reg { text-transform: none; }
            .res-stats { display: flex; flex-direction: column; align-items: flex-end; gap: 3px; }
            .res-live-pill {
                display: inline-flex;
                align-items: center;
                gap: 4px;
                font-size: 9px;
                font-weight: 800;
                letter-spacing: 0.06em;
                color: #052e14;
                background: linear-gradient(135deg, #4ade80, #22c55e);
                padding: 2px 7px;
                border-radius: 999px;
            }
            .res-live-pill > i { font-size: 8px; }

            .res-route-banner {
                display: flex;
                align-items: center;
                gap: 10px;
                margin: 6px 14px 4px 38px;
                padding: 10px 12px;
                background: var(--lui-hover-bg);
                border: 1px solid var(--lui-border-light);
                border-radius: 12px;
            }
            .res-route-ep {
                flex: 1 1 0;
                min-width: 0;
                display: flex;
                flex-direction: column;
                gap: 1px;
            }
            .res-route-ep.is-arr { text-align: right; align-items: flex-end; }
            .res-route-code {
                font-size: 17px;
                font-weight: 800;
                letter-spacing: 0.02em;
                color: var(--lui-text-main);
            }
            .res-route-name {
                font-size: 10.5px;
                font-weight: 500;
                color: var(--lui-text-muted);
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                max-width: 100%;
            }
            .res-route-mid {
                flex: 1.2 1 0;
                display: flex;
                align-items: center;
                gap: 6px;
                color: var(--lui-text-dim);
            }
            .res-route-mid > i { font-size: 11px; flex: 0 0 auto; }
            .res-route-line {
                flex: 1 1 auto;
                height: 1px;
                background: linear-gradient(90deg, transparent, var(--lui-border-strong), transparent);
            }

            .res-status-line {
                display: flex;
                align-items: center;
                gap: 8px;
                margin: 4px 14px 2px 38px;
                font-size: 12px;
                font-weight: 700;
                color: #22c55e;
            }
            .res-status-line > i { font-size: 11px; }
            .res-status-line.is-ground { color: var(--lui-text-muted); }
            .res-status-line.is-climb { color: #38bdf8; }
            .res-status-line.is-descent { color: #fbbf24; }

            .res-pilot-link {
                display: flex;
                align-items: center;
                gap: 10px;
                margin: 6px 14px 0 38px;
                padding: 8px 12px;
                border: 1px solid var(--lui-border-light);
                border-radius: 12px;
                background: var(--lui-hover-bg);
                color: var(--lui-text-main);
                cursor: pointer;
                text-align: left;
                transition: background 0.15s ease, transform 0.1s ease;
            }
            .res-pilot-link:active { transform: scale(0.98); }
            .res-pilot-link-text {
                flex: 1 1 auto;
                min-width: 0;
                display: flex;
                flex-direction: column;
                gap: 1px;
            }
            .res-pilot-link-name {
                font-size: 13px;
                font-weight: 700;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .res-pilot-link-sub {
                font-size: 10.5px;
                font-weight: 500;
                color: var(--lui-text-muted);
            }
            .res-pilot-link-chev { font-size: 11px; color: var(--lui-text-dim); }

            .res-action-bar {
                display: flex;
                gap: 8px;
                margin: 8px 14px 12px 38px;
            }
            .res-action-btn {
                flex: 1 1 0;
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
                padding: 10px 12px;
                border: 1px solid var(--lui-border-light);
                border-radius: 10px;
                background: var(--lui-hover-bg);
                color: var(--lui-text-main);
                font-size: 12.5px;
                font-weight: 700;
                cursor: pointer;
                transition: background 0.15s ease, transform 0.1s ease;
            }
            .res-action-btn:active { transform: scale(0.97); }
            .res-action-btn > i { font-size: 12px; }
            .res-action-btn.is-primary {
                background: var(--lui-accent);
                border-color: var(--lui-accent);
                color: #fff;
            }
            .res-action-btn .res-pro-badge { margin-left: 2px; }

            /* ---- Pilot rows (live users + offline network lookup) ---- */
            .res-user-avatar {
                flex: 0 0 auto;
                display: grid;
                place-items: center;
                width: 34px;
                height: 34px;
                border-radius: 50%;
                background: linear-gradient(135deg, #3b82f6, #8b5cf6);
                color: #fff;
                font-size: 12px;
                font-weight: 800;
                letter-spacing: 0.03em;
            }
            .res-user-avatar.is-lookup {
                background: var(--lui-hover-bg);
                color: var(--lui-text-muted);
                border: 1px dashed var(--lui-border-strong);
                font-size: 12px;
            }
            .res-user-chev { font-size: 11px; color: var(--lui-text-dim); }

            .blade-results-section + .blade-results-section {
                border-top: 1px solid var(--lui-border-base);
                margin-top: 4px;
                padding-top: 4px;
            }
            .blade-results-header {
                font-size: 0.65rem;
                font-weight: 700;
                letter-spacing: 0.1em;
                text-transform: uppercase;
                color: var(--lui-text-muted);
                padding: 8px 12px 4px;
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            .blade-results-count {
                color: var(--lui-text-dim);
                font-weight: 600;
            }
            .premium-highlight {
                color: var(--lui-accent);
                font-weight: 700;
            }

            .auth-nexus {
                position: absolute;
                bottom: 40px;
                left: 40px;
                pointer-events: auto;
                z-index: 2000;
            }

            .utility-nexus {
                position: absolute;
                bottom: 40px;
                right: 40px;
                pointer-events: none;
            }
            .orb-row {
                display: flex;
                gap: 15px;
                pointer-events: auto;
                align-items: flex-end;
            }
            .orb-btn {
                width: 52px;
                height: 52px;
                border-radius: 50%;
                background: var(--lui-glass-btn);
                backdrop-filter: blur(15px);
                border: 1px solid var(--lui-border-base);
                color: var(--lui-text-main);
                cursor: pointer;
                display: grid;
                place-items: center;
                transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
                position: relative;
                box-shadow: 0 10px 20px rgba(0,0,0,0.3);
                font-size: 1.1rem;
            }
            .orb-btn:hover {
                transform: translateY(-5px);
                background: var(--lui-text-main);
                color: var(--lui-text-inverse);
                border-color: var(--lui-text-main);
                box-shadow: 0 15px 30px rgba(0,0,0,0.2);
            }

            .nexus-orb-wrapper { position: relative; }
            /* Tab labels + Server tab are mobile-only (FR24 bottom bar) */
            .tab-label { display: none; }
            .mobile-only-tab { display: none; }
            /* The ATC orb is desktop-only — mobile has its own ATC tab in the
               iOS bottom bar (MobileLandingChromeUI). */
            @media (max-width: 768px) {
                .desktop-only-tab { display: none !important; }
            }
            .nexus-preview-tooltip {
                position: absolute;
                bottom: calc(100% + 20px);
                right: 0;
                width: 260px;
                background: var(--lui-glass-bg);
                backdrop-filter: blur(30px);
                border: 1px solid var(--lui-border-strong);
                border-radius: 18px;
                padding: 20px;
                color: var(--lui-text-main);
                opacity: 0;
                visibility: hidden;
                transform: translateY(15px);
                transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                box-shadow: 0 30px 60px rgba(0,0,0,0.6);
                pointer-events: none;
                z-index: 4000;
            }
            .nexus-preview-tooltip.visible {
                opacity: 1;
                visibility: visible;
                transform: translateY(0);
            }
            .preview-header {
                font-size: 0.65rem;
                font-weight: 900;
                color: var(--lui-text-gray-2);
                letter-spacing: 1.5px;
                margin-bottom: 14px;
                border-bottom: 1px solid var(--lui-border-base);
                padding-bottom: 8px;
                text-transform: uppercase;
            }
            .preview-line {
                display: flex;
                align-items: center;
                gap: 12px;
                font-size: 0.85rem;
                margin-bottom: 10px;
            }
            .preview-line i {
                color: var(--lui-accent);
                width: 18px;
                text-align: center;
                font-size: 0.8rem;
            }
            .preview-label { color: var(--lui-text-gray-1); }
            .preview-value { font-weight: 700; color: var(--lui-text-main); margin-left: auto; }
            .preview-footer {
                margin-top: 14px;
                font-size: 0.65rem;
                color: var(--lui-accent);
                font-weight: 600;
                border-top: 1px solid var(--lui-border-light);
                padding-top: 10px;
            }

            .top-branding.dropdown:hover {
                background: var(--lui-glass-heavy);
                border-color: var(--lui-border-strong);
            }
            .status-dot { width: 8px; height: 8px; background: #10b981; border-radius: 50%; box-shadow: 0 0 12px #10b981; }
            #landing-server-name { font-size: 0.8rem; font-weight: 800; letter-spacing: 1px; }
            .dropdown-arrow { font-size: 0.75rem; opacity: 0.4; transition: transform 0.3s; }
            .top-branding.dropdown.open .dropdown-arrow { transform: rotate(180deg); opacity: 1; }

            .server-menu {
                position: absolute;
                top: calc(100% + 12px);
                left: 0;
                width: 100%;
                background: var(--lui-bg-menu);
                border: 1px solid var(--lui-border-menu);
                border-radius: 16px;
                display: none;
                flex-direction: column;
                overflow: hidden;
                box-shadow: 0 20px 40px rgba(0,0,0,0.6);
                z-index: 5000;
            }
            .top-branding.dropdown.open .server-menu { display: flex; }
            .server-option {
                padding: 14px 24px;
                font-size: 0.85rem;
                font-weight: 600;
                color: var(--lui-text-gray-1);
                transition: all 0.2s;
            }
            .server-option:hover {
                background: var(--lui-accent-hover);
                color: var(--lui-accent);
            }

            .weather-nexus-container { position: relative; display: flex; flex-direction: column-reverse; align-items: center; gap: 15px; }
            .weather-spread {
                display: flex;
                flex-direction: column-reverse;
                align-items: center;
                gap: 12px;
                opacity: 0;
                visibility: hidden;
                position: absolute;
                bottom: calc(100% + 15px);
                left: 50%;
                transform: translateX(-50%) translateY(20px);
                transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                pointer-events: none;
            }
            .weather-nexus-container.expanded .weather-spread {
                opacity: 1;
                visibility: visible;
                transform: translateX(-50%) translateY(0);
                pointer-events: auto;
            }
            .spread-opt {
                padding: 12px 20px;
                border-radius: 100px;
                background: var(--lui-glass-bg);
                backdrop-filter: blur(20px);
                border: 1px solid var(--lui-border-strong);
                color: var(--lui-text-muted);
                cursor: pointer;
                display: flex;
                align-items: center;
                gap: 14px;
                white-space: nowrap;
                transition: all 0.2s;
                box-shadow: 0 10px 20px rgba(0,0,0,0.4);
            }
            .spread-opt i { font-size: 0.95rem; }
            .spread-label { font-size: 0.8rem; font-weight: 700; }
            .spread-opt:hover { background: var(--lui-hover-bg); color: var(--lui-text-main); border-color: var(--lui-accent); }
            .spread-opt.active { background: var(--lui-accent-active); color: var(--lui-accent); border-color: var(--lui-accent); }

            .modal-overlay {
                position: fixed;
                inset: 0;
                background: var(--lui-glass-heavy);
                backdrop-filter: blur(15px);
                display: flex;
                align-items: center;
                justify-content: center;
                opacity: 0;
                visibility: hidden;
                transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                z-index: 3000;
                pointer-events: auto;
            }
            .modal-overlay.open { opacity: 1; visibility: visible; }
            
            .filter-modal {
                background: var(--lui-bg-main);
                width: 940px;
                height: 660px;
                max-width: 95vw;
                max-height: 90vh;
                border: 1px solid var(--lui-border-base);
                border-radius: 28px;
                display: flex;
                flex-direction: column;
                overflow: hidden;
                box-shadow: 0 50px 100px rgba(0,0,0,0.9);
                transform: scale(0.96) translateY(20px);
                transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);
            }
            .modal-overlay.open .filter-modal { transform: scale(1) translateY(0); }

            .modal-header {
                height: 90px;
                padding: 0 40px;
                background: var(--lui-hover-bg);
                border-bottom: 1px solid var(--lui-border-base);
                display: flex;
                justify-content: space-between;
                align-items: center;
            }
            .header-main { display: flex; align-items: center; gap: 24px; }
            .header-icon-box {
                width: 50px;
                height: 50px;
                background: var(--lui-accent-hover);
                border-radius: 14px;
                color: var(--lui-accent);
                display: grid;
                place-items: center;
                font-size: 1.3rem;
            }
            .header-text h2 { margin: 0; font-size: 1.4rem; font-weight: 800; color: var(--lui-text-main); }
            .header-text span { font-size: 0.9rem; color: var(--lui-text-gray-2); font-weight: 500; }
            .close-modal { background: none; border: none; color: var(--lui-text-gray-2); font-size: 2.2rem; cursor: pointer; transition: 0.2s; }
            .close-modal:hover { color: var(--lui-text-main); transform: rotate(90deg); }

            .modal-body { display: flex; flex: 1; overflow: hidden; }
            .filter-selection-pane {
                width: 300px;
                background: var(--lui-hover-bg);
                border-right: 1px solid var(--lui-border-base);
                padding: 30px;
                overflow-y: auto;
            }
            .filter-group-header {
                font-size: 0.7rem;
                font-weight: 900;
                color: var(--lui-text-gray-3);
                text-transform: uppercase;
                letter-spacing: 2px;
                margin-bottom: 18px;
                margin-top: 30px;
            }
            .filter-group-header:first-child { margin-top: 0; }
            
            .nexus-item {
                width: 100%;
                text-align: left;
                background: transparent;
                border: none;
                padding: 14px 18px;
                border-radius: 14px;
                color: var(--lui-text-gray-2);
                cursor: pointer;
                display: flex;
                align-items: center;
                gap: 14px;
                transition: all 0.25s;
                margin-bottom: 6px;
            }
            .nexus-item:hover { background: var(--lui-hover-bg); color: var(--lui-text-main); }
            .nexus-item.active { background: var(--lui-accent-hover); color: var(--lui-accent); font-weight: 700; }
            .nexus-icon { width: 24px; text-align: center; font-size: 1rem; }

            .filter-config-pane {
                flex: 1;
                padding: 40px;
                background: var(--lui-bg-panel);
                display: flex;
                flex-direction: column;
                position: relative;
            }
            .config-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 28px; }
            .config-header label { font-size: 0.8rem; font-weight: 900; color: var(--lui-text-gray-3); text-transform: uppercase; letter-spacing: 2.5px; }
            #active-count-badge { background: var(--lui-accent); color: var(--lui-text-inverse); padding: 6px 14px; border-radius: 100px; font-size: 0.75rem; font-weight: 800; }

            .modal-active-list { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 20px; padding-bottom: 120px; }
            .modal-filter-card {
                background: var(--lui-bg-card);
                border: 1px solid var(--lui-border-base);
                border-radius: 20px;
                display: flex;
                overflow: hidden;
                box-shadow: 0 8px 30px rgba(0,0,0,0.3);
            }
            .card-left-strip { width: 6px; background: var(--lui-accent); }
            .card-content { flex: 1; padding: 24px; }
            .row-label { display: flex; align-items: center; gap: 14px; font-size: 1rem; font-weight: 700; color: var(--lui-text-main); }
            .row-label i { color: var(--lui-accent); opacity: 0.9; }
            .row-control { margin-top: 20px; }

            .row-input, .row-input-select {
                width: 100%;
                background: var(--lui-bg-input);
                border: 1px solid var(--lui-border-solid);
                border-radius: 12px;
                color: var(--lui-text-main);
                padding: 14px 18px;
                font-size: 0.95rem;
                font-family: inherit;
                outline: none;
                transition: all 0.2s;
            }
            .row-input:focus, .row-input-select:focus { border-color: var(--lui-accent); background: var(--lui-hover-bg); box-shadow: 0 0 0 4px var(--lui-accent-hover); }

            .range-pill-container {
                display: flex;
                background: var(--lui-bg-input);
                border: 1px solid var(--lui-border-solid);
                border-radius: 12px;
                overflow: hidden;
            }
            .range-half { flex: 1; display: flex; align-items: center; padding: 0 16px; }
            .range-label { font-size: 0.65rem; font-weight: 900; color: var(--lui-text-gray-3); margin-right: 14px; }
            .range-input { background: none; border: none; color: var(--lui-text-main); width: 100%; padding: 14px 0; outline: none; font-size: 1rem; font-weight: 600; }
            .range-divider { width: 1px; height: 28px; background: var(--lui-border-solid); align-self: center; }

            .modal-footer-embedded {
                position: absolute;
                bottom: 0;
                left: 0;
                right: 0;
                padding: 30px 40px;
                background: var(--lui-glass-bg);
                backdrop-filter: blur(12px);
                border-top: 1px solid var(--lui-border-base);
                display: flex;
                justify-content: flex-end;
                gap: 20px;
            }
            .modal-btn {
                padding: 14px 32px;
                border-radius: 14px;
                font-weight: 700;
                font-size: 1rem;
                cursor: pointer;
                transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
                border: none;
            }
            .modal-btn.primary { background: var(--lui-accent); color: var(--lui-text-inverse); }
            .modal-btn.primary:hover { transform: translateY(-3px); box-shadow: 0 12px 25px var(--lui-accent-hover); }
            .modal-btn.secondary { background: var(--lui-hover-bg); color: var(--lui-text-main); border: 1px solid var(--lui-border-base); }
            .modal-btn.secondary:hover { background: var(--lui-active-bg); }

            .empty-state {
                flex: 1;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                color: var(--lui-text-gray-3);
                text-align: center;
                padding: 40px;
            }
            .empty-icon-circle {
                width: 90px;
                height: 90px;
                border-radius: 50%;
                background: var(--lui-hover-bg);
                border: 2px dashed var(--lui-border-base);
                display: grid;
                place-items: center;
                font-size: 2.2rem;
                margin-bottom: 24px;
            }
            .empty-state p { margin: 0; color: var(--lui-text-gray-1); font-weight: 700; font-size: 1.2rem; }
            .empty-state span { font-size: 0.95rem; margin-top: 10px; max-width: 260px; line-height: 1.5; }

            .active-pulse-dot {
                position: absolute;
                top: 0;
                right: 0;
                width: 12px;
                height: 12px;
                background: var(--lui-accent);
                border-radius: 50%;
                border: 2px solid var(--lui-bg-main);
                opacity: 0;
                transition: opacity 0.3s;
                box-shadow: 0 0 15px var(--lui-accent);
            }

            .custom-scroll::-webkit-scrollbar { width: 8px; }
            .custom-scroll::-webkit-scrollbar-track { background: transparent; }
            .custom-scroll::-webkit-scrollbar-thumb { background: var(--lui-border-base); border-radius: 10px; border: 2px solid transparent; background-clip: content-box; }
            .custom-scroll::-webkit-scrollbar-thumb:hover { background: var(--lui-border-strong); border: 2px solid transparent; background-clip: content-box; }

            @keyframes slideIn {
                from { opacity: 0; transform: translateY(12px); }
                to { opacity: 1; transform: translateY(0); }
            }
            .slide-in { animation: slideIn 0.35s forwards; }

            @media (max-width: 768px) {
                .tactical-header {
                    position: fixed;
                    top: 0;
                    height: 60px;
                    background: var(--lui-bg-main);
                    backdrop-filter: blur(20px);
                    border-bottom: 1px solid var(--lui-border-base);
                    display: flex !important;
                    align-items: center !important;
                    justify-content: space-between !important;
                    padding: 0 15px !important;
                    pointer-events: none !important;
                }

                .top-branding.dropdown, 
                .top-right-actions {
                    position: static !important;
                    transform: none !important;
                    box-shadow: none !important;
                    padding: 0 !important;
                    margin: 0 !important;
                    background: transparent !important;
                    border: none !important;
                    backdrop-filter: none !important;
                }

                .top-branding.dropdown {
                    flex-shrink: 0;
                    margin-right: 15px !important;
                }

                #landing-server-name {
                    font-size: 0.7rem !important;
                    font-weight: 800;
                }

                .top-right-actions {
                    flex: 1;
                    max-width: 200px; 
                    display: flex;
                    justify-content: flex-end;
                }

                .search-blade {
                    width: 100% !important;
                    height: 36px !important;
                    padding: 0 12px !important;
                    background: var(--lui-border-base) !important;
                    border-radius: 8px !important;
                }

                .search-blade:focus-within {
                    position: absolute !important;
                    left: 10px !important;
                    right: 10px !important;
                    top: 10px !important;
                    width: calc(100% - 20px) !important;
                    height: 40px !important;
                    z-index: 100 !important;
                    max-width: none !important;
                    background: var(--lui-bg-card) !important;
                }

                .search-shortcut { display: none !important; }

                .utility-nexus { bottom: 20px !important; right: 20px !important; }
                
                .auth-nexus {
                    bottom: 20px !important;
                    left: 20px !important;
                }

                .orb-btn { width: 44px !important; height: 44px !important; }
                
                .search-results-dropdown {
                    position: fixed !important;
                    top: 60px !important;
                    left: 0 !important;
                    width: 100vw !important;
                    /* dvh accounts for mobile browser chrome (URL bar / safe area)
                       so the bottom of the dropdown is never clipped. vh stays as
                       a fallback for browsers without dvh support. */
                    height: calc(100vh - 60px) !important;
                    height: calc(100dvh - 60px) !important;
                    max-height: none !important;
                    border-radius: 0 !important;
                    padding-bottom: env(safe-area-inset-bottom, 0px) !important;
                }
                .blade-results-section + .blade-results-section {
                    margin-top: 0 !important;
                    padding-top: 0 !important;
                }
                .blade-results-header {
                    position: sticky;
                    top: 0;
                    background: var(--lui-bg-main);
                    z-index: 1;
                    padding: 12px 16px 6px !important;
                }

                .top-branding.dropdown {
                    top: 15px !important;
                    left: 15px !important;
                    padding: 8px 14px !important;
                    gap: 8px !important;
                }
                #landing-server-name {
                    font-size: 0.7rem !important; 
                }
                .status-dot {
                    width: 6px !important;
                    height: 6px !important;
                }

                .top-right-actions {
                    position: static !important;
                    flex: 1;
                    display: flex;
                    justify-content: flex-end; 
                    pointer-events: auto;
                }

                .search-blade {
                    width: 150px !important; 
                    height: 38px !important;
                    transition: width 0.3s cubic-bezier(0.4, 0, 0.2, 1); 
                    position: relative !important; 
                }

                .search-blade:focus-within {
                    width: calc(100vw - 120px) !important; 
                    z-index: 100 !important;
                }
                #blade-search-input {
                    font-size: 13px !important;
                }
                .search-shortcut {
                    display: none; 
                }

                .utility-nexus {
                    bottom: 20px !important;
                    right: 20px !important;
                }
                .orb-row {
                    gap: 10px !important;
                }
                .orb-btn {
                    width: 42px !important;
                    height: 42px !important;
                    font-size: 0.9rem !important; 
                }

                .spread-opt {
                    padding: 8px 15px !important;
                }
                .spread-opt i {
                    font-size: 0.8rem !important;
                }
            }

            /* ============================================================
               FR24-style mobile chrome (authoritative overrides — kept last
               so they win over the legacy mobile rules above)
               ============================================================ */
            @media (max-width: 768px) {
                /* ---------- TOP: native-iOS search bar ---------- *
                   One frosted bar pinned under the status bar. It holds the
                   search field; the profile avatar floats at the trailing
                   edge while idle and is swapped for a "Cancel" button while
                   searching (the standard iOS search pattern). */
                .tactical-header {
                    top: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    width: 100% !important;
                    height: auto !important;
                    padding: calc(env(safe-area-inset-top, 0px) + 8px) 64px 8px 12px !important;
                    background: var(--lui-glass-bg) !important;
                    -webkit-backdrop-filter: blur(24px) saturate(180%) !important;
                    backdrop-filter: blur(24px) saturate(180%) !important;
                    border-bottom: 1px solid var(--lui-border-base) !important;
                    display: flex !important;
                    align-items: center !important;
                    gap: 8px !important;
                    pointer-events: none !important;
                    z-index: 1500 !important;
                    transition: padding 0.25s cubic-bezier(0.16,1,0.3,1) !important;
                }
                /* Server moved to the bottom bar — hide it from the top */
                .tactical-header .top-branding.dropdown { display: none !important; }

                .top-right-actions {
                    flex: 1 1 auto !important;
                    width: auto !important;
                    max-width: none !important;
                    display: flex !important;
                    pointer-events: auto !important;
                }
                .search-blade {
                    width: 100% !important;
                    height: 40px !important;
                    padding: 0 14px !important;
                    background: var(--lui-bg-input) !important;
                    border: 1px solid var(--lui-border-base) !important;
                    border-radius: 12px !important;
                    display: flex !important;
                    align-items: center !important;
                    gap: 8px !important;
                    box-shadow: none !important;
                    transition: border-color 0.2s ease, box-shadow 0.2s ease !important;
                }
                .search-blade .search-icon { color: var(--lui-text-gray-1) !important; font-size: 0.9rem !important; }
                #blade-search-input {
                    font-size: 16px !important; /* >=16px stops iOS auto-zoom on focus */
                    flex: 1 1 auto !important;
                    min-width: 0 !important;
                    -webkit-appearance: none !important;
                }
                #blade-search-input::placeholder { color: var(--lui-text-muted) !important; }

                /* Inline clear (✕) — only once there's text */
                .search-clear-btn {
                    display: none;
                    background: none !important;
                    border: none !important;
                    padding: 0 2px !important;
                    margin: 0 !important;
                    color: var(--lui-text-gray-2) !important;
                    font-size: 1rem !important;
                    line-height: 1 !important;
                    cursor: pointer;
                    flex: 0 0 auto !important;
                }
                .search-blade.has-text .search-clear-btn { display: block !important; }

                /* Focus / active: the bar pins to the top, full width,
                   leaving room for the trailing Cancel button. */
                .mobile-search-active .search-blade,
                .search-blade:focus-within {
                    position: fixed !important;
                    left: 12px !important;
                    right: 72px !important;
                    top: calc(env(safe-area-inset-top, 0px) + 8px) !important;
                    width: auto !important;
                    max-width: none !important;
                    height: 40px !important;
                    border-radius: 12px !important;
                    z-index: 1600 !important;
                    background: var(--lui-bg-card) !important;
                    border-color: var(--lui-border-base) !important;
                    box-shadow: 0 4px 16px rgba(0,0,0,0.35) !important;
                }

                /* Full-screen results sheet under the search bar. */
                .search-results-dropdown {
                    position: fixed !important;
                    top: calc(env(safe-area-inset-top, 0px) + 56px) !important;
                    left: 0 !important;
                    width: 100vw !important;
                    height: calc(100vh - env(safe-area-inset-top, 0px) - 56px) !important;
                    height: calc(100dvh - env(safe-area-inset-top, 0px) - 56px) !important;
                    max-height: none !important;
                    border-radius: 0 !important;
                    border: none !important;
                    padding: 8px 0 calc(env(safe-area-inset-bottom, 0px) + 16px) !important;
                    background: var(--lui-bg-main) !important;
                    box-shadow: none !important;
                    -webkit-overflow-scrolling: touch !important;
                    overscroll-behavior: contain !important;
                }

                /* ---------- Touch-sized result rows ---------- */
                .premium-result-item {
                    min-height: 60px !important;
                    padding: 10px 16px !important;
                    gap: 14px !important;
                    margin-bottom: 0 !important;
                    border-radius: 0 !important;
                    border-bottom: 1px solid var(--lui-border-light) !important;
                }
                .premium-result-item:active { background: var(--lui-active-bg) !important; }
                .res-callsign { font-size: 15px !important; }
                .res-secondary-row { font-size: 13px !important; }
                .res-meta-icon { font-size: 8px !important; }
                .blade-results-header {
                    background: var(--lui-bg-main) !important;
                    padding: 14px 16px 6px !important;
                    font-size: 0.62rem !important;
                }

                /* ---------- TRAILING: profile avatar (idle) ---------- */
                .auth-nexus {
                    position: fixed !important;
                    top: calc(env(safe-area-inset-top, 0px) + 8px) !important;
                    right: 12px !important;
                    left: auto !important;
                    bottom: auto !important;
                    z-index: 1600 !important;
                    transition: opacity 0.2s ease !important;
                }
                .auth-nexus .orb-btn {
                    width: 40px !important;
                    height: 40px !important;
                    border-radius: 50% !important;
                    font-size: 0.95rem !important;
                    background: var(--lui-bg-input) !important;
                    border: 1px solid var(--lui-border-base) !important;
                    color: var(--lui-text-main) !important;
                    box-shadow: none !important;
                }
                .auth-nexus .orb-btn:active {
                    transform: scale(0.94) !important;
                    background: var(--lui-bg-card) !important;
                }

                /* ---------- TRAILING: Cancel button (searching) ---------- */
                .search-cancel-btn {
                    display: block !important;
                    position: fixed !important;
                    top: calc(env(safe-area-inset-top, 0px) + 8px) !important;
                    right: 12px !important;
                    height: 40px !important;
                    padding: 0 4px !important;
                    background: none !important;
                    border: none !important;
                    color: var(--lui-accent) !important;
                    font-family: 'Inter', sans-serif !important;
                    font-size: 16px !important;
                    font-weight: 600 !important;
                    cursor: pointer;
                    opacity: 0 !important;
                    pointer-events: none !important;
                    transform: translateX(6px) !important;
                    transition: opacity 0.2s ease, transform 0.2s ease !important;
                    z-index: 1601 !important;
                }
                .mobile-search-active .search-cancel-btn {
                    opacity: 1 !important;
                    pointer-events: auto !important;
                    transform: translateX(0) !important;
                }

                /* ---------- BOTTOM: floating tab bar ---------- */
                .utility-nexus {
                    position: fixed !important;
                    left: 50% !important;
                    right: auto !important;
                    bottom: calc(env(safe-area-inset-bottom, 0px) + 10px) !important;
                    transform: translateX(-50%) !important;
                    pointer-events: none !important;
                    z-index: 1500 !important;
                    transition: transform 0.3s cubic-bezier(0.16,1,0.3,1), opacity 0.3s !important;
                }
                .orb-row {
                    gap: 2px !important;
                    align-items: stretch !important;
                    background: var(--lui-glass-bg) !important;
                    -webkit-backdrop-filter: blur(22px) !important;
                    backdrop-filter: blur(22px) !important;
                    border: 1px solid var(--lui-border-base) !important;
                    border-radius: 22px !important;
                    padding: 6px !important;
                    box-shadow: 0 12px 30px rgba(0,0,0,0.45) !important;
                    pointer-events: auto !important;
                }
                .mobile-only-tab { display: block !important; }

                .orb-row .orb-btn {
                    width: 64px !important;
                    height: auto !important;
                    min-height: 48px !important;
                    border-radius: 14px !important;
                    background: transparent !important;
                    border: none !important;
                    box-shadow: none !important;
                    display: flex !important;
                    flex-direction: column !important;
                    align-items: center !important;
                    justify-content: center !important;
                    gap: 4px !important;
                    color: var(--lui-text-gray-1) !important;
                    font-size: 1.05rem !important;
                    transform: none !important;
                }
                .orb-row .orb-btn:hover,
                .orb-row .orb-btn:active {
                    transform: none !important;
                    background: var(--lui-active-bg) !important;
                    color: var(--lui-accent) !important;
                }
                .orb-row .tab-label {
                    display: block !important;
                    font-size: 0.62rem !important;
                    font-weight: 700 !important;
                    letter-spacing: 0.2px !important;
                    line-height: 1 !important;
                }
                .orb-row .active-pulse-dot {
                    position: absolute !important;
                    top: 6px !important;
                    right: 14px !important;
                    bottom: auto !important;
                }
                .weather-nexus-container { flex-direction: column !important; gap: 0 !important; }

                /* Slide the tab bar away while searching or when a detail sheet is open */
                .mobile-search-active .utility-nexus,
                #sector-ops-map-fullscreen:has(.mobile-island-bottom.island-active) .utility-nexus {
                    opacity: 0 !important;
                    transform: translateX(-50%) translateY(140%) !important;
                    pointer-events: none !important;
                }
                /* Hide the profile avatar while searching (Cancel takes its slot) */
                .mobile-search-active .auth-nexus {
                    opacity: 0 !important;
                    pointer-events: none !important;
                }
            }
        `;
        
        const styleId = 'landing-ui-integrated-css';
        if (!document.getElementById(styleId)) {
            const style = document.createElement('style');
            style.id = styleId;
            style.textContent = css;
            document.head.appendChild(style);
        }
    }
};