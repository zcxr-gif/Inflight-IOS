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

    function getPlugin() {
        if (pluginRef) return pluginRef;
        try {
            const cap = (typeof window !== 'undefined') ? window.Capacitor : null;
            if (!cap) return null;
            // Capacitor 5+ requires explicit registration on the JS side for
            // custom native plugins; Capacitor.Plugins.X is not auto-populated.
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
        if (typeof window === 'undefined') return false;
        if (typeof window.isIOSNative !== 'function' || !window.isIOSNative()) return false;
        return !!getPlugin();
    }

    async function requestNotificationPermission(opts) {
        if (!isSupported()) return { ok: false, reason: 'unsupported' };
        const force = !!(opts && opts.force);
        if (notificationPermissionRequested && !force) {
            return { ok: true, reason: 'already_requested' };
        }
        notificationPermissionRequested = true;
        const plugin = getPlugin();
        try {
            const res = await plugin.requestNotificationPermission();
            return { ok: true, ...res };
        } catch (err) {
            console.warn('[LiveActivity] requestNotificationPermission failed:', err);
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

    window.InflightLiveActivity = {
        isSupported,
        start,
        update,
        end,
        isTrackingFlight,
        getTrackedFlightId,
        requestNotificationPermission
    };

    // Fire the iOS notification permission prompt on first launch (once).
    // Without this, Live Activities still work but the user never sees the
    // standard "Allow Notifications" dialog and the OS can't deliver
    // remote/local notification updates.
    function maybePromptOnLaunch() {
        if (!isSupported()) return;
        setTimeout(() => { requestNotificationPermission(); }, 1200);
    }
    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', maybePromptOnLaunch);
        } else {
            maybePromptOnLaunch();
        }
    }
})();
