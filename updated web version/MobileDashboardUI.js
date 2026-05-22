/**
 * MobileDashboardUI.js — Premium Mobile-Optimized Full-Screen Dashboard
 *
 * A full mobile counterpart to ProfileUI. Mirrors all tabs in a native-feeling
 * bottom-sheet + tab-bar architecture, fully aligned with the "Soft Premium"
 * warm-neutral design language, dynamic accent colors, and component parity.
 */

import { CareerModule } from './careerModule.js';
import { PredictiveAirspaceNetwork } from './PredictiveQueueManager.js';
import { socketDataHub } from './SocketDataHub.js';
import { AircraftViewer3D } from './AircraftViewer3D.js';

const AIRCRAFT_SELECTION_LIST = [
    { value: 'A318', name: 'Airbus A318-100' }, { value: 'A319', name: 'Airbus A319-100' },
    { value: 'A320', name: 'Airbus A320-200' }, { value: 'A20N', name: 'Airbus A320neo' },
    { value: 'A321', name: 'Airbus A321-200' }, { value: 'A21N', name: 'Airbus A321neo' },
    { value: 'A333', name: 'Airbus A330-300' }, { value: 'A339', name: 'Airbus A330-900neo' },
    { value: 'A346', name: 'Airbus A340-600' }, { value: 'A359', name: 'Airbus A350-900' },
    { value: 'A388', name: 'Airbus A380-800' }, { value: 'B712', name: 'Boeing 717-200' },
    { value: 'B737', name: 'Boeing 737-700' }, { value: 'B738', name: 'Boeing 737-800' },
    { value: 'B739', name: 'Boeing 737-900' }, { value: 'B38M', name: 'Boeing 737 MAX 8' },
    { value: 'B742', name: 'Boeing 747-200B' }, { value: 'B744', name: 'Boeing 747-400' },
    { value: 'B748', name: 'Boeing 747-8' }, { value: 'B752', name: 'Boeing 757-200' },
    { value: 'B763', name: 'Boeing 767-300ER' }, { value: 'B772', name: 'Boeing 777-200ER' },
    { value: 'B77L', name: 'Boeing 777-200LR' }, { value: 'B77W', name: 'Boeing 777-300ER' },
    { value: 'B788', name: 'Boeing 787-8' }, { value: 'B789', name: 'Boeing 787-9' },
    { value: 'B78X', name: 'Boeing 787-10' }, { value: 'CRJ2', name: 'Bombardier CRJ-200' },
    { value: 'CRJ7', name: 'Bombardier CRJ-700' }, { value: 'CRJ9', name: 'Bombardier CRJ-900' },
    { value: 'CRJX', name: 'Bombardier CRJ-1000' }, { value: 'DH8D', name: 'De Havilland Dash 8 Q400' },
    { value: 'E175', name: 'Embraer E175' }, { value: 'E190', name: 'Embraer E190' },
    { value: 'DC10', name: 'McDonnell Douglas DC-10' }, { value: 'MD11', name: 'McDonnell Douglas MD-11' }
];

export const MobileDashboardUI = {

    // ─── State ──────────────────────────────────────────────────────────────
    _supabase:          null,
    _isOpen:            false,
    _injected:          false,
    _activeTab:         'dashboard',
    _careerActiveTab:   'overview',
    _currentUser:       null,
    _theme:             'light',     
    _accent:            'caramel',   
    _bio:               '',
    _coverUrl:          '',
    _flightPlansData:   [],
    _editingFlightId:   null,
    _airportCache:      null,
    
    // Telemetry & Watchlist
    _liveFlights:       [],
    _currentAllFlights: [],
    _watchlist:         [],
    _watchedPilotStatus:{},
    _prevWatchedStatus: {},
    _userPrefs: { notification_watchlist_enabled: true },
    
    _socketUnsubscribe: null,
    _airspaceNetwork:   null,
    _airspaceTimer:     null,
    _3dViewerHostKey:   null,
    _active3DFlightId:  null,
    _subscription: {
        status:      'Active',
        plan:        'Pro Access',
        nextPayment: 'Upcoming',
        price:       '$1.99 / month',
    },
    _ifData: {
        loading:       false,
        userId:        null,
        stats:         null,
        logbook:       [],
        logbookTotal:  0,
        activeHistory: null,
        error:         null,
    },
    _backendUrl: window.APP_CONFIG?.backendUrl || 'https://site--acars-backend--6dmjph8ltlhv.code.run',

    // ─── Shared Premium Accents ─────────────────────────────────────────────
    _ACCENT_PRESETS: {
        caramel: { label: 'Caramel', light: { c: '#b88553', h: '#a87543', s: 'rgba(184,133,83,0.10)',  g: 'rgba(184,133,83,0.18)'  },
                                     dark:  { c: '#d4a574', h: '#e0b384', s: 'rgba(212,165,116,0.14)', g: 'rgba(212,165,116,0.22)' } },
        ocean:   { label: 'Ocean',   light: { c: '#3b7ea8', h: '#2f6c93', s: 'rgba(59,126,168,0.10)',  g: 'rgba(59,126,168,0.18)'  },
                                     dark:  { c: '#5fa8d3', h: '#7ab8de', s: 'rgba(95,168,211,0.14)', g: 'rgba(95,168,211,0.22)'  } },
        forest:  { label: 'Forest',  light: { c: '#3f8c5a', h: '#327547', s: 'rgba(63,140,90,0.10)',   g: 'rgba(63,140,90,0.18)'   },
                                     dark:  { c: '#7bbf91', h: '#8fcca3', s: 'rgba(123,191,145,0.14)',g: 'rgba(123,191,145,0.22)' } },
        rose:    { label: 'Rose',    light: { c: '#c25a7e', h: '#a8466a', s: 'rgba(194,90,126,0.10)',  g: 'rgba(194,90,126,0.18)'  },
                                     dark:  { c: '#e08aa8', h: '#e89cb6', s: 'rgba(224,138,168,0.14)',g: 'rgba(224,138,168,0.22)' } },
        violet:  { label: 'Violet',  light: { c: '#7e57c2', h: '#6845a8', s: 'rgba(126,87,194,0.10)',  g: 'rgba(126,87,194,0.18)'  },
                                     dark:  { c: '#b287d9', h: '#c099e0', s: 'rgba(178,135,217,0.14)',g: 'rgba(178,135,217,0.22)' } },
        slate:   { label: 'Slate',   light: { c: '#5a6878', h: '#475363', s: 'rgba(90,104,120,0.10)', g: 'rgba(90,104,120,0.18)'  },
                                     dark:  { c: '#94a3b3', h: '#a8b5c2', s: 'rgba(148,163,179,0.14)',g: 'rgba(148,163,179,0.22)' } },
    },

    // ─── Public API ──────────────────────────────────────────────────────────

init(supabaseClient) {
        this._supabase = supabaseClient;

        this._supabase.auth.onAuthStateChange((event, session) => {
            if (session?.user) {
                this._currentUser = session.user;
                if (session.user.user_metadata?.theme) {
                    this._theme = this._normalizeTheme(session.user.user_metadata.theme);
                }
                if (session.user.user_metadata?.accent_color) {
                    this._accent = session.user.user_metadata.accent_color;
                }
                this._fetchWatchlist();
                this._fetchUserPreferences();
            } else {
                this._currentUser = null;
                this._watchlist = [];
            }

            if (event === 'USER_UPDATED' && session?.user && this._isOpen) {
                const ifUsername = session.user.user_metadata?.if_username;
                if (ifUsername) this._fetchInfiniteFlightData(ifUsername);
                this._applyVisualPreferences();
                this._render();
            }
        });

        if (!this._socketUnsubscribe) {
            this._socketUnsubscribe = socketDataHub.subscribe('all_flights_update', (payload) => {
                if (!payload?.flights) return;
                this._currentAllFlights = payload.flights;
                
                // --- 3D HUD Live Telemetry Feed ---
                if (this._active3DFlightId && typeof AircraftViewer3D !== 'undefined') {
                    const active3DFlight = payload.flights.find(f => String(f.flightId || f.properties?.flightId) === this._active3DFlightId);
                    if (active3DFlight) {
                        AircraftViewer3D.updateFlightData(this._extractPositionForViewer(active3DFlight));
                    }
                }
                
                const ifUsername = this._currentUser?.user_metadata?.if_username;
                if (ifUsername) {
                    const prev = this._liveFlights.length > 0;
                    this._liveFlights = payload.flights.filter(
                        f => f.username?.toLowerCase() === ifUsername.toLowerCase()
                    );
                    if (this._isOpen && this._activeTab === 'dashboard') {
                        if (this._liveFlights.length > 0 || prev) this._updateLiveBanner();
                    }
                }

                // Watchlist sync
                if (this._watchlist.length > 0) {
                    this._prevWatchedStatus = { ...this._watchedPilotStatus };
                    const newStatus = {};
                    for (const entry of this._watchlist) {
                        const un = entry.watched_username.toLowerCase();
                        const flight = payload.flights.find(f => f.username?.toLowerCase() === un);
                        newStatus[un] = { isLive: !!flight, flight: flight || null };
                    }
                    this._watchedPilotStatus = newStatus;

                    if (this._userPrefs.notification_watchlist_enabled) {
                        for (const [un, cur] of Object.entries(newStatus)) {
                            const prev = this._prevWatchedStatus[un];
                            if (cur.isLive && prev && !prev.isLive) {
                                const f = cur.flight;
                                const route = (f?.departureIcao && f?.arrivalIcao) ? ` on ${f.departureIcao} → ${f.arrivalIcao}` : '';
                                this._showToast(`<i class="fa-solid fa-plane-departure" style="margin-right:8px;"></i><strong>${f?.username || un}</strong> is now airborne${route}`, 'info');
                            }
                        }
                    }

                    if (this._isOpen && this._activeTab === 'watchlist') {
                        this._updateWatchlistDOM();
                    }
                    this._syncBadgeCount();
                }
            });
        }
    },

    open(user) {
        this._currentUser = user;

        const needsOnboarding = !user?.user_metadata?.onboarding_complete;
        this._activeTab = needsOnboarding ? 'onboarding' : 'dashboard';

        // Load preferences
        const rawTheme = user?.user_metadata?.theme || localStorage.getItem('pui-theme') || 'light';
        this._theme = this._normalizeTheme(rawTheme);

        const rawAccent = user?.user_metadata?.accent_color || localStorage.getItem('pui-accent') || 'caramel';
        this._accent = this._ACCENT_PRESETS[rawAccent] ? rawAccent : 'caramel';

        this._bio       = user?.user_metadata?.pilot_bio || '';
        this._coverUrl  = user?.user_metadata?.cover_url || '';

        if (!this._injected) {
            this._injectStyles();
            this._injectShell();
            this._injected = true;
        }

        this._applyVisualPreferences();

        if (!this._airspaceNetwork) {
            this._airspaceNetwork = new PredictiveAirspaceNetwork();
            this._airspaceNetwork.bindTelemetryStream();
            this._airspaceNetwork.setActiveNodes(['KJFK', 'EGLL', 'KLAX', 'OMDB']);
        }

        this._editingFlightId = null;
        this._render();
        this._fetchSubscriptionData();
        this._fetchFlightPlans();
        this._fetchWatchlist();
        this._fetchUserPreferences();

        const ifUsername = user?.user_metadata?.if_username;
        if (ifUsername) this._fetchInfiniteFlightData(ifUsername);

        requestAnimationFrame(() => requestAnimationFrame(() => {
            document.getElementById('mdui-shell')?.classList.add('mdui-open');
            this._isOpen = true;
            document.body.style.overflow = 'hidden';
        }));
    },

    close() {
        document.getElementById('mdui-shell')?.classList.remove('mdui-open');
        this._isOpen = false;
        document.body.style.overflow = '';
        this._editingFlightId = null;
        
        if (this._airspaceTimer) {
            clearInterval(this._airspaceTimer);
            this._airspaceTimer = null;
        }
        setTimeout(() => {
            if (this._currentUser?.user_metadata?.onboarding_complete) {
                this._activeTab = 'dashboard';
            }
        }, 350);
    },

    switchTab(tabId) {
        if (this._activeTab === tabId) return;
        this._activeTab = tabId;
        
        if (tabId !== 'flight-plan') {
            this._editingFlightId = null;
        }

        if (this._airspaceTimer) { clearInterval(this._airspaceTimer); this._airspaceTimer = null; }
        this._render();
        
        if (tabId === 'airspace-intel') {
            this._airspaceTimer = setInterval(() => {
                if (this._isOpen && this._activeTab === 'airspace-intel') this._updateAirspaceDOM();
            }, 8000);
        }
    },

    // ─── Helpers ──────────────────────────────────────────────────────────────

    _normalizeTheme(name) {
        if (name === 'white' || name === 'light-gray') return 'light';
        if (name === 'dark-gray' || name === 'dark') return 'dark';
        return name === 'light' || name === 'dark' ? name : 'light';
    },

    _applyVisualPreferences() {
        const shell = document.getElementById('mdui-shell');
        if (!shell) return;
        
        shell.setAttribute('data-theme', this._theme);

        const preset = this._ACCENT_PRESETS[this._accent] || this._ACCENT_PRESETS.caramel;
        const variant = this._theme === 'dark' ? preset.dark : preset.light;
        
        shell.style.setProperty('--mdui-accent', variant.c);
        shell.style.setProperty('--mdui-accent-hover', variant.h);
        shell.style.setProperty('--mdui-accent-soft', variant.s);
        shell.style.setProperty('--mdui-accent-glow', variant.g);
    },

    _showToast(htmlContent, type = 'info', duration = 4000) {
        const container = document.getElementById('mdui-toast-container');
        if (!container) return;

        const toast = document.createElement('div');
        toast.className = `mdui-toast mdui-toast-${type}`;
        toast.innerHTML = htmlContent;

        const dismiss = () => {
            toast.classList.add('mdui-toast-out');
            setTimeout(() => toast.remove(), 240);
        };
        toast.addEventListener('click', dismiss);
        container.appendChild(toast);
        setTimeout(dismiss, duration);
    },

    _syncBadgeCount() {
        const liveCount = Object.values(this._watchedPilotStatus).filter(s => s.isLive).length;
        const badge = document.getElementById('mdui-tab-badge-watchlist');
        if (badge) {
            badge.textContent = liveCount;
            badge.style.display = liveCount > 0 ? '' : 'none';
        }
    },

    // ─── Data Fetching ────────────────────────────────────────────────────────

    async _fetchSubscriptionData() {
        if (!this._currentUser || !this._supabase) return;
        try {
            const { data, error } = await this._supabase
                .from('subscriptions')
                .select('status, plan_name, current_period_end, amount')
                .eq('user_id', this._currentUser.id)
                .single();
            if (data && !error) {
                const nextDate = new Date(data.current_period_end);
                this._subscription = {
                    status:      data.status === 'active' ? 'Active' : 'Inactive',
                    plan:        data.plan_name || 'Pro Access',
                    nextPayment: isNaN(nextDate) ? 'Pending' : nextDate.toLocaleDateString(),
                    price:       `$${(data.amount / 100).toFixed(2)} / month`,
                };
                if (this._activeTab === 'settings' && this._isOpen) this._render();
            }
        } catch (_) { }
    },

    async _fetchFlightPlans() {
        if (!this._currentUser || !this._supabase) return;
        try {
            const { data, error } = await this._supabase
                .from('user_flights')
                .select('*')
                .eq('user_id', this._currentUser.id)
                .order('dep_time', { ascending: false })
                .limit(50);
            if (error) throw error;
            this._flightPlansData = data || [];
            if (this._activeTab === 'flight-plan' && this._isOpen) this._render();
        } catch (err) {
            console.error('Error fetching flight plans:', err.message);
        }
    },

    async _fetchWatchlist() {
        if (!this._currentUser || !this._supabase) return;
        try {
            const { data, error } = await this._supabase
                .from('user_watchlist')
                .select('id, watched_username, added_at')
                .eq('user_id', this._currentUser.id)
                .order('added_at', { ascending: false });
            if (error) throw error;
            this._watchlist = data || [];
            this._syncBadgeCount();
        } catch (err) {
            console.warn('[MobileUI] Could not load watchlist:', err.message);
        }
    },

    async _fetchUserPreferences() {
        if (!this._currentUser || !this._supabase) return;
        try {
            const { data, error } = await this._supabase
                .from('user_preferences')
                .select('*')
                .eq('user_id', this._currentUser.id)
                .single();
            if (data && !error) {
                if (typeof data.notification_watchlist_enabled === 'boolean') {
                    this._userPrefs.notification_watchlist_enabled = data.notification_watchlist_enabled;
                }
            }
        } catch (err) {
            // defaults
        }
    },

    async _saveUserPreferences() {
        if (!this._currentUser || !this._supabase) return;
        try {
            await this._supabase.from('user_preferences').upsert({
                user_id: this._currentUser.id,
                notification_watchlist_enabled: this._userPrefs.notification_watchlist_enabled,
            }, { onConflict: 'user_id' });
        } catch (err) { }
    },

    async _fetchInfiniteFlightData(ifUsername) {
        if (!ifUsername) return;
        this._ifData.loading = true;
        this._ifData.error   = null;
        if (this._isOpen) this._render();

        try {
            let ifUserId = null;
            let activeFlightId = null;

            if (typeof window.getLiveFlightData === 'function') {
                const liveFlights  = window.getLiveFlightData();
                const activeFlight = liveFlights.find(
                    f => f.properties?.username?.toLowerCase() === ifUsername.toLowerCase()
                );
                if (activeFlight) {
                    activeFlightId = activeFlight.properties.flightId;
                    ifUserId       = activeFlight.properties.userId;
                }
            }

            if (!ifUserId) {
                const res      = await fetch(`${this._backendUrl}/users`, {
                    method:  'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body:    JSON.stringify({ discourseNames: [ifUsername], userHashes: [ifUsername] }),
                });
                const userData = await res.json();
                ifUserId       = userData?.users?.[0]?.userId;
            }

            if (!ifUserId) throw new Error('Could not find an Infinite Flight account with that username.');
            this._ifData.userId = ifUserId;

            const requests = [
                fetch(`${this._backendUrl}/api/users/${ifUserId}/stats`).then(r => r.json()),
                fetch(`${this._backendUrl}/api/users/${ifUserId}/flights?page=1`).then(r => r.json()),
            ];
            if (activeFlightId) {
                requests.push(
                    fetch(`${this._backendUrl}/api/flights/${activeFlightId}/history`)
                        .then(r => r.json()).catch(() => null)
                );
            }

            const [statsData, flightsData, historyData] = await Promise.all(requests);
            this._ifData.stats        = statsData.ok  ? statsData.stats   : null;
            this._ifData.logbook      = flightsData.ok ? flightsData.flights : [];
            this._ifData.logbookTotal = flightsData.ok ? flightsData.totalCount : 0;
            if (historyData?.ok) this._ifData.activeHistory = historyData.path;
            this._ifData.loading = false;
        } catch (err) {
            this._ifData.error   = err.message;
            this._ifData.loading = false;
        }

        if (this._isOpen) this._render();
    },

    // ─── DOM Shell ────────────────────────────────────────────────────────────

    _injectShell() {
        const el = document.createElement('div');
        el.id    = 'mdui-shell';
        el.innerHTML = `
            <div id="mdui-screen"></div>
            <nav id="mdui-tabbar">
                ${this._tabDef().map(t => {
                    const badge = t.id === 'watchlist' ? `<span id="mdui-tab-badge-watchlist" class="mdui-tab-badge" style="display:none;"></span>` : '';
                    return `
                    <button class="mdui-tab-btn" data-tab="${t.id}" aria-label="${t.label}">
                        <div style="position:relative;">
                            <i class="${t.icon}"></i>
                            ${badge}
                        </div>
                        <span>${t.label}</span>
                    </button>`;
                }).join('')}
            </nav>
            <div id="mdui-toast-container" class="mdui-toast-container"></div>
        `;
        document.body.appendChild(el);

        el.addEventListener('click', e => {
            const btn = e.target.closest('.mdui-tab-btn');
            if (btn) this.switchTab(btn.dataset.tab);
        });
    },

    _tabDef() {
        return [
            { id: 'dashboard',        icon: 'fa-solid fa-house',             label: 'Home'     },
            { id: 'career-deep-dive', icon: 'fa-solid fa-id-card',           label: 'Dossier'  },
            { id: 'airspace-intel',   icon: 'fa-solid fa-tower-broadcast',   label: 'Traffic'  },
            { id: 'flight-plan',      icon: 'fa-solid fa-route',             label: 'Dispatch' },
            { id: 'watchlist',        icon: 'fa-solid fa-binoculars',        label: 'Watchlist'},
            { id: 'settings',         icon: 'fa-solid fa-sliders',           label: 'Settings' },
        ];
    },

    // ─── Render ───────────────────────────────────────────────────────────────

    _render() {
        const screen = document.getElementById('mdui-screen');
        if (!screen) return;

        document.querySelectorAll('.mdui-tab-btn').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.tab === this._activeTab);
        });

        const tabbar = document.getElementById('mdui-tabbar');
        if (tabbar) tabbar.style.display = this._activeTab === 'onboarding' ? 'none' : '';

        screen.innerHTML = `
            <div class="mdui-top-bar">
                ${this._renderTopBar()}
            </div>
            <div class="mdui-content mdui-scroll" id="mdui-content-area">
                ${this._renderTabContent()}
            </div>
        `;

        this._attachListeners();
        this._syncBadgeCount();

        if (this._activeTab === 'dashboard') this._updateLiveBanner();
    },

    _renderTopBar() {
        if (this._activeTab === 'onboarding') {
            return `<span class="mdui-top-title">Welcome Aboard</span>`;
        }
        const titles = {
            dashboard:        'Command Center',
            'career-deep-dive': 'Pilot Dossier',
            'airspace-intel': 'Airspace Radar',
            'flight-plan':    'Flight Dispatch',
            watchlist:        'Pilot Watchlist',
            settings:         'Settings',
        };
        const user    = this._currentUser;
        const name    = user?.user_metadata?.full_name || user?.user_metadata?.name || 'Captain';
        const initials = name.trim().split(/\s+/).map(w => w[0]).join('').toUpperCase().slice(0, 2);

        return `
            <div class="mdui-avatar">${initials}</div>
            <span class="mdui-top-title">${titles[this._activeTab] || ''}</span>
            <button class="mdui-close-btn" id="mdui-close" aria-label="Close">
                <i class="fa-solid fa-xmark"></i>
            </button>
        `;
    },

    // ─── Tab Content ─────────────────────────────────────────────────────────

    _renderTabContent() {
        switch (this._activeTab) {
            case 'onboarding':        return this._tabOnboarding();
            case 'dashboard':         return this._tabDashboard();
            case 'career-deep-dive':  return this._tabCareer();
            case 'airspace-intel':    return this._tabAirspace();
            case 'flight-plan':       return this._tabDispatch();
            case 'watchlist':         return this._tabWatchlist();
            case 'settings':          return this._tabSettings();
            default:                  return '';
        }
    },

