/**
 * ===================================================================
 * MapAnimator.js
 * -------------------------------------------------------------------
 * A module to handle updating flight positions on a Mapbox GL JS map.
 *
 * --- [Teleport Model + Optional Smooth Cruise Motion] ---
 *
 * By default this module uses a *teleport* model: when new flight
 * data arrives, the GeoJSON feature is immediately moved to the new
 * coordinates with no interpolation.
 *
 * When "Smooth Cruise Motion" is enabled (setAnimationEnabled(true)),
 * flights in steady forward flight (Cruise / level Enroute) glide
 * continuously and NEVER stop: every animation frame the plane is
 * integrated forward along its heading at its ground speed. When a
 * fresh fix arrives it is not snapped — instead it converges onto the
 * true track via a correction that is clamped so it can never cancel
 * the forward motion (it can slow to converge, but never halts or
 * reverses). With no fresh data the plane keeps gliding forward; the
 * caller's cleanup pass removes flights that drop off the network.
 * All other phases (Ground, Climb, Descent) keep the simple teleport
 * behaviour.
 * ===================================================================
 */

// Knots -> metres per second.
const KNOTS_TO_MPS = 0.514444;

// Cap how often we rebuild the GeoJSON source while animating. ~25fps
// keeps cruise motion visually smooth without rebuilding the feature
// collection on every single rAF tick (which is costly with hundreds
// of flights on screen).
const REDRAW_INTERVAL_MS = 40;

// Don't bother dead-reckoning planes that are barely moving.
const MIN_ANIMATE_SPEED_KT = 40;

// The plane is integrated forward every frame at its ground speed and never
// pauses. When a fresh fix lands we converge onto the true track with an
// exponential correction (this time constant), instead of snapping. A higher
// value corrects more gently.
const CORRECTION_TAU_S = 1.5;

// Hard guarantee that the plane NEVER stops: the per-frame correction is
// clamped to at most this fraction of the forward step, so the net motion is
// always at least (1 - ratio) of the real ground speed in the heading
// direction — it can slow to converge, but it never halts or reverses.
const MAX_CORRECTION_RATIO = 0.8;

// Clamp per-frame delta time so returning from a backgrounded tab (where rAF
// was paused) doesn't teleport the plane forward by the whole gap.
const MAX_FRAME_DT_S = 1.0;

// A gap larger than this between the drawn position and a new fix is a real
// discontinuity (missed data, server teleport), so snap instead of taking
// many seconds to slide across it.
const MAX_SNAP_METERS = 20000;

/**
 * Main manager for the Mapbox map.
 */
export class MapAnimator {
    /**
     * @param {mapboxgl.Map} map - The Mapbox map instance.
     * @param {string} sourceName - The name of the GeoJSON source to update.
     * @param {Object} featuresObject - A *reference* to the master features object (currentMapFeatures) in flight.js.
     */
    constructor(map, sourceName, featuresObject) {
        this.map = map;
        this.sourceName = sourceName;
        this.currentMapFeatures = featuresObject; // This is a SHARED REFERENCE

        // --- Smooth cruise motion state ---
        this.animationEnabled = false;
        // Per-flight motion state, keyed by flightId.
        // {
        //   anchorLon, anchorLat, anchorTime,  // last true reported fix + time
        //   headingDeg, speedMps,              // current velocity
        //   renderLon, renderLat,              // continuously-integrated drawn position
        //   lastFrame                          // timestamp of last integration step
        // }
        this.animationStates = {};
        this._rafId = null;
        this._lastDraw = 0;

        // Optional per-frame hook (set by the host) invoked with the current
        // animation states after each redraw — used to grow live trail
        // connectors so flown paths build up between packets.
        this.onFrame = null;
    }

    /**
     * Starts the animator. (No-op in teleport mode; the cruise-motion
     * loop is driven on-demand whenever there are flights to animate.)
     */
    start() {
        console.log('MapAnimator started.');
        this._ensureLoop();
    }

