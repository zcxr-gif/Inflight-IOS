/**
 * CareerModule — Advanced Aviation Telemetry & Analytics Dashboard
 * Premium Redesign: Aligned with the glassmorphic Command Dossier architecture.
 */

/**
 * A single touchdown captured during a flight.
 * @typedef {Object} LandingStat
 * @property {string} timestamp              - ISO 8601 (with Z) of the touchdown.
 * @property {number} maxGForce              - Peak vertical G at touchdown.
 * @property {number} groundSpeed            - Ground speed at touchdown (knots).
 * @property {number} indicatedAirspeed      - Indicated airspeed at touchdown (knots).
 * @property {number} latitude
 * @property {number} longitude
 * @property {number} centerlineDistance     - Lateral offset from runway centerline (meters).
 * @property {number} verticalSpeed          - Touchdown vertical speed (fpm; negative = descending).
 * @property {number} distanceFrom1kftMarker - Distance from the 1,000 ft markers (meters).
 * @property {number} groundRollDistance     - Ground roll after touchdown (meters).
 * @property {number} timeSinceLastLanding   - Seconds since the previous landing.
 */

/**
 * A historical flight record returned by /api/users/{userId}/flights.
 * NOTE: In this codebase totalTime/dayTime/nightTime are handled as MINUTES
 * (see formatMinutes / calculateRatePerHour) to match the existing logbook feed.
 * @typedef {Object} Flight
 * @property {string} id
 * @property {string} created                - ISO 8601, no tz suffix (treat as UTC).
 * @property {string} userId
 * @property {string} aircraftId
 * @property {string} liveryId
 * @property {string} callsign
 * @property {string} server
 * @property {number} dayTime
 * @property {number} nightTime
 * @property {number} totalTime
 * @property {number} landingCount
 * @property {?string} originAirport         - ICAO, may be null/empty.
 * @property {?string} destinationAirport    - ICAO, may be null/empty.
 * @property {number} xp
 * @property {number} fuelUsedKg             - Total fuel burned (kg).
 * @property {LandingStat[]} landingStats    - Per-touchdown telemetry (may be []).
 */