_tabOnboarding() {
        return `
            <div class="mdui-onboarding mdui-fade-up">
                <div class="mdui-onb-icon"><i class="fa-solid fa-plane-departure"></i></div>
                <h2 class="mdui-onb-title">Welcome aboard.</h2>
                <p class="mdui-onb-sub">Thank you for subscribing to Pro Access. Let's set up your flight deck.</p>

                <div class="mdui-card" style="margin-top: 28px;">
                    <div class="mdui-card-body">
                        <div class="mdui-input-group" style="margin-bottom: 0;">
                            <label>Choose Your Theme</label>
                            <div class="mdui-pill-row">
                                <label class="mdui-radio-pill">
                                    <input type="radio" name="onb-theme" value="light" ${this._theme === 'light' ? 'checked' : ''}>
                                    <i class="fa-solid fa-sun" style="margin-right: 6px;"></i>
                                    <span>Light</span>
                                </label>
                                <label class="mdui-radio-pill">
                                    <input type="radio" name="onb-theme" value="dark" ${this._theme === 'dark' ? 'checked' : ''}>
                                    <i class="fa-solid fa-moon" style="margin-right: 6px;"></i>
                                    <span>Dark</span>
                                </label>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="mdui-card" style="margin-top: 14px;">
                    <div class="mdui-card-body">
                        <div class="mdui-input-group" style="margin-bottom: 0;">
                            <label>Infinite Flight Username</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-plane mdui-input-icon"></i>
                                <input type="text" id="mdui-onb-username" class="mdui-input" placeholder="Community Forum Name">
                            </div>
                            <p class="mdui-help">We use this to fetch your live flights and career stats.</p>
                        </div>
                    </div>
                </div>

                <button class="mdui-btn-primary" id="mdui-onb-complete" style="margin-top: 28px; width: 100%;">
                    Complete Setup
                </button>
                <p class="mdui-help" style="text-align: center; margin-top: 14px;">
                    These preferences can be changed later in Settings.
                </p>
            </div>
        `;
    },

    // ── Dashboard / Command Center ─────────────────────────────────────────────
    _tabDashboard() {
        const user      = this._currentUser;
        const name      = user?.user_metadata?.full_name || user?.user_metadata?.name || 'Captain';
        const firstName = name.trim().split(/\s+/)[0];
        const hour      = new Date().getHours();
        const greeting  = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
        const dateStr   = new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' });
        const ifUsername = user?.user_metadata?.if_username || '';

        let statPills = '';
        if (this._ifData.stats) {
            const g = this._ifData.stats.gradeDetails?.gradeIndex;
            const x = this._ifData.stats.totalXP?.toLocaleString();
            const f = this._ifData.logbookTotal?.toLocaleString();
            statPills = `
                <div class="mdui-stat-strip">
                    ${g ? `<span>Grade ${g}</span><span class="mdui-strip-sep">·</span>` : ''}
                    ${x ? `<span>${x} XP</span><span class="mdui-strip-sep">·</span>` : ''}
                    ${f ? `<span>${f} flights</span>` : ''}
                </div>`;
        } else if (this._ifData.loading) {
            statPills = `<div class="mdui-stat-strip"><span style="opacity:0.4;">Loading pilot data…</span></div>`;
        }

        let recentHTML = '';
        if (!ifUsername) {
            recentHTML = `<div class="mdui-empty"><i class="fa-solid fa-link-slash"></i><span>Link your IF account in Settings.</span></div>`;
        } else if (this._ifData.loading) {
            recentHTML = [1,2,3].map(() => `
                <div class="mdui-flight-row">
                    <div class="mdui-skel" style="width:110px;height:14px;border-radius:4px;"></div>
                    <div class="mdui-skel" style="width:55px;height:10px;border-radius:4px;"></div>
                </div>`).join('');
        } else if (this._ifData.logbook?.length > 0) {
            recentHTML = this._ifData.logbook.slice(0, 5).map((f, i) => {
                const dep     = f.originAirport      || 'N/A';
                const arr     = f.destinationAirport || 'N/A';
                const hrs     = (f.totalTime / 60).toFixed(1);
                const dateObj = new Date(f.created);
                const fresh   = (Date.now() - dateObj.getTime()) < 172800000;
                const timeStr = fresh ? 'Recently' : dateObj.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
                const depAttr = dep !== 'N/A' ? `data-drill="icao" data-icao="${dep}"` : '';
                const arrAttr = arr !== 'N/A' ? `data-drill="icao" data-icao="${arr}"` : '';
                const cs = f.callsign || 'N/A';
                const csAttr = cs !== 'N/A' ? `data-drill="callsign" data-callsign="${cs}"` : '';
                return `
                    <div class="mdui-flight-row mdui-fade-up" style="animation-delay:${i * 0.04}s;">
                        <div class="mdui-flight-route">
                            <span class="mdui-icao mdui-drillable" ${depAttr}>${dep}</span>
                            <span class="mdui-arrow">→</span>
                            <span class="mdui-icao mdui-drillable" ${arrAttr}>${arr}</span>
                        </div>
                        <div class="mdui-flight-meta">
                            <span class="mdui-drillable" ${csAttr}>${cs}</span>
                            <span class="mdui-dot">·</span>
                            <span>${hrs}h</span>
                        </div>
                        <div class="mdui-flight-time">${timeStr}</div>
                    </div>`;
            }).join('');
        } else {
            recentHTML = `<div class="mdui-empty"><i class="fa-solid fa-inbox"></i><span>No recent flights.</span></div>`;
        }

        let nextDepHTML = '';
        if (this._flightPlansData?.length > 0) {
            const next    = this._flightPlansData[0];
            const depTime = new Date(next.dep_time);
            const diffMs  = depTime - Date.now();
            const diffH   = Math.floor(diffMs / 3600000);
            const diffM   = Math.floor((diffMs % 3600000) / 60000);
            const countdown = diffMs > 0
                ? (diffH > 0 ? `In ${diffH}h ${diffM}m` : `In ${diffM}m`)
                : 'Departed';
            const hours = Math.floor(next.duration_minutes / 60);
            const mins  = next.duration_minutes % 60;

            nextDepHTML = `
                <div class="mdui-dispatch-mini">
                    <div class="mdui-dispatch-route">
                        <div class="mdui-dispatch-airport">
                            <span class="mdui-dispatch-icao mdui-drillable" ${next.dep_icao ? `data-drill="icao" data-icao="${next.dep_icao}"` : ''}>${next.dep_icao || '----'}</span>
                            ${next.dep_gate ? `<span class="mdui-dispatch-gate">Gate ${next.dep_gate}</span>` : ''}
                        </div>
                        <div class="mdui-dispatch-center">
                            <i class="fa-solid fa-plane mdui-dispatch-plane"></i>
                            <span class="mdui-dispatch-dur">${hours}h ${mins}m</span>
                        </div>
                        <div class="mdui-dispatch-airport" style="text-align:right;">
                            <span class="mdui-dispatch-icao mdui-drillable" ${next.arr_icao ? `data-drill="icao" data-icao="${next.arr_icao}"` : ''}>${next.arr_icao || '----'}</span>
                            ${next.arr_gate ? `<span class="mdui-dispatch-gate">Gate ${next.arr_gate}</span>` : ''}
                        </div>
                    </div>
                    <div class="mdui-dispatch-meta-row">
                        <div style="display:flex; justify-content:space-between; width:100%; margin-bottom: 4px;">
                            <span>Aircraft</span>
                            <strong style="color:var(--mdui-text);">${next.aircraft_type || 'N/A'}</strong>
                        </div>
                        <div style="display:flex; justify-content:space-between; width:100%; margin-bottom: 4px;">
                            <span>Callsign</span>
                            <strong style="color:var(--mdui-text); font-family:var(--mdui-font-mono);">${next.callsign || 'N/A'}</strong>
                        </div>
                        <div style="display:flex; justify-content:space-between; width:100%;">
                            <span>Departure</span>
                            <strong style="color:var(--mdui-accent);">${countdown}</strong>
                        </div>
                    </div>
                </div>`;
        } else {
            nextDepHTML = `<div class="mdui-empty" style="padding: 20px 0;"><i class="fa-regular fa-calendar"></i><span>No upcoming flights filed.</span></div>`;
        }

        return `
            <div class="mdui-cc-greeting mdui-fade-up">
                <div>
                    <h1 class="mdui-greeting-name">${greeting},<br/>${firstName}.</h1>
                    ${statPills}
                </div>
                <span class="mdui-greeting-date">${dateStr}</span>
            </div>

            <div id="mdui-live-banner"></div>

            <div class="mdui-card mdui-fade-up" style="animation-delay:0.06s;">
                <div class="mdui-card-eyebrow">Next Departure</div>
                ${nextDepHTML}
            </div>

            <div class="mdui-card mdui-fade-up" style="animation-delay:0.1s; padding: 6px 0;">
                <div class="mdui-card-eyebrow" style="padding: 14px 16px 0;">Recent Flights</div>
                ${recentHTML}
            </div>
        `;
    },

    // ── Career / Pilot Dossier ────────────────────────────────────────────────
    _computeComparativeStats() {
        const logbook = this._ifData?.logbook;
        if (!Array.isArray(logbook) || logbook.length === 0) return null;

        const now = new Date();
        const ms = (d) => d.getTime();

        const startOfThisMonth = new Date(now.getFullYear(), now.getMonth(), 1);
        const startOfLastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);

        const sevenDaysAgo  = new Date(ms(now) - 7  * 86400000);
        const fourteenDaysAgo = new Date(ms(now) - 14 * 86400000);

        let hoursThisMonth = 0, hoursLastMonth = 0;
        let flightsThisWeek = 0, flightsLastWeek = 0;
        const acftThisMonth = new Set(), acftLastMonth = new Set();
        const daysThisWeek  = new Set(), daysLastWeek  = new Set();

        for (const f of logbook) {
            if (!f?.created) continue;
            const d  = new Date(f.created);
            const dT = ms(d);
            const minutes = typeof f.totalTime === 'number' ? f.totalTime : 0;

            if (dT >= ms(startOfThisMonth)) {
                hoursThisMonth += minutes / 60;
                if (f.aircraftId) acftThisMonth.add(f.aircraftId);
            } else if (dT >= ms(startOfLastMonth) && dT < ms(startOfThisMonth)) {
                hoursLastMonth += minutes / 60;
                if (f.aircraftId) acftLastMonth.add(f.aircraftId);
            }

            if (dT >= ms(sevenDaysAgo)) {
                flightsThisWeek += 1;
                daysThisWeek.add(d.toISOString().slice(0, 10));
            } else if (dT >= ms(fourteenDaysAgo) && dT < ms(sevenDaysAgo)) {
                flightsLastWeek += 1;
                daysLastWeek.add(d.toISOString().slice(0, 10));
            }
        }

        const anyData = hoursThisMonth || hoursLastMonth || flightsThisWeek || flightsLastWeek
                     || acftThisMonth.size || acftLastMonth.size || daysThisWeek.size || daysLastWeek.size;
        if (!anyData) return null;

        const buildDelta = (current, previous) => {
            const diff = current - previous;
            let pct = null;
            if (previous > 0) {
                pct = Math.round((diff / previous) * 100);
            } else if (current > 0) {
                pct = 100;
            }
            return { current, previous, diff, pct };
        };

        return {
            hoursMonth:   buildDelta(+hoursThisMonth.toFixed(1), +hoursLastMonth.toFixed(1)),
            flightsWeek:  buildDelta(flightsThisWeek, flightsLastWeek),
            activeDays:   buildDelta(daysThisWeek.size, daysLastWeek.size),
            fleetVariety: buildDelta(acftThisMonth.size, acftLastMonth.size),
        };
    },

    _getTrendsCardHTML() {
        const stats = this._computeComparativeStats();
        if (!stats) {
            return `
                <div class="mdui-card mdui-fade-up">
                    <div class="mdui-card-header"><h3><i class="fa-solid fa-chart-line" style="color: var(--mdui-accent); margin-right:8px;"></i>Trends</h3></div>
                    <div class="mdui-card-body">
                        <div class="mdui-empty">Trends will appear once we have at least two periods of data.</div>
                    </div>
                </div>`;
        }

        const fmtDelta = (d) => {
            if (d.pct == null) return `<span class="mdui-trend-neutral">—</span>`;
            const arrow = d.diff > 0 ? '▲' : d.diff < 0 ? '▼' : '●';
            const cls   = d.diff > 0 ? 'mdui-trend-up' : d.diff < 0 ? 'mdui-trend-down' : 'mdui-trend-neutral';
            const sign  = d.pct > 0 ? '+' : '';
            return `<span class="${cls}"><span class="mdui-trend-arrow">${arrow}</span>${sign}${d.pct}%</span>`;
        };

        const row = (label, d, fmtCurrent) => `
            <div class="mdui-trend-row">
                <div class="mdui-trend-label">${label}</div>
                <div class="mdui-trend-current">${fmtCurrent(d.current)}</div>
                <div class="mdui-trend-delta">${fmtDelta(d)}</div>
            </div>`;

        return `
            <div class="mdui-card mdui-fade-up">
                <div class="mdui-card-header">
                    <h3><i class="fa-solid fa-chart-line" style="color: var(--mdui-accent); margin-right:8px;"></i>Trends</h3>
                </div>
                <div class="mdui-card-body" style="padding: 10px 20px;">
                    <div class="mdui-trends-grid">
                        ${row('Hours this month',   stats.hoursMonth,   v => `${v}h`)}
                        ${row('Flights this week',  stats.flightsWeek,  v => `${v}`)}
                        ${row('Active days',   stats.activeDays,   v => `${v}`)}
                        ${row('Fleet variety', stats.fleetVariety, v => `${v}`)}
                    </div>
                </div>
            </div>`;
    },

    _getPersonalRecordsHTML() {
        const logbook = this._ifData.logbook;
        if (!logbook || logbook.length === 0) return '';

        const longest = logbook.reduce((best, f) => (f.totalTime > (best?.totalTime || 0) ? f : best), null);
        const longestH = longest ? `${Math.floor(longest.totalTime / 60)}h ${longest.totalTime % 60}m` : '—';
        const longestRoute = longest ? `${longest.originAirport || '?'} → ${longest.destinationAirport || '?'}` : '';

        const acftCount = {};
        logbook.forEach(f => { if (f.aircraftId) acftCount[f.aircraftId] = (acftCount[f.aircraftId] || 0) + 1; });
        const favAcft = Object.entries(acftCount).sort((a, b) => b[1] - a[1])[0];

        const routeCount = {};
        logbook.forEach(f => {
            if (f.originAirport && f.destinationAirport) {
                const key = `${f.originAirport} → ${f.destinationAirport}`;
                routeCount[key] = (routeCount[key] || 0) + 1;
            }
        });
        const favRoute = Object.entries(routeCount).sort((a, b) => b[1] - a[1])[0];

        const records = [
            { icon: 'fa-clock',          tone: 'indigo',  label: 'Longest Flight',  value: longestH, sub: longestRoute },
            { icon: 'fa-plane',          tone: 'emerald', label: 'Favourite Route', value: favRoute?.[0] || '—', sub: favRoute ? `${favRoute[1]} flights` : '' },
            { icon: 'fa-jet-fighter-up', tone: 'amber',   label: 'Top Aircraft',    value: favAcft?.[0] || '—', sub: favAcft ? `${favAcft[1]} flights` : '' },
        ];

        return `
            <div class="mdui-card mdui-fade-up">
                <div class="mdui-card-header">
                    <h3><i class="fa-solid fa-trophy" style="color: var(--mdui-accent); margin-right: 8px;"></i>Personal Records</h3>
                </div>
                <div class="mdui-card-body" style="padding: 14px 20px;">
                    <div class="mdui-records-grid">
                        ${records.map(r => `
                            <div class="mdui-record" data-tone="${r.tone}">
                                <div class="mdui-record-head">
                                    <span class="mdui-record-icon"><i class="fa-solid ${r.icon}"></i></span>
                                    <span class="mdui-record-label">${r.label}</span>
                                </div>
                                <div class="mdui-record-value">${r.value}</div>
                                ${r.sub ? `<div class="mdui-record-sub">${r.sub}</div>` : ''}
                            </div>`).join('')}
                    </div>
                </div>
            </div>`;
    },