    /**
     * Stops the animator and any in-flight cruise animation loop.
     */
    stop() {
        console.log('MapAnimator stopped.');
        this._stopLoop();
    }

    /**
     * Enables or disables smooth cruise motion (dead reckoning).
     * @param {boolean} enabled
     */
    setAnimationEnabled(enabled) {
        const next = !!enabled;
        if (next === this.animationEnabled) return;
        this.animationEnabled = next;

        if (!this.animationEnabled) {
            // Drop all anchors and stop animating; the next data update
            // will teleport everything back to its true position.
            this.animationStates = {};
            this._stopLoop();
            // Clear any live trail connectors left on the map.
            if (typeof this.onFrame === 'function') this.onFrame({});
        } else {
            // Start moving every cruising plane RIGHT AWAY — seed motion from
            // the data already on the map so nothing waits for its next packet.
            this._seedFromCurrentFeatures();
            this._ensureLoop();
        }
        console.log(`MapAnimator: smooth cruise motion ${this.animationEnabled ? 'ON' : 'OFF'}.`);
    }

    /**
     * Seeds motion state for every cruising flight currently on the map so
     * they begin gliding immediately (e.g. the instant the toggle is enabled),
     * without waiting for a fresh socket packet to arrive. Reads heading and
     * ground speed straight from the feature properties.
     */
    _seedFromCurrentFeatures() {
        const now = performance.now();
        for (const flightId in this.currentMapFeatures) {
            const feature = this.currentMapFeatures[flightId];
            if (!feature || !feature.geometry || !feature.properties) continue;
            if (this.animationStates[flightId]) continue; // already moving

            const props = feature.properties;
            const speedKt = Number(props.speed) || 0;
            if (!this._isCruising(props) || speedKt < MIN_ANIMATE_SPEED_KT) continue;

            const coords = feature.geometry.coordinates;
            if (!coords || !isFinite(coords[0]) || !isFinite(coords[1])) continue;

            this.animationStates[flightId] = {
                anchorLon: coords[0],
                anchorLat: coords[1],
                anchorTime: now,
                headingDeg: Number(props.heading) || 0,
                speedMps: speedKt * KNOTS_TO_MPS,
                renderLon: coords[0],
                renderLat: coords[1],
                lastFrame: now
            };
        }
    }

    /**
     * Updates or creates a flight's state based on new data.
     * Teleports the feature to its true reported position and, when
     * smooth motion is enabled, (re-)anchors steady cruise flights so
     * they can glide forward until the next update.
     * @param {object} newPosition - {lon, lat, heading_deg, gs_kt, ...}
     * @param {object} newProperties - The full properties object.
     */
    updateFlight(newPosition, newProperties) {
        const flightId = newProperties.flightId;
        const trueLon = newPosition.lon;
        const trueLat = newPosition.lat;

        const speedKt = Number(newPosition.gs_kt) || 0;
        const eligible = this.animationEnabled
            && this._isCruising(newProperties)
            && speedKt >= MIN_ANIMATE_SPEED_KT;

        // Position we'll actually draw this instant. For an eligible flight
        // that's already on screen we keep it where it is and let the frame
        // loop ease it onto the new track, so it never jumps back.
        let renderLon = trueLon;
        let renderLat = trueLat;

        if (eligible) {
            const now = performance.now();
            const prev = this.animationStates[flightId];

            // Keep the plane wherever it's currently drawn so it never jumps;
            // the frame loop converges it onto the new true track. Only a huge
            // discontinuity (missed data / teleport) snaps to the reported spot.
            if (prev && Number.isFinite(prev.renderLon)) {
                const drift = this._approxDistanceMeters(
                    prev.renderLat, prev.renderLon, trueLat, trueLon
                );
                if (drift <= MAX_SNAP_METERS) {
                    renderLon = prev.renderLon;
                    renderLat = prev.renderLat;
                }
            }

            this.animationStates[flightId] = {
                // Authoritative (true) anchor + velocity from this fix.
                anchorLon: trueLon,
                anchorLat: trueLat,
                anchorTime: now,
                headingDeg: Number(newPosition.heading_deg) || 0,
                speedMps: speedKt * KNOTS_TO_MPS,
                // Continuously-integrated drawn position.
                renderLon: renderLon,
                renderLat: renderLat,
                // Carry the integration clock so motion stays continuous.
                lastFrame: (prev && Number.isFinite(prev.lastFrame)) ? prev.lastFrame : now
            };
            this._ensureLoop();
        } else if (this.animationStates[flightId]) {
            // No longer eligible (e.g. started descending) — stop gliding it.
            delete this.animationStates[flightId];
        }

        // Write into the shared cache. Preserve any feature id assigned
        // upstream so Mapbox keeps a stable identity for the feature.
        const prevFeature = this.currentMapFeatures[flightId];
        const feature = {
            type: 'Feature',
            geometry: {
                type: 'Point',
                coordinates: [renderLon, renderLat]
            },
            properties: newProperties // Includes new heading, phase, etc.
        };
        if (prevFeature && prevFeature.id !== undefined) {
            feature.id = prevFeature.id;
        }
        this.currentMapFeatures[flightId] = feature;

        // Trigger an immediate update of the map source.
        this._updateMapSource();
    }

