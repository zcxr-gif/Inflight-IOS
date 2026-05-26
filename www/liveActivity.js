// Thin JS wrapper around the iOS LiveActivityPlugin (ActivityKit bridge).
// On non-iOS or non-supporting devices every call is a silent no-op.
//
// Public API on window.InflightLiveActivity:
//   start({ flightId, callsign, airlineName, departureIcao, arrivalIcao,
//           scheduledDeparture, scheduledArrival, currentEta,
//           currentAtd, distanceToDestinationNm, isLanded }) -> Promise
//   update({ flightId, currentEta, currentAtd,
//            distanceToDestinationNm, isLanded }) -> Promise
//   end({ flightId, immediate }) -> Promise
//   isTrackingFlight(flightId) -> bool
//   getTrackedFlightId() -> string | null

(function () {
    const trackedFlights = new Set();
    let lastUpdateByFlight = new Map();
    let pluginRef = null;
    let notificationPermissionRequested = false;

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
            // Capacitor 5+ requires explicit registration on the JS side for
            // custom native plugins; Capacitor.Plugins.X is not auto-populated.
            // Importantly: do NOT cache `null` if Capacitor isn't loaded yet —
            // the runtime is injected after our IIFE on cold start, so a one-
            // shot lookup would lock isSupported() to false for the session.
            if (typeof cap.registerPlugin === 'function') {
                pluginRef = cap.registerPlugin('LiveActivity');
                return pluginRef;
            }
            if (cap.Plugins && cap.Plugins.LiveActivity) {
                pluginRef = cap.Plugins.LiveActivity;
                return pluginRef;
            }
            return null;
        } catch (_) {
            return null;
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
        if (!plugin) return { ok: false, reason: 'plugin_unavailable' };
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
        const args = {
            flightId: String(payload.flightId),
            callsign: payload.callsign || '',
            airlineName: payload.airlineName || '',
            departureIcao: payload.departureIcao || '',
            arrivalIcao: payload.arrivalIcao || '',
            scheduledDepartureMs: toMs(payload.scheduledDeparture),
            scheduledArrivalMs: toMs(payload.scheduledArrival),
            currentEtaMs: toMs(payload.currentEta || payload.scheduledArrival),
            currentAtdMs: toMs(payload.currentAtd),
            distanceToDestinationNm: Number(payload.distanceToDestinationNm) || 0,
            isLanded: !!payload.isLanded
        };
        try {
            const res = await plugin.start(args);
            trackedFlights.add(args.flightId);
            lastUpdateByFlight.set(args.flightId, Date.now());
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
        // We only intend one Live Activity at a time for "my flight" — return the first.
        return trackedFlights.values().next().value || null;
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
        requestNotificationPermission,
        getNotificationPermissionStatus,
        openSystemSettings
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