export const CareerModule = {
    // Core State
    _atcData: null,
    _flightData: null,
    _loadingData: false,
    _error: null,
    _injectedStyles: false,
    _activeSubTab: 'overview',
    _navListenerAttached: false,
    _reRenderCallback: null,

    // API Context
    _userId: null,
    _backendUrl: null,

    // Pagination State
    _flightPage: 1,
    _flightTotalPages: 1,
    _loadingMoreFlights: false,
    
    _atcPage: 1,
    _atcTotalPages: 1,
    _loadingMoreATC: false,

    // Tracks which flight cards have their landing-detail panel expanded
    _expandedFlights: new Set(),

    // Metadata caches
    _aircraftMap: new Map(),
    _liveryMap: new Map(),

    // API Enum Mappings
    _frequencyMap: {
        0: "Ground", 1: "Tower", 2: "Unicom", 3: "Clearance", 
        4: "Approach", 5: "Departure", 6: "Center", 7: "ATIS", 
        8: "Aircraft", 9: "Recorded", 10: "Unknown", 11: "Unused"
    },

    _worldTypeMap: {
        0: "Solo", 1: "Casual", 2: "Training", 3: "Expert", 4: "Private"
    },

    formatMinutes(minutes) {
        if (!minutes || minutes <= 0) return "0h 0m";
        const h = Math.floor(minutes / 60);
        const m = Math.floor(minutes % 60);
        return `${h}h ${m}m`;
    },

    calculateRatePerHour(value, minutes) {
        if (!minutes || minutes <= 0 || !value) return "0.0";
        return ((value / minutes) * 60).toFixed(1);
    },

    /**
     * Format a fuel-burn figure (kg) for display, rolling up to tonnes when large.
     * @param {number} kg
     * @returns {string}
     */
    formatFuel(kg) {
        if (kg == null || isNaN(kg) || kg <= 0) return "—";
        if (kg >= 1000) return `${(kg / 1000).toFixed(1)}t`;
        return `${Math.round(kg).toLocaleString()} kg`;
    },

    /**
     * Classify a touchdown by its vertical speed (fpm) into a quality band.
     * @param {number} verticalSpeed - Negative = descending.
     * @returns {{label: string, class: string}}
     */
    rateLanding(verticalSpeed) {
        const v = Math.abs(Number(verticalSpeed) || 0);
        if (v <= 100) return { label: "Butter", class: "land-butter" };
        if (v <= 250) return { label: "Smooth", class: "land-smooth" };
        if (v <= 500) return { label: "Firm", class: "land-firm" };
        return { label: "Hard", class: "land-hard" };
    },

    /**
     * Reduce a flight's landingStats into a card-level summary.
     * @param {LandingStat[]} landingStats
     * @returns {{count: number, best: LandingStat}|null}
     */
    summarizeLandings(landingStats) {
        if (!Array.isArray(landingStats) || landingStats.length === 0) return null;
        // "Best" landing = smoothest touchdown (smallest absolute vertical speed).
        let best = landingStats[0];
        for (const ls of landingStats) {
            if (Math.abs(ls.verticalSpeed || 0) < Math.abs(best.verticalSpeed || 0)) best = ls;
        }
        return { count: landingStats.length, best };
    },

    async loadExtraData(userId, backendUrl, reRenderCallback) {
        if (!userId) {
            this._error = "System Error: Missing telemetry authorization token.";
            if (reRenderCallback) reRenderCallback();
            return;
        }
        
        if ((this._atcData && this._flightData) || this._loadingData) return;
        
        this._userId = userId;
        this._backendUrl = backendUrl;
        this._loadingData = true;
        this._flightPage = 1;
        this._atcPage = 1;
        if (reRenderCallback) reRenderCallback();

        try {
            // Fetch ATC, Flights (Page 1), and System Metadata in parallel
            const [atcRes, flightsRes, metaRes] = await Promise.all([
                fetch(`${backendUrl}/api/users/${userId}/atc?page=1`),
                fetch(`${backendUrl}/api/users/${userId}/flights?page=1`),
                fetch(`${backendUrl}/api/metadata`).catch(() => null)
            ]);

            if (!atcRes.ok || !flightsRes.ok) {
                this._error = `Telemetry Node Offline - ATC: ${atcRes.status} | FLT: ${flightsRes.status}`;
                this._atcData = [];
                this._flightData = [];
                return;
            }

            const atcJson = await atcRes.json();
            const flightsJson = await flightsRes.json();


            // Process Metadata if available to translate UUIDs to Aircraft/Livery names
            if (metaRes && metaRes.ok) {
                const metaJson = await metaRes.json();
                if (metaJson.ok) {
                    this._aircraftMap = new Map((metaJson.aircraft || []).map(a => [String(a.id).toLowerCase(), a.name]));
                    
                    // FIX: Store BOTH the Livery Name AND the Aircraft Name inside the livery map
                    this._liveryMap = new Map((metaJson.liveries || []).map(l => [
                        String(l.id).toLowerCase(), 
                        { liveryName: l.name, aircraftName: l.aircraftName }
                    ]));
                }
            }

            if (atcJson.ok && flightsJson.ok) {
                this._atcData = Array.isArray(atcJson.data) ? atcJson.data : [];
                this._atcTotalPages = atcJson.totalPages || 1;

                this._flightData = Array.isArray(flightsJson.flights) ? flightsJson.flights : [];
                this._flightTotalPages = flightsJson.totalPages || 1;

                this._error = null;
            } else {
                const atcErr = atcJson.error?.message || "Unknown ATC Fault";
                const flightErr = flightsJson.error?.message || "Unknown FLT Fault";
                this._error = `API Rejection - ATC: ${atcErr} | FLT: ${flightErr}`;
                this._atcData = [];
                this._flightData = [];
            }
        } catch (err) {
            this._error = "Critical network failure retrieving historical telemetry.";
            console.error("Dossier Fetch Error:", err);
        } finally {
            this._loadingData = false;
            if (this._reRenderCallback) this._reRenderCallback();
        }
    },

    async loadMoreFlights() {
        if (!this._userId || !this._backendUrl || this._loadingMoreFlights || this._flightPage >= this._flightTotalPages) return;
        
        this._loadingMoreFlights = true;
        this._flightPage++;
        if (this._reRenderCallback) this._reRenderCallback(); // Trigger UI to show loading state

        try {
            const res = await fetch(`${this._backendUrl}/api/users/${this._userId}/flights?page=${this._flightPage}`);
            if (res.ok) {
                const json = await res.json();
                if (json.ok && Array.isArray(json.flights)) {
                    // Append new records to the existing array
                    this._flightData = [...this._flightData, ...json.flights];
                    this._flightTotalPages = json.totalPages || this._flightTotalPages;
                }
            }
        } catch (err) {
            console.error("Failed to fetch more flights:", err);
            this._flightPage--; // Revert page counter on network failure
        } finally {
            this._loadingMoreFlights = false;
            if (this._reRenderCallback) this._reRenderCallback();
        }
    },

    async loadMoreATC() {
        if (!this._userId || !this._backendUrl || this._loadingMoreATC || this._atcPage >= this._atcTotalPages) return;
        
        this._loadingMoreATC = true;
        this._atcPage++;
        if (this._reRenderCallback) this._reRenderCallback(); // Trigger UI to show loading state

        try {
            const res = await fetch(`${this._backendUrl}/api/users/${this._userId}/atc?page=${this._atcPage}`);
            if (res.ok) {
                const json = await res.json();
                if (json.ok && Array.isArray(json.data)) {
                    // Append new records to the existing array
                    this._atcData = [...this._atcData, ...json.data];
                    this._atcTotalPages = json.totalPages || this._atcTotalPages;
                }
            }
        } catch (err) {
            console.error("Failed to fetch more ATC sessions:", err);
            this._atcPage--; // Revert page counter on network failure
        } finally {
            this._loadingMoreATC = false;
            if (this._reRenderCallback) this._reRenderCallback();
        }
    },

    getHTML(ifData) {
        if (!this._injectedStyles) {
            this._injectStyles();
            this._injectedStyles = true;
        }

        if (ifData.loading) {
            return `
                <div class="cm-skeleton-container pui-fade-in">
                    <div class="pui-skeleton" style="height: 60px; border-radius: 12px; margin-bottom: 24px;"></div>
                    <div class="pui-skeleton" style="height: 300px; border-radius: 16px;"></div>
                </div>`;
        }

        if (!ifData.stats) {
            return `
                <div class="pui-alert pui-alert-error pui-fade-in" style="flex-direction: column; align-items: center; padding: 32px;">
                    <i class="fa-solid fa-satellite-dish" style="font-size: 2rem; opacity: 0.5; margin-bottom: 12px;"></i>
                    <span style="font-weight: 600;">Telemetry Unavailable</span>
                    <span style="font-size: 0.85rem; opacity: 0.8;">Unable to parse extended logbook data.</span>
                </div>
            `;
        }

        const navHTML = `
            <div class="cm-segmented-control pui-fade-in">
                <button type="button" class="cm-segment-btn ${this._activeSubTab === 'overview' ? 'active' : ''}" data-tab="overview">
                    <i class="fa-solid fa-id-card-clip"></i> Identity
                </button>
                <button type="button" class="cm-segment-btn ${this._activeSubTab === 'flights' ? 'active' : ''}" data-tab="flights">
                    <i class="fa-solid fa-plane-departure"></i> Logs
                </button>
                <button type="button" class="cm-segment-btn ${this._activeSubTab === 'atc' ? 'active' : ''}" data-tab="atc">
                    <i class="fa-solid fa-tower-control"></i> ATC
                </button>
                <button type="button" class="cm-segment-btn ${this._activeSubTab === 'enforcement' ? 'active' : ''}" data-tab="enforcement">
                    <i class="fa-solid fa-shield-halved"></i> Enforcement
                </button>
            </div>
        `;

        let activeTabHTML = '';
        switch (this._activeSubTab) {
            case 'overview': activeTabHTML = this._renderOverview(ifData.stats); break;
            case 'enforcement': activeTabHTML = this._renderEnforcement(ifData.stats); break;
            case 'flights': activeTabHTML = this._renderFlights(); break;
            case 'atc': activeTabHTML = this._renderATC(); break;
            default: activeTabHTML = this._renderOverview(ifData.stats);
        }

        return `
            <div class="cm-module-wrapper">
                ${navHTML}
                <div class="cm-tab-viewport">
                    ${activeTabHTML}
                </div>
            </div>
        `;
    },

    _renderOverview(stats) {
        const vaName = stats.virtualOrganization || 'Independent Operator';
        const discourse = stats.discourseUsername ? `@${stats.discourseUsername}` : 'UNLINKED';
        const groups = Array.isArray(stats.groups) && stats.groups.length > 0 ? stats.groups : ['No active community groups'];
        const roles = Array.isArray(stats.roles) && stats.roles.length > 0 ? stats.roles : ['Standard Operator'];
        
        const atcRankStr = stats.atcRank !== null ? `Rank ${stats.atcRank}` : 'Unranked';
        const onlineRatio = stats.landingCount > 0 ? ((stats.onlineFlights / stats.landingCount) * 100).toFixed(1) : 0;

        return `
            <div class="cm-grid-layout pui-fade-in">
                <div class="pui-card cm-premium-card">
                    <div class="pui-card-header cm-card-header-accent">
                        <h3><i class="fa-solid fa-passport"></i> Operational Identity</h3>
                    </div>
                    <div class="pui-card-body cm-identity-body">
                        <div class="cm-id-row">
                            <span class="cm-id-label">Virtual Organization</span>
                            <span class="cm-id-value cm-highlight-va">${vaName}</span>
                        </div>
                        <div class="cm-id-row">
                            <span class="cm-id-label">IFC Handle</span>
                            <span class="cm-id-value">${discourse}</span>
                        </div>
                        <div class="cm-id-row">
                            <span class="cm-id-label">ATC Clearances</span>
                            <span class="cm-id-value">${atcRankStr} | ${(stats.atcOperations || 0).toLocaleString()} Ops</span>
                        </div>
                        <div class="cm-id-row" style="border-bottom: none;">
                            <span class="cm-id-label">Network Presence</span>
                            <span class="cm-id-value">${stats.onlineFlights || 0} Flights (${onlineRatio}% Online)</span>
                        </div>
                    </div>
                </div>

                <div class="pui-card cm-premium-card">
                    <div class="pui-card-header cm-card-header-accent">
                        <h3><i class="fa-solid fa-key"></i> Clearance & Roles</h3>
                    </div>
                    <div class="pui-card-body">
                        <div class="cm-tag-section">
                            <label>System Roles</label>
                            <div class="cm-tag-cloud">
                                ${roles.map(r => `<span class="cm-system-tag role-tag"><i class="fa-solid fa-user-shield"></i> ${r}</span>`).join('')}
                            </div>
                        </div>
                        <div class="cm-tag-section" style="margin-top: 20px;">
                            <label>Group UUIDs</label>
                            <div class="cm-tag-cloud">
                                ${groups.map(g => `<span class="cm-system-tag group-tag" title="${g}">${g.includes('-') ? g.split('-')[0] : g}</span>`).join('')}
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    },

    _renderEnforcement(stats) {
        const vios = stats.violationCountByLevel || {};
        const total12Mo = stats.total12MonthsViolations || 0;
        
        const getVioStatus = (count, threshold) => {
            if (count === 0) return { class: 'status-clean', icon: 'fa-check-circle', text: 'CLEAN' };
            if (count < threshold) return { class: 'status-warn', icon: 'fa-triangle-exclamation', text: 'WARNING' };
            return { class: 'status-danger', icon: 'fa-circle-xmark', text: 'CRITICAL' };
        };

        const l1Stat = getVioStatus(vios.level1 || 0, 3);
        const l2Stat = getVioStatus(vios.level2 || 0, 1);
        const l3Stat = getVioStatus(vios.level3 || 0, 1);

        const formatDate = (dateString) => {
            if (!dateString || dateString.startsWith("0001-01-01")) return 'No Record';
            return new Date(dateString).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
        };

        return `
            <div class="pui-card cm-premium-card pui-fade-in">
                <div class="cm-enforcement-header">
                    <div class="cm-eh-left">
                        <h3><i class="fa-solid fa-scale-balanced"></i> Enforcement Matrix</h3>
                        <p>Real-time infractions and account standing.</p>
                    </div>
                    <div class="cm-eh-right">
                        <div class="cm-12mo-badge ${total12Mo > 0 ? 'active-vios' : 'clean-vios'}">
                            <span class="lbl">12-MO Rolling</span>
                            <span class="val">${total12Mo}</span>
                        </div>
                    </div>
                </div>
                
                <div class="cm-severity-grid">
                    <div class="cm-severity-block ${l1Stat.class}">
                        <div class="cm-sb-top">
                            <span class="cm-sb-level">Level 1 <span>(System)</span></span>
                            <i class="fa-solid ${l1Stat.icon}"></i>
                        </div>
                        <div class="cm-sb-center">${vios.level1 || 0}</div>
                        <div class="cm-sb-bottom">Last: ${formatDate(stats.lastLevel1ViolationDate)}</div>
                    </div>
                    
                    <div class="cm-severity-block ${l2Stat.class}">
                        <div class="cm-sb-top">
                            <span class="cm-sb-level">Level 2 <span>(Report)</span></span>
                            <i class="fa-solid ${l2Stat.icon}"></i>
                        </div>
                        <div class="cm-sb-center">${vios.level2 || 0}</div>
                        <div class="cm-sb-bottom">Last: ${formatDate(stats.lastLevel2ViolationDate)}</div>
                    </div>
                    
                    <div class="cm-severity-block ${l3Stat.class}">
                        <div class="cm-sb-top">
                            <span class="cm-sb-level">Level 3 <span>(Ghost)</span></span>
                            <i class="fa-solid ${l3Stat.icon}"></i>
                        </div>
                        <div class="cm-sb-center">${vios.level3 || 0}</div>
                        <div class="cm-sb-bottom">Last: ${formatDate(stats.lastLevel3ViolationDate)}</div>
                    </div>
                </div>
            </div>
        `;
    },

 _renderFlights() {
        if (this._loadingData) return `<div class="pui-skeleton" style="height: 400px; border-radius: 16px;"></div>`;
        if (this._error) return `<div class="pui-alert pui-alert-error">${this._error}</div>`;
        if (!this._flightData || this._flightData.length === 0) return `<div class="cm-empty-state"><i class="fa-solid fa-wind"></i> No flight telemetry logged.</div>`;

        const flightRows = this._flightData.map((flight, index) => {
            const date = flight.created ? new Date(flight.created).toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute:'2-digit' }) : 'UNKNOWN';

            const origin = flight.originAirport || 'VFR';
            const dest = flight.destinationAirport || 'LOCAL';

            const totalTimeStr = this.formatMinutes(flight.totalTime);
            const serverName = flight.server || this._worldTypeMap[flight.worldType] || "UNKNOWN";
            const xpPerHour = this.calculateRatePerHour(flight.xp, flight.totalTime);
            const hasVios = flight.violations && flight.violations.length > 0;

            // NEW: fuel burn + per-touchdown landing telemetry
            const fuelStr = this.formatFuel(flight.fuelUsedKg);
            const landingStats = Array.isArray(flight.landingStats) ? flight.landingStats : [];
            const landingSummary = this.summarizeLandings(landingStats);
            const flightKey = flight.id || `flt-${index}`;
            const isExpanded = this._expandedFlights.has(flightKey);
            
            // Safely handle both lowercase 'd' and capital 'D' variations from the API
            const rawAircraftId = flight.aircraftID || flight.aircraftId;
            const targetAircraftId = rawAircraftId ? String(rawAircraftId).toLowerCase() : null;

            const rawLiveryId = flight.liveryID || flight.liveryId;
            const targetLiveryId = rawLiveryId ? String(rawLiveryId).toLowerCase() : null;

            // 1. Look up the livery data first
            const liveryData = targetLiveryId ? this._liveryMap.get(targetLiveryId) : null;

            // 2. Resolve Aircraft Name: Check direct aircraft ID first, then fallback to Livery's embedded aircraft name
            let aircraftName = 'Unknown Airframe';
            if (targetAircraftId && this._aircraftMap.has(targetAircraftId)) {
                aircraftName = this._aircraftMap.get(targetAircraftId);
            } else if (liveryData && liveryData.aircraftName) {
                aircraftName = liveryData.aircraftName;
            }

            // 3. Resolve Livery Name
            const liveryName = liveryData ? liveryData.liveryName : '';

            let vioBadge = hasVios
                ? `<div class="cm-log-vio-badge" title="${flight.violations.length} Violation(s) Issued"><i class="fa-solid fa-triangle-exclamation"></i> Lvl ${flight.violations[0].level}</div>`
                : '';

            const fuelStatHTML = fuelStr !== '—'
                ? `<div class="cm-fc-stat-item" title="Total fuel burned">
                        <span class="lbl">FUEL</span>
                        <span class="val">${fuelStr}</span>
                    </div>`
                : '';

            // NEW: expandable landing-detail block (only when touchdown telemetry exists)
            let landingBlockHTML = '';
            if (landingSummary) {
                const bestRate = this.rateLanding(landingSummary.best.verticalSpeed);
                const bestVs = Math.round(landingSummary.best.verticalSpeed || 0);
                const plural = landingSummary.count === 1 ? '' : 's';

                const landingRows = landingStats.map((ls, i) => {
                    const rate = this.rateLanding(ls.verticalSpeed);
                    const tdTime = ls.timestamp
                        ? new Date(ls.timestamp).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
                        : '';
                    return `
                        <div class="cm-landing-row">
                            <div class="cm-lr-head">
                                <span class="cm-lr-idx">#${i + 1}</span>
                                <span class="cm-lr-rate ${rate.class}">${rate.label}</span>
                                ${tdTime ? `<span class="cm-lr-time">${tdTime}</span>` : ''}
                            </div>
                            <div class="cm-lr-metrics">
                                <span><b>${Math.round(ls.verticalSpeed || 0)}</b> fpm</span>
                                <span><b>${(Number(ls.maxGForce) || 0).toFixed(2)}</b> G</span>
                                <span><b>${Math.round(ls.groundSpeed || 0)}</b> kt GS</span>
                                <span><b>${Math.round(ls.centerlineDistance || 0)}</b> m CL</span>
                                <span><b>${Math.round(ls.groundRollDistance || 0)}</b> m roll</span>
                            </div>
                        </div>`;
                }).join('');

                landingBlockHTML = `
                    <button type="button" class="cm-landing-toggle ${isExpanded ? 'open' : ''}" data-action="toggle-landings" data-flight="${flightKey}">
                        <span class="cm-lt-summary">
                            <i class="fa-solid fa-plane-arrival"></i>
                            ${landingSummary.count} Landing${plural}
                            <span class="cm-lt-best">· Best <b class="${bestRate.class}">${bestRate.label}</b> (${bestVs} fpm)</span>
                        </span>
                        <i class="fa-solid fa-chevron-down cm-lt-chevron"></i>
                    </button>
                    <div class="cm-landing-detail ${isExpanded ? 'open' : ''}">
                        ${landingRows}
                    </div>`;
            }

            return `
                <div class="cm-flight-entry">
                    <div class="cm-flight-card ${hasVios ? 'card-has-vio' : ''} ${landingBlockHTML ? 'has-landings' : ''}">
                        <div class="cm-fc-context">
                            <div class="cm-fc-date">${date}</div>
                            <div class="cm-fc-acft">
                                <span class="cm-fc-acft-name">${aircraftName}</span>
                                ${liveryName ? `<span class="cm-fc-livery">${liveryName}</span>` : ''}
                            </div>
                            <div class="cm-fc-server">${serverName}</div>
                        </div>

                        <div class="cm-fc-route">
                            <div class="cm-fc-apt">${origin}</div>
                            <div class="cm-fc-path">
                                <div class="cm-fc-line"></div>
                                <i class="fa-solid fa-plane cm-fc-plane-icon"></i>
                            </div>
                            <div class="cm-fc-apt">${dest}</div>
                        </div>

                        <div class="cm-fc-telemetry">
                            <div class="cm-fc-stat-item">
                                <span class="lbl">DURATION</span>
                                <span class="val">${totalTimeStr}</span>
                            </div>
                            <div class="cm-fc-stat-item">
                                <span class="lbl">EFFICIENCY</span>
                                <span class="val">${xpPerHour} <small>XP/h</small></span>
                            </div>
                            ${fuelStatHTML}
                        </div>
                        ${vioBadge}
                    </div>
                    ${landingBlockHTML}
                </div>
            `;
        }).join('');

        let loadMoreHTML = '';
        if (this._flightPage < this._flightTotalPages) {
            loadMoreHTML = `
                <div class="cm-load-more-container">
                    <button type="button" class="cm-load-more-btn ${this._loadingMoreFlights ? 'cm-btn-loading' : ''}" data-action="load-more-flights">
                        ${this._loadingMoreFlights ? '<i class="fa-solid fa-circle-notch fa-spin"></i> Retrieving Telemetry...' : '<i class="fa-solid fa-angles-down"></i> Load Older Logs'}
                    </button>
                </div>
            `;
        }

        return `
            <div class="pui-card cm-premium-card pui-fade-in">
                <div class="cm-data-list-header">
                    <h3>Flight Telemetry</h3>
                    <span class="cm-meta-count">Showing ${this._flightData.length} logs</span>
                </div>
                <div class="cm-data-list-viewport">
                    ${flightRows}
                    ${loadMoreHTML}
                </div>
            </div>
        `;
    },

    _renderATC() {
        if (this._loadingData) return `<div class="pui-skeleton" style="height: 400px; border-radius: 16px;"></div>`;
        if (this._error) return `<div class="pui-alert pui-alert-error">${this._error}</div>`;
        if (!this._atcData || this._atcData.length === 0) return `<div class="cm-empty-state"><i class="fa-solid fa-headset"></i> No ATC operations logged.</div>`;

        const atcRows = this._atcData.map(session => {
            const date = session.created ? new Date(session.created).toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute:'2-digit' }) : 'UNKNOWN';
            const facilityName = session.facility ? session.facility.airportIcao : "UNKN";
            const freqTypeInt = session.facility ? session.facility.frequencyType : 10;
            const freqType = this._frequencyMap[freqTypeInt] || "UNK";
            
            const totalTimeStr = this.formatMinutes(session.totalTime);
            const serverName = session.server || this._worldTypeMap[session.worldType] || "UNKNOWN";
            
            const viosIssued = session.violationsIssued || 0;
            const workloadIndex = this.calculateRatePerHour(session.operations, session.totalTime);

            let enforceBadge = viosIssued > 0 
                ? `<div class="cm-log-vio-badge enforce-badge" title="${viosIssued} Violation(s) Issued"><i class="fa-solid fa-gavel"></i> ${viosIssued} Iss</div>` 
                : '';

            return `
                <div class="cm-flight-card ${viosIssued > 0 ? 'card-has-enforce' : ''}">
                    <div class="cm-fc-context">
                        <div class="cm-fc-date">${date}</div>
                        <div class="cm-fc-acft">
                            <span class="cm-fc-acft-name">Controller Console</span>
                        </div>
                        <div class="cm-fc-server">${serverName}</div>
                    </div>

                    <div class="cm-fc-route">
                         <div class="cm-fc-apt">${facilityName}</div>
                         <div class="cm-fc-path">
                            <div class="cm-fc-line cm-atc-line"></div>
                            <span class="cm-freq-pill">${freqType}</span>
                        </div>
                    </div>

                    <div class="cm-fc-telemetry">
                        <div class="cm-fc-stat-item">
                            <span class="lbl">ONLINE</span>
                            <span class="val">${totalTimeStr}</span>
                        </div>
                        <div class="cm-fc-stat-item" title="Operations Per Hour">
                            <span class="lbl">WORKLOAD</span>
                            <span class="val">${workloadIndex} <small>OPH</small></span>
                        </div>
                    </div>
                    ${enforceBadge}
                </div>
            `;
        }).join('');

        let loadMoreHTML = '';
        if (this._atcPage < this._atcTotalPages) {
            loadMoreHTML = `
                <div class="cm-load-more-container">
                    <button type="button" class="cm-load-more-btn ${this._loadingMoreATC ? 'cm-btn-loading' : ''}" data-action="load-more-atc">
                        ${this._loadingMoreATC ? '<i class="fa-solid fa-circle-notch fa-spin"></i> Retrieving Telemetry...' : '<i class="fa-solid fa-angles-down"></i> Load Older Sessions'}
                    </button>
                </div>
            `;
        }

        return `
            <div class="pui-card cm-premium-card pui-fade-in">
                <div class="cm-data-list-header">
                    <h3>ATC Sessions</h3>
                    <span class="cm-meta-count">Showing ${this._atcData.length} logs</span>
                </div>
                <div class="cm-data-list-viewport">
                    ${atcRows}
                    ${loadMoreHTML}
                </div>
            </div>
        `;
    },

    attachListeners(ifData, backendUrl, reRenderCallback) {
        this._reRenderCallback = reRenderCallback;

        // Fetch data if we don't have it
        if (ifData && ifData.userId && !this._atcData && !this._flightData && !this._loadingData) {
            this.loadExtraData(ifData.userId, backendUrl, reRenderCallback);
        }

        // Advanced Event Delegation: Using CAPTURE phase to bypass modal propagation blocks
        if (!this._navListenerAttached) {
            document.addEventListener('click', (e) => {
                // Tab Navigation
                const targetBtn = e.target.closest('.cm-segment-btn');
                if (targetBtn) {
                    e.preventDefault(); 
                    e.stopPropagation(); 
                    const tab = targetBtn.getAttribute('data-tab');
                    if (this._activeSubTab !== tab) {
                        this._activeSubTab = tab;
                        if (this._reRenderCallback) this._reRenderCallback();
                    }
                    return;
                }

                // Load More Flights
                const loadFlightsBtn = e.target.closest('[data-action="load-more-flights"]');
                if (loadFlightsBtn) {
                    e.preventDefault();
                    e.stopPropagation();
                    this.loadMoreFlights();
                    return;
                }

                // Load More ATC
                const loadAtcBtn = e.target.closest('[data-action="load-more-atc"]');
                if (loadAtcBtn) {
                    e.preventDefault();
                    e.stopPropagation();
                    this.loadMoreATC();
                    return;
                }

                // Toggle per-flight landing detail panel
                const landingToggle = e.target.closest('[data-action="toggle-landings"]');
                if (landingToggle) {
                    e.preventDefault();
                    e.stopPropagation();
                    const key = landingToggle.getAttribute('data-flight');
                    if (key) {
                        if (this._expandedFlights.has(key)) this._expandedFlights.delete(key);
                        else this._expandedFlights.add(key);
                        if (this._reRenderCallback) this._reRenderCallback();
                    }
                    return;
                }

            }, true); 
            
            this._navListenerAttached = true;
        }
    },

    _injectStyles() {
        if (document.getElementById('cm-dossier-styles')) return;
        const css = `
            /* ═══════════════════════════════════════════════════════════════
               CAREER MODULE - DOSSIER UNIFICATION STYLES
               ═══════════════════════════════════════════════════════════════ */
            
            .cm-module-wrapper {
                display: flex;
                flex-direction: column;
                gap: 16px;
                width: 100%;
            }

            /* Segmented Control Navigation */
            .cm-segmented-control {
                display: flex;
                background: rgba(0, 0, 0, 0.05);
                padding: 6px;
                border-radius: 14px;
                gap: 6px;
                border: 1px solid var(--pui-border-light);
                overflow-x: auto;
            }
            .pui-wrapper-layer[data-theme="dark-gray"] .cm-segmented-control,
            .pui-wrapper-layer[data-theme="dark"] .cm-segmented-control {
                background: rgba(0, 0, 0, 0.2);
            }
            .cm-segment-btn {
                flex: 1;
                min-width: 110px;
                background: transparent;
                border: none;
                padding: 10px 16px;
                border-radius: 10px;
                font-family: var(--pui-font-mono);
                font-size: 0.8rem;
                font-weight: 600;
                color: var(--pui-text-secondary);
                cursor: pointer;
                transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
            }
            .cm-segment-btn:hover {
                color: var(--pui-text-primary);
                background: rgba(255, 255, 255, 0.05);
            }
            .cm-segment-btn.active {
                background: var(--pui-bg-surface);
                color: var(--pui-accent);
                box-shadow: 0 2px 8px rgba(0,0,0,0.05);
                border: 1px solid var(--pui-border);
            }
            .pui-wrapper-layer[data-theme="dark-gray"] .cm-segment-btn.active,
            .pui-wrapper-layer[data-theme="dark"] .cm-segment-btn.active {
                background: rgba(255,255,255,0.08);
                border-color: rgba(255,255,255,0.1);
            }

            /* Premium Card Overrides */
            .cm-premium-card {
                background: var(--pui-bg-surface);
                border-radius: 16px;
                overflow: hidden;
                margin-bottom: 0;
            }
            .cm-card-header-accent {
                border-bottom: 1px solid var(--pui-border-light);
                padding: 16px 20px;
            }
            .cm-card-header-accent h3 {
                font-size: 0.95rem;
                letter-spacing: 0.02em;
            }
            .cm-grid-layout {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
                gap: 16px;
            }

            /* Identity Rows */
            .cm-identity-body {
                padding: 0;
                display: flex;
                flex-direction: column;
            }
            .cm-id-row {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 16px 20px;
                border-bottom: 1px solid var(--pui-border-light);
            }
            .cm-id-label {
                font-size: 0.75rem;
                color: var(--pui-text-secondary);
                text-transform: uppercase;
                letter-spacing: 0.05em;
                font-weight: 700;
            }
            .cm-id-value {
                font-family: var(--pui-font-mono);
                font-size: 0.9rem;
                font-weight: 600;
                color: var(--pui-text-primary);
                text-align: right;
            }
            .cm-highlight-va {
                color: var(--pui-accent);
                background: rgba(var(--pui-accent-rgb, 139, 92, 246), 0.1);
                padding: 4px 10px;
                border-radius: 6px;
            }

            /* Tag Clouds */
            .cm-tag-section label {
                display: block;
                font-size: 0.75rem;
                color: var(--pui-text-secondary);
                text-transform: uppercase;
                letter-spacing: 0.05em;
                font-weight: 700;
                margin-bottom: 8px;
            }
            .cm-tag-cloud {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
            }
            .cm-system-tag {
                font-family: var(--pui-font-mono);
                font-size: 0.75rem;
                padding: 6px 12px;
                border-radius: 8px;
                font-weight: 600;
                border: 1px solid transparent;
            }
            .role-tag {
                background: rgba(16, 185, 129, 0.1);
                color: #10b981;
                border-color: rgba(16, 185, 129, 0.2);
            }
            .group-tag {
                background: var(--pui-hover);
                color: var(--pui-text-primary);
                border-color: var(--pui-border);
            }

            /* Enforcement Matrix */
            .cm-enforcement-header {
                display: flex;
                justify-content: space-between;
                align-items: flex-start;
                padding: 20px;
                border-bottom: 1px solid var(--pui-border-light);
            }
            .cm-eh-left h3 { margin-bottom: 4px; }
            .cm-eh-left p { font-size: 0.8rem; color: var(--pui-text-secondary); margin: 0; }
            .cm-12mo-badge {
                display: flex;
                flex-direction: column;
                align-items: flex-end;
                background: var(--pui-hover);
                padding: 8px 12px;
                border-radius: 8px;
                border: 1px solid var(--pui-border-light);
            }
            .cm-12mo-badge.active-vios { border-color: var(--pui-neg); background: rgba(239, 68, 68, 0.05); }
            .cm-12mo-badge .lbl { font-size: 0.65rem; text-transform: uppercase; font-weight: 700; color: var(--pui-text-secondary); }
            .cm-12mo-badge .val { font-family: var(--pui-font-mono); font-size: 1.2rem; font-weight: 700; line-height: 1; }
            .active-vios .val { color: var(--pui-neg); }

            .cm-severity-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                gap: 16px;
                padding: 20px;
            }
            .cm-severity-block {
                display: flex;
                flex-direction: column;
                padding: 16px;
                border-radius: 12px;
                border: 1px solid var(--pui-border-light);
                background: rgba(0,0,0,0.02);
                position: relative;
                overflow: hidden;
            }
            .pui-wrapper-layer[data-theme="dark-gray"] .cm-severity-block { background: rgba(255,255,255,0.02); }
            
            .cm-sb-top { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
            .cm-sb-level { font-size: 0.8rem; font-weight: 700; color: var(--pui-text-primary); }
            .cm-sb-level span { font-weight: 400; color: var(--pui-text-secondary); font-size: 0.7rem; }
            .cm-sb-center { font-family: var(--pui-font-mono); font-size: 2.5rem; font-weight: 700; line-height: 1; margin-bottom: 12px; }
            .cm-sb-bottom { font-family: var(--pui-font-mono); font-size: 0.7rem; color: var(--pui-text-secondary); opacity: 0.8; }

            /* Status Colors */
            .status-clean { border-top: 3px solid var(--pui-pos); }
            .status-clean .cm-sb-center, .status-clean i { color: var(--pui-pos); }
            .status-warn { border-top: 3px solid var(--pui-warn); background: rgba(245, 158, 11, 0.05); }
            .status-warn .cm-sb-center, .status-warn i { color: var(--pui-warn); }
            .status-danger { border-top: 3px solid var(--pui-neg); background: rgba(239, 68, 68, 0.05); }
            .status-danger .cm-sb-center, .status-danger i { color: var(--pui-neg); }

            /* Data Lists - Premium Grid Layouts */
            .cm-data-list-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 16px 20px;
                border-bottom: 1px solid var(--pui-border-light);
                background: var(--pui-bg-base);
            }
            .cm-meta-count { font-size: 0.75rem; color: var(--pui-text-tertiary); font-family: var(--pui-font-mono); }
            
            .cm-data-list-viewport {
                max-height: 700px;
                overflow-y: auto;
                display: flex;
                flex-direction: column;
                padding: 16px;
                gap: 12px;
                background: var(--pui-bg-base);
            }
            .cm-data-list-viewport::-webkit-scrollbar { width: 6px; }
            .cm-data-list-viewport::-webkit-scrollbar-track { background: transparent; }
            .cm-data-list-viewport::-webkit-scrollbar-thumb { background: var(--pui-border); border-radius: 4px; }

            /* Premium Flight / ATC Cards */
            .cm-flight-card {
                display: grid;
                grid-template-columns: minmax(140px, 1.5fr) minmax(180px, 2fr) minmax(140px, 1fr);
                gap: 16px;
                align-items: center;
                background: linear-gradient(145deg, rgba(0,0,0,0.03) 0%, rgba(0,0,0,0.01) 100%);
                border: 1px solid var(--pui-border-light);
                border-radius: 12px;
                padding: 16px 20px;
                transition: all 0.3s cubic-bezier(0.25, 0.8, 0.25, 1);
                position: relative;
            }
            .pui-wrapper-layer[data-theme="dark-gray"] .cm-flight-card,
            .pui-wrapper-layer[data-theme="dark"] .cm-flight-card {
                background: linear-gradient(145deg, rgba(255,255,255,0.04) 0%, rgba(255,255,255,0.01) 100%);
            }
            
            .cm-flight-card:hover {
                transform: translateY(-2px);
                box-shadow: 0 8px 24px rgba(0,0,0,0.08);
                border-color: var(--pui-border);
            }
            /* Keep cards anchored to their attached landing panel */
            .cm-flight-card.has-landings:hover { transform: none; }

            .card-has-vio { 
                border-left: 3px solid var(--pui-neg); 
                background: linear-gradient(90deg, rgba(239, 68, 68, 0.05) 0%, transparent 100%) !important; 
            }
            .card-has-enforce { 
                border-left: 3px solid var(--pui-warn); 
                background: linear-gradient(90deg, rgba(245, 158, 11, 0.05) 0%, transparent 100%) !important; 
            }

            /* Context Column */
            .cm-fc-context { display: flex; flex-direction: column; gap: 4px; }
            .cm-fc-date { font-family: var(--pui-font-mono); font-size: 0.75rem; color: var(--pui-text-tertiary); font-weight: 600; }
            .cm-fc-acft { display: flex; flex-direction: column; line-height: 1.2; }
            .cm-fc-acft-name { font-size: 0.95rem; font-weight: 700; color: var(--pui-text-primary); }
            .cm-fc-livery { font-size: 0.75rem; color: var(--pui-text-secondary); }
            .cm-fc-server { font-size: 0.7rem; font-family: var(--pui-font-mono); color: var(--pui-accent); margin-top: 4px; }

            /* Route Column (The Visual Center) */
            .cm-fc-route {
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 12px;
            }
            .cm-fc-apt {
                font-family: var(--pui-font-mono);
                font-size: 1.1rem;
                font-weight: 700;
                color: var(--pui-text-primary);
                background: var(--pui-hover);
                padding: 4px 8px;
                border-radius: 6px;
            }
            .cm-fc-path {
                flex: 1;
                display: flex;
                align-items: center;
                position: relative;
                max-width: 100px;
            }
            .cm-fc-line {
                flex: 1;
                height: 2px;
                background: repeating-linear-gradient(90deg, var(--pui-text-tertiary) 0, var(--pui-text-tertiary) 4px, transparent 4px, transparent 8px);
                opacity: 0.5;
            }
            .cm-atc-line { background: var(--pui-border); opacity: 1; }
            .cm-fc-plane-icon {
                color: var(--pui-text-secondary);
                margin-left: 8px;
                font-size: 0.9rem;
            }
            .cm-freq-pill {
                font-family: var(--pui-font-mono);
                font-size: 0.75rem;
                background: var(--pui-accent);
                color: #fff;
                padding: 2px 8px;
                border-radius: 12px;
                font-weight: 700;
                margin-left: 8px;
                white-space: nowrap;
            }

            /* Telemetry/Stats Column */
            .cm-fc-telemetry {
                display: flex;
                flex-direction: column;
                align-items: flex-end;
                gap: 8px;
            }
            .cm-fc-stat-item { display: flex; flex-direction: column; align-items: flex-end; }
            .cm-fc-stat-item .lbl { font-size: 0.6rem; font-weight: 700; color: var(--pui-text-tertiary); letter-spacing: 0.05em; }
            .cm-fc-stat-item .val { font-family: var(--pui-font-mono); font-size: 0.95rem; font-weight: 700; color: var(--pui-text-primary); }
            .cm-fc-stat-item small { font-size: 0.7rem; color: var(--pui-text-secondary); font-weight: 400; }

            /* Flight entry wrapper (card + expandable landing detail) */
            .cm-flight-entry {
                display: flex;
                flex-direction: column;
            }
            .cm-flight-entry .cm-flight-card.has-landings {
                border-bottom-left-radius: 0;
                border-bottom-right-radius: 0;
            }

            /* Landing detail toggle */
            .cm-landing-toggle {
                display: flex;
                align-items: center;
                justify-content: space-between;
                width: 100%;
                background: var(--pui-bg-base);
                border: 1px solid var(--pui-border-light);
                border-top: none;
                border-radius: 0 0 12px 12px;
                padding: 10px 20px;
                cursor: pointer;
                font-family: var(--pui-font-mono);
                font-size: 0.78rem;
                font-weight: 600;
                color: var(--pui-text-secondary);
                transition: background 0.2s ease, color 0.2s ease;
            }
            .cm-landing-toggle:hover { color: var(--pui-text-primary); background: var(--pui-hover); }
            .cm-landing-toggle.open { border-radius: 0; color: var(--pui-text-primary); }
            .cm-lt-summary { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
            .cm-lt-summary > i { color: var(--pui-accent); }
            .cm-lt-best { color: var(--pui-text-tertiary); font-weight: 500; }
            .cm-lt-chevron { transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1); font-size: 0.75rem; }
            .cm-landing-toggle.open .cm-lt-chevron { transform: rotate(180deg); }

            /* Landing detail panel (collapsible) */
            .cm-landing-detail {
                max-height: 0;
                overflow: hidden;
                background: var(--pui-bg-base);
                border: 1px solid var(--pui-border-light);
                border-top: none;
                transition: max-height 0.3s cubic-bezier(0.16, 1, 0.3, 1);
            }
            .cm-landing-detail.open {
                max-height: 1200px;
                border-radius: 0 0 12px 12px;
            }
            .cm-landing-row {
                display: flex;
                flex-direction: column;
                gap: 6px;
                padding: 12px 20px;
                border-top: 1px dashed var(--pui-border-light);
            }
            .cm-landing-row:first-child { border-top: none; }
            .cm-lr-head { display: flex; align-items: center; gap: 10px; }
            .cm-lr-idx { font-family: var(--pui-font-mono); font-size: 0.7rem; font-weight: 700; color: var(--pui-text-tertiary); }
            .cm-lr-time { font-family: var(--pui-font-mono); font-size: 0.7rem; color: var(--pui-text-tertiary); margin-left: auto; }
            .cm-lr-rate {
                font-family: var(--pui-font-mono);
                font-size: 0.68rem;
                font-weight: 700;
                padding: 2px 8px;
                border-radius: 6px;
                text-transform: uppercase;
                letter-spacing: 0.04em;
            }
            .land-butter { background: rgba(16, 185, 129, 0.12); color: #10b981; }
            .land-smooth { background: rgba(59, 130, 246, 0.12); color: #3b82f6; }
            .land-firm   { background: rgba(245, 158, 11, 0.12); color: #f59e0b; }
            .land-hard   { background: rgba(239, 68, 68, 0.12);  color: #ef4444; }
            b.land-butter, b.land-smooth, b.land-firm, b.land-hard { background: none; padding: 0; }
            .cm-lr-metrics {
                display: flex;
                flex-wrap: wrap;
                gap: 6px 16px;
                font-family: var(--pui-font-mono);
                font-size: 0.75rem;
                color: var(--pui-text-secondary);
            }
            .cm-lr-metrics b { color: var(--pui-text-primary); font-weight: 700; }

            .cm-log-vio-badge {
                position: absolute;
                top: -8px;
                right: -8px;
                background: var(--pui-neg);
                color: #fff;
                font-size: 0.65rem;
                font-weight: 700;
                padding: 4px 8px;
                border-radius: 6px;
                font-family: var(--pui-font-mono);
                display: flex;
                align-items: center;
                gap: 4px;
                box-shadow: 0 4px 12px rgba(239, 68, 68, 0.4);
            }
            .enforce-badge { background: var(--pui-warn); box-shadow: 0 4px 12px rgba(245, 158, 11, 0.4); }

            /* Pagination Button */
            .cm-load-more-container {
                display: flex;
                justify-content: center;
                padding: 16px 0;
            }
            .cm-load-more-btn {
                background: rgba(255, 255, 255, 0.05);
                border: 1px solid var(--pui-border-light);
                color: var(--pui-text-primary);
                padding: 10px 24px;
                border-radius: 20px;
                font-family: var(--pui-font-mono);
                font-size: 0.8rem;
                font-weight: 600;
                cursor: pointer;
                transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
            }
            .cm-load-more-btn:hover {
                background: var(--pui-hover);
                border-color: var(--pui-accent);
                color: var(--pui-accent);
            }
            .cm-load-more-btn i { margin-right: 8px; }
            .cm-btn-loading { opacity: 0.7; pointer-events: none; }

            .cm-empty-state {
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                padding: 64px 20px;
                color: var(--pui-text-tertiary);
                font-family: var(--pui-font-mono);
                font-size: 0.9rem;
                gap: 12px;
            }
            .cm-empty-state i { font-size: 2rem; opacity: 0.5; }

            @media (max-width: 768px) {
                .cm-flight-card {
                    grid-template-columns: 1fr;
                    text-align: center;
                    gap: 12px;
                }
                .cm-fc-context { align-items: center; }
                .cm-fc-telemetry { align-items: center; flex-direction: row; justify-content: center; gap: 24px; }
                .cm-fc-stat-item { align-items: center; }
                .cm-segmented-control { flex-wrap: nowrap; overflow-x: auto; padding-bottom: 8px; }
                .cm-segment-btn { min-width: auto; padding: 8px 12px; }
            }
        `;
        const style = document.createElement('style');
        style.id = 'cm-dossier-styles';
        style.innerHTML = css;
        document.head.appendChild(style);
    }
};