/**
 * WatchlistService.js
 *
 * Single source of truth for the friends watchlist and its live
 * "pilot online" notification feed.
 *
 * The watchlist is moving to the ACARS backend. The backend endpoints don't
 * exist yet, so this service lays the groundwork: it speaks the future ACARS
 * contract first, and transparently falls back to today's behavior
 * (Supabase `user_watchlist` table + client-side diffing of the
 * `all_flights_update` socket stream) whenever the backend reports the
 * feature as unavailable.
 *
 * ============================================================================
 * 📡 ACARS BACKEND CONTRACT (groundwork — not yet implemented server-side)
 * ============================================================================
 * All REST calls carry `Authorization: Bearer <supabase access token>` so the
 * backend can verify the caller against Supabase auth.
 *
 * GET    /api/watchlist/capabilities
 *        → { ok: true, watchlist: boolean, events: boolean }
 *        Probed once on boot. `watchlist` enables REST CRUD below;
 *        `events` enables server-pushed notifications and disables the
 *        client-side diffing fallback.
 *
 * GET    /api/watchlist
 *        → { ok: true, entries: [{ id, watchedUsername, addedAt }] }
 *
 * POST   /api/watchlist            body { watchedUsername }
 *        → { ok: true, entry: { id, watchedUsername, addedAt } }
 *
 * DELETE /api/watchlist/{entryId}
 *        → { ok: true }
 *
 * ── Socket.IO (same connection as `all_flights_update`) ────────────────────
 * emit   'watchlist_subscribe'    { userId, usernames: string[] }
 *        Sent on connect and whenever the watchlist changes, so the backend
 *        knows which pilots to watch for this client.
 *
 * on     'watchlist_event'        { type: 'pilot_online' | 'pilot_offline',
 *                                   username, flight, timestamp }
 *        Server-pushed when a watched pilot connects/disconnects. `flight`
 *        matches the FlightData shape documented in SocketDataHub.js.
 * ============================================================================
 *
 * Consumers (ProfileUI, MobileDashboardUI, flight.js) subscribe via
 * `subscribe(listener)` and receive:
 *   { type: 'entries_changed' }                      — watchlist add/remove/refresh
 *   { type: 'status_updated' }                       — live status map recomputed
 *   { type: 'pilot_online',  username, flight }      — watched pilot connected
 *   { type: 'pilot_offline', username, flight }      — watched pilot disconnected
 *
 * The native iOS banner (LiveActivityPlugin's presentLocalNotification bridge)
 * is fired HERE, exactly once per transition — not by the UI layers — so the
 * desktop and mobile dashboards can both be initialized without duplicating
 * system notifications.
 */

import { socketDataHub } from './SocketDataHub.js';

const DEFAULT_BACKEND_URL = 'https://site--acars-backend--6dmjph8ltlhv.code.run';

// Suppress repeat native banners for the same pilot within this window, in
// case the server push and the local diff fallback ever overlap.
const NOTIFY_DEDUPE_MS = 60_000;

