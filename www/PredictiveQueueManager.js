import { socketDataHub } from './SocketDataHub.js';

/**
 * PredictiveAirspaceNetwork — Premium Multi-Node Airspace Intelligence Module
 * Features 4D Trajectories, Wake Turbulence Matrix, Energy Profiling, 
 * Dynamic ATC Capacity Mapping, and Telemetry Integrity Analysis.
 */

export class PredictiveAirspaceNetwork {
    constructor() {
        this._roster = new Map();
        this._hubRegistry = new Map();
        this._atcRegistry = new Map(); 
        this._activeNodes = new Set();
        
        this._unsubscribeFlights = null;
        this._unsubscribeAtc = null;
        
        this._config = {
            staleTimeoutMs: 180000,       
            landedSpeedKts: 50,           
            landedAltFt: 500,             
            
            terminalRadiusNm: 40,         
            terminalAltFt: 18000,         
            
            levelFlightThresholdFpm: 200, 
            speedRestrictionAltFt: 10000, 
            speedRestrictionKts: 260,     
            glideSlopeDegrees: 3.0,       
            
            emaAlphaVelocity: 0.4,        
            emaAlphaAltitude: 0.6,
            
            // DOCILE EXPANSION FACTORS
            tmaExpansionFactor: 1.05,     
            enrouteExpansionFactor: 1.0, 

            bucketSizeMinutes: 15,        
            forecastHours: 4,             
            defaultCapacity15m: 12,

            uncontrolledCapacityPenalty: 0.70, 
            heavyWakeCapacityPenalty: 0.85     
        };

        this._preloadDefaultHubs();
        this._gcInterval = setInterval(() => this._sweepStaleTargets(), 60000); 
    }

    _preloadDefaultHubs() {
        const defaults = [
            { icao: 'KJFK', lat: 40.6413, lon: -73.7781, capacity: 11, elevationFt: 13 },
            { icao: 'EGLL', lat: 51.4700, lon: -0.4543,  capacity: 12, elevationFt: 83 },
            { icao: 'OMDB', lat: 25.2532, lon: 55.3657,  capacity: 10, elevationFt: 62 },
            { icao: 'KLAX', lat: 33.9416, lon: -118.4085,capacity: 14, elevationFt: 128 },
            { icao: 'EDDF', lat: 50.0333, lon: 8.5705,   capacity: 13, elevationFt: 364 }
        ];
        defaults.forEach(h => this.registerNode(h.icao, h.lat, h.lon, h.capacity, h.elevationFt));
    }

    bindTelemetryStream() {
        if (!this._unsubscribeFlights) {
            this._unsubscribeFlights = socketDataHub.subscribe('all_flights_update', (payload) => {
                if (!payload || !Array.isArray(payload.flights)) return;
                for (let i = 0; i < payload.flights.length; i++) {
                    this.processSocketTelemetry(payload.flights[i]);
                }
            });
        }

        if (!this._unsubscribeAtc) {
            this._unsubscribeAtc = socketDataHub.subscribe('secondary_data_update', (payload) => {
                if (!payload || !Array.isArray(payload.atc)) return;
                this._processAtcTelemetry(payload.atc);
            });
        }
    }

    registerNode(icaoCode, lat, lon, capacity_15m = this._config.defaultCapacity15m, elevationFt = 0) {
        const upperIcao = icaoCode.toUpperCase();
        this._hubRegistry.set(upperIcao, { lat, lon, capacity_15m, elevationFt });
        this._atcRegistry.set(upperIcao, { hasTower: false, hasApproach: false, controllers: [] });
    }

    setActiveNodes(icaoCodesArray) {
        this._activeNodes.clear();
        icaoCodesArray.forEach(icao => this._activeNodes.add(icao.toUpperCase()));
        this._reconcileRoster();
    }

    _inferWakeCategory(acftType) {
        if (!acftType) return 'MEDIUM';
        const type = acftType.toUpperCase();
        if (type.match(/A38.|A225/)) return 'SUPER';
        if (type.match(/B74.|B77.|B78.|A33.|A34.|A35.|MD11|DC10|IL96/)) return 'HEAVY';
        if (type.match(/B73.|A31.|A32.|BCS.|E19.|E17.|CRJ./)) return 'MEDIUM';
        return 'LIGHT';
    }

