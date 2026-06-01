/**
 * metadataRefresh.js
 * --------------------------------------------------------------------------
 * Manual aircraft/livery metadata refresh. When Infinite Flight ships new
 * planes or liveries, this lets the app pull them without a backend restart.
 *
 *   GET  /api/metadata
 *        -> { ok, aircraft:[...], liveries:[...],
 *             counts:{ aircraft, liveries }, lastUpdated }   // epoch ms | null
 *
 *   POST /api/admin/refresh-metadata
 *        -> re-fetches + hot-swaps in memory.
 *        success: { ok:true, message, aircraft:N, liveries:M, lastUpdated }
 *        errors:  403 (METADATA_REFRESH_SECRET required via x-admin-secret
 *                      header or ?secret=), 502 (IF fetch failed; old data kept)
 *
 * The POST is safe to double-click — overlapping refreshes collapse to one
 * in-flight request (we dedupe client-side too).
 */
export const MetadataRefresh = (() => {
    const BACKEND = (typeof window !== 'undefined' && window.APP_CONFIG?.backendUrl)
        || 'https://site--acars-backend--6dmjph8ltlhv.code.run';

    // An admin secret, if the deployment requires one. Pulled from app config
    // so we never hard-code it. Left null when the backend is open.
    function adminSecret() {
        return (typeof window !== 'undefined'
            && (window.APP_CONFIG?.metadataRefreshSecret || window.CONFIG?.METADATA_REFRESH_SECRET))
            || null;
    }

    let inflight = null; // shared promise so double-clicks collapse to one POST

    function formatRelative(ms) {
        if (!ms) return 'never';
        const diff = Date.now() - ms;
        if (diff < 0) return 'just now';
        const s = Math.floor(diff / 1000);
        if (s < 60) return 'just now';
        const m = Math.floor(s / 60);
        if (m < 60) return `${m} min${m === 1 ? '' : 's'} ago`;
        const h = Math.floor(m / 60);
        if (h < 24) return `${h} hour${h === 1 ? '' : 's'} ago`;
        const d = Math.floor(h / 24);
        return `${d} day${d === 1 ? '' : 's'} ago`;
    }

    async function getMetadata() {
        const res = await fetch(`${BACKEND}/api/metadata`);
        if (!res.ok) throw new Error(`metadata ${res.status}`);
        return res.json();
    }

    async function refresh() {
        if (inflight) return inflight; // collapse overlapping refreshes
        inflight = (async () => {
            const headers = {};
            let url = `${BACKEND}/api/admin/refresh-metadata`;
            const secret = adminSecret();
            if (secret) headers['x-admin-secret'] = secret;
            const res = await fetch(url, { method: 'POST', headers });
            let body = null;
            try { body = await res.json(); } catch { /* non-JSON error body */ }
            if (res.status === 403) {
                const e = new Error('Refresh requires an admin secret.');
                e.code = 403; throw e;
            }
            if (res.status === 502) {
                const e = new Error('Infinite Flight metadata fetch failed (existing data kept).');
                e.code = 502; throw e;
            }
            if (!res.ok || !body || body.ok === false) {
                const e = new Error((body && body.message) || `Refresh failed (${res.status}).`);
                e.code = res.status; throw e;
            }
            return body; // { ok, message, aircraft, liveries, lastUpdated }
        })();
        try {
            return await inflight;
        } finally {
            inflight = null;
        }
    }

    return { getMetadata, refresh, formatRelative };
})();

if (typeof window !== 'undefined') window.MetadataRefresh = MetadataRefresh;
