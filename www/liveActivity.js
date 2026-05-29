// Thin JS wrapper around the iOS LiveActivityPlugin (ActivityKit bridge).
// On non-iOS or non-supporting devices every call is a silent no-op.
//
// Public API on window.InflightLiveActivity:
//   start({ flightId, callsign, airlineName, aircraftType, liveryName,
//           registration, departureIcao, arrivalIcao,
//           scheduledDeparture, scheduledArrival, currentEta,
//           currentAtd, distanceToDestinationNm, totalDistanceNm,
//           isLanded }) -> Promise
//   update({ flightId, currentEta, currentAtd,
//            distanceToDestinationNm, isLanded }) -> Promise
//   end({ flightId, immediate }) -> Promise
//   isTrackingFlight(flightId) -> bool
//   getTrackedFlightId() -> string | null

(function () {
    const trackedFlights = new Set();
    let lastUpdateByFlight = new Map();
    // Per-flight display snapshot so the Inflight panel can render rich info
    // (route, ETA, distance, status) even for flights that have scrolled off
    // the live map. Keyed by flightId, kept in start order for FIFO swaps.
    const trackedMeta = new Map();
    let pluginRef = null;
    let notificationPermissionRequested = false;

    function rememberMeta(flightId, payload, partial) {
        const prev = trackedMeta.get(flightId) || { startedAt: Date.now() };
        const next = partial ? Object.assign({}, prev) : Object.assign({}, prev);
        const assignIf = (key, val) => { if (val !== undefined && val !== null) next[key] = val; };
        assignIf('callsign', payload.callsign);
        assignIf('airlineName', payload.airlineName);
        assignIf('aircraftType', payload.aircraftType);
        assignIf('liveryName', payload.liveryName);
        assignIf('registration', payload.registration);
        assignIf('departureIcao', payload.departureIcao);
        assignIf('arrivalIcao', payload.arrivalIcao);
        if (payload.currentEta != null) next.currentEtaMs = toMs(payload.currentEta);
        if (payload.currentAtd != null) next.currentAtdMs = toMs(payload.currentAtd);
        if (payload.distanceToDestinationNm != null) {
            const d = Number(payload.distanceToDestinationNm);
            if (Number.isFinite(d)) next.distanceToDestinationNm = d;
        }
        if (payload.totalDistanceNm != null) {
            const t = Number(payload.totalDistanceNm);
            if (Number.isFinite(t)) next.totalDistanceNm = t;
        }
        if (payload.isLanded != null) next.isLanded = !!payload.isLanded;
        next.flightId = String(flightId);
        next.updatedAt = Date.now();
        trackedMeta.set(String(flightId), next);
    }

    function detectIOS() {
        // Be liberal: any of (Capacitor reports ios) OR (UA looks like iOS in a
        // WebView) OR (running under the capacitor:// scheme) is enough. The
        // worst case if we're wrong is a button that errors when tapped — far
        // better than a button that silently never renders.
        try {
            if (typeof window === 'undefined') return false;
            const cap = window.Capacitor;
            if (cap && typeof cap.getPlatform === 'function' && cap.getPlatform() === 'ios') return true;
            if (typeof window.isIOSNative === 'function' && window.isIOSNative()) return true;
            const proto = (window.location && window.location.protocol) || '';
            const ua = (navigator.userAgent || '') + ' ' + (navigator.platform || '');
            const looksLikeIOS = /iPhone|iPad|iPod/i.test(ua) ||
                (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
            if ((proto === 'capacitor:' || proto === 'ionic:') && looksLikeIOS) return true;
            return false;
        } catch (_) {
            return false;
        }
    }

    function getPlugin() {
        if (pluginRef) return pluginRef;
        try {
            const cap = (typeof window !== 'undefined') ? window.Capacitor : null;
            if (!cap) return null;
            // Try the native-bridge auto-populated Plugins map first — on iOS
            // the Capacitor runtime populates Capacitor.Plugins.<Name> from
            // any plugin registered via the CAP_PLUGIN() macro at launch.
            if (cap.Plugins && cap.Plugins.LiveActivity) {
                pluginRef = cap.Plugins.LiveActivity;
                return pluginRef;
            }
            // Then fall back to explicit registration. registerPlugin
            // returns a Proxy in Capacitor 5+; only cache if it's actually
            // an object so a transient null doesn't poison the session.
            if (typeof cap.registerPlugin === 'function') {
                const proxy = cap.registerPlugin('LiveActivity');
                if (proxy && typeof proxy === 'object') {
                    pluginRef = proxy;
                    return pluginRef;
                }
            }
            return null;
        } catch (e) {
            console.error('[LiveActivity] getPlugin threw:', e);
            return null;
        }
    }

    // Small human-readable dump of what's actually on window.Capacitor,
    // so a toast or PR comment can carry enough info to diagnose missing
    // native plugin registration without a USB-attached Safari debugger.
    function describeCapacitor() {
        try {
            const cap = window.Capacitor;
            if (!cap) return 'window.Capacitor=missing';
            const platform = (typeof cap.getPlatform === 'function') ? cap.getPlatform() : 'unknown';
            const hasReg = (typeof cap.registerPlugin === 'function');
            const pluginKeys = (cap.Plugins && typeof cap.Plugins === 'object')
                ? Object.keys(cap.Plugins).slice(0, 12).join(',')
                : 'none';
            return `platform=${platform}, registerPlugin=${hasReg}, Plugins={${pluginKeys}}`;
        } catch (e) {
            return 'describe_failed:' + (e && e.message || e);
        }
    }

    function isSupported() {
        if (!detectIOS()) return false;
        // On iOS we return true even if the plugin proxy isn't ready yet — the
        // proxy will materialize once Capacitor finishes booting, and the
        // actual call will surface a real error if the native side is missing.
        // This prevents the bell from being permanently hidden on a race.
        getPlugin();
        return true;
    }

    async function getNotificationPermissionStatus() {
        if (!detectIOS()) return { status: 'unsupported', granted: false };
        const plugin = getPlugin();
        if (!plugin) return { status: 'unknown', granted: false };
        try {
            if (typeof plugin.getNotificationPermissionStatus === 'function') {
                const res = await plugin.getNotificationPermissionStatus();
                return { status: res.status || 'unknown', granted: !!res.granted };
            }
        } catch (err) {
            console.warn('[LiveActivity] getNotificationPermissionStatus failed:', err);
        }
        return { status: 'unknown', granted: false };
    }

    async function requestNotificationPermission(opts) {
        if (!detectIOS()) return { ok: false, reason: 'unsupported' };
        const plugin = getPlugin();
        if (!plugin || typeof plugin.requestNotificationPermission !== 'function') {
            return {
                ok: false,
                reason: 'native bridge unreachable (' + describeCapacitor() + ')'
            };
        }
        const force = !!(opts && opts.force);
        if (notificationPermissionRequested && !force) {
            return { ok: true, reason: 'already_requested' };
        }
        notificationPermissionRequested = true;
        try {
            const res = await plugin.requestNotificationPermission();
            return { ok: true, ...res };
        } catch (err) {
            console.warn('[LiveActivity] requestNotificationPermission failed:', err);
            // Allow a retry next time if the call genuinely failed.
            notificationPermissionRequested = false;
            return { ok: false, reason: String(err && err.message || err) };
        }
    }

    /**
     * Fire an immediate iOS banner notification. Falls back gracefully
     * to the web Notification API if the native bridge isn't reachable
     * (desktop browser / non-iOS), and to "no-op" if neither is
     * available — callers should treat this as a best-effort surface
     * and keep their in-app toast as the real source of truth.
     *
     * args = { title, subtitle, body, identifier, threadIdentifier,
     *          categoryIdentifier, sound, userInfo }
     *
     * iOS renders title in bold, subtitle in a slightly lighter bold below,
     * and body in regular weight underneath -- giving us three distinct
     * lines without HTML. Use subtitle for the "Now airborne" / "Just
     * landed" status line and body for the route / aircraft.
     */
    async function presentLocalNotification(args) {
        const payload = Object.assign({ sound: true }, args || {});
        if (!payload.title) return { ok: false, reason: 'missing_title' };

        // 1) Native iOS path — real system banner, works backgrounded too.
        if (detectIOS()) {
            const plugin = getPlugin();
            if (plugin && typeof plugin.presentLocalNotification === 'function') {
                try {
                    const res = await plugin.presentLocalNotification(payload);
                    return { ok: true, source: 'native', ...res };
                } catch (err) {
                    console.warn('[LiveActivity] presentLocalNotification failed:', err);
                    // fall through to web API attempt
                }
            }
        }

        // 2) Web Notification API fallback — works on desktop Safari,
        //    Chrome, Firefox. On iOS WKWebView this won't surface
        //    system banners, but it won't throw either. The web API has
        //    no subtitle, so we fold it into the body.
        try {
            if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
                const composedBody = [payload.subtitle, payload.body].filter(Boolean).join(' · ');
                const n = new Notification(payload.title, {
                    body: composedBody,
                    tag:  payload.identifier || undefined,
                    silent: payload.sound === false
                });
                return { ok: true, source: 'web', delivered: true };
            }
        } catch (_) {}

        return { ok: false, reason: 'unsupported' };
    }

    function toMs(value) {
        if (value == null) return undefined;
        if (value instanceof Date) return value.getTime();
        if (typeof value === 'number') return value;
        const parsed = Date.parse(value);
        return Number.isFinite(parsed) ? parsed : undefined;
    }

    async function start(payload) {
        if (!isSupported()) return { ok: false, reason: 'unsupported' };
        const plugin = getPlugin();
        if (!plugin || typeof plugin.start !== 'function') {
            return {
                ok: false,
                reason: 'native bridge unreachable (' + describeCapacitor() + ')'
            };
        }
        const args = {
            flightId: String(payload.flightId),
            callsign: payload.callsign || '',
            airlineName: payload.airlineName || '',
            aircraftType: payload.aircraftType || '',
            liveryName: payload.liveryName || '',
            registration: payload.registration || '',
            departureIcao: payload.departureIcao || '',
            arrivalIcao: payload.arrivalIcao || '',
            scheduledDepartureMs: toMs(payload.scheduledDeparture),
            scheduledArrivalMs: toMs(payload.scheduledArrival),
            currentEtaMs: toMs(payload.currentEta || payload.scheduledArrival),
            currentAtdMs: toMs(payload.currentAtd),
            distanceToDestinationNm: Number(payload.distanceToDestinationNm) || 0,
            // Total airport-to-airport distance, captured once at start so
            // the lock-screen progress bar can render done/total. Falls
            // back to the live remaining distance if the caller doesn't
            // know -- the bar will simply start near 0% in that case.
            totalDistanceNm: Number(payload.totalDistanceNm) || Number(payload.distanceToDestinationNm) || 0,
            isLanded: !!payload.isLanded
        };
        try {
            const res = await plugin.start(args);
            trackedFlights.add(args.flightId);
            lastUpdateByFlight.set(args.flightId, Date.now());
            rememberMeta(args.flightId, payload, false);
            window.dispatchEvent(new CustomEvent('inflightTrackingChanged', { detail: { flightId: args.flightId, tracking: true } }));
            return { ok: true, ...res };
        } catch (err) {
            console.warn('[LiveActivity] start failed:', err);
            return { ok: false, reason: String(err && err.message || err) };
        }
    }

    async function update(payload) {
        if (!isSupported()) return { ok: false, reason: 'unsupported' };
        const plugin = getPlugin();
        const flightId = String(payload.flightId);
        if (!trackedFlights.has(flightId)) {
            return { ok: false, reason: 'not_tracking' };
        }
        // Throttle: ActivityKit budget is generous but no need to push more often than once per 15s.
        const last = lastUpdateByFlight.get(flightId) || 0;
        if (Date.now() - last < 15000 && !payload.force) {
            return { ok: false, reason: 'throttled' };
        }
        const args = {
            flightId,
            currentEtaMs: toMs(payload.currentEta),
            currentAtdMs: toMs(payload.currentAtd),
            distanceToDestinationNm: Number(payload.distanceToDestinationNm) || 0,
            isLanded: !!payload.isLanded
        };
        try {
            await plugin.update(args);
            lastUpdateByFlight.set(flightId, Date.now());
            rememberMeta(flightId, payload, true);
            return { ok: true };
        } catch (err) {
            console.warn('[LiveActivity] update failed:', err);
            return { ok: false, reason: String(err && err.message || err) };
        }
    }

    async function end(payload) {
        if (!isSupported()) return { ok: false, reason: 'unsupported' };
        const plugin = getPlugin();
        const flightId = String(payload.flightId);
        try {
            await plugin.end({ flightId, immediate: !!payload.immediate });
            trackedFlights.delete(flightId);
            lastUpdateByFlight.delete(flightId);
            trackedMeta.delete(flightId);
            window.dispatchEvent(new CustomEvent('inflightTrackingChanged', { detail: { flightId, tracking: false } }));
            return { ok: true };
        } catch (err) {
            console.warn('[LiveActivity] end failed:', err);
            return { ok: false, reason: String(err && err.message || err) };
        }
    }

    function isTrackingFlight(flightId) {
        return trackedFlights.has(String(flightId));
    }

    function getTrackedFlightId() {
        // Back-compat: the oldest tracked flight. Newer callers should prefer
        // getTrackedFlightIds() now that Pro users can track several at once.
        return trackedFlights.values().next().value || null;
    }

    function getTrackedFlightIds() {
        return Array.from(trackedFlights);
    }

    function getTrackedCount() {
        return trackedFlights.size;
    }

    // Rich per-flight snapshots for the Inflight panel, in start order.
    function getTrackedFlights() {
        return Array.from(trackedFlights).map(id => {
            const m = trackedMeta.get(id) || { flightId: id };
            return Object.assign({ flightId: id }, m);
        });
    }

    // Plan limit: free tier tracks 1 flight, Pro tracks up to 3.
    function getTrackingLimit() {
        const isPro = (typeof window !== 'undefined' && typeof window.isInflightPro === 'function')
            ? window.isInflightPro()
            : false;
        return isPro ? 3 : 1;
    }

    async function openSystemSettings() {
        if (!detectIOS()) return { ok: false, reason: 'unsupported' };
        const plugin = getPlugin();
        if (!plugin || typeof plugin.openSystemSettings !== 'function') {
            return { ok: false, reason: 'unavailable' };
        }
        try {
            const res = await plugin.openSystemSettings();
            return { ok: true, ...res };
        } catch (err) {
            return { ok: false, reason: String(err && err.message || err) };
        }
    }

    window.InflightLiveActivity = {
        isSupported,
        start,
        update,
        end,
        isTrackingFlight,
        getTrackedFlightId,
        getTrackedFlightIds,
        getTrackedCount,
        getTrackedFlights,
        getTrackingLimit,
        requestNotificationPermission,
        getNotificationPermissionStatus,
        presentLocalNotification,
        openSystemSettings,
        describeCapacitor,
        // Diagnostic: returns everything we know about the bridge state.
        diagnose() {
            return {
                detectIOS: detectIOS(),
                capacitor: describeCapacitor(),
                plugin: !!getPlugin(),
                pluginMethods: (() => {
                    const p = getPlugin();
                    if (!p) return null;
                    return ['start', 'update', 'end', 'requestNotificationPermission',
                            'getNotificationPermissionStatus', 'openSystemSettings',
                            'areActivitiesEnabled']
                        .map(n => `${n}=${typeof p[n]}`).join(', ');
                })()
            };
        }
    };

    // Fire the iOS notification permission prompt on first launch (once).
    // We poll briefly because the Capacitor runtime is injected after our
    // IIFE on cold start — a single setTimeout misses the window.
    function maybePromptOnLaunch() {
        if (!detectIOS()) return;
        let attempts = 0;
        const tick = () => {
            attempts++;
            const plugin = getPlugin();
            if (plugin) {
                requestNotificationPermission();
                return;
            }
            if (attempts < 20) setTimeout(tick, 500);
        };
        setTimeout(tick, 800);
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', maybePromptOnLaunch);
        } else {
            maybePromptOnLaunch();
        }
    }
})();