    _processAtcTelemetry(atcArray) {
        for (const [icao, data] of this._atcRegistry.entries()) {
            data.hasTower = false;
            data.hasApproach = false;
            data.controllers = [];
        }

        for (let i = 0; i < atcArray.length; i++) {
            const facility = atcArray[i];
            const airport = (facility.airportName || '').toUpperCase();
            
            if (this._activeNodes.has(airport) && this._atcRegistry.has(airport)) {
                const nodeAtc = this._atcRegistry.get(airport);
                nodeAtc.controllers.push({ type: facility.type, user: facility.username, start: facility.startTime });
                
                if (facility.type === 1) nodeAtc.hasTower = true;
                if (facility.type === 4 || facility.type === 5) nodeAtc.hasApproach = true;
            }
        }
    }

    processSocketTelemetry(flightData) {
        if (this._activeNodes.size === 0 || !flightData) return;

        const flightId = flightData.flightId || flightData.callsign;
        if (!flightId) return;

        // PREMIUM STATE MANAGEMENT
        // 0: Active, 1: Away, 2: Parked.
        // We preserve 'Away' states to capture long-haul enroute traffic.
        // We only evaporate strictly 'Parked' aircraft to prevent phantom ground targets.
        if (flightData.pilotState === 2) {
            if (this._roster.has(flightId)) this._roster.delete(flightId);
            return;
        }

        const depIcao = (flightData.departureIcao || '').toUpperCase();
        const arrIcao = (flightData.arrivalIcao || '').toUpperCase();
        
        const isMonitoredDeparture = this._activeNodes.has(depIcao);
        const isMonitoredArrival = this._activeNodes.has(arrIcao);

        if (!isMonitoredDeparture && !isMonitoredArrival) {
            if (this._roster.has(flightId)) this._roster.delete(flightId);
            return;
        }

        const pos = flightData.position || {};
        const currentLat = pos.lat;
        const currentLon = pos.lon;
        const rawAlt = pos.alt_ft || 0;
        const rawGs = pos.gs_kt || 0;
        const rawHeading = pos.heading_deg || 0;
        const rawVsFpm = pos.vs_fpm || 0;

        if (currentLat === undefined || currentLon === undefined) return;

        const now = Date.now();
        let distToArrival_nm = null;
        let distFromDeparture_nm = null;

        if (isMonitoredArrival && this._hubRegistry.has(arrIcao)) {
            const node = this._hubRegistry.get(arrIcao);
            distToArrival_nm = this._calculateHaversineNM(currentLat, currentLon, node.lat, node.lon);
        }

        if (isMonitoredDeparture && this._hubRegistry.has(depIcao)) {
            const node = this._hubRegistry.get(depIcao);
            distFromDeparture_nm = this._calculateHaversineNM(currentLat, currentLon, node.lat, node.lon);
        }

        let target;
        if (this._roster.has(flightId)) {
            target = this._roster.get(flightId);
            if (now <= target.lastSeen) return; 

            const timeDeltaSeconds = (now - target.lastSeen) / 1000;
            const timeDeltaMinutes = timeDeltaSeconds / 60;

            if (timeDeltaMinutes > 0) {
                const prevGs = target.currentGs;
                
                target.currentGs = (this._config.emaAlphaVelocity * rawGs) + ((1 - this._config.emaAlphaVelocity) * target.currentGs);
                target.currentAlt = (this._config.emaAlphaAltitude * rawAlt) + ((1 - this._config.emaAlphaAltitude) * target.currentAlt);

                const emaVerticalSpeed = (target.currentAlt - target.previousAlt) / timeDeltaMinutes;
                target.verticalSpeedFpm = (this._config.emaAlphaVelocity * emaVerticalSpeed) + ((1 - this._config.emaAlphaVelocity) * target.verticalSpeedFpm);

                target.accelerationKtsPerMin = (target.currentGs - prevGs) / timeDeltaMinutes;

                const newTrack = this._calculateBearing(target.currentLat, target.currentLon, currentLat, currentLon);
                target.derivedTrack = newTrack;

                let drift = Math.abs(target.derivedTrack - rawHeading);
                if (drift > 180) drift = 360 - drift;
                target.aerodynamicDriftDeg = drift;

                const vsAnomaly = Math.abs(target.verticalSpeedFpm - rawVsFpm);
                target.flags.telemetryDegraded = vsAnomaly > 1200; 
            }

            target.previousAlt = target.currentAlt;
            target.currentLat = currentLat;
            target.currentLon = currentLon;
            target.distToArrival_nm = distToArrival_nm;
            target.distFromDeparture_nm = distFromDeparture_nm;
            target.lastSeen = now;
        } else {
            const aircraftData = flightData.aircraft || {};
            const acftType = aircraftData.aircraftName || 'UNK';
            const livery = aircraftData.liveryName || 'Unknown Operator';
            
            target = {
                flightId: flightId,
                callsign: flightData.callsign || 'UNK',
                acftType: acftType,
                livery: livery,
                wakeCategory: this._inferWakeCategory(acftType),
                depIcao: depIcao,
                arrIcao: arrIcao,
                currentLat: currentLat,
                currentLon: currentLon,
                currentGs: rawGs,
                currentAlt: rawAlt,
                previousAlt: rawAlt,
                verticalSpeedFpm: rawVsFpm,
                accelerationKtsPerMin: 0,
                derivedTrack: rawHeading,
                aerodynamicDriftDeg: 0,
                distToArrival_nm: distToArrival_nm,
                distFromDeparture_nm: distFromDeparture_nm,
                lastSeen: now,
                eta_epoch: null,
                phase: 'ENROUTE',
                flags: {
                    isMonitoredDeparture: isMonitoredDeparture,
                    isMonitoredArrival: isMonitoredArrival,
                    isATCMetered: false,
                    highEnergyState: false,
                    telemetryDegraded: false
                }
            };
            this._roster.set(flightId, target);
        }

        this._updateTargetPhysics(target);
    }

    _updateTargetPhysics(target) {
        if (!target.flags.isMonitoredArrival || target.distToArrival_nm === null) return;

        const node = this._hubRegistry.get(target.arrIcao);
        const elevationFt = node ? (node.elevationFt || 0) : 0;

        if (target.distToArrival_nm <= this._config.terminalRadiusNm && target.currentAlt <= this._config.terminalAltFt) {
            target.phase = 'TERMINAL_AREA';
        } else {
            target.phase = 'ENROUTE';
        }

        target.flags.isATCMetered = (target.phase === 'TERMINAL_AREA' && Math.abs(target.verticalSpeedFpm) < this._config.levelFlightThresholdFpm);

        const requiredAltFt = elevationFt + (target.distToArrival_nm * 6076.115 * Math.tan(this._config.glideSlopeDegrees * (Math.PI / 180)));
        if (target.currentAlt > (requiredAltFt + 2000) && target.currentGs > 250) {
            target.flags.highEnergyState = true;
        } else if (target.currentAlt < this._config.speedRestrictionAltFt && target.currentGs > this._config.speedRestrictionKts) {
            target.flags.highEnergyState = true; 
        } else {
            target.flags.highEnergyState = false;
        }

        let effectiveSpeed = target.currentGs > 50 ? target.currentGs : 250;
        let actualTrackMiles = target.distToArrival_nm;
        
        if (target.phase === 'TERMINAL_AREA') {
            actualTrackMiles *= this._config.tmaExpansionFactor; 
        } else if (target.phase === 'ENROUTE') {
            actualTrackMiles *= this._config.enrouteExpansionFactor; 
        }

        let hoursEnroute = actualTrackMiles / effectiveSpeed;

        target.eta_epoch = Date.now() + (hoursEnroute * 60 * 60 * 1000);
    }

    generateNetworkAnalytics() {
        const report = {
            timestamp: new Date(),
            nodes: {}
        };

        const now = Date.now();
        const msPerBucket = this._config.bucketSizeMinutes * 60 * 1000;
        const numBuckets = (this._config.forecastHours * 60) / this._config.bucketSizeMinutes;

        const nodeAggregates = new Map();

        this._activeNodes.forEach(icao => {
            const nodeData = this._hubRegistry.get(icao) || { capacity_15m: this._config.defaultCapacity15m };
            const atcData = this._atcRegistry.get(icao) || { hasApproach: false, hasTower: false };
            
            nodeAggregates.set(icao, {
                arrAcft: new Map(), arrLiv: new Map(),
                depAcft: new Map(), depLiv: new Map()
            });

            report.nodes[icao] = {
                hubControlState: {
                    hasApproach: atcData.hasApproach,
                    hasTower: atcData.hasTower,
                    isFullyControlled: (atcData.hasApproach && atcData.hasTower)
                },
                metrics: {
                    totalInbound: 0,
                    totalOutbound: 0,
                    netFlowDelta: 0,
                    inTerminalArea: 0,   
                    meteredAircraftCount: 0, 
                    highEnergyArrivals: 0,
                    heavyAircraftInbound: 0,
                    baseCapacity: nodeData.capacity_15m,
                    effectiveCapacity: nodeData.capacity_15m
                },
                arrivalQueue: Array.from({ length: numBuckets }, (_, i) => ({
                    startTime: new Date(now + (i * msPerBucket)),
                    endTime: new Date(now + ((i+1) * msPerBucket)),
                    count: 0,
                    flights: [],
                    status: 'NORMAL'
                })),
                departureQueue: {
                    activeDepartures: [],
                    clearedSector: 0
                },
                topOperators: { arrivals: [], departures: [] },
                topAirframes: { arrivals: [], departures: [] }
            };
        });

        for (const [flightId, target] of this._roster.entries()) {
            
            if (target.flags.isMonitoredArrival && this._activeNodes.has(target.arrIcao)) {
                const nodeReport = report.nodes[target.arrIcao];
                const agg = nodeAggregates.get(target.arrIcao);

                nodeReport.metrics.totalInbound++;
                
                agg.arrAcft.set(target.acftType, (agg.arrAcft.get(target.acftType) || 0) + 1);
                agg.arrLiv.set(target.livery, (agg.arrLiv.get(target.livery) || 0) + 1);
                
                if (target.phase === 'TERMINAL_AREA') nodeReport.metrics.inTerminalArea++;
                if (target.flags.isATCMetered) nodeReport.metrics.meteredAircraftCount++;
                if (target.flags.highEnergyState) nodeReport.metrics.highEnergyArrivals++;
                if (target.wakeCategory === 'HEAVY' || target.wakeCategory === 'SUPER') nodeReport.metrics.heavyAircraftInbound++;

                if (target.eta_epoch) {
                    const msFromNow = target.eta_epoch - now;
                    if (msFromNow >= 0) {
                        const bucketIndex = Math.floor(msFromNow / msPerBucket);
                        if (bucketIndex < numBuckets) {
                            nodeReport.arrivalQueue[bucketIndex].count++;
                            nodeReport.arrivalQueue[bucketIndex].flights.push({
                                callsign: target.callsign,
                                acftType: target.acftType,
                                wakeCategory: target.wakeCategory,
                                phase: target.phase,
                                vSpeedFpm: Math.round(target.verticalSpeedFpm),
                                driftDeg: Math.round(target.aerodynamicDriftDeg),
                                degradedTelemetry: target.flags.telemetryDegraded,
                                eta: new Date(target.eta_epoch)
                            });
                        }
                    }
                }
            }

            if (target.flags.isMonitoredDeparture && this._activeNodes.has(target.depIcao)) {
                const nodeReport = report.nodes[target.depIcao];
                const agg = nodeAggregates.get(target.depIcao);

                nodeReport.metrics.totalOutbound++;
                
                agg.depAcft.set(target.acftType, (agg.depAcft.get(target.acftType) || 0) + 1);
                agg.depLiv.set(target.livery, (agg.depLiv.get(target.livery) || 0) + 1);

                nodeReport.departureQueue.activeDepartures.push({
                    callsign: target.callsign,
                    acftType: target.acftType,
                    distOutNm: target.distFromDeparture_nm ? target.distFromDeparture_nm.toFixed(1) : 0,
                    climbRate: Math.round(target.verticalSpeedFpm)
                });
            }
        }

        const extractTop5 = (mapObj) => Array.from(mapObj.entries())
                                             .sort((a, b) => b[1] - a[1])
                                             .slice(0, 5)
                                             .map(entry => ({ name: entry[0], count: entry[1] }));

        this._activeNodes.forEach(icao => {
            const nodeReport = report.nodes[icao];
            const agg = nodeAggregates.get(icao);
            
            nodeReport.metrics.netFlowDelta = nodeReport.metrics.totalInbound - nodeReport.metrics.totalOutbound;

            nodeReport.topOperators.arrivals = extractTop5(agg.arrLiv);
            nodeReport.topOperators.departures = extractTop5(agg.depLiv);
            nodeReport.topAirframes.arrivals = extractTop5(agg.arrAcft);
            nodeReport.topAirframes.departures = extractTop5(agg.depAcft);

            let adjustedCapacity = nodeReport.metrics.baseCapacity;
            
            if (!nodeReport.hubControlState.isFullyControlled) {
                adjustedCapacity *= this._config.uncontrolledCapacityPenalty;
            }
            
            const heavyRatio = nodeReport.metrics.totalInbound > 0 ? (nodeReport.metrics.heavyAircraftInbound / nodeReport.metrics.totalInbound) : 0;
            if (heavyRatio > 0.3) {
                adjustedCapacity *= this._config.heavyWakeCapacityPenalty; 
            }

            nodeReport.metrics.effectiveCapacity = Math.round(adjustedCapacity);

            nodeReport.arrivalQueue.forEach(bucket => {
                const saturationRatio = bucket.count / nodeReport.metrics.effectiveCapacity;
                if (saturationRatio >= 1.0) bucket.status = 'CRITICAL';
                else if (saturationRatio >= 0.8) bucket.status = 'SATURATED';
                else if (saturationRatio >= 0.6) bucket.status = 'HEAVY';
            });
        });

        return report;
    }

    _reconcileRoster() {
        let pruned = 0;
        for (const [flightId, target] of this._roster.entries()) {
            const isRelevantArrival = this._activeNodes.has(target.arrIcao);
            const isRelevantDeparture = this._activeNodes.has(target.depIcao);
            
            if (!isRelevantArrival && !isRelevantDeparture) {
                this._roster.delete(flightId);
                pruned++;
            } else {
                target.flags.isMonitoredArrival = isRelevantArrival;
                target.flags.isMonitoredDeparture = isRelevantDeparture;
            }
        }
    }

    _sweepStaleTargets() {
        const now = Date.now();
        for (const [flightId, target] of this._roster.entries()) {
            const timeSinceLastPing = now - target.lastSeen;
            const isStale = timeSinceLastPing > this._config.staleTimeoutMs;
            
            // Allow departures to remain tracked globally until they go stale or park
            // instead of prematurely evaporating them at the 50nm sector line.
            if (isStale) {
                this._roster.delete(flightId);
            }
        }
    }

    _calculateHaversineNM(lat1, lon1, lat2, lon2) {
        const R = 3440.065; 
        const toRad = (value) => value * Math.PI / 180;
        const dLat = toRad(lat2 - lat1);
        const dLon = toRad(lon2 - lon1);
        const a = Math.sin(dLat/2) * Math.sin(dLat/2) +
                  Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
                  Math.sin(dLon/2) * Math.sin(dLon/2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
        return R * c;
    }

    _calculateBearing(lat1, lon1, lat2, lon2) {
        if (lat1 === lat2 && lon1 === lon2) return 0;
        const toRad = (value) => value * Math.PI / 180;
        const toDeg = (value) => value * 180 / Math.PI;
        const phi1 = toRad(lat1);
        const phi2 = toRad(lat2);
        const deltaLambda = toRad(lon2 - lon1);
        const y = Math.sin(deltaLambda) * Math.cos(phi2);
        const x = Math.cos(phi1) * Math.sin(phi2) -
                  Math.sin(phi1) * Math.cos(phi2) * Math.cos(deltaLambda);
        const theta = Math.atan2(y, x);
        return (toDeg(theta) + 360) % 360;
    }
    
    destroy() {
        if (this._gcInterval) clearInterval(this._gcInterval);
        if (this._unsubscribeFlights) {
            this._unsubscribeFlights();
            this._unsubscribeFlights = null;
        }
        if (this._unsubscribeAtc) {
            this._unsubscribeAtc();
            this._unsubscribeAtc = null;
        }
        this._roster.clear();
        this._hubRegistry.clear();
        this._atcRegistry.clear();
        this._activeNodes.clear();
    }
}