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
 * flights that are in steady forward flight (Cruise / level Enroute)
 * are "dead-reckoned" between the ~3s server updates: each animation
 * frame the plane is projected forward along its heading at its
 * ground speed, so it glides instead of jumping. Every server update
 * re-anchors the plane to its true reported position, correcting any
 * prediction drift. All other phases (Ground, Climb, Descent) keep
 * the simple teleport behaviour.
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

// Live fixes arrive roughly every ~3s. If a flight goes quiet we keep
// gliding it forward for a short grace window, then hold position so a
// stale plane never drifts unrealistically far from its last real fix.
const MAX_EXTRAPOLATION_SEC = 12;

// When a new fix lands, ease the plane from where it's currently drawn onto
// the freshly reported track over this window instead of snapping. This
// removes the visible "jump back" when our prediction overshot or a packet
// arrived late.
const CORRECTION_BLEND_MS = 1000;

// If the gap between the drawn position and the new fix is larger than this,
// treat it as a real discontinuity (missed data, server teleport) and snap
// rather than slow-sliding the plane across the map.
const MAX_CORRECTION_METERS = 10000;

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
        // Per-flight dead-reckoning anchors, keyed by flightId.
        // { lon, lat, headingDeg, speedMps, anchorTime }
        this.animationStates = {};
        this._rafId = null;
        this._lastDraw = 0;
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
        } else {
            this._ensureLoop();
        }
        console.log(`MapAnimator: smooth cruise motion ${this.animationEnabled ? 'ON' : 'OFF'}.`);
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

            let blendFrom = null;
            let blendStart = null;
            if (prev && Number.isFinite(prev.renderedLon)) {
                const drift = this._approxDistanceMeters(
                    prev.renderedLat, prev.renderedLon, trueLat, trueLon
                );
                // Smoothly correct small prediction errors; snap big jumps.
                if (drift <= MAX_CORRECTION_METERS) {
                    blendFrom = { lon: prev.renderedLon, lat: prev.renderedLat };
                    blendStart = now;
                    renderLon = prev.renderedLon;
                    renderLat = prev.renderedLat;
                }
            }

            this.animationStates[flightId] = {
                // Authoritative (true) anchor + velocity from this fix.
                anchorLon: trueLon,
                anchorLat: trueLat,
                headingDeg: Number(newPosition.heading_deg) || 0,
                speedMps: speedKt * KNOTS_TO_MPS,
                anchorTime: now,
                // Last position we drew (drives the next correction).
                renderedLon: renderLon,
                renderedLat: renderLat,
                // Active correction, if any.
                blendFrom: blendFrom,
                blendStart: blendStart
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
     * Animation tick: dead-reckon each anchored flight forward and push
     * the updated positions to the map (throttled to REDRAW_INTERVAL_MS).
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

                // Real wall-clock seconds since the last true fix. Clamped so a
                // flight that stops updating holds position instead of gliding
                // off forever; the next real fix re-anchors it.
                let dtSec = (now - state.anchorTime) / 1000;
                if (dtSec < 0) dtSec = 0;
                if (dtSec > MAX_EXTRAPOLATION_SEC) dtSec = MAX_EXTRAPOLATION_SEC;

                // Predicted position along the reported track. Distance = real
                // ground speed (m/s) x elapsed time, so the plane tracks at its
                // actual speed over the ground.
                const predicted = this._destinationPoint(
                    state.anchorLat, state.anchorLon, state.headingDeg, state.speedMps * dtSec
                );

                let renderLon = predicted[0];
                let renderLat = predicted[1];

                // If a correction is in progress, ease from the pre-correction
                // position onto the live track so a late/overshot packet glides
                // into place instead of snapping back.
                if (state.blendFrom && state.blendStart !== null) {
                    const p = (now - state.blendStart) / CORRECTION_BLEND_MS;
                    if (p >= 1) {
                        state.blendFrom = null;
                        state.blendStart = null;
                    } else {
                        const e = p * p * (3 - 2 * p); // smoothstep ease
                        renderLon = state.blendFrom.lon + (predicted[0] - state.blendFrom.lon) * e;
                        renderLat = state.blendFrom.lat + (predicted[1] - state.blendFrom.lat) * e;
                    }
                }

                state.renderedLon = renderLon;
                state.renderedLat = renderLat;
                feature.geometry.coordinates = [renderLon, renderLat];
            }
            this._updateMapSource();
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
