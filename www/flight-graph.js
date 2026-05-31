/**
 * flight-graph.js — dependency-free Speed & Altitude time-series chart.
 *
 * Renders a FlightRadar24-style graph (barometric altitude + ground speed
 * over UTC time) from a flight's position history. Shared by both flight-info
 * windows: the full avionics window (same document as flight.js) and the
 * simple window (loaded inside an iframe), so they stay visually identical.
 *
 * Point parsing is intentionally tolerant: the /history endpoint is read in
 * two different shapes across the app — a flat shape ({date, latitude,
 * altitude, groundSpeed}) and a nested one ({position:{lat, alt_ft, gs_kt,
 * lastReportMs}}). We accept either, plus live-trail points.
 *
 * Exposes window.FlightGraph = { extractSeries, render, buildSVG, normalize }.
 */
(function (global) {
    'use strict';

    const ALT_COLOR = '#38bdf8';
    const GS_COLOR  = '#f59e0b';
    const GRID      = 'rgba(255,255,255,0.08)';
    const TEXT      = '#94a3b8';

    function num(v) { return (typeof v === 'number' && !isNaN(v)) ? v : null; }

    function pointTime(p) {
        if (!p) return null;
        if (p.date) { const t = Date.parse(p.date); if (!isNaN(t)) return t; }
        if (num(p.lastReportMs) != null) return p.lastReportMs;
        if (p.position) {
            if (num(p.position.lastReportMs) != null) return p.position.lastReportMs;
            if (p.position.lastReport) { const t = Date.parse(p.position.lastReport); if (!isNaN(t)) return t; }
        }
        if (num(p.timestamp) != null) return p.timestamp;
        return null;
    }

    function pointAlt(p) {
        if (!p) return null;
        let v = num(p.altitude); if (v != null) return v;
        v = num(p.alt_ft); if (v != null) return v;
        if (p.position) {
            v = num(p.position.alt_ft); if (v != null) return v;
            v = num(p.position.altitude); if (v != null) return v;
        }
        return null;
    }

    function pointGs(p) {
        if (!p) return null;
        let v = num(p.groundSpeed); if (v != null) return v;
        v = num(p.gs_kt); if (v != null) return v;
        v = num(p.speed); if (v != null) return v;
        if (p.position) {
            v = num(p.position.gs_kt); if (v != null) return v;
            v = num(p.position.groundSpeed); if (v != null) return v;
        }
        return null;
    }

    /**
     * Turn raw history/trail points into a compact, chronological series of
     * { t (ms), alt (ft|null), gs (kt|null) } samples, downsampled so it stays
     * cheap to render and light to postMessage. Endpoints are preserved.
     */
    function extractSeries(points, maxSamples) {
        maxSamples = maxSamples || 240;
        const out = { samples: [], hasGs: false, hasAlt: false };
        if (!Array.isArray(points) || points.length === 0) return out;

        let arr = [];
        for (const p of points) {
            const t = pointTime(p);
            if (t == null) continue;
            const alt = pointAlt(p);
            const gs = pointGs(p);
            if (alt == null && gs == null) continue;
            arr.push({ t, alt, gs });
        }
        if (arr.length === 0) return out;

        arr.sort((a, b) => a.t - b.t);

        if (arr.length > maxSamples) {
            const step = arr.length / maxSamples;
            const ds = [];
            for (let i = 0; i < maxSamples; i++) ds.push(arr[Math.floor(i * step)]);
            ds.push(arr[arr.length - 1]); // always keep the most recent point
            arr = ds;
        }

        out.samples = arr;
        out.hasAlt = arr.some(s => s.alt != null);
        out.hasGs = arr.some(s => s.gs != null);
        return out;
    }

    // Accept either a pre-extracted series object or a raw point array.
    function normalize(input) {
        if (input && Array.isArray(input.samples)) return input;
        return extractSeries(input);
    }

    function fmtUtc(ms) {
        const d = new Date(ms);
        return String(d.getUTCHours()).padStart(2, '0') + ':' + String(d.getUTCMinutes()).padStart(2, '0');
    }

    function buildSVG(series, W, H) {
        const padTop = 14, padBottom = 26, padLeft = 52, padRight = 46;
        const x0 = padLeft, x1 = W - padRight, y0 = padTop, y1 = H - padBottom;
        const plotW = Math.max(1, x1 - x0), plotH = Math.max(1, y1 - y0);
        const s = series.samples;

        if (!s || s.length < 2) {
            return `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">`
                + `<text x="${W / 2}" y="${H / 2}" fill="${TEXT}" font-size="11" font-family="Inter,sans-serif" text-anchor="middle">Awaiting flight history…</text></svg>`;
        }

        let tMin = s[0].t, tMax = s[s.length - 1].t;
        if (tMax <= tMin) tMax = tMin + 1;

        let maxAlt = 0, maxGs = 0;
        for (const p of s) {
            if (p.alt != null && p.alt > maxAlt) maxAlt = p.alt;
            if (p.gs != null && p.gs > maxGs) maxGs = p.gs;
        }
        // ~3% headroom so the peak never touches the top gridline (matches FR24).
        const altMax = Math.max(1000, maxAlt * 1.03);
        const gsMax  = Math.max(60, maxGs * 1.03);

        const xOf  = t => x0 + ((t - tMin) / (tMax - tMin)) * plotW;
        const yAlt = v => y1 - (v / altMax) * plotH;
        const yGs  = v => y1 - (v / gsMax) * plotH;

        const N = 5;
        let grid = '';
        for (let i = 0; i <= N; i++) {
            const y = y0 + (plotH * i / N);
            grid += `<line x1="${x0}" y1="${y.toFixed(1)}" x2="${x1}" y2="${y.toFixed(1)}" stroke="${GRID}" stroke-width="1"/>`;
            const altLabel = Math.round(altMax * (N - i) / N).toLocaleString();
            grid += `<text x="${x0 - 6}" y="${(y + 3).toFixed(1)}" fill="${ALT_COLOR}" font-size="9" font-family="'JetBrains Mono',monospace" text-anchor="end" opacity="0.85">${altLabel}</text>`;
            if (series.hasGs) {
                const gsLabel = Math.round(gsMax * (N - i) / N);
                grid += `<text x="${x1 + 6}" y="${(y + 3).toFixed(1)}" fill="${GS_COLOR}" font-size="9" font-family="'JetBrains Mono',monospace" text-anchor="start" opacity="0.85">${gsLabel}</text>`;
            }
        }

        let timeLabels = '';
        const T = 5;
        for (let i = 0; i <= T; i++) {
            const t = tMin + ((tMax - tMin) * i / T);
            const x = xOf(t);
            const anchor = i === 0 ? 'start' : (i === T ? 'end' : 'middle');
            timeLabels += `<text x="${x.toFixed(1)}" y="${(y1 + 16).toFixed(1)}" fill="${TEXT}" font-size="9" font-family="'JetBrains Mono',monospace" text-anchor="${anchor}">${fmtUtc(t)}</text>`;
        }

        function pathFor(getY, key) {
            let d = '', started = false;
            for (const p of s) {
                if (p[key] == null) { started = false; continue; }
                const x = xOf(p.t), y = getY(p[key]);
                d += (started ? ' L ' : ' M ') + x.toFixed(1) + ' ' + y.toFixed(1);
                started = true;
            }
            return d;
        }

        let paths = '';
        if (series.hasAlt) paths += `<path d="${pathFor(yAlt, 'alt')}" fill="none" stroke="${ALT_COLOR}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;
        if (series.hasGs)  paths += `<path d="${pathFor(yGs, 'gs')}" fill="none" stroke="${GS_COLOR}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;

        return `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg" style="display:block;width:100%;height:auto">`
            + grid + paths + timeLabels
            + `<text x="${x0 - 6}" y="${(y0 - 3).toFixed(1)}" fill="${ALT_COLOR}" font-size="8" font-family="Inter,sans-serif" text-anchor="end" opacity="0.7">FEET</text>`
            + (series.hasGs ? `<text x="${x1 + 6}" y="${(y0 - 3).toFixed(1)}" fill="${GS_COLOR}" font-size="8" font-family="Inter,sans-serif" text-anchor="start" opacity="0.7">KTS</text>` : '')
            + `</svg>`;
    }

    function legendHTML(series) {
        const chip = (color, label) =>
            `<span style="display:inline-flex;align-items:center;gap:5px;font-size:9px;font-weight:700;letter-spacing:.4px;color:${TEXT};text-transform:uppercase;">`
            + `<span style="width:14px;height:3px;border-radius:2px;background:${color};"></span>${label}</span>`;
        let html = '<div class="fg-legend" style="display:flex;gap:14px;align-items:center;justify-content:center;flex-wrap:wrap;margin-bottom:6px;">';
        if (series.hasAlt) html += chip(ALT_COLOR, 'Barometric Altitude');
        if (series.hasGs)  html += chip(GS_COLOR, 'Ground Speed');
        html += '</div>';
        return html;
    }

    /**
     * Render the chart into a container element.
     * @param {HTMLElement} container
     * @param {Object|Array} input  series object ({samples,hasGs,hasAlt}) or raw points
     * @param {Object} [opts] { height, width }
     */
    function render(container, input, opts) {
        if (!container) return;
        opts = opts || {};
        const series = normalize(input);
        const H = opts.height || 180;
        let W = container.clientWidth;
        if (!W || W < 60) W = opts.width || 340;

        if (!series.samples || series.samples.length < 2) {
            container.innerHTML = `<div style="height:${H}px;display:flex;align-items:center;justify-content:center;color:${TEXT};font-size:11px;font-family:Inter,sans-serif;font-style:italic;">Awaiting flight history…</div>`;
            return;
        }
        container.innerHTML = legendHTML(series) + buildSVG(series, W, H);
    }

    global.FlightGraph = { extractSeries, render, buildSVG, normalize };

})(typeof window !== 'undefined' ? window : this);