export const WatchlistService = {
    _supabase:   null,
    _socket:     null,
    _backendUrl: DEFAULT_BACKEND_URL,

    _user:    null,
    // 'supabase' until the ACARS capability probe succeeds.
    _source:  'supabase',
    _capabilities: { watchlist: false, events: false },

    // Entries keep the legacy Supabase row shape ({ id, watched_username,
    // added_at }) regardless of source, so existing UI templates don't change.
    _entries: [],
    _status:  {},   // usernameLower → { isLive, flight }
    _statusKnown: false,
    _notificationsEnabled: true,

    _listeners: new Set(),
    _lastNotifiedAt: new Map(),

    // ─── Lifecycle ───────────────────────────────────────────────────────────

    init(supabaseClient) {
        if (this._supabase) return;
        this._supabase   = supabaseClient;
        this._backendUrl = window.APP_CONFIG?.backendUrl || DEFAULT_BACKEND_URL;

        socketDataHub.subscribe('all_flights_update', (payload) => {
            if (payload?.flights) this._ingestAllFlights(payload.flights);
        });

        this._probeCapabilities();
    },

    /** Attach the live Socket.IO connection (called from flight.js once the
     *  sector-ops socket is created) so the service can register for
     *  server-pushed watchlist events and announce which pilots it watches. */
    bindSocket(socket) {
        if (!socket || this._socket === socket) return;
        this._socket = socket;
        socket.on('connect', () => this._syncServerSubscription());
        socket.on('watchlist_event', (evt) => this._ingestServerEvent(evt));
        this._syncServerSubscription();
    },

    setUser(user) {
        if ((user?.id || null) === (this._user?.id || null)) {
            this._user = user || null;
            return;
        }
        this._user = user || null;
        this._entries = [];
        this._status = {};
        this._statusKnown = false;
        this._lastNotifiedAt.clear();
        if (this._user) {
            this.refresh();
        } else {
            this._emit({ type: 'entries_changed' });
            this._emit({ type: 'status_updated' });
        }
    },

    setNotificationsEnabled(enabled) {
        this._notificationsEnabled = !!enabled;
    },

    // ─── Reads ───────────────────────────────────────────────────────────────

    getSource()  { return this._source; },
    getEntries() { return this._entries; },
    getStatus()  { return this._status; },

    getWatchedUsernames() {
        return this._entries
            .map(e => e?.watched_username)
            .filter(Boolean);
    },

    subscribe(listener) {
        this._listeners.add(listener);
        return () => this._listeners.delete(listener);
    },

    // ─── CRUD (ACARS-first, Supabase fallback) ──────────────────────────────

    async refresh() {
        if (!this._user) return [];
        try {
            this._entries = this._source === 'acars'
                ? await this._acarsFetchEntries()
                : await this._supabaseFetchEntries();
        } catch (err) {
            console.warn('[WatchlistService] Could not load watchlist:', err.message);
        }
        this._emit({ type: 'entries_changed' });
        this._syncServerSubscription();
        return this._entries;
    },

    /** @returns the new entry, or throws. */
    async add(username) {
        if (!this._user) throw new Error('Sign in to use the watchlist');
        const clean = String(username || '').trim();
        if (!clean) throw new Error('No pilot name given');
        if (this._entries.some(e => e.watched_username.toLowerCase() === clean.toLowerCase())) {
            throw new Error(`${clean} is already on your watchlist`);
        }

        const entry = this._source === 'acars'
            ? await this._acarsAddEntry(clean)
            : await this._supabaseAddEntry(clean);

        this._entries.unshift(entry);
        this._emit({ type: 'entries_changed' });
        this._syncServerSubscription();
        return entry;
    },

    async remove(entryId, username) {
        if (this._source === 'acars') {
            await this._acarsRemoveEntry(entryId);
        } else {
            await this._supabaseRemoveEntry(entryId);
        }
        this._entries = this._entries.filter(e => String(e.id) !== String(entryId));
        const un = (username || '').toLowerCase();
        if (un) delete this._status[un];
        this._emit({ type: 'entries_changed' });
        this._syncServerSubscription();
    },

    // ─── ACARS transport ─────────────────────────────────────────────────────

    async _probeCapabilities() {
        // window.APP_CONFIG.watchlistSource: 'acars' | 'supabase' (force a
        // source and skip probing), unset = auto-detect.
        const override = window.APP_CONFIG?.watchlistSource;
        if (override === 'supabase') return;

        try {
            const res = await this._fetchWithTimeout(
                `${this._backendUrl}/api/watchlist/capabilities`, {}, 5000);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const caps = await res.json();
            if (!caps?.ok) throw new Error('capabilities not ok');

            this._capabilities = { watchlist: !!caps.watchlist, events: !!caps.events };
            if (this._capabilities.watchlist || override === 'acars') {
                this._source = 'acars';
                console.log('[WatchlistService] ACARS watchlist backend detected', this._capabilities);
                if (this._user) await this.refresh();
            }
            this._syncServerSubscription();
        } catch (_) {
            // Backend not ready (today's normal case) — stay on Supabase.
        }
    },

    async _authHeaders() {
        const headers = { 'Content-Type': 'application/json' };
        try {
            const { data } = await this._supabase.auth.getSession();
            const token = data?.session?.access_token;
            if (token) headers['Authorization'] = `Bearer ${token}`;
        } catch (_) { /* unauthenticated request — backend will reject */ }
        return headers;
    },

    async _fetchWithTimeout(url, options = {}, timeoutMs = 8000) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        try {
            return await fetch(url, { ...options, signal: controller.signal });
        } finally {
            clearTimeout(timer);
        }
    },

    _normalizeAcarsEntry(e) {
        return {
            id:               e.id,
            watched_username: e.watchedUsername ?? e.watched_username,
            added_at:         e.addedAt ?? e.added_at ?? null,
        };
    },

    async _acarsFetchEntries() {
        const res = await this._fetchWithTimeout(`${this._backendUrl}/api/watchlist`, {
            headers: await this._authHeaders(),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        return (data?.entries || []).map(e => this._normalizeAcarsEntry(e));
    },

    async _acarsAddEntry(username) {
        const res = await this._fetchWithTimeout(`${this._backendUrl}/api/watchlist`, {
            method:  'POST',
            headers: await this._authHeaders(),
            body:    JSON.stringify({ watchedUsername: username }),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        if (!data?.entry) throw new Error('Malformed response');
        return this._normalizeAcarsEntry(data.entry);
    },

    async _acarsRemoveEntry(entryId) {
        const res = await this._fetchWithTimeout(
            `${this._backendUrl}/api/watchlist/${encodeURIComponent(entryId)}`, {
                method:  'DELETE',
                headers: await this._authHeaders(),
            });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
    },

    /** Tell the backend which pilots this client watches so it can push
     *  `watchlist_event`s. No-op until the backend advertises `events`. */
    _syncServerSubscription() {
        if (!this._socket?.connected || !this._capabilities.events) return;
        try {
            this._socket.emit('watchlist_subscribe', {
                userId:    this._user?.id || null,
                usernames: this.getWatchedUsernames(),
            });
        } catch (_) { /* best-effort */ }
    },

    // ─── Supabase fallback transport ─────────────────────────────────────────

    async _supabaseFetchEntries() {
        const { data, error } = await this._supabase
            .from('user_watchlist')
            .select('id, watched_username, added_at')
            .eq('user_id', this._user.id)
            .order('added_at', { ascending: false });
        if (error) throw error;
        return data || [];
    },

    async _supabaseAddEntry(username) {
        const { data, error } = await this._supabase
            .from('user_watchlist')
            .insert([{ user_id: this._user.id, watched_username: username }])
            .select('id, watched_username, added_at')
            .single();
        if (error) throw error;
        return data;
    },

    async _supabaseRemoveEntry(entryId) {
        const { error } = await this._supabase
            .from('user_watchlist')
            .delete()
            .eq('id', entryId);
        if (error) throw error;
    },

    // ─── Live status + notifications ─────────────────────────────────────────

    _ingestAllFlights(flights) {
        if (this._entries.length === 0) {
            if (Object.keys(this._status).length) {
                this._status = {};
                this._emit({ type: 'status_updated' });
            }
            return;
        }

        const prevStatus = this._status;
        const prevKnown  = this._statusKnown;
        const newStatus  = {};
        for (const entry of this._entries) {
            const un = entry.watched_username.toLowerCase();
            const flight = flights.find(f => f.username?.toLowerCase() === un);
            newStatus[un] = { isLive: !!flight, flight: flight || null };
        }
        this._status = newStatus;
        this._statusKnown = true;

        // Transition detection is the fallback notification path: once the
        // ACARS backend pushes `watchlist_event`s itself, skip local diffing
        // so each transition is announced exactly once.
        if (!this._capabilities.events && prevKnown) {
            for (const [un, cur] of Object.entries(newStatus)) {
                const prev = prevStatus[un];
                if (!prev || cur.isLive === prev.isLive) continue;
                this._handleTransition(cur.isLive ? 'pilot_online' : 'pilot_offline', un, cur.flight);
            }
        }

        this._emit({ type: 'status_updated' });
    },

    _ingestServerEvent(evt) {
        if (!evt?.type || !evt?.username) return;
        const un = String(evt.username).toLowerCase();
        if (!this._entries.some(e => e.watched_username.toLowerCase() === un)) return;

        if (evt.type === 'pilot_online' || evt.type === 'pilot_offline') {
            this._status[un] = {
                isLive: evt.type === 'pilot_online',
                flight: evt.flight || null,
            };
            this._handleTransition(evt.type, un, evt.flight || null);
            this._emit({ type: 'status_updated' });
        }
    },

    _handleTransition(type, username, flight) {
        // Watchlist notifications are an account-gated feature.
        if (!this._user || !this._notificationsEnabled) return;

        this._emit({ type, username, flight });

        // Native banner only for "online" — matches the existing product
        // behavior; offline events are surfaced in-app only.
        if (type !== 'pilot_online') return;

        const last = this._lastNotifiedAt.get(username) || 0;
        if (Date.now() - last < NOTIFY_DEDUPE_MS) return;
        this._lastNotifiedAt.set(username, Date.now());

        try {
            // iOS notification hierarchy:
            //   title   = friend's name (bold)
            //   subtitle= status verb (semibold)
            //   body    = route + aircraft
            const who  = flight?.username || username;
            const acft = flight?.aircraft?.aircraftName || '';
            const bodyParts = [];
            if (flight?.departureIcao && flight?.arrivalIcao) {
                bodyParts.push(`${flight.departureIcao} → ${flight.arrivalIcao}`);
            }
            if (acft) bodyParts.push(acft);
            window.InflightLiveActivity?.presentLocalNotification?.({
                title: who,
                subtitle: 'Now online',
                body:  bodyParts.join(' · ') || 'Watchlist pilot just connected',
                identifier: `watchlist-online-${username}`,
                threadIdentifier: 'inflight-watchlist',
                userInfo: { kind: 'watchlist_online', username },
            });
        } catch (_) { /* best-effort */ }
    },

    _emit(event) {
        for (const listener of this._listeners) {
            try {
                listener(event);
            } catch (err) {
                console.error('[WatchlistService] Listener error:', err);
            }
        }
    },
};
