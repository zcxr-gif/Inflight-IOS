// Monitors window.fetch for slow / stuck requests and surfaces a single
// non-blocking toast when the connection is misbehaving. Exists because
// flight info, airport info, and profile fetches can hang indefinitely
// on poor cellular, which keeps promises (and their captured DOM /
// closure state) pinned in memory and degrades the UI silently.
//
// Behavior:
//   - 6s after a request is issued, it counts as "slow".
//   - When 2+ requests are slow at the same time, fire one toast.
//   - 30s cooldown so a flaky link doesn't spam toasts.
//   - Requests that exceed MAX_TIMEOUT_MS are aborted so their promises
//     resolve and stop holding references.
//   - Opt-out via { headers: { 'x-skip-slow-monitor': '1' } } or by
//     passing a caller-supplied AbortSignal (we still time it, but we
//     never override the caller's abort).

const SLOW_AFTER_MS = 6000;
const MAX_TIMEOUT_MS = 45000;
const TOAST_COOLDOWN_MS = 30000;
const SLOW_THRESHOLD = 2;

let _installed = false;
let _lastToastAt = 0;
let _slowCount = 0;

function fireToast() {
    const now = Date.now();
    if (now - _lastToastAt < TOAST_COOLDOWN_MS) return;
    _lastToastAt = now;

    const message = 'Slow connection — some data may take a moment to load.';
    try {
        if (typeof window.showGlobalNotification === 'function') {
            window.showGlobalNotification(message, 'info');
            return;
        }
    } catch (_) {}

    // Toastify fallback in case the global helper hasn't been wired yet
    // (e.g., a fetch fired during the very first frame of bootstrap).
    if (typeof window.Toastify === 'function') {
        try {
            window.Toastify({
                text: message,
                duration: 4000,
                close: true,
                gravity: 'top',
                position: 'right',
                style: { background: '#475569' }
            }).showToast();
        } catch (_) {}
    }
}

function shouldSkip(input, init) {
    try {
        const headers = init && init.headers;
        if (headers) {
            if (headers instanceof Headers) {
                if (headers.get('x-skip-slow-monitor') === '1') return true;
            } else if (typeof headers === 'object') {
                if (headers['x-skip-slow-monitor'] === '1') return true;
            }
        }
        const url = typeof input === 'string' ? input : (input?.url || '');
        // Don't monitor analytics beacons / socket polling — those are fire-and-forget.
        if (url.includes('/analytics') || url.includes('beacon')) return true;
    } catch (_) {}
    return false;
}

export function installSlowConnectionMonitor() {
    if (_installed) return;
    if (typeof window === 'undefined' || typeof window.fetch !== 'function') return;
    _installed = true;

    const originalFetch = window.fetch.bind(window);

    window.fetch = function wrappedFetch(input, init) {
        if (shouldSkip(input, init)) {
            return originalFetch(input, init);
        }

        const callerSignal = init && init.signal;
        const controller = new AbortController();
        const onCallerAbort = () => controller.abort(callerSignal?.reason);
        if (callerSignal) {
            if (callerSignal.aborted) controller.abort(callerSignal.reason);
            else callerSignal.addEventListener('abort', onCallerAbort, { once: true });
        }

        const nextInit = { ...(init || {}), signal: controller.signal };

        let slowMarked = false;
        const slowTimer = setTimeout(() => {
            slowMarked = true;
            _slowCount += 1;
            if (_slowCount >= SLOW_THRESHOLD) fireToast();
        }, SLOW_AFTER_MS);

        const hardTimer = setTimeout(() => {
            try { controller.abort(new DOMException('Request timed out', 'AbortError')); } catch (_) {}
        }, MAX_TIMEOUT_MS);

        const cleanup = () => {
            clearTimeout(slowTimer);
            clearTimeout(hardTimer);
            if (slowMarked) _slowCount = Math.max(0, _slowCount - 1);
            if (callerSignal) callerSignal.removeEventListener('abort', onCallerAbort);
        };

        return originalFetch(input, nextInit).then(
            (res) => { cleanup(); return res; },
            (err) => { cleanup(); throw err; }
        );
    };
}