_tabCareer() {
        const user = this._currentUser;
        const ifUsername = user?.user_metadata?.if_username || '';
        const fullName = user?.user_metadata?.full_name || user?.user_metadata?.name || 'Captain';

        // Internal Career Sub-Tabs
        const subTabs = [
            { id: 'overview', label: 'Overview', icon: 'fa-chart-pie' },
            { id: 'logbook',  label: 'Logbook',  icon: 'fa-book' },
            { id: 'records',  label: 'Records',  icon: 'fa-trophy' }
        ];

        const subTabNav = `
            <div class="mdui-sub-tab-bar mdui-fade-up">
                ${subTabs.map(t => `
                    <button class="mdui-career-tab-btn ${this._careerActiveTab === t.id ? 'active' : ''}" 
                            data-tab="${t.id}" aria-label="${t.label}">
                        <i class="fa-solid ${t.icon}"></i>
                        <span>${t.label}</span>
                    </button>
                `).join('')}
            </div>
        `;

        const coverHTML = this._coverUrl ? `
            <div class="mdui-cover-banner mdui-fade-up" style="background-image:url('${this._coverUrl.replace(/'/g, "&apos;")}')">
                <div class="mdui-cover-overlay">
                    <div class="mdui-cover-name">${fullName}</div>
                    ${this._bio ? `<div class="mdui-cover-bio">${this._bio}</div>` : ''}
                </div>
            </div>
        ` : '';

        // Content selection based on sub-tab
        let activeContentHTML = '';
        if (this._careerActiveTab === 'overview') {
            activeContentHTML = `
                <div class="mdui-mini-stat-grid mdui-fade-up" style="margin-bottom: 24px;">
                    ${this._renderCareerMiniStats()}
                </div>
                ${this._getTrendsCardHTML()}
            `;
        } else if (this._careerActiveTab === 'logbook') {
            activeContentHTML = `
                <div class="mdui-fade-up" style="animation-delay:0.1s; margin-bottom: 24px;">
                    ${CareerModule.getHTML(this._ifData, 'logbook')}
                </div>
            `;
        } else {
            activeContentHTML = this._ifData.logbook?.length > 0 ? this._getPersonalRecordsHTML() : '<div class="mdui-empty">No records found.</div>';
        }

        return `
            ${coverHTML}
            <div class="mdui-tab-header mdui-fade-up">
                <h2>Pilot Dossier</h2>
                <p>Comprehensive career analytics and flight history.</p>
            </div>
            
            ${subTabNav}

            <div id="mdui-career-content-host">
                ${activeContentHTML}
            </div>
            
            ${this._careerActiveTab === 'overview' ? `<div class="mdui-fade-up">${CareerModule.getHTML(this._ifData, 'overview')}</div>` : ''}
        `;
    },

    // Helper to keep _tabCareer clean
    _renderCareerMiniStats() {
        if (!this._ifData.stats) return `<div class="mdui-skel" style="height:80px; width:100%;"></div>`;
        const stats = this._ifData.stats;
        return `
            <div class="mdui-mini-stat-card mdui-drillable-card" data-drill="grade" data-tone="indigo">
                <div class="mdui-mini-icon"><i class="fa-solid fa-award"></i></div>
                <div class="mdui-mini-data">
                    <div class="mdui-mini-value">Grade ${stats.gradeDetails?.gradeIndex || 'N/A'}</div>
                    <div class="mdui-mini-label">Pilot Level</div>
                </div>
            </div>
            <div class="mdui-mini-stat-card mdui-drillable-card" data-drill="xp" data-tone="violet">
                <div class="mdui-mini-icon"><i class="fa-solid fa-star"></i></div>
                <div class="mdui-mini-data">
                    <div class="mdui-mini-value">${stats.totalXP?.toLocaleString() || '0'}</div>
                    <div class="mdui-mini-label">Total XP</div>
                </div>
            </div>
            <div class="mdui-mini-stat-card mdui-drillable-card" data-drill="flights" data-tone="emerald">
                <div class="mdui-mini-icon"><i class="fa-solid fa-plane-arrival"></i></div>
                <div class="mdui-mini-data">
                    <div class="mdui-mini-value">${this._ifData.logbookTotal?.toLocaleString() || '0'}</div>
                    <div class="mdui-mini-label">Flights</div>
                </div>
            </div>`;
    },

    // ── Airspace Intel ────────────────────────────────────────────────────────
    _tabAirspace() {
        return `
            <div class="mdui-tab-header mdui-fade-up">
                <h2>Traffic</h2>
                <p>Real-time predictive multi-node telemetry. Forecasting congestion across active hubs.</p>
            </div>
            <div class="mdui-airspace-add mdui-fade-up">
                <div class="mdui-input-wrap" style="flex:1;">
                    <i class="fa-solid fa-location-crosshairs mdui-input-icon"></i>
                    <input type="text" id="mdui-intel-input" class="mdui-input mdui-icao-input"
                        placeholder="ICAO" maxlength="4">
                </div>
                <button class="mdui-btn-primary" id="mdui-intel-add" style="white-space:nowrap;">
                    <i class="fa-solid fa-satellite-dish"></i> Monitor
                </button>
            </div>
            <div id="mdui-intel-nodes" class="mdui-fade-up" style="animation-delay:0.08s;">
                ${this._renderAirspaceNodes()}
            </div>
        `;
    },

    _renderAirspaceNodes() {
        if (!this._airspaceNetwork) return '';
        const report = this._airspaceNetwork.generateNetworkAnalytics();
        
        if (Object.keys(report.nodes).length === 0) {
            return `<div class="mdui-alert mdui-alert-info"><i class="fa-solid fa-satellite"></i><span>No nodes monitored. Add an ICAO above.</span></div>`;
        }

        return Object.entries(report.nodes).map(([icao, data]) => {
            let maxSat = 'NORMAL';
            const statuses = data.arrivalQueue.map(b => b.status);
            if (statuses.includes('CRITICAL')) maxSat = 'CRITICAL';
            else if (statuses.includes('SATURATED')) maxSat = 'SATURATED';
            else if (statuses.includes('HEAVY')) maxSat = 'HEAVY';

            let statusColor = 'var(--mdui-success)'; 
            let statusBg = 'var(--mdui-success-soft)';
            let statusIcon = 'fa-circle-check';
            let statusSummary = 'Traffic flow is optimal and unrestricted. No delays anticipated.';

            if (maxSat === 'CRITICAL') { 
                statusColor = 'var(--mdui-danger)'; 
                statusBg = 'var(--mdui-danger-soft)'; 
                statusIcon = 'fa-triangle-exclamation';
                statusSummary = 'Critical congestion. Significant delays expected.';
            } else if (maxSat === 'SATURATED') { 
                statusColor = 'var(--mdui-warn)'; 
                statusBg = 'var(--mdui-warn-soft)'; 
                statusIcon = 'fa-circle-exclamation';
                statusSummary = 'Approaching saturation. Sequencing delays likely.';
            } else if (maxSat === 'HEAVY') { 
                statusColor = 'var(--mdui-info)'; 
                statusBg = 'var(--mdui-info-soft)'; 
                statusIcon = 'fa-wave-square';
                statusSummary = 'Heavy demand. Throughput is high but flow remains controlled.';
            }

            let firstHourInbound = 0;
            for(let i = 0; i < Math.min(4, data.arrivalQueue.length); i++) {
                firstHourInbound += data.arrivalQueue[i].count;
            }
            const firstHourCapacity = data.metrics.effectiveCapacity * 4;
            const loadPercentage = Math.min(100, Math.round((firstHourInbound / firstHourCapacity) * 100)) || 0;

            let heatmapHTML = '<div class="mdui-intel-heatmap">';
            const maxCount = Math.max(1, ...data.arrivalQueue.map(b => b.count || 0));
            
            for(let i = 0; i < Math.min(4, data.arrivalQueue.length); i++) {
                const bucket = data.arrivalQueue[i];
                const intensity = (bucket.count || 0) / maxCount;
                let blockColor = 'var(--mdui-border)';
                if (bucket.status === 'CRITICAL') blockColor = 'var(--mdui-danger)';
                else if (bucket.status === 'SATURATED') blockColor = 'var(--mdui-warn)';
                else if (bucket.status === 'HEAVY') blockColor = 'var(--mdui-info)';
                else if (bucket.count > 0) blockColor = 'var(--mdui-success)';
                
                heatmapHTML += `<div class="mdui-intel-heatblock" style="background: ${blockColor}; opacity: ${0.3 + intensity * 0.7};"></div>`;
            }
            heatmapHTML += '</div>';

            let alertsHTML = '';
            if (data.metrics.highEnergyArrivals > 0) alertsHTML += `<span class="mdui-mini-tag" style="background:var(--mdui-warn-soft);color:var(--mdui-warn);"><i class="fa-solid fa-bolt"></i> ${data.metrics.highEnergyArrivals} HIGH ENERGY</span>`;
            if (data.metrics.heavyAircraftInbound > 0) alertsHTML += `<span class="mdui-mini-tag" style="background:var(--mdui-info-soft);color:var(--mdui-info);"><i class="fa-solid fa-weight-hanging"></i> ${data.metrics.heavyAircraftInbound} HEAVY</span>`;

            const netFlowColor = data.metrics.netFlowDelta > 0 ? 'var(--mdui-success)' : (data.metrics.netFlowDelta < 0 ? 'var(--mdui-danger)' : 'var(--mdui-text)');
            const netFlowText = data.metrics.netFlowDelta > 0 ? `+${data.metrics.netFlowDelta}` : data.metrics.netFlowDelta;

            return `
                <div class="mdui-card mdui-fade-up">
                    <div class="mdui-node-header">
                        <div style="display:flex; align-items:center; gap:8px;">
                            <i class="fa-solid fa-tower-observation" style="color: var(--mdui-tertiary);"></i>
                            <span class="mdui-node-icao">${icao}</span>
                        </div>
                        <span class="mdui-node-badge" style="background:${statusBg};color:${statusColor};">${maxSat}</span>
                    </div>
                    
                    <div class="mdui-assessment-row">
                        <div class="mdui-assessment-icon" style="color: ${statusColor};"><i class="fa-solid ${statusIcon}"></i></div>
                        <div class="mdui-assessment-text">
                            <strong>Network Assessment</strong>
                            <span>${statusSummary}</span>
                        </div>
                    </div>

                    <div class="mdui-load-bar-block">
                        <div class="mdui-load-bar-head">
                            <span class="mdui-eyebrow">1-Hour Load</span>
                            <span class="mdui-mono-meta">${loadPercentage}%</span>
                        </div>
                        <div class="mdui-load-bar-track">
                            <div class="mdui-load-bar-fill" style="width:${loadPercentage}%;background:${statusColor};"></div>
                        </div>
                    </div>

                    <div class="mdui-intel-stats-quad">
                        <div class="mdui-intel-stat">
                            <span class="label">INBOUND</span>
                            <span class="value">${data.metrics.totalInbound}</span>
                        </div>
                        <div class="mdui-intel-stat">
                            <span class="label">OUTBOUND</span>
                            <span class="value">${data.metrics.totalOutbound}</span>
                        </div>
                        <div class="mdui-intel-stat">
                            <span class="label">NET FLOW</span>
                            <span class="value" style="color: ${netFlowColor};">${netFlowText}</span>
                        </div>
                    </div>

                    ${alertsHTML ? `<div class="mdui-mini-tag-row">${alertsHTML}</div>` : ''}

                    <div class="mdui-section-head" style="margin-top: 16px;">
                        <span class="mdui-eyebrow">4-Hour Saturation Map</span>
                        <span class="mdui-mono-meta" style="font-size:0.6rem;">CAP ${data.metrics.effectiveCapacity}/15m</span>
                    </div>
                    ${heatmapHTML}

                    <div class="mdui-card-footer">
                        <button class="mdui-btn-ghost mdui-node-remove" data-icao="${icao}">
                            <i class="fa-solid fa-link-slash"></i> Unlink Node
                        </button>
                    </div>
                </div>`;
        }).join('');
    },

    _updateAirspaceDOM() {
        const el = document.getElementById('mdui-intel-nodes');
        if (el) el.innerHTML = this._renderAirspaceNodes();
        this._bindNodeRemoveButtons();
    },

    _bindNodeRemoveButtons() {
        document.querySelectorAll('.mdui-node-remove').forEach(btn => {
            btn.addEventListener('click', () => {
                const icao  = btn.dataset.icao;
                const nodes = Array.from(this._airspaceNetwork._activeNodes).filter(n => n !== icao);
                this._airspaceNetwork.setActiveNodes(nodes);
                this._updateAirspaceDOM();
            });
        });
    },

    // ── Watchlist ─────────────────────────────────────────────────────────────
    _tabWatchlist() {
        const notifChecked = this._userPrefs.notification_watchlist_enabled ? 'checked' : '';
        return `
            <div class="mdui-tab-header mdui-fade-up">
                <h2>Pilot Watchlist</h2>
                <p>Track specific pilots in real-time. Get notified the moment they go airborne.</p>
                <label class="mdui-toggle-label" style="margin-top: 10px; display:inline-flex;">
                    <input type="checkbox" id="mdui-watchlist-notif-toggle" ${notifChecked}>
                    <span class="mdui-toggle-track"><span class="mdui-toggle-thumb"></span></span>
                    <span class="mdui-toggle-text">Live alerts</span>
                </label>
            </div>

            <div class="mdui-card mdui-fade-up" style="margin-bottom: 24px; overflow: visible;">
                <div class="mdui-card-body" style="display:flex; gap:10px;">
                    <div class="mdui-input-wrap" style="flex:1; position: relative;">
                        <i class="fa-solid fa-user-plus mdui-input-icon"></i>
                        <input type="text" id="mdui-watchlist-input" class="mdui-input has-icon" placeholder="Search active pilots…" autocomplete="off">
                        <div id="mdui-watchlist-dropdown" class="mdui-autocomplete-dropdown" style="display: none;"></div>
                    </div>
                    <button class="mdui-btn-primary" id="mdui-watchlist-add-btn">
                        <i class="fa-solid fa-plus"></i> Add
                    </button>
                </div>
            </div>

            <div id="mdui-watchlist-pilots-container" class="mdui-fade-up">
                ${this._getWatchlistPilotsHTML()}
            </div>
        `;
    },

    _getWatchlistPilotsHTML() {
        if (this._watchlist.length === 0) {
            return `
                <div class="mdui-empty-state">
                    <i class="fa-solid fa-binoculars"></i>
                    <h4>No Pilots Tracked</h4>
                    <p>Add an Infinite Flight username above to start monitoring their live status.</p>
                </div>`;
        }
        return `
            <div class="mdui-watchlist-grid">
                ${this._watchlist.map(entry => {
                    const un = entry.watched_username.toLowerCase();
                    const status = this._watchedPilotStatus[un];
                    const isLive = status?.isLive;
                    const flight = status?.flight;

                    const dep = flight?.departureIcao || '----';
                    const arr = flight?.arrivalIcao   || '----';
                    const alt = flight ? Math.round(flight.position.alt_ft).toLocaleString() + ' ft' : '—';
                    const gs  = flight ? Math.round(flight.position.gs_kt) + ' kt'                : '—';
                    const acft = flight?.aircraft?.aircraftName || '—';

                    const statusDot  = isLive ? `<span class="mdui-wl-dot live"></span>` : `<span class="mdui-wl-dot offline"></span>`;
                    const statusText = isLive ? 'Airborne' : 'Offline';

                    return `
                        <div class="mdui-wl-card ${isLive ? 'live' : ''}">
                            <div class="mdui-wl-card-top">
                                <div class="mdui-wl-identity">
                                    ${statusDot}
                                    <div>
                                        <div class="mdui-wl-username">${entry.watched_username}</div>
                                        <div class="mdui-wl-status ${isLive ? 'live' : ''}">${statusText}</div>
                                    </div>
                                </div>
                                <button class="mdui-watchlist-remove-btn" data-id="${entry.id}" data-username="${entry.watched_username}" title="Remove">
                                    <i class="fa-solid fa-xmark"></i>
                                </button>
                            </div>
                            ${isLive ? `
                            <div class="mdui-wl-flight-info">
                                <div class="mdui-wl-route">
                                    <span class="mdui-wl-icao mdui-drillable" data-drill="icao" data-icao="${dep}">${dep}</span>
                                    <i class="fa-solid fa-plane mdui-wl-plane-icon"></i>
                                    <span class="mdui-wl-icao mdui-drillable" data-drill="icao" data-icao="${arr}">${arr}</span>
                                </div>
                                <div class="mdui-wl-telemetry">
                                    <div class="mdui-wl-tele-item"><span class="label">ALTITUDE</span><span class="value">${alt}</span></div>
                                    <div class="mdui-wl-tele-item"><span class="label">GND SPD</span><span class="value">${gs}</span></div>
                                </div>
                            </div>` : ''}
                        </div>`;
                }).join('')}
            </div>`;
    },

    async _autoCalculateRouteEET(depIcao, arrIcao) {
        if (!depIcao || !arrIcao || depIcao.length !== 4 || arrIcao.length !== 4) return null;
        try {
            if (!this._airportCache) {
                const res = await fetch('https://raw.githubusercontent.com/mwgg/Airports/master/airports.json');
                if (!res.ok) throw new Error('Network error');
                this._airportCache = await res.json();
            }
            const origin = this._airportCache[depIcao.toUpperCase()];
            const dest = this._airportCache[arrIcao.toUpperCase()];
            if (!origin || !dest) return null;

            const toRad = (value) => value * Math.PI / 180;
            const R = 3440.065; 
            const dLat = toRad(dest.lat - origin.lat);
            const dLon = toRad(dest.lon - origin.lon);
            const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                      Math.cos(toRad(origin.lat)) * Math.cos(toRad(dest.lat)) *
                      Math.sin(dLon / 2) * Math.sin(dLon / 2);
            const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
            const distanceNM = R * c;

            const cruiseHours = distanceNM / 450;
            return Math.round((cruiseHours * 60) + 30);
        } catch (e) {
            return null;
        }
    },

    // ── Flight Dispatch ───────────────────────────────────────────────────────
    _tabDispatch() {
        let ticketsHTML = '';
        if (this._flightPlansData?.length > 0) {
            ticketsHTML = this._flightPlansData.map((f, i) => {
                const dateStr = new Date(f.dep_time).toLocaleDateString([], { month: 'short', day: 'numeric' });
                const timeStr = new Date(f.dep_time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
                const hours   = Math.floor(f.duration_minutes / 60);
                const mins    = f.duration_minutes % 60;
                return `
                    <div class="mdui-ticket mdui-fade-up" style="animation-delay:${i * 0.04}s;">
                        <div class="mdui-ticket-actions">
                            <button class="mdui-icon-btn mdui-ticket-edit-btn" data-id="${f.flight_id}"><i class="fa-solid fa-pen"></i></button>
                            <button class="mdui-icon-btn mdui-ticket-delete-btn" data-id="${f.flight_id}"><i class="fa-solid fa-trash"></i></button>
                        </div>
                        <div class="mdui-ticket-stub">
                            <span class="mdui-ticket-date">${dateStr}</span>
                            <span class="mdui-ticket-time">${timeStr}</span>
                            <span class="mdui-ticket-cs">${f.callsign || 'N/A'}</span>
                        </div>
                        <div class="mdui-ticket-body">
                            <div class="mdui-ticket-route">
                                <div class="mdui-ticket-point">
                                    <span class="mdui-ticket-icao">${f.dep_icao || '----'}</span>
                                    ${f.dep_gate ? `<span class="mdui-ticket-gate">Gate ${f.dep_gate}</span>` : ''}
                                </div>
                                <div class="mdui-ticket-path">
                                    <span class="mdui-ticket-duration">${hours}h ${mins}m</span>
                                    <div class="mdui-ticket-line"><i class="fa-solid fa-plane"></i></div>
                                    <span class="mdui-ticket-acft">${f.aircraft_type || 'UNK'}</span>
                                </div>
                                <div class="mdui-ticket-point mdui-ticket-point-right">
                                    <span class="mdui-ticket-icao">${f.arr_icao || '----'}</span>
                                    ${f.arr_gate ? `<span class="mdui-ticket-gate">Gate ${f.arr_gate}</span>` : ''}
                                </div>
                            </div>
                        </div>
                        <div class="mdui-ticket-aside">
                            ${f.passengers ? `<div class="mdui-ticket-stat"><i class="fa-solid fa-users"></i> ${f.passengers} pax</div>` : ''}
                            ${f.fuel_used ? `<div class="mdui-ticket-stat"><i class="fa-solid fa-gas-pump"></i> ${f.fuel_used.toLocaleString()} lbs</div>` : ''}
                        </div>
                    </div>`;
            }).join('');
        } else {
            ticketsHTML = `
                <div class="mdui-empty-state mdui-fade-up">
                    <i class="fa-solid fa-paper-plane"></i>
                    <h4>No flights filed yet</h4>
                    <p>File your first flight plan using the button below.</p>
                </div>`;
        }

        const aircraftOptions = AIRCRAFT_SELECTION_LIST.map(a => `<option value="${a.value}">${a.name} (${a.value})</option>`).join('');

        return `
            <div class="mdui-tab-header mdui-fade-up">
                <h2>Flight Dispatch</h2>
                <p>File upcoming flight plans and review your active schedule.</p>
            </div>

            <button class="mdui-btn-primary mdui-btn-block mdui-fade-up" id="mdui-toggle-form" style="margin-bottom:16px;">
                <i class="fa-solid fa-file-pen"></i> Generate dispatch
            </button>

            <div id="mdui-flight-form" class="mdui-card mdui-form-sheet" style="display:none; margin-bottom: 24px;">
                <div class="mdui-card-header">
                    <h3 id="mdui-dispatch-form-title"><i class="fa-solid fa-file-pen" style="color: var(--mdui-accent); margin-right: 6px;"></i> Dispatch Briefing</h3>
                </div>
                <div class="mdui-card-body">
                    <div class="mdui-form-section-title">Flight Identification</div>
                    <div class="mdui-form-row">
                        <div class="mdui-input-group">
                            <label>Callsign</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-tower-broadcast mdui-input-icon"></i>
                                <input type="text" id="mdui-new-callsign" class="mdui-input has-icon" placeholder="DAL404">
                            </div>
                        </div>
                        <div class="mdui-input-group">
                            <label>Aircraft</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-plane mdui-input-icon"></i>
                                <select id="mdui-new-aircraft" class="mdui-input has-icon mdui-select">
                                    <option value="" disabled selected>Select</option>
                                    ${aircraftOptions}
                                </select>
                            </div>
                        </div>
                    </div>

                    <div class="mdui-form-section-title">Routing</div>
                    <div class="mdui-form-row">
                        <div class="mdui-input-group">
                            <label>Origin</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-plane-departure mdui-input-icon"></i>
                                <input type="text" id="mdui-new-dep" class="mdui-input has-icon mdui-icao-input" placeholder="KJFK" maxlength="4">
                            </div>
                        </div>
                        <div class="mdui-input-group">
                            <label>Destination</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-plane-arrival mdui-input-icon"></i>
                                <input type="text" id="mdui-new-arr" class="mdui-input has-icon mdui-icao-input" placeholder="EGLL" maxlength="4">
                            </div>
                        </div>
                    </div>
                    <div class="mdui-form-row">
                        <div class="mdui-input-group">
                            <label>Dep Gate</label>
                            <input type="text" id="mdui-new-dep-gate" class="mdui-input" placeholder="B24">
                        </div>
                        <div class="mdui-input-group">
                            <label>Arr Gate</label>
                            <input type="text" id="mdui-new-arr-gate" class="mdui-input" placeholder="501">
                        </div>
                    </div>

                    <div class="mdui-form-section-title">Schedule & Load</div>
                    <div class="mdui-input-group" style="margin-bottom: 12px;">
                        <label>Departure Time</label>
                        <input type="datetime-local" id="mdui-new-time" class="mdui-input">
                    </div>
                    <div class="mdui-form-row">
                        <div class="mdui-input-group">
                            <label>EET (mins)</label>
                            <input type="number" id="mdui-new-duration" class="mdui-input" placeholder="Auto-calc">
                        </div>
                        <div class="mdui-input-group">
                            <label>POB (pax)</label>
                            <input type="number" id="mdui-new-pax" class="mdui-input" placeholder="212">
                        </div>
                    </div>
                    <div class="mdui-input-group" style="margin-bottom: 12px;">
                        <label>Block Fuel (lbs)</label>
                        <div class="mdui-input-wrap">
                            <i class="fa-solid fa-gas-pump mdui-input-icon"></i>
                            <input type="number" id="mdui-new-fuel" class="mdui-input has-icon" placeholder="85000">
                        </div>
                    </div>

                    <div id="mdui-flight-msg" class="mdui-alert" style="display:none; margin-bottom:12px;"></div>

                    <div class="mdui-form-actions">
                        <button class="mdui-btn-ghost" id="mdui-cancel-form">Cancel</button>
                        <button class="mdui-btn-primary" id="mdui-submit-flight">
                            <i class="fa-solid fa-paper-plane"></i> File Plan
                        </button>
                    </div>
                </div>
            </div>

            <div class="mdui-dispatch-list">
                ${ticketsHTML}
            </div>
        `;
    },

    /**
     * Premium Subscription Cancellation Portal
     * Mirrors Desktop logic: Stripe/PayPal selection -> Edge Function -> Mailto Fallback
     */
    _showCancellationModal() {
        const existing = document.getElementById('mdui-custom-confirm');
        if (existing) existing.remove();

        const overlay = document.createElement('div');
        overlay.id = 'mdui-custom-confirm';
        overlay.className = 'mdui-wrapper-layer mdui-open';
        overlay.style.zIndex = '10005';

        overlay.innerHTML = `
            <div class="mdui-confirm-box mdui-fade-up" style="max-width: 440px; padding: 0; overflow: hidden; text-align: left;">
                <div style="padding: 24px 20px 8px; text-align: center;">
                    <div class="mdui-confirm-icon" style="margin-bottom: 12px;"><i class="fa-solid fa-ban"></i></div>
                    <h3 style="margin: 0; font-size: 1.25rem;">Cancel Subscription</h3>
                </div>
                <div style="padding: 0 20px 20px;">
                    <p style="margin-bottom: 20px; font-size: 0.88rem; color: var(--mdui-muted); line-height: 1.5; text-align: center;">
                        Select the payment method used to upgrade. We will route you to the secure portal to manage your billing.
                    </p>
                    
                    <div style="display: flex; flex-direction: column; gap: 12px;">
                        <button class="mdui-btn-secondary" id="mdui-cancel-stripe-btn" style="padding: 12px; height: auto; justify-content: flex-start; border-color: var(--mdui-border-strong); text-align: left;">
                            <i class="fa-brands fa-stripe" style="font-size: 1.8rem; color: #6366f1; width: 40px;"></i>
                            <div style="display: flex; flex-direction: column; gap: 2px;">
                                <span style="font-size: 0.9rem;">Apple Pay, Google Pay, or Card</span>
                                <span style="font-size: 0.7rem; color: var(--mdui-tertiary); font-weight: 500;">Manage via Stripe Billing Portal</span>
                            </div>
                        </button>

                        <button class="mdui-btn-secondary" id="mdui-cancel-paypal-btn" style="padding: 12px; height: auto; justify-content: flex-start; border-color: var(--mdui-border-strong); text-align: left;">
                            <i class="fa-brands fa-paypal" style="font-size: 1.5rem; color: #00457C; width: 40px;"></i>
                            <div style="display: flex; flex-direction: column; gap: 2px;">
                                <span style="font-size: 0.9rem;">PayPal</span>
                                <span style="font-size: 0.7rem; color: var(--mdui-tertiary); font-weight: 500;">Manage via PayPal AutoPay</span>
                            </div>
                        </button>
                    </div>
                </div>
                <div style="padding: 16px 20px; background: var(--mdui-surface); border-top: 1px solid var(--mdui-border-light);">
                    <button class="mdui-btn-ghost" id="mdui-confirm-close" style="width: 100%;">Keep Subscription</button>
                </div>
            </div>
        `;

        document.body.appendChild(overlay);

        const cleanup = () => {
            overlay.remove();
            document.removeEventListener('keydown', escHandler);
        };

        const escHandler = (e) => { if (e.key === 'Escape') cleanup(); };
        document.addEventListener('keydown', escHandler);
        document.getElementById('mdui-confirm-close').addEventListener('click', cleanup);
        overlay.addEventListener('click', (e) => { if (e.target === overlay) cleanup(); });

        // --- PAYPAL ROUTE ---
        document.getElementById('mdui-cancel-paypal-btn').addEventListener('click', () => {
            window.open('https://www.paypal.com/myaccount/autopay/', '_blank');
            cleanup();
            this._showMessage('mdui-billing-msg', 'Opened PayPal. Please log in to manage your payments.', 'info');
        });

        // --- STRIPE ROUTE ---
        document.getElementById('mdui-cancel-stripe-btn').addEventListener('click', async () => {
            const btn = document.getElementById('mdui-cancel-stripe-btn');
            const originalHtml = btn.innerHTML;
            btn.innerHTML = '<i class="fa-solid fa-circle-notch fa-spin" style="width: 40px; font-size: 1.2rem;"></i> Loading Portal...';
            btn.style.pointerEvents = 'none';

            try {
                const { data, error } = await this._supabase.functions.invoke('create-stripe-portal', {
                    body: { return_url: window.location.href }
                });

                if (error || data?.error) throw new Error(error?.message || data?.error || "Failed to reach server.");
                if (!data?.url) throw new Error("Portal URL missing.");

                window.location.href = data.url;
                cleanup();

            } catch (err) {
                console.warn("[MobileUI] Stripe failed:", err.message);
                btn.innerHTML = originalHtml;
                btn.style.pointerEvents = 'auto';
                
                this._showMessage('mdui-billing-msg', `Redirection failed. Opening email support fallback.`, 'error');
                
                const userEmail = this._currentUser?.email || 'Unknown';
                const ifUsername = this._currentUser?.user_metadata?.if_username || 'Not Linked';
                const subject = encodeURIComponent("Cancellation Request - Pro Access (Mobile)");
                const body = encodeURIComponent(
                    `Hello Inflight Pro Support,\n\n` +
                    `I would like to cancel my Pro Access subscription.\n\n` +
                    `Account Details:\n` +
                    `• Email: ${userEmail}\n` +
                    `• IF Username: ${ifUsername}\n` +
                    `• Account ID: ${this._currentUser?.id}\n\n` +
                    `Sent from Mobile Dashboard.`
                );

                window.location.href = `mailto:inflightCustomer@gmail.com?subject=${subject}&body=${body}`;
                setTimeout(() => cleanup(), 1500);
            }
        });
    },

    /** Helper to show inline alerts inside cards (matching desktop flow) */
    _showMessage(msgDivId, msg, type) {
        const msgDiv = document.getElementById(msgDivId);
        if (msgDiv) {
            msgDiv.textContent = msg;
            msgDiv.style.display = 'flex';
            msgDiv.className = `mdui-alert mdui-alert-${type}`;
        }
    },

    _showDeleteConfirmation(flight) {
        return new Promise((resolve) => {
            const existing = document.getElementById('mdui-custom-confirm');
            if (existing) existing.remove();

            const overlay = document.createElement('div');
            overlay.id = 'mdui-custom-confirm';
            overlay.className = 'mdui-wrapper-layer mdui-open';
            overlay.style.zIndex = '10000';

            const route = `${flight.dep_icao || 'N/A'} &rarr; ${flight.arr_icao || 'N/A'}`;
            const cs = flight.callsign || 'UNK';

            overlay.innerHTML = `
                <div class="mdui-confirm-box mdui-fade-up">
                    <div class="mdui-confirm-header">
                        <div class="mdui-confirm-icon"><i class="fa-solid fa-plane-slash"></i></div>
                        <h3>Delete Dispatch</h3>
                    </div>
                    <div class="mdui-confirm-body">
                        <p>Are you sure you want to permanently delete this flight plan?</p>
                        <div class="mdui-confirm-flight-plate">
                            <span class="mdui-ticket-cs" style="margin: 0;">${cs}</span>
                            <span class="mdui-confirm-route">${route}</span>
                        </div>
                    </div>
                    <div class="mdui-confirm-actions">
                        <button class="mdui-btn-ghost" id="mdui-confirm-cancel">Keep</button>
                        <button class="mdui-btn-danger" id="mdui-confirm-proceed">Delete</button>
                    </div>
                </div>
            `;
            document.body.appendChild(overlay);

            const cleanup = (result) => {
                overlay.remove();
                resolve(result);
            };

            document.getElementById('mdui-confirm-cancel').addEventListener('click', () => cleanup(false));
            document.getElementById('mdui-confirm-proceed').addEventListener('click', () => cleanup(true));
        });
    },

    _resetFlightForm() {
        this._editingFlightId = null;
        const formTitle = document.getElementById('mdui-dispatch-form-title');
        if (formTitle) formTitle.innerHTML = `<i class="fa-solid fa-file-pen" style="color: var(--mdui-accent); margin-right: 6px;"></i> Dispatch Briefing`;
        const submitBtn = document.getElementById('mdui-submit-flight');
        if (submitBtn) submitBtn.innerHTML = `<i class="fa-solid fa-paper-plane"></i> File Plan`;
        const form = document.getElementById('mdui-flight-form');
        if (form) form.style.display = 'none';

        ['mdui-new-callsign', 'mdui-new-aircraft', 'mdui-new-dep', 'mdui-new-arr', 
         'mdui-new-dep-gate', 'mdui-new-arr-gate', 'mdui-new-time', 'mdui-new-duration', 
         'mdui-new-pax', 'mdui-new-fuel'].forEach(id => {
            const el = document.getElementById(id);
            if (el) el.value = '';
        });
    },

// ── Settings ──────────────────────────────────────────────────────────────
    _tabSettings() {
        const user       = this._currentUser;
        const name       = user?.user_metadata?.full_name || user?.user_metadata?.name || '';
        const email      = user?.email || '';
        const ifUsername = user?.user_metadata?.if_username || '';

        const accentSwatchesHTML = Object.entries(this._ACCENT_PRESETS).map(([key, preset]) => {
            const variant = this._theme === 'dark' ? preset.dark : preset.light;
            const isActive = key === this._accent;
            return `
                <button type="button"
                        class="mdui-accent-swatch ${isActive ? 'active' : ''}"
                        data-accent="${key}"
                        title="${preset.label}"
                        style="background:${variant.c};">
                    ${isActive ? '<i class="fa-solid fa-check"></i>' : ''}
                </button>`;
        }).join('');

        return `
            <div class="mdui-tab-header mdui-fade-up">
                <h2>Settings</h2>
                <p>Manage your profile, preferences, and security.</p>
            </div>

            <div class="mdui-settings-grid mdui-fade-up">
                <div class="mdui-card">
                    <div class="mdui-card-header"><h3>Profile Details</h3></div>
                    <div class="mdui-card-body">
                        <div class="mdui-input-group">
                            <label>Full Name</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-user mdui-input-icon"></i>
                                <input type="text" id="mdui-edit-name" class="mdui-input has-icon" value="${name}">
                            </div>
                        </div>
                        <div class="mdui-input-group">
                            <label>Email Address</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-envelope mdui-input-icon"></i>
                                <input type="email" class="mdui-input has-icon" value="${email}" disabled>
                            </div>
                        </div>
                        <div class="mdui-input-group">
                            <label>Infinite Flight Username</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-plane mdui-input-icon"></i>
                                <input type="text" id="mdui-edit-if" class="mdui-input has-icon" value="${ifUsername}">
                            </div>
                        </div>
                        <div class="mdui-input-group">
                            <label>New Password (Optional)</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-lock mdui-input-icon"></i>
                                <input type="password" id="mdui-edit-pw" class="mdui-input has-icon" placeholder="Leave blank to keep current">
                            </div>
                        </div>
                    </div>
                </div>

                <div class="mdui-card mdui-fade-up" style="animation-delay:0.04s;">
                    <div class="mdui-card-header"><h3>Pilot Identity</h3></div>
                    <div class="mdui-card-body">
                        <div class="mdui-input-group">
                            <label>Tagline</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-quote-left mdui-input-icon"></i>
                                <input type="text" id="mdui-edit-bio" class="mdui-input has-icon" maxlength="140"
                                       value="${(this._bio || '').replace(/"/g, '&quot;')}" placeholder="e.g. Long-haul addict · 787 type rating">
                            </div>
                        </div>
                        <div class="mdui-input-group" style="margin-bottom:0;">
                            <label>Cover Image URL</label>
                            <div class="mdui-input-wrap">
                                <i class="fa-solid fa-image mdui-input-icon"></i>
                                <input type="url" id="mdui-edit-cover" class="mdui-input has-icon"
                                       value="${(this._coverUrl || '').replace(/"/g, '&quot;')}" placeholder="https://...">
                            </div>
                        </div>
                    </div>
                </div>

                <div class="mdui-card mdui-fade-up" style="animation-delay:0.08s;">
                    <div class="mdui-card-header"><h3>Appearance</h3></div>
                    <div class="mdui-card-body">
                        <div class="mdui-input-group">
                            <label>Theme</label>
                            <div class="mdui-pill-row">
                                <label class="mdui-theme-option">
                                    <input type="radio" name="mdui-theme" value="light" ${this._theme === 'light' ? 'checked' : ''}>
                                    <i class="fa-solid fa-sun"></i>
                                    <span>Light</span>
                                </label>
                                <label class="mdui-theme-option">
                                    <input type="radio" name="mdui-theme" value="dark" ${this._theme === 'dark' ? 'checked' : ''}>
                                    <i class="fa-solid fa-moon"></i>
                                    <span>Dark</span>
                                </label>
                            </div>
                        </div>
                        <div class="mdui-input-group" style="margin-bottom:0;">
                            <label>Accent Color</label>
                            <div class="mdui-accent-grid" id="mdui-accent-grid">${accentSwatchesHTML}</div>
                        </div>
                    </div>
                </div>

                <div id="mdui-settings-msg" class="mdui-alert" style="display:none;"></div>
                <button class="mdui-btn-primary mdui-btn-block mdui-fade-up" id="mdui-save-btn" style="animation-delay:0.1s;">Save Changes</button>

                <div class="mdui-card mdui-fade-up" style="animation-delay:0.12s; margin-top: 16px;">
                    <div class="mdui-card-header"><h3>Billing</h3></div>
                    <div class="mdui-card-body">
                        <div class="mdui-plan-box">
                            <div class="mdui-plan-header">
                                <h4>${this._subscription.plan}</h4>
                                <span class="mdui-status-badge ${this._subscription.status === 'Active' ? 'pos' : 'neg'}">
                                    ${this._subscription.status}
                                </span>
                            </div>
                            <p class="mdui-plan-price">${this._subscription.price}</p>
                            <p class="mdui-plan-renewal">Next payment: ${this._subscription.nextPayment}</p>
                        </div>
                        <div id="mdui-billing-msg" class="mdui-alert" style="display:none; margin:12px 0 0;"></div>
                        <div class="mdui-billing-actions">
                            <button class="mdui-btn-secondary" id="mdui-billing-update">
                                <i class="fa-solid fa-credit-card"></i> Update payment method
                            </button>
                            <button class="mdui-btn-danger-outline" id="mdui-billing-cancel">
                                <i class="fa-solid fa-ban"></i> Cancel subscription
                            </button>
                        </div>
                    </div>
                </div>

                <div class="mdui-card mdui-fade-up" style="animation-delay:0.14s; margin-top: 16px;">
                    <div class="mdui-card-header"><h3>Support & Legal</h3></div>
                    <div class="mdui-card-body" style="padding: 12px;">
                        <div style="display: flex; flex-direction: column; gap: 10px;">
                            <a href="terms.html" target="_blank" class="mdui-action-link">
                                <span class="mdui-action-icon"><i class="fa-solid fa-file-contract"></i></span>
                                <span class="mdui-action-text">Terms of Use</span>
                            </a>
                            <a href="privacy.html" target="_blank" class="mdui-action-link">
                                <span class="mdui-action-icon"><i class="fa-solid fa-shield-halved"></i></span>
                                <span class="mdui-action-text">Privacy Policy</span>
                            </a>
                            <a href="https://discord.gg/9a6d8s4s" target="_blank" class="mdui-action-link">
                                <span class="mdui-action-icon" style="color: #5865F2;"><i class="fa-brands fa-discord"></i></span>
                                <span class="mdui-action-text">Discord Community</span>
                            </a>
                            <a href="mailto:inflightCustomer@gmail.com" class="mdui-action-link">
                                <span class="mdui-action-icon"><i class="fa-solid fa-envelope"></i></span>
                                <span class="mdui-action-text">Email Support</span>
                            </a>
                        </div>
                    </div>
                </div>

                <div class="mdui-fade-up" style="animation-delay:0.16s; padding-bottom: 8px; margin-top: 16px;">
                    <button class="mdui-btn-danger-outline" id="mdui-signout" style="width:100%;">
                        <i class="fa-solid fa-right-from-bracket"></i> Sign Out
                    </button>
                </div>
            </div>
        `;
    },

_updateLiveBanner() {
        const banner = document.getElementById('mdui-live-banner');
        if (!banner) return;

        if (!this._liveFlights || this._liveFlights.length === 0) {
            banner.innerHTML = '';
            banner.style.display = 'none';
            this._close3DHUD(); 
            return;
        }

        banner.style.display = 'block';

        const existingCarousel = banner.querySelector('.mdui-live-carousel');
        const currentScrollPos = existingCarousel ? existingCarousel.scrollLeft : 0;

const cardsHtmlArray = this._liveFlights.map((f, index) => {
            const props = f.properties || f;
            const flightIdStr = String(f.flightId || props.flightId);
            const altRaw = props.altitude || f.position?.alt_ft || 0;
            const alt = altRaw ? Math.round(altRaw).toLocaleString() : '—';
            const spd = props.speed || f.position?.gs_kt ? Math.round(props.speed || f.position?.gs_kt) : '—';
            const hdg = props.heading || f.position?.heading_deg ? String(Math.round(props.heading || f.position?.heading_deg)).padStart(3, '0') : '—';
            const dep = props.departureIcao || f.departureIcao || '----';
            const arr = props.arrivalIcao || f.arrivalIcao || '----';
            const cs = props.callsign || f.callsign || props.username || f.username || '—';
            const acft = props.aircraft?.aircraftName || f.aircraft?.aircraftName || 'Unknown Aircraft';

            let imageUrl = null;
            if (typeof window.getLiveFlightData === 'function') {
                const mapFlights = window.getLiveFlightData();
                const mapFlight = mapFlights.find(mapF => mapF.properties?.flightId === f.flightId);
                if (mapFlight?.properties?.communityImageUrl) {
                    imageUrl = mapFlight.properties.communityImageUrl;
                }
            }

            const canLaunch3D = altRaw > 3000;
            
            // Dual-layer image technique: Blurred background + contained sharp foreground
            const bgHTML = imageUrl 
                ? `<div class="mdui-live-bg-blur" style="background-image:url('${imageUrl}')"></div>
                   <div class="mdui-live-bg" style="background-image:url('${imageUrl}')"></div>` 
                : `<div class="mdui-live-bg mdui-live-bg-fallback"></div>`;

            // Explicit mobile-friendly text swap instead of relying on hover tooltips
            const actionButtonText = canLaunch3D 
                ? `<i class="fa-solid fa-vr-cardboard"></i> 3D HUD` 
                : `<i class="fa-solid fa-ban"></i> No 3D under 3K`;

            const actionButtonColor = canLaunch3D ? '#fff' : 'rgba(255, 255, 255, 0.45)';

            const actionButtonHTML = `
                <button class="mdui-btn-ghost mdui-launch-3d-btn" style="background: rgba(0,0,0,0.5); color: ${actionButtonColor}; border: 1px solid rgba(255,255,255,0.15); backdrop-filter: blur(6px); padding: 6px 10px; height: 32px; font-size: 0.75rem; font-weight: 600;" data-flight-id="${flightIdStr}" ${!canLaunch3D ? 'disabled' : ''}>
                    ${actionButtonText}
                </button>
            `;

            return `
                <div class="mdui-live-card mdui-fade-up" style="animation-delay:${index * 0.08}s;">
                    <div class="mdui-live-visual">
                        ${bgHTML}
                        <div class="mdui-live-overlay"></div>
                        <div class="mdui-3d-action-wrap">
                            ${actionButtonHTML}
                        </div>
                    </div>
                    <div class="mdui-live-content">
                        <div class="mdui-live-top">
                            <div class="mdui-live-route-pill">
                                <span class="mdui-live-icao">${dep}</span>
                                <i class="fa-solid fa-plane mdui-live-route-icon"></i>
                                <span class="mdui-live-icao">${arr}</span>
                            </div>
                            <div class="mdui-live-ident">
                                <span class="mdui-live-acft">${acft}</span>
                                <span class="mdui-live-cs">${cs}</span>
                            </div>
                        </div>
                        <div class="mdui-live-stats">
                            <div class="mdui-live-stat">
                                <span class="label">ALT</span>
                                <span class="value">${alt} <em>ft</em></span>
                            </div>
                            <div class="mdui-live-stat">
                                <span class="label">SPD</span>
                                <span class="value">${spd} <em>kt</em></span>
                            </div>
                            <div class="mdui-live-stat">
                                <span class="label">HDG</span>
                                <span class="value">${hdg}<em>°</em></span>
                            </div>
                        </div>
                    </div>
                </div>
            `;
        });

        banner.innerHTML = `<div class="mdui-live-carousel" style="cursor: grab;">${cardsHtmlArray.join('')}</div>`;

        const newCarousel = banner.querySelector('.mdui-live-carousel');
        if (newCarousel) {
            newCarousel.scrollLeft = currentScrollPos;
            
            let isDown = false, startX, scrollLeft;
            newCarousel.addEventListener('touchstart', (e) => {
                if (e.target.closest('button')) return;
                isDown = true;
                startX = e.touches[0].pageX;
                scrollLeft = newCarousel.scrollLeft;
            }, { passive: true });
            
            newCarousel.addEventListener('touchend', () => isDown = false, { passive: true });
            
            newCarousel.addEventListener('touchmove', (e) => {
                if (!isDown) return;
                const walk = (e.touches[0].pageX - startX);
                newCarousel.scrollLeft = scrollLeft - walk;
            }, { passive: true });
        }

        banner.querySelectorAll('.mdui-launch-3d-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const targetId = e.currentTarget.dataset.flightId;
                const targetFlight = this._liveFlights.find(f => String(f.flightId || f.properties?.flightId) === targetId);
                this._open3DHUD(targetFlight);
            });
        });
    },

    _extractPositionForViewer(flight) {
        const pos = flight?.position || {};
        let lat = pos.lat ?? pos.latitude ?? flight.latitude ?? null;
        let lon = pos.lon ?? pos.longitude ?? flight.longitude ?? null;

        if ((lat == null || lon == null) && typeof window.getLiveFlightData === 'function') {
            try {
                const mapFlights = window.getLiveFlightData();
                const mapFlight  = mapFlights.find(f => f.properties?.flightId === flight.flightId);
                const coords     = mapFlight?.geometry?.coordinates;
                if (Array.isArray(coords) && coords.length >= 2) {
                    if (lon == null) lon = coords[0];
                    if (lat == null) lat = coords[1];
                }
            } catch (_) {}
        }

        return {
            lat:         lat ?? 46.0,
            lon:         lon ?? 7.5,
            alt_ft:      pos.alt_ft      ?? flight.altitude ?? 35000,
            gs_kt:       pos.gs_kt       ?? flight.speed ?? 450,
            pitch_deg:   pos.pitch_deg   ?? 0,
            roll_deg:    pos.roll_deg    ?? 0,
            heading_deg: pos.heading_deg ?? pos.track ?? flight.heading ?? 45,
        };
    },

    _open3DHUD(flight) {
        if (!flight) return;
        this._close3DHUD(); // Clean up existing if any

        const overlay = document.createElement('div');
        overlay.id = 'mdui-3d-modal';
        overlay.style.position = 'fixed';
        overlay.style.inset = '0';
        overlay.style.zIndex = '10005';
        overlay.style.background = '#0a1628';
        
        try {
            if (document.documentElement.requestFullscreen) {
                document.documentElement.requestFullscreen().catch(()=>{});
            }
        } catch(e) {}

        try {
            if (screen.orientation && screen.orientation.lock) {
                screen.orientation.lock('landscape').catch(()=>{});
            }
        } catch(e) {}

        overlay.innerHTML = `
            <div class="mdui-3d-landscape-wrapper">
                <button class="mdui-btn-ghost" id="mdui-3d-close" style="position:absolute; top: 20px; right: 20px; z-index: 9999; background: rgba(0,0,0,0.6); color: #fff; border: 1px solid rgba(255,255,255,0.2); backdrop-filter: blur(4px); box-shadow: 0 4px 12px rgba(0,0,0,0.5);">
                    <i class="fa-solid fa-xmark"></i> Exit HUD
                </button>
                <div id="mdui-3d-host-container" style="width: 100%; height: 100%;">
                    ${typeof AircraftViewer3D !== 'undefined' ? AircraftViewer3D.getHTML() : ''}
                </div>
            </div>
        `;
        
        document.body.appendChild(overlay);
        this._active3DFlightId = String(flight.flightId || flight.properties?.flightId);

        setTimeout(() => {
            if (typeof AircraftViewer3D !== 'undefined') {
                AircraftViewer3D.init(flight.aircraft?.aircraftName || 'Unknown', this._extractPositionForViewer(flight))
                    .catch(err => console.warn('[MobileUI] 3D init failed:', err));
            }
        }, 300);

        document.getElementById('mdui-3d-close').addEventListener('click', () => {
            this._close3DHUD();
        });
    },

    _close3DHUD() {
        const overlay = document.getElementById('mdui-3d-modal');
        if (overlay) overlay.remove();
        this._active3DFlightId = null;
        
        try {
            if (typeof AircraftViewer3D !== 'undefined') {
                if (typeof AircraftViewer3D.destroy === 'function') {
                    AircraftViewer3D.destroy();
                } else if (window.Cesium && window.viewer) {
                    // Fallback cleanup if destroy() wasn't exposed
                    window.viewer.destroy(); 
                }
            }
        } catch (e) {}

        try {
            if (document.exitFullscreen) document.exitFullscreen().catch(()=>{});
            if (screen.orientation && screen.orientation.unlock) screen.orientation.unlock();
        } catch(e) {}
    },

    // ─── Drill-Down Modal ─────────────────────────────────────────────────────
    
    _showDrillDown(type, payload = {}) {
        const existing = document.getElementById('mdui-drill-modal');
        if (existing) existing.remove();

        const overlay = document.createElement('div');
        overlay.id = 'mdui-drill-modal';
        overlay.className = 'mdui-wrapper-layer';
        overlay.setAttribute('data-theme', this._theme);
        overlay.style.zIndex = '10001';

        const preset = this._ACCENT_PRESETS[this._accent] || this._ACCENT_PRESETS.caramel;
        const variant = this._theme === 'dark' ? preset.dark : preset.light;
        overlay.style.setProperty('--mdui-accent', variant.c);

        const body = this._getDrillDownBody(type, payload);

        overlay.innerHTML = `
            <div class="mdui-drill-box mdui-fade-up">
                <div class="mdui-drill-header">
                    <h3>${body.title}</h3>
                    <button class="mdui-close-btn" id="mdui-drill-close" aria-label="Close">
                        <i class="fa-solid fa-xmark"></i>
                    </button>
                </div>
                <div class="mdui-drill-body">${body.html}</div>
                ${body.actions ? `<div class="mdui-drill-actions">${body.actions}</div>` : ''}
            </div>
        `;

        document.body.appendChild(overlay);
        requestAnimationFrame(() => requestAnimationFrame(() => overlay.classList.add('mdui-open')));

        const cleanup = () => {
            overlay.classList.remove('mdui-open');
            setTimeout(() => overlay.remove(), 240);
        };

        document.getElementById('mdui-drill-close')?.addEventListener('click', cleanup);
        overlay.addEventListener('click', (e) => { if (e.target === overlay) cleanup(); });

        document.getElementById('mdui-drill-goto-traffic')?.addEventListener('click', () => {
            cleanup();
            if (payload.icao) window.dispatchEvent(new CustomEvent('puiFocusHub', { detail: { icao: payload.icao } }));
            this.switchTab('airspace-intel');
        });
        document.getElementById('mdui-drill-watch-pilot')?.addEventListener('click', () => {
            cleanup();
            this.switchTab('watchlist');
            setTimeout(() => {
                const input = document.getElementById('mdui-watchlist-input');
                if (input && payload.callsign) {
                    input.value = payload.callsign;
                    input.focus();
                }
            }, 120);
        });
    },

    _getDrillDownBody(type, payload) {
        const stats = this._ifData?.stats;
        const logbook = this._ifData?.logbook || [];

        if (type === 'grade') {
            const grade      = stats?.gradeDetails?.gradeIndex ?? '—';
            const violations = stats?.violations ?? '—';
            const landings   = stats?.landingCount ?? '—';
            const onlineHrs  = stats?.onlineFlightTime ? (stats.onlineFlightTime / 60).toFixed(1) + 'h' : '—';
            return {
                title: 'Pilot Grade Detail',
                html: `
                    <div class="mdui-drill-stat-row"><span>Current grade</span><strong>${grade}</strong></div>
                    <div class="mdui-drill-stat-row"><span>Online flight time</span><strong>${onlineHrs}</strong></div>
                    <div class="mdui-drill-stat-row"><span>Landing count</span><strong>${typeof landings === 'number' ? landings.toLocaleString() : landings}</strong></div>
                    <div class="mdui-drill-stat-row"><span>Violations</span><strong>${violations}</strong></div>
                `,
            };
        }

        if (type === 'xp') {
            const xp = stats?.totalXP ?? 0;
            const total = logbook.length;
            const totalMins = logbook.reduce((s, f) => s + (f.totalTime || 0), 0);
            const totalHours = (totalMins / 60).toFixed(1);
            return {
                title: 'XP Breakdown',
                html: `
                    <div class="mdui-drill-stat-row"><span>Total XP</span><strong>${xp.toLocaleString()}</strong></div>
                    <div class="mdui-drill-stat-row"><span>Across</span><strong>${total.toLocaleString()} flights · ${totalHours}h</strong></div>
                `,
            };
        }

        if (type === 'flights') {
            const byAcft = {};
            for (const f of logbook) {
                if (!f.aircraftId) continue;
                if (!byAcft[f.aircraftId]) byAcft[f.aircraftId] = { count: 0, minutes: 0 };
                byAcft[f.aircraftId].count   += 1;
                byAcft[f.aircraftId].minutes += (f.totalTime || 0);
            }
            const rows = Object.entries(byAcft).sort((a, b) => b[1].count - a[1].count).slice(0, 8);
            const totalCount = logbook.length || 1;
            const html = rows.length
                ? rows.map(([id, agg]) => {
                    const pct = Math.round((agg.count / totalCount) * 100);
                    return `
                        <div class="mdui-drill-bar-row">
                            <div class="mdui-drill-bar-label"><span>${id}</span><span>${agg.count} flights</span></div>
                            <div class="mdui-drill-bar-track"><div class="mdui-drill-bar-fill" style="width:${pct}%"></div></div>
                        </div>`;
                }).join('') : `<div class="mdui-empty">None</div>`;

            return { title: 'Flights by Aircraft', html };
        }

        if (type === 'icao') {
            const icao = (payload.icao || '').toUpperCase();
            const flights = this._currentAllFlights || [];
            const inbound  = flights.filter(f => (f.arrivalIcao   || '').toUpperCase() === icao).length;
            const outbound = flights.filter(f => (f.departureIcao || '').toUpperCase() === icao).length;
            return {
                title: `Airport · ${icao}`,
                html: `
                    <div class="mdui-drill-stat-row"><span>Live inbound</span><strong>${inbound}</strong></div>
                    <div class="mdui-drill-stat-row"><span>Live outbound</span><strong>${outbound}</strong></div>
                `,
                actions: `<button class="mdui-btn-primary" id="mdui-drill-goto-traffic">Open in Traffic</button>`,
            };
        }

        if (type === 'callsign') {
            const cs = payload.callsign || '';
            return {
                title: cs,
                html: `<p class="mdui-drill-note">${cs}</p>`,
                actions: `<button class="mdui-btn-primary" id="mdui-drill-watch-pilot">Add to Watchlist</button>`,
            };
        }
        return { title: '', html: '' };
    },

    // ─── Listeners ────────────────────────────────────────────────────────────

