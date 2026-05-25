export const LandingUI = {
    _isVisible: false,
    _modalOpen: false,
    _weatherMenuOpen: false,
    _activeFilters: {}, 
    _currentServer: 'Expert', 
    _searchCursorIndex: -1,
    _currentMatches: [],
    _currentResults: { flights: [], airports: [], airlines: [] },
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
            this._currentResults = { flights: [], airports: [], airlines: [] };
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
            : { flights: [], airports: [], airlines: [] };

        this._currentResults = results;
        // Keep flight matches around for keyboard nav (arrows + Enter).
        this._currentMatches = (results.flights || []).map(r => r.feature);
        this._searchCursorIndex = -1;

        const total = (results.flights?.length || 0) + (results.airports?.length || 0) + (results.airlines?.length || 0);
        if (total > 0 && searchBlade) {
            searchBlade.classList.add('has-results');
        } else if (searchBlade) {
            searchBlade.classList.remove('has-results');
        }

        this.renderSearchResults(query);
    },

    highlightText(text, query) {
        if (!query || !text) return text;
        const regex = new RegExp(`(${query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi');
        return text.replace(regex, '<span class="premium-highlight">$1</span>');
    },

    _renderFlightRow(entry, idx, query) {
        const f = entry.feature;
        const p = f.properties || {};
        const acData = (typeof p.aircraft === 'string') ? (() => { try { return JSON.parse(p.aircraft); } catch { return {}; } })() : (p.aircraft || {});
        const acName = acData.aircraftName || p.aircraftName || '---';
        const lat = f.geometry?.coordinates?.[1];
        const lon = f.geometry?.coordinates?.[0];
        return `
            <div class="premium-result-item ${this._searchCursorIndex === idx ? 'selected' : ''}"
                 data-index="${idx}"
                 onclick="LandingUI.executeSearchClick('${p.flightId}', ${lat}, ${lon})">
                <div class="res-meta-icon"><i class="fa-solid fa-circle"></i></div>
                <div class="res-info-main">
                    <div class="res-primary-row">
                        <span class="res-callsign">${this.highlightText(p.callsign || 'N/A', query)}</span>
                        <span class="res-pill">${this.highlightText(acName, query)}</span>
                    </div>
                    <div class="res-secondary-row">
                        <span class="res-pilot">${this.highlightText(p.username || 'Anonymous', query)}</span>
                    </div>
                </div>
                <div class="res-stats">
                    <span class="res-altitude">${Math.round(p.altitude || 0).toLocaleString()}<span>ft</span></span>
                </div>
            </div>
        `;
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

        const r = this._currentResults || { flights: [], airports: [], airlines: [] };
        const total = (r.flights?.length || 0) + (r.airports?.length || 0) + (r.airlines?.length || 0);

        if (total === 0) {
            container.innerHTML = `<div class="premium-empty-state"><p>No matches found</p></div>`;
        } else {
            container.innerHTML = [
                this._renderSection('Live flights', (r.flights || []).map((e, i) => this._renderFlightRow(e, i, query))),
                this._renderSection('Airports', (r.airports || []).map(e => this._renderAirportRow(e, query))),
                this._renderSection('Airlines', (r.airlines || []).map(e => this._renderAirlineRow(e, query))),
            ].join('');
        }
        container.classList.add('visible');
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
        this._currentResults = { flights: [], airports: [], airlines: [] };
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
                            <input type="text" id="blade-search-input" placeholder="Search flights, airports, airlines"
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
                toggleModal(true);
            }
        });

        settingsBtn?.addEventListener('click', () => {
            window.dispatchEvent(new CustomEvent('openSettings'));
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