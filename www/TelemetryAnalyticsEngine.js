/**
 * TelemetryAnalyticsEngine
 * Premium utility to calculate real-time flight statistics, fuel estimations, 
 * and routing progress by merging live spatial telemetry, filed dispatch plans,
 * and internal ACARS DB historical crumbs for exact numerical integration.
 */

export class TelemetryAnalyticsEngine {
    static ACARS_BACKEND_URL = 'https://site--acars-backend--6dmjph8ltlhv.code.run';

    /**
     * Asynchronously fetches internal history crumbs and analyzes the flight.
     * @param {Object} liveFlight - The live telemetry object (position, speed, etc.)
     * @param {Object} dispatchPlan - The associated flight plan from Supabase
     * @returns {Promise<Object>} Comprehensive telemetry statistics
     */
    static async analyze(liveFlight, dispatchPlan) {
        // 1. Base Spatial Stats
        const alt = liveFlight?.position?.alt_ft || 0;
        const gs = liveFlight?.position?.gs_kt || 0;
        const vs = liveFlight?.position?.vs_fpm || 0;
        const flightId = liveFlight?.flightId;

        const phaseOfFlight = this._determinePhaseOfFlight(alt, gs, vs);

        if (!dispatchPlan || !dispatchPlan.dep_time || !dispatchPlan.fuel_used || !dispatchPlan.duration_minutes) {
            return {
                isTrackable: false,
                phaseOfFlight,
                message: 'No active dispatch plan found to calculate fuel or progress.'
            };
        }

        // 2. Dispatch Variables
        const blockFuelLbs = dispatchPlan.fuel_used;
        const durationMins = dispatchPlan.duration_minutes;
        const currentTimeMs = Date.now();

        // 3. Fetch DB Crumbs (Moved before time calculations to find ground-truth spawn time)
        let flightHistory = [];
        if (flightId) {
            flightHistory = await this._fetchHistoryCrumbs(flightId);
        }

        // 4. Precision Time Calculations (Premium Telemetry Override)
        let trueStartMs = new Date(dispatchPlan.dep_time).getTime();
        
        // If we have actual telemetry history, the earliest crumb is the true block-off time.
        // This prevents inaccurate progress if the dispatch was filed mid-flight or delayed.
        if (flightHistory && flightHistory.length > 0) {
            let earliestMs = Infinity;
            for (const crumb of flightHistory) {
                if (crumb.position?.lastReportMs && crumb.position.lastReportMs < earliestMs) {
                    earliestMs = crumb.position.lastReportMs;
                }
            }
            if (earliestMs !== Infinity && earliestMs < currentTimeMs) {
                // Overwrite manual scheduled dispatch time with ground-truth telemetry
                trueStartMs = earliestMs;
            }
        }

        const elapsedMins = Math.max(0, (currentTimeMs - trueStartMs) / 60000);
        let remainingMins = durationMins - elapsedMins;
        if (remainingMins < 0) remainingMins = 0; 

        let progressPercent = (elapsedMins / durationMins) * 100;
        if (progressPercent > 100) progressPercent = 100;

        // 5. Exact Historical Processing
        let fuelBurned = 0;
        let estimatedDistanceTraveledNm = 0;

        if (flightHistory.length > 1) {
            // History available: Perform strict numerical integration over the crumbs
            const integration = this._integrateCrumbHistory(flightHistory, blockFuelLbs, durationMins);
            fuelBurned = integration.fuelBurned;
            estimatedDistanceTraveledNm = integration.distanceTraveledNm;
        } else {
            // Backend unreachable or no crumbs yet: Seamless fallback to non-linear approximations
            fuelBurned = this._calculateNonLinearFuelBurn(blockFuelLbs, durationMins, elapsedMins);
            estimatedDistanceTraveledNm = this._calculateDynamicDistance(elapsedMins, gs, phaseOfFlight, durationMins);
        }

        let estimatedFuelRemaining = blockFuelLbs - fuelBurned;
        if (estimatedFuelRemaining < 0) estimatedFuelRemaining = 0;

        const fuelPercent = (estimatedFuelRemaining / blockFuelLbs) * 100;
        const currentBurnRatePerMin = this._getCurrentPhaseBurnRate(blockFuelLbs, durationMins, phaseOfFlight);

        // 6. Dynamic ETA Adjustment 
        const totalEstimatedDistance = this._calculateDynamicDistance(durationMins, gs, 'Cruising', durationMins);
        const distanceRemaining = Math.max(0, totalEstimatedDistance - estimatedDistanceTraveledNm);
        
        let dynamicRemainingMins = remainingMins;
        if (gs > 100 && distanceRemaining > 0) {
            const timeToCoverRemaining = (distanceRemaining / gs) * 60;
            dynamicRemainingMins = (remainingMins * 0.3) + (timeToCoverRemaining * 0.7);
        }

        const estArrivalMs = currentTimeMs + (dynamicRemainingMins * 60000);

        return {
            isTrackable: true,
            phaseOfFlight,
            
            time: {
                elapsedMinutes: Math.round(elapsedMins),
                remainingMinutes: Math.round(dynamicRemainingMins),
                progressPercent: parseFloat(progressPercent.toFixed(1)),
                etaISO: new Date(estArrivalMs).toISOString()
            },
            
            fuel: {
                blockFuelLbs: blockFuelLbs,
                estimatedRemainingLbs: Math.round(estimatedFuelRemaining),
                estimatedBurnedLbs: Math.round(fuelBurned),
                currentBurnRatePerHour: Math.round(currentBurnRatePerMin * 60),
                remainingPercent: parseFloat(fuelPercent.toFixed(1))
            },
            
            distance: {
                estimatedTraveledNm: Math.round(estimatedDistanceTraveledNm)
            }
        };
    }

