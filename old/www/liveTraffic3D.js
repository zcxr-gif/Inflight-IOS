/**
 * liveTraffic3D.js
 * -------------------------------------------------------------------
 * Renders LIVE traffic as a field of glowing, altitude-elevated contacts
 * on the main mapbox-gl map — the same visual language as the ATC replay's
 * 3D view (atcReplay.js), but fed from the live `currentMapFeatures`
 * instead of a recorded session clock.
 *
 * What makes this "alive" (vs. the original teleporting dot field):
 *  - SMOOTH MOTION: between the ~15s server updates each contact is
 *    dead-reckoned forward from its last fix using heading + ground speed
 *    + vertical speed, and the rendered position eases toward that
 *    prediction. No more snapping; the whole field drifts continuously.
 *  - COMET TRAILS: a short, additively-glowing trail fades out behind
 *    each moving contact, sampled from its real interpolated track.
 *  - LEADER VECTORS: a forward beam shows each aircraft's heading, its
 *    length scaled by speed — you can read the flow of traffic at a glance.
 *  - BEAM STEMS: the ground tether fades from bright (at the aircraft) to
 *    dark (at the ground) so altitude reads as a glowing column of light.
 *  - LIVING PULSE + SELECTED RETICLE: the field breathes subtly, and the
 *    currently-selected flight wears a pulsing ring so you never lose it.
 *
 * Everything is one THREE custom layer sharing the map's own WebGL context
 * (exactly like flownPath3D.js / atcReplay.js). Geometry is batched into a
 * handful of preallocated buffers — one draw call per primitive — so cost
 * stays flat regardless of contact count. While the field is visible we
 * drive a continuous repaint loop for the animation.
 *
 * Public API (see export at bottom):
 *   init(map, featuresProvider [, selectedProvider])
 *                                featuresProvider() -> array of GeoJSON
 *                                features (Object.values(currentMapFeatures));
 *                                selectedProvider() -> flightId of the
 *                                currently-selected contact (optional)
 *   setVisible(on)               toggle the 3D field; returns new state
 *   isVisible()                  -> boolean
 *   refresh()                    re-anchor tracks from the provider (call
 *                                after each live data update)
 */

export const LiveTraffic3D = (() => {
    const LYR_3D = 'live-traffic-3d';
    // Live traffic can be large; cap the buffers so a packed server can't
    // balloon GPU memory. Beyond this we simply stop adding contacts.
    const MAX_3D_DOTS = 4000;
    const ALT_EXAGGERATION = 2.5;   // vertical scale for dot/stem heights
    const DOT_SIZE_PX = 30;         // base on-screen dot size (no attenuation)

    // Motion / animation tuning.
    const EASE_TAU = 0.45;          // s; how quickly render pos chases the
                                    // dead-reckoned prediction (smaller = snappier)
    const MAX_DR_SECONDS = 30;      // cap dead-reckoning so a stale contact
                                    // doesn't sail off across the map forever
    const LEADER_SECONDS = 25;      // how far ahead the heading vector reaches
                                    // (in seconds of travel at current speed)
    const LEADER_MIN_KT = 25;       // below this we treat the contact as parked
    const TRAIL_LEN = 10;           // samples kept per comet trail
    const TRAIL_SAMPLE_MS = 260;    // spacing between trail samples
    const TRAIL_MAX_CONTACTS = 1600;// above this, trails are skipped (perf)
    const SPAWN_FADE_MS = 900;      // new contacts bloom in over this long

    const KT_TO_MS = 0.514444;      // knots -> metres/second
    const FT_TO_M = 0.3048;
    const DEG2RAD = Math.PI / 180;
    const M_PER_DEG_LAT = 111320;   // good enough for short dead-reckon steps

    // Flat 2D layers to hide while the 3D field is active so contacts don't
    // render twice. Missing layers are skipped silently.
    const FLAT_LAYERS = [
        'sector-ops-live-flights-layer',
        'sector-ops-live-flights-natural-layer',
        'sector-ops-live-flights-hover-layer',
        'sector-ops-live-flights-labels'
    ];

    let map = null;
    let three = null;
    let visible = false;
    let featuresProvider = null;
    let selectedProvider = null;
    // Per-flight motion state, keyed by flightId. See refresh()/animate().
    const tracks = new Map();
    // Projection we swapped away from when enabling 3D (e.g. 'globe'), so we
    // can restore it when the field is turned off. null = we didn't change it.
    let savedProjection = null;
    // The user's original minZoom, saved while we raise the floor to keep the
    // flat world filling the viewport. null = we haven't changed it.
    let savedMinZoom = null;
    let lastFrameT = 0;             // performance.now() of the previous frame

    // Altitude -> RGB (0..1), low (cyan) through high (red). Mirrors the
    // replay's altColor01 so live and replay read identically.
    function altColor01(alt) {
        const stops = [
            [0, [56, 189, 248]], [10000, [45, 212, 191]], [20000, [163, 230, 53]],
            [30000, [250, 204, 21]], [40000, [244, 63, 94]]
        ];
        const a = Math.max(0, Math.min(40000, alt || 0));
        let s1 = stops[0], s2 = stops[stops.length - 1];
        for (let i = 0; i < stops.length - 1; i++) {
            if (a >= stops[i][0] && a <= stops[i + 1][0]) { s1 = stops[i]; s2 = stops[i + 1]; break; }
        }
        const range = s2[0] - s1[0], f = range === 0 ? 0 : (a - s1[0]) / range;
        return [
            (s1[1][0] + (s2[1][0] - s1[1][0]) * f) / 255,
            (s1[1][1] + (s2[1][1] - s1[1][1]) * f) / 255,
            (s1[1][2] + (s2[1][2] - s1[1][2]) * f) / 255
        ];
    }

    // Soft radial sprite so each point renders as a glowing orb rather than
    // a hard square, tinted per-aircraft by the vertex colour. A bright core
    // with a wide falloff gives each contact a pronounced bloom.
    function makeGlowTexture() {
        const THREE = window.THREE;
        const size = 64;
        const c = document.createElement('canvas');
        c.width = c.height = size;
        const ctx = c.getContext('2d');
        const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
        g.addColorStop(0, 'rgba(255,255,255,1)');
        g.addColorStop(0.35, 'rgba(255,255,255,0.95)');
        g.addColorStop(0.7, 'rgba(255,255,255,0.45)');
        g.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, size, size);
        const tex = new THREE.CanvasTexture(c);
        tex.needsUpdate = true;
        return tex;
    }

    // A glowing ring/reticle sprite used to mark the selected contact.
    function makeRingTexture() {
        const THREE = window.THREE;
        const size = 128;
        const c = document.createElement('canvas');
        c.width = c.height = size;
        const ctx = c.getContext('2d');
        ctx.translate(size / 2, size / 2);
        // Two concentric soft rings.
        for (const r of [size * 0.32, size * 0.46]) {
            ctx.beginPath();
            ctx.arc(0, 0, r, 0, Math.PI * 2);
            ctx.lineWidth = size * 0.045;
            ctx.strokeStyle = 'rgba(255,255,255,0.95)';
            ctx.shadowColor = 'rgba(255,255,255,0.9)';
            ctx.shadowBlur = size * 0.08;
            ctx.stroke();
        }
        const tex = new THREE.CanvasTexture(c);
        tex.needsUpdate = true;
        return tex;
    }

    // Advance a lat/lon by `metres` along `headingDeg` (0 = N, clockwise).
    // Small-step flat-earth approximation — fine for ≤ a few km of reckoning.
    function deadReckon(lat, lon, headingDeg, metres) {
        const h = (headingDeg || 0) * DEG2RAD;
        const dN = metres * Math.cos(h);
        const dE = metres * Math.sin(h);
        const cosLat = Math.max(0.01, Math.cos(lat * DEG2RAD));
        return [
            lat + dN / M_PER_DEG_LAT,
            lon + dE / (M_PER_DEG_LAT * cosLat)
        ];
    }

    // Build the custom layer once (lazily, on first enable). Preallocated
    // buffers for dots (glow), stems, leader vectors and comet trails, plus a
    // single sprite for the selected-contact reticle.
    function ensureLayer() {
        if (!map || three || !window.THREE || !window.mapboxgl) return;
        if (map.getLayer(LYR_3D)) return;
        const THREE = window.THREE;
        const self = { visible: false };
        const glowTex = makeGlowTexture();
        const ringTex = makeRingTexture();
        const trailVerts = MAX_3D_DOTS * (TRAIL_LEN - 1) * 2; // 2 verts/segment

        const layer = {
            id: LYR_3D, type: 'custom', renderingMode: '3d',
            onAdd(m, gl) {
                self.camera = new THREE.Camera();
                self.scene = new THREE.Scene();

                // --- glowing contact dots (additive points) ---
                self.dotGeo = new THREE.BufferGeometry();
                self.dotGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 3), 3));
                self.dotGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 3), 3));
                self.dotMat = new THREE.PointsMaterial({
                    size: DOT_SIZE_PX, sizeAttenuation: false, map: glowTex,
                    vertexColors: true, transparent: true, depthWrite: false,
                    blending: THREE.AdditiveBlending
                });
                self.dots = new THREE.Points(self.dotGeo, self.dotMat);
                self.dots.frustumCulled = false;
                self.scene.add(self.dots);

                // --- altitude stems (beam: bright top -> dark ground) ---
                self.stemGeo = new THREE.BufferGeometry();
                self.stemGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.stemGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.stemMat = new THREE.LineBasicMaterial({
                    vertexColors: true, transparent: true, opacity: 0.55,
                    depthWrite: false, blending: THREE.AdditiveBlending
                });
                self.stems = new THREE.LineSegments(self.stemGeo, self.stemMat);
                self.stems.frustumCulled = false;
                self.scene.add(self.stems);

                // --- heading leader vectors (bright at nose -> faded ahead) ---
                self.leadGeo = new THREE.BufferGeometry();
                self.leadGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.leadGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.leadMat = new THREE.LineBasicMaterial({
                    vertexColors: true, transparent: true, opacity: 0.85,
                    depthWrite: false, blending: THREE.AdditiveBlending
                });
                self.leaders = new THREE.LineSegments(self.leadGeo, self.leadMat);
                self.leaders.frustumCulled = false;
                self.scene.add(self.leaders);

                // --- comet trails (per-vertex fade toward the tail) ---
                self.trailGeo = new THREE.BufferGeometry();
                self.trailGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(trailVerts * 3), 3));
                self.trailGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(trailVerts * 3), 3));
                self.trailMat = new THREE.LineBasicMaterial({
                    vertexColors: true, transparent: true, opacity: 0.7,
                    depthWrite: false, blending: THREE.AdditiveBlending
                });
                self.trails = new THREE.LineSegments(self.trailGeo, self.trailMat);
                self.trails.frustumCulled = false;
                self.scene.add(self.trails);

                // --- selected-contact reticle (single pulsing ring sprite) ---
                self.selGeo = new THREE.BufferGeometry();
                self.selGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(3), 3));
                self.selMat = new THREE.PointsMaterial({
                    size: DOT_SIZE_PX * 3.2, sizeAttenuation: false, map: ringTex,
                    color: 0xffffff, transparent: true, opacity: 0.0,
                    depthWrite: false, blending: THREE.AdditiveBlending
                });
                self.sel = new THREE.Points(self.selGeo, self.selMat);
                self.sel.frustumCulled = false;
                self.scene.add(self.sel);

                self.renderer = new THREE.WebGLRenderer({ canvas: m.getCanvas(), context: gl, antialias: true });
                self.renderer.autoClear = false;
                self.glowTex = glowTex;
                self.ringTex = ringTex;
            },
            render(gl, matrix) {
                if (!self.renderer || !self.visible) return;
                // Advance the animation, then draw, then ask for the next frame
                // so the field keeps moving between server updates.
                try { animate(); } catch (_) {}
                self.camera.projectionMatrix = new THREE.Matrix4().fromArray(matrix);
                self.renderer.resetState();
                self.renderer.render(self.scene, self.camera);
                if (self.visible && map) map.triggerRepaint();
            }
        };
        try { map.addLayer(layer); three = self; } catch (e) { console.warn('[LiveTraffic3D] 3D layer add failed:', e); }
    }

    // Re-anchor tracks from the current live features. This sets each
    // contact's authoritative fix + velocity; the per-frame animate() loop
    // does the actual smooth motion. No-op unless the field is showing, so
    // the flat map costs nothing.
    function refresh() {
        if (!three || !three.visible || !map || !featuresProvider) return;
        const feats = featuresProvider() || [];
        const now = (typeof performance !== 'undefined' ? performance.now() : Date.now());
        const seen = new Set();
        for (const f of feats) {
            if (!f || !f.geometry || !f.geometry.coordinates) continue;
            const [lon, lat] = f.geometry.coordinates;
            if (!isFinite(lon) || !isFinite(lat)) continue;
            const p = f.properties || {};
            const id = p.flightId != null ? String(p.flightId) : (p.callsign || (lon + ',' + lat));
            seen.add(id);
            const alt = p.altitude || 0;
            const col = altColor01(alt);
            let t = tracks.get(id);
            if (!t) {
                // New contact: render position starts at the fix and blooms in.
                t = {
                    rLat: lat, rLon: lon, rAlt: alt,
                    trail: [], lastTrailT: now, bornT: now
                };
                tracks.set(id, t);
            }
            // Authoritative fix + velocity (re-anchored every update).
            t.lat = lat; t.lon = lon; t.alt = alt;
            t.hdg = p.heading || 0;
            t.spd = p.speed || 0;          // knots, ground speed
            t.vs = p.verticalSpeed || 0;   // ft/min
            t.col = col;
            t.t0 = now;
        }
        // Drop contacts that disappeared from the feed.
        for (const id of tracks.keys()) {
            if (!seen.has(id)) tracks.delete(id);
        }
        if (map) map.triggerRepaint();
    }

    // Per-frame: dead-reckon every track forward, ease the rendered position
    // toward that prediction, sample trails, and rebuild all the GPU buffers.
    function animate() {
        if (!three || !three.visible || !window.mapboxgl) return;
        const Merc = window.mapboxgl.MercatorCoordinate;
        const now = (typeof performance !== 'undefined' ? performance.now() : Date.now());
        const dt = lastFrameT ? Math.min(0.1, (now - lastFrameT) / 1000) : 0.016;
        lastFrameT = now;
        const ease = 1 - Math.exp(-dt / EASE_TAU);  // frame-rate-independent
        const pulse = 1 + 0.07 * Math.sin(now / 360); // gentle global breathing

        const dotPos = three.dotGeo.attributes.position, dotCol = three.dotGeo.attributes.color;
        const stemPos = three.stemGeo.attributes.position, stemCol = three.stemGeo.attributes.color;
        const leadPos = three.leadGeo.attributes.position, leadCol = three.leadGeo.attributes.color;
        const trailPos = three.trailGeo.attributes.position, trailCol = three.trailGeo.attributes.color;

        const wantTrails = tracks.size <= TRAIL_MAX_CONTACTS;
        const selId = selectedProvider ? (() => { try { return selectedProvider(); } catch (_) { return null; } })() : null;
        let selMerc = null, selCol = null;

        let n = 0;      // contact index
        let tv = 0;     // trail vertex index
        for (const [id, t] of tracks) {
            if (n >= MAX_3D_DOTS) break;

            // --- dead-reckon the authoritative fix forward by elapsed time ---
            const age = Math.min(MAX_DR_SECONDS, (now - t.t0) / 1000);
            const dist = (t.spd || 0) * KT_TO_MS * age;
            const [pLat, pLon] = dist > 0.5 ? deadReckon(t.lat, t.lon, t.hdg, dist) : [t.lat, t.lon];
            const pAlt = Math.max(0, t.alt + (t.vs || 0) / 60 * age);

            // --- ease the rendered position toward the prediction ---
            t.rLat += (pLat - t.rLat) * ease;
            t.rLon += (pLon - t.rLon) * ease;
            t.rAlt += (pAlt - t.rAlt) * ease;

            const m = Merc.fromLngLat([t.rLon, t.rLat], t.rAlt * FT_TO_M * ALT_EXAGGERATION);
            const c = t.col || [1, 1, 1];

            // Spawn bloom: new contacts fade up over SPAWN_FADE_MS.
            const life = Math.min(1, (now - t.bornT) / SPAWN_FADE_MS);
            const k = life * pulse;

            // --- dot ---
            dotPos.setXYZ(n, m.x, m.y, m.z);
            dotCol.setXYZ(n, c[0] * k, c[1] * k, c[2] * k);

            // --- beam stem: bright at the aircraft, dark at the ground ---
            const ground = Merc.fromLngLat([t.rLon, t.rLat], 0);
            stemPos.setXYZ(n * 2, ground.x, ground.y, 0);
            stemCol.setXYZ(n * 2, c[0] * 0.04, c[1] * 0.04, c[2] * 0.04);
            stemPos.setXYZ(n * 2 + 1, m.x, m.y, m.z);
            stemCol.setXYZ(n * 2 + 1, c[0] * life, c[1] * life, c[2] * life);

            // --- heading leader vector (length scaled by speed) ---
            if ((t.spd || 0) > LEADER_MIN_KT) {
                const lead = t.spd * KT_TO_MS * LEADER_SECONDS;
                const [lLat, lLon] = deadReckon(t.rLat, t.rLon, t.hdg, lead);
                const lm = Merc.fromLngLat([lLon, lLat], t.rAlt * FT_TO_M * ALT_EXAGGERATION);
                leadPos.setXYZ(n * 2, m.x, m.y, m.z);
                leadCol.setXYZ(n * 2, c[0] * 0.9 * life, c[1] * 0.9 * life, c[2] * 0.9 * life);
                leadPos.setXYZ(n * 2 + 1, lm.x, lm.y, lm.z);
                leadCol.setXYZ(n * 2 + 1, 0, 0, 0); // fade out ahead
            } else {
                // Degenerate (zero-length) segment for parked contacts.
                leadPos.setXYZ(n * 2, m.x, m.y, m.z);
                leadCol.setXYZ(n * 2, 0, 0, 0);
                leadPos.setXYZ(n * 2 + 1, m.x, m.y, m.z);
                leadCol.setXYZ(n * 2 + 1, 0, 0, 0);
            }

            // --- comet trail sampling + buffer fill ---
            if (wantTrails) {
                if (now - t.lastTrailT > TRAIL_SAMPLE_MS) {
                    t.trail.push([t.rLon, t.rLat, t.rAlt]);
                    if (t.trail.length > TRAIL_LEN) t.trail.shift();
                    t.lastTrailT = now;
                }
                const tr = t.trail;
                for (let i = 0; i + 1 < tr.length; i++) {
                    const a = tr[i], b = tr[i + 1];
                    const ma = Merc.fromLngLat([a[0], a[1]], a[2] * FT_TO_M * ALT_EXAGGERATION);
                    const mb = Merc.fromLngLat([b[0], b[1]], b[2] * FT_TO_M * ALT_EXAGGERATION);
                    // Fade from tail (dim) to head (bright).
                    const fa = (i / TRAIL_LEN) * 0.5 * life;
                    const fb = ((i + 1) / TRAIL_LEN) * 0.7 * life;
                    trailPos.setXYZ(tv, ma.x, ma.y, ma.z);
                    trailCol.setXYZ(tv, c[0] * fa, c[1] * fa, c[2] * fa); tv++;
                    trailPos.setXYZ(tv, mb.x, mb.y, mb.z);
                    trailCol.setXYZ(tv, c[0] * fb, c[1] * fb, c[2] * fb); tv++;
                }
            } else if (t.trail.length) {
                t.trail.length = 0;
            }

            // Remember the selected contact's position for the reticle.
            if (selId != null && id === String(selId)) { selMerc = m; selCol = c; }

            n++;
        }

        three.dotGeo.setDrawRange(0, n);
        three.stemGeo.setDrawRange(0, n * 2);
        three.leadGeo.setDrawRange(0, n * 2);
        three.trailGeo.setDrawRange(0, tv);
        dotPos.needsUpdate = dotCol.needsUpdate = true;
        stemPos.needsUpdate = stemCol.needsUpdate = true;
        leadPos.needsUpdate = leadCol.needsUpdate = true;
        trailPos.needsUpdate = trailCol.needsUpdate = true;

        // --- selected reticle: pulse in/out at the selected contact ---
        if (selMerc) {
            three.selGeo.attributes.position.setXYZ(0, selMerc.x, selMerc.y, selMerc.z);
            three.selGeo.attributes.position.needsUpdate = true;
            three.selMat.size = DOT_SIZE_PX * (3.0 + 0.6 * Math.sin(now / 240));
            three.selMat.opacity = 0.55 + 0.35 * (0.5 + 0.5 * Math.sin(now / 240));
            if (selCol) three.selMat.color.setRGB(
                0.6 + 0.4 * selCol[0], 0.6 + 0.4 * selCol[1], 0.6 + 0.4 * selCol[2]);
            three.selGeo.setDrawRange(0, 1);
        } else {
            three.selGeo.setDrawRange(0, 0);
        }
    }

    function init(mapInstance, provider, selProvider) {
        map = mapInstance;
        featuresProvider = provider;
        selectedProvider = selProvider || null;
    }

    // Raise the map's minZoom so the flat (mercator) world covers the full
    // viewport height, preventing the gray void above/below the poles from
    // showing. The world is 512*2^zoom px tall, so we need 2^zoom >= H/512.
    function applyFlatMinZoom() {
        if (!map || !map.setMinZoom) return;
        try {
            const el = map.getContainer && map.getContainer();
            const h = el ? el.clientHeight : 0;
            if (!h) return;
            // 1.05 margin guards against fractional rounding / slight pitch.
            const fillZoom = Math.max(0, Math.log2((h * 1.05) / 512));
            if (savedMinZoom === null) {
                savedMinZoom = (map.getMinZoom && map.getMinZoom()) || 0;
            }
            map.setMinZoom(fillZoom);
            if (map.getZoom && map.getZoom() < fillZoom) {
                map.easeTo({ zoom: fillZoom, duration: 250 });
            }
        } catch (_) {}
    }

    // Swap between the flat 2D icons and the 3D field.
    function setVisible(on) {
        on = !!on;
        if (on) ensureLayer();
        visible = on;
        if (three) three.visible = on;
        lastFrameT = 0; // reset the animation clock so dt doesn't spike

        // The elevated contacts are placed with a mercator custom-layer matrix,
        // which doesn't line up on the curved globe. Mirror the ATC replay:
        // drop to a flat (mercator) projection while the 3D field is up, then
        // restore the user's projection (e.g. globe) when it's switched off.
        if (map && map.setProjection) {
            try {
                if (on) {
                    const cur = (map.getProjection && map.getProjection().name) || 'mercator';
                    if (cur !== 'mercator') {
                        savedProjection = cur;
                        map.setProjection('mercator');
                    }
                    // Flat mercator can't draw the poles, so when zoomed out (or
                    // panned to the top/bottom edge) the gray void beyond the
                    // world shows. Raise the zoom floor so the world always
                    // fills the viewport vertically and the edges stay off-screen.
                    applyFlatMinZoom();
                } else {
                    if (savedProjection) {
                        map.setProjection(savedProjection);
                        savedProjection = null;
                    }
                    if (savedMinZoom !== null) {
                        try { map.setMinZoom(savedMinZoom); } catch (_) {}
                        savedMinZoom = null;
                    }
                }
            } catch (_) {}
        }

        const flatVis = on ? 'none' : 'visible';
        FLAT_LAYERS.forEach(id => {
            if (map && map.getLayer(id)) {
                try { map.setLayoutProperty(id, 'visibility', flatVis); } catch (_) {}
            }
        });
        if (on) refresh();
        else tracks.clear();
        if (map) map.triggerRepaint();
        return visible;
    }

    function isVisible() { return visible; }

    return { init, setVisible, isVisible, refresh };
})();