    /**
     * Removes a flight from the map.
     * @param {string} flightId
     */
    removeFlight(flightId) {
        delete this.currentMapFeatures[flightId];
        delete this.animationStates[flightId];

        // Trigger an immediate update to remove it from the map.
        this._updateMapSource();
    }

    /**
     * A flight is treated as "constant forward motion" when it is in
     * Cruise or steady level Enroute flight. Climb/Descent/Ground are
     * excluded because their tracks turn and change speed enough that
     * prediction would visibly snap on each correction.
     */
    _isCruising(properties) {
        const phase = properties && properties.phase;
        return phase === 'Cruise' || phase === 'Enroute';
    }

    /**
     * Fast approximate (equirectangular) distance in metres between two
     * lat/lon points. Plenty accurate for the sub-km correction checks here.
     */
    _approxDistanceMeters(lat1, lon1, lat2, lon2) {
        const R = 6371000;
        const meanLat = (lat1 + lat2) * 0.5 * Math.PI / 180;
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180 * Math.cos(meanLat);
        return Math.sqrt(dLat * dLat + dLon * dLon) * R;
    }

    /**
     * Projects a lat/lon forward along a bearing by a given distance.
     * Standard destination-point (great-circle) formula.
     * @returns {[number, number]} [lon, lat]
     */
    _destinationPoint(latDeg, lonDeg, bearingDeg, distMeters) {
        const R = 6371000; // Earth radius in metres.
        const ang = distMeters / R;
        const theta = bearingDeg * Math.PI / 180;
        const phi1 = latDeg * Math.PI / 180;
        const lambda1 = lonDeg * Math.PI / 180;

        const sinPhi1 = Math.sin(phi1), cosPhi1 = Math.cos(phi1);
        const sinAng = Math.sin(ang), cosAng = Math.cos(ang);

        const sinPhi2 = sinPhi1 * cosAng + cosPhi1 * sinAng * Math.cos(theta);
        const phi2 = Math.asin(sinPhi2);
        const y = Math.sin(theta) * sinAng * cosPhi1;
        const x = cosAng - sinPhi1 * sinPhi2;
        const lambda2 = lambda1 + Math.atan2(y, x);

        const lon = ((lambda2 * 180 / Math.PI) + 540) % 360 - 180; // normalise to -180..180
        const lat = phi2 * 180 / Math.PI;
        return [lon, lat];
    }