_attachListeners() {
    document.getElementById('mdui-close')?.addEventListener('click', () => this.close());

    // ─── Career Deep Dive (Dossier) Listeners ─────────────────────────
    // Mirrors the desktop implementation to enable internal module 
    // functionality (like logbook pagination or detailed stat toggles).
    if (this._activeTab === 'career-deep-dive') {
        if (typeof CareerModule !== 'undefined' && typeof CareerModule.attachListeners === 'function') {
            CareerModule.attachListeners(this._ifData, this._backendUrl, () => {
                // Callback to re-render the view if the module updates its data
                this._render();
            });
        }
    }

    const contentRoot = document.getElementById('mdui-content-area');
    if (contentRoot && !contentRoot.dataset.drillBound) {
        contentRoot.dataset.drillBound = '1';
        contentRoot.addEventListener('click', (e) => {
            
            // 1. Career Sub-Tab Switcher (Overview | Logbook | Records)
            const subTabBtn = e.target.closest('.mdui-career-tab-btn');
            if (subTabBtn) {
                e.stopPropagation();
                const targetTab = subTabBtn.dataset.tab;
                
                // Only re-render if the tab actually changed
                if (this._careerActiveTab !== targetTab) {
                    this._careerActiveTab = targetTab;
                    this._render(); 
                }
                return;
            }

            // 2. Existing Drill-Down Logic
            const target = e.target.closest('[data-drill]');
            if (target && contentRoot.contains(target)) {
                e.stopPropagation();
                this._showDrillDown(target.dataset.drill, { 
                    icao: target.dataset.icao, 
                    callsign: target.dataset.callsign 
                });
                return;
            }
        });
    }

        if (this._activeTab === 'onboarding') {
            document.querySelectorAll('input[name="onb-theme"]').forEach(r => {
                r.addEventListener('change', e => {
                    this._theme = e.target.value;
                    this._applyVisualPreferences();
                });
            });
            document.getElementById('mdui-onb-complete')?.addEventListener('click', async () => {
                const ifUsername    = document.getElementById('mdui-onb-username')?.value.trim();
                const selectedTheme = document.querySelector('input[name="onb-theme"]:checked')?.value || 'light';
                const btn           = document.getElementById('mdui-onb-complete');
                if (btn) { btn.disabled = true; btn.innerHTML = '<i class="fa-solid fa-circle-notch fa-spin"></i> Setting up…'; }
                try {
                    const { data, error } = await this._supabase.auth.updateUser({
                        data: { if_username: ifUsername, theme: selectedTheme, onboarding_complete: true },
                    });
                    if (error) throw error;
                    this._currentUser = data.user;
                    this._theme       = selectedTheme;
                    this._applyVisualPreferences();
                    if (ifUsername) this._fetchInfiniteFlightData(ifUsername);
                    this._activeTab = 'dashboard';
                    this._render();
                } catch (err) {
                    alert('Setup failed: ' + err.message);
                    if (btn) { btn.disabled = false; btn.textContent = 'Complete Setup'; }
                }
            });
        }

        if (this._activeTab === 'airspace-intel') {
            document.getElementById('mdui-intel-add')?.addEventListener('click', () => {
                const input = document.getElementById('mdui-intel-input');
                const icao  = input?.value.trim().toUpperCase();
                if (icao?.length >= 3 && this._airspaceNetwork) {
                    if (!this._airspaceNetwork._hubRegistry?.has(icao)) {
                        this._airspaceNetwork.registerNode(icao, 0, 0);
                    }
                    const nodes = Array.from(this._airspaceNetwork._activeNodes);
                    if (!nodes.includes(icao)) {
                        this._airspaceNetwork.setActiveNodes([...nodes, icao]);
                        if (input) input.value = '';
                        this._updateAirspaceDOM();
                    }
                }
            });
            document.getElementById('mdui-intel-input')?.addEventListener('keydown', e => {
                if (e.key === 'Enter') document.getElementById('mdui-intel-add')?.click();
            });
            this._bindNodeRemoveButtons();
        }

        if (this._activeTab === 'watchlist') {
            const addBtn = document.getElementById('mdui-watchlist-add-btn');
            const input = document.getElementById('mdui-watchlist-input');
            const dropdown = document.getElementById('mdui-watchlist-dropdown');

            const doAdd = async (override) => {
                const username = override || input?.value.trim();
                if (!username) return;
                input.value = '';
                if (dropdown) dropdown.style.display = 'none';

                if (this._watchlist.some(e => e.watched_username.toLowerCase() === username.toLowerCase())) {
                    this._showToast(`Already watching ${username}`, 'warn');
                    return;
                }
                try {
                    const { data, error } = await this._supabase.from('user_watchlist')
                        .insert([{ user_id: this._currentUser.id, watched_username: username }]).select().single();
                    if (error) throw error;
                    this._watchlist.unshift(data);
                    this._showToast(`Tracking ${username}`, 'success');
                    this._render();
                } catch (err) {
                    this._showToast(`Failed to add: ${err.message}`, 'error');
                }
            };

            addBtn?.addEventListener('click', () => doAdd());
            input?.addEventListener('keydown', (e) => { if (e.key === 'Enter') doAdd(); });
            
            input?.addEventListener('input', (e) => {
                const val = e.target.value.toLowerCase().trim();
                if (!val) { dropdown.style.display = 'none'; return; }
                const matches = (this._currentAllFlights || []).filter(f => f.username?.toLowerCase().includes(val));
                const unique = Array.from(new Set(matches.map(m => m.username))).slice(0, 4);
                if (unique.length === 0) { dropdown.style.display = 'none'; return; }
                
                dropdown.innerHTML = unique.map(un => `
                    <div class="mdui-autocomplete-item" data-username="${un}">
                        <i class="fa-solid fa-plane"></i> <span>${un}</span>
                    </div>`).join('');
                dropdown.style.display = 'block';
                
                dropdown.querySelectorAll('.mdui-autocomplete-item').forEach(item => {
                    item.addEventListener('click', (ev) => {
                        input.value = ev.currentTarget.dataset.username;
                        doAdd(ev.currentTarget.dataset.username);
                    });
                });
            });

            input?.addEventListener('blur', () => setTimeout(() => { if (dropdown) dropdown.style.display = 'none'; }, 200));

            document.querySelectorAll('.mdui-watchlist-remove-btn').forEach(btn => {
                btn.addEventListener('click', async (e) => {
                    const id = e.currentTarget.dataset.id;
                    try {
                        await this._supabase.from('user_watchlist').delete().eq('id', id);
                        this._watchlist = this._watchlist.filter(w => w.id !== id);
                        this._showToast(`Removed from watchlist`, 'info');
                        this._render();
                    } catch (err) {}
                });
            });

            const notifToggle = document.getElementById('mdui-watchlist-notif-toggle');
            notifToggle?.addEventListener('change', async () => {
                this._userPrefs.notification_watchlist_enabled = notifToggle.checked;
                await this._saveUserPreferences();
            });
        }

        if (this._activeTab === 'flight-plan') {
            const form = document.getElementById('mdui-flight-form');

            document.getElementById('mdui-toggle-form')?.addEventListener('click', () => {
                if (!form) return;
                this._resetFlightForm();
                form.style.display = 'block';
                form.scrollIntoView({ behavior: 'smooth', block: 'start' });
            });
            document.getElementById('mdui-cancel-form')?.addEventListener('click', () => {
                this._resetFlightForm();
            });

            // Auto EET
            const triggerEET = async () => {
                const dep = document.getElementById('mdui-new-dep')?.value.trim();
                const arr = document.getElementById('mdui-new-arr')?.value.trim();
                const durInput = document.getElementById('mdui-new-duration');
                if (dep?.length === 4 && arr?.length === 4 && !durInput.value) {
                    const mins = await this._autoCalculateRouteEET(dep, arr);
                    if (mins) durInput.value = mins;
                }
            };
            document.getElementById('mdui-new-dep')?.addEventListener('blur', triggerEET);
            document.getElementById('mdui-new-arr')?.addEventListener('blur', triggerEET);

            // Edit / Delete Delegation
            document.querySelector('.mdui-dispatch-list')?.addEventListener('click', async (e) => {
                const editBtn = e.target.closest('.mdui-ticket-edit-btn');
                const delBtn = e.target.closest('.mdui-ticket-delete-btn');

                if (editBtn) {
                    const id = editBtn.dataset.id;
                    const flight = this._flightPlansData.find(f => f.flight_id == id);
                    if (!flight) return;
                    
                    this._editingFlightId = id;
                    document.getElementById('mdui-dispatch-form-title').innerHTML = `<i class="fa-solid fa-pen"></i> Edit Dispatch`;
                    document.getElementById('mdui-submit-flight').innerHTML = `<i class="fa-solid fa-check"></i> Update`;
                    
                    document.getElementById('mdui-new-callsign').value = flight.callsign || '';
                    document.getElementById('mdui-new-aircraft').value = flight.aircraft_type || '';
                    document.getElementById('mdui-new-dep').value = flight.dep_icao || '';
                    document.getElementById('mdui-new-arr').value = flight.arr_icao || '';
                    document.getElementById('mdui-new-dep-gate').value = flight.dep_gate || '';
                    document.getElementById('mdui-new-arr-gate').value = flight.arr_gate || '';
                    
                    if (flight.dep_time) {
                        const dt = new Date(flight.dep_time);
                        document.getElementById('mdui-new-time').value = dt.toISOString().slice(0, 16);
                    }
                    document.getElementById('mdui-new-duration').value = flight.duration_minutes || '';
                    document.getElementById('mdui-new-pax').value = flight.passengers || '';
                    document.getElementById('mdui-new-fuel').value = flight.fuel_used || '';
                    
                    form.style.display = 'block';
                    form.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }

                if (delBtn) {
                    const flight = this._flightPlansData.find(f => f.flight_id == delBtn.dataset.id);
                    if (!flight) return;
                    const confirmed = await this._showDeleteConfirmation(flight);
                    if (confirmed) {
                        try {
                            await this._supabase.from('user_flights').delete().eq('flight_id', flight.flight_id);
                            this._showToast('Flight plan deleted.', 'success');
                            if (this._editingFlightId == flight.flight_id) this._resetFlightForm();
                            await this._fetchFlightPlans();
                        } catch (err) {
                            this._showToast('Error deleting.', 'error');
                        }
                    }
                }
            });

            document.getElementById('mdui-submit-flight')?.addEventListener('click', async () => {
                const callsign = document.getElementById('mdui-new-callsign')?.value.trim();
                const aircraft = document.getElementById('mdui-new-aircraft')?.value.trim();
                const depIcao  = document.getElementById('mdui-new-dep')?.value.trim().toUpperCase();
                const arrIcao  = document.getElementById('mdui-new-arr')?.value.trim().toUpperCase();
                const duration = parseInt(document.getElementById('mdui-new-duration')?.value);
                const depTime  = document.getElementById('mdui-new-time')?.value;
                const depGate  = document.getElementById('mdui-new-dep-gate')?.value.trim();
                const arrGate  = document.getElementById('mdui-new-arr-gate')?.value.trim();
                const pax      = parseInt(document.getElementById('mdui-new-pax')?.value) || null;
                const fuel     = parseInt(document.getElementById('mdui-new-fuel')?.value) || null;
                const msgDiv   = document.getElementById('mdui-flight-msg');
                const btn      = document.getElementById('mdui-submit-flight');

                if (!callsign || !aircraft || !depIcao || !arrIcao || !depTime || isNaN(duration)) {
                    if (msgDiv) { msgDiv.textContent = 'Please fill in all required fields.'; msgDiv.className = 'mdui-alert mdui-alert-error'; msgDiv.style.display = 'block'; }
                    return;
                }

                if (btn) { btn.disabled = true; btn.innerHTML = '<i class="fa-solid fa-circle-notch fa-spin"></i> Filing…'; }

                try {
                    const payload = {
                        user_id: this._currentUser.id,
                        callsign, aircraft_type: aircraft,
                        dep_icao: depIcao, arr_icao: arrIcao,
                        dep_gate: depGate || null, arr_gate: arrGate || null,
                        dep_time: new Date(depTime).toISOString(),
                        duration_minutes: duration,
                        passengers: pax, fuel_used: fuel,
                    };

                    if (this._editingFlightId) {
                        const { error } = await this._supabase.from('user_flights').update(payload).eq('flight_id', this._editingFlightId);
                        if (error) throw error;
                        this._showToast('Flight plan updated!', 'success');
                    } else {
                        const { error } = await this._supabase.from('user_flights').insert([payload]);
                        if (error) throw error;
                        this._showToast('Flight plan filed!', 'success');
                    }
                    
                    await this._fetchFlightPlans();
                    setTimeout(() => { this._resetFlightForm(); this._render(); }, 1200);
                } catch (err) {
                    if (msgDiv) { msgDiv.textContent = err.message || 'Failed to file plan.'; msgDiv.className = 'mdui-alert mdui-alert-error'; msgDiv.style.display = 'block'; }
                    if (btn) { btn.disabled = false; btn.innerHTML = this._editingFlightId ? 'Update' : '<i class="fa-solid fa-paper-plane"></i> File Plan'; }
                }
            });
        }

        if (this._activeTab === 'settings') {
            document.querySelectorAll('input[name="mdui-theme"]').forEach(r => {
                r.addEventListener('change', e => {
                    this._theme = e.target.value;
                    this._applyVisualPreferences();
                    
                    document.querySelectorAll('.mdui-accent-swatch').forEach(sw => {
                        const key = sw.dataset.accent;
                        const preset = this._ACCENT_PRESETS[key];
                        if(preset) {
                            const variant = this._theme === 'dark' ? preset.dark : preset.light;
                            sw.style.background = variant.c;
                        }
                    });
                });
            });

            document.querySelectorAll('.mdui-accent-swatch').forEach(btn => {
                btn.addEventListener('click', () => {
                    const key = btn.dataset.accent;
                    if (!key) return;
                    this._accent = key;
                    this._applyVisualPreferences();
                    
                    document.querySelectorAll('.mdui-accent-swatch').forEach(sw => {
                        sw.classList.toggle('active', sw.dataset.accent === key);
                        sw.innerHTML = sw.dataset.accent === key ? '<i class="fa-solid fa-check"></i>' : '';
                    });
                });
            });

            document.getElementById('mdui-save-btn')?.addEventListener('click', async () => {
                const newName       = document.getElementById('mdui-edit-name')?.value.trim();
                const newIfUsername = document.getElementById('mdui-edit-if')?.value.trim();
                const newBio        = document.getElementById('mdui-edit-bio')?.value.trim();
                const newCover      = document.getElementById('mdui-edit-cover')?.value.trim();
                const newPassword   = document.getElementById('mdui-edit-pw')?.value;
                const btn           = document.getElementById('mdui-save-btn');
                const msgDiv        = document.getElementById('mdui-settings-msg');

                const updates = { data: { 
                    full_name: newName, name: newName, 
                    if_username: newIfUsername, 
                    theme: this._theme, 
                    accent_color: this._accent,
                    pilot_bio: newBio,
                    cover_url: newCover
                }};
                
                this._bio = newBio;
                this._coverUrl = newCover;

                if (newPassword) updates.password = newPassword;

                if (btn) { btn.disabled = true; btn.innerHTML = '<i class="fa-solid fa-circle-notch fa-spin"></i> Saving…'; }

                try {
                    const { data, error } = await this._supabase.auth.updateUser(updates);
                    if (error) throw error;
                    this._currentUser = data.user;
                    if (newIfUsername && newIfUsername !== this._currentUser?.user_metadata?.if_username) {
                        this._fetchInfiniteFlightData(newIfUsername);
                    }
                    if (msgDiv) { msgDiv.textContent = 'Settings saved!'; msgDiv.className = 'mdui-alert mdui-alert-success'; msgDiv.style.display = 'flex'; }
                    setTimeout(() => { if (msgDiv) msgDiv.style.display = 'none'; if (btn) { btn.disabled = false; btn.textContent = 'Save Changes'; } }, 3000);
                } catch (err) {
                    if (msgDiv) { msgDiv.textContent = err.message || 'Failed to save.'; msgDiv.className = 'mdui-alert mdui-alert-error'; msgDiv.style.display = 'flex'; }
                    if (btn) { btn.disabled = false; btn.textContent = 'Save Changes'; }
                }
            });

document.getElementById('mdui-billing-cancel')?.addEventListener('click', () => {
    this._showCancellationModal();
});

            document.getElementById('mdui-signout')?.addEventListener('click', async () => {
                if (this._supabase) { await this._supabase.auth.signOut(); this.close(); }
            });
        }
    },

    // ─── Styles ───────────────────────────────────────────────────────────────

    _injectStyles() {
        if (document.getElementById('mdui-styles')) return;

        const css = `
            @import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700;800&family=JetBrains+Mono:wght@500;700&display=swap');

            /* ── DOSSIER SUB-TABS ── */
            .mdui-sub-tab-bar {
                display: flex;
                background: var(--mdui-surface);
                border: 1px solid var(--mdui-border);
                padding: 4px;
                border-radius: 12px;
                margin-bottom: 24px;
                gap: 4px;
            }
            .mdui-career-tab-btn {
                flex: 1;
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
                padding: 8px 0;
                border: none;
                background: transparent;
                color: var(--mdui-muted);
                font-family: var(--mdui-font-sans);
                font-size: 0.78rem;
                font-weight: 600;
                border-radius: 8px;
                cursor: pointer;
                transition: 0.2s cubic-bezier(0.16, 1, 0.3, 1);
            }
            .mdui-career-tab-btn i { font-size: 0.85rem; }
            .mdui-career-tab-btn.active {
                background: var(--mdui-card);
                color: var(--mdui-accent);
                box-shadow: 0 2px 8px rgba(0,0,0,0.06);
            }
            #mdui-career-content-host {
                min-height: 200px;
            }

            /* ── Full-Screen 3D Modal ── */
        .mdui-3d-landscape-wrapper {
            position: absolute;
            width: 100%;
            height: 100%;
            top: 0; left: 0;
            background: #0a1628;
            overflow: hidden;
        }
        @media screen and (orientation: portrait) {
            .mdui-3d-landscape-wrapper {
                width: 100vh;
                height: 100vw;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%) rotate(90deg);
                transform-origin: center center;
            }
            #mdui-3d-close {
                top: auto !important;
                bottom: 20px !important;
                right: 20px !important;
            }
        }

            /* ── Shell & Theme Variables ── */
            #mdui-shell {
                --mdui-bg:        #f5f1ea;
                --mdui-surface:   #faf6ef;
                --mdui-card:      #ffffff;
                --mdui-card-elev: #fffbf3;
                --mdui-input:     #ffffff;
                --mdui-border:    rgba(26, 22, 18, 0.08);
                --mdui-border-strong: rgba(26, 22, 18, 0.14);
                --mdui-hover:     rgba(26, 22, 18, 0.04);
                --mdui-text:      #1a1612;
                --mdui-muted:     #6b6258;
                --mdui-tertiary:  #9a9088;
                --mdui-on-accent: #fffbf3;

                --mdui-accent:    #b88553;
                --mdui-accent-hover: #a87543;
                --mdui-accent-soft: rgba(184, 133, 83, 0.10);
                --mdui-accent-glow: rgba(184, 133, 83, 0.18);

                --mdui-success:   #4a8c5a;
                --mdui-success-soft: rgba(74, 140, 90, 0.12);
                --mdui-danger:    #c25a5a;
                --mdui-danger-soft: rgba(194, 90, 90, 0.10);
                --mdui-warn:      #c8893d;
                --mdui-warn-soft: rgba(200, 137, 61, 0.12);
                --mdui-info:      #5a82c8;
                --mdui-info-soft: rgba(90, 130, 200, 0.10);

                --mdui-tab-h:     68px;
                --mdui-top-h:     60px;
                --mdui-radius:    16px;
                --mdui-font-sans: 'DM Sans', system-ui, -apple-system, sans-serif;
                --mdui-font-mono: 'JetBrains Mono', ui-monospace, 'SF Mono', monospace;
                --mdui-shadow-card: 0 1px 2px rgba(26, 22, 18, 0.04);
                --mdui-shadow-pop:  0 8px 24px -6px rgba(28, 22, 16, 0.18);

                position: fixed; inset: 0; z-index: 9998;
                background: var(--mdui-bg); display: flex; flex-direction: column;
                font-family: var(--mdui-font-sans); color: var(--mdui-text);
                transform: translateY(100%); transition: transform 0.4s cubic-bezier(0.16, 1, 0.3, 1);
            }
            #mdui-shell.mdui-open { transform: translateY(0); }

            #mdui-shell[data-theme="dark"] {
                --mdui-bg:        #1a1612; --mdui-surface:   #221d17;
                --mdui-card:      #2a241d; --mdui-card-elev: #322b22;
                --mdui-input:     #1f1a14;
                --mdui-border:    rgba(255, 248, 235, 0.08);
                --mdui-border-strong: rgba(255, 248, 235, 0.14);
                --mdui-hover:     rgba(255, 248, 235, 0.04);
                --mdui-text:      #f0e9dd; --mdui-muted:     #9a8e7e;
                --mdui-tertiary:  #6e6457; --mdui-on-accent: #1a1612;

                --mdui-success:   #6db380; --mdui-success-soft: rgba(109, 179, 128, 0.16);
                --mdui-danger:    #d97676; --mdui-danger-soft: rgba(217, 118, 118, 0.14);
                --mdui-warn:      #d9a563; --mdui-warn-soft: rgba(217, 165, 99, 0.16);
                --mdui-info:      #7da0e6; --mdui-info-soft: rgba(125, 160, 230, 0.14);
                --mdui-shadow-card: 0 1px 2px rgba(0, 0, 0, 0.2);
                --mdui-shadow-pop:  0 8px 24px -6px rgba(0, 0, 0, 0.4);
            }

            .mdui-wrapper-layer {
                position: fixed; inset: 0; z-index: 10000;
                background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center;
                opacity: 0; visibility: hidden; transition: opacity 0.2s; padding: 20px;
            }
            .mdui-wrapper-layer.mdui-open { opacity: 1; visibility: visible; }

            #mdui-screen { display: flex; flex-direction: column; flex: 1; min-height: 0; position: relative; }

            .mdui-eyebrow { font-size: 0.66rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.1em; color: var(--mdui-tertiary); }
            .mdui-mono-meta { font-family: var(--mdui-font-mono); font-size: 0.74rem; color: var(--mdui-muted); font-weight: 600; }

            .mdui-top-bar { height: var(--mdui-top-h); min-height: var(--mdui-top-h); display: flex; align-items: center; padding: 0 20px; gap: 12px; flex-shrink: 0; z-index: 10; background: var(--mdui-bg); }
            .mdui-avatar { width: 32px; height: 32px; background: var(--mdui-accent); color: var(--mdui-on-accent); border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 0.75rem; font-weight: 700; letter-spacing: 0.02em; flex-shrink: 0; }
            .mdui-top-title { font-weight: 700; font-size: 1.05rem; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--mdui-text); }
            .mdui-close-btn { width: 36px; height: 36px; border: 1px solid var(--mdui-border); border-radius: 10px; background: var(--mdui-card); color: var(--mdui-muted); display: flex; align-items: center; justify-content: center; font-size: 0.85rem; cursor: pointer; flex-shrink: 0; transition: 0.14s; }
            .mdui-close-btn:hover { background: var(--mdui-danger-soft); color: var(--mdui-danger); border-color: transparent; }

            .mdui-content { flex: 1; overflow-y: auto; min-height: 0; padding: 10px 20px calc(var(--mdui-tab-h) + env(safe-area-inset-bottom) + 20px); -webkit-overflow-scrolling: touch; scrollbar-width: none; }
            .mdui-content::-webkit-scrollbar { display: none; }

            #mdui-tabbar { position: absolute; bottom: 0; left: 0; right: 0; height: calc(var(--mdui-tab-h) + env(safe-area-inset-bottom)); padding-bottom: env(safe-area-inset-bottom); background: var(--mdui-card); border-top: 1px solid var(--mdui-border); display: flex; z-index: 9999; box-shadow: 0 -4px 24px rgba(0,0,0,0.03); }
            .mdui-tab-btn { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 5px; border: none; background: none; color: var(--mdui-muted); font-size: 0.65rem; font-weight: 600; cursor: pointer; transition: color 0.14s; }
            .mdui-tab-btn i { font-size: 1.1rem; transition: transform 0.14s; }
            .mdui-tab-btn.active { color: var(--mdui-accent); }
            .mdui-tab-btn.active i { transform: translateY(-1px); }
            .mdui-tab-badge { position: absolute; top: -4px; right: -8px; min-width: 16px; height: 16px; padding: 0 4px; background: var(--mdui-success); color: #fff; font-size: 0.6rem; font-weight: 800; border-radius: 999px; display: flex; align-items: center; justify-content: center; box-shadow: 0 0 0 2px var(--mdui-card); }

            .mdui-tab-header { margin-bottom: 24px; }
            .mdui-tab-header h2 { margin: 0 0 4px 0; font-size: 1.6rem; font-weight: 700; color: var(--mdui-text); letter-spacing: -0.02em; }
            .mdui-tab-header p { margin: 0; color: var(--mdui-muted); font-size: 0.92rem; line-height: 1.45; }

            .mdui-card { background: var(--mdui-card); border: 1px solid var(--mdui-border); border-radius: var(--mdui-radius); box-shadow: var(--mdui-shadow-card); margin-bottom: 16px; overflow: hidden; }
            .mdui-card-header { padding: 16px 20px; border-bottom: 1px solid var(--mdui-border-light); }
            .mdui-card-header h3 { margin: 0; font-size: 0.95rem; font-weight: 600; color: var(--mdui-text); display: flex; align-items: center; }
            .mdui-card-body { padding: 20px; }
            .mdui-card-eyebrow { font-size: 0.66rem; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--mdui-tertiary); margin-bottom: 14px; }
            .mdui-card-footer { margin-top: 16px; padding-top: 16px; border-top: 1px solid var(--mdui-border-light); display: flex; justify-content: flex-end; }

            .mdui-alert { padding: 12px 14px; border-radius: 10px; font-size: 0.84rem; font-weight: 500; display: flex; align-items: center; gap: 8px; }
            .mdui-alert-error   { background: var(--mdui-danger-soft);  color: var(--mdui-danger); }
            .mdui-alert-success { background: var(--mdui-success-soft); color: var(--mdui-success); }
            .mdui-alert-warn    { background: var(--mdui-warn-soft);    color: var(--mdui-warn); }
            .mdui-alert-info    { background: var(--mdui-info-soft);    color: var(--mdui-info); }

            .mdui-status-badge { padding: 3px 10px; border-radius: 999px; font-size: 0.66rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; }
            .mdui-status-badge.pos { background: var(--mdui-success-soft); color: var(--mdui-success); }
            .mdui-status-badge.neg { background: var(--mdui-danger-soft); color: var(--mdui-danger); }

            .mdui-mini-tag { display: inline-flex; align-items: center; gap: 5px; padding: 3px 8px; border-radius: 6px; font-size: 0.62rem; font-weight: 700; letter-spacing: 0.04em; }
            .mdui-mini-tag-row { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 12px; }

            .mdui-input-group { margin-bottom: 16px; }
            .mdui-input-group label { display: block; font-size: 0.72rem; font-weight: 600; color: var(--mdui-muted); margin-bottom: 6px; }
            .mdui-input-wrap { position: relative; display: flex; align-items: center; }
            .mdui-input-icon { position: absolute; left: 12px; color: var(--mdui-tertiary); font-size: 0.82rem; pointer-events: none; }
            .mdui-input { width: 100%; padding: 10px 12px; background: var(--mdui-input); border: 1px solid var(--mdui-border); border-radius: 10px; color: var(--mdui-text); font-family: var(--mdui-font-sans); font-size: 0.88rem; outline: none; transition: 0.14s; box-sizing: border-box; }
            .mdui-input.has-icon { padding-left: 36px; }
            .mdui-input:focus { border-color: var(--mdui-accent); box-shadow: 0 0 0 3px var(--mdui-accent-soft); }
            .mdui-input:disabled { opacity: 0.5; cursor: not-allowed; }
            .mdui-icao-input { font-family: var(--mdui-font-mono); text-transform: uppercase; font-weight: 700; letter-spacing: 0.05em; }
            .mdui-help { font-size: 0.72rem; color: var(--mdui-tertiary); margin-top: 6px; line-height: 1.4; }
            .mdui-select { appearance: none; cursor: pointer; }

            .mdui-btn-primary, .mdui-btn-secondary, .mdui-btn-danger-outline, .mdui-btn-ghost, .mdui-btn-danger { display: inline-flex; align-items: center; justify-content: center; gap: 8px; padding: 10px 18px; border-radius: 10px; font-family: var(--mdui-font-sans); font-size: 0.86rem; font-weight: 600; cursor: pointer; transition: 0.14s; }
            .mdui-btn-primary { background: var(--mdui-accent); color: var(--mdui-on-accent); border: 1px solid transparent; box-shadow: 0 1px 2px rgba(0,0,0,0.04); }
            .mdui-btn-primary:hover { background: var(--mdui-accent-hover); box-shadow: 0 4px 12px var(--mdui-accent-glow); }
            .mdui-btn-primary:disabled { opacity: 0.55; cursor: not-allowed; }
            .mdui-btn-block { width: 100%; padding: 12px 20px; }
            .mdui-btn-secondary { background: var(--mdui-card); color: var(--mdui-text); border: 1px solid var(--mdui-border); width: 100%; }
            .mdui-btn-danger-outline { background: transparent; color: var(--mdui-danger); border: 1px solid var(--mdui-danger-soft); width: 100%; }
            .mdui-btn-ghost { background: transparent; color: var(--mdui-muted); border: 1px solid var(--mdui-border); font-size: 0.78rem; padding: 7px 14px; border-radius: 9px; }
            .mdui-btn-ghost:hover { background: var(--mdui-hover); color: var(--mdui-text); }
            .mdui-btn-danger { background: var(--mdui-danger); color: #fff; border: 1px solid transparent; }
            .mdui-icon-btn { width: 32px; height: 32px; border-radius: 8px; border: 1px solid var(--mdui-border); background: var(--mdui-card); color: var(--mdui-muted); cursor: pointer; transition: 0.14s; }
            .mdui-icon-btn:hover { background: var(--mdui-hover); color: var(--mdui-text); }

            @keyframes mdui-fade-up { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
            .mdui-fade-up { animation: mdui-fade-up 0.28s cubic-bezier(0.16, 1, 0.3, 1) both; }
            @keyframes mdui-pulse { 0%, 100% { opacity: 0.55; } 50% { opacity: 0.85; } }
            .mdui-skel { background: var(--mdui-border); border-radius: 6px; animation: mdui-pulse 1.6s ease-in-out infinite; }
            @keyframes mdui-toast-in { from { opacity: 0; transform: translateY(8px) scale(0.98); } to { opacity: 1; transform: translateY(0) scale(1); } }

            .mdui-empty-state { text-align: center; padding: 40px 20px; background: var(--mdui-card); border: 1px dashed var(--mdui-border); border-radius: var(--mdui-radius); }
            .mdui-empty-state i { font-size: 2.2rem; color: var(--mdui-tertiary); opacity: 0.6; margin-bottom: 14px; display: block; }
            .mdui-empty-state h4 { margin: 0 0 6px 0; color: var(--mdui-text); font-size: 1rem; font-weight: 600; }
            .mdui-empty-state p { margin: 0; color: var(--mdui-muted); font-size: 0.84rem; line-height: 1.5; }
            .mdui-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; padding: 28px 0; color: var(--mdui-muted); font-size: 0.85rem; font-weight: 500; text-align: center; }

            /* ── TOASTS ── */
            .mdui-toast-container { position: fixed; bottom: 80px; left: 20px; right: 20px; z-index: 10000; display: flex; flex-direction: column-reverse; gap: 10px; pointer-events: none; }
            .mdui-toast { background: var(--mdui-card); border: 1px solid var(--mdui-border); color: var(--mdui-text); padding: 12px 16px; border-radius: var(--mdui-radius); font-size: 0.84rem; font-weight: 500; line-height: 1.45; box-shadow: var(--mdui-shadow-pop); pointer-events: auto; animation: mdui-toast-in 240ms ease-out; transition: 0.24s; }
            .mdui-toast-out { opacity: 0; transform: translateY(8px); }
            .mdui-toast-info { border-color: var(--mdui-info-soft); }
            .mdui-toast-success { background: var(--mdui-success-soft); border-color: var(--mdui-success-soft); color: var(--mdui-success); }
            .mdui-toast-error { background: var(--mdui-danger-soft); border-color: var(--mdui-danger-soft); color: var(--mdui-danger); }
            .mdui-toast-warn { background: var(--mdui-warn-soft); border-color: var(--mdui-warn-soft); color: var(--mdui-warn); }

            /* ── DASHBOARD ── */
            .mdui-cc-greeting { display: flex; justify-content: space-between; align-items: flex-end; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--mdui-border); }
            .mdui-greeting-name { font-size: 1.7rem; font-weight: 700; margin: 0 0 6px 0; color: var(--mdui-text); line-height: 1.1; letter-spacing: -0.025em; }
            .mdui-greeting-date { font-size: 0.78rem; font-weight: 500; color: var(--mdui-tertiary); text-align: right; white-space: nowrap; }
            .mdui-stat-strip { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; color: var(--mdui-muted); font-size: 0.8rem; font-weight: 500; }
            .mdui-strip-sep { opacity: 0.4; }

            .mdui-dispatch-mini { padding: 0 20px 20px; }
            .mdui-dispatch-route { display: flex; align-items: center; justify-content: space-between; padding-bottom: 12px; border-bottom: 1px solid var(--mdui-border-light); margin-bottom: 12px; gap: 10px; }
            .mdui-dispatch-airport { display: flex; flex-direction: column; gap: 4px; }
            .mdui-dispatch-icao { font-family: var(--mdui-font-mono); font-size: 1.5rem; font-weight: 700; line-height: 1; color: var(--mdui-text); letter-spacing: -0.02em; }
            .mdui-dispatch-gate { font-size: 0.65rem; color: var(--mdui-tertiary); font-weight: 600; }
            .mdui-dispatch-center { display: flex; flex-direction: column; align-items: center; gap: 4px; color: var(--mdui-tertiary); flex: 1; font-size: 0.66rem; font-weight: 600; }
            .mdui-dispatch-plane { color: var(--mdui-accent); font-size: 0.85rem; }
            .mdui-dispatch-meta-row { display: flex; flex-direction: column; gap: 4px; font-size: 0.8rem; font-weight: 500; color: var(--mdui-muted); }

            .mdui-flight-row { display: flex; align-items: center; gap: 12px; padding: 12px 20px; border-bottom: 1px solid var(--mdui-border-light); }
            .mdui-flight-row:last-child { border-bottom: none; }
            .mdui-flight-route { display: flex; align-items: center; gap: 8px; flex: 1; min-width: 0; }
            .mdui-icao { font-family: var(--mdui-font-mono); font-size: 0.86rem; font-weight: 700; color: var(--mdui-text); letter-spacing: 0.02em; }
            .mdui-arrow { color: var(--mdui-tertiary); font-size: 0.7rem; }
            .mdui-flight-meta { display: flex; align-items: center; gap: 5px; font-size: 0.7rem; color: var(--mdui-muted); font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .mdui-flight-time { font-size: 0.68rem; font-weight: 600; color: var(--mdui-tertiary); white-space: nowrap; flex-shrink: 0; }

            .mdui-live-card { background: var(--mdui-card); border: 1px solid var(--mdui-border); border-radius: var(--mdui-radius); overflow: hidden; box-shadow: var(--mdui-shadow-pop); display: flex; flex-direction: column; margin-bottom: 24px; height: auto; }
            .mdui-live-visual { position: relative; height: 170px; background: #0a0e14; overflow: hidden; display: flex; align-items: center; justify-content: center; }
            .mdui-live-bg { position: absolute; inset: 0; background-size: contain; background-repeat: no-repeat; background-position: center; z-index: 2; }
            .mdui-live-bg-blur { position: absolute; inset: -20px; background-size: cover; background-position: center; filter: blur(16px) brightness(0.6); z-index: 1; }
            .mdui-live-bg-fallback { background: linear-gradient(135deg, #2a3445 0%, #1a2030 60%, #14181f 100%); z-index: 1; }
            .mdui-live-overlay { position: absolute; inset: 0; background: linear-gradient(to bottom, rgba(0,0,0,0.5) 0%, transparent 40%); z-index: 3; pointer-events: none; }
            .mdui-3d-action-wrap { position: absolute; top: 12px; right: 12px; z-index: 4; }
            
            .mdui-live-content { display: flex; flex-direction: column; padding: 16px 20px; background: var(--mdui-card); border-top: 1px solid var(--mdui-border-light); z-index: 5; }
            .mdui-live-top { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
            .mdui-live-route-pill { display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; background: var(--mdui-surface); border: 1px solid var(--mdui-border); border-radius: 999px; }
            .mdui-live-icao { font-family: var(--mdui-font-mono); font-size: 0.92rem; font-weight: 700; color: var(--mdui-text); letter-spacing: 0.04em; }
            .mdui-live-route-icon { color: var(--mdui-accent); font-size: 0.7rem; }
            .mdui-live-ident { display: flex; flex-direction: column; align-items: flex-end; text-align: right; }
            .mdui-live-acft { font-size: 0.92rem; font-weight: 700; color: var(--mdui-text); }
            .mdui-live-cs { font-family: var(--mdui-font-mono); font-size: 0.74rem; color: var(--mdui-muted); font-weight: 600; margin-top: 2px; }
            
            .mdui-live-stats { display: grid; grid-template-columns: repeat(3, 1fr); background: var(--mdui-surface); border: 1px solid var(--mdui-border); border-radius: 12px; overflow: hidden; }
            .mdui-live-stat { display: flex; flex-direction: column; gap: 2px; padding: 10px 14px; border-right: 1px solid var(--mdui-border); align-items: center; }
            .mdui-live-stat:last-child { border-right: none; }
            .mdui-live-stat .label { font-size: 0.56rem; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--mdui-tertiary); }
            .mdui-live-stat .value { font-family: var(--mdui-font-mono); font-size: 1.05rem; font-weight: 700; color: var(--mdui-text); display: flex; align-items: baseline; gap: 3px; line-height: 1; }
            .mdui-live-stat .value em { font-style: normal; font-size: 0.62rem; color: var(--mdui-muted); font-weight: 600; }

            /* ── CAREER / TRENDS ── */
            .mdui-cover-banner { width: 100%; height: 160px; margin-bottom: 24px; border-radius: var(--mdui-radius); background-size: cover; background-position: center; position: relative; overflow: hidden; border: 1px solid var(--mdui-border); }
            .mdui-cover-overlay { position: absolute; inset: 0; display: flex; flex-direction: column; justify-content: flex-end; padding: 18px 20px; background: linear-gradient(to top, rgba(0,0,0,0.62) 0%, rgba(0,0,0,0.18) 55%, transparent 100%); color: #fff; }
            .mdui-cover-name { font-size: 1.4rem; font-weight: 700; letter-spacing: -0.01em; }
            .mdui-cover-bio { margin-top: 4px; font-size: 0.88rem; opacity: 0.92; }
            .mdui-bio-strip { display: flex; align-items: center; gap: 10px; padding: 12px 16px; margin-bottom: 24px; background: var(--mdui-accent-soft); border: 1px solid var(--mdui-accent-soft); border-radius: var(--mdui-radius); color: var(--mdui-muted); font-size: 0.92rem; font-style: italic; }

            .mdui-mini-stat-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
            .mdui-mini-stat-card { background: var(--mdui-card); border: 1px solid var(--mdui-border); border-radius: var(--mdui-radius); padding: 16px 12px; display: flex; flex-direction: column; align-items: center; text-align: center; gap: 8px; box-shadow: var(--mdui-shadow-card); }
            .mdui-drillable-card { cursor: pointer; transition: 0.14s; }
            .mdui-drillable-card:hover { transform: translateY(-1px); border-color: var(--mdui-accent-soft); }
            .mdui-mini-icon { width: 44px; height: 44px; border-radius: 12px; display: grid; place-items: center; font-size: 1.1rem; flex-shrink: 0; }
            .mdui-mini-stat-card[data-tone="indigo"]  .mdui-mini-icon { background: rgba(99,102,241,0.10);  color: #6366f1; }
            .mdui-mini-stat-card[data-tone="violet"]  .mdui-mini-icon { background: rgba(139,92,246,0.10);  color: #8b5cf6; }
            .mdui-mini-stat-card[data-tone="emerald"] .mdui-mini-icon { background: rgba(16,185,129,0.10);  color: #10b981; }
            .mdui-mini-data { display: flex; flex-direction: column; gap: 2px; }
            .mdui-mini-value { font-size: 1.05rem; font-weight: 700; color: var(--mdui-text); line-height: 1; letter-spacing: -0.01em; }
            .mdui-mini-label { font-size: 0.65rem; font-weight: 600; color: var(--mdui-muted); text-transform: uppercase; letter-spacing: 0.05em; }

            .mdui-trends-grid { display: grid; gap: 4px; }
            .mdui-trend-row { display: grid; grid-template-columns: 1.6fr 1fr 1fr; align-items: center; gap: 12px; padding: 10px 0; border-bottom: 1px solid var(--mdui-border-light); }
            .mdui-trend-row:last-child { border-bottom: none; }
            .mdui-trend-label { font-size: 0.88rem; color: var(--mdui-muted); }
            .mdui-trend-current { font-size: 1.05rem; font-weight: 600; color: var(--mdui-text); }
            .mdui-trend-delta { font-size: 0.92rem; font-weight: 600; }
            .mdui-trend-up { color: var(--mdui-success); }
            .mdui-trend-down { color: var(--mdui-danger); }
            .mdui-trend-neutral { color: var(--mdui-tertiary); }

            .mdui-records-grid { display: grid; gap: 12px; }
            .mdui-record { padding: 14px 16px; border-radius: var(--mdui-radius); border: 1px solid var(--mdui-border); background: var(--mdui-surface); }
            .mdui-record[data-tone="indigo"]  { background: rgba(99,102,241,0.06);  border-color: rgba(99,102,241,0.16); }
            .mdui-record[data-tone="emerald"] { background: rgba(16,185,129,0.06);  border-color: rgba(16,185,129,0.16); }
            .mdui-record[data-tone="amber"]   { background: rgba(245,158,11,0.06);  border-color: rgba(245,158,11,0.18); }
            .mdui-record-head { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
            .mdui-record-icon { font-size: 0.9rem; }
            .mdui-record[data-tone="indigo"] .mdui-record-icon { color: #6366f1; }
            .mdui-record[data-tone="emerald"] .mdui-record-icon { color: #10b981; }
            .mdui-record[data-tone="amber"] .mdui-record-icon { color: #f59e0b; }
            .mdui-record-label { font-size: 0.62rem; font-weight: 800; letter-spacing: 0.1em; text-transform: uppercase; color: var(--mdui-tertiary); }
            .mdui-record-value { font-family: var(--mdui-font-mono); font-size: 1rem; font-weight: 700; color: var(--mdui-text); margin-bottom: 3px; }
            .mdui-record-sub { font-size: 0.72rem; color: var(--mdui-muted); }

            /* ── AIRSPACE ── */
            .mdui-airspace-add { display: flex; gap: 10px; margin-bottom: 16px; }
            .mdui-node-header { display: flex; justify-content: space-between; align-items: center; padding: 16px 20px; border-bottom: 1px solid var(--mdui-border-light); }
            .mdui-node-icao { font-family: var(--mdui-font-mono); font-size: 1.25rem; font-weight: 700; color: var(--mdui-text); }
            .mdui-assessment-row { display: flex; align-items: flex-start; gap: 12px; padding: 12px; background: var(--mdui-surface); border-radius: 10px; margin: 16px 20px; }
            .mdui-assessment-icon { font-size: 1.2rem; flex-shrink: 0; padding-top: 2px; }
            .mdui-assessment-text strong { font-size: 0.8rem; color: var(--mdui-text); font-weight: 700; display:block; margin-bottom:3px; }
            .mdui-assessment-text span { font-size: 0.78rem; color: var(--mdui-muted); line-height: 1.5; }
            .mdui-load-bar-block { margin: 0 20px 16px; }
            .mdui-load-bar-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
            .mdui-load-bar-track { width: 100%; height: 6px; background: var(--mdui-surface); border-radius: 3px; overflow: hidden; }
            .mdui-load-bar-fill { height: 100%; border-radius: 3px; transition: 0.32s; }
            .mdui-intel-stats-quad { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; padding: 14px 20px; border-top: 1px solid var(--mdui-border-light); border-bottom: 1px solid var(--mdui-border-light); }
            .mdui-intel-stat { display: flex; flex-direction: column; gap: 4px; }
            .mdui-intel-stat .label { font-size: 0.6rem; color: var(--mdui-tertiary); font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; }
            .mdui-intel-stat .value { font-family: var(--mdui-font-mono); font-size: 1.25rem; color: var(--mdui-text); font-weight: 700; line-height: 1; }
            .mdui-section-head { display: flex; justify-content: space-between; align-items: center; margin: 0 20px 8px; }
            .mdui-intel-heatmap { display: flex; gap: 3px; height: 32px; border-radius: 6px; overflow: hidden; background: var(--mdui-surface); padding: 3px; margin: 0 20px 16px;}
            .mdui-intel-heatblock { flex: 1; border-radius: 4px; }

            /* ── DISPATCH ── */
            .mdui-form-sheet { margin-bottom: 24px; }
            .mdui-form-section-title { margin: 0 0 12px 0; font-size: 0.66rem; font-weight: 700; color: var(--mdui-tertiary); text-transform: uppercase; letter-spacing: 0.1em; padding-bottom: 6px; border-bottom: 1px solid var(--mdui-border-light); }
            .mdui-form-actions { margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--mdui-border-light); display: flex; gap: 10px; justify-content: flex-end; }
            .mdui-form-actions button { flex: 1; }

            .mdui-ticket { background: var(--mdui-card); border: 1px solid var(--mdui-border); border-radius: var(--mdui-radius); box-shadow: var(--mdui-shadow-card); display: flex; flex-direction: column; margin-bottom: 16px; position: relative; }
            .mdui-ticket-actions { position: absolute; top: 12px; right: 12px; display: flex; gap: 6px; }
            .mdui-ticket-stub { border-bottom: 1px dashed var(--mdui-border); padding: 16px 20px; display: flex; align-items: center; }
            .mdui-ticket-date { font-family: var(--mdui-font-mono); font-size: 0.86rem; font-weight: 700; color: var(--mdui-text); margin-right: 10px; }
            .mdui-ticket-time { font-size: 0.74rem; color: var(--mdui-muted); font-weight: 600; flex: 1; }
            .mdui-ticket-cs { background: var(--mdui-accent-soft); color: var(--mdui-accent); padding: 3px 8px; border-radius: 6px; font-size: 0.74rem; font-weight: 700; font-family: var(--mdui-font-mono); }
            .mdui-ticket-body { padding: 16px 20px; }
            .mdui-ticket-route { width: 100%; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
            .mdui-ticket-point { display: flex; flex-direction: column; gap: 4px; }
            .mdui-ticket-point-right { align-items: flex-end; }
            .mdui-ticket-icao { font-family: var(--mdui-font-mono); font-size: 1.5rem; font-weight: 700; color: var(--mdui-text); letter-spacing: -0.01em; line-height: 1; }
            .mdui-ticket-gate { font-size: 0.66rem; color: var(--mdui-tertiary); font-weight: 600; }
            .mdui-ticket-path { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 6px; position: relative; padding: 0 16px; }
            .mdui-ticket-duration { font-size: 0.68rem; color: var(--mdui-tertiary); font-weight: 600; }
            .mdui-ticket-line { width: 100%; height: 1px; background: var(--mdui-border); position: relative; display: flex; justify-content: center; align-items: center; }
            .mdui-ticket-line i { position: absolute; color: var(--mdui-accent); font-size: 0.85rem; background: var(--mdui-card); padding: 0 6px; }
            .mdui-ticket-acft { font-size: 0.7rem; color: var(--mdui-muted); font-weight: 700; letter-spacing: 0.04em; }
            .mdui-ticket-aside { border-top: 1px solid var(--mdui-border-light); padding: 12px 20px; display: flex; justify-content: space-around; }
            .mdui-ticket-stat { display: flex; align-items: center; gap: 8px; font-size: 0.78rem; color: var(--mdui-muted); font-weight: 500; }

            .mdui-confirm-box { background: var(--mdui-card); border-radius: var(--mdui-radius); padding: 20px; max-width: 340px; width: 100%; text-align: center; }
            .mdui-confirm-icon { font-size: 2rem; color: var(--mdui-danger); margin-bottom: 12px; }
            .mdui-confirm-header h3 { margin: 0 0 10px; }
            .mdui-confirm-flight-plate { background: var(--mdui-surface); padding: 10px; border-radius: 8px; margin: 16px 0; font-family: var(--mdui-font-mono); font-weight: 700; }
            .mdui-confirm-actions { display: flex; gap: 10px; }

            /* ── WATCHLIST ── */
            .mdui-autocomplete-dropdown { position: absolute; top: calc(100% + 5px); left: 0; right: 0; background: var(--mdui-card); border: 1px solid var(--mdui-border); border-radius: 10px; z-index: 100; box-shadow: var(--mdui-shadow-pop); overflow: hidden; }
            .mdui-autocomplete-item { padding: 10px 14px; display: flex; align-items: center; gap: 10px; border-bottom: 1px solid var(--mdui-border-light); cursor: pointer; font-weight: 500; }
            .mdui-autocomplete-item:hover { background: var(--mdui-hover); }
            
            .mdui-watchlist-grid { display: grid; gap: 12px; }
            .mdui-wl-card { background: var(--mdui-card); border: 1px solid var(--mdui-border); border-radius: var(--mdui-radius); padding: 16px; }
            .mdui-wl-card.live { border-color: var(--mdui-success-soft); background: linear-gradient(180deg, var(--mdui-success-soft) 0%, var(--mdui-card) 65%); }
            .mdui-wl-card-top { display: flex; justify-content: space-between; align-items: center; }
            .mdui-wl-identity { display: flex; align-items: center; gap: 12px; }
            .mdui-wl-dot { width: 10px; height: 10px; border-radius: 50%; }
            .mdui-wl-dot.live { background: var(--mdui-success); animation: mdui-pulse 2s infinite; }
            .mdui-wl-dot.offline { background: var(--mdui-tertiary); opacity: 0.5; }
            .mdui-wl-username { font-weight: 700; font-size: 0.95rem; }
            .mdui-wl-status { font-size: 0.72rem; color: var(--mdui-muted); margin-top: 2px; }
            .mdui-wl-status.live { color: var(--mdui-success); }
            .mdui-watchlist-remove-btn { background: none; border: none; color: var(--mdui-tertiary); cursor: pointer; padding: 5px; }
            .mdui-wl-flight-info { margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--mdui-border-light); }
            .mdui-wl-route { display: flex; align-items: center; justify-content: center; gap: 14px; margin-bottom: 12px; font-family: var(--mdui-font-mono); font-weight: 700; font-size: 1.2rem; }
            .mdui-wl-plane-icon { color: var(--mdui-accent); font-size: 1rem; }
            .mdui-wl-telemetry { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
            .mdui-wl-tele-item { display: flex; flex-direction: column; background: var(--mdui-surface); padding: 8px 12px; border-radius: 8px; }
            .mdui-wl-tele-item .label { font-size: 0.6rem; color: var(--mdui-tertiary); font-weight: 700; }
            .mdui-wl-tele-item .value { font-family: var(--mdui-font-mono); font-weight: 700; font-size: 0.9rem; }

            .mdui-toggle-label { display: inline-flex; align-items: center; gap: 10px; cursor: pointer; }
            .mdui-toggle-label input { display: none; }
            .mdui-toggle-track { position: relative; width: 38px; height: 22px; background: var(--mdui-border); border-radius: 999px; transition: 0.14s; }
            .mdui-toggle-thumb { position: absolute; top: 2px; left: 2px; width: 18px; height: 18px; background: #fff; border-radius: 50%; transition: 0.18s; }
            .mdui-toggle-label input:checked + .mdui-toggle-track { background: var(--mdui-accent); }
            .mdui-toggle-label input:checked + .mdui-toggle-track .mdui-toggle-thumb { transform: translateX(16px); }
            .mdui-toggle-text { font-size: 0.78rem; font-weight: 600; color: var(--mdui-muted); }

            /* ── DRILL DOWN ── */
            .mdui-drill-box { background: var(--mdui-card); border-radius: var(--mdui-radius); width: 100%; max-width: 360px; overflow: hidden; box-shadow: var(--mdui-shadow-pop); }
            .mdui-drill-header { display: flex; align-items: center; justify-content: space-between; padding: 16px 20px; border-bottom: 1px solid var(--mdui-border-light); }
            .mdui-drill-header h3 { margin: 0; font-weight: 600; font-size: 1.05rem; }
            .mdui-drill-body { padding: 16px 20px; }
            .mdui-drill-stat-row { display: flex; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid var(--mdui-border-light); font-size: 0.88rem; }
            .mdui-drill-stat-row:last-child { border-bottom: none; }
            .mdui-drill-stat-row span { color: var(--mdui-muted); }
            .mdui-drill-stat-row strong { font-weight: 600; color: var(--mdui-text); }
            .mdui-drill-bar-row { margin-bottom: 12px; font-size: 0.84rem; }
            .mdui-drill-bar-label { display: flex; justify-content: space-between; margin-bottom: 4px; }
            .mdui-drill-bar-track { width: 100%; height: 6px; background: var(--mdui-input); border-radius: 3px; }
            .mdui-drill-bar-fill { height: 100%; background: var(--mdui-accent); border-radius: 3px; }
            .mdui-drill-note { margin: 0; padding: 10px; background: var(--mdui-info-soft); border-radius: 6px; font-size: 0.82rem; color: var(--mdui-muted); }
            .mdui-drill-actions { padding: 14px 20px; border-top: 1px solid var(--mdui-border-light); display: flex; justify-content: flex-end; }
            .mdui-drillable { cursor: pointer; border-bottom: 1px dashed var(--mdui-tertiary); transition: color 0.14s; }
            .mdui-drillable:hover { color: var(--mdui-accent); border-bottom-color: var(--mdui-accent); }

            /* ── SETTINGS ── */
            .mdui-settings-grid { display: flex; flex-direction: column; gap: 16px; }
            .mdui-theme-options { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
            .mdui-theme-option { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border: 1px solid var(--mdui-border); border-radius: 10px; cursor: pointer; transition: 0.14s; }
            .mdui-theme-option:hover { background: var(--mdui-hover); }
            .mdui-theme-option input { display: none; }
            .mdui-theme-option i { color: var(--mdui-tertiary); font-size: 0.85rem; }
            .mdui-theme-option span { color: var(--mdui-text); font-weight: 500; font-size: 0.85rem; }
            .mdui-theme-option:has(input:checked) { border-color: var(--mdui-accent); background: var(--mdui-accent-soft); }
            .mdui-theme-option:has(input:checked) i { color: var(--mdui-accent); }
            .mdui-accent-grid { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 4px; }
            .mdui-accent-swatch { width: 36px; height: 36px; border-radius: 50%; border: 2px solid var(--mdui-border); cursor: pointer; display: flex; align-items: center; justify-content: center; color: #fff; font-size: 0.78rem; transition: 0.14s; padding: 0; }
            .mdui-accent-swatch.active { border-color: var(--mdui-text); box-shadow: 0 0 0 2px var(--mdui-card), 0 0 0 4px var(--mdui-accent-glow); }
            .mdui-plan-box { background: var(--mdui-surface); border: 1px solid var(--mdui-border); border-radius: var(--mdui-radius); padding: 16px; }
            .mdui-plan-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
            .mdui-plan-header h4 { margin: 0; font-size: 0.95rem; font-weight: 700; color: var(--mdui-text); }
            .mdui-plan-price { font-size: 1.4rem; font-weight: 700; color: var(--mdui-text); margin: 0 0 4px 0; letter-spacing: -0.02em; }
            .mdui-plan-renewal { font-size: 0.78rem; color: var(--mdui-tertiary); margin: 0; }
            .mdui-billing-actions { display: flex; flex-direction: column; gap: 8px; margin-top: 16px; }

            /* ── ONBOARDING ── */
            .mdui-onboarding { padding: 40px 20px; display: flex; flex-direction: column; justify-content: flex-start; min-height: 100%; }
            .mdui-onb-icon { width: 56px; height: 56px; margin: 0 auto 18px; border-radius: 16px; background: var(--mdui-accent-soft); color: var(--mdui-accent); font-size: 1.5rem; display: grid; place-items: center; }
            .mdui-onb-title { font-size: 1.7rem; font-weight: 700; text-align: center; margin: 0 0 8px; color: var(--mdui-text); letter-spacing: -0.02em; }
            .mdui-onb-sub { text-align: center; color: var(--mdui-muted); font-size: 0.92rem; line-height: 1.5; margin: 0; }
            .mdui-pill-row { display: flex; gap: 10px; }
            .mdui-radio-pill { flex: 1; padding: 10px 12px; border-radius: 10px; cursor: pointer; border: 1px solid var(--mdui-border); background: var(--mdui-input); display: flex; align-items: center; justify-content: center; font-size: 0.85rem; font-weight: 500; color: var(--mdui-text); transition: 0.14s; }
            .mdui-radio-pill:has(input:checked) { border-color: var(--mdui-accent); background: var(--mdui-accent-soft); }
            .mdui-radio-pill input { display: none; }
            /* ── Carousel Roulette & 3D HUD Support ── */
        .mdui-live-carousel {
            display: flex;
            overflow-x: auto;
            scroll-snap-type: x mandatory;
            gap: 16px;
            padding: 0 20px;
            margin: 0 -20px 24px;
            scrollbar-width: none;
        }
        .mdui-live-carousel::-webkit-scrollbar {
            display: none;
        }
        .mdui-live-carousel > .mdui-live-card {
            scroll-snap-align: center;
            flex: 0 0 calc(100% - 16px);
            margin-bottom: 0;
        }
        .mdui-live-bg-3d {
            background: #0a1628;
            overflow: hidden;
        }
        .mdui-live-bg-3d > * {
            width: 100%;
            height: 100%;
        }

        /* ── Support & Legal Action Links ── */
        .mdui-action-link {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px 14px;
            background: var(--mdui-surface);
            border: 1px solid var(--mdui-border);
            border-radius: 12px;
            text-decoration: none;
            transition: 0.14s;
        }
        .mdui-action-link:hover {
            background: var(--mdui-card-elev);
            border-color: var(--mdui-border-strong);
        }
        .mdui-action-icon {
            width: 36px;
            height: 36px;
            border-radius: 10px;
            background: var(--mdui-hover);
            color: var(--mdui-muted);
            display: grid;
            place-items: center;
            font-size: 0.95rem;
        }
        .mdui-action-text {
            flex: 1;
            font-size: 0.88rem;
            font-weight: 600;
            color: var(--mdui-text);
        }
        `;

        const style       = document.createElement('style');
        style.id          = 'mdui-styles';
        style.textContent = css;
        document.head.appendChild(style);
    },
};