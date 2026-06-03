/**
 * liveTraffic3D.js
 * -------------------------------------------------------------------
 * Renders LIVE traffic as a field of glowing, altitude-elevated dots
 * (plus a faint vertical stem down to the ground) on the main mapbox-gl
 * map — the same visual language as the ATC replay's 3D view
 * (atcReplay.js), but fed from the live `currentMapFeatures` instead of
 * a recorded session clock.
 *
 * Design notes:
 *  - A single THREE custom layer in the map's own WebGL context, exactly
 *    like flownPath3D.js / atcReplay.js. One batched draw call for all
 *    dots and one for all stems, so cost stays flat regardless of count.
 *  - "Teleport" model: dots jump to each new position on refresh(); there
 *    is no interpolation between the ~15s updates (deliberately, for now).
 *  - When active, the flat 2D plane symbols/labels are hidden so contacts
 *    don't double up.
 *
 * Public API (see export at bottom):
 *   init(map, featuresProvider)  featuresProvider() -> array of GeoJSON
 *                                features (Object.values(currentMapFeatures))
 *   setVisible(on)               toggle the 3D field; returns new state
 *   isVisible()                  -> boolean
 *   refresh()                    re-fill buffers from the provider (call
 *                                after each live data update)
 */

export const LiveTraffic3D = (() => {
    const LYR_3D = 'live-traffic-3d';
    // Live traffic can be large; cap the buffer so a packed server can't
    // balloon GPU memory. Beyond this we simply stop adding dots.
    const MAX_3D_DOTS = 4000;
    const ALT_EXAGGERATION = 2.5;   // vertical scale for dot/stem heights
    const DOT_SIZE_PX = 28;         // on-screen sprite size (no attenuation);
                                    // a touch larger than the old dot so the
                                    // plane silhouette stays legible

    // Flat 2D layers to hide while the 3D field is active so contacts don't
    // render twice. Missing layers are skipped silently.
    const FLAT_LAYERS = [
        'sector-ops-live-flights-layer',
        'sector-ops-live-flights-hover-layer',
        'sector-ops-live-flights-labels'
    ];

    let map = null;
    let three = null;
    let visible = false;
    let featuresProvider = null;

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

    // Sprite for each contact: a soft glow halo with a crisp top-down plane
    // silhouette punched into the middle, so the field reads as little
    // aircraft rather than featureless dots. Drawn in white on transparent —
    // the per-vertex altitude colour tints it, and additive blending keeps the
    // luminous "contact" feel of the original dots. The glyph always points
    // "up" (it's billboarded toward the camera); per-heading rotation isn't
    // possible with a single batched THREE.Points draw, so this is a generic,
    // orientation-free plane marker.
    function makePlaneSprite() {
        const THREE = window.THREE;
        const size = 64;
        const c = document.createElement('canvas');
        c.width = c.height = size;
        const ctx = c.getContext('2d');

        // 1. Soft glow halo (dimmer than the old pure-dot so the plane reads).
        const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
        g.addColorStop(0, 'rgba(255,255,255,0.42)');
        g.addColorStop(0.45, 'rgba(255,255,255,0.12)');
        g.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, size, size);

        // 2. Crisp top-down airliner silhouette, built from a symmetric
        //    right-hand outline mirrored about the vertical centreline.
        const right = [
            [32, 5], [35, 24], [61, 38], [61, 42], [35, 33],
            [35, 50], [46, 58], [46, 60], [33, 55], [32, 60]
        ];
        ctx.beginPath();
        ctx.moveTo(right[0][0], right[0][1]);
        for (let i = 1; i < right.length; i++) ctx.lineTo(right[i][0], right[i][1]);
        for (let i = right.length - 1; i >= 0; i--) ctx.lineTo(size - right[i][0], right[i][1]);
        ctx.closePath();
        ctx.fillStyle = 'rgba(255,255,255,1)';
        ctx.fill();

        const tex = new THREE.CanvasTexture(c);
        tex.needsUpdate = true;
        return tex;
    }

    // Build the custom layer once (lazily, on first enable). Two preallocated
    // buffers: dots (THREE.Points, additive glow) and stems (LineSegments).
    function ensureLayer() {
        if (!map || three || !window.THREE || !window.mapboxgl) return;
        if (map.getLayer(LYR_3D)) return;
        const THREE = window.THREE;
        const self = { visible: false };
        const glowTex = makePlaneSprite();

        const layer = {
            id: LYR_3D, type: 'custom', renderingMode: '3d',
            onAdd(m, gl) {
                self.camera = new THREE.Camera();
                self.scene = new THREE.Scene();

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

                self.stemGeo = new THREE.BufferGeometry();
                self.stemGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.stemGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(MAX_3D_DOTS * 2 * 3), 3));
                self.stemMat = new THREE.LineBasicMaterial({
                    vertexColors: true, transparent: true, opacity: 0.32,
                    depthWrite: false, blending: THREE.AdditiveBlending
                });
                self.stems = new THREE.LineSegments(self.stemGeo, self.stemMat);
                self.stems.frustumCulled = false;
                self.scene.add(self.stems);

                self.renderer = new THREE.WebGLRenderer({ canvas: m.getCanvas(), context: gl, antialias: true });
                self.renderer.autoClear = false;
                self.glowTex = glowTex;
            },
            render(gl, matrix) {
                if (!self.renderer || !self.visible) return;
                self.camera.projectionMatrix = new THREE.Matrix4().fromArray(matrix);
                self.renderer.resetState();
                self.renderer.render(self.scene, self.camera);
            }
        };
        try { map.addLayer(layer); three = self; } catch (e) { console.warn('[LiveTraffic3D] 3D layer add failed:', e); }
    }

    // Re-fill the dot + stem buffers from the current live features. No-op
    // unless the 3D field is showing, so the flat map costs nothing.
    function refresh() {
        if (!three || !three.visible || !map || !featuresProvider) return;
        if (!window.mapboxgl) return;
        const Merc = window.mapboxgl.MercatorCoordinate;
        const feats = featuresProvider() || [];
        const dotPos = three.dotGeo.attributes.position, dotCol = three.dotGeo.attributes.color;
        const stemPos = three.stemGeo.attributes.position, stemCol = three.stemGeo.attributes.color;
        let n = 0;
        for (const f of feats) {
            if (n >= MAX_3D_DOTS) break;
            if (!f || !f.geometry || !f.geometry.coordinates) continue;
            const [lon, lat] = f.geometry.coordinates;
            if (!isFinite(lon) || !isFinite(lat)) continue;
            const alt = (f.properties && f.properties.altitude) || 0;
            const m = Merc.fromLngLat([lon, lat], alt * 0.3048 * ALT_EXAGGERATION);
            const c = altColor01(alt);
            dotPos.setXYZ(n, m.x, m.y, m.z);
            dotCol.setXYZ(n, c[0], c[1], c[2]);
            // stem runs from the ground point straight up to the dot
            stemPos.setXYZ(n * 2, m.x, m.y, 0);
            stemPos.setXYZ(n * 2 + 1, m.x, m.y, m.z);
            stemCol.setXYZ(n * 2, c[0], c[1], c[2]);
            stemCol.setXYZ(n * 2 + 1, c[0], c[1], c[2]);
            n++;
        }
        three.dotGeo.setDrawRange(0, n);
        three.stemGeo.setDrawRange(0, n * 2);
        dotPos.needsUpdate = dotCol.needsUpdate = true;
        stemPos.needsUpdate = stemCol.needsUpdate = true;
        map.triggerRepaint();
    }

    function init(mapInstance, provider) {
        map = mapInstance;
        featuresProvider = provider;
    }

    // Swap between the flat 2D icons and the 3D dot field.
    function setVisible(on) {
        on = !!on;
        if (on) ensureLayer();
        visible = on;
        if (three) three.visible = on;
        const flatVis = on ? 'none' : 'visible';
        FLAT_LAYERS.forEach(id => {
            if (map && map.getLayer(id)) {
                try { map.setLayoutProperty(id, 'visibility', flatVis); } catch (_) {}
            }
        });
        if (on) refresh();
        if (map) map.triggerRepaint();
        return visible;
    }

    function isVisible() { return visible; }

    return { init, setVisible, isVisible, refresh };
})();