    /**
     * Starts the rAF loop if smooth motion is on and there is something to animate.
     */
    _ensureLoop() {
        if (!this.animationEnabled) return;
        if (this._rafId !== null) return;
        if (Object.keys(this.animationStates).length === 0) return;
        this._lastDraw = 0;
        this._rafId = requestAnimationFrame((t) => this._frame(t));
    }

    _stopLoop() {
        if (this._rafId !== null) {
            cancelAnimationFrame(this._rafId);
            this._rafId = null;
        }
    }

    /**
     * Animation tick. Every flight is integrated forward at its ground speed
     * so it never stops, then nudged toward the true track by a clamped
     * correction that can never cancel the forward motion. Throttled to
     * REDRAW_INTERVAL_MS.
     */
    _frame(now) {
        this._rafId = null;

        if (!this.animationEnabled) return;

        const ids = Object.keys(this.animationStates);
        if (ids.length === 0) return; // Nothing to animate; loop will restart on next eligible update.

        if (now - this._lastDraw >= REDRAW_INTERVAL_MS) {
            this._lastDraw = now;
            for (const flightId of ids) {
                const feature = this.currentMapFeatures[flightId];
                if (!feature) {
                    delete this.animationStates[flightId];
                    continue;
                }
                const state = this.animationStates[flightId];

                // Wall-clock seconds since the last drawn frame. Clamped so a
                // backgrounded tab doesn't fling the plane forward on resume.
                let dt = (now - state.lastFrame) / 1000;
                state.lastFrame = now;
                if (dt <= 0) continue;
                if (dt > MAX_FRAME_DT_S) dt = MAX_FRAME_DT_S;

                const fwdMeters = state.speedMps * dt;

                // 1) Always advance forward along the heading — the plane never
                //    pauses, even with no fresh data (the cleanup pass removes
                //    flights that genuinely drop off the network).
                let [lon, lat] = this._destinationPoint(
                    state.renderLat, state.renderLon, state.headingDeg, fwdMeters
                );

                // 2) Converge onto the true track. The target is the reported
                //    fix carried forward at ground speed, so it advances at the
                //    same rate the drawn plane does; the exponential term just
                //    closes the residual prediction error.
                const tElapsed = (now - state.anchorTime) / 1000;
                const target = this._destinationPoint(
                    state.anchorLat, state.anchorLon, state.headingDeg, state.speedMps * tElapsed
                );
                const k = 1 - Math.exp(-dt / CORRECTION_TAU_S);
                let cLon = (target[0] - lon) * k;
                let cLat = (target[1] - lat) * k;

                // Clamp the correction so it can never exceed a fraction of the
                // forward step — guaranteeing net motion stays forward (the
                // plane can slow to converge but never stops or reverses).
                const corrMeters = this._approxDistanceMeters(lat, lon, lat + cLat, lon + cLon);
                const maxCorr = fwdMeters * MAX_CORRECTION_RATIO;
                if (corrMeters > maxCorr && corrMeters > 0) {
                    const scale = maxCorr / corrMeters;
                    cLon *= scale;
                    cLat *= scale;
                }
                lon += cLon;
                lat += cLat;

                state.renderLon = lon;
                state.renderLat = lat;
                feature.geometry.coordinates = [lon, lat];
            }
            this._updateMapSource();

            // Let the host extend live trail connectors to the new positions.
            if (typeof this.onFrame === 'function') this.onFrame(this.animationStates);
        }

        // Keep looping.
        this._rafId = requestAnimationFrame((t) => this._frame(t));
    }

    /**
     * Pushes the current state of *all* features to the map source.
     */
    _updateMapSource() {
        const source = this.map.getSource(this.sourceName);
        if (!source || !this.map.isStyleLoaded()) {
            // If source/style isn't ready, it's fine.
            // The next update will catch it.
            return;
        }

        // This single call pushes all changes to the map at once.
        source.setData({
            type: 'FeatureCollection',
            features: Object.values(this.currentMapFeatures)
        });
    }
}