    /**
     * Safely fetches the historical breadcrumbs from the ACARS backend.
     * Includes a strict 4-second timeout to prevent UI hanging if the server lags.
     */
    static async _fetchHistoryCrumbs(flightId) {
        const url = `${this.ACARS_BACKEND_URL}/api/flights/${encodeURIComponent(flightId)}/history`;
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 4000);
            
            const response = await fetch(url, { signal: controller.signal });
            clearTimeout(timeoutId);
            
            if (!response.ok) return [];
            
            const json = await response.json();
            return Array.isArray(json.path) ? json.path : [];
        } catch (error) {
            console.warn(`[TelemetryEngine] Failed to fetch history for ${flightId}, defaulting to approximation models.`, error.message);
            return [];
        }
    }

    /**
     * Walks through the custom DB crumb array to calculate exact point-to-point 
     * distance and exact time-in-phase for perfect fuel burn allocation.
     */
    static _integrateCrumbHistory(history, blockFuel, durationMins) {
        let totalDistanceNm = 0;
        let timeInClimb = 0;
        let timeInCruise = 0;
        let timeInDescent = 0;
        let timeOnGround = 0;

        // Ensure chronological order using your custom lastReportMs schema
        const sortedHistory = [...history].sort((a, b) => {
            const tA = a.position?.lastReportMs || 0;
            const tB = b.position?.lastReportMs || 0;
            return tA - tB;
        });

        for (let i = 1; i < sortedHistory.length; i++) {
            const pos1 = sortedHistory[i - 1].position;
            const pos2 = sortedHistory[i].position;

            if (!pos1 || !pos2) continue;

            // 1. Accumulate Exact Distance (Haversine)
            if (typeof pos1.lat === 'number' && typeof pos1.lon === 'number' &&
                typeof pos2.lat === 'number' && typeof pos2.lon === 'number') {
                totalDistanceNm += this._haversineDistanceNm(pos1.lat, pos1.lon, pos2.lat, pos2.lon);
            }

            // 2. Accumulate Exact Phase Times
            const t1 = pos1.lastReportMs;
            const t2 = pos2.lastReportMs;
            
            if (!t1 || !t2) continue;
            
            const deltaMins = (t2 - t1) / 60000;
            if (deltaMins <= 0 || deltaMins > 15) continue; // Skip massive gaps to prevent statistical corruption

            const alt2 = pos2.alt_ft || 0;
            const vs2 = pos2.vs_fpm || 0;
            const gs2 = pos2.gs_kt || 0;

            if (alt2 < 100 && gs2 <= 45) {
                timeOnGround += deltaMins;
            } else if (alt2 >= 200 && vs2 > 300) {
                timeInClimb += deltaMins;
            } else if (alt2 >= 200 && vs2 < -300) {
                timeInDescent += deltaMins;
            } else {
                timeInCruise += deltaMins;
            }
        }

        // 3. Apply phase times to dynamic burn rates
        const nominalRate = blockFuel / durationMins;
        const climbRate = nominalRate * 1.6;
        const descentRate = nominalRate * 0.35;
        const groundRate = nominalRate * 0.15;
        
        // Ensure total block fuel is respected across anticipated operational windows
        const expectedClimbDuration = Math.min(20, durationMins * 0.25);
        const expectedDescentDuration = Math.min(18, durationMins * 0.22);
        const expectedCruiseDuration = Math.max(0, durationMins - expectedClimbDuration - expectedDescentDuration);
        
        const expectedFixedBurn = (climbRate * expectedClimbDuration) + (descentRate * expectedDescentDuration);
        const cruiseRate = expectedCruiseDuration > 0 ? (blockFuel - expectedFixedBurn) / expectedCruiseDuration : nominalRate;

        // Calculate final integrated burn
        const fuelBurned = (timeOnGround * groundRate) + 
                           (timeInClimb * climbRate) + 
                           (timeInCruise * cruiseRate) + 
                           (timeInDescent * descentRate);

        return {
            distanceTraveledNm: totalDistanceNm,
            fuelBurned: fuelBurned
        };
    }

    /**
     * Calculates the Great Circle distance between two coordinates in Nautical Miles.
     */
    static _haversineDistanceNm(lat1, lon1, lat2, lon2) {
        const toRad = (value) => (value * Math.PI) / 180;
        const R = 3440.065; // Earth radius in Nautical Miles

        const dLat = toRad(lat2 - lat1);
        const dLon = toRad(lon2 - lon1);
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                  Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
                  Math.sin(dLon / 2) * Math.sin(dLon / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    }

    static _determinePhaseOfFlight(alt, gs, vs) {
        if (alt < 100 && gs <= 45) return 'Taxiing';
        if (alt < 200 && gs > 45 && vs >= 0) return 'Takeoff / Landing Roll';
        if (alt >= 200 && vs > 300) return 'Climbing';
        if (alt >= 200 && vs < -300) return 'Descending';
        if (alt > 3000 && Math.abs(vs) <= 300 && gs > 100) return 'Cruising';
        return 'Ground / Unknown';
    }

    static _calculateNonLinearFuelBurn(blockFuel, durationMins, elapsedMins) {
        if (elapsedMins === 0) return 0;
        const climbDuration = Math.min(20, durationMins * 0.25);
        const descentDuration = Math.min(18, durationMins * 0.22);
        const cruiseDuration = Math.max(0, durationMins - climbDuration - descentDuration);

        const nominalRate = blockFuel / durationMins;
        const climbRate = nominalRate * 1.6;
        const descentRate = nominalRate * 0.35;
        const fixedBurn = (climbRate * climbDuration) + (descentRate * descentDuration);
        const cruiseRate = cruiseDuration > 0 ? (blockFuel - fixedBurn) / cruiseDuration : nominalRate;

        let burnedOut = 0;
        let t = elapsedMins;

        if (t > 0) {
            const timeInPhase = Math.min(t, climbDuration);
            burnedOut += timeInPhase * climbRate;
            t -= timeInPhase;
        }
        if (t > 0) {
            const timeInPhase = Math.min(t, cruiseDuration);
            burnedOut += timeInPhase * cruiseRate;
            t -= timeInPhase;
        }
        if (t > 0) {
            const timeInPhase = Math.min(t, descentDuration);
            burnedOut += timeInPhase * descentRate;
            t -= timeInPhase;
        }
        return burnedOut;
    }

    static _getCurrentPhaseBurnRate(blockFuel, durationMins, phase) {
        const nominalRate = blockFuel / durationMins;
        if (phase === 'Takeoff / Landing Roll' || phase === 'Climbing') return nominalRate * 1.6;
        if (phase === 'Descending') return nominalRate * 0.35;
        if (phase === 'Taxiing' || phase === 'Ground / Unknown') return nominalRate * 0.15;
        
        const climbDuration = Math.min(20, durationMins * 0.25);
        const descentDuration = Math.min(18, durationMins * 0.22);
        const cruiseDuration = Math.max(0, durationMins - climbDuration - descentDuration);
        const fixedBurn = (nominalRate * 1.6 * climbDuration) + (nominalRate * 0.35 * descentDuration);
        
        return cruiseDuration > 0 ? (blockFuel - fixedBurn) / cruiseDuration : nominalRate;
    }

    static _calculateDynamicDistance(elapsedMins, currentGs, phase, durationMins) {
        if (elapsedMins < 2) return currentGs * (elapsedMins / 60);

        let averageHistoricalGs = currentGs;
        const climbTime = Math.min(20, durationMins * 0.25);

        if (phase === 'Cruising' || phase === 'Descending') {
            if (elapsedMins > climbTime) {
                const cruiseTime = elapsedMins - climbTime;
                const climbGs = currentGs * 0.65; 
                averageHistoricalGs = ((climbGs * climbTime) + (currentGs * cruiseTime)) / elapsedMins;
            } else {
                averageHistoricalGs = currentGs * 0.75; 
            }
        } else if (phase === 'Climbing') {
            averageHistoricalGs = currentGs * 0.65;
        } else if (phase === 'Taxiing' || phase === 'Takeoff / Landing Roll') {
            averageHistoricalGs = currentGs * 0.5;
        }

        return averageHistoricalGs * (elapsedMins / 60);
    }
}