import { MapAnimator } from './mapAnimator.js';
import { AirportLayoutManager } from './airportLayout.js';
import { LandingUI } from './landingUI.js';
import { initPlaneSizeSlider } from './planeSizeController.js';
import { GroupFlightManager } from './groupFlightManager.js';
import { updateActiveSectors } from './atcHighlights.js';
import { applyTerrainMode, removeTerrainMode } from './terrainMode.js';
import { NatTracksLayer } from './natTracksLayer.js';
import { FlownPath3D } from './flownPath3D.js';
import { LiveTraffic3D } from './liveTraffic3D.js';
import { MobileSettingsUI } from './MobileSettingsUI.js';
import { spriteUVs } from './plane-D2OPBxWC.js';
// Populates window.IFVA_DATABASE (the IFVARB Virtual Airline directory) used
// by the VA filter. Side-effect import — runs before any filter code below.
import './va-database.js';
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm';
import { AuthUI } from './authUI.js';
import { ProfileUI } from './profileUI.js';
import { PerformanceMonitor } from './performanceMonitor.js';
import { socketDataHub } from './SocketDataHub.js';
import { FlightDispatchService } from './FlightDispatchService.js';
import { MobileDashboardUI } from './MobileDashboardUI.js';
import { trackManager } from './proTrackManager.js';
import { FlightReplay } from './flightReplay.js';
import { AtcReplay } from './atcReplay.js';
import { installSlowConnectionMonitor } from './slowConnectionMonitor.js';
import { runFirstRunExperience } from './firstRunExperience.js';

installSlowConnectionMonitor();

console.log(
    "%cInflight %cdesigned by and property of _Servernoob",
    "color: #38bdf8; font-size: 16px; font-weight: 800; font-family: monospace; text-shadow: 0px 0px 8px rgba(56, 189, 248, 0.6);",
    "color: #cbd5e1; font-size: 12px; font-style: italic;"
);


const supabaseUrl = 'https://lcgaoiqwwpyqndaucyzu.supabase.co'; 
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxjZ2FvaXF3d3B5cW5kYXVjeXp1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIwNjkyOTksImV4cCI6MjA4NzY0NTI5OX0.9TO21knXR_P9E80pea7gUOu-gTjb17sCGk7BYgRRe3U'; 
const supabase = createClient(supabaseUrl, supabaseKey);

// 1. Initialize Desktop Dashboard
ProfileUI.init(supabase);

// 2. Initialize Mobile Dashboard
MobileDashboardUI.init(supabase);

// 3. Synchronize Data State (Ensures mobile and desktop share the exact same backend data array)
MobileDashboardUI._ifData = ProfileUI._ifData;

window.AuthUI = AuthUI;
window.AuthUI.init(supabase);
FlightDispatchService.init(supabase);


async function loadSpriteSheetAndGenerateIcons(map) {
    const spriteUrl = './markers.png'; 

    const USE_SDF = true;

    const img = new Image();
    img.crossOrigin = "Anonymous";
    
    // Await the physical loading of the sprite sheet
    await new Promise((resolve, reject) => {
        img.onload = resolve;
        img.onerror = reject;
        img.src = spriteUrl;
    });

    // --- GPU ACCELERATED SDF MASKING ---
    // 1. Master Base Canvas
    const baseCanvas = document.createElement('canvas');
    baseCanvas.width = img.width;
    baseCanvas.height = img.height;
    const baseCtx = baseCanvas.getContext('2d', { willReadFrequently: true });
    baseCtx.drawImage(img, 0, 0);

    const TARGET_LOGICAL_SIZE = 128; 
    const entries = Object.entries(spriteUVs);

    // --- ADAPTIVE FRAME BUDGETING ---
    const FRAME_BUDGET_MS = 12; 
    let executionStartTime = performance.now();

    for (let i = 0; i < entries.length; i++) {
        const [iconKey, uvRatios] = entries[i];
        const [xRatio, yRatio, wRatio, hRatio] = uvRatios;
        
        const pixelX = Math.floor(xRatio * img.width);
        const pixelY = Math.floor(yRatio * img.height);
        const pixelW = Math.floor(wRatio * img.width);
        const pixelH = Math.floor(hRatio * img.height);

        if (pixelW === 0 || pixelH === 0) continue;

        if (!USE_SDF) {
            const raw = baseCtx.getImageData(pixelX, pixelY, pixelW, pixelH);
            const pRatio = pixelW / TARGET_LOGICAL_SIZE;
            map.addImage(`icon-${iconKey}`, raw, { pixelRatio: pRatio, sdf: false });
            if (performance.now() - executionStartTime > FRAME_BUDGET_MS) {
                await new Promise(resolve => requestAnimationFrame(resolve));
                executionStartTime = performance.now();
            }
            continue;
        }

        
        const pRatio = pixelW / TARGET_LOGICAL_SIZE;

        // Register Base Icon with 'sdf: true' for Native Mapbox GPU Tinting
        // This replaces the old multi-canvas system and unlocks infinite colors.
        if (!map.hasImage(`icon-${iconKey}`)) {
            const baseImageData = baseCtx.getImageData(pixelX, pixelY, pixelW, pixelH);
            map.addImage(`icon-${iconKey}`, baseImageData, { pixelRatio: pRatio, sdf: true });

            // Also register a NON-SDF "natural" twin of every base icon (skip the
            // `_S` hover/selected sprites — those always render tinted). In the
            // White plane color mode we draw the un-highlighted traffic from this
            // full-detail sprite instead of the flat SDF silhouette, and only the
            // aircraft that actually need a color (your plane, watchlist, traffic
            // highlight) fall back to the tintable SDF icon. See
            // getIconImageExpression().
            if (!iconKey.endsWith('_S') && !map.hasImage(`icon-${iconKey}-nat`)) {
                const natImageData = baseCtx.getImageData(pixelX, pixelY, pixelW, pixelH);
                map.addImage(`icon-${iconKey}-nat`, natImageData, { pixelRatio: pRatio, sdf: false });
            }
        }
        
        if (performance.now() - executionStartTime > FRAME_BUDGET_MS) {
            await new Promise(resolve => requestAnimationFrame(resolve));
            executionStartTime = performance.now();
        }
    }
}


function applyTrafficHighlighting() {
    const { in: inbounds, out: outbounds } = window.currentAirportTraffic || { in: [], out: [] };
    const inSet = new Set(inbounds);
    const outSet = new Set(outbounds);

    // Update feature properties in the cache
    Object.values(currentMapFeatures).forEach(f => {
        const fid = f.properties.flightId;
        if (isTrafficHighlightActive) {
            if (inSet.has(fid)) f.properties.trafficType = 'inbound';
            else if (outSet.has(fid)) f.properties.trafficType = 'outbound';
            else f.properties.trafficType = 'none';
        } else {
            f.properties.trafficType = 'none';
        }
    });

    // 1. Update the layer's icon-image expression
    if (sectorOpsMap && sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
        sectorOpsMap.setLayoutProperty(
            'sector-ops-live-flights-layer', 
            'icon-image', 
            getIconImageExpression()
        );

        // --- NEW PREMIUM COLORS ---
        const iconColorExpression = getPremiumColorExpression();

        sectorOpsMap.setPaintProperty(
            'sector-ops-live-flights-layer', 
            'icon-color', 
            iconColorExpression
        );

        if (sectorOpsMap.getLayer('sector-ops-live-flights-hover-layer')) {
            sectorOpsMap.setPaintProperty(
                'sector-ops-live-flights-hover-layer', 
                'icon-color', 
                iconColorExpression
            );
        }
    }

    // 2. Sync the updated data to the Mapbox source
    if (sectorOpsMap && sectorOpsMap.getSource('sector-ops-live-flights-source')) {
        sectorOpsMap.getSource('sector-ops-live-flights-source').setData({
            type: 'FeatureCollection',
            features: Object.values(currentMapFeatures)
        });
    }
}

function getIconImageExpression() {
    const cat = ['coalesce', ['get', 'category'], 'B737'];

    // mapFilters lives inside the DOMContentLoaded closure; this helper is at
    // module scope and only runs after init, so read it off window.
    const colorMode = (window.mapFilters && window.mapFilters.iconColorMode) || 'default';

    // In any colored mode (Blue / Orange / custom) every aircraft is tinted, so
    // they all use the SDF silhouette that `icon-color` can recolor.
    if (colorMode !== 'default') {
        return ['concat', 'icon-', cat];
    }

    // White ("Default") mode: render the bulk of traffic from the full-detail,
    // NON-SDF sprite (which ignores icon-color and keeps its natural look) and
    // only fall back to the tintable SDF icon for the aircraft that genuinely
    // need a color — the logged-in pilot, watchlist pilots, and the airport
    // traffic highlight. Everything else stays a clean white plane.
    const needsTint = ['any',
        ['==', ['get', 'pilotRelation'], 'user'],
        ['==', ['get', 'pilotRelation'], 'watchlist'],
        ['==', ['get', 'trafficType'], 'inbound'],
        ['==', ['get', 'trafficType'], 'outbound']
    ];
    return ['concat', 'icon-', cat, ['case', needsTint, '', '-nat']];
}

// --- TWO-LAYER SDF / NATURAL RENDERING ---------------------------------------
// Mapbox can't reliably tint when a single symbol layer mixes SDF (tintable)
// and non-SDF (natural) icons in the same draw call, so aircraft are split
// across two layers that share one source and one visibility filter:
//   * sector-ops-live-flights-layer          -> SDF silhouettes, honors icon-color
//   * sector-ops-live-flights-natural-layer  -> full-detail natural sprites
// Each layer renders only the planes it owns; for the rest it emits an empty
// icon-image (''), which Mapbox skips. That keeps every layer internally
// homogeneous (all-SDF or all-natural) so tinting always works — which is what
// makes "your plane / watchlist / airport traffic" color correctly even while
// the bulk of traffic stays a clean natural white.

// True when the active color mode tints EVERY aircraft (Blue / Orange / the
// Pro custom color) rather than only the highlighted few. In those modes the
// SDF layer owns every plane and the natural layer renders nothing.
function tintsAllAircraft() {
    const mode = (window.mapFilters && window.mapFilters.iconColorMode) || 'default';
    return mode !== 'default';
}

// Boolean expression: does this individual plane need a color (and therefore
// the tintable SDF sprite)? — the logged-in pilot, watchlist pilots, and the
// airport-traffic highlight.
function planeNeedsTintExpr() {
    return ['any',
        ['==', ['get', 'pilotRelation'], 'user'],
        ['==', ['get', 'pilotRelation'], 'watchlist'],
        ['==', ['get', 'trafficType'], 'inbound'],
        ['==', ['get', 'trafficType'], 'outbound']
    ];
}

// icon-image for the SDF/tinted layer: the recolorable silhouette for the
// planes that need a color, '' (nothing) for everyone else.
function getTintedIconImageExpression() {
    const cat = ['coalesce', ['get', 'category'], 'B737'];
    const sdf = ['concat', 'icon-', cat];
    if (tintsAllAircraft()) return sdf;                 // colored mode: tint all
    return ['case', planeNeedsTintExpr(), sdf, ''];     // white mode: only the few
}

// icon-image for the non-SDF/natural layer: the full-detail sprite for the
// un-highlighted bulk, '' (nothing) for the planes the SDF layer owns.
function getNaturalIconImageExpression() {
    const cat = ['coalesce', ['get', 'category'], 'B737'];
    const nat = ['concat', 'icon-', cat, '-nat'];
    if (tintsAllAircraft()) return '';                  // colored mode: SDF owns all
    return ['case', planeNeedsTintExpr(), '', nat];     // white mode: bulk only
}

function getHoverIconImageExpression() {
    return ['concat', 'icon-', ['coalesce', ['get', 'category'], 'B737'], '_S'];
}

document.addEventListener('DOMContentLoaded', async () => {
    window.loadingStartTime = Date.now();

    // Register Service Worker for Instant Map Loading
if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js')
        .then(() => console.log("Map Tile Cache Service Worker Active"))
        .catch(err => console.warn("Service Worker registration failed", err));
}

    // --- Global Configuration ---
    const API_BASE_URL = 'https://site--indgo-backend--6dmjph8ltlhv.code.run';
    const LIVE_FLIGHTS_API_URL = 'https://site--acars-backend--6dmjph8ltlhv.code.run/flights';
    const ACARS_USER_API_URL = 'https://site--acars-backend--6dmjph8ltlhv.code.run/users'; // NEW: For user stats
    let currentServerName = localStorage.getItem('preferredServer') || 'Expert Server';
    // iOS/Capacitor app shim: inside the native app the origin is capacitor://,
    // so relative netlify-function calls must be redirected to production.
    const PRODUCTION_URL = 'https://inflight.info';
    const IS_LOCAL_OR_APP = window.location.hostname === 'localhost' ||
                            window.location.protocol === 'file:' ||
                            window.location.protocol === 'capacitor:';
    const CURRENT_SITE_URL = IS_LOCAL_OR_APP ? PRODUCTION_URL : window.location.origin;


    // --- State Variables ---
    let OWM_API_KEY = null;
    let isWeatherLayerAdded = false;
    let isTrafficHighlightActive = false; // Tracks if the airport traffic colorizer is ON
window.currentAirportTraffic = { in: [], out: [] }; // Stores IDs for the currently inspected airport
    let isCloudLayerAdded = false;   // NEW: For Clouds
    let isWindLayerAdded = false;    // NEW: For Wind
    let MAPBOX_ACCESS_TOKEN = null;
    let CURRENT_PILOT = null;
    let CURRENT_OFP_DATA = null;
    let airportsData = {};
    let precalculatedMajorAirports = null; // Caches the heavy math
    let runwaysData = {}; // NEW: To store runway data indexed by airport ICAO
    let currentMapFeatures = {}; // Key: flightId, Value: GeoJSON Feature
    const DATA_REFRESH_INTERVAL_MS = 50000; // Your current refresh interval
    const ACARS_SOCKET_URL = 'https://site--acars-backend--6dmjph8ltlhv.code.run'; // <-- NEW: For WebSocket
    let isAircraftWindowLoading = false;
    let activeFirIds = new Set(); // Globally track which FIRs are staffed
    window.getLiveFlightData = () => Object.values(currentMapFeatures);
    let natTracksLayerInstance = null;

    window.pinnedFlights = new Set();

// --- PRO GATE: Clear ALL Pro features when the user signs out ---
    // Multi-Track, Custom Map Styles, 3D Layers, and Themes are signed-in-only features.
    // This entirely wipes the Pro state and reverts the client to the free tier visually.
    try {
        supabase.auth.onAuthStateChange((event, session) => {
            if (event === 'SIGNED_OUT' || !session?.user) {
                
                // 1. Wipe Pinned Flights (Multi-Track)
                if (window.pinnedFlights && window.pinnedFlights.size > 0) {
                    const ids = Array.from(window.pinnedFlights);
                    ids.forEach(id => {
                        if (typeof window.unpinFlight === 'function') {
                            window.unpinFlight(id);
                        }
                    });
                }

                // 2. Revert Pro Map Styles back to Default Dark
                const proStyles = ['outdoors', 'nav-dark', 'nav-light', 'traffic-night', 'traffic-day', 'satellite'];
                if (proStyles.includes(mapFilters.mapStyle)) {
                    mapFilters.mapStyle = 'dark';
                }

                // 3. Revert Pro Theme Window Colors
                mapFilters.themeStartColor = '#18181b';
                mapFilters.themeEndColor = '#18181b';
                mapFilters.themeOpacity = 90;

                // 4. Wipe Pro Map Configurations (3D Buildings, Terminator, Labels)
                mapFilters.proMapConfig = {
                    showBorders: true,
                    showRoads: true,
                    showLabels: true,
                    showPois: false,
                    showWaterLabels: true,
                    showTerrain: true,
                    showAirportLayout: true,
                    showLandUse: true
                };
                mapFilters.showBuildings = false;
                mapFilters.showDayNight = false;

                // 5. Save the downgraded filters to local storage
                if (typeof saveFiltersToLocalStorage === 'function') {
                    saveFiltersToLocalStorage();
                }

                // 6. Force an immediate visual Mapbox update
                if (typeof updateMapFilters === 'function') {
                    updateMapFilters();
                }
                
                // 7. Strip out 3D layers and day/night cycle
                if (typeof updatePro3DLayers === 'function') {
                    updatePro3DLayers();
                }

                // 8. Re-apply UI Theme CSS variables instantly (No refresh required)
                const root = document.documentElement;
                if (root) {
                    const hexToRgba = (hex, alpha) => {
                        const r = parseInt(hex.slice(1, 3), 16) || 24;
                        const g = parseInt(hex.slice(3, 5), 16) || 24;
                        const b = parseInt(hex.slice(5, 7), 16) || 27;
                        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
                    };
                    root.style.setProperty('--iw-bg-start', hexToRgba('#18181b', 0.90));
                    root.style.setProperty('--iw-bg-end', hexToRgba('#18181b', 0.90));
                }

                // 9. Re-evaluate Pilot Relations to remove Custom Friend/User Highlighting
                if (typeof refreshPilotRelations === 'function') {
                    refreshPilotRelations();
                }

                // 10. Revert UI toggles if the settings menu is open during the kick
                const darkRadio = document.querySelector(`input[name="map-style-mode"][value="dark"]`);
                if (darkRadio) darkRadio.checked = true;
                
                const startColorInput = document.getElementById('theme-color-start');
                const endColorInput = document.getElementById('theme-color-end');
                if (startColorInput) startColorInput.value = '#18181b';
                if (endColorInput) endColorInput.value = '#18181b';
            }
        });
    } catch (err) {
        console.warn('Pro feature sign-out cleanup could not be registered:', err);
    }
    
    window.toggleFlightPin = function(flightId) {
        // --- PRO GATE: Multi-Track pinned flights require a signed-in account ---
        // Allow unpinning regardless (so a user who somehow has stale pins can clear them),
        // but block any new pin attempts from non-signed-in users.
        const isSignedIn = !!(typeof ProfileUI !== 'undefined' && ProfileUI?._currentUser);

        if (window.pinnedFlights.has(flightId)) {
            window.unpinFlight(flightId);
            return;
        }

        if (!isSignedIn) {
            if (typeof showNotification === 'function') {
                showNotification((typeof window !== 'undefined' && window.isIOSNative && window.isIOSNative()) ? "Multi-flight pinning isn't available on this account." : "Multi-Track is a Pro feature — sign in to pin flights.", "error");
            }
            // Surface the signup modal so the user can convert immediately
            if (window.AuthUI && typeof window.AuthUI.open === 'function') {
                window.AuthUI.open('signup');
            }
            return;
        }

        window.pinFlight(flightId);
    };

    function createMiniWindowsContainer() {
        let container = document.getElementById('mini-windows-container');
        if (!container) {
            container = document.createElement('div');
            container.id = 'mini-windows-container';
            document.body.appendChild(container);
        }
        return container;
    }

window.pinFlight = function(flightId) {
    const isSignedIn = !!(typeof ProfileUI !== 'undefined' && ProfileUI?._currentUser);
    if (!isSignedIn) {
        if (typeof showNotification === 'function') {
            showNotification((typeof window !== 'undefined' && window.isIOSNative && window.isIOSNative()) ? "Multi-flight pinning isn't available on this account." : "Multi-Track is a Pro feature — sign in to pin flights.", "error");
        }
        if (window.AuthUI && typeof window.AuthUI.open === 'function') {
            window.AuthUI.open('signup');
        }
        return;
    }

    window.pinnedFlights.add(flightId);
    const container = createMiniWindowsContainer();
    const flightProps = currentMapFeatures[flightId]?.properties;
    if (!flightProps) return;
    
    let pos = flightProps.position;
    if (typeof pos === 'string') pos = JSON.parse(pos);
    
    const imageUrl = flightProps.communityImageUrl || 'Images/default_ac.png';
    
    const card = document.createElement('div');
    card.id = `pinned-flight-${flightId}`;
    card.className = 'pinned-flight-card';
    card.style.cursor = 'pointer'; 
    
    card.innerHTML = `
        <div class="pinned-image-flush" style="width: fit-content; flex-shrink: 0; position: relative; display: flex;">
            <img src="${imageUrl}" alt="Aircraft" style="height: 100%; width: auto; max-width: 160px; object-fit: cover;" onerror="this.src='Images/default_ac.png'" />
            <div class="pinned-image-gradient"></div>
        </div>
        <div class="pinned-content">
            <button class="pinned-close" onclick="window.unpinFlight('${flightId}')" title="Unpin Flight">
                <i class="fa-solid fa-xmark"></i>
            </button>
            <div class="pinned-header">
                <span class="pinned-callsign">${flightProps.callsign || 'N/A'}</span>
            </div>
            <div class="pinned-stats">
                <div class="p-stat">
                    <span class="p-label">ALT</span>
                    <span class="p-val">${Math.round(pos.alt_ft || 0)} <small>FT</small></span>
                </div>
                <div class="p-stat">
                    <span class="p-label">SPD</span>
                    <span class="p-val">${Math.round(pos.gs_kt || 0)} <small>KTS</small></span>
                </div>
                <div class="p-stat">
                    <span class="p-label">DEST</span>
                    <span class="p-val dest-val">${flightProps.arrivalIcao || '---'}</span>
                </div>
            </div>
        </div>
    `;

    card.addEventListener('click', function(e) {
        if (e.target.closest('.pinned-close')) return;
        
        const feature = currentMapFeatures[flightId];
        if (!feature || !feature.properties) return;
        
        const props = feature.properties;
        const fp = {
            ...props,
            position: typeof props.position === 'string' ? JSON.parse(props.position) : props.position,
            aircraft: typeof props.aircraft === 'string' ? JSON.parse(props.aircraft) : props.aircraft
        };
        
        if (feature.geometry && feature.geometry.coordinates && typeof sectorOpsMap !== 'undefined') {
            sectorOpsMap.flyTo({
                center: feature.geometry.coordinates,
                zoom: 9,
                essential: true
            });
        }

        if (typeof getValidSessionId === 'function') {
            getValidSessionId().then(sessionId => {
                handleAircraftClick(fp, sessionId);
            });
        } else {
            handleAircraftClick(fp, 'default');
        }
    });

    container.appendChild(card);
    
    const pinBtn = document.getElementById('pin-flight-btn');
    if (pinBtn && currentFlightInWindow === flightId) {
        pinBtn.classList.add('active-pin');
        pinBtn.style.color = '#38bdf8';
    }
};

    window.unpinFlight = function(flightId) {
        window.pinnedFlights.delete(flightId);
        const card = document.getElementById(`pinned-flight-${flightId}`);
        if (card) card.remove();
        
        if (currentFlightInWindow !== flightId) {
            if (typeof clearLiveFlightPath === 'function') clearLiveFlightPath(flightId);
            if (typeof liveTrailCache !== 'undefined') liveTrailCache.delete(flightId);
        } else {
            const pinBtn = document.getElementById('pin-flight-btn');
            if (pinBtn) {
                pinBtn.classList.remove('active-pin');
                pinBtn.style.color = '#94a3b8';
            }
        }
    };

    // --- [NEW] Map Style Constants & State ---
    const MAP_STYLE_DARK = 'mapbox://styles/mapbox/dark-v11';
    const MAP_STYLE_LIGHT = 'mapbox://styles/servernoob/cmg3wq7an002p01s17kbx7lqk';
    const MAP_STYLE_SATELLITE = 'mapbox://styles/mapbox/satellite-streets-v12';
    
    // --- PRO MAP STYLES ---
    const MAP_STYLE_OUTDOORS = 'mapbox://styles/mapbox/outdoors-v12';
    const MAP_STYLE_NAV_DARK = 'mapbox://styles/mapbox/navigation-night-v1';
    const MAP_STYLE_NAV_LIGHT = 'mapbox://styles/mapbox/navigation-day-v1';
    const MAP_STYLE_TRAFFIC_NIGHT = 'mapbox://styles/mapbox/traffic-night-v2';
    const MAP_STYLE_TRAFFIC_DAY = 'mapbox://styles/mapbox/traffic-day-v2';

    let currentMapStyle = MAP_STYLE_DARK; // Set the default

    // --- Map-related State ---
    let lastSocketUpdateTimestamp = 0; // NEW: Tracks the last valid flight data packet
    let liveTrailCache = new Map();
    const communityAircraftCache = new Map();
    const lookupQueue = new Map();
    let liveFlightsMap = null;
    let pilotMarkers = {};
    let liveFlightsInterval = null;
    let sectorOpsMap = null;
    let mapAnimator = null;
    let airportAndAtcMarkers = {}; // Holds all airport markers (blue dots and red ATC dots)
    let sectorOpsMapRouteLayers = [];
    let sectorOpsLiveFlightPathLayers = {}; // NEW: To track multiple flight trails
    let sectorOpsAtcNotamInterval = null; // <-- MODIFIED: Renamed from sectorOpsLiveFlightsInterval
    let sectorOpsSocket = null; // <-- NEW: Socket.IO client instance
    let activeAtcFacilities = []; // To store fetched ATC data
    let activeNotams = []; // To store fetched NOTAMs data
    let atcPopup = null; // To manage a single, shared popup instance
    // State for the airport info window
    let airportInfoWindow = null;
    let airportInfoWindowRecallBtn = null;
    let currentAirportInWindow = null;
    // Monotonic token for airport-window open requests. Busy airports sit under
    // dense marker clusters, so it's easy to tap several in quick succession;
    // each tap fires an async fetch. This lets a request detect that a newer
    // one has superseded it and bail before it writes stale content (or stale
    // map-highlight state) into a window the user has already moved on from.
    let airportWindowRequestSeq = 0;
    // NEW: State for the aircraft info window
    let aircraftInfoWindow = null;
    let weatherSettingsWindow = null; // <-- This was added in the last step
    let filterSettingsWindow = null; // <-- ADD THIS NEW VARIABLE
    let aircraftInfoWindowRecallBtn = null;
    let currentFlightInWindow = null; // Stores the flightId of the last selected aircraft
    let activePfdUpdateInterval = null; // Interval for updating the PFD display
    let activeGeocodeUpdateInterval = null; // NEW: Interval for reverse geocoding
    let activeWeatherUpdateInterval = null;
    let currentAircraftPositionForGeocode = null; // NEW: Stores the latest position
    let lastGeocodeCoords = { lat: 0, lon: 0 }; // NEW: Prevents redundant calls
    // --- FIX: Added roll_deg to state to prevent flickering ---
    let lastPfdState = { track_deg: 0, timestamp: 0, roll_deg: 0 };
    // --- NEW: To cache flight data when switching to stats view ---
    let cachedFlightDataForStatsView = { flightProps: null, plan: null };
let mapFilters = {
        activeAirportStyle: 'default',
        proCustomColor: '#38bdf8',
        userPlaneColor: '#f97316',     // Orange — color of the logged-in pilot's own plane
        friendPlaneColor: '#c084fc',   // Purple — color of pilots on the watchlist
        proMapConfig: {
            showBorders: true,
            showRoads: true,
            showLabels: true,
            showPois: false,
            showWaterLabels: true,
            showTerrain: true,   // Terrain Hillshading
            showAirportLayout: true,   // [RENAMED] Airport Layout (Runways & Taxiways)
            showLandUse: true    // Parks, Forests, etc.
        },
        show3DPath: false,
        live3DTraffic: false, // 3D elevated dot view for live traffic (toolbar/settings toggle)
        showNatTracks: true,
        showNatLabels: false,
        showVaOnly: false,
        vaFilter: '', // Callsign code of a specific VA to show (e.g. 'DLVA'); '' = all VAs
        showGroupFlights: false,
        showUnstaffedAirports: false,
        showStaffOnly: false,
        hideAllAircraft: false,
        showAtcAirportsOnly: false,
        hideAtcMarkers: false,
        hideAllAirports: false,
        // New default: render active (staffed) airports as a fast GPU label
        // layer that shows staffed positions at a glance. Flip on to restore
        // the classic DOM airport tags.
        useClassicAirportTags: false,
        hideNoAtcMarkers: false,
        // ATC sector (FIR) boundary overlay. When on, active controllers'
        // FIR boundaries are drawn on the map; when off, they stay hidden
        // even while ATC is online. See applyAtcBoundaryVisibility().
        showAtcBoundaries: true,
        // Terrain Awareness mode (free for everyone). showTerrainMode draws the
        // hypsometric elevation map + hillshade; terrainTawsEnabled switches the
        // colouring to be relative to terrainTawsAltitude (ft). See
        // refreshTerrainMode() and terrainMode.js.
        showTerrainMode: false,
        terrainTawsEnabled: false,
        terrainTawsAltitude: 10000,
        planDisplayMode: 'none',
        mapStyle: 'dark',
        iconColorMode: 'default',
        showAircraftLabels: false,
        // Aircraft label designer — pick exactly which rows appear in the
        // on-map tag. Read by getAircraftLabelTextField() to build the Mapbox
        // `format` expression dynamically. See applyAircraftLabelStyle().
        labelConfig: {
            airlineLogo: true,
            callsign: true,
            aircraftType: true,
            altSpeed: true,
            route: false,
            registration: false,
            pilot: false
        },
        labelScale: 1,            // 0.8–1.4 multiplier on base text size
        labelTheme: 'default',    // default | cyan | amber | mono | contrast (pro)
        // PRO — custom active-ATC airport tag designer (see
        // getAtcTagAppearance). `style` is one of ATC_TAG_STYLES: 'classic',
        // 'chip', 'pill', 'outline', 'neon', 'glass', 'flag' or 'mono'.
        atcTagConfig: {
            enabled: false,
            style: 'classic',
            bg: '#0a0f19',
            text: '#ffffff',
            border: '#ffffff',
            opacity: 0.9,
            showFreqs: true,
            showPulse: true
        },
        useFlatMap: false,
        useSimpleFlightWindow: false,
        planeIconSize: 0.15,
        themeStartColor: '#18181b',
        themeEndColor: '#18181b',
        themeOpacity: 90,
        showBuildings: false, // NEW: 3D Buildings
        showDayNight: false   // NEW: Day/Night Cycle
    };

    window.saveFiltersToLocalStorage = saveFiltersToLocalStorage;
    window.updateMapFilters = updateMapFilters;
    window.initializeSectorOpsMap = initializeSectorOpsMap;
    window.mapFilters = mapFilters;
    // Exposed so the current mobile settings panel (MobileSettingsUI.js) can
    // drive the 3D live-traffic dot view through the canonical toggle path.
    window.setLive3DTraffic = setLive3DTraffic;

    const departureHubs = []; // Empty array
    let ALL_AVAILABLE_ROUTES = []; // Empty array
    const DYNAMIC_FLEET = []; // Empty array
    const AIRCRAFT_SELECTION_LIST = [
        // Airbus
        { value: 'A318', name: 'Airbus A318-100' },
        { value: 'A319', name: 'Airbus A319-100' },
        { value: 'A320', name: 'Airbus A320-200' },
        { value: 'A20N', name: 'Airbus A320neo' },
        { value: 'A321', name: 'Airbus A321-200' },
        { value: 'A21N', name: 'Airbus A321neo' },
        { value: 'A333', name: 'Airbus A330-300' },
        { value: 'A339', name: 'Airbus A330-900neo' },
        { value: 'A346', name: 'Airbus A340-600' },
        { value: 'A359', name: 'Airbus A350-900' },
        { value: 'A388', name: 'Airbus A380-800' },
        // Boeing
        { value: 'B712', name: 'Boeing 717-200' },
        { value: 'B737', name: 'Boeing 737-700' },
        { value: 'B738', name: 'Boeing 737-800' },
        { value: 'B739', name: 'Boeing 737-900' },
        { value: 'B38M', name: 'Boeing 737 MAX 8' },
        { value: 'B742', name: 'Boeing 747-200B' },
        { value: 'B744', name: 'Boeing 747-400' },
        { value: 'B748', name: 'Boeing 747-8' },
        { value: 'B752', name: 'Boeing 757-200' },
        { value: 'B763', name: 'Boeing 767-300ER' },
        { value: 'B772', name: 'Boeing 777-200ER' },
        { value: 'B77L', name: 'Boeing 777-200LR' },
        { value: 'B77W', name: 'Boeing 777-300ER' },
        { value: 'B788', name: 'Boeing 787-8' },
        { value: 'B789', name: 'Boeing 787-9' },
        { value: 'B78X', name: 'Boeing 787-10' },
        // Bombardier (CRJ)
        { value: 'CRJ2', name: 'Bombardier CRJ-200' },
        { value: 'CRJ7', name: 'Bombardier CRJ-700' },
        { value: 'CRJ9', name: 'Bombardier CRJ-900' },
        { value: 'CRJX', name: 'Bombardier CRJ-1000' },
        // De Havilland
        { value: 'DH8D', name: 'De Havilland Dash 8 Q400' },
        // Embraer
        { value: 'E175', name: 'Embraer E175' },
        { value: 'E190', name: 'Embraer E190' },
        // McDonnell Douglas
        { value: 'DC10', name: 'McDonnell Douglas DC-10' },
        { value: 'MD11', name: 'McDonnell Douglas MD-11' },
    ];

let cachedSessionId = null;
    let lastSessionFetchTime = 0;

    async function getValidSessionId() {
        const now = Date.now();
        // Cache the session ID for 5 minutes (300000 ms) to prevent API spam
        if (cachedSessionId && (now - lastSessionFetchTime < 300000)) {
            return cachedSessionId;
        }
        
        try {
            const res = await fetch('https://site--acars-backend--6dmjph8ltlhv.code.run/if-sessions');
            if (!res.ok) throw new Error(`HTTP error! status: ${res.status}`);
            const data = await res.json();
            const sessionId = getCurrentSessionId(data);
            if (sessionId) {
                cachedSessionId = sessionId;
                lastSessionFetchTime = now;
                return sessionId;
            }
        } catch (error) {
            console.error("Failed to fetch sessions:", error);
        }
        return 'default';
    }  

    let mapSourceUpdateTimeout = null;

function scheduleMapSourceUpdate() {
    if (mapSourceUpdateTimeout) return; 
    
    mapSourceUpdateTimeout = setTimeout(() => {
        if (typeof sectorOpsMap !== 'undefined' && sectorOpsMap && sectorOpsMap.isStyleLoaded() && sectorOpsMap.getSource('sector-ops-live-flights-source')) {
            sectorOpsMap.getSource('sector-ops-live-flights-source').setData({
                type: 'FeatureCollection',
                features: Object.values(currentMapFeatures)
            });
        }
        mapSourceUpdateTimeout = null;
    }, 400); // Batches all image resolutions into a single update every 400ms
}

// Single entry point for toggling the 3D live-traffic dot view. Persists the
// preference, drives the THREE layer, and keeps both UI affordances (the map
// toolbar button and the Settings toggle) in sync regardless of which one the
// user tapped. Safe to call before either control exists (null-guarded).
function setLive3DTraffic(on) {
    on = !!on;
    mapFilters.live3DTraffic = on;
    try { saveFiltersToLocalStorage(); } catch (_) {}
    if (typeof LiveTraffic3D !== 'undefined') LiveTraffic3D.setVisible(on);

    const btn = document.getElementById('live-3d-toggle-btn');
    if (btn) btn.classList.toggle('active', on);
    const toggle = document.getElementById('set-3d-traffic');
    if (toggle) toggle.checked = on;
}

// --- PREMIUM PLANE COLOR EXPRESSION ---
// Single source of truth for the layer's icon-color paint expression.
// Priority order:
//   1. Logged-in user's own plane  -> amber/gold
//   2. Pilots on the user's watchlist -> amethyst/purple
//   3. Airport traffic highlighting (inbound/outbound) when active
//   4. Default active color from mapFilters
function getPremiumColorExpression() {
    let activeColor = '#ffffff';
    // 'default' (White) keeps the bulk of traffic on the natural layer, so its
    // activeColor never actually paints anyone — only the highlighted planes
    // reach the SDF layer, and those are caught by the user/watchlist/traffic
    // cases below. 'custom' is the Pro mode that recolors every other aircraft.
    if (mapFilters.iconColorMode === 'custom') activeColor = mapFilters.proCustomColor || '#38bdf8';
    else if (mapFilters.iconColorMode === 'blue') activeColor = '#00a8ff';
    else if (mapFilters.iconColorMode === 'orange') activeColor = '#ff9900';

    // User-configurable user/friend colors (with sensible fallbacks). These
    // are independent of the global "Custom Plane Color" setting — that only
    // controls the fallback color for everyone else.
    const userColor = mapFilters.userPlaneColor || '#f97316';
    const friendColor = mapFilters.friendPlaneColor || '#c084fc';

    return [
        'case',
        ['==', ['get', 'pilotRelation'], 'user'], userColor,
        ['==', ['get', 'pilotRelation'], 'watchlist'], friendColor,
        ['match',
            ['get', 'trafficType'],
            'inbound', '#38bdf8',
            'outbound', '#f59e0b',
            activeColor
        ]
    ];
}

// Re-tag every cached feature with its current pilotRelation, then push the
// updated source to Mapbox. Call this whenever the logged-in user, their IF
// username, or their watchlist changes so colors update without waiting for
// the next polling tick.
function refreshPilotRelations() {
    try {
        const profile = (typeof ProfileUI !== 'undefined') ? ProfileUI : null;
        const myIfName = profile?._currentUser?.user_metadata?.if_username?.toLowerCase() || null;
        const watchlist = profile?._watchlist || [];
        const watchSet = new Set(
            watchlist
                .map(w => w?.watched_username?.toLowerCase())
                .filter(Boolean)
        );

        Object.values(currentMapFeatures).forEach(f => {
            const flightUser = f?.properties?.username?.toLowerCase();
            let relation = 'none';
            if (myIfName && flightUser === myIfName) {
                relation = 'user';
            } else if (flightUser && watchSet.has(flightUser)) {
                relation = 'watchlist';
            }
            f.properties.pilotRelation = relation;
        });

        // Push the re-tagged features so Mapbox re-evaluates the color expression.
        if (typeof sectorOpsMap !== 'undefined' && sectorOpsMap && sectorOpsMap.getSource && sectorOpsMap.getSource('sector-ops-live-flights-source')) {
            sectorOpsMap.getSource('sector-ops-live-flights-source').setData({
                type: 'FeatureCollection',
                features: Object.values(currentMapFeatures)
            });
        }
    } catch (err) {
        console.warn('refreshPilotRelations failed:', err);
    }
}

// Expose so profileUI.js (and anywhere else) can trigger an immediate refresh
// when the user logs in or edits their watchlist.
window.refreshPilotRelations = refreshPilotRelations;

// Re-apply the icon-image / icon-color expressions to both aircraft layers
// (SDF "tinted" + non-SDF "natural") and the hover layer. Call this whenever
// the color mode, custom color, pilot relations, or traffic highlight changes
// so the two layers stay in sync. Icon size is managed separately.
function applyAircraftLayerStyles() {
    if (typeof sectorOpsMap === 'undefined' || !sectorOpsMap) return;
    const colorExpr = getPremiumColorExpression();

    if (sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
        sectorOpsMap.setLayoutProperty('sector-ops-live-flights-layer', 'icon-image', getTintedIconImageExpression());
        sectorOpsMap.setPaintProperty('sector-ops-live-flights-layer', 'icon-color', colorExpr);
    }
    if (sectorOpsMap.getLayer('sector-ops-live-flights-natural-layer')) {
        sectorOpsMap.setLayoutProperty('sector-ops-live-flights-natural-layer', 'icon-image', getNaturalIconImageExpression());
    }
    if (sectorOpsMap.getLayer('sector-ops-live-flights-hover-layer')) {
        sectorOpsMap.setLayoutProperty('sector-ops-live-flights-hover-layer', 'icon-image', getHoverIconImageExpression());
        sectorOpsMap.setPaintProperty('sector-ops-live-flights-hover-layer', 'icon-color', colorExpr);
    }
}
window.applyAircraftLayerStyles = applyAircraftLayerStyles;

// --- PREMIUM CLOUD SYNC ENGINE ---
    let cloudSyncTimeout = null;

    async function saveFiltersToLocalStorage() {
        try {
            // 1. Instant Local Commit (Zero Latency UI)
            const filtersJson = JSON.stringify(mapFilters);
            localStorage.setItem('mapFilters', filtersJson);

            // 2. Debounced Cloud Sync for Pro Users
            const { data: sessionData } = await supabase.auth.getSession();
            if (sessionData?.session?.user) {
                const userId = sessionData.session.user.id;
                
                // Clear existing timeout to prevent database hammering during rapid UI toggles
                if (cloudSyncTimeout) clearTimeout(cloudSyncTimeout);
                
                cloudSyncTimeout = setTimeout(async () => {
                    try {
                        const { data: profile } = await supabase
                            .from('profiles')
                            .select('is_pro')
                            .eq('id', userId)
                            .single();

                        if (profile && profile.is_pro) {
                            const { error } = await supabase
                                .from('profiles')
                                .update({ map_filters: mapFilters })
                                .eq('id', userId);
                                
                            if (!error) {
                                console.log("☁️ Premium Settings Synced to Cloud.");
                            } else {
                                console.warn("Cloud sync failed. Ensure 'map_filters' JSONB column exists in 'profiles' table.");
                            }
                        }
                    } catch (err) {
                        console.warn("Cloud sync interrupted:", err);
                    }
                }, 1200); // 1.2s Debounce for silky smooth performance
            }
        } catch (e) {
            console.warn("Could not save filters locally.", e);
        }
    }

    async function loadFiltersFromLocalStorage() {
        // 1. Instant Local Paint
        const savedFilters = localStorage.getItem('mapFilters');
        if (savedFilters) {
            try {
                const parsedFilters = JSON.parse(savedFilters);
                Object.assign(mapFilters, parsedFilters);
                // Saved label configs predating newer rows (e.g. airlineLogo)
                // replace the defaults wholesale above — backfill missing keys
                // so the map, previews and settings toggles all agree.
                mapFilters.labelConfig = Object.assign({}, DEFAULT_LABEL_CONFIG, mapFilters.labelConfig || {});
                applyMapStyleMapping();
            } catch (e) {
                console.warn("Local storage parse failed.", e);
            }
        }

        // 2. Seamless Background Cloud Reconciliation
        try {
            const { data: sessionData } = await supabase.auth.getSession();
            if (sessionData?.session?.user) {
                const userId = sessionData.session.user.id;
                
                const { data: profile } = await supabase
                    .from('profiles')
                    .select('is_pro, map_filters')
                    .eq('id', userId)
                    .single();

                // Only overwrite if Pro is active AND cloud settings exist
                if (profile && profile.is_pro && profile.map_filters) {
                    const cloudJson = JSON.stringify(profile.map_filters);
                    
                    // Compare cloud state with local state to prevent unnecessary repaints
                    if (cloudJson !== savedFilters) {
                        Object.assign(mapFilters, profile.map_filters);
                        mapFilters.labelConfig = Object.assign({}, DEFAULT_LABEL_CONFIG, mapFilters.labelConfig || {});
                        
                        // Re-sync local storage to match the authoritative cloud state
                        localStorage.setItem('mapFilters', cloudJson);
                        applyMapStyleMapping();
                        
                        // Force Mapbox and UI to visually update seamlessly
                        if (typeof updateMapFilters === 'function') {
                            updateMapFilters();
                        }
                        console.log("☁️ Settings restored from Cloud.");
                    }
                }
            }
        } catch (e) {
            console.warn("Cloud settings retrieval failed.", e);
        }
    }

    // --- Pro entitlement cache -------------------------------------------
    // The app reads `profiles.is_pro` from Supabase in a few places ad-hoc.
    // For features that need a synchronous "is this user Pro?" answer (e.g.
    // the Inflight multi-flight tracking limit) we cache it once here and
    // expose it on window. Defaults to false until the lookup resolves so a
    // slow/failed query never accidentally unlocks Pro-only behavior.
    window.InflightUser = window.InflightUser || { isPro: false, loaded: false };
    window.isInflightPro = function () {
        return !!(window.InflightUser && window.InflightUser.isPro);
    };

    async function refreshProStatus() {
        try {
            const { data: sessionData } = await supabase.auth.getSession();
            const userId = sessionData?.session?.user?.id;
            if (!userId) {
                window.InflightUser = { isPro: false, loaded: true };
                return false;
            }
            const { data: profile, error } = await supabase
                .from('profiles')
                .select('is_pro')
                .eq('id', userId)
                .single();
            const isPro = !error && !!(profile && profile.is_pro);
            window.InflightUser = { isPro, loaded: true };
            window.dispatchEvent(new CustomEvent('proStatusChanged', { detail: { isPro } }));
            return isPro;
        } catch (e) {
            console.warn('[Pro] status refresh failed:', e);
            window.InflightUser = { isPro: false, loaded: true };
            return false;
        }
    }
    window.refreshProStatus = refreshProStatus;

    // Helper function to extract repetitive style mapping logic
    function applyMapStyleMapping() {
        if (mapFilters.mapStyle) {
            const stylesMap = {
                'light': MAP_STYLE_LIGHT,
                'satellite': MAP_STYLE_SATELLITE,
                'outdoors': MAP_STYLE_OUTDOORS,
                'nav-dark': MAP_STYLE_NAV_DARK,
                'nav-light': MAP_STYLE_NAV_LIGHT,
                'traffic-night': MAP_STYLE_TRAFFIC_NIGHT,
                'traffic-day': MAP_STYLE_TRAFFIC_DAY,
                'dark': MAP_STYLE_DARK
            };
            currentMapStyle = stylesMap[mapFilters.mapStyle] || MAP_STYLE_DARK;
        }
    }

    async function fetchAndRenderRosters(hubIcao) {
        // This feature is disabled
        console.log("Roster feature is disabled.");
        return []; // Return empty array
    }

    /**
     * Helper Function: Renders the dispatch preview.
     * This is the 'populateDispatchPass' function that
     * SimbriefIntegration.js (sb.js) requires.
     */
    function populateDispatchPass(container, plan, options = {}) {
        // Clear previous content
        container.innerHTML = '';

        // --- Helper functions for formatting ---
        const formatEtd = (date) => {
            const d = new Date(date);
            return {
                time: d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' }),
                date: d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' })
            };
        };
        
        const formatEet = (decimalHours) => {
            const hours = Math.floor(decimalHours);
            const minutes = Math.round((decimalHours % 1) * 60);
            return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
        };

        // --- Format data for display ---
        const etd = formatEtd(plan.etd);
        const eetFormatted = formatEet(plan.eet);
        const cargoFormatted = (plan.cargo > 0) ? plan.cargo.toFixed(0) : '0';
        const cruiseSpeed = String(plan.cruiseSpeed).startsWith('M') ? plan.cruiseSpeed : `M${plan.cruiseSpeed}`;

        // --- Define reusable inline styles ---
        const sectionStyle = `padding: 16px 20px; border-bottom: 1px solid rgba(255, 255, 255, 0.1);`;
        const gridStyle = `display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 16px;`;
        const itemStyle = `display: flex; flex-direction: column; gap: 4px;`;
        const labelStyle = `font-size: 0.8rem; color: #9fa8da; text-transform: uppercase; font-weight: 600;`;
        const valueStyle = `font-size: 1.1rem; color: #fff; font-weight: 600;`;
        const headingStyle = `margin: 0 0 15px 0; color: #00a8ff; font-size: 1rem; font-weight: 600; display: flex; align-items: center; gap: 8px;`;
        const metarStyle = `display: block; width: 100%; box-sizing: border-box; background: rgba(0,0,0,0.2); padding: 8px 10px; border-radius: 4px; font-family: monospace; color: #e0e0e0; font-size: 0.85rem; border: 1px solid rgba(255,255,255,0.1);`;

        // Build the HTML for the dispatch preview
        container.innerHTML = `
            <div class="info-panel-header" style="display: flex; justify-content: space-between; align-items: center; padding: 16px 20px; background: rgba(10, 12, 26, 0.6); border-bottom: 1px solid rgba(255, 255, 255, 0.1);">
                <h3>Dispatch Preview</h3>
                <button id="dispatch-close-btn" class="sb-close-btn" title="Close Preview" style="background: none; border: none; color: #fff; font-size: 1.2rem; cursor: pointer;">
                    <i class="fa-solid fa-times"></i>
                </button>
            </div>
            <div class="dispatch-pass-body" style="padding: 0; color: #e8eaf6;">

                <div class="dispatch-section" style="${sectionStyle}">
                    <h4 style="${headingStyle}"><i class="fa-solid fa-plane"></i> Flight Details</h4>
                    <div class="dispatch-grid" style="${gridStyle} grid-template-columns: 1fr 1fr;">
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Flight</span>
                            <span style="${valueStyle}">${plan.flightNumber}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Aircraft</span>
                            <span style="${valueStyle}">${plan.aircraft}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Departure</span>
                            <span style="${valueStyle}">${plan.departure}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Arrival</span>
                            <span style="${valueStyle}">${plan.arrival}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Alternate</span>
                            <span style="${valueStyle}">${plan.alternate || 'N/A'}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Squawk</span>
                            <span style="${valueStyle}">${plan.squawkCode || '----'}</span>
                        </div>
                    </div>
                </div>

                <div class="dispatch-section" style="${sectionStyle}">
                    <h4 style="${headingStyle}"><i class="fa-solid fa-clock"></i> Performance & Time</h4>
                    <div class="dispatch-grid" style="${gridStyle}">
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">ETD (UTC)</span>
                            <span style="${valueStyle}">${etd.time}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Date</span>
                            <span style="${valueStyle}">${etd.date}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">EET</span>
                            <span style="${valueStyle}">${eetFormatted}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Cruise</span>
                            <span style="${valueStyle}">${plan.cruiseAltitude} ft / ${cruiseSpeed}</span>
                        </div>
                    </div>
                </div>

                <div class="dispatch-section" style="${sectionStyle}">
                    <h4 style="${headingStyle}"><i class="fa-solid fa-weight-hanging"></i> Weight & Fuel</h4>
                    <div class="dispatch-grid" style="${gridStyle}">
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">POB</span>
                            <span style="${valueStyle}">${plan.pob}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">Cargo (KG)</span>
                            <span style="${valueStyle}">${cargoFormatted}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">ZFW (KG)</span>
                            <span style="${valueStyle}">${plan.zfw}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle}">
                            <span style="${labelStyle}">TOW (KG)</span>
                            <span style="${valueStyle}">${plan.tow}</span>
                        </div>
                        <div class="dispatch-item" style="${itemStyle} grid-column: 1 / -1;">
                            <span style="${labelStyle}">Block Fuel (KG)</span>
                            <span style="${valueStyle}">${plan.fuelTotal}</span>
                        </div>
                    </div>
                </div>

                <div class="dispatch-section" style="${sectionStyle}">
                    <h4 style="${headingStyle}"><i class="fa-solid fa-cloud-sun"></i> Weather</h4>
                    <div class="dispatch-item" style="${itemStyle} margin-bottom: 12px;">
                        <span style="${labelStyle}">Departure (${plan.departure})</span>
                        <code style="${metarStyle}">${plan.departureWeather.raw}</code>
                    </div>
                    <div class="dispatch-item" style="${itemStyle}">
                        <span style="${labelStyle}">Arrival (${plan.arrival})</span>
                        <code style="${metarStyle}">${plan.arrivalWeather.raw}</code>
                    </div>
                </div>
                
                <div class="dispatch-section" style="padding: 16px 20px; background: rgba(10, 12, 26, 0.6);">
                    <h4 style="${headingStyle}"><i class="fa-solid fa-route"></i> Full Route</h4>
                    <textarea readonly style="width: 100%; height: 100px; background: #1a1a1a; color: #fff; border: 1px solid #444; border-radius: 4px; font-family: monospace; padding: 8px; box-sizing: border-box;">${plan.route}</textarea>
                </div>
                
                ${options.isPreview ? `
                    <div class="dispatch-button-area" style="padding: 16px 20px; background: rgba(10, 12, 26, 0.6);">
                        <button id="save-from-simbrief-btn" class="sb-generate-btn" style="width: 100%; padding: 12px; background: #00a8ff; color: #fff; border: none; border-radius: 5px; cursor: pointer; font-size: 1rem; font-weight: 600;">
                            <i class="fa-solid fa-save"></i> Save This Flight Plan
                        </button>
                    </div>
                ` : ``}
            </div>
        `;
    }

    /**
 * Helper Function: Callback for when flights are saved/erased.
 * This is the 'onFlightSaved' callback for SimbriefIntegration.js.
 * --- MODIFIED: This function now re-renders the saved flight list. ---
 */
function refreshSavedFlightList() {
    console.log("SimbriefIntegration: onFlightSaved callback triggered!");
    // This new function will render the list in the UI
    renderSavedFlightList();
}

/**
 * --- [NEW FUNCTION] ---
 * Renders the list of saved flights from local storage into the UI.
 */
function renderSavedFlightList() {
    // Ensure SimbriefIntegration is available
    if (typeof SimbriefIntegration === 'undefined') {
        return;
    }

    const flights = SimbriefIntegration.getAllSavedFlights();
    
    const listContainer = document.getElementById('saved-flights-list');
    const noFlightsMsg = document.getElementById('no-saved-flights-msg');
    const deleteAllBtn = document.getElementById('saved-flights-delete-all-btn');

    if (!listContainer || !noFlightsMsg || !deleteAllBtn) {
        // The HTML for the panel hasn't loaded yet, or is missing.
        return;
    }

    // Clear the list first
    listContainer.innerHTML = '';

    if (flights.length === 0) {
        // Show "No flights" message
        noFlightsMsg.style.display = 'block';
        listContainer.style.display = 'none';
        deleteAllBtn.style.display = 'none';
    } else {
        // Hide "No flights" message and show list
        noFlightsMsg.style.display = 'none';
        listContainer.style.display = 'block';
        deleteAllBtn.style.display = 'block';

        // `getAllSavedFlights` returns flights oldest-to-newest.
        // We reverse it to show the newest flight on top.
        flights.reverse().forEach(flight => {
            const flightHtml = `
                <li class="saved-flight-item">
                    <div class="saved-flight-info">
                        <strong>
                            <i class="fa-solid fa-plane"></i>
                            ${flight.flightNumber || 'No Callsign'}
                        </strong>
                        <small>${flight.departure || '???'} &rarr; ${flight.arrival || '???'} (${flight.aircraft || 'A/C'})</small>
                    </div>
                    <div class="saved-flight-actions">
                        <button class="saved-flight-btn saved-flight-view-btn" data-flight-id="${flight.id}">
                            View
                        </button>
                        <button class="saved-flight-btn saved-flight-delete-btn" data-flight-id="${flight.id}" title="Delete this plan">
                            <i class="fa-solid fa-trash"></i>
                        </button>
                    </div>
                </li>
            `;
            listContainer.insertAdjacentHTML('beforeend', flightHtml);
        });
    }
}

/**
 * --- [NEW FUNCTION] ---
 * Handles all clicks for the saved flights list using event delegation.
 */
function handleSavedFlightListClick(e) {
    const viewBtn = e.target.closest('.saved-flight-view-btn');
    const deleteBtn = e.target.closest('.saved-flight-delete-btn');
    const deleteAllBtn = e.target.closest('#saved-flights-delete-all-btn');

    // 1. Handle "View" button click
    if (viewBtn) {
        e.preventDefault();
        const flightId = viewBtn.dataset.flightId;
        if (!flightId || typeof SimbriefIntegration === 'undefined') return;

        const flights = SimbriefIntegration.getAllSavedFlights();
        const flightToView = flights.find(f => f.id === flightId);

        if (flightToView) {
            // The dispatch pass renderer needs 'etd' and 'eta' as Date objects.
            // The saved payload has 'etd' as a string and only 'eet' (decimal hours).
            
            // Re-calculate ETA
            const etdDate = new Date(flightToView.etd);
            const eetMs = (flightToView.eet || 0) * 3600 * 1000;
            const etaDate = new Date(etdDate.getTime() + eetMs);

            // Get containers
            const dispatchDisplay = document.getElementById('dispatch-pass-display');
            const manualDispatchContainer = document.getElementById('manual-dispatch-container');

            if (!dispatchDisplay || !manualDispatchContainer) return;

            // Populate the dispatch pass
            // We create a new object to pass the correct Date objects
            populateDispatchPass(dispatchDisplay, {
                ...flightToView,
                etd: etdDate,
                eta: etaDate
            }, { isPreview: false }); // isPreview: false hides the "Save" button

            // Show the dispatch pass and hide the form
            manualDispatchContainer.style.display = 'none';
            dispatchDisplay.style.display = 'block';

            // Scroll the tab content to the top
            const tabContent = dispatchDisplay.closest('.tab-content');
            if (tabContent) {
                tabContent.scrollTop = 0;
            }
        }
        return; // End execution
    }

    // 2. Handle "Delete" (single) button click
    if (deleteBtn) {
        e.preventDefault();
        const flightId = deleteBtn.dataset.flightId;
        if (!flightId || typeof SimbriefIntegration === 'undefined') return;
        
        // Use native browser confirm dialog
        if (confirm("Are you sure you want to delete this flight plan?")) {
            const flights = SimbriefIntegration.getAllSavedFlights();
            const newFlights = flights.filter(f => f.id !== flightId);
            
            // Save the new array back to local storage
            // Note: sb.js doesn't have a "delete one" method, so we do it manually
            localStorage.setItem('communityTrackerFlights', JSON.stringify(newFlights));
            
            // Manually trigger the refresh
            refreshSavedFlightList();
            showNotification('Flight plan deleted.', 'success');
        }
        return; // End execution
    }

    // 3. Handle "Delete All" button click
    if (deleteAllBtn) {
        e.preventDefault();
        if (typeof SimbriefIntegration === 'undefined') return;

        // Use native browser confirm dialog
        if (confirm("Are you sure you want to delete ALL saved flight plans? This cannot be undone.")) {
            // This function from sb.js will delete the key
            // and automatically call our 'refreshSavedFlightList'
            // callback, which re-renders the (now empty) list.
            SimbriefIntegration.eraseAllSavedFlights();
        }
        return; // End execution
    }
}
    
    async function fetchAndRenderRoutes() {
        // This feature is disabled
        console.log("Route feature is disabled.");
        const routeContainer = document.getElementById('route-list-container');
        if (routeContainer) {
             routeContainer.innerHTML = '<p class="muted-text" style="padding: 2rem;">Route loading is disabled.</p>';
        }
        return []; // Return empty array
    }


    // --- Helper: Fetch API Keys from Netlify Function ---
    async function fetchApiKeys() {
        try {
            const response = await fetch(`${CURRENT_SITE_URL}/.netlify/functions/config`);
            if (!response.ok) throw new Error('Could not fetch server configuration.');
            
            const config = await response.json();
            
            if (!config.mapboxToken) throw new Error('Mapbox token is missing from server configuration.');
            if (!config.owmApiKey) throw new Error('OWM API key is missing from server configuration.');

            // Set Mapbox key
            MAPBOX_ACCESS_TOKEN = config.mapboxToken;
            mapboxgl.accessToken = MAPBOX_ACCESS_TOKEN;
            
            // Set OWM key
            OWM_API_KEY = config.owmApiKey;

        } catch (error) {
            console.error('Failed to initialize API keys:', error.message);
            showNotification('Could not load mapping or weather services.', 'error');
        }
    }


function injectCustomStyles() {
    const styleId = 'sector-ops-custom-styles';
    if (document.getElementById(styleId)) return;

    const css = `

    /* --- MODERN HEADER REDESIGN --- */
.ac-header-modern {
    position: relative;
    height: 220px; /* Taller for better impact */
    background-size: cover;
    background-position: center;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    overflow: hidden;
}

/* Dark gradient overlay for text readability */
.ac-header-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(180deg,
        rgba(0,0,0,0.2) 0%,
        rgba(0,0,0,0.1) 40%,
        var(--iw-bg-end) 100%
    );
    z-index: 1;
}

/* Top Row: Callsign & Status */
.ac-header-top {
    position: relative;
    z-index: 2;
    padding: 20px;
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
}

.ac-identity-group h1 {
    margin: 0;
    font-size: 2.2rem;
    font-weight: 800;
    color: #fff;
    letter-spacing: -1px;
    line-height: 1;
    text-shadow: 0 2px 10px rgba(0,0,0,0.5);
    display: flex;
    align-items: center;
    gap: 12px;
}

.ac-logo-hero {
    height: 28px;
    width: auto;
    object-fit: contain;
    filter: drop-shadow(0 2px 4px rgba(0,0,0,0.5));
}

.ac-sub-identity {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 6px;
    font-size: 0.85rem;
    font-weight: 500;
    color: #cbd5e1;
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.ac-sub-identity .separator {
    width: 4px;
    height: 4px;
    background: #64748b;
    border-radius: 50%;
}

/* Phase Badge (Top Right) */
.phase-badge-hero {
    background: rgba(15, 23, 42, 0.6);
    backdrop-filter: blur(8px);
    border: 1px solid rgba(255,255,255,0.1);
    padding: 6px 12px;
    border-radius: 99px;
    font-size: 0.75rem;
    font-weight: 700;
    color: #fff;
    display: flex;
    align-items: center;
    gap: 8px;
    box-shadow: 0 4px 15px rgba(0,0,0,0.3);
}

.phase-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #4ade80;
    box-shadow: 0 0 8px #4ade80;
    animation: pulse 2s infinite;
}

/* Bottom Strip: Route Info */
.ac-header-route-strip {
    position: relative;
    z-index: 2;
    padding: 0 24px 16px 24px;
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    gap: 20px;
    align-items: end;
}

.route-node {
    display: flex;
    flex-direction: column;
}

.route-node.end {
    text-align: right;
    align-items: flex-end;
}

.city-name {
    font-size: 0.75rem;
    color: #94a3b8;
    font-weight: 600;
    text-transform: uppercase;
    margin-bottom: 2px;
    max-width: 120px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.icao-large {
    font-family: 'JetBrains Mono', monospace;
    font-size: 1.8rem;
    font-weight: 700;
    color: #fff;
    line-height: 1;
}

.time-small {
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.85rem;
    color: #38bdf8;
    margin-top: 4px;
    font-weight: 600;
}

/* Middle Progress Visual */
.route-visual {
    display: flex;
    flex-direction: column;
    align-items: center;
    width: 100%;
    padding-bottom: 8px;
}

.flight-progress-track {
    width: 100%;
    height: 4px;
    background: rgba(255,255,255,0.1);
    border-radius: 2px;
    position: relative;
    overflow: visible;
}

.flight-progress-fill {
    height: 100%;
    background: #38bdf8;
    border-radius: 2px;
    position: relative;
    box-shadow: 0 0 10px rgba(56, 189, 248, 0.5);
}


    /* --- TRIP CARD (REDESIGNED) ---
       Desktop: floating bottom-center card, fixed width.
       Mobile:  full-width sheet anchored to the bottom edge with safe-area
                padding so nothing is hidden under iOS gesture areas. */
#trip-card-takeover {
    position: fixed;
    z-index: 9999;
    pointer-events: none;
    display: none;
    font-family: 'Inter', sans-serif;
    transition: opacity 0.35s ease, transform 0.4s cubic-bezier(0.16, 1, 0.3, 1);
    opacity: 0;
}

/* Desktop layout */
#trip-card-takeover {
    bottom: 24px;
    left: 50%;
    transform: translateX(-50%) translateY(24px);
    width: 380px;
    max-width: calc(100vw - 24px);
}
#trip-card-takeover.active {
    display: block;
    pointer-events: auto;
    transform: translateX(-50%) translateY(0);
    opacity: 1;
}

/* Mobile layout — full-width drawer */
@media (max-width: 640px) {
    #trip-card-takeover {
        bottom: 0;
        left: 0;
        right: 0;
        width: 100%;
        max-width: 100%;
        transform: translateY(120%);
        padding: 0 10px;
        padding-bottom: calc(env(safe-area-inset-bottom, 0px) + 12px);
        box-sizing: border-box;
    }
    #trip-card-takeover.active {
        transform: translateY(0);
    }
}

.tc-card {
    background: linear-gradient(180deg, #11141f 0%, #0a0b10 100%);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 18px;
    overflow: hidden;
    box-shadow: 0 20px 60px rgba(0, 0, 0, 0.55), 0 0 0 1px rgba(56, 189, 248, 0.04);
}

.tc-hero {
    position: relative;
    width: 100%;
    height: 150px;
    background: #0f172a;
    overflow: hidden;
}
@media (max-width: 640px) {
    .tc-hero { height: 130px; }
}

.tc-bg-layer {
    position: absolute;
    inset: 0;
    background-color: #0f172a;
    background-size: cover;
    background-position: center;
    transition: background-image 0.5s ease-in-out;
}
.tc-hero-gradient {
    position: absolute;
    inset: 0;
    background: linear-gradient(to bottom, rgba(15,23,42,0.05) 0%, rgba(17,20,31,0.55) 70%, rgba(17,20,31,1) 100%);
    pointer-events: none;
}

.tc-exit-btn {
    position: absolute;
    top: 12px;
    right: 12px;
    z-index: 10;
    background: rgba(0,0,0,0.5);
    backdrop-filter: blur(6px);
    -webkit-backdrop-filter: blur(6px);
    border: 1px solid rgba(255,255,255,0.15);
    color: #fff;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 0.85rem;
    transition: background 0.2s ease, border-color 0.2s ease, transform 0.15s ease;
}
.tc-exit-btn:hover {
    background: rgba(239, 68, 68, 0.85);
    border-color: rgba(239, 68, 68, 1);
}
.tc-exit-btn:active { transform: scale(0.92); }

.tc-hero-badge {
    position: absolute;
    top: 12px;
    left: 12px;
    z-index: 10;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 10px;
    background: rgba(0,0,0,0.55);
    backdrop-filter: blur(6px);
    -webkit-backdrop-filter: blur(6px);
    border-radius: 999px;
    border: 1px solid rgba(255,255,255,0.12);
    font-size: 0.58rem;
    font-weight: 800;
    letter-spacing: 1px;
    color: #fff;
    text-transform: uppercase;
}
.tc-hero-badge .tc-live-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #22c55e;
    box-shadow: 0 0 6px rgba(34,197,94,0.7);
    animation: tc-pulse 1.5s ease-in-out infinite;
}
@keyframes tc-pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.35; }
}

.tc-body {
    padding: 16px 18px 18px;
    display: flex;
    flex-direction: column;
    gap: 14px;
}

.tc-title-row {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
}
.tc-callsign {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 1.35rem;
    font-weight: 800;
    color: #fff;
    margin: 0;
    line-height: 1.1;
    letter-spacing: -0.4px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}
.tc-subtitle {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 0.72rem;
    color: #94a3b8;
    font-weight: 500;
    overflow: hidden;
}
.tc-pilot {
    color: #38bdf8;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    white-space: nowrap;
}
.tc-divider { color: #475569; flex-shrink: 0; }
.tc-ac {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
}

.tc-route {
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: center;
    gap: 12px;
}
.tc-route-airport {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
}
.tc-route-airport-right {
    align-items: flex-end;
    text-align: right;
}
.tc-route-label {
    font-size: 0.55rem;
    color: #64748b;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 1px;
}
.tc-icao {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 1.5rem;
    font-weight: 800;
    color: #fff;
    line-height: 1;
}
.tc-route-progress { padding: 0 4px; min-width: 60px; }
.tc-progress-track {
    position: relative;
    width: 100%;
    height: 4px;
    background: rgba(255,255,255,0.08);
    border-radius: 2px;
    display: flex;
    align-items: center;
}
.tc-progress-bar {
    position: absolute;
    left: 0;
    height: 100%;
    width: 0%;
    background: linear-gradient(90deg, #38bdf8, #a855f7);
    border-radius: 2px;
    box-shadow: 0 0 8px rgba(56,189,248,0.5);
    transition: width 0.6s ease;
}
.tc-plane-icon {
    position: absolute;
    left: 0%;
    transform: translateX(-50%);
    color: #fff;
    font-size: 12px;
    filter: drop-shadow(0 1px 3px rgba(0,0,0,0.8));
    transition: left 0.6s ease;
}

.tc-stats {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
}
.tc-stat {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 10px 12px;
    background: rgba(255,255,255,0.03);
    border: 1px solid rgba(255,255,255,0.05);
    border-radius: 10px;
}
.tc-stat-label {
    font-size: 0.55rem;
    color: #64748b;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 1px;
}
.tc-stat-value {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 1rem;
    color: #fff;
    font-weight: 700;
}
.tc-stat-value .tc-alt { color: #38bdf8; }
.tc-stat-value .tc-spd { color: #fbbf24; }
.tc-unit { color: #64748b; font-size: 0.7rem; margin-left: 3px; font-weight: 600; }

.tc-share-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    width: 100%;
    padding: 12px 20px;
    background: linear-gradient(135deg, #38bdf8, #a855f7);
    color: #fff;
    border: none;
    border-radius: 12px;
    cursor: pointer;
    font-family: 'Inter', sans-serif;
    font-size: 0.85rem;
    font-weight: 700;
    letter-spacing: 0.3px;
    box-shadow: 0 8px 24px rgba(56,189,248,0.3), inset 0 1px 0 rgba(255,255,255,0.15);
    transition: transform 0.15s ease, box-shadow 0.15s ease, background 0.25s ease;
}
.tc-share-btn:hover {
    transform: translateY(-1px);
    box-shadow: 0 12px 28px rgba(56,189,248,0.45), inset 0 1px 0 rgba(255,255,255,0.2);
}
.tc-share-btn:active { transform: translateY(0); }
.tc-share-btn i { font-size: 0.95rem; }

    .settings-section { display: flex; flex-direction: column; gap: 16px; }
.settings-row { 
    display: flex; 
    justify-content: space-between; 
    align-items: center; 
    background: rgba(255,255,255,0.03); 
    padding: 12px 16px; 
    border-radius: 10px; 
    border: 1px solid rgba(255,255,255,0.05);
}
.row-label { color: #e4e4e7; font-size: 0.85rem; font-weight: 500; display: flex; align-items: center; gap: 10px; }
.row-label i { color: #52525b; width: 16px; text-align: center; }
.settings-color-input { background: none; border: none; width: 40px; height: 30px; cursor: pointer; padding: 0; }
.settings-modal .filter-config-pane { 
        background: #121214 !important; 
        max-height: 500px; /* Limits height to trigger scrollbar */
        overflow-y: auto !important; /* Enables vertical scrolling */
    }
    
    /* Ensure the list pane also scrolls if it gets too long */
    .filter-selection-pane.custom-scroll {
        overflow-y: auto;
    }    

        /* --- REDESFIGNED TACTICAL FLIGHT CARDS --- */
.route-card-reborn {
    position: relative;
    height: 115px;
    flex-shrink: 0; /* Add this line to prevent squeezing */
    border-radius: 12px;
    overflow: hidden;
    background-size: 101% 101%;
    background-position: center;
    margin-bottom: 12px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    cursor: pointer;
}

        .route-card-reborn:hover {
            transform: translateY(-2px) scale(1.01);
            border-color: rgba(255, 255, 255, 0.2);
            box-shadow: 0 12px 40px rgba(0,0,0,0.6);
        }

        .route-card-bg {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    z-index: 0;
    /* Slight zoom mirrors the old background-size: 101% so edges stay covered. */
    transform: scale(1.01);
}

        .card-overlay {
    position: absolute;
    inset: -2px; /* Slightly larger than the card */
    background: linear-gradient(180deg,
        rgba(24, 24, 27, 0.4) 0%,
        rgba(24, 24, 27, 0.8) 60%,
        rgba(24, 24, 27, 1) 100%
    );
    z-index: 1;
    /* This "spreads" the color slightly to fill gaps */
    box-shadow: inset 0 0 0 1px rgba(24, 24, 27, 1);
}

        .card-content {
            position: relative;
            z-index: 2;
            height: 100%;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
            padding: 14px 18px;
            box-sizing: border-box;
        }

        /* Header Zone: Metadata */
        .card-header-zone {
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .card-header-zone .callsign-meta {
            display: flex;
            align-items: center;
            font-family: 'JetBrains Mono', monospace;
            font-weight: 800;
            font-size: 0.9rem;
            color: #fff;
            letter-spacing: -0.5px;
        }

        .card-header-zone .aircraft-meta {
            font-size: 0.6rem;
            font-weight: 900;
            color: #71717a; /* Muted grey */
            text-transform: uppercase;
            letter-spacing: 1.5px;
            font-family: 'Inter', sans-serif;
        }

        /* Center Zone: High-Impact Route */
        .card-center-zone {
            display: flex;
            align-items: center;
            justify-content: center;
            flex-grow: 1;
            margin-top: -5px;
        }

        .route-display {
            display: flex;
            align-items: center;
            gap: 15px;
        }

        .icao-code {
            font-family: 'Inter', sans-serif;
            font-weight: 900;
            font-size: 2.6rem;
            color: rgba(255, 255, 255, 0.2); /* Muted origin */
            letter-spacing: -3px;
            line-height: 1;
        }

        .icao-code.destination-focus {
            color: #ffffff; /* Ultra-bold white focal point */
            text-shadow: 0 0 30px rgba(255,255,255,0.15);
        }

        .route-path-arrow {
            color: rgba(255, 255, 255, 0.1);
            font-size: 1.2rem;
        }

        /* Footer Zone: Details */
        .card-footer-zone {
            display: flex;
            justify-content: space-between;
            align-items: flex-end;
        }

        .operated-by-meta {
            font-size: 0.55rem;
            font-weight: 800;
            color: #52525b; /* Muted grey */
            text-transform: uppercase;
            letter-spacing: 1px;
            font-family: 'Inter', sans-serif;
        }

        .time-status-meta {
            font-size: 0.75rem;
            font-weight: 900;
            font-family: 'JetBrains Mono', monospace;
            color: #00ff41; /* Vibrant Neon Green */
            letter-spacing: 0.5px;
            text-shadow: 0 0 12px rgba(0, 255, 65, 0.4);
        }

        /* --- DYNAMIC & LOCKED AIRPORT TAG STYLES --- */
        :root {
            --apt-tag-scale: 1; 
        }

        .apt-live-tag, .destination-marker {
            display: flex;
            flex-direction: column-reverse;
            align-items: center;
            /* The --atc-tag-* custom properties are only set (inline, per
               marker) when the PRO custom tag designer is active — see
               applyAtcTagAppearance(). Stock look is the fallback. */
            background: var(--atc-tag-bg, rgba(10, 15, 25, 0.9)); /* Class 1 / Default */
            backdrop-filter: blur(8px);
            border: 1px solid var(--atc-tag-border, rgba(255, 255, 255, 0.2));
            border-radius: 6px;
            padding: 2px;
            cursor: pointer;
            pointer-events: auto;
            white-space: nowrap;
            transform: scale(var(--apt-tag-scale));
            transform-origin: bottom center;
            min-height: 22px; 
            box-sizing: border-box;
            user-select: none;
            box-shadow: 0 4px 12px rgba(0,0,0,0.5);
        }

        /* Class 2: Dark Green */
        .apt-class-2 {
            background: rgba(6, 78, 59, 0.9) !important;
            border-color: #10b981 !important;
        }

        /* Class 3: Dark Orange */
        .apt-class-3 {
            background: rgba(120, 53, 15, 0.9) !important;
            border-color: #f59e0b !important;
        }

        .destination-marker {
            padding: 2px 6px;
            font-family: 'JetBrains Mono', monospace;
            font-weight: 800;
            font-size: 11px;
            color: #fff;
        }

        .apt-live-tag .apt-tag-extra {
            max-height: 0;
            opacity: 0;
            overflow: hidden;
            width: 100%;
            display: flex;
            flex-direction: column;
            align-items: center;
            border-bottom: 0px solid rgba(255,255,255,0.1);
        }

        @media (hover: hover) {
            .apt-live-tag:hover {
                background: #0f172a;
                border-color: #38bdf8;
                z-index: 9999 !important;
                padding-bottom: 4px;
            }

            .apt-live-tag:hover .apt-tag-extra {
                max-height: 50px;
                opacity: 1;
                padding-bottom: 4px;
                margin-bottom: 4px;
                border-bottom-width: 1px;
            }

            /* Custom (PRO) tags keep their user-picked colors on hover
               instead of snapping to the stock navy/cyan. */
            .apt-live-tag.atc-tag-custom:hover {
                background: var(--atc-tag-bg, #0f172a);
                border-color: var(--atc-tag-border, #38bdf8);
            }
        }

        /* --- PRO: custom ATC tag appearance --- */
        /* 'Chip' style: just the ICAO letters on a colored square. */
        .apt-live-tag.atc-tag-chip {
            border-radius: 3px;
            padding: 3px 5px;
            min-height: 0;
        }
        .apt-live-tag.atc-tag-chip .apt-tag-extra { display: none; }

        /* 'Pill': rounded capsule. */
        .apt-live-tag.atc-tag-pill {
            border-radius: 999px;
            padding: 2px 7px;
        }

        /* 'Outline': hollow tag — border + letters carry the color. */
        .apt-live-tag.atc-tag-outline {
            background: transparent;
            backdrop-filter: none;
            border-width: 2px;
            box-shadow: none;
        }
        .apt-live-tag.atc-tag-outline .apt-tag-ident {
            text-shadow: 0 1px 3px rgba(0,0,0,0.9);
        }

        /* 'Neon': glowing border + letters, dark glassy core. */
        .apt-live-tag.atc-tag-neon {
            border-width: 1.5px;
            box-shadow:
                0 0 10px var(--atc-tag-border, #38bdf8),
                inset 0 0 6px rgba(255,255,255,0.06);
        }
        .apt-live-tag.atc-tag-neon .apt-tag-ident {
            text-shadow: 0 0 6px var(--atc-tag-text, #fff);
        }

        /* 'Glass': frosted, softly rounded, barely-there border. */
        .apt-live-tag.atc-tag-glass {
            border-radius: 10px;
            backdrop-filter: blur(14px) saturate(160%);
            border: 1px solid var(--atc-tag-border, rgba(255,255,255,0.35));
            box-shadow: 0 6px 18px rgba(0,0,0,0.35), inset 0 1px 0 rgba(255,255,255,0.25);
        }

        /* 'Flag': squared tag with a bold accent spine, like a strip board. */
        .apt-live-tag.atc-tag-flag {
            border-radius: 2px 8px 8px 2px;
            border-left: 4px solid var(--atc-tag-border, #38bdf8);
        }

        /* 'Mono': flat terminal block — square, no blur, no shadow. */
        .apt-live-tag.atc-tag-mono {
            border-radius: 0;
            backdrop-filter: none;
            box-shadow: none;
            padding: 3px 4px;
        }
        .apt-live-tag.atc-tag-mono .apt-tag-ident { letter-spacing: 1px; }

        .apt-live-tag.atc-tag-no-freqs .apt-tag-freqs { display: none; }
        .apt-live-tag.atc-tag-no-pulse .tag-pulse-aura { display: none; }

        .apt-simple-marker {
            cursor: pointer;
            pointer-events: auto;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: all 0.3s cubic-bezier(0.175, 0.885, 0.32, 1.275);
            background: rgba(15, 23, 42, 0.65);
            backdrop-filter: blur(4px);
            border: 1px solid rgba(255, 255, 255, 0.15);
            border-radius: 50%;
            width: 32px;
            height: 32px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.5);
            box-sizing: border-box;
        }
        .apt-simple-marker:hover {
            transform: scale(1.2) translateY(-2px);
            background: rgba(15, 23, 42, 0.95);
            border-color: #38bdf8;
            box-shadow: 0 8px 20px rgba(56, 189, 248, 0.4);
            z-index: 9999 !important;
        }

        .apt-tag-base {
            display: flex;
            align-items: center;
            width: 100%;
            height: 18px;
        }

        .apt-tag-ident {
            font-family: 'JetBrains Mono', monospace;
            font-weight: 800;
            font-size: 11px;
            color: var(--atc-tag-text, #fff);
            padding: 0 4px;
        }

        .apt-tag-freqs {
            display: flex;
            gap: 2px;
            margin-left: 2px;
            border-left: 1px solid rgba(255, 255, 255, 0.1);
            padding-left: 4px;
        }

        .freq-mini-badge {
            width: 14px;
            height: 14px;
            border-radius: 2px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: 'Inter', sans-serif;
            font-size: 8px;
            font-weight: 900;
            color: #fff;
        }

        .f-gnd { background: #475569; }
        .f-twr { background: #2563eb; }
        .f-app { background: #7c3aed; }
        .f-atis { background: #fbbf24; color: #000; }

        .tag-pulse-aura {
            position: absolute;
            inset: -1px;
            border-radius: 4px;
            border: 1px solid rgba(124, 58, 237, 0.6);
            pointer-events: none;
        }

        /* --- IMPORT FONTS --- */
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap');

        /* --- THEME VARIABLES --- */
        :root {
            --bg-glass: rgba(45, 45, 45, 0.9);
            --bg-panel: rgba(65, 65, 65, 0.5);
            --bg-subtle: rgba(255, 255, 255, 0.05);
            --border-glass: rgba(255, 255, 255, 0.1);
            --border-highlight: rgba(255, 255, 255, 0.15);
            --text-primary: #fafafa;
            --text-secondary: #a1a1aa;
            --text-dim: #94a3b8;
            --color-accent: #e4e4e7;
            --color-brand: #38bdf8;
            --color-success: #10b981;
            --color-warning: #f59e0b;
            --color-danger: #ef4444;
            --color-purple: #c084fc;
            --radius-sm: 8px;
            --radius-md: 12px;
            --radius-lg: 16px;
            --font-ui: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            --font-data: 'JetBrains Mono', 'Consolas', monospace;
            --iw-bg-start: rgba(45, 45, 45, 0.9);
            --iw-bg-end: rgba(45, 45, 45, 0.9);
        }

        /* --- [MODIFIED] MODAL STYLES --- */
        #sector-ops-floating-panel {
            /* Position Center */
            position: fixed !important;
            top: 50% !important;
            left: 50% !important;
            transform: translate(-50%, -50%) !important;
            
            /* Dimensions */
            width: 900px !important;
            max-width: 95vw !important;
            height: 85vh !important;
            max-height: 800px !important;
            
            /* Visual Style */
            background: var(--bg-glass) !important;
            backdrop-filter: blur(20px) !important;
            -webkit-backdrop-filter: blur(20px) !important;
            border: 1px solid var(--border-glass) !important;
            border-radius: var(--radius-lg) !important;
            box-shadow: 0 0 0 100vmax rgba(0, 0, 0, 0.6), 0 25px 50px rgba(0, 0, 0, 0.5) !important;
            
            /* [FIXED] HIDDEN BY DEFAULT */
            display: none; 
            flex-direction: column !important;
            z-index: 5000 !important;
            overflow: hidden !important;
            
            /* Reset Sidebar specific props */
            right: auto !important;
            bottom: auto !important;
            margin: 0 !important;
        }

        /* [NEW] Class to show the modal */
        #sector-ops-floating-panel.visible {
            display: flex !important;
            animation: modalFadeIn 0.3s ease-out forwards;
        }

        @keyframes modalFadeIn {
            from { opacity: 0; transform: translate(-50%, -48%) scale(0.96); }
            to { opacity: 1; transform: translate(-50%, -50%) scale(1); }
        }

        #sector-ops-floating-panel .panel-content {
            flex: 1;
            overflow-y: auto !important;
            height: auto !important;
            padding-bottom: 20px;
        }

        /* Close Button Styling */
        .panel-close-btn {
            position: absolute !important;
            top: 15px !important;
            right: 15px !important;
            z-index: 5010 !important;
            background: rgba(255, 255, 255, 0.1) !important;
            border: 1px solid rgba(255, 255, 255, 0.1) !important;
            color: #fff !important;
            width: 32px !important;
            height: 32px !important;
            border-radius: 50% !important;
            cursor: pointer !important;
            display: flex !important;
            align-items: center !important;
            justify-content: center !important;
            transition: all 0.2s ease !important;
        }
        .panel-close-btn:hover {
            background: var(--color-danger) !important;
            transform: rotate(90deg);
        }

        /* Mobile Adjustment */
        @media (max-width: 768px) {
            #sector-ops-floating-panel {
                width: 100% !important;
                height: 100% !important;
                max-width: 100% !important;
                max-height: 100% !important;
                border-radius: 0 !important;
                top: 0 !important;
                left: 0 !important;
                transform: none !important;
            }
        }

        /* --- ORIGINAL GLOBAL STYLES CONTINUED BELOW --- */
        body, .mapboxgl-popup {
            font-family: var(--font-ui);
            color: var(--text-primary);
        }

        /* --- TOOLBAR STYLES --- */

        .dashboard-toolbar {
    display: none !important;
}
        .toolbar-btn {
            background: var(--bg-glass) !important;
            border: 1px solid var(--border-glass) !important;
            color: var(--text-secondary) !important;
            backdrop-filter: blur(10px);
        }

        .toolbar-btn:hover, .toolbar-btn.active {
            background: var(--bg-panel) !important;
            color: var(--text-primary) !important;
            border-color: var(--text-secondary) !important;
        }

        /* --- INFO WINDOW STYLES --- */
        .info-window {
            font-family: var(--font-ui);
            color: var(--text-primary);
            position: absolute;
            top: 20px; 
            right: 20px;
            width: 460px;
            max-width: 95vw;
            max-height: calc(100vh - 40px);
            background: linear-gradient(135deg, var(--iw-bg-start), var(--iw-bg-end));
            backdrop-filter: blur(40px) saturate(140%);
            -webkit-backdrop-filter: blur(40px) saturate(140%);
            border-radius: var(--radius-lg);
            border: 1px solid var(--border-glass);
            box-shadow: 0 20px 50px rgba(0,0,0,0.8); 
            z-index: 2100; 
            display: flex;
            flex-direction: column;
            overflow: hidden;
            transition: opacity 0.55s cubic-bezier(0.16, 1, 0.3, 1),
                        transform 0.6s cubic-bezier(0.16, 1, 0.3, 1);
            transform-origin: top right;
            opacity: 0;
            transform: translateX(28px) translateY(10px) scale(0.96);
            pointer-events: none;
            will-change: opacity, transform;
        }
        .info-window.visible {
            opacity: 1;
            transform: translateX(0) translateY(0) scale(1);
            pointer-events: auto;
        }
        /* --- MOBILE SHEET GUARD --- */
        /* On phones the same windows are re-presented as a bottom sheet
           (sector-ops-mobile-ui.js adds .mobile-legacy-sheet). The desktop
           entrance above — fade + translate/scale anchored top-right — must
           never apply to the sheet: when these rules won the cascade, the
           sheet visibly dragged in from the top-right corner before settling
           at the bottom. While the sheet class is on, the window is always
           opaque and its only motion is vertical: parked below the bottom
           edge when hidden, slid up by the sheet's own state rules (which
           carry higher specificity) when visible. Kept identical to the
           sheet's base declarations so the duplicate guard is harmless
           whichever stylesheet loads last. */
        .info-window.mobile-legacy-sheet {
            opacity: 1;
            transform: translateY(100%);
            transform-origin: center bottom;
            transition: transform 0.45s cubic-bezier(0.16, 1, 0.3, 1);
            pointer-events: auto;
        }
        .info-window-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 16px 20px;
            background: var(--bg-panel);
            border-bottom: 1px solid var(--border-glass);
            flex-shrink: 0;
        }
        .info-window-header h3 {
            margin: 0;
            font-size: 1.1rem; 
            color: var(--text-primary);
            font-weight: 700;
            letter-spacing: -0.025em;
        }
        .info-window-actions button {
            background: var(--bg-subtle);
            border: 1px solid var(--border-glass);
            color: var(--text-secondary);
            cursor: pointer;
            font-size: 0.9rem;
            width: 28px; height: 28px;
            border-radius: 50%;
            margin-left: 8px;
            line-height: 1;
            display: grid;
            place-items: center;
            transition: all 0.2s ease-in-out;
        }
        .info-window-actions button:hover { 
            background: var(--bg-panel);
            color: #fff; 
            border-color: var(--text-secondary);
        }
        .info-window-content { 
            overflow-y: auto;
            flex-grow: 1; 
            padding: 0;
            background: transparent; 
        }

        /* --- VIRTUAL COCKPIT SEAT SENSOR --- */
        .seat-sensor-wrapper {
            background: var(--bg-glass);
            border: 1px solid var(--border-glass); 
            border-radius: var(--radius-sm); 
            display: flex;
            flex-direction: column;
            box-shadow: 0 4px 20px rgba(0,0,0,0.5);
            overflow: hidden;
            position: relative;
        }

        .sensor-header {
            background: var(--bg-panel);
            padding: 8px 12px;
            border-bottom: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            font-size: 0.75rem;
            font-weight: 700;
            color: var(--text-secondary);
            flex-shrink: 0;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        .sensor-body {
            padding: 15px;
            display: flex;
            flex-direction: column;
            align-items: center;
            position: relative;
            background: transparent;
        }

        .cockpit-view {
            position: relative;
            width: 140px;
            height: 80px;
            background: rgba(0,0,0,0.3);
            border-radius: 40px 40px 10px 10px;
            border: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            padding: 10px 20px;
            box-sizing: border-box;
            margin-bottom: 10px;
        }

        .cockpit-view::after {
            content: '';
            position: absolute;
            left: 50%;
            bottom: 10px;
            transform: translateX(-50%);
            width: 14px;
            height: 40px;
            background: #333;
            border-radius: 4px;
            border: 1px solid #555;
        }

        .seat {
            width: 35px;
            height: 40px;
            background: #222;
            border-radius: 6px;
            border: 1px solid #444;
            transition: all 0.5s ease;
            position: relative;
            display: flex;
            justify-content: center;
            align-items: center;
        }

        .seat::before {
            content: '';
            position: absolute;
            top: -8px;
            width: 25px;
            height: 8px;
            background: inherit;
            border-radius: 4px;
            border: 1px solid #444;
        }

        .cockpit-overlay-icon {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            font-size: 2.5rem;
            z-index: 10;
            opacity: 0;
            transition: opacity 0.3s ease, transform 0.3s ease;
            pointer-events: none;
            text-shadow: 0 2px 10px rgba(0,0,0,0.8);
        }

        .cockpit-overlay-icon.visible {
            opacity: 1;
            transform: translate(-50%, -50%) scale(1);
        }

        .icon-parking { color: var(--color-danger); border: 3px solid var(--color-danger);
            border-radius: 50%; width: 45px; height: 45px; display: flex; align-items: center; justify-content: center; font-weight: bold; background: rgba(0,0,0,0.6); font-family: sans-serif;
        }
        .icon-coffee { color: var(--color-warning);
        }
        .icon-cloud { color: var(--color-brand);
        }

        .seat.active-green { background: rgba(16, 185, 129, 0.1); border-color: var(--color-success);
            box-shadow: 0 0 15px rgba(16, 185, 129, 0.2); }
        .seat.active-green::before { border-color: var(--color-success);
            background: #064e3b; }

        .seat.active-amber { background: rgba(245, 158, 11, 0.1); border-color: var(--color-warning);
            box-shadow: 0 0 15px rgba(245, 158, 11, 0.2); }
        .seat.active-amber::before { border-color: var(--color-warning);
            background: #78350f; }

        .seat.active-blue { background: rgba(56, 189, 248, 0.1); border-color: var(--color-brand);
            box-shadow: 0 0 15px rgba(56, 189, 248, 0.2); }
        .seat.active-blue::before { border-color: var(--color-brand);
            background: #0c4a6e; }

        .seat::after { content: attr(data-role); font-size: 0.6rem; font-weight: bold; color: var(--text-dim);
            margin-top: 2px; }
        .seat.active-green::after, .seat.active-amber::after, .seat.active-blue::after { color: #fff;
            text-shadow: 0 0 5px currentColor; }

        .seat-status-display {
            margin-top: 8px;
            font-family: var(--font-data);
            font-size: 0.75rem;
            text-align: center;
            width: 100%;
            display: flex;
            justify-content: space-between;
            color: var(--text-secondary);
        }

        .status-pill { padding: 2px 8px; border-radius: 4px; background: rgba(255,255,255,0.05);
            border: 1px solid var(--border-glass); }
        .status-pill.green { color: var(--color-success);
            border-color: rgba(16, 185, 129, 0.3); background: rgba(16, 185, 129, 0.1);
        }
        .status-pill.amber { color: var(--color-warning); border-color: rgba(245, 158, 11, 0.3);
            background: rgba(245, 158, 11, 0.1); }
        .status-pill.blue { color: var(--color-brand);
            border-color: rgba(56, 189, 248, 0.3); background: rgba(56, 189, 248, 0.1);
        }
        .status-pill.red { color: var(--color-danger); border-color: rgba(239, 68, 68, 0.3);
            background: rgba(239, 68, 68, 0.1); }

        #seat-narrative-text {
            font-family: var(--font-ui);
            font-size: 0.7rem;
            color: var(--text-secondary);
            margin-top: 8px;
            text-align: center;
            border-top: 1px solid var(--border-glass);
            padding-top: 6px;
            width: 100%;
            font-style: italic;
        }
        
        #view-rosters.active {
            position: absolute;
            inset: 0;
            width: 100%;
            height: 100%;
            padding: 0;
            overflow: hidden;
            display: grid;
            grid-template-columns: 1fr;
            grid-template-rows: 1fr;
        }
        #sector-ops-map-fullscreen {
            grid-column: 1 / -1;
            grid-row: 1 / -1;
        }
        .main-content:has(#view-rosters.active) {
            padding: 0;
            height: 100dvh; 
            overflow: hidden; 
        }

        .pfd-and-location-grid { 
    display: grid;
    grid-template-columns: 1fr 150px; /* Fixed width for right column  */
    gap: 6px;
    align-items: stretch; /* Forces children to match height of the tallest item (PFD) */
}

        .info-right-col {
    display: flex;
    flex-direction: column;
    gap: 6px; /* Reduced gap to keep it within PFD bounds  */
    height: 100%; /* Stretch to fill the grid cell */
    overflow: hidden; /* Prevents accidental overflow */
}
        
        /* --- FMS & MODULE STYLES --- */
        .fms-module-container {
            height: 380px;
            max-height: 380px;
            background: var(--bg-glass);
            color: var(--color-success); 
            font-family: var(--font-data);
            display: flex;
            flex-direction: column;
            border: 1px solid var(--border-glass);
            border-radius: var(--radius-sm);
            box-shadow: inset 0 0 20px rgba(0,0,0,0.5);
            box-sizing: border-box;
            overflow: hidden;
        }
        .fms-header {
            background: var(--bg-panel);
            padding: 6px 10px;
            border-bottom: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            font-size: 0.75rem;
            font-weight: 700;
            color: var(--text-primary);
            flex-shrink: 0;
        }
        .fms-columns {
            display: grid;
            grid-template-columns: 2fr 1fr 1fr;
            padding: 4px 10px;
            border-bottom: 1px dashed var(--border-glass);
            font-size: 0.7rem;
            color: var(--color-brand);
            flex-shrink: 0;
        }
        .fms-list-scrollarea {
            flex-grow: 1;
            overflow-y: auto;
            padding: 5px 0;
            scrollbar-width: thin;
            scrollbar-color: var(--border-glass) transparent;
        }
        .fms-list-scrollarea::-webkit-scrollbar { width: 4px;
        }
        .fms-list-scrollarea::-webkit-scrollbar-track { background: transparent;
        }
        .fms-list-scrollarea::-webkit-scrollbar-thumb { background-color: var(--border-glass); border-radius: 2px;
        }
        
        .fms-row {
            display: grid;
            grid-template-columns: 2fr 1fr 1fr;
            padding: 4px 10px;
            font-size: 0.85rem;
            border-bottom: 1px solid rgba(255,255,255,0.03);
            align-items: center;
        }
        .fms-row.active-leg {
            background: rgba(192, 132, 252, 0.1);
            color: var(--color-purple);
            font-weight: bold;
        }
        .fms-row.passed-leg { color: var(--text-dim);
        }
        .fms-proc-header {
            padding: 4px 10px;
            background: rgba(255,255,255,0.02);
            color: var(--text-secondary);
            font-size: 0.75rem;
            font-weight: bold;
            border-top: 1px solid var(--border-glass);
            border-bottom: 1px solid var(--border-glass);
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .proc-tag {
            font-size: 0.6rem;
            padding: 1px 4px;
            border-radius: 2px;
            background: rgba(255,255,255,0.05);
            color: var(--text-secondary);
        }
        .proc-tag.sid { background: rgba(16, 185, 129, 0.1);
            color: var(--color-success); }
        .proc-tag.star { background: rgba(245, 158, 11, 0.1); color: var(--color-warning);
        }
        .fms-row.is-child { padding-left: 20px;
        }
        .fms-footer {
            background: var(--bg-panel);
            padding: 6px 10px;
            border-top: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            flex-shrink: 0;
        }
        .fms-stat { display: flex; gap: 8px; font-size: 0.8rem;
        }
        .stat-label { color: var(--text-dim);
        }
        .stat-value { color: var(--text-primary); font-weight: bold;
        }
        .fms-empty-state { text-align: center; padding: 20px; color: var(--text-dim); font-style: italic;
        }

        /* --- LOCATION DATA PANEL --- */
        #location-data-panel {
            background: var(--bg-glass);
            border-radius: var(--radius-sm);
            border: 1px solid var(--border-glass);
            box-shadow: none;
            width: 100%;
            display: flex;
            flex-direction: column;
            overflow: visible;
        }
        .nav-header {
            background: var(--bg-panel);
            padding: 8px 12px;
            border-bottom: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .nav-title { 
            font-size: 0.7rem;
            font-weight: 700; 
            color: var(--text-dim); 
            letter-spacing: 1px; 
            font-family: var(--font-ui);
        }
        .nav-status-indicator {
            display: flex;
            align-items: center; gap: 6px;
            font-size: 0.65rem; font-weight: 700; letter-spacing: 0.5px;
            color: var(--color-success); text-transform: uppercase;
        }
        .nav-blink {
            width: 6px;
            height: 6px; border-radius: 50%; background: var(--color-success);
            box-shadow: 0 0 6px var(--color-success);
            animation: navPulse 2s infinite;
        }
        @keyframes navPulse { 0% { opacity: 1; } 50% { opacity: 0.4;
        } 100% { opacity: 1; } }
        
        .nav-grid-container {
            padding: 10px;
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 8px;
        }
        .nav-cell {
            background: var(--bg-panel);
            border-radius: 4px;
            padding: 6px 10px;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
            height: auto; 
            min-height: 45px;
            border: 1px solid var(--border-glass);
            transition: background 0.2s;
            overflow: visible;
        }
        .nav-cell:hover {
            background: rgba(255, 255, 255, 0.06);
            border-color: var(--border-highlight);
        }
        .nav-span-2 { grid-column: span 2;
        }
        .nav-span-4 { grid-column: span 4;
        }
        .nav-label {
            font-size: 0.6rem;
            color: var(--color-brand);
            text-transform: uppercase;
            margin-bottom: 4px;
            font-weight: 600;
            letter-spacing: 0.5px;
            display: flex;
            align-items: center;
            gap: 6px;
            white-space: nowrap;
        }
        .nav-label i { opacity: 0.7; font-size: 0.7rem;
        }
        
        .nav-value {
            font-family: var(--font-data);
            font-size: 1.0rem; 
            color: var(--text-primary);
            font-weight: 600;
            white-space: normal;  
            overflow: visible;    
            text-overflow: clip;  
            word-wrap: break-word; 
            line-height: 1.2;
        }
        
        .nav-value.large { font-size: 1.2rem;
        }
        .nav-value.small { font-size: 0.85rem; color: var(--text-secondary);
        }
        .nav-value.highlight { color: var(--color-success); text-shadow: 0 0 5px rgba(16, 185, 129, 0.2);
        }
        .nav-value.accent { color: var(--color-warning);
        }
        
        .nav-row {
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            width: 100%;
            flex-wrap: wrap; 
            gap: 4px;
        }
        
        .nav-unit {
            font-size: 0.7rem;
            color: var(--text-dim);
            margin-left: 2px;
            font-family: var(--font-ui);
            font-weight: 400;
            white-space: nowrap;
        }

        @media (max-width: 992px) {
            .info-window { width: 95vw;
                top: 10px; right: 2.5vw; left: 2.5vw; max-height: calc(100vh - 20px);
            }
            .pfd-and-location-grid { grid-template-columns: 1fr;
            } 
            #fms-legs-module { display: none;
            }
            #location-data-panel { min-height: auto;
            }
            .nav-grid-container { grid-template-columns: repeat(2, 1fr);
            }
            .nav-span-2 { grid-column: span 2;
            }
        }
        
        .aircraft-overview-panel {
            position: relative;
            height: 200px;
            background-size: contain;
            background-repeat: no-repeat;
            background-position: center;
            background-color: #0b1220;
            border-bottom-left-radius: 0;
            border-bottom-right-radius: 0;
            color: #fff;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
            margin-bottom: 0px;
        }
        
        .aircraft-overview-panel::before { 
            content: '';
            position: absolute; 
            inset: 0; 
            z-index: 1; 
            background: linear-gradient(
                to bottom,
                rgba(0, 0, 0, 0.7) 0%, 
                rgba(0, 0, 0, 0) 35%, 
                rgba(0, 0, 0, 0.2) 80%, 
                var(--bg-glass) 100% /* Matches your window background */
            );
        }
        
        .overview-content { position: relative;
            z-index: 2; padding: 16px 20px 0 20px; display: flex; justify-content: space-between; align-items: flex-start;
        }
        .overview-col-left h3 { margin: 0; font-size: 1.6rem; font-weight: 700;
            text-shadow: 0 4px 10px rgba(0, 0, 0, 0.7); display: flex; align-items: center; gap: 12px;
        }
        .ac-header-logo { height: 1.8rem; width: auto; max-width: 100px; object-fit: contain;
            filter: drop-shadow(0 2px 4px rgba(0,0,0,0.7)); }
        .overview-col-left p { position: relative; margin: 0;
            font-size: 1.0rem; color: #e8eaf6; font-weight: 400; text-shadow: 0 2px 5px rgba(0, 0, 0, 0.6); min-height: 1.2em; margin-top: 4px;
        }
        
        .ac-header-subtext { 
            position: absolute;
            top: 0; 
            left: 0; 
            width: 100%; 
            opacity: 0; 
            white-space: normal;
        }
        
        @keyframes primarySubtextAnimation { 0% { opacity: 1;
            transform: translateY(0); } 40% { opacity: 1; transform: translateY(0); } 50% { opacity: 0; transform: translateY(10px);
            } 51% { opacity: 0; transform: translateY(-10px); } 90% { opacity: 0; transform: translateY(-10px); } 100% { opacity: 1;
            transform: translateY(0); } }
        @keyframes secondarySubtextAnimation { 0% { opacity: 0; transform: translateY(-10px);
            } 40% { opacity: 0; transform: translateY(-10px); } 50% { opacity: 1; transform: translateY(0); } 90% { opacity: 1;
            transform: translateY(0); } 100% { opacity: 0; transform: translateY(10px); } }
        #ac-header-livery { animation: primarySubtextAnimation 8s infinite ease-in-out;
        }
        #ac-header-actype { animation: secondarySubtextAnimation 8s infinite ease-in-out;
        }
        .overview-actions { position: absolute; top: 16px; right: 16px; z-index: 3; display: flex;
            gap: 8px; }
        
        .route-summary-overlay { 
            position: relative;
            padding: 15px 20px 12px 20px; 
            background: linear-gradient(180deg, 
                transparent 0%, 
                rgba(0, 0, 0, 0.2) 40%, 
                rgba(24, 24, 27, 1) 100%
            );
            display: grid; 
            grid-template-columns: auto 1fr auto; 
            align-items: center; 
            gap: 16px; 
            width: 100%;
        }
        
        .route-summary-airport { display: flex;
            flex-direction: column; }
        #route-summary-dep { text-align: left; align-items: center;
        }
        #route-summary-arr { text-align: right; align-items: center;
        }
        .route-summary-airport .airport-line { display: flex; align-items: center; gap: 8px;
        }
        .route-summary-airport .icao { font-family: var(--font-data); font-size: 1.2rem; font-weight: 700; color: #fff;
            text-shadow: 0 1px 3px rgba(0,0,0,0.5); }
        .route-summary-airport .time { font-size: 0.85rem; font-weight: 600;
            color: var(--text-secondary); margin-top: 4px; text-align: center; }
        .country-flag { width: 20px; height: auto;
            border-radius: 3px; border: 1px solid rgba(255, 255, 255, 0.2); display: none;
        }
        .route-progress-container { display: grid; grid-template-columns: 1fr; grid-template-rows: 1fr; align-items: center; justify-items: center;
            position: relative; min-height: 28px; }
        .route-progress-bar-container { width: 100%; height: 6px; background: var(--bg-panel);
            border-radius: 3px; overflow: hidden; grid-row: 1; grid-column: 1; z-index: 1;
        }
        .progress-bar-fill { height: 100%; width: 0%; background: var(--color-brand); transition: none;
            border-radius: 3px; }
        .flight-phase-indicator { padding: 4px 12px; border-radius: 20px; font-size: 0.75rem;
            font-weight: 700; color: #fff; border: 1px solid var(--border-glass); grid-row: 1; grid-column: 1; z-index: 2;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.5); }
        .phase-climb { background: var(--color-success);
            opacity: 0.9; } .phase-cruise { background: var(--color-brand); opacity: 0.9; } .phase-descent { background: var(--color-warning); opacity: 0.9;
        } .phase-approach { background: var(--color-purple); opacity: 0.9; } .phase-enroute { background: var(--text-dim); opacity: 0.9;
        }

        /* Complete Window Scrolling Overrides */
        #aircraft-info-window {
            overflow-y: auto !important;
            overflow-x: hidden !important;
            display: block !important; 
        }

        /* Disable all internal scrollbars so the parent takes over */
        #aircraft-info-window .unified-display-main-content,
        #aircraft-info-window .info-window-content {
            overflow-y: visible !important;
            height: auto !important;
            flex: none !important;
        }
        
        .unified-display-main-content { 
            padding: 10px;
            flex-grow: 1; 
            display: flex; 
            flex-direction: column; 
            gap: 10px; 
            background: linear-gradient(180deg, var(--bg-glass), var(--bg-glass));
            border-top: 1px solid var(--border-glass);
            overflow-y: auto;
        }

        .ac-tab-pane { display: none; flex-direction: column; gap: 16px; animation: fadeIn 0.4s;
        }
        .ac-tab-pane.active { display: flex;
        }
        
        .pfd-main-panel { 
            display: flex;
            flex-direction: column; 
            width: 100%; 
            align-items: center; 
            gap: 16px; 
        }

        .display-bezel { 
            position: relative;
            background-color: #1f2937; 
            border: 4px solid #374151; 
            padding: 12px; 
            border-radius: var(--radius-md); 
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
            width: 100%; 
            box-sizing: border-box; 
            display: flex;
            flex-direction: column;
        }
        
        .screw { 
            position: absolute;
            width: 0.5rem; 
            height: 0.5rem; 
            background-color: #4b5563; 
            border-radius: 50%; 
            box-shadow: inset 1px 1px 2px rgba(0,0,0,0.5); 
            z-index: 5;
        }
        .screw.tl { top: 0.35rem; left: 0.35rem;
        } 
        .screw.tr { top: 0.35rem; right: 0.35rem;
        } 
        .screw.bl { bottom: 0.35rem; left: 0.35rem;
        } 
        .screw.br { bottom: 0.35rem; right: 0.35rem;
        }
        
        .crt-container { 
            width: 100%;
            position: relative; 
            border: 2px solid #111827; 
            background: #000; 
            border-radius: 12px; 
            overflow: hidden; 
            box-shadow: inset 0 0 20px rgba(0,0,0,0.8); 
            display: flex;
        }
        
        .scanlines::before { 
            content: " ";
            display: block; 
            position: absolute; 
            top: 0; left: 0; bottom: 0; right: 0;
            background: linear-gradient(rgba(18, 16, 16, 0) 50%, rgba(0, 0, 0, 0.25) 50%), 
                        linear-gradient(90deg, rgba(255, 0, 0, 0.06), rgba(0, 255, 0, 0.02), rgba(0, 0, 255, 0.06));
            z-index: 10; 
            background-size: 100% 2px, 3px 100%; 
            pointer-events: none; 
        }
        
        #pfd-container { width: 100%;
        }
        
        #pfd-container svg { 
            width: 100%;
            height: auto; 
            display: block;
            margin: 0; 
            max-width: none; 
            aspect-ratio: 787 / 800; 
            background-color: #1a1a1a; 
            overflow: hidden; 
            border-radius: 0;
            filter: brightness(1.3) contrast(1.2) drop-shadow(0 0 2px rgba(255, 255, 255, 0.3));
        }
        
        #nd-container { 
            width: 100%;
            aspect-ratio: 787 / 800; 
            background: transparent; 
            overflow: hidden; 
            display: flex; 
            justify-content: center; 
            height: auto;
        }
        
        #nav-display-frame {
            width: 100%;
            height: 100%; 
            border: none;
            display: block;
        }

        .rules-module-container {
            background: var(--bg-glass);
            border: 1px solid var(--border-glass);
            border-radius: var(--radius-sm);
            display: flex;
            flex-direction: column;
            box-shadow: inset 0 0 20px rgba(0,0,0,0.8);
            overflow: hidden;
        }

        .rules-header {
            background: var(--bg-panel);
            padding: 6px 10px;
            border-bottom: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            font-size: 0.8rem;
            font-weight: bold;
            color: var(--text-primary);
            font-family: var(--font-data);
        }

        .rules-body {
            padding: 12px;
            display: flex;
            justify-content: center;
            align-items: center;
            background: transparent; 
        }

        .flight-rules-badge {
            padding: 6px 16px;
            border-radius: 4px;
            font-family: var(--font-data);
            font-weight: bold;
            font-size: 1.1rem;
            text-align: center;
            width: 100%;
            border: 1px solid rgba(255,255,255,0.1);
            box-shadow: 0 4px 15px rgba(0,0,0,0.5);
            text-shadow: 0 1px 2px rgba(0,0,0,0.8);
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
        }

        .badge-ifr {
            background: linear-gradient(180deg, rgba(0, 119, 255, 0.2) 0%, rgba(0, 60, 130, 0.4) 100%);
            color: var(--color-brand);
            border-color: var(--color-brand);
        }

        .badge-vfr {
            background: linear-gradient(180deg, rgba(40, 167, 69, 0.2) 0%, rgba(20, 80, 35, 0.4) 100%);
            color: var(--color-success);
            border-color: var(--color-success);
        }

        .badge-svfr {
            background: linear-gradient(180deg, rgba(255, 193, 7, 0.2) 0%, rgba(130, 100, 5, 0.4) 100%);
            color: var(--color-warning);
            border-color: var(--color-warning);
        }
        
        .vsd-module-container {
            height: 260px;
            max-height: 260px;
            background: var(--bg-glass);
            border: 1px solid var(--border-glass);
            border-radius: var(--radius-sm);
            display: flex;
            flex-direction: column;
            box-shadow: inset 0 0 20px rgba(0,0,0,0.8);
            box-sizing: border-box;
            overflow: hidden;
            margin-bottom: 16px; 
        }

        .vsd-panel { 
            display: flex;
            flex-direction: column; 
            background: transparent; 
            flex-grow: 1;
            position: relative;
            overflow: hidden; 
            width: 100%;
        }

        .vsd-graph-window { 
            position: relative;
            width: 100%; 
            height: 100%; 
            overflow: hidden; 
            padding-left: 35px; 
            box-sizing: border-box;
        }

        #vsd-y-axis {
            position: absolute;
            top: 0;
            left: 0;
            width: 35px;
            height: 100%;
            background: var(--bg-panel);
            border-right: 1px solid var(--border-glass);
            z-index: 10;
        }
        .y-axis-label {
            position: absolute;
            right: 4px;
            font-family: var(--font-data);
            font-size: 0.65rem;
            color: var(--text-dim);
            transform: translateY(-50%);
        }

        #vsd-graph-content {
            position: relative;
            height: 100%;
        }

        #vsd-profile-svg {
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            overflow: visible;
        }

        #vsd-profile-path {
            fill: none;
            stroke: #444; 
            stroke-width: 2;
            stroke-dasharray: 4, 2;
        }

        #vsd-flown-path {
            fill: none;
            stroke: var(--color-success); 
            stroke-width: 3;
            filter: drop-shadow(0 0 4px rgba(0, 230, 0, 0.5));
        }

        #vsd-aircraft-icon {
            position: absolute;
            width: 14px;
            height: 14px;
            background-image: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><path fill="%2338bdf8" d="M488 256l-112-80v-96l-80 48-80-48v96L104 256 24 288v64l192-48v96l-32 32v32l72-24 72 24v-32l-32-32v-96l192 48v-64l-80-32z"/></svg>');
            background-size: contain;
            background-repeat: no-repeat;
            transform: translate(-50%, -50%);
            z-index: 20;
        }

        .vsd-wp-label {
            position: absolute;
            transform: translateX(-50%);
            font-family: var(--font-data);
            text-align: center;
            width: 60px;
            pointer-events: none;
        }
        .vsd-wp-label .wp-name {
            display: block;
            font-size: 0.7rem;
            color: var(--color-brand);
            font-weight: bold;
            background: rgba(0,0,0,0.7);
            padding: 1px 3px;
            border-radius: 2px;
        }
        .vsd-wp-label .wp-alt {
            display: block;
            font-size: 0.6rem;
            color: var(--text-secondary);
            margin-top: 1px;
        }
        
        .vsd-footer {
            background: var(--bg-panel);
            padding: 4px 10px;
            border-top: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 0.7rem;
            color: var(--text-dim);
            flex-shrink: 0;
        }
        .vsd-legend-item { display: flex; align-items: center; gap: 5px;
        }
        .dot-plan { width: 6px; height: 6px; background: #444; border-radius: 50%;
        }
        .dot-flown { width: 6px; height: 6px; background: var(--color-success); border-radius: 50%;
            box-shadow: 0 0 4px var(--color-success); }
        
        .ac-info-window-tabs {
            display: flex;
            justify-content: space-between;
            align-items: center;
            background: #3a3a3a;
            border-top: 1px solid rgba(255,255,255,0.04);
            border-bottom: 1px solid rgba(0,0,0,0.24);
            padding: 0 20px;
            height: 60px;
        }

        .ac-tabs-wrapper {
            display: flex;
            gap: 20px;
            height: 100%;
        }

        .ac-info-tab-logo {
            height: 32px;
            width: auto;
            object-fit: contain;
            opacity: 0.8;
        }

        .ac-info-tab-btn {
            padding: 0 10px;
            height: 100%;
            border: none;
            background: transparent;
            color: var(--text-secondary);
            cursor: pointer;
            font-size: 0.95rem;
            font-family: var(--font-ui);
            font-weight: 600;
            position: relative;
            display: flex;
            align-items: center;
            gap: 10px;
            transition: all 0.3s ease;
            border-bottom: 3px solid transparent;
        }

        .ac-info-tab-btn:hover {
            color: #fff;
        }

        .ac-info-tab-btn.active {
            color: #fff;
            border-bottom-color: var(--color-brand);
            text-shadow: 0 0 10px rgba(56, 189, 248, 0.5);
        }
        .ac-info-tab-btn.active i {
            color: var(--color-brand);
        }

        .ac-info-tab-btn.pilot-tab-btn {
            color: var(--text-primary);
            font-weight: 700;
            letter-spacing: 0.5px;
        }
        .ac-info-tab-btn.pilot-tab-btn i {
            color: var(--color-warning);
        }
        .ac-info-tab-btn.pilot-tab-btn.active {
            color: #fff;
            border-bottom-color: var(--color-warning); 
            text-shadow: 0 0 10px rgba(255, 183, 77, 0.5);
        }

        @media (max-width: 768px) {
            .ac-info-tab-logo {
                display: none !important;
            }
            .ac-info-window-tabs {
                justify-content: center;
                padding: 0 10px;
            }
            .ac-tabs-wrapper {
                width: 100%;
                justify-content: space-around;
                gap: 0;
            }
        }

        .vsd-disclaimer { background: rgba(10, 12, 26, 0.5);
            border: 1px solid var(--border-glass); border-radius: var(--radius-sm); padding: 10px 14px; margin-top: 0;
        }

        /* --- MAPBOX POPUP OVERRIDES (FIXED) --- */
        .mapboxgl-popup-content {
            background: transparent !important;
            box-shadow: none !important;
            padding: 0 !important;
            border: none !important;
            pointer-events: none !important;
        }
        .mapboxgl-popup-tip {
            display: none !important;
        }
        
        /* --- FR24 STYLE CARD CONTAINER (MICRO) --- */
        .fr24-card-container {
            width: 160px;
            display: flex;
            flex-direction: column;
            gap: 3px;
            font-family: var(--font-ui);
            pointer-events: none;
        }

        /* --- TOP IMAGE BUBBLE --- */
        .fr24-image-box {
            height: 85px;
            width: 100%;
            background-color: #2c2c2e;
            background-size: cover;
            background-position: center;
            border-radius: var(--radius-sm);
            position: relative;
            box-shadow: 0 2px 8px rgba(0,0,0,0.4);
            overflow: hidden;
        }
        
        .fr24-copyright {
            position: absolute;
            bottom: 3px;
            left: 6px;
            color: rgba(255, 255, 255, 0.7);
            font-size: 7px;
            font-weight: 500;
            text-shadow: 0 1px 2px rgba(0,0,0,1);
            z-index: 2;
        }
        
        .fr24-image-overlay {
            position: absolute;
            inset: 0;
            background: linear-gradient(to top, rgba(0,0,0,0.6) 0%, transparent 40%);
        }

        /* --- BOTTOM INFO BUBBLE --- */
        .fr24-info-box {
            background-color: #2c2c2e;
            border-radius: var(--radius-sm);
            padding: 6px 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.4);
            display: flex;
            flex-direction: column;
            gap: 4px;
            color: #ffffff;
        }

        .fr24-header-row {
            display: flex;
            align-items: center;
            gap: 6px;
        }

        .fr24-airline-logo {
            height: 14px;
            width: auto;
            max-width: 35px;
            object-fit: contain;
            border-radius: 1px;
        }

        .fr24-ident-group {
            display: flex;
            align-items: center;
            gap: 4px;
        }

        .fr24-callsign {
            font-size: 13px;
            font-weight: 700;
            color: #fff;
            line-height: 1;
        }

        .fr24-ac-badge {
            background-color: #3a3a3c;
            border: 1px solid #48484a;
            color: #d1d1d6;
            font-size: 8px;
            font-weight: 600;
            padding: 0px 3px;
            border-radius: 3px;
            line-height: 1.1;
        }

        .fr24-route {
            font-size: 10px;
            font-weight: 500;
            color: #d1d1d6;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            max-width: 100px;
        }

        .fr24-progress-track {
            height: 3px;
            width: 100%;
            background-color: #3a3a3c;
            border-radius: 1.5px;
            overflow: hidden;
            margin-top: 1px;
        }

        .fr24-progress-fill {
            height: 100%;
            background-color: var(--color-danger);
            border-radius: 1.5px;
        }

        .fr24-stats-row {
            font-size: 10px;
            color: #98989d;
            font-weight: 600;
            margin-top: 1px;
        }

        .mapboxgl-popup {
    z-index: 3000 !important; 
    pointer-events: none; /* Prevents the popup from blocking clicks to aircraft behind it */
}

.mapboxgl-popup-content {
    background: transparent !important;
    box-shadow: none !important;
    padding: 0 !important;
    border: none !important;
    pointer-events: none !important;
}

        /* --- AIRPORT WINDOW SPECIFIC STYLES --- */

        .airport-hero {
    /* Set the background size and position */
    background-size: 101% 101%;
    background-position: center;
    min-height: 160px; /* Increased height to better showcase the airport image */
    border-bottom: 1px solid var(--border-glass);
    padding: 20px;
    display: flex;
    justify-content: space-between;
    align-items: flex-end; /* Align data to the bottom of the image */
    position: relative;
    overflow: hidden;
}

/* Add this new overlay class */
.airport-hero-overlay {
    position: absolute;
    inset: -1px;
    /* Dark gradient to make white text pop — neutral zinc, matching the
       app's gray base instead of the old navy tint */
    background: linear-gradient(180deg,
        rgba(24, 24, 27, 0.15) 0%,
        rgba(24, 24, 27, 0.5) 50%,
        rgba(24, 24, 27, 0.94) 100%
    );
    z-index: 1;
}

/* Ensure the ident group stays above the overlay */
.apt-ident-group {
    display: flex;
    flex-direction: column;
    z-index: 2; /* Sits above the overlay */
}

        .apt-icao {
            font-family: var(--font-data);
            font-size: 2.5rem;
            font-weight: 800;
            color: #fff;
            line-height: 1;
            text-shadow: 0 4px 10px rgba(0,0,0,0.5);
            display: flex;
            align-items: center;
            gap: 12px;
        }

        .apt-name {
            font-size: 0.9rem;
            color: #d4d4d8;
            margin-top: 6px;
            font-weight: 500;
            text-shadow: 0 1px 3px rgba(0,0,0,0.7);
        }

        .apt-meta-badge {
            background: rgba(255,255,255,0.05);
            border: 1px solid var(--border-glass);
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.75rem;
            color: #cbd5e1;
            display: flex;
            align-items: center;
            gap: 6px;
        }

        /* --- AIRPORT AT-A-GLANCE STATS BAR --- */
        .apt-stats-bar {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            background: rgba(24, 24, 27, 0.55);
            border-bottom: 1px solid var(--border-glass);
        }

        .apt-stat-cell {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 3px;
            padding: 10px 6px;
            border-right: 1px solid rgba(255, 255, 255, 0.06);
        }
        .apt-stat-cell:last-child { border-right: none; }

        .apt-stat-value {
            font-family: var(--font-data);
            font-size: 1.05rem;
            font-weight: 700;
            color: var(--text-primary);
            line-height: 1;
        }

        .apt-stat-label {
            font-size: 0.58rem;
            font-weight: 800;
            letter-spacing: 1px;
            color: #a1a1aa;
            text-transform: uppercase;
        }

        /* --- AIRPORT INFO TAB: DETAIL GRID & RUNWAYS --- */
        .apt-section-title {
            font-size: 0.7rem;
            color: #a1a1aa;
            font-weight: 800;
            letter-spacing: 1px;
            text-transform: uppercase;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .apt-detail-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
        }

        .apt-detail-row {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.06);
            border-radius: 8px;
            padding: 8px 10px;
            min-width: 0;
        }

        .apt-detail-label {
            display: block;
            font-size: 0.6rem;
            color: #a1a1aa;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 3px;
        }

        .apt-detail-value {
            font-family: var(--font-data);
            font-size: 0.82rem;
            color: var(--text-primary);
            font-weight: 600;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .apt-runway-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
        }

        @media (max-width: 480px) {
            .apt-runway-grid { grid-template-columns: 1fr; }
        }

        .apt-runway-card {
            background: rgba(24, 24, 27, 0.6);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 8px;
            padding: 10px 12px;
            display: flex;
            flex-direction: column;
            gap: 6px;
        }

        .apt-runway-ident {
            font-family: var(--font-data);
            font-weight: 800;
            font-size: 0.95rem;
            color: var(--text-primary);
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 8px;
        }

        .apt-rwy-tag {
            font-size: 0.55rem;
            font-weight: 800;
            letter-spacing: 0.5px;
            padding: 2px 6px;
            border-radius: 4px;
            background: rgba(255, 255, 255, 0.06);
            border: 1px solid rgba(255, 255, 255, 0.12);
            color: #d4d4d8;
        }
        .apt-rwy-tag.lit { color: #fbbf24; border-color: rgba(251, 191, 36, 0.35); background: rgba(251, 191, 36, 0.08); }

        .apt-runway-meta {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            font-size: 0.65rem;
            color: #a1a1aa;
            font-weight: 600;
        }
        .apt-runway-meta i { margin-right: 4px; opacity: 0.7; }

        /* --- AIRPORT WINDOW SKELETON (loading state) --- */
        @keyframes aptShimmer {
            0% { background-position: -200% 0; }
            100% { background-position: 200% 0; }
        }

        .apt-skel-block {
            border-radius: 6px;
            background: linear-gradient(90deg,
                rgba(255, 255, 255, 0.05) 25%,
                rgba(255, 255, 255, 0.11) 50%,
                rgba(255, 255, 255, 0.05) 75%);
            background-size: 200% 100%;
            animation: aptShimmer 1.4s ease-in-out infinite;
        }

        .apt-skel-hero {
            background: #1c1c1f;
            min-height: 160px;
        }

        .apt-skeleton .apt-stats-bar .apt-skel-block { width: 60%; height: 14px; margin: 2px auto; }

        /* Content entrance: when real data replaces the skeleton, the major
           sections rise in with a slight stagger instead of popping. */
        @keyframes aptContentIn {
            from { opacity: 0; transform: translateY(8px); }
            to { opacity: 1; transform: translateY(0); }
        }
        #airport-window-content.apt-ready > * {
            animation: aptContentIn 0.4s cubic-bezier(0.16, 1, 0.3, 1) both;
        }
        #airport-window-content.apt-ready > *:nth-child(2) { animation-delay: 0.05s; }
        #airport-window-content.apt-ready > *:nth-child(3) { animation-delay: 0.1s; }
        #airport-window-content.apt-ready > *:nth-child(4) { animation-delay: 0.15s; }

        /* Weather Module Refactor */
        .weather-module-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 8px;
            margin-top: 12px;
        }

        .wx-stat-box {
            background: var(--bg-subtle);
            border-radius: 6px;
            padding: 8px;
            display: flex;
            flex-direction: column;
            align-items: center;
            text-align: center;
        }

        .wx-label {
            font-size: 0.65rem;
            color: #64748b;
            text-transform: uppercase;
            font-weight: 700;
            margin-bottom: 4px;
        }

        .wx-value {
            font-family: var(--font-data);
            font-size: 0.95rem;
            color: #e2e8f0;
            font-weight: 600;
        }

        .wx-condition-pill {
            grid-column: span 4;
            background: rgba(16, 185, 129, 0.1); 
            border: 1px solid rgba(16, 185, 129, 0.2);
            color: var(--color-success);
            padding: 8px;
            border-radius: 6px;
            text-align: center;
            font-weight: 700;
            font-size: 0.9rem;
            margin-top: 4px;
            display: flex;
            justify-content: center;
            align-items: center;
            gap: 8px;
        }

        /* Dynamic colors for flight rules */
        .wx-vfr { background: rgba(34, 197, 94, 0.1);
            color: #4ade80; border-color: rgba(34, 197, 94, 0.3); }
        .wx-mvfr { background: rgba(59, 130, 246, 0.1);
            color: #60a5fa; border-color: rgba(59, 130, 246, 0.3); }
        .wx-ifr { background: rgba(239, 68, 68, 0.1);
            color: #f87171; border-color: rgba(239, 68, 68, 0.3); }
        .wx-lifr { background: rgba(168, 85, 247, 0.1);
            color: #c084fc; border-color: rgba(168, 85, 247, 0.3); }

        /* Route Cards (Flight Strips) */
        .route-card {
            background: linear-gradient(to right, rgba(30, 41, 59, 0.4), rgba(30, 41, 59, 0.2));
            border: 1px solid var(--border-glass);
            border-left: 3px solid var(--color-brand);
            border-radius: 4px;
            padding: 10px 14px;
            margin-bottom: 8px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: all 0.2s;
        }

        .route-card:hover {
            background: rgba(30, 41, 59, 0.7);
            transform: translateX(2px);
            border-color: var(--border-highlight);
        }

        .route-info {
            display: flex;
            flex-direction: column;
            gap: 4px;
        }

        .route-callsign {
            font-family: var(--font-data);
            font-size: 1rem;
            color: #fff;
            font-weight: 700;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .route-details {
            font-size: 0.75rem;
            color: #94a3b8;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .route-ac-badge {
            background: #1e293b;
            padding: 2px 6px;
            border-radius: 3px;
            color: #cbd5e1;
            font-weight: 600;
            font-size: 0.7rem;
            border: 1px solid var(--border-glass);
        }

        .plan-btn-mini {
            background: rgba(14, 165, 233, 0.1);
            color: var(--color-brand);
            border: 1px solid rgba(14, 165, 233, 0.3);
            padding: 6px 12px;
            border-radius: 4px;
            font-size: 0.8rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
        }

        .plan-btn-mini:hover {
            background: var(--color-brand);
            color: #fff;
        }

        /* ATC Grid */
        .atc-grid-card {
            background: #232326;
            border: 1px solid var(--border-glass);
            border-radius: 6px;
            padding: 10px;
            margin-bottom: 8px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .atc-type-badge {
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.75rem;
            font-weight: 800;
            text-transform: uppercase;
            width: 80px;
            text-align: center;
        }
        /* Neutral gray chips with colored type text — the old solid navy /
           indigo fills clashed with the app's zinc base. */
        .atc-type-gnd { background: #1c1c1f; color: #a1a1aa; border: 1px solid #3f3f46;
        }
        .atc-type-twr { background: #1c1c1f; color: #60a5fa; border: 1px solid #3f3f46;
        }
        .atc-type-app { background: #1c1c1f; color: #818cf8; border: 1px solid #3f3f46;
        }
        .atc-type-obs { background: #1c1c1f; color: #a1a1aa; border: 1px solid #3f3f46;
        }

        .atc-controller {
            font-weight: 600;
            color: #e2e8f0;
            font-size: 0.9rem;
        }

        .atc-duration {
            font-family: monospace;
            color: #64748b;
            font-size: 0.8rem;
        }

        /* --- ATC SESSION HISTORY (Replay) --- */
        .atc-history-card {
            background: #232326;
            border: 1px solid var(--border-glass);
            border-radius: 8px;
            padding: 10px 12px;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px;
        }
        .atc-history-main { display: flex; flex-direction: column; gap: 5px; min-width: 0; flex: 1; }
        .atc-history-top { display: flex; align-items: center; gap: 8px; }
        .atc-history-user { font-weight: 700; color: #e2e8f0; font-size: 0.85rem; }
        .atc-history-user i { color: #818cf8; margin-right: 4px; }
        .atc-history-live {
            font-size: 0.6rem; font-weight: 800; letter-spacing: 0.5px;
            color: #4ade80; border: 1px solid #4ade80; border-radius: 4px; padding: 0 5px;
            animation: atc-history-pulse 1.8s ease-in-out infinite;
        }
        @keyframes atc-history-pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.45; } }
        .atc-history-freqs { display: flex; flex-wrap: wrap; gap: 4px; }
        .atc-history-freq-pill {
            font-size: 0.6rem; font-weight: 700; color: #d4d4d8;
            background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.14);
            border-radius: 4px; padding: 1px 6px;
        }
        .atc-history-freq-pill.muted { color: #71717a; background: transparent; border-color: #3f3f46; }
        .atc-history-meta { font-family: monospace; font-size: 0.7rem; color: #71717a; }
        .atc-replay-session-btn {
            flex-shrink: 0; display: inline-flex; align-items: center; gap: 6px;
            background: rgba(255,255,255,0.1); color: #fff;
            border: 1px solid rgba(255,255,255,0.16); border-radius: 8px; padding: 8px 12px;
            font-size: 0.72rem; font-weight: 800; letter-spacing: 0.3px; cursor: pointer;
            transition: transform .12s ease, box-shadow .12s ease, background .12s ease;
        }
        .atc-replay-session-btn:hover { transform: translateY(-1px); background: rgba(255,255,255,0.18); box-shadow: 0 4px 14px rgba(0,0,0,0.45); }
        .atc-replay-session-btn:active { transform: translateY(0); }

        /* --- HERO ACTION BUTTONS --- */
        .hero-actions {
            position: absolute;
            top: 15px;
            right: 15px;
            display: flex;
            gap: 8px;
            z-index: 10;
        }

        .hero-btn {
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #fff;
            width: 32px;
            height: 32px;
            border-radius: 50%;
            cursor: pointer;
            display: grid;
            place-items: center;
            transition: all 0.2s ease;
            backdrop-filter: blur(4px);
            position: relative;
        }

        /* Extends the tap area to ~44pt (Apple HIG minimum) without changing
           the visual size. The 32px circular button alone is a fiddly target
           in portrait, where the identity h1 can also sit close to it. */
        .hero-btn::before {
            content: '';
            position: absolute;
            inset: -6px;
            border-radius: 50%;
        }

        .hero-btn:hover {
            background: rgba(255, 255, 255, 0.2);
            transform: scale(1.1);
        }

        /* --- AIRPORT WINDOW TABS --- */
        .apt-tabs-header {
            display: flex;
            background: rgba(0, 0, 0, 0.2);
            border-bottom: 1px solid var(--border-glass);
            margin-bottom: 16px;
        }

        .apt-tab-btn {
            flex: 1;
            padding: 12px 10px;
            background: transparent;
            border: none;
            color: #94a3b8;
            font-size: 0.85rem;
            font-weight: 600;
            text-transform: uppercase;
            cursor: pointer;
            border-bottom: 2px solid transparent;
            transition: all 0.3s ease;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            min-width: 0;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .apt-tab-btn:hover {
            color: #fff;
            background: rgba(255, 255, 255, 0.05);
        }

        .apt-tab-btn.active {
            color: var(--text-primary);
            border-bottom-color: var(--color-accent);
            background: rgba(255, 255, 255, 0.06);
        }

        .apt-tab-content {
            display: none;
            animation: fadeIn 0.3s ease;
        }

        .apt-tab-content.active {
            display: block;
        }

        @keyframes fadeIn {
            from { opacity: 0;
            transform: translateY(5px); }
            to { opacity: 1; transform: translateY(0);
            }
        }

        /* --- RUNWAY DROPDOWN STYLES --- */
        .runway-dropdown-header {
            cursor: pointer;
            transition: background 0.2s;
        }
        .runway-dropdown-header:hover {
            background: rgba(255, 255, 255, 0.05);
        }
        .runway-dropdown-content {
            display: none;
            padding: 8px;
            border-top: 1px solid var(--border-glass);
        }
        .runway-dropdown-content.open {
            display: grid;
            grid-template-columns: 1fr 1fr; 
            gap: 8px;
            animation: slideDown 0.3s ease-out;
        }
        .runway-toggle-icon {
            color: #94a3b8;
            transition: transform 0.3s ease;
        }
        .runway-dropdown-header.open .runway-toggle-icon {
            transform: rotate(180deg);
        }
        
        @keyframes slideDown {
            from { opacity: 0;
            transform: translateY(-5px); }
            to { opacity: 1; transform: translateY(0);
            }
        }

        /* --- SERVER SELECTOR PILL --- */
        #server-selector-container {
            position: absolute;
            top: 20px;
            left: 50%;
            transform: translateX(-50%);
            background: rgba(15, 23, 42, 0.9);
            backdrop-filter: blur(10px);
            border: 1px solid var(--border-glass);
            border-radius: 999px;
            /* Pill shape */
            padding: 4px;
            display: flex;
            gap: 4px;
            z-index: 1050; /* Above map */
            box-shadow: 0 4px 20px rgba(0,0,0,0.4);
        }

        .server-btn {
            background: transparent;
            border: none;
            color: #94a3b8;
            padding: 6px 16px;
            font-size: 0.8rem;
            font-weight: 600;
            border-radius: 999px;
            cursor: pointer;
            transition: all 0.2s ease;
            white-space: nowrap;
            font-family: var(--font-ui);
        }

        .server-btn:hover {
            color: #fff;
            background: rgba(255, 255, 255, 0.05);
        }

        .server-btn.active {
            background: #3b82f6;
            color: #fff;
            box-shadow: 0 2px 10px rgba(59, 130, 246, 0.4);
        }

        /* Mobile adjustment */
        @media (max-width: 768px) {
            #server-selector-container {
                top: 70px;
                width: auto;
                max-width: 90vw;
            }
            .server-btn {
                padding: 6px 12px;
                font-size: 0.75rem;
            }
        }

        .apt-quick-info-strip {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 10px 16px;
            background: rgba(0, 0, 0, 0.2);
            border-bottom: 1px solid var(--border-glass);
            font-size: 0.75rem;
            color: #94a3b8;
            overflow-x: auto;
            white-space: nowrap;
        }

        .apt-feature-pill {
            display: flex;
            align-items: center;
            gap: 6px;
            background: var(--bg-subtle);
            padding: 3px 8px;
            border-radius: 4px;
            border: 1px solid var(--border-glass);
            font-weight: 600;
        }

        .apt-dashboard-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
            padding: 0 16px;
            margin-bottom: 8px;
        }

        @media (max-width: 600px) {
            .apt-dashboard-grid {
                grid-template-columns: 1fr;
            }
        }

        .apt-mini-module {
            background: rgba(24, 24, 27, 0.6);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: var(--radius-sm);
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }

        .apt-mini-header {
            background: var(--bg-subtle);
            padding: 6px 10px;
            font-size: 0.7rem;
            font-weight: 700;
            color: #94a3b8;
            text-transform: uppercase;
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--border-glass);
        }

        .apt-mini-body {
            padding: 10px;
            flex-grow: 1;
            display: flex;
            flex-direction: column;
            justify-content: center;
        }

        .stat-grid-compact {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
        }

        .compact-stat-box {
            text-align: center;
            background: rgba(255, 255, 255, 0.02);
            border-radius: 4px;
            padding: 4px;
        }
        .compact-label { font-size: 0.6rem;
            color: #a1a1aa; display: block; }
        .compact-value { font-family: var(--font-data); font-size: 0.9rem; color: #e4e4e7;
            font-weight: 600; }

        .metar-strip {
            background: rgba(0, 0, 0, 0.3);
            padding: 8px 16px;
            font-family: var(--font-data);
            font-size: 0.7rem;
            color: #94a3b8;
            border-bottom: 1px solid var(--border-glass);
            white-space: pre-wrap;
            line-height: 1.3;
        }

        /* --- Shared Tech Style --- */
        .tech-module {
            background: var(--bg-glass);
            border: 1px solid var(--border-glass);
            border-radius: var(--radius-md);
            overflow: hidden;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.5);
            margin-bottom: 8px; 
            display: flex;
            flex-direction: column;
        }

        .tech-module-header {
            background: var(--bg-panel);
            padding: 8px 12px;
            border-bottom: 1px solid var(--border-glass);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .tech-module-title {
            font-size: 0.75rem;
            font-weight: 700;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .tech-module-body {
            padding: 12px;
            background: transparent;
            position: relative;
        }

        /* --- Tech Card Specifics --- */
        .tech-card {
            background: var(--bg-glass);
            border: 1px solid var(--border-glass);
            border-radius: var(--radius-md); 
            overflow: hidden;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.5);
            position: relative;
            font-family: var(--font-ui);
            margin-bottom: 12px; 
        }
        .tech-card-header {
            padding: 12px 16px 4px;
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            position: relative;
            z-index: 10;
        }
        .tech-badge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            padding: 1px 6px;
            border-radius: 999px;
            background: rgba(16, 185, 129, 0.1);
            border: 1px solid rgba(16, 185, 129, 0.2);
            font-size: 9px;
            font-weight: 700;
            color: var(--color-success);
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }
        .tech-ping {
            position: relative;
            display: flex;
            height: 5px;
            width: 5px;
        }
        .tech-ping span {
            position: absolute;
            display: inline-flex;
            height: 100%;
            width: 100%;
            border-radius: 50%;
            background-color: var(--color-success);
        }
        .tech-ping .animate {
            animation: ping 1s cubic-bezier(0, 0, 0.2, 1) infinite;
            opacity: 0.75;
        }
        @keyframes ping {
            75%, 100% { transform: scale(2);
            opacity: 0; }
        }
        .tech-model {
            font-size: 1.1rem;
            font-weight: 700;
            color: var(--text-primary);
            letter-spacing: -0.025em;
            margin: 0;
            line-height: 1.2;
        }
        .tech-airline {
            font-size: 0.75rem;
            font-weight: 500;
            color: rgba(56, 189, 248, 0.9);
            margin-top: 0px;
            display: flex;
            align-items: center;
            gap: 5px;
        }
        .tech-content {
            padding: 12px;
            position: relative;
            z-index: 10;
        }
        .tech-image-container {
            position: relative;
            width: 100%;
            aspect-ratio: 21 / 9;
            border-radius: var(--radius-sm);
            overflow: hidden;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.2);
            border: 1px solid var(--border-glass);
            background: #000;
        }
        .tech-image {
            width: 100%;
            height: 100%;
            object-fit: cover;
            transition: transform 0.7s ease-out;
        }
        .tech-image-container:hover .tech-image {
            transform: scale(1.05);
        }
        .tech-image-overlay {
            position: absolute;
            inset: 0;
            background: linear-gradient(to top, rgba(2, 6, 23, 0.9), transparent, transparent);
            opacity: 0.8;
        }
        .tech-image-info {
            position: absolute;
            bottom: 8px;
            left: 10px;
            right: 10px;
            display: flex;
            justify-content: space-between;
            align-items: flex-end;
        }
        .tech-photographer {
            display: flex;
            flex-direction: column;
        }
        .tech-photo-label {
            font-size: 9px;
            color: #cbd5e1;
            font-weight: 500;
            margin-bottom: 0px;
            line-height: 1;
        }
        .tech-photo-name {
            display: flex;
            align-items: center;
            gap: 4px;
            font-size: 10px;
            font-weight: 600;
            color: #fff;
        }
        .tech-grid {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 8px;
            margin-top: 12px;
        }
        .tech-stat-card {
            background: var(--bg-panel);
            border: 1px solid var(--border-glass);
            padding: 8px 10px;
            border-radius: 6px;
            transition: background 0.2s;
        }
        .tech-stat-card:hover {
            background: rgba(63, 63, 70, 0.6);
        }
        .tech-stat-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 2px;
        }
        .tech-stat-label {
            font-size: 9px;
            font-weight: 600;
            color: #94a3b8;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }
        .tech-stat-value {
            font-family: var(--font-data);
            font-size: 0.95rem;
            color: #fff;
            font-weight: 600;
            letter-spacing: -0.025em;
        }
        .tech-country-card {
            grid-column: span 2;
            background: var(--bg-panel);
            border: 1px solid var(--border-glass);
            padding: 6px 10px;
            border-radius: 6px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .tech-country-left {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .tech-country-icon {
            width: 24px;
            height: 24px;
            border-radius: 4px;
            background: rgba(51, 65, 85, 0.5);
            display: flex;
            align-items: center;
            justify-content: center;
            color: #94a3b8;
        }
        .tech-bottom-bar {
            height: 3px;
            width: 100%;
            background: linear-gradient(to right, #0ea5e9, #2563eb, #4f46e5);
            opacity: 0.8;
        }

        #simple-flight-window-frame {
            border-radius: var(--radius-md);
            background: var(--bg-glass);
        }

        /* --- Simple Flight Window phases (collapsed bar <-> expanded panel) --- */
        .info-window.simple-collapsed,
        .info-window.simple-expanded {
            transition: width 0.4s cubic-bezier(0.16, 1, 0.3, 1),
                        height 0.4s cubic-bezier(0.16, 1, 0.3, 1),
                        max-height 0.4s cubic-bezier(0.16, 1, 0.3, 1),
                        opacity 0.55s cubic-bezier(0.16, 1, 0.3, 1),
                        transform 0.6s cubic-bezier(0.16, 1, 0.3, 1);
        }
        .info-window.simple-collapsed { overflow: hidden; }

        /* --- ATIS & TERMINAL STYLES --- */
        .atis-status-row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 8px;
            font-family: var(--font-data);
        }

        .atis-code-large {
            font-size: 1.2rem;
            font-weight: 700;
            color: #fbbf24; /* Amber */
            text-shadow: 0 0 5px rgba(251, 191, 36, 0.3);
        }

        .atis-timestamp {
            font-size: 0.75rem;
            color: #94a3b8;
        }

        /* The Digital Text Box */
        .terminal-text-box {
            background: rgba(10, 12, 16, 0.6);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 6px;
            padding: 10px;
            font-family: 'JetBrains Mono', 'Consolas', monospace;
            font-size: 0.7rem;
            color: #86efac;
            /* Terminal Green */
            line-height: 1.5;
            white-space: pre-wrap;
            box-shadow: inset 0 0 10px rgba(0,0,0,0.5);
            max-height: 120px;
            overflow-y: auto;
            text-transform: uppercase;
        }

        /* Scrollbar for terminal */
        .terminal-text-box::-webkit-scrollbar { width: 4px;
        }
        .terminal-text-box::-webkit-scrollbar-thumb { background: #334155; border-radius: 2px;
        }

        /* Fallback / Calculated Mode Styles */
        .atis-runway-row {
            display: flex;
            align-items: center; justify-content: space-between;
            background: rgba(255, 255, 255, 0.02); padding: 6px 8px;
            border-radius: 4px; border: 1px solid var(--border-glass); margin-bottom: 4px;
        }
        .atis-label { font-size: 0.65rem; font-weight: 700; color: #94a3b8; min-width: 40px;
        }
        .atis-pill { font-family: var(--font-data); font-size: 0.75rem; font-weight: 700; padding: 2px 6px;
            border-radius: 3px; border: 1px solid; margin-left: 4px; }
        .pill-arr { background: rgba(16, 185, 129, 0.1);
            color: #4ade80; border-color: rgba(16, 185, 129, 0.3); }
        .pill-dep { background: rgba(56, 189, 248, 0.1);
            color: #38bdf8; border-color: rgba(56, 189, 248, 0.3); }
        
        /* Mini Module Footer (For ATIS Remarks) */
        .apt-mini-footer {
            padding: 6px 10px;
            background: rgba(0, 0, 0, 0.2);
            border-top: 1px solid var(--border-glass);
            font-size: 0.65rem;
            color: #cbd5e1;
            display: flex;
            align-items: center;
            min-height: 24px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        .apt-mini-footer i { margin-right: 6px;
            color: #fbbf24; } /* Amber icon for remarks */



        .stat-alt { color: #38bdf8;
        } /* Sky Blue */
        .stat-gs { color: #fbbf24; font-size: 0.75rem; font-weight: 600;
        } /* Amber */

        /* --- NEW: TRAFFIC DROPDOWN STYLES --- */
.traffic-dropdown {
    background: rgba(24, 24, 27, 0.45);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 8px;
    overflow: hidden;
    margin-bottom: 8px;
    transition: all 0.3s ease;
}

.traffic-dropdown[open] {
    background: rgba(24, 24, 27, 0.65);
    border-color: rgba(255, 255, 255, 0.18);
}

.traffic-dropdown-header {
    padding: 12px 16px;
    cursor: pointer;
    list-style: none; /* Hide default browser arrow */
    display: flex;
    align-items: center;
    font-size: 0.75rem;
    font-weight: 800;
    color: #94a3b8;
    text-transform: uppercase;
    letter-spacing: 1px;
    user-select: none;
}

.traffic-dropdown-header::-webkit-details-marker {
    display: none; /* Hide Safari arrow */
}

.traffic-dropdown-header:hover {
    color: #fff;
    background: rgba(255, 255, 255, 0.05);
}

.traffic-dropdown-header i.chevron {
    font-size: 0.8rem;
    transition: transform 0.3s ease;
    opacity: 0.6;
    margin-left: 10px;
}

.traffic-dropdown[open] .traffic-dropdown-header i.chevron {
    transform: rotate(180deg);
}

.traffic-count-badge {
    background: rgba(255, 255, 255, 0.08);
    color: #e4e4e7;
    padding: 2px 8px;
    border-radius: 99px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.7rem;
    margin-left: auto;
}

.traffic-dropdown-content {
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    max-height: 350px; /* Limits height to prevent excessive scrolling */
    overflow-y: auto;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
}
    /* --- UNIVERSAL MODERN SCROLLBAR --- */
/* Target all scrollable elements */
*::-webkit-scrollbar {
    width: 6px;     /* Thin enough to be sleek, thick enough to grab */
    height: 6px;    /* For horizontal bars */
}

*::-webkit-scrollbar-track {
    background: transparent; /* Keep background clean */
}

*::-webkit-scrollbar-thumb {
    background-color: rgba(255, 255, 255, 0.1); /* Subtle white tint */
    border-radius: 10px;
    border: 1px solid transparent; /* Padding effect */
}

*::-webkit-scrollbar-thumb:hover {
    background-color: var(--color-brand, #38bdf8); /* High-tech blue highlight on hover */
}

/* Firefox Support */
* {
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.1) transparent;
}

/* Example: Hiding the server selection buttons */
.server-selection-container {
    display: none !important;
}

/* --- SPICED PILOT REPORT STYLES --- */
.stats-rehaul-container {
    padding: 20px;
    font-family: 'Inter', sans-serif;
}

.stats-hero {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 24px;
    padding: 20px;
    background: rgba(255, 255, 255, 0.03);
    border-radius: 16px;
    border: 1px solid rgba(255, 255, 255, 0.05);
}

.hero-username {
    font-size: 2.2rem; /* Big Typography */
    font-weight: 800;
    margin: 4px 0;
    letter-spacing: -1px;
    color: #fff;
}

.hero-rank-tag {
    font-size: 0.7rem;
    font-weight: 900;
    color: #38bdf8;
    text-transform: uppercase;
    letter-spacing: 1.5px;
}

.grade-badge {
    text-align: center;
    background: #38bdf8;
    color: #000;
    padding: 10px 18px;
    border-radius: 12px;
    display: flex;
    flex-direction: column;
}

.grade-label { font-size: 0.6rem; font-weight: 900; }
.grade-val { font-size: 1.8rem; font-weight: 800; line-height: 1; }

.spiced-kpi-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    margin-bottom: 20px;
}

.kpi-card {
    background: rgba(10, 10, 12, 0.4);
    padding: 16px;
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.05);
}

.kpi-label {
    display: block;
    font-size: 0.65rem;
    color: #71717a;
    font-weight: 800;
    margin-bottom: 4px;
}

.kpi-value {
    font-size: 1.4rem;
    font-weight: 700;
    color: #fff;
    font-family: 'JetBrains Mono', monospace;
}

.kpi-value.warn { color: #ef4444; }
.kpi-value small { font-size: 0.8rem; color: #52525b; }

/* --- CONTROLLER SPICE THEMES --- */

/* Specialist (Blue Glow) */
.atc-specialist .stats-hero {
    border-left: 5px solid #38bdf8;
    box-shadow: -10px 0 20px -10px rgba(56, 189, 248, 0.3);
}

/* Officer (Cyan / High Tech) */
.atc-officer .stats-hero {
    border-left: 5px solid #22d3ee;
    background: linear-gradient(90deg, rgba(34, 211, 238, 0.05) 0%, rgba(255,255,255,0.03) 100%);
}
.atc-officer .hero-rank-tag { color: #22d3ee; }

/* Supervisor (Gold / Elite) */
.atc-supervisor .stats-hero {
    border-left: 5px solid #fbbf24;
    background: linear-gradient(90deg, rgba(251, 191, 36, 0.1) 0%, rgba(255,255,255,0.03) 100%);
}
.atc-supervisor .hero-rank-tag { color: #fbbf24; }
.atc-supervisor .grade-badge { background: #fbbf24; }

/* --- MULTI-TRACK / PINNED FLIGHTS (PRO FEATURE) --- */
        #mini-windows-container {
            position: fixed;
            bottom: 24px;
            left: 24px;
            display: flex;
            flex-direction: column-reverse;
            gap: 12px;
            z-index: 2000;
            pointer-events: none;
        }

.pinned-flight-card {
            width: 360px;
            height: 92px;
            background: rgba(20, 20, 25, 0.85);
            backdrop-filter: blur(16px);
            -webkit-backdrop-filter: blur(16px);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 12px 30px rgba(0,0,0,0.6), inset 0 1px 1px rgba(255, 255, 255, 0.05);
            pointer-events: auto;
            animation: slideInLeft 0.3s cubic-bezier(0.16, 1, 0.3, 1) forwards;
            transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
            font-family: 'Inter', sans-serif;
            display: flex;
            align-items: stretch;
            position: relative;
        }

        .pinned-flight-card:hover {
            background: rgba(30, 30, 35, 0.9);
            border-color: rgba(255, 255, 255, 0.2);
            transform: translateX(6px);
            box-shadow: 0 16px 40px rgba(0,0,0,0.7), inset 0 1px 1px rgba(255, 255, 255, 0.1);
        }

        .pinned-image-flush {
            width: 140px;
            flex-shrink: 0;
            position: relative;
            background: #000;
        }

        .pinned-image-flush img {
            width: 100%;
            height: 100%;
            object-fit: cover;
            object-position: center;
        }

        /* Premium detail: A gradient overlay that fades the right edge of the image into the dark card */
        .pinned-image-gradient {
            position: absolute;
            top: 0;
            right: 0;
            bottom: 0;
            left: 0;
            background: linear-gradient(to right, transparent 60%, rgba(20, 20, 25, 0.85) 100%);
            pointer-events: none;
        }

        .pinned-content {
            flex: 1;
            padding: 12px 16px;
            display: flex;
            flex-direction: column;
            justify-content: center;
            position: relative;
        }

        .pinned-close {
            position: absolute;
            top: 8px;
            right: 12px;
            background: transparent;
            border: none;
            color: #64748b;
            font-size: 0.85rem;
            cursor: pointer;
            transition: all 0.2s ease;
            padding: 4px;
            display: grid;
            place-items: center;
        }

        .pinned-close:hover {
            color: #ef4444;
            transform: scale(1.15);
        }

        .pinned-header {
            margin-bottom: 8px;
        }

        .pinned-callsign {
            font-size: 1.15rem;
            font-weight: 800;
            color: #ffffff;
            letter-spacing: -0.2px;
        }

        .pinned-stats {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 8px;
        }

        .p-stat {
            display: flex;
            flex-direction: column;
        }

        .p-label {
            font-size: 0.55rem;
            color: #94a3b8;
            font-weight: 800;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 3px;
        }

        .p-val {
            font-size: 0.85rem;
            color: #f1f5f9;
            font-family: 'JetBrains Mono', monospace;
            font-weight: 700;
        }

        .p-val small {
            font-size: 0.55rem;
            color: #64748b;
        }

        .dest-val {
            color: #38bdf8;
        }

        @media (max-width: 768px) {
            #pin-flight-btn {
                display: none !important;
            }
        }

        /* --- DOCKING WINDOW & TOGGLE BUTTON STYLES --- */
        @media (min-width: 993px) {
            .info-window.dock-left {
                right: auto !important;
                left: 20px !important;
                transform-origin: top left;
                transform: translateX(-28px) translateY(10px) scale(0.96);
            }

            .info-window.dock-left.visible {
                transform: translateX(0) translateY(0) scale(1);
            }
        }

        .ac-dock-toggle-btn {
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.1);
            color: #94a3b8;
            width: 44px;
            height: 44px;
            border-radius: 12px;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            flex-shrink: 0;
        }

        .ac-dock-toggle-btn:hover {
            background: rgba(255, 255, 255, 0.1);
            color: #fff;
            transform: scale(1.05);
        }

        .ac-dock-toggle-btn:active {
            transform: scale(0.95);
        }

        .ac-dock-toggle-btn.docked-left {
            color: #38bdf8;
            background: rgba(56, 189, 248, 0.1);
            border-color: rgba(56, 189, 248, 0.3);
        }

        .ac-dock-toggle-btn.docked-left i {
            transform: rotate(180deg);
            transition: transform 0.3s ease;
        }

        @media (max-width: 992px) {
            .ac-dock-toggle-btn {
                display: none !important;
            }
        }
    `;

    const style = document.createElement('style');
    style.id = styleId;
    style.type = 'text/css';
    style.appendChild(document.createTextNode(css));
    document.head.appendChild(style);
}

/**
 * Calculates the departure gate based on the closest proximity to the start of the flown path.
 * Leaves the arrival gate blank as a placeholder for future implementation.
 * @param {string} departureIcao - The 4-letter ICAO code of the departure airport.
 * @param {Array} flownPath - The array of trail points [{lat, lon}, ...] for the flight.
 * @returns {Promise<{departureGate: string, arrivalGate: string}>} The resolved gate names.
 */
const gateCache = new Map();

async function determineGatesForFlight(departureIcao, flownPath) {
    let departureGate = '---';
    let arrivalGate = '---'; // Left blank for now

    if (!departureIcao || !flownPath || flownPath.length === 0) {
        return { departureGate, arrivalGate };
    }

    // 1. Get the starting point of the flight (first recorded point in the trail)
    const startPoint = flownPath[0];
    const startLat = startPoint.lat !== undefined ? startPoint.lat : startPoint.latitude;
    const startLon = startPoint.lon !== undefined ? startPoint.lon : startPoint.longitude;

    if (startLat === undefined || startLon === undefined) {
        return { departureGate, arrivalGate };
    }

    try {
        let gates;
        // 2. Fetch the gates from the MongoDB-backed endpoint or Cache
        if (gateCache.has(departureIcao)) {
            gates = gateCache.get(departureIcao);
        } else {
            const response = await fetch(`https://site--indgo-backend--6dmjph8ltlhv.code.run/api/gates/${departureIcao}`);
            if (!response.ok) {
                return { departureGate, arrivalGate };
            }
            gates = await response.json();
            gateCache.set(departureIcao, gates);
        }
        
        if (!gates || gates.length === 0) {
            return { departureGate, arrivalGate };
        }

        let nearestGate = null;
        let minDistance = Infinity;

        // 3. Iterate through all gates to find the closest one to the start point
        gates.forEach(gate => {
            const gateLat = gate.latitude || gate.lat || (gate.location && gate.location.lat) || (gate.location && gate.location.latitude);
            const gateLon = gate.longitude || gate.lon || (gate.location && gate.location.lon) || (gate.location && gate.location.longitude);

            if (gateLat != null && gateLon != null) {
                // Utilizing the existing getDistanceKm helper function
                const distance = getDistanceKm(startLat, startLon, gateLat, gateLon);
                
                if (distance < minDistance) {
                    minDistance = distance;
                    nearestGate = gate;
                }
            }
        });

        // 4. Set the departure gate to the nearest one found
        if (nearestGate) {
            departureGate = nearestGate.name || nearestGate.ident || nearestGate.gateName || nearestGate.id || 'GATE';
        }

    } catch (error) {
        console.error(`Error calculating departure gate for ${departureIcao}:`, error);
    }

    return { departureGate, arrivalGate };
}

/**
 * Injects explicit gate information retrieved directly from the FlightDispatchService.
 * Replaces the loading/calculating placeholders immediately.
 * Features a premium, aviation-grade status indicator.
 */
function injectFiledGateInfoUI(filedPlan, flightProps, plan) {
    const routeBar = document.querySelector('.ac-route-info-bar');
    if (!routeBar) return;

    // Inject premium animations for the status dot if not already present
    if (!document.getElementById('ac-premium-status-styles')) {
        const style = document.createElement('style');
        style.id = 'ac-premium-status-styles';
        style.innerHTML = `
            @keyframes ac-pulse-ring {
                0% { box-shadow: 0 0 0 0 rgba(var(--status-rgb), 0.8); }
                70% { box-shadow: 0 0 0 5px rgba(var(--status-rgb), 0); }
                100% { box-shadow: 0 0 0 0 rgba(var(--status-rgb), 0); }
            }
            .ac-status-dot {
                width: 6px;
                height: 6px;
                border-radius: 50%;
                background-color: currentColor;
                animation: ac-pulse-ring 2.5s infinite cubic-bezier(0.2, 0.8, 0.2, 1);
            }
        `;
        document.head.appendChild(style);
    }

    // 1. Locate the nodes
    const depNode = routeBar.querySelector('.route-node:not(.end)');
    const arrNode = routeBar.querySelector('.route-node.end');
    const routeVisualNode = routeBar.querySelector('.route-visual');

    const premiumGateCss = 'color: #94a3b8; font-size: 0.65rem; font-weight: 600; letter-spacing: 0.05em; margin-top: 8px; background: rgba(255,255,255,0.02); border: 1px solid rgba(255,255,255,0.06); padding: 4px 8px; border-radius: 4px; width: fit-content; display: inline-flex; align-items: center; gap: 6px; box-shadow: 0 2px 8px rgba(0,0,0,0.2);';

    // 2. Inject the Departure Gate HTML
    if (depNode) {
        depNode.style.display = 'flex';
        depNode.style.flexDirection = 'column';
        
        let depGateEl = document.getElementById('ac-dep-gate');
        if (!depGateEl) {
            depGateEl = document.createElement('span');
            depGateEl.id = 'ac-dep-gate';
            depGateEl.style.cssText = premiumGateCss;
            depNode.appendChild(depGateEl);
        }
        depGateEl.innerHTML = filedPlan.dep_gate ? `<i class="fa-solid fa-plane-departure" style="color: #64748b; font-size: 0.6rem;"></i> GATE ${filedPlan.dep_gate}` : `<i class="fa-solid fa-plane-departure" style="color: #64748b; font-size: 0.6rem;"></i> GATE ---`;
    }

    // 3. Inject the Arrival Gate HTML
    if (arrNode) {
        arrNode.style.display = 'flex';
        arrNode.style.flexDirection = 'column';
        arrNode.style.alignItems = 'flex-end';
        
        let arrGateEl = document.getElementById('ac-arr-gate');
        if (!arrGateEl) {
            arrGateEl = document.createElement('span');
            arrGateEl.id = 'ac-arr-gate';
            arrGateEl.style.cssText = premiumGateCss;
            arrNode.appendChild(arrGateEl);
        }
        arrGateEl.innerHTML = filedPlan.arr_gate ? `<i class="fa-solid fa-plane-arrival" style="color: #64748b; font-size: 0.6rem;"></i> GATE ${filedPlan.arr_gate}` : `<i class="fa-solid fa-plane-arrival" style="color: #64748b; font-size: 0.6rem;"></i> GATE ---`;
    }

    // 4. Inject Premium Schedule Status Centered
    if (routeVisualNode && flightProps && filedPlan.dep_time && filedPlan.duration_minutes) {
        const oldStatusEl = document.getElementById('ac-arr-status');
        if (oldStatusEl) oldStatusEl.remove();

        const plannedArrDate = new Date(new Date(filedPlan.dep_time).getTime() + filedPlan.duration_minutes * 60000);
        let etaTimestamp = null;

        if (plan && plan.flightPlanItems && plan.flightPlanItems.length >= 2 && flightProps.position.gs_kt > 50) {
            let destLat = null, destLon = null;
            const extractDest = (items) => {
                for (let i = items.length - 1; i >= 0; i--) {
                    if (items[i].location && typeof items[i].location.latitude === 'number') {
                        destLat = items[i].location.latitude;
                        destLon = items[i].location.longitude;
                        return true;
                    }
                    if (items[i].children && items[i].children.length > 0) {
                        if (extractDest(items[i].children)) return true;
                    }
                }
                return false;
            };
            extractDest(plan.flightPlanItems);

            if (destLat != null && destLon != null) {
                const distanceToDestKm = getDistanceKm(flightProps.position.lat, flightProps.position.lon, destLat, destLon);
                const distanceToDestNM = distanceToDestKm / 1.852;
                const eteHours = distanceToDestNM / flightProps.position.gs_kt;
                
                if (eteHours > 0 && eteHours < 48) {
                    etaTimestamp = new Date(Date.now() + (eteHours * 3600 * 1000));
                }
            }
        }

        let statusText = "ON TIME";
        let statusColor = "#10b981"; // Emerald Green
        let statusRgb = "16, 185, 129";
        
        const isAtGate = (!flightProps.position.gs_kt || flightProps.position.gs_kt < 30) && (!flightProps.phase || flightProps.phase === 'Ground');

        if (isAtGate) {
            statusText = "SCHEDULED";
            statusColor = "#32ade6"; // Aviation Cyan
            statusRgb = "50, 173, 230";
        } else if (etaTimestamp) {
            const diffMs = etaTimestamp.getTime() - plannedArrDate.getTime();
            if (diffMs > 10 * 60000) { 
                statusText = "DELAYED";
                statusColor = "#ff3b30"; // Alert Red
                statusRgb = "255, 59, 48";
            }
        }

        let statusEl = document.getElementById('ac-flight-status-badge');
        if (!statusEl) {
            statusEl = document.createElement('div');
            statusEl.id = 'ac-flight-status-badge';
            routeVisualNode.appendChild(statusEl);
        }
        
        // Instrument Panel Telemetry Styling
        statusEl.style.cssText = `
            margin-top: 14px;
            padding: 4px 10px 4px 8px;
            background: rgba(15, 20, 25, 0.45);
            border: 1px solid rgba(255, 255, 255, 0.05);
            border-left: 3px solid ${statusColor};
            border-radius: 4px;
            color: ${statusColor};
            font-family: 'Inter', system-ui, sans-serif;
            font-size: 0.65rem;
            font-weight: 700;
            letter-spacing: 0.12em;
            text-transform: uppercase;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
            position: relative;
        `;
        
        statusEl.innerHTML = `
            <div style="--status-rgb: ${statusRgb}; color: ${statusColor}; display: flex; align-items: center; justify-content: center; margin-left: 2px;">
                <div class="ac-status-dot"></div>
            </div>
            <span style="padding-top: 1px; line-height: 1;">${statusText}</span>
        `;
    }
}

/**
 * Dynamically injects the gate info into the existing flight info bar layout.
 * Finds the HTML nodes and injects pills that show a "Loading" state until the math finishes.
 * @param {string} departureIcao - The 4-letter ICAO of the origin.
 * @param {Array} flownPath - The array of trail points.
 */
function injectGateInfoUI(departureIcao, flownPath) {
    const routeBar = document.querySelector('.ac-route-info-bar');
    if (!routeBar) return;

    // 1. Locate the left (Departure) and right (Arrival) node containers
    const depNode = routeBar.querySelector('.route-node:not(.end)');
    const arrNode = routeBar.querySelector('.route-node.end');

    // 2. Inject the Departure Gate HTML if it doesn't already exist
    if (depNode) {
        depNode.style.display = 'flex';
        depNode.style.flexDirection = 'column';
        
        let depGateEl = document.getElementById('ac-dep-gate');
        if (!depGateEl) {
            depGateEl = document.createElement('span');
            depGateEl.id = 'ac-dep-gate';
            depGateEl.style.cssText = 'color: #cbd5e1; font-size: 10px; font-weight: 700; margin-top: 4px; background: rgba(0,0,0,0.2); padding: 2px 6px; border-radius: 4px; width: fit-content; display: inline-block;';
            depGateEl.innerHTML = '<i class="fa-solid fa-door-open"></i> Calc...';
            depNode.appendChild(depGateEl);
        }
    }

    // 3. Inject the Arrival Gate HTML if it doesn't already exist
    if (arrNode) {
        arrNode.style.display = 'flex';
        arrNode.style.flexDirection = 'column';
        arrNode.style.alignItems = 'flex-end'; // Keep it aligned to the right side
        
        let arrGateEl = document.getElementById('ac-arr-gate');
        if (!arrGateEl) {
            arrGateEl = document.createElement('span');
            arrGateEl.id = 'ac-arr-gate';
            arrGateEl.style.cssText = 'color: #cbd5e1; font-size: 10px; font-weight: 700; margin-top: 4px; background: rgba(0,0,0,0.2); padding: 2px 6px; border-radius: 4px; width: fit-content; display: inline-block;';
            arrGateEl.innerHTML = '<i class="fa-solid fa-door-closed"></i> ---';
            arrNode.appendChild(arrGateEl);
        }
    }

    // 4. Execute the logic and update the UI when the nearest gate is found
    determineGatesForFlight(departureIcao, flownPath).then(gates => {
        const depGateEl = document.getElementById('ac-dep-gate');
        const arrGateEl = document.getElementById('ac-arr-gate');
        
        if (depGateEl) {
            depGateEl.innerHTML = gates.departureGate !== '---' 
                ? `<i class="fa-solid fa-door-open"></i> Gate ${gates.departureGate}` 
                : `<i class="fa-solid fa-door-open"></i> Gate ---`;
        }
        
        if (arrGateEl) {
            arrGateEl.innerHTML = `<i class="fa-solid fa-door-closed"></i> Gate ${gates.arrivalGate}`;
        }
    });
}

function createFlightMarker(flight) {
    if (!map) return null;

    const el = document.createElement('div');
    el.className = 'flight-icon';

    // Rotate icon based on heading
    const heading = flight.position.heading_deg || 0;
    
    // Choose icon color/image based on state
    let iconUrl = 'https://raw.githubusercontent.com/massun-sky/massun-sky-flight-icons/master/img/plane_b738.svg'; 
    if (flight.isVAMember) {
        // Gold icon for VA members? Or keep standard.
        // You can customize this if you want specific styling for VA members
    }

    el.style.backgroundImage = `url('${iconUrl}')`;
    el.style.transform = `rotate(${heading}deg)`;
    el.style.width = '30px';
    el.style.height = '30px';
    el.style.backgroundSize = 'contain';
    el.style.backgroundRepeat = 'no-repeat';

    // Create Leaflet Marker
    const marker = L.marker([flight.position.lat, flight.position.lon], {
        icon: L.divIcon({
            html: el,
            className: 'css-icon',
            iconSize: [30, 30],
            iconAnchor: [15, 15]
        })
    });

    // --- CLICK LISTENER ---
    marker.on('click', () => {
        selectedFlight = flight;
        updatePopupContent(flight, true); // Update & Open Popup
        updateSidebar(flight);            // Update Sidebar details
        drawTrail(flight.userId, flight.flightId); // Fetch Trail

        // <--- NEW: TRACK THIS VIEW FOR LEADERBOARD --->
        trackPilotView(flight);
    });

    marker.addTo(map);
    return marker;
}

async function trackPilotView(flight) {
    // Safety check: ensure we have a valid user to track
    if (!flight || !flight.userId || !flight.username) return;

    // Direct link to your backend database
    const BACKEND = "https://site--indgo-backend--6dmjph8ltlhv.code.run";

    try {
        await fetch(`${BACKEND}/api/leaderboard/track`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                pilotUserId: flight.userId,
                pilotName: flight.username
            })
        });
    } catch (e) {
        console.warn("❌ Leaderboard tracking failed:", e);
    }
}


async function initializeMapBoundaries(map) {
    if (!map) return;

    try {
        // 1. Switched to local GeoJSON
        if (!map.getSource('fir-boundaries')) {
            map.addSource('fir-boundaries', {
                type: 'geojson',
                data: './Boundaries.geojson' 
            });
        }

        const styleMode = mapFilters.mapStyle || 'dark';
        // Aeronautical-chart styling for the FIR boundary network: a clean cyan
        // line on dark maps, a deep sky line on light maps.
        const borderColor = (styleMode === 'light') ? '#0369a1' : '#67e8f9';
        const borderOpacity = (styleMode === 'light') ? 0.5 : 0.45;

        // FIX: Check if the plane layer exists before trying to place boundaries under it
        const beforeId = map.getLayer('sector-ops-live-flights-layer')
            ? 'sector-ops-live-flights-layer'
            : undefined;

        // 2. fir-fills Layer — a faint translucent tint applied ONLY to sectors
        // that currently have a controller online. updateActiveSectors() sets
        // the filter; until then nothing is tinted.
        if (!map.getLayer('fir-fills')) {
            map.addLayer({
                id: 'fir-fills',
                type: 'fill',
                source: 'fir-boundaries',
                filter: ['==', 'id', 'none-active'],
                paint: {
                    'fill-color': '#22c55e',
                    'fill-opacity': 0.1
                }
            }, beforeId); // Use safe reference
        }

        // 3. fir-borders Layer — the FULL FIR boundary network, drawn as clean
        // thin lines. The lines look the same whether or not a sector is
        // staffed; whether they show at all is controlled by the
        // showAtcBoundaries toggle (see applyAtcBoundaryVisibility).
        if (!map.getLayer('fir-borders')) {
            map.addLayer({
                id: 'fir-borders',
                type: 'line',
                source: 'fir-boundaries',
                paint: {
                    'line-color': borderColor,
                    'line-width': 0.8,
                    'line-opacity': borderOpacity
                }
            }, beforeId); // Use safe reference
        }

    } catch (err) {
        console.error("Error loading local map boundaries:", err);
    }

    // Honour the user's ATC-boundaries toggle for the freshly created layers.
    applyAtcBoundaryVisibility(map);
}

// Show or hide every FIR boundary layer based on the showAtcBoundaries toggle.
// Visibility is a layout property that persists until changed, so flipping the
// toggle here is enough — updateActiveSectors keeps drawing only the active
// sectors, but nothing is painted while the layers are hidden.
function applyAtcBoundaryVisibility(map) {
    const target = map || sectorOpsMap;
    if (!target) return;
    const vis = (mapFilters.showAtcBoundaries === false) ? 'none' : 'visible';
    ['fir-fills', 'fir-borders'].forEach(id => {
        if (target.getLayer(id)) {
            target.setLayoutProperty(id, 'visibility', vis);
        }
    });
}
window.applyAtcBoundaryVisibility = applyAtcBoundaryVisibility;

// Apply or remove Terrain Awareness mode to match the current mapFilters. Safe
// to call repeatedly (layers are guarded) and from any state — applyTerrainMode
// defers itself until the style is ready. Re-run on style swaps so the overlay
// survives a base-map change, and whenever the TAWS toggle/altitude changes.
function refreshTerrainMode() {
    if (!sectorOpsMap) return;
    if (mapFilters.showTerrainMode) {
        applyTerrainMode(sectorOpsMap, {
            tawsEnabled: !!mapFilters.terrainTawsEnabled,
            altitudeFt: Number(mapFilters.terrainTawsAltitude) || 10000
        });
    } else {
        removeTerrainMode(sectorOpsMap, {
            // If the Pro 3D-terrain toggle is on it shares the DEM source, so
            // hand elevation back to it instead of clearing the terrain.
            keepDemTerrain: !!(mapFilters.proMapConfig && mapFilters.proMapConfig.showTerrain)
        });
    }
}
window.refreshTerrainMode = refreshTerrainMode;

// 2. Fetch and display the Top 3 Pilots (Call this once on load, or on an interval)
async function updateLeaderboard() {
    const container = document.getElementById('leaderboard-list'); // Ensure you have this ID in your HTML
    if (!container) return; // specific safety check if element is missing

    try {
        const response = await fetch(`${API_BASE_URL}/api/leaderboard/top`);
        if (!response.ok) throw new Error('Network response was not ok');
        
        const topPilots = await response.json();

        container.innerHTML = ''; // Clear previous list

        if (topPilots.length === 0) {
            container.innerHTML = '<div class="leaderboard-empty">No flights tracked yet today</div>';
            return;
        }

        topPilots.forEach((pilot, index) => {
            const item = document.createElement('div');
            item.className = 'leaderboard-item';
            
            // Add medal emojis for top 3
            let rankDisplay = `#${index + 1}`;
            if (index === 0) rankDisplay = '🥇';
            if (index === 1) rankDisplay = '🥈';
            if (index === 2) rankDisplay = '🥉';

            item.innerHTML = `
                <div class="lb-rank">${rankDisplay}</div>
                <div class="lb-name">${pilot.pilotName}</div>
                <div class="lb-views">${pilot.viewCount} views</div>
            `;
            container.appendChild(item);
        });

    } catch (error) {
        console.error("Failed to update leaderboard:", error);
    }
}

// Optional: Auto-refresh leaderboard every 60 seconds
setInterval(updateLeaderboard, 60000);
// Run immediately on load
document.addEventListener('DOMContentLoaded', updateLeaderboard);

/**
 * Deciphers Infinite Flight ATIS text into a structured object.
 * Extracts Info letter, Time, Runways, Approaches, and Remarks.
 */
function parseAtis(text) {
    if (!text) return null;
    
    // 1. Info Letter (e.g., "Information ALPHA")
    const infoMatch = text.match(/information\s+([A-Z])/i);
    const info = infoMatch ? infoMatch[1].toUpperCase() : '?';

    // 2. Time (e.g., "0522 ZULU")
    const timeMatch = text.match(/(\d{4})\s*Z/i);
    const time = timeMatch ? timeMatch[1] + 'Z' : '--';

    // 3. Runways (e.g., "Landing Runway 31R", "Departing Runways 4L and 4R")
    // We capture the phrase after "Landing/Departing" then find all runway codes in it.
    const landingMatch = text.match(/Landing\s+([^,.]+)/i);
    const departingMatch = text.match(/Departing\s+([^,.]+)/i);
    
    const extractRwys = (str) => {
        if (!str) return '---';
        const matches = str.match(/\d{2}[LRC]?/g);
        return matches ? matches.join('/') : '---';
    };

    const landing = extractRwys(landingMatch ? landingMatch[1] : null);
    const departing = extractRwys(departingMatch ? departingMatch[1] : null);

    // 4. Approach (e.g., "expect ILS approach")
    const approachMatch = text.match(/expect\s+(.*?)\s+approach/i);
    let approach = approachMatch ? approachMatch[1].toUpperCase() : 'VISUAL';
    // Clean up common long words
    approach = approach.replace('VISUAL', 'VIS').replace('APPROACH', '');

    // 5. Remarks (e.g., "Remarks, no pattern work.")
    // Captures text after "Remarks" until the next period or major keyword.
    const remarksMatch = text.match(/Remarks[.,]\s*(.*?)(?=\.|Landing|Departing|Advise|$)/i);
    let remarks = remarksMatch ? remarksMatch[1].trim() : null;
    
    // Formatting cleanup
    if (remarks && remarks.toLowerCase().includes('no pattern work')) remarks = 'NO PATTERN WORK';

    return { info, time, landing, departing, approach, remarks };
}

/**
 * --- [REPLACED] Traffic UI Module ---
 * Renders the Delay Index bar and stats matching your theme.
 */
function generateTrafficForecastHTML(congestion) {
    if (!congestion) return `<div class="apt-mini-module"><div class="apt-mini-body" style="padding:10px; text-align:center;">No Traffic Data</div></div>`;

    // Convert 0.0-1.0 score to percentage for the bar width
    const percent = Math.min(congestion.score * 100, 100);
    
    return `
    <div class="apt-mini-module">
        <div class="apt-mini-header">
            <span><i class="fa-solid fa-chart-line"></i> DELAY INDEX</span>
            <span style="color: ${congestion.color}; font-family: 'Consolas', monospace; font-size: 0.8rem;">
                ${congestion.scoreDisplay} / 5.0
            </span>
        </div>
        <div class="apt-mini-body">
            
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px;">
                <span style="font-size: 0.75rem; font-weight: 700; color: ${congestion.color};">${congestion.level}</span>
                <span style="font-size: 0.65rem; color: #94a3b8; text-transform: uppercase;">
                    <i class="fa-solid fa-arrow-trend-up"></i> ${congestion.trend}
                </span>
            </div>

            <div style="height: 6px; width: 100%; background: rgba(255,255,255,0.1); border-radius: 3px; overflow: hidden; margin-bottom: 10px;">
                <div style="width: ${percent}%; height: 100%; background-color: ${congestion.color}; transition: width 0.5s ease;"></div>
            </div>

            <div class="stat-grid-compact" style="grid-template-columns: 1fr 1fr 1fr;">
                <div class="compact-stat-box">
                    <span class="compact-label">ARRIVALS</span>
                    <span class="compact-value" style="color: #38bdf8;">${congestion.stats.inbound}</span>
                </div>
                <div class="compact-stat-box">
                    <span class="compact-label">GROUND</span>
                    <span class="compact-value">${congestion.stats.ground}</span>
                </div>
                <div class="compact-stat-box">
                    <span class="compact-label">HOLDING</span>
                    <span class="compact-value" style="color: ${congestion.stats.holding > 0 ? '#ef4444' : '#e2e8f0'};">${congestion.stats.holding}</span>
                </div>
            </div>

        </div>
    </div>
    `;
}

/**
 * --- [NEW] Generates the HTML for the Traffic Forecast Module ---
 */
function generateTrafficForecastHTML(congestion) {
    // Calculate percentages for the flow bar
    const total = congestion.imminent + congestion.approach + congestion.enroute;
    const pImm = total > 0 ? (congestion.imminent / total) * 100 : 0;
    const pApp = total > 0 ? (congestion.approach / total) * 100 : 0;
    const pEnr = total > 0 ? (congestion.enroute / total) * 100 : 0;

    return `
    <div class="tech-module" style="margin-bottom: 8px;">
        <div class="tech-module-header">
            <span class="tech-module-title"><i class="fa-solid fa-chart-pie"></i> TRAFFIC FORECAST</span>
            <span class="tech-badge" style="background: rgba(255,255,255,0.05); color: ${congestion.color}; border-color: ${congestion.color};">
                ${congestion.level}
            </span>
        </div>
        <div class="tech-module-body" style="padding: 12px;">
            
            <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
                <div style="text-align: center; flex: 1;">
                    <div style="font-size: 1.2rem; font-weight: 700; color: #fff;">${congestion.imminent}</div>
                    <div style="font-size: 0.6rem; color: #ef4444; font-weight: 600; text-transform: uppercase;">Final (< 12m)</div>
                </div>
                <div style="text-align: center; flex: 1; border-left: 1px solid rgba(255,255,255,0.1); border-right: 1px solid rgba(255,255,255,0.1);">
                    <div style="font-size: 1.2rem; font-weight: 700; color: #fff;">${congestion.approach}</div>
                    <div style="font-size: 0.6rem; color: #f59e0b; font-weight: 600; text-transform: uppercase;">Appr (12-25m)</div>
                </div>
                <div style="text-align: center; flex: 1;">
                    <div style="font-size: 1.2rem; font-weight: 700; color: #fff;">${congestion.enroute}</div>
                    <div style="font-size: 0.6rem; color: #38bdf8; font-weight: 600; text-transform: uppercase;">Enroute (25m+)</div>
                </div>
            </div>

            <div style="height: 6px; width: 100%; background: #1e293b; border-radius: 3px; display: flex; overflow: hidden; margin-top: 10px;">
                <div style="width: ${pImm}%; background: #ef4444;"></div>
                <div style="width: ${pApp}%; background: #f59e0b;"></div>
                <div style="width: ${pEnr}%; background: #38bdf8;"></div>
            </div>
            
            <div style="margin-top: 8px; font-size: 0.75rem; color: #94a3b8; text-align: center; font-style: italic;">
                <i class="fa-solid fa-arrow-trend-up"></i> Status: <span style="color: #e2e8f0; font-weight: 600;">${congestion.trend}</span>
                ${congestion.avgHoldTime > 0 ? `<span style="margin-left: 8px; color: #ef4444;">(Est. Delay: ~${congestion.avgHoldTime}m)</span>` : ''}
            </div>

        </div>
    </div>
    `;
}


/**
     * --- [NEW] Helper to find the session ID for the currently selected server ---
     */
    function getCurrentSessionId(sessionsData) {
        if (!sessionsData || !Array.isArray(sessionsData.sessions)) return null;
        
        const targetName = currentServerName.toLowerCase();
        
        // 1. Try Exact Match
        let session = sessionsData.sessions.find(s => s.name.toLowerCase() === targetName);
        
        // 2. Try Fuzzy Match (e.g. "Expert" matching "Expert Server")
        if (!session) {
            session = sessionsData.sessions.find(s => s.name.toLowerCase().includes(targetName.split(' ')[0]));
        }
        
        return session ? session.id : null;
    }

 function switchServer(newServerName) {
        if (newServerName === currentServerName) return;

        console.log(`Switching server from ${currentServerName} to ${newServerName}...`);
        
        // 1. Update State & Storage
        currentServerName = newServerName;
        localStorage.setItem('preferredServer', currentServerName);

        // Clear the session cache when switching servers
        cachedSessionId = null;
        lastSessionFetchTime = 0;

        // 2. Clear Live Aircraft Data (Visuals)
        Object.keys(pilotMarkers).forEach(fid => {
            if (pilotMarkers[fid].marker) pilotMarkers[fid].marker.remove();
        });
        pilotMarkers = {};
        
        liveTrailCache.clear();
        
        for (const key in currentMapFeatures) {
            delete currentMapFeatures[key];
        }
        
        if (mapAnimator && typeof mapAnimator._updateMapSource === 'function') {
            mapAnimator._updateMapSource(); 
        }
        
        if (currentFlightInWindow) {
            const closeBtn = document.querySelector('.aircraft-window-close-btn');
            if (closeBtn) closeBtn.click();
        }

        // 3. ATC & AIRPORT MARKER RESET
        if (sectorOpsAtcNotamInterval) {
            clearInterval(sectorOpsAtcNotamInterval);
            sectorOpsAtcNotamInterval = null;
        }

        Object.values(airportAndAtcMarkers).forEach(obj => {
            if (obj && obj.marker) {
                obj.marker.remove();
            }
        });
        airportAndAtcMarkers = {}; 

        activeAtcFacilities = [];
        activeNotams = [];
        
        renderAirportMarkers();

        // 4. UI Updates
        document.querySelectorAll('.server-btn').forEach(btn => {
            if (btn.dataset.server === currentServerName) {
                btn.classList.add('active');
            } else {
                btn.classList.remove('active');
            }
        });

        const shortName = newServerName.split(' ')[0]; 
        const landingServerLabel = document.getElementById('landing-server-name');
        if (landingServerLabel) {
            landingServerLabel.textContent = `${shortName.toUpperCase()} SERVER`;
        }

        // 5. Show Notification
        showNotification(`Switching to ${currentServerName}...`, 'info');

        // 6. Socket Handshake
        if (sectorOpsSocket && sectorOpsSocket.connected) {
            sectorOpsSocket.emit('join_server_room', currentServerName);
        }

        // 7. Restart Data Polling
        updateSectorOpsSecondaryData();
        sectorOpsAtcNotamInterval = setInterval(updateSectorOpsSecondaryData, DATA_REFRESH_INTERVAL_MS);
    }

/**
 * --- [NEW] SMART RUNWAY LOGIC ---
 * Parses wind string (e.g. "360 @ 10KT") into numeric values.
 */
function parseWindString(windStr) {
    if (!windStr) return { dir: 0, spd: 0 };
    
    // Remove " @ " if present to standardize
    const cleanStr = windStr.replace(' @ ', '');
    
    // Handle "VRB" (Variable)
    if (cleanStr.startsWith('VRB')) {
        const spdMatch = cleanStr.match(/VRB(\d+)/);
        return { dir: -1, spd: spdMatch ? parseInt(spdMatch[1]) : 0 };
    }

    // Standard format (e.g. 36010KT or 360/10)
    const match = cleanStr.match(/(\d{3})\/?(\d+)(?:KT|MPS)?/);
    if (match) {
        return { dir: parseInt(match[1]), spd: parseInt(match[2]) };
    }
    
    return { dir: 0, spd: 0 };
}

/**
 * Calculates headwind/crosswind components and assigns a suitability score.
 */
function getRunwayRecommendations(runways, windStr) {
    if (!runways || runways.length === 0) return [];
    
    const wind = parseWindString(windStr);
    
    // Logic for Calm/Variable winds (< 5 kts)
    if (wind.spd < 5 || wind.dir === -1) {
        // Just return longest runways, marking them as "CALM / ANY"
        return runways.flatMap(r => [
            { ident: r.le_ident, score: 100, reason: 'CALM WIND', color: 'green', headwind: 0, crosswind: 0 },
            { ident: r.he_ident, score: 100, reason: 'CALM WIND', color: 'green', headwind: 0, crosswind: 0 }
        ]).sort((a, b) => a.ident.localeCompare(b.ident)).slice(0, 4);
    }

    const recommendations = [];

    runways.forEach(r => {
        // Check both ends (Low End and High End)
        [
            { ident: r.le_ident, heading: r.le_heading_degT },
            { ident: r.he_ident, heading: r.he_heading_degT }
        ].forEach(end => {
            if (end.heading == null) return;

            // --- PHYSICS CALCULATION ---
            // 1. Calculate angle difference (0-180)
            let angleDiff = Math.abs(end.heading - wind.dir);
            if (angleDiff > 180) angleDiff = 360 - angleDiff;
            
            // 2. Convert to Radians
            const rads = angleDiff * (Math.PI / 180);
            
            // 3. Components
            const headwind = Math.round(wind.spd * Math.cos(rads));
            const crosswind = Math.round(wind.spd * Math.sin(rads));

            // --- SCORING LOGIC ---
            let score = 100;
            let color = 'green';
            let reason = 'FAVORABLE';

            // Headwind is good (add to score), Tailwind is bad (subtract)
            score += headwind * 2; 

            // Tailwind Penalty
            if (headwind < -5) {
                score -= 200; // Heavy penalty for significant tailwind
                color = 'red';
                reason = 'TAILWIND';
            } else if (headwind < 0) {
                score -= 50; // Minor penalty for slight tailwind
                color = 'orange';
                reason = 'MARGINAL';
            }

            // Crosswind Penalty
            if (Math.abs(crosswind) > 20) {
                score -= 100;
                color = 'red';
                reason = 'X-WIND LIMIT';
            } else if (Math.abs(crosswind) > 12) {
                score -= 30;
                color = 'orange';
                reason = 'CROSSWIND';
            }

            recommendations.push({
                ident: end.ident,
                score: score,
                color: color,
                reason: reason,
                headwind: headwind,
                crosswind: Math.abs(crosswind)
            });
        });
    });

    // Sort by score (descending) and return top 4
    return recommendations.sort((a, b) => b.score - a.score).slice(0, 4);
}

/**
 * --- [FIXED] Helper to find the Simbrief aircraft <option> value
 * from a given aircraft name.
 * @param {string} aircraftName - The aircraft name (e.g., "Airbus A320-200" or "A320").
 * @returns {string|null} The matching value (e.g., "A320") or null.
 */
function findSimbriefAircraftValue(aircraftName) {
    if (!aircraftName || !AIRCRAFT_SELECTION_LIST) return null;
    
    const upperName = aircraftName.toUpperCase().trim();

    // --- [NEW FIX] Step 0: Create a specific mapping for known mismatches ---
    // This is the most reliable solution.
    // Key: The exact name from the Infinite Flight API (in uppercase).
    // Value: The "value" from your AIRCRAFT_SELECTION_LIST.
    const knownMismatches = {
        // --- Airbus ---
        "AIRBUS A318": "A318",
        "AIRBUS A319": "A319",
        "AIRBUS A320-200": "A320",
        "A320": "A320", // In case the API just sends "A320"
        "AIRBUS A320NEO": "A20N",
        "A320NEO": "A20N",
        "AIRBUS A321": "A321",
        "A321": "A321",
        "AIRBUS A321NEO": "A21N",
        "A321NEO": "A21N",
        "AIRBUS A330-300": "A333",
        "AIRBUS A330-900": "A339",
        "AIRBUS A340": "A346",
        "AIRBUS A350": "A359",
        "AIRBUS A380": "A388",
        
        // --- Boeing ---
        "BOEING 717-200": "B712",
        "BOEING 737-700": "B737",
        "BOEING 737-800": "B738",
        "B738": "B738", // In case the API just sends "B738"
        "BOEING 737-900": "B739",
        "BOEING 737 MAX 8": "B38M",
        "BOEING 747-200B": "B742",
        "BOEING 747-400": "B744",
        "BOEING 747-8": "B748",
        "BOEING 757-200": "B752",
        "BOEING 767-300ER": "B763",
        "BOEING 777-200ER": "B772",
        "BOEING 777-200LR": "B77L",
        "BOEING 777-300ER": "B77W",
        "BOEING 787-8": "B788",
        "BOEING 787-9": "B789",
        "BOEING 787-10": "B78X",

        // --- Others ---
        "CRJ-200": "CRJ2",
        "CRJ-700": "CRJ7",
        "CRJ-900": "CRJ9",
        "CRJ-1000": "CRJX",
        "DE HAVILLAND DASH 8 Q400": "DH8D",
        "E175": "E175",
        "E190": "E190",
        "DC-10": "DC10",
        "MD-11": "MD11"
        
        // --- Add more known mismatches here as you find them ---
        // "API NAME": "YOUR_VALUE",
    };

    // Try the new mismatch map first.
    if (knownMismatches[upperName]) {
        return knownMismatches[upperName];
    }
    
    // --- If not in the map, fallback to existing logic ---

    // 1. Try to match by "value" (e.g., "A320")
    let match = AIRCRAFT_SELECTION_LIST.find(ac => ac.value.toUpperCase() === upperName);
    if (match) return match.value;

    // 2. Try to match by "name" (e.g., "Airbus A320-200")
    match = AIRCRAFT_SELECTION_LIST.find(ac => ac.name.toUpperCase() === upperName);
    if (match) return match.value;
    
    // 3. Fallback: Try to find a "value" that is *included* in the name
    // (e.g., name is "Airbus A320neo", value is "A20N")
    match = AIRCRAFT_SELECTION_LIST.find(ac => upperName.includes(ac.value.toUpperCase()));
    if (match) return match.value;

    // 4. Fallback: Try to find a "name" that *includes* the given name
    // (e.g., name is "A320", list name is "Airbus A320-200")
     match = AIRCRAFT_SELECTION_LIST.find(ac => ac.name.toUpperCase().includes(upperName));
    if (match) return match.value;

    console.warn(`Could not find Simbrief match for aircraft: ${aircraftName}`);
    return null; // No match found
}

window.handleSearchInput = handleSearchInput;


async function loadExternalPanelContent() {
    const panel = document.getElementById('sector-ops-floating-panel');
    if (!panel) {
        console.error('Could not find #sector-ops-floating-panel to inject content.');
        return;
    }

    // 1. Clean up old tabs if present
    const oldTabs = panel.querySelector('.panel-tabs');
    if (oldTabs) oldTabs.remove();

    // 2. Find/Prepare content container
    const mainContentContainer = panel.querySelector('.panel-content');
    if (!mainContentContainer) {
        console.error('Could not find .panel-content to inject content into.');
        return;
    }
    
    // 3. Show loading state
    mainContentContainer.innerHTML = '<div class="spinner-small" style="margin: 2rem auto;"></div>';
    mainContentContainer.style.overflow = 'auto'; 

    // --- [NEW] INJECT CLOSE BUTTON ---
    // Remove existing button if it exists to avoid duplicates
    const existingBtn = panel.querySelector('.panel-close-btn');
    if (existingBtn) existingBtn.remove();

    const closeBtn = document.createElement('button');
    closeBtn.className = 'panel-close-btn';
    closeBtn.innerHTML = '<i class="fa-solid fa-times"></i>';
    closeBtn.title = "Close Window";
    panel.appendChild(closeBtn); // Add it directly to the panel frame

    // Add Close Logic
    closeBtn.addEventListener('click', () => {
        panel.classList.remove('visible'); // Hides the modal
    });

    // 4. Fetch content
    try {
        const response = await fetch('panel-content.html');
        if (!response.ok) throw new Error(`Failed to fetch panel-content.html (Status: ${response.status})`);
        
        const htmlContent = await response.text();
        mainContentContainer.innerHTML = htmlContent;

        // 5. Initialize Tabs
        const tabButtons = mainContentContainer.querySelectorAll('.panel-tab-btn');
        const tabContents = mainContentContainer.querySelectorAll('.tab-content');

        function activateTab(tabId) {
            tabButtons.forEach(btn => {
                if (btn.dataset.tab === tabId) btn.classList.add('active');
                else btn.classList.remove('active');
            });
            tabContents.forEach(content => {
                if (content.id === tabId) content.classList.add('active');
                else content.classList.remove('active');
            });
        }

        tabButtons.forEach(button => {
            button.addEventListener('click', () => {
                activateTab(button.dataset.tab);
            });
        });

        // 6. Handle Auto-Open based on URL
        const urlParams = new URLSearchParams(window.location.search);
        if (urlParams.get('view') === 'view-flight-plan' || urlParams.has('ofp_id')) {
            activateTab('tab-flightplan');
            panel.classList.add('visible'); // ONLY open if URL requests it
        } else {
            activateTab('tab-welcome');
            // Do NOT add .visible here, so it stays closed on load
        }

        // 7. Populate Aircraft Select
        const aircraftSelect = mainContentContainer.querySelector('#fp-aircraft');
        if (aircraftSelect && AIRCRAFT_SELECTION_LIST.length > 0) {
            AIRCRAFT_SELECTION_LIST.forEach(aircraft => {
                const option = document.createElement('option');
                option.value = aircraft.value;
                option.textContent = aircraft.name;
                aircraftSelect.appendChild(option);
            });
        }

        // 8. Initialize SimBrief
        if (typeof SimbriefIntegration !== 'undefined') {
            SimbriefIntegration.init({
                showNotification: showNotification,
                populateDispatchPass: populateDispatchPass,
                onFlightSaved: refreshSavedFlightList,
                maxFlights: 2
            });
            mainContentContainer.addEventListener('click', handleSavedFlightListClick);
            renderSavedFlightList();
        }

    } catch (error) {
        console.error('Error loading external panel content:', error);
        mainContentContainer.innerHTML = `
            <div class="info-panel-content">
                <p class="error-text">Could not load panel content.</p>
            </div>
        `;
    }
}


function toggleTripCardMode(active) {
    const takeoverUI = document.getElementById('trip-card-takeover');
    if (!takeoverUI) return;

    if (active && currentFlightInWindow) {
        takeoverUI.innerHTML = `
            <div class="tc-card">
                <div class="tc-hero">
                    <div class="tc-bg-layer"></div>
                    <div class="tc-hero-gradient"></div>
                    <div class="tc-hero-badge"><span class="tc-live-dot"></span> Live</div>
                    <button class="tc-exit-btn" type="button" aria-label="Close trip card">
                        <i class="fa-solid fa-xmark"></i>
                    </button>
                </div>
                <div class="tc-body">
                    <div class="tc-title-row">
                        <h2 class="tc-callsign">---</h2>
                        <div class="tc-subtitle">
                            <span class="tc-pilot">---</span>
                            <span class="tc-divider">·</span>
                            <span class="tc-ac">---</span>
                        </div>
                    </div>
                    <div class="tc-route">
                        <div class="tc-route-airport">
                            <span class="tc-route-label">From</span>
                            <span class="tc-icao origin">---</span>
                        </div>
                        <div class="tc-route-progress">
                            <div class="tc-progress-track">
                                <div class="tc-progress-bar"></div>
                                <i class="fa-solid fa-plane tc-plane-icon"></i>
                            </div>
                        </div>
                        <div class="tc-route-airport tc-route-airport-right">
                            <span class="tc-route-label">To</span>
                            <span class="tc-icao destination">---</span>
                        </div>
                    </div>
                    <div class="tc-stats">
                        <div class="tc-stat">
                            <span class="tc-stat-label">Altitude</span>
                            <span class="tc-stat-value"><span class="tc-alt">---</span><span class="tc-unit">ft</span></span>
                        </div>
                        <div class="tc-stat">
                            <span class="tc-stat-label">Speed</span>
                            <span class="tc-stat-value"><span class="tc-spd">---</span><span class="tc-unit">kt</span></span>
                        </div>
                    </div>
                    <button class="tc-share-btn" type="button" title="Share this flight">
                        <i class="fa-solid fa-share-nodes"></i>
                        <span class="tc-share-btn-label">Share Flight</span>
                    </button>
                </div>
            </div>
        `;

        takeoverUI.querySelector('.tc-share-btn')?.addEventListener('click', () => {
            shareCurrentFlight(takeoverUI.querySelector('.tc-share-btn'));
        });

        takeoverUI.querySelector('.tc-exit-btn')?.addEventListener('click', () => {
            toggleTripCardMode(false);
        });

        takeoverUI.classList.add('active');
        
        if (sectorOpsMap && sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
            setLiveFlightsFilter(['==', 'flightId', currentFlightInWindow]);
        }

        document.getElementById('sector-ops-floating-panel')?.classList.remove('visible');
        if (typeof aircraftInfoWindow !== 'undefined' && aircraftInfoWindow) {
            aircraftInfoWindow.classList.remove('visible');
        }
        
        updateTripCardRealtime();
        
        const feature = currentMapFeatures[currentFlightInWindow];
        if (feature) {
            sectorOpsMap.flyTo({ center: feature.geometry.coordinates, zoom: 7, speed: 0.8, pitch: 0 });
        }
    } else {
        takeoverUI.classList.remove('active');
        if (typeof updateAircraftLayerFilter === 'function') updateAircraftLayerFilter(); 
        if (typeof aircraftInfoWindow !== 'undefined' && aircraftInfoWindow) {
            aircraftInfoWindow.classList.add('visible');
            if (window.MobileUIHandler && window.MobileUIHandler.isMobile()) {
                window.MobileUIHandler.openWindow(aircraftInfoWindow);
            }
        }
    }
}

window.toggleTripCardMode = toggleTripCardMode;

function buildFlightShareUrl(flightId) {
    if (!flightId) return null;
    const origin = (typeof window !== 'undefined' && window.location && window.location.origin) || '';
    return `${origin}/share/${encodeURIComponent(flightId)}`;
}

async function shareCurrentFlight(triggerBtn = null) {
    const flightId = currentFlightInWindow;
    if (!flightId) {
        if (typeof showNotification === 'function') showNotification('Open a flight first to share it.', 'error');
        return;
    }

    const shareUrl = buildFlightShareUrl(flightId);
    if (!shareUrl) return;

    const feature = currentMapFeatures[flightId];
    const props = feature?.properties || {};
    const callsign = props.callsign || 'Live Flight';
    const dep = props.departureIcao || '???';
    const arr = props.arrivalIcao || '???';
    const title = `${callsign} · ${dep} → ${arr}`;
    const text = `Watch ${callsign} live on Inflight`;

    const flashSuccess = (label) => {
        if (!triggerBtn) return;
        const lbl = triggerBtn.querySelector('.tc-share-btn-label');
        const original = lbl ? lbl.textContent : null;
        if (lbl) lbl.textContent = label;
        triggerBtn.style.background = 'linear-gradient(135deg, #22c55e, #16a34a)';
        setTimeout(() => {
            if (lbl && original !== null) lbl.textContent = original;
            triggerBtn.style.background = '';
        }, 1600);
    };

    // Native share sheet on mobile / supported browsers.
    if (typeof navigator !== 'undefined' && typeof navigator.share === 'function') {
        try {
            await navigator.share({ title, text, url: shareUrl });
            flashSuccess('Shared!');
            return;
        } catch (err) {
            // AbortError = user cancelled the sheet; treat as no-op without falling back.
            if (err && err.name === 'AbortError') return;
            // Otherwise fall through to clipboard.
        }
    }

    // Clipboard fallback.
    try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
            await navigator.clipboard.writeText(shareUrl);
        } else {
            const tmp = document.createElement('textarea');
            tmp.value = shareUrl;
            tmp.setAttribute('readonly', '');
            tmp.style.position = 'absolute';
            tmp.style.left = '-9999px';
            document.body.appendChild(tmp);
            tmp.select();
            document.execCommand('copy');
            document.body.removeChild(tmp);
        }
        flashSuccess('Link copied!');
        if (typeof showNotification === 'function') showNotification('Share link copied to clipboard.', 'success');
    } catch (err) {
        console.warn('shareCurrentFlight: clipboard failed', err);
        if (typeof showNotification === 'function') showNotification('Could not copy link — try again.', 'error');
    }
}

window.shareCurrentFlight = shareCurrentFlight;

// --- INCOMING SHARE LINK ---
// Goal: when the user follows /share/<id> the flight info window must appear
// the *instant* the app loads — not "after the websocket reconnects, then
// after currentServerName matches, then after the next push". The share
// function writes a payload to sessionStorage before redirecting, so we can
// open the window from that snapshot immediately and let the socket / direct
// API refresh it in the background.
function buildSyntheticFeature(flightLike, communityImageUrl) {
    if (!flightLike) return null;
    const pos = flightLike.position || {};
    const lat = pos.lat ?? pos.latitude;
    const lon = pos.lon ?? pos.longitude;
    if (lat == null || lon == null) return null;
    const ac = flightLike.aircraft || {};
    return {
        type: 'Feature',
        geometry: { type: 'Point', coordinates: [lon, lat] },
        properties: {
            flightId: flightLike.flightId,
            callsign: flightLike.callsign || null,
            username: flightLike.username || null,
            altitude: pos.alt_ft || 0,
            speed: pos.gs_kt || 0,
            verticalSpeed: pos.vs_fpm || 0,
            position: pos,
            aircraft: ac,
            aircraftName: ac.aircraftName || flightLike.aircraftName || '',
            liveryName: ac.liveryName || flightLike.liveryName || '',
            airlineIcao: getAirlineIcaoFromLivery(ac.liveryName || flightLike.liveryName),
            registration: ac.registration || flightLike.registration || '',
            arrivalIcao: flightLike.arrivalIcao || null,
            departureIcao: flightLike.departureIcao || null,
            userId: flightLike.userId || null,
            heading: pos.heading_deg || 0,
            isStaff: !!flightLike.isStaff,
            isVAMember: !!flightLike.isVAMember,
            pilotState: flightLike.pilotState ?? null,
            communityImageUrl: communityImageUrl || null,
            contributorName: null,
            tailNumber: null
        }
    };
}

// Visible "Opening shared flight…" overlay so the user gets immediate feedback
// during the 5–10s window between page boot and the live socket populating.
// Removed automatically once the flight info window opens, or replaced with a
// friendlier failure message after the budget expires.
function showShareLoadingOverlay() {
    if (typeof document === 'undefined') return null;
    if (document.getElementById('inflight-share-loading-overlay')) {
        return document.getElementById('inflight-share-loading-overlay');
    }
    const overlay = document.createElement('div');
    overlay.id = 'inflight-share-loading-overlay';
    overlay.setAttribute('role', 'status');
    overlay.setAttribute('aria-live', 'polite');
    overlay.innerHTML = `
        <style>
            #inflight-share-loading-overlay {
                position: fixed; inset: 0; z-index: 99999;
                display: flex; align-items: center; justify-content: center;
                background: radial-gradient(circle at center, rgba(10,15,31,0.92), rgba(10,15,31,0.97));
                backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px);
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                color: #e5e7eb;
                animation: inflight-share-overlay-in 180ms ease-out;
            }
            #inflight-share-loading-overlay .panel {
                max-width: 320px; padding: 28px 32px; text-align: center;
                background: linear-gradient(180deg, rgba(56,189,248,0.08), rgba(15,23,42,0));
                border: 1px solid rgba(255,255,255,0.08);
                border-radius: 16px;
                box-shadow: 0 12px 40px rgba(0,0,0,0.45);
            }
            #inflight-share-loading-overlay .spinner {
                width: 44px; height: 44px; margin: 0 auto 16px;
                border-radius: 50%;
                border: 3px solid rgba(56,189,248,0.18);
                border-top-color: #38bdf8;
                animation: inflight-share-spin 0.9s linear infinite;
            }
            #inflight-share-loading-overlay h2 { margin: 0 0 6px; font-size: 1.05rem; font-weight: 700; letter-spacing: 0.2px; }
            #inflight-share-loading-overlay p { margin: 0; color: #94a3b8; font-size: 0.85rem; line-height: 1.4; }
            #inflight-share-loading-overlay.fade-out { animation: inflight-share-overlay-out 200ms ease-in forwards; }
            @keyframes inflight-share-spin { to { transform: rotate(360deg); } }
            @keyframes inflight-share-overlay-in { from { opacity: 0; } to { opacity: 1; } }
            @keyframes inflight-share-overlay-out { from { opacity: 1; } to { opacity: 0; } }
        </style>
        <div class="panel">
            <div class="spinner"></div>
            <h2 data-share-overlay-title>Opening shared flight…</h2>
            <p data-share-overlay-msg>Connecting to the live feed.</p>
        </div>
    `;
    document.body.appendChild(overlay);
    return overlay;
}

function updateShareLoadingOverlay(title, msg) {
    const overlay = document.getElementById('inflight-share-loading-overlay');
    if (!overlay) return;
    if (title) {
        const t = overlay.querySelector('[data-share-overlay-title]');
        if (t) t.textContent = title;
    }
    if (msg) {
        const m = overlay.querySelector('[data-share-overlay-msg]');
        if (m) m.textContent = msg;
    }
}

function dismissShareLoadingOverlay() {
    const overlay = document.getElementById('inflight-share-loading-overlay');
    if (!overlay) return;
    overlay.classList.add('fade-out');
    setTimeout(() => { try { overlay.remove(); } catch (_) {} }, 220);
}

async function consumeShareLinkParam() {
    if (typeof window === 'undefined' || !window.location) return;
    let params;
    try { params = new URLSearchParams(window.location.search || ''); } catch (_) { params = new URLSearchParams(); }
    const flightId = params.get('flight');
    let sharedServer = params.get('server');

    // Load any sessionStorage handoff the share function dropped for us.
    let sharePayload = null;
    try {
        const raw = sessionStorage.getItem('inflight_share_payload');
        if (raw) {
            const parsed = JSON.parse(raw);
            // Only honour payloads recent enough to plausibly still be live,
            // and only for the flight we actually navigated to.
            if (parsed && (!flightId || parsed.flightId === flightId) &&
                (!parsed.capturedAt || Date.now() - parsed.capturedAt < 10 * 60 * 1000)) {
                sharePayload = parsed;
                if (!sharedServer && parsed.serverName) sharedServer = parsed.serverName;
            }
            sessionStorage.removeItem('inflight_share_payload');
        }
    } catch (_) { /* private mode etc */ }

    const effectiveFlightId = flightId || sharePayload?.flightId;
    if (!effectiveFlightId) return;

    // Make sure the Inflight Pro upsell modal doesn't steal focus from the
    // flight info window. Remove it if the IIFE managed to slip it in before
    // our share check could fire.
    try {
        const proOverlay = document.getElementById('inflight-pro-loader-overlay');
        if (proOverlay) proOverlay.remove();
    } catch (_) { /* non-fatal */ }

    // Strip the share params so a refresh doesn't re-trigger and so the URL
    // stays clean once the window is open.
    try {
        params.delete('flight');
        params.delete('server');
        const newQuery = params.toString();
        const newUrl = window.location.pathname + (newQuery ? `?${newQuery}` : '') + window.location.hash;
        window.history.replaceState({}, '', newUrl);
    } catch (_) { /* non-fatal */ }

    // A pending payload means the share function couldn't confirm the flight
    // server-side. We still know the flightId — keep searching client-side.
    const hasUsableSnapshot = !!(sharePayload && sharePayload.flight);

    // Show the loading overlay immediately so the user knows the click worked.
    // (Skipped if the snapshot is good enough to open instantly below — the
    // flight info window itself is the feedback in that case.)
    if (!hasUsableSnapshot) showShareLoadingOverlay();

    // If the share landed us on a different server than the flight is on,
    // hop over before we start listening. switchServer() resets state cleanly.
    if (sharedServer && typeof currentServerName !== 'undefined' && sharedServer !== currentServerName) {
        try {
            if (typeof switchServer === 'function') switchServer(sharedServer);
            else {
                currentServerName = sharedServer;
                try { localStorage.setItem('preferredServer', sharedServer); } catch (_) {}
            }
        } catch (err) {
            console.warn('consumeShareLinkParam: server switch failed', err);
        }
    }

    let opened = false;
    const openFromFeature = async (feature, { seedCache = true } = {}) => {
        if (!feature || !feature.properties) return false;
        try {
            // Seed currentMapFeatures so the rest of the UI (trip card, traffic
            // counts, etc.) sees the flight even before the socket catches up.
            if (seedCache && typeof currentMapFeatures !== 'undefined' &&
                !currentMapFeatures[effectiveFlightId]) {
                currentMapFeatures[effectiveFlightId] = feature;
            }
            const props = feature.properties;
            const flightProps = {
                ...props,
                position: typeof props.position === 'string' ? JSON.parse(props.position) : props.position,
                aircraft: typeof props.aircraft === 'string' ? JSON.parse(props.aircraft) : props.aircraft
            };
            if (typeof sectorOpsMap !== 'undefined' && sectorOpsMap && feature.geometry?.coordinates) {
                try { sectorOpsMap.flyTo({ center: feature.geometry.coordinates, zoom: 7, essential: true }); } catch (_) {}
            }
            const sessionId = (typeof getValidSessionId === 'function') ? await getValidSessionId() : 'default';
            if (typeof handleAircraftClick === 'function') {
                await handleAircraftClick(flightProps, sessionId);
                opened = true;
                dismissShareLoadingOverlay();
                return true;
            }
        } catch (err) {
            console.warn('consumeShareLinkParam: failed to open flight', err);
        }
        return false;
    };

    // Wait briefly for the DOM bits handleAircraftClick depends on. We don't
    // want to fire it before #aircraft-info-window exists.
    const waitForUi = async () => {
        for (let i = 0; i < 50; i++) { // ~5s budget
            if (document.getElementById('aircraft-info-window')) return;
            await new Promise(r => setTimeout(r, 100));
        }
    };

    // 1) Open IMMEDIATELY from the share payload if we have one with real
    //    position data. This is the "the instant the user jumps in" path —
    //    no waiting on the socket. Pending payloads (no flight body) skip
    //    this and rely on the polling/retry loop below.
    if (hasUsableSnapshot) {
        const synthetic = buildSyntheticFeature(sharePayload.flight, sharePayload.communityImageUrl);
        if (synthetic) {
            await waitForUi();
            await openFromFeature(synthetic);
        }
    }

    // Make sure the info-window element exists before we start trying to open
    // from socket data, so the first hit lands cleanly.
    if (!opened) await waitForUi();

    // 2) Direct ACARS REST lookup across sessions, retried periodically. A
    //    fresh flight can take a few seconds to surface in the REST endpoint
    //    even when the socket already sees it, so one-shot isn't enough.
    let directHit = null;
    let directInFlight = false;
    const tryDirectLookup = async () => {
        if (directInFlight || directHit || opened) return null;
        directInFlight = true;
        try {
            const sessionsRes = await fetch('https://site--acars-backend--6dmjph8ltlhv.code.run/if-sessions');
            if (!sessionsRes.ok) return null;
            const sessionsJson = await sessionsRes.json();
            const sessions = Array.isArray(sessionsJson?.sessions) ? sessionsJson.sessions : [];
            if (!sessions.length) return null;

            const target = (typeof currentServerName !== 'undefined' && currentServerName) ? currentServerName.toLowerCase() : '';
            const ordered = [...sessions].sort((a, b) => {
                const an = (a?.name || '').toLowerCase();
                const bn = (b?.name || '').toLowerCase();
                const aHit = target && an.includes(target.split(' ')[0]) ? -1 : 0;
                const bHit = target && bn.includes(target.split(' ')[0]) ? -1 : 0;
                return aHit - bHit;
            });

            for (const session of ordered) {
                if (!session?.id) continue;
                if (opened || directHit) return null;
                try {
                    const flightsRes = await fetch(`https://site--acars-backend--6dmjph8ltlhv.code.run/flights/${session.id}`);
                    if (!flightsRes.ok) continue;
                    const flightsJson = await flightsRes.json();
                    const flights = flightsJson?.flights || flightsJson?.data || (Array.isArray(flightsJson) ? flightsJson : []);
                    const match = flights.find(f => f && f.flightId === effectiveFlightId);
                    if (!match || !match.position || match.position.lat == null || match.position.lon == null) continue;

                    if (session.name && typeof switchServer === 'function' && session.name !== currentServerName) {
                        switchServer(session.name);
                    }
                    directHit = { feature: buildSyntheticFeature(match, sharePayload?.communityImageUrl), server: session.name || '' };
                    return directHit;
                } catch (_) { /* try next session */ }
            }
        } catch (err) {
            console.warn('consumeShareLinkParam: direct fetch failed', err);
        } finally {
            directInFlight = false;
        }
        return null;
    };

    // Fire the first REST attempt right away so it runs in parallel with the
    // socket boot. Subsequent attempts are scheduled inside the poll loop.
    tryDirectLookup();

    // 3) Poll the live socket cache (primary path once the socket is up) AND
    //    re-fire the REST lookup every few seconds to catch the case where
    //    the socket and REST are both lagging.
    const POLL_INTERVAL_MS = 500;
    const REST_RETRY_INTERVAL_MS = 4000;
    const TOTAL_BUDGET_MS = 60000;
    const startedAt = Date.now();
    let lastRestAttemptAt = Date.now();
    let progressed = false;

    while (Date.now() - startedAt < TOTAL_BUDGET_MS) {
        if (opened && (typeof currentMapFeatures !== 'undefined') && currentMapFeatures[effectiveFlightId]) {
            // Window is up and the socket is now driving updates — we're done.
            dismissShareLoadingOverlay();
            return;
        }

        const feature = (typeof currentMapFeatures !== 'undefined') ? currentMapFeatures[effectiveFlightId] : null;
        if (feature && feature.properties && !opened) {
            await openFromFeature(feature, { seedCache: false });
            return;
        }

        if (directHit && directHit.feature && !opened) {
            await openFromFeature(directHit.feature);
            return;
        }

        // Re-try the REST lookup periodically while we wait.
        if (!directHit && !directInFlight && Date.now() - lastRestAttemptAt >= REST_RETRY_INTERVAL_MS) {
            lastRestAttemptAt = Date.now();
            tryDirectLookup();
        }

        // Once the live feed starts producing features, update the overlay so
        // the user knows we're actively searching the cache rather than stuck.
        if (!progressed && typeof currentMapFeatures !== 'undefined' && Object.keys(currentMapFeatures).length > 0) {
            progressed = true;
            updateShareLoadingOverlay(null, 'Live feed online — locating flight…');
        }

        await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
    }

    // 4) Budget exhausted. One last check before declaring defeat.
    if (!opened) {
        const lateFeature = (typeof currentMapFeatures !== 'undefined') ? currentMapFeatures[effectiveFlightId] : null;
        if (lateFeature && lateFeature.properties) {
            await openFromFeature(lateFeature, { seedCache: false });
        } else if (directHit && directHit.feature) {
            await openFromFeature(directHit.feature);
        }
    }

    // Only warn if we genuinely couldn't open anything. If the snapshot
    // already put the window up, the user is looking at the flight — don't
    // contradict that with a "flight ended" toast.
    if (!opened) {
        dismissShareLoadingOverlay();
        if (typeof showNotification === 'function') {
            showNotification("Couldn't load this flight — the pilot may have signed off.", 'warning');
        }
    }
}

if (typeof window !== 'undefined') {
    if (document.readyState === 'complete' || document.readyState === 'interactive') {
        // Defer one tick so the rest of the bootstrap finishes wiring.
        setTimeout(consumeShareLinkParam, 0);
    } else {
        window.addEventListener('load', () => setTimeout(consumeShareLinkParam, 0), { once: true });
    }
}

function updateTripCardRealtime() {
    if (!currentFlightInWindow || !currentMapFeatures[currentFlightInWindow]) return;

    const feature = currentMapFeatures[currentFlightInWindow];
    const props = feature.properties;
    const pos = typeof props.position === 'string' ? JSON.parse(props.position || '{}') : (props.position || {});
    const ui = document.getElementById('trip-card-takeover');
    if (!ui) return;

    // Apply Background Image to the card layer directly
    const bgLayer = ui.querySelector('.tc-bg-layer');
    if (bgLayer) {
        const fallbackImg = '/CommunityPlanes/default.png';
        if (props.communityImageUrl) {
            bgLayer.style.backgroundImage = `url('${props.communityImageUrl}'), url('${fallbackImg}')`;
        } else {
            bgLayer.style.backgroundImage = `url('${fallbackImg}')`;
        }
    }

    ui.querySelector('.tc-callsign').textContent = props.callsign || 'N/A';
    ui.querySelector('.tc-pilot').textContent = (props.username || 'Unknown').toUpperCase();
    ui.querySelector('.tc-alt').textContent = Math.round(pos.alt_ft || 0).toLocaleString();
    ui.querySelector('.tc-spd').textContent = Math.round(pos.gs_kt || 0).toString();
    
    const acData = (typeof props.aircraft === 'string') ? JSON.parse(props.aircraft || '{}') : (props.aircraft || {});
    const acName = acData.aircraftName || props.aircraftName || 'Unknown Type';
    const livName = acData.liveryName || props.liveryName || '';
    
    ui.querySelector('.tc-ac').textContent = `${acName} • ${livName}`;

    const dep = props.departureIcao || '???';
    const arr = props.arrivalIcao || '???';
    ui.querySelector('.tc-icao.origin').textContent = dep;
    ui.querySelector('.tc-icao.destination').textContent = arr;

    // Route Progress Bar Logic
    let progressPercent = 0;
    if (dep !== '???' && arr !== '???') {
        const depData = typeof airportsData !== 'undefined' ? airportsData[dep] : null;
        const arrData = typeof airportsData !== 'undefined' ? airportsData[arr] : null;
        if (depData && arrData && pos.lat) {
            try {
                const totalDist = typeof getDistanceKm === 'function' ? getDistanceKm(depData.lat, depData.lon, arrData.lat, arrData.lon) : 0;
                const remainingDist = typeof getDistanceKm === 'function' ? getDistanceKm(pos.lat, pos.lon, arrData.lat, arrData.lon) : 0;
                if (totalDist > 0) {
                    progressPercent = Math.max(0, Math.min(100, (1 - (remainingDist / totalDist)) * 100));
                }
            } catch(err) {}
        }
    }
    
    const displayPercent = Math.max(0, Math.min(100, progressPercent));
    const progressBar = ui.querySelector('.tc-progress-bar');
    const planeIcon = ui.querySelector('.tc-plane-icon');
    
    if (progressBar) progressBar.style.width = `${displayPercent}%`;
    if (planeIcon) planeIcon.style.left = `${displayPercent}%`;

    // Airline Logo Handling
    const words = livName.trim().split(/\s+/);
    let logoName = words.length > 1 && /[^a-zA-Z0-9]/.test(words[1]) ? words[0] : (words[0] + (words[1] ? ' ' + words[1] : ''));
    const sanitizedLogoName = logoName.toLowerCase().replace(/[^a-z0-9\s]/g, '').replace(/\s+/g, '_');
    const logoImg = ui.querySelector('.tc-logo');
    if (logoImg) {
        const img = new Image();
        img.onload = () => {
            logoImg.src = img.src;
            logoImg.style.display = 'block';
        };
        img.onerror = () => {
            logoImg.style.display = 'none';
        };
        img.src = `Images/airline_logos/${sanitizedLogoName}.png`;
    }
}
    
/**
 * Categorized search input handler.
 * Delegates ranking to window.GlobalSearchEngine and renders three sections:
 * Live flights, Airports, Airlines.
 */
function handleSearchInput(searchText) {
    const dropdown = document.getElementById('search-results-dropdown');
    if (!dropdown) return;

    if (!searchText || searchText.length < 2) {
        dropdown.innerHTML = '';
        dropdown.style.display = 'none';
        const searchBar = document.querySelector('#sector-ops-search-container .search-bar-container');
        if (searchBar) searchBar.classList.remove('has-results');
        return;
    }

    const results = runGlobalSearch(searchText);
    renderSearchResultsDropdown(results);
}

/**
 * Public helper: runs the categorized search using the live in-page state
 * (airportsData + currentMapFeatures). Other UI modules (e.g. landingUI's
 * blade search) call this so they don't need their own copy of the data.
 */
function runGlobalSearch(query) {
    const engine = window.GlobalSearchEngine;
    if (!engine) return { flights: [], airports: [], airlines: [], query: query || '' };
    return engine.runSearch(query, {
        airportsData: airportsData,
        flights: Object.values(currentMapFeatures),
    });
}
window.runGlobalSearch = runGlobalSearch;

function escapeHtml(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function shortenAircraftType(acName) {
    if (!acName) return '';
    let s = acName.split(' ')[0].substring(0, 4).toUpperCase();
    if (acName.includes('777')) s = 'B77W';
    else if (acName.includes('737')) s = 'B737';
    else if (acName.includes('320')) s = 'A320';
    else if (acName.includes('321')) s = 'A321';
    else if (acName.includes('350')) s = 'A350';
    else if (acName.includes('380')) s = 'A380';
    else if (acName.includes('787')) s = 'B787';
    else if (acName.includes('747')) s = 'B747';
    else if (acName.includes('CRJ')) s = 'CRJ';
    else if (acName.includes('Dash')) s = 'DH8D';
    return s;
}

function renderFlightRow(entry) {
    const feature = entry.feature;
    const props = feature.properties || {};
    const coords = feature.geometry && feature.geometry.coordinates;
    const acData = (typeof props.aircraft === 'string') ? (() => { try { return JSON.parse(props.aircraft); } catch { return {}; } })() : (props.aircraft || {});
    const acName = acData.aircraftName || props.aircraftName || 'Unknown';
    const livName = acData.liveryName || props.liveryName || 'Generic';
    const shortType = shortenAircraftType(acName);
    const altDisplay = props.altitude ? Math.round(props.altitude).toLocaleString() : '0';

    const propsString = JSON.stringify(props).replace(/'/g, '&apos;').replace(/"/g, '&quot;');
    const coordsString = JSON.stringify(coords || []);

    return `
        <div class="search-result-item"
             onclick="onSearchResultClick(this)"
             data-flight-id="${escapeHtml(props.flightId)}"
             data-coordinates='${coordsString}'
             data-properties='${propsString}'>
            <div class="search-result-icon-box">
                <i class="fa-solid fa-plane"></i>
            </div>
            <div class="search-result-info">
                <strong>${escapeHtml(props.callsign || '—')}${shortType ? ` <span style="font-size:0.7rem;color:#9fa8da;font-weight:500;">${escapeHtml(shortType)}</span>` : ''}</strong>
                <small>${escapeHtml(props.username || '')}${livName ? ` • ${escapeHtml(livName)}` : ''}</small>
            </div>
            <div class="search-result-meta">${altDisplay} ft</div>
        </div>
    `;
}

function renderAirportRow(entry) {
    const a = entry.airport;
    return `
        <div class="search-result-item"
             onclick="onAirportSearchResultClick(this)"
             data-icao="${escapeHtml(a.icao)}"
             data-lat="${a.lat}"
             data-lon="${a.lon}">
            <div class="search-result-icon-box airport-box">
                <i class="fa-solid fa-tower-control"></i>
            </div>
            <div class="search-result-info">
                <strong>${escapeHtml(a.icao)} <span style="font-size:0.75rem;color:#9fa8da;font-weight:500;">${escapeHtml(a.country || '')}</span></strong>
                <small>${escapeHtml(a.name || '')}</small>
            </div>
        </div>
    `;
}

function renderAirlineRow(entry) {
    return `
        <div class="search-result-item"
             onclick="onAirlineSearchResultClick(this)"
             data-livery="${escapeHtml(entry.name)}">
            <div class="search-result-icon-box airline-box">
                <i class="fa-solid fa-plane-departure"></i>
            </div>
            <div class="search-result-info">
                <strong>${escapeHtml(entry.name)}</strong>
                <small>${entry.count} active flight${entry.count === 1 ? '' : 's'}</small>
            </div>
        </div>
    `;
}

function renderSection(title, rows, emptyHidden = true) {
    if (!rows.length && emptyHidden) return '';
    const body = rows.length
        ? rows.join('')
        : `<div class="search-results-empty">No matches</div>`;
    return `
        <div class="search-results-section">
            <div class="search-results-header"><span>${title}</span><span class="count">${rows.length || ''}</span></div>
            ${body}
        </div>
    `;
}

/**
 * Renders categorized search results: flights / airports / airlines.
 * Accepts the engine output: { flights, airports, airlines }.
 */
function renderSearchResultsDropdown(results) {
    const dropdown = document.getElementById('search-results-dropdown');
    const searchBar = document.querySelector('#sector-ops-search-container .search-bar-container');
    if (!dropdown || !searchBar) return;

    dropdown.innerHTML = '';

    const flights = (results && results.flights) || [];
    const airports = (results && results.airports) || [];
    const airlines = (results && results.airlines) || [];

    if (!flights.length && !airports.length && !airlines.length) {
        dropdown.innerHTML = `
            <div style="padding: 24px 16px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; color: #94a3b8; opacity: 0.8;">
                <i class="fa-solid fa-magnifying-glass" style="font-size: 1.2rem;"></i>
                <span style="font-size: 0.85rem; font-weight: 500;">No matches found</span>
            </div>
        `;
        dropdown.style.display = 'block';
        searchBar.classList.add('has-results');
        return;
    }

    const html = [
        renderSection('Live flights', flights.map(renderFlightRow)),
        renderSection('Airports', airports.map(renderAirportRow)),
        renderSection('Airlines', airlines.map(renderAirlineRow)),
    ].join('');

    dropdown.innerHTML = html;
    dropdown.style.display = 'block';
    searchBar.classList.add('has-results');
}


function onSearchResultClick(arg1, arg2, arg3) {
        let coordinates;
        let props;

        console.log("[Flight] onSearchResultClick received:", arg1);

        if (arg1 instanceof HTMLElement) {
            try {
                coordinates = JSON.parse(arg1.dataset.coordinates);
                props = JSON.parse(arg1.dataset.properties);
            } catch (e) {
                console.error("onSearchResultClick: Failed to parse element data.", e);
                return;
            }
        } else {
            const flightId = arg1;
            coordinates = [arg3, arg2]; 
            
            const feature = currentMapFeatures[flightId];
            if (feature) {
                props = feature.properties;
            } else {
                console.error(`onSearchResultClick: Flight ${flightId} not found in map cache.`);
                return;
            }
        }

        const dropdown = document.getElementById('search-results-dropdown');
        const searchInput = document.getElementById('sector-ops-search-input');

        if (dropdown) dropdown.innerHTML = '';
        if (searchInput) {
            searchInput.value = '';
            searchInput.blur();
        }
        const _mapWrap = document.getElementById('sector-ops-map-fullscreen');
        if (_mapWrap && _mapWrap.classList.contains('mobile-search-open')) {
            _mapWrap.classList.remove('mobile-search-open');
        }

        sectorOpsMap.flyTo({
            center: coordinates,
            zoom: 9,
            essential: true
        });

        let flightProps;
        try {
            flightProps = {
                ...props,
                position: typeof props.position === 'string' ? JSON.parse(props.position) : props.position,
                aircraft: typeof props.aircraft === 'string' ? JSON.parse(props.aircraft) : props.aircraft
            };
        } catch (err) {
            console.error('onSearchResultClick: Nested property parse failed:', err);
            flightProps = { ...props };
        }
        
        if (!flightProps || !flightProps.position) return;
        
        getValidSessionId().then(sessionId => {
            handleAircraftClick(flightProps, sessionId);
        });
    }

    // CRITICAL: Make function globally available to landingUI.js
    window.onSearchResultClick = onSearchResultClick;

function _closeSearchAfterPick() {
    const dropdown = document.getElementById('search-results-dropdown');
    const searchInput = document.getElementById('sector-ops-search-input');
    const searchBar = document.querySelector('#sector-ops-search-container .search-bar-container');
    if (dropdown) {
        dropdown.innerHTML = '';
        dropdown.style.display = 'none';
    }
    if (searchInput) {
        searchInput.value = '';
        searchInput.blur();
    }
    if (searchBar) searchBar.classList.remove('has-results');
    // Close mobile overlay if open
    const mapContainer = document.getElementById('sector-ops-map-fullscreen');
    if (mapContainer && mapContainer.classList.contains('mobile-search-open')) {
        mapContainer.classList.remove('mobile-search-open');
    }
}

function onAirportSearchResultClick(arg) {
    // Accept either a clicked DOM element (with data-icao/lat/lon) or a plain
    // {icao, lat, lon} object so other UI modules can call this without
    // synthesizing a fake element. handleAirportClick lives inside this IIFE,
    // so external callers can't reach it directly.
    let icao, lat, lon;
    if (arg && arg instanceof HTMLElement) {
        icao = arg.dataset.icao;
        lat = parseFloat(arg.dataset.lat);
        lon = parseFloat(arg.dataset.lon);
    } else if (arg && typeof arg === 'object') {
        icao = arg.icao;
        lat = parseFloat(arg.lat);
        lon = parseFloat(arg.lon);
    } else {
        return;
    }
    if (!icao) return;

    _closeSearchAfterPick();

    if (Number.isFinite(lat) && Number.isFinite(lon) && sectorOpsMap) {
        sectorOpsMap.flyTo({ center: [lon, lat], zoom: 11, essential: true });
    }
    if (typeof handleAirportClick === 'function') {
        handleAirportClick(icao);
    }
}
window.onAirportSearchResultClick = onAirportSearchResultClick;

function onAirlineSearchResultClick(arg) {
    // Accept either a clicked DOM element (with data-livery) or a raw livery string,
    // so other UI modules can call this without synthesizing a fake element.
    let livery;
    if (typeof arg === 'string') {
        livery = arg;
    } else if (arg instanceof HTMLElement) {
        livery = arg.dataset.livery;
    } else {
        return;
    }
    if (!livery) return;

    _closeSearchAfterPick();

    // Collect every live flight matching this airline, then fit the map to them.
    const matches = [];
    const target = livery.toLowerCase();
    for (const id in currentMapFeatures) {
        const f = currentMapFeatures[id];
        const p = f && f.properties;
        if (!p) continue;
        let acData = p.aircraft;
        if (typeof acData === 'string') {
            try { acData = JSON.parse(acData); } catch { acData = {}; }
        }
        const liv = ((acData && acData.liveryName) || p.liveryName || '').toLowerCase();
        if (liv === target) matches.push(f);
    }

    if (!matches.length || !sectorOpsMap) return;

    if (matches.length === 1) {
        const c = matches[0].geometry && matches[0].geometry.coordinates;
        if (c) sectorOpsMap.flyTo({ center: c, zoom: 7, essential: true });
        return;
    }

    // Compute bounding box of matching flights.
    let minLon = Infinity, minLat = Infinity, maxLon = -Infinity, maxLat = -Infinity;
    for (const f of matches) {
        const c = f.geometry && f.geometry.coordinates;
        if (!c) continue;
        const [lon, lat] = c;
        if (lon < minLon) minLon = lon;
        if (lat < minLat) minLat = lat;
        if (lon > maxLon) maxLon = lon;
        if (lat > maxLat) maxLat = lat;
    }
    if (Number.isFinite(minLon)) {
        try {
            sectorOpsMap.fitBounds([[minLon, minLat], [maxLon, maxLat]], {
                padding: 80,
                maxZoom: 6,
                duration: 1200,
            });
        } catch (_) {}
    }

    if (typeof showNotification === 'function') {
        showNotification(`Showing ${matches.length} live ${livery} flight${matches.length === 1 ? '' : 's'}.`, 'info');
    }
}
window.onAirlineSearchResultClick = onAirlineSearchResultClick;

const AIRCRAFT_LABEL_LAYER_ID = 'sector-ops-live-flights-labels';

// Default rows when no saved config exists yet. Mirrors the mapFilters
// default above so the on-map tag and the settings preview always agree.
const DEFAULT_LABEL_CONFIG = {
    airlineLogo: true,
    callsign: true,
    aircraftType: true,
    altSpeed: true,
    route: false,
    registration: false,
    pilot: false
};

/* ============================================================
   AIRLINE LOGOS ON FLIGHT LABELS
   Logos are fetched on demand from community-maintained ICAO-keyed
   sets on GitHub (raw CDN, CORS-enabled) and composited onto a
   uniform white badge so every brand mark renders unmodified — no
   recoloring, stretching or cropping — in line with airline
   brand-usage norms.

   LEGAL: airline names and logos are trademarks of their respective
   owners. They are displayed purely for entertainment, to represent
   the airline of a virtual Infinite Flight flight. Inflight is not
   affiliated with, endorsed by, or sponsored by any airline. The
   matching user-facing disclaimer lives next to the label toggle in
   both settings UIs; takedown requests: inflightcustomer@gmail.com.
   Honored takedowns are pushed through the ACARS backend blocklist
   below, which suppresses a logo immediately on all installs.
   ============================================================ */
const AIRLINE_LOGO_IMAGE_PREFIX = 'airline-logo-';
// Tried in order until one returns a usable PNG for the ICAO code. The
// RadarBox banners are wide full-wordmark logos (the Plane Finder look);
// the square sets backfill the handful of airlines with no banner.
const AIRLINE_LOGO_SOURCES = [
    icao => `https://raw.githubusercontent.com/Jxck-S/airline-logos/main/radarbox_banners/${icao}.png`,
    icao => `https://raw.githubusercontent.com/sexym0nk3y/airline-logos/main/logos/${icao}.png`,
    icao => `https://raw.githubusercontent.com/Jxck-S/airline-logos/main/flightaware_logos/${icao}.png`
];

// --- Remote takedown blocklist -------------------------------------------
// ICAO codes whose logos must NOT be shown, served by the ACARS backend so
// an airline's removal request takes effect immediately — no App Store
// update needed. Expected response: ["AAL", ...] or { "blocked": ["AAL"] }.
// Cached in localStorage and fail-open: backend unreachable = last known
// list (or none on first run).
const AIRLINE_LOGO_BLOCKLIST_URL = ACARS_SOCKET_URL + '/api/airline-logos/blocklist';
const AIRLINE_LOGO_BLOCKLIST_CACHE_KEY = 'airlineLogoBlocklist';
const airlineLogoBlocklist = new Set();
try {
    (JSON.parse(localStorage.getItem(AIRLINE_LOGO_BLOCKLIST_CACHE_KEY)) || [])
        .forEach(code => airlineLogoBlocklist.add(code));
} catch (e) {}

let airlineLogoBlocklistFetched = false;
async function loadAirlineLogoBlocklist(map) {
    if (airlineLogoBlocklistFetched) return;
    airlineLogoBlocklistFetched = true; // claim before awaiting so parallel calls no-op
    try {
        const res = await fetch(AIRLINE_LOGO_BLOCKLIST_URL);
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const data = await res.json();
        const list = (Array.isArray(data) ? data : (data && Array.isArray(data.blocked) ? data.blocked : []))
            .map(c => String(c).trim().toUpperCase())
            .filter(c => /^[A-Z]{3}$/.test(c));
        airlineLogoBlocklist.clear();
        list.forEach(c => airlineLogoBlocklist.add(c));
        try { localStorage.setItem(AIRLINE_LOGO_BLOCKLIST_CACHE_KEY, JSON.stringify(list)); } catch (e) {}
        // Swap any badge that rendered before the list arrived for a blank.
        if (map) {
            list.forEach(code => {
                const id = AIRLINE_LOGO_IMAGE_PREFIX + code;
                try {
                    if (map.hasImage(id)) {
                        map.removeImage(id);
                        map.addImage(id, { width: 1, height: 1, data: new Uint8Array(4) });
                    }
                } catch (e) {}
            });
        }
    } catch (e) {
        // Allow a retry on the next label-style application.
        airlineLogoBlocklistFetched = false;
    }
}

// Livery/airline display name -> ICAO code (the key format of the logo
// sets above). Keys are normalized: lowercase, punctuation stripped.
// Matching is longest-prefix, so "Delta Air Lines (SkyTeam)" still hits
// "delta air lines" and "Air Canada Rouge" falls back to "air canada".
// Every code below was verified to resolve against the logo sources.
const AIRLINE_LIVERY_ICAO = {
    // North America
    'american airlines': 'AAL', 'american': 'AAL',
    'delta air lines': 'DAL', 'delta': 'DAL',
    'united airlines': 'UAL', 'united': 'UAL',
    'southwest airlines': 'SWA', 'southwest': 'SWA',
    'alaska airlines': 'ASA', 'jetblue airways': 'JBU', 'jetblue': 'JBU',
    'spirit airlines': 'NKS', 'frontier airlines': 'FFT', 'allegiant air': 'AAY',
    'hawaiian airlines': 'HAL', 'sun country airlines': 'SCX',
    'breeze airways': 'MXY', 'avelo airlines': 'VXP',
    'fedex express': 'FDX', 'fedex': 'FDX', 'ups airlines': 'UPS', 'ups': 'UPS',
    'atlas air': 'GTI', 'kalitta air': 'CKS', 'omni air international': 'OAE',
    'national airlines': 'NCR',
    'air canada': 'ACA', 'westjet': 'WJA', 'air transat': 'TSC',
    'porter airlines': 'POE', 'flair airlines': 'FLE', 'cargojet': 'CJT',
    'sunwing airlines': 'SWG',
    'us airways': 'AWE', 'continental airlines': 'COA', 'northwest airlines': 'NWA',
    'virgin america': 'VRD',
    // Latin America & Caribbean
    'aeromexico': 'AMX', 'volaris': 'VOI', 'vivaaerobus': 'VIV',
    'copa airlines': 'CMP', 'avianca': 'AVA', 'latam airlines': 'LAN', 'latam': 'LAN',
    'gol linhas aereas': 'GLO', 'gol': 'GLO', 'azul': 'AZU',
    'aerolineas argentinas': 'ARG', 'jetsmart': 'JAT', 'sky airline': 'SKU',
    'caribbean airlines': 'BWA', 'boliviana de aviacion': 'BOV',
    // Europe
    'british airways': 'BAW', 'virgin atlantic': 'VIR',
    'easyjet': 'EZY', 'ryanair': 'RYR', 'jet2': 'EXS', 'jet2com': 'EXS',
    'tui airways': 'TOM', 'tui': 'TOM', 'wizz air': 'WZZ',
    'lufthansa cargo': 'GEC', 'lufthansa': 'DLH',
    'eurowings discover': 'OCN', 'discover airlines': 'OCN', 'discover': 'OCN',
    'eurowings': 'EWG', 'condor': 'CFG', 'austrian airlines': 'AUA',
    'swiss international air lines': 'SWR', 'swiss': 'SWR',
    'edelweiss air': 'EDW', 'brussels airlines': 'BEL',
    'klm royal dutch airlines': 'KLM', 'klm': 'KLM', 'transavia': 'TRA',
    'air france': 'AFR', 'french bee': 'FBU', 'corsair': 'CRL',
    'iberia': 'IBE', 'vueling': 'VLG', 'air europa': 'AEA',
    'tap air portugal': 'TAP', 'tap portugal': 'TAP',
    'scandinavian airlines': 'SAS', 'sas': 'SAS',
    'norwegian air shuttle': 'NAX', 'norwegian': 'NAX',
    'finnair': 'FIN', 'icelandair': 'ICE', 'play': 'FPY',
    'aer lingus': 'EIN', 'ita airways': 'ITY', 'alitalia': 'AZA',
    'aegean airlines': 'AEE', 'lot polish airlines': 'LOT',
    'turkish airlines': 'THY', 'pegasus airlines': 'PGT', 'aeroflot': 'AFL',
    'airbaltic': 'BTI', 'air serbia': 'ASL', 'croatia airlines': 'CTN',
    'luxair': 'LGL', 'volotea': 'VOE', 'sky express': 'SEH',
    'norse atlantic airways': 'NBT', 'air berlin': 'BER',
    'air astana': 'KZR', 'uzbekistan airways': 'UZB',
    'azerbaijan airlines': 'AHY',
    // Middle East & Africa
    'emirates': 'UAE', 'etihad airways': 'ETD', 'etihad': 'ETD',
    'qatar airways': 'QTR', 'saudia': 'SVA', 'flynas': 'KNE', 'flydubai': 'FDB',
    'gulf air': 'GFA', 'oman air': 'OMA', 'kuwait airways': 'KAC',
    'el al': 'ELY', 'royal jordanian': 'RJA', 'middle east airlines': 'MEA',
    'air arabia': 'ABY', 'jazeera airways': 'JZR', 'salamair': 'OMS',
    'egyptair': 'MSR', 'ethiopian airlines': 'ETH', 'kenya airways': 'KQA',
    'south african airways': 'SAA', 'royal air maroc': 'RAM',
    'air algerie': 'DAH', 'rwandair': 'RWD', 'air mauritius': 'MAU',
    'taag angola airlines': 'DTA',
    // Asia
    'singapore airlines': 'SIA', 'scoot': 'TGW',
    'malaysia airlines': 'MAS', 'airasia': 'AXM', 'garuda indonesia': 'GIA',
    'lion air': 'LNI', 'batik air': 'BTK',
    'thai airways': 'THA', 'bangkok airways': 'BKP',
    'vietjet air': 'VJC', 'vietjet': 'VJC', 'vietnam airlines': 'HVN',
    'philippine airlines': 'PAL', 'cebu pacific': 'CEB',
    'cathay pacific': 'CPA', 'hong kong express': 'HKE', 'hk express': 'HKE',
    'china airlines': 'CAL', 'eva air': 'EVA', 'starlux airlines': 'SJX',
    'japan airlines': 'JAL', 'all nippon airways': 'ANA', 'ana': 'ANA',
    'zipair tokyo': 'TZP', 'zipair': 'TZP', 'peach aviation': 'APJ', 'peach': 'APJ',
    'korean air': 'KAL', 'asiana airlines': 'AAR', 'jeju air': 'JJA',
    'air china': 'CCA', 'china eastern airlines': 'CES', 'china eastern': 'CES',
    'china southern airlines': 'CSN', 'china southern': 'CSN',
    'xiamen air': 'CXA', 'xiamenair': 'CXA', 'hainan airlines': 'CHH',
    'air india express': 'AXB', 'air india': 'AIC', 'indigo': 'IGO',
    'vistara': 'VTI', 'spicejet': 'SEJ', 'akasa air': 'AKJ',
    'srilankan airlines': 'ALK', 'pakistan international airlines': 'PIA',
    // Oceania
    'qantas': 'QFA', 'jetstar airways': 'JST', 'jetstar': 'JST',
    'virgin australia': 'VOZ', 'air new zealand': 'ANZ',
    'fiji airways': 'FJI', 'air tahiti nui': 'THT'
};

/**
 * Derives the airline's ICAO code from a livery name ("American Airlines",
 * "Discover", "Singapore Airlines (Star Alliance)"…). Callsigns in Infinite
 * Flight are free-form, so the livery is the only reliable airline signal.
 * Liveries without a match (GA, military, generic) return null = no logo.
 */
function getAirlineIcaoFromLivery(liveryName) {
    if (!liveryName) return null;
    const name = String(liveryName).toLowerCase()
        .replace(/\(.*?\)/g, ' ')        // drop variant suffixes: "(Retro)", "(Star Alliance)"
        .replace(/[^a-z0-9\s]/g, '')     // strip punctuation: "Jet2.com" -> "jet2com"
        .replace(/\s+/g, ' ')
        .trim();
    if (!name) return null;
    const words = name.split(' ');
    // Longest prefix wins so "air india express" beats "air india".
    for (let n = Math.min(words.length, 5); n >= 1; n--) {
        const icao = AIRLINE_LIVERY_ICAO[words.slice(0, n).join(' ')];
        if (icao) return airlineLogoBlocklist.has(icao) ? null : icao;
    }
    return null;
}
window.getAirlineIcaoFromLivery = getAirlineIcaoFromLivery;

/**
 * `icon-image` expression for the label layer: maps each feature's
 * airlineIcao onto a dynamically-loaded badge image ('' = no icon).
 */
function getAircraftLabelIconImage() {
    const cfg = Object.assign({}, DEFAULT_LABEL_CONFIG, mapFilters.labelConfig || {});
    if (!cfg.airlineLogo) return '';
    return ['case',
        ['==', ['coalesce', ['get', 'airlineIcao'], ''], ''],
        '',
        ['concat', AIRLINE_LOGO_IMAGE_PREFIX, ['get', 'airlineIcao']]
    ];
}

/**
 * Data-driven text-offset: only flights that actually have a logo pill get
 * the extra clearance under the plane — GA/military/blocked-airline labels
 * keep the tight default gap instead of an empty hole.
 */
function getAircraftLabelTextOffset() {
    const cfg = Object.assign({}, DEFAULT_LABEL_CONFIG, mapFilters.labelConfig || {});
    // Offsets are in ems of the zoom-graded text size, so each stop's em is
    // back-computed to keep the physical gap constant: ~16px under the plane
    // for plain text, ~4px under the logo pill when one is shown.
    const atZoom = (plainEm, pillEm) => cfg.airlineLogo
        ? ['case',
            ['==', ['coalesce', ['get', 'airlineIcao'], ''], ''],
            ['literal', [0, plainEm]],
            ['literal', [0, pillEm]]]
        : ['literal', [0, plainEm]];
    return ['interpolate', ['linear'], ['zoom'],
        6.5, atZoom(1.9, 3.2),
        12, atZoom(1.7, 3.3),
        16, atZoom(1.5, 3.7)
    ];
}

/**
 * Zoom-graded sizes: labels stay compact while browsing the map and only
 * grow once the user zooms well in (≳ z12). `scale` is the user's
 * label-size multiplier from the designer (0.8–1.4).
 */
function getAircraftLabelTextSize(scale) {
    return ['interpolate', ['linear'], ['zoom'],
        6.5, 8.5 * scale,
        12, 9.5 * scale,
        16, 12.5 * scale
    ];
}
function getAircraftLabelIconSize(scale) {
    return ['interpolate', ['linear'], ['zoom'],
        6.5, 0.52 * scale,
        12, 0.62 * scale,
        16, 0.95 * scale
    ];
}

// Draws a fetched logo onto a white rounded pill (2x backing scale). The
// pill height is fixed and its width follows the wordmark's aspect ratio —
// wide banners get a wide pill, square fallback logos a compact chip — so
// every brand mark renders unmodified, contain-fit on a light background
// (these logos are full-color marks designed for light surfaces).
function composeAirlineLogoBadge(bitmap) {
    const SCALE = 2;
    const H = 28 * SCALE;
    const PAD_X = 7 * SCALE, PAD_Y = 5 * SCALE;
    const innerH = H - PAD_Y * 2;
    const fitW = bitmap.width * (innerH / bitmap.height);
    const innerW = Math.max(innerH, Math.min(96 * SCALE, fitW));
    const W = Math.round(innerW + PAD_X * 2);
    const R = 8 * SCALE;
    const canvas = document.createElement('canvas');
    canvas.width = W; canvas.height = H;
    const ctx = canvas.getContext('2d');
    ctx.beginPath();
    if (ctx.roundRect) {
        ctx.roundRect(0, 0, W, H, R);
    } else {
        ctx.moveTo(R, 0);
        ctx.arcTo(W, 0, W, H, R);
        ctx.arcTo(W, H, 0, H, R);
        ctx.arcTo(0, H, 0, 0, R);
        ctx.arcTo(0, 0, W, 0, R);
        ctx.closePath();
    }
    ctx.fillStyle = '#ffffff';
    ctx.fill();
    ctx.lineWidth = 3;
    ctx.strokeStyle = 'rgba(15, 23, 42, 0.35)';
    ctx.stroke();
    ctx.clip();
    // Contain-fit inside the padded box (ultra-wide banners shrink to fit).
    const boxW = W - PAD_X * 2, boxH = innerH;
    const s = Math.min(boxW / bitmap.width, boxH / bitmap.height);
    const w = bitmap.width * s, h = bitmap.height * s;
    ctx.drawImage(bitmap, (W - w) / 2, (H - h) / 2, w, h);
    return ctx.getImageData(0, 0, W, H);
}

/**
 * Lazy logo loading via MapLibre's styleimagemissing: the first time the
 * label layer asks for `airline-logo-XXX` we fetch + badge the PNG and add
 * it to the style. Failures register a transparent pixel so the map stops
 * re-requesting (and that airline just shows a text-only label).
 */
function registerAirlineLogoLoader(map) {
    if (map.__airlineLogoLoaderAttached) return;
    map.__airlineLogoLoaderAttached = true;
    loadAirlineLogoBlocklist(map);
    const requested = new Set();
    map.on('styleimagemissing', async (e) => {
        const id = (e && e.id) || '';
        if (!id.startsWith(AIRLINE_LOGO_IMAGE_PREFIX) || requested.has(id)) return;
        requested.add(id);
        const addTransparent = () => {
            try { if (!map.hasImage(id)) map.addImage(id, { width: 1, height: 1, data: new Uint8Array(4) }); } catch (err) {}
        };
        const icao = id.slice(AIRLINE_LOGO_IMAGE_PREFIX.length);
        if (!/^[A-Z]{3}$/.test(icao) || airlineLogoBlocklist.has(icao)) { addTransparent(); return; }
        for (const urlFor of AIRLINE_LOGO_SOURCES) {
            try {
                const res = await fetch(urlFor(icao));
                if (!res.ok) throw new Error('HTTP ' + res.status);
                const bitmap = await createImageBitmap(await res.blob());
                if (!map.hasImage(id)) map.addImage(id, composeAirlineLogoBadge(bitmap), { pixelRatio: 2 });
                return;
            } catch (err) { /* try the next source */ }
        }
        addTransparent();
    });
}

// Halo/text color palettes for the label themes. `contrast` is a pro-only
// high-legibility chip (dark text on a bright halo).
const AIRCRAFT_LABEL_THEMES = {
    default:  { text: '#ffffff', halo: 'rgba(15, 23, 42, 0.9)', haloWidth: 2 },
    cyan:     { text: '#7dd3fc', halo: 'rgba(8, 47, 73, 0.92)', haloWidth: 2 },
    amber:    { text: '#fcd34d', halo: 'rgba(69, 26, 3, 0.92)', haloWidth: 2 },
    mono:     { text: '#e4e4e7', halo: 'rgba(0, 0, 0, 0.85)',   haloWidth: 1.5 },
    contrast: { text: '#0b1120', halo: 'rgba(226, 232, 240, 0.95)', haloWidth: 2.4 }
};

/**
 * Builds the Mapbox GL `format` expression for the live-aircraft label from
 * the user's chosen rows (mapFilters.labelConfig). Each enabled row becomes a
 * line in the stacked tag, scaled relative to the layer's base text-size.
 */
function getAircraftLabelTextField() {
    const cfg = Object.assign({}, DEFAULT_LABEL_CONFIG, mapFilters.labelConfig || {});

    const rows = [];
    if (cfg.callsign)     rows.push({ expr: ['coalesce', ['get', 'callsign'], ''], scale: 1.15 });
    if (cfg.pilot)        rows.push({ expr: ['coalesce', ['get', 'username'], ''], scale: 0.82 });
    if (cfg.aircraftType) rows.push({ expr: ['coalesce', ['get', 'aircraftName'], ''], scale: 0.82 });
    if (cfg.registration) rows.push({ expr: ['coalesce', ['get', 'registration'], ''], scale: 0.78 });
    if (cfg.route) {
        rows.push({
            expr: ['concat',
                ['coalesce', ['get', 'departureIcao'], '----'], '  →  ',
                ['coalesce', ['get', 'arrivalIcao'], '----']],
            scale: 0.78
        });
    }
    if (cfg.altSpeed) {
        rows.push({
            expr: ['concat',
                ['to-string', ['coalesce', ['get', 'altitude'], 0]], ' ft  ·  ',
                ['to-string', ['coalesce', ['get', 'speed'], 0]], ' kts'],
            scale: 0.78
        });
    }

    // With every text row off: if the airline-logo badge is on, let the label
    // be logo-only (Plane Finder style); otherwise fall back to the callsign
    // so the tag never collapses to nothing.
    if (!rows.length) {
        if (cfg.airlineLogo) return '';
        rows.push({ expr: ['coalesce', ['get', 'callsign'], ''], scale: 1.15 });
    }

    const fmt = ['format'];
    rows.forEach((row, i) => {
        if (i > 0) fmt.push('\n', {});
        fmt.push(row.expr, { 'font-scale': row.scale });
    });
    return fmt;
}
window.getAircraftLabelTextField = getAircraftLabelTextField;

/**
 * Applies every live-aircraft label preference (visibility, chosen rows,
 * size, color theme) to the map layer in one pass. Safe to call before the
 * layer exists — it simply no-ops until the map is ready.
 */
function applyAircraftLabelStyle() {
    if (!sectorOpsMap || !sectorOpsMap.getLayer(AIRCRAFT_LABEL_LAYER_ID)) return;

    sectorOpsMap.setLayoutProperty(
        AIRCRAFT_LABEL_LAYER_ID,
        'visibility',
        mapFilters.showAircraftLabels ? 'visible' : 'none'
    );
    if (!mapFilters.showAircraftLabels) return;

    sectorOpsMap.setLayoutProperty(AIRCRAFT_LABEL_LAYER_ID, 'text-field', getAircraftLabelTextField());

    const scale = Math.min(1.6, Math.max(0.7, parseFloat(mapFilters.labelScale) || 1));
    sectorOpsMap.setLayoutProperty(AIRCRAFT_LABEL_LAYER_ID, 'text-size', getAircraftLabelTextSize(scale));

    const theme = AIRCRAFT_LABEL_THEMES[mapFilters.labelTheme] || AIRCRAFT_LABEL_THEMES.default;
    sectorOpsMap.setPaintProperty(AIRCRAFT_LABEL_LAYER_ID, 'text-color', theme.text);
    sectorOpsMap.setPaintProperty(AIRCRAFT_LABEL_LAYER_ID, 'text-halo-color', theme.halo);
    sectorOpsMap.setPaintProperty(AIRCRAFT_LABEL_LAYER_ID, 'text-halo-width', theme.haloWidth);

    // Airline logo pill tucked under the plane, with the text rows beneath
    // it (Plane Finder style). icon-offset is multiplied by icon-size and
    // text-offset is in ems of text-size, so both gaps track the label scale
    // and the pill/text never collide at any size.
    loadAirlineLogoBlocklist(sectorOpsMap); // no-op once fetched; retries after failures
    sectorOpsMap.setLayoutProperty(AIRCRAFT_LABEL_LAYER_ID, 'icon-image', getAircraftLabelIconImage());
    sectorOpsMap.setLayoutProperty(AIRCRAFT_LABEL_LAYER_ID, 'icon-size', getAircraftLabelIconSize(scale));
    sectorOpsMap.setLayoutProperty(AIRCRAFT_LABEL_LAYER_ID, 'icon-offset', [0, 16]);
    sectorOpsMap.setLayoutProperty(AIRCRAFT_LABEL_LAYER_ID, 'text-offset', getAircraftLabelTextOffset());
}
window.applyAircraftLabelStyle = applyAircraftLabelStyle;

// Back-compat alias — older call sites only toggled visibility; route them
// through the full style applier so row/size/theme changes take effect too.
function updateAircraftLabelVisibility() {
    applyAircraftLabelStyle();
}

/**
 * --- [UPDATED] "Pro Smooth" RainViewer Layer ---
 * Uses Source Clamping (maxzoom: 8) to force smooth interpolation
 * instead of pixelated blocks when zooming in.
 */
async function toggleWeatherLayer(show) {
    if (!sectorOpsMap) return;

    const SOURCE_ID = 'rainviewer-radar-source';
    const LAYER_ID = 'rainviewer-radar-layer';

    if (show && !isWeatherLayerAdded) {
        try {
            // 1. Fetch official configuration
            const res = await fetch('https://api.rainviewer.com/public/weather-maps.json');
            const data = await res.json();
            const host = data.host; 
            
            // Get the very latest frame
            const latestFrame = data.radar.past[data.radar.past.length - 1];
            const path = latestFrame.path;

            // --- SETTINGS ---
            // 512 = High DPI (Retina)
            // 4   = 'Titan' Color Scheme (Professional Aviation)
            // 1_1 = Smooth (1) + Snow (1)
            const tileUrl = `${host}${path}/512/{z}/{x}/{y}/4/1_1.png`;

            // 2. Add Source with "Clamped" Zoom
            sectorOpsMap.addSource(SOURCE_ID, {
                'type': 'raster',
                'tiles': [tileUrl],
                'tileSize': 512,
                
                // --- THE TRICK IS HERE ---
                // We tell Mapbox the server only has data up to zoom 8.
                // When you zoom past 8, Mapbox will stretch these tiles smoothly.
                'maxzoom': 8 
            });

            // 3. Add Layer
            sectorOpsMap.addLayer({
                'id': LAYER_ID,
                'type': 'raster',
                'source': SOURCE_ID,
                'paint': {
                    'raster-opacity': 0.65,       // Slightly transparent for modern look
                    'raster-resampling': 'linear', // FORCE smooth gradient scaling
                    'raster-fade-duration': 0
                }
            }, 'sector-ops-live-flights-layer'); // Draw underneath aircraft

            isWeatherLayerAdded = true;
            console.log(`Premium Smooth Radar layer added.`);

        } catch (error) {
            console.error("Failed to init weather layer:", error);
            showNotification('Could not load radar data.', 'error');
        }

    } else if (isWeatherLayerAdded) {
        const visibility = show ? 'visible' : 'none';
        if (sectorOpsMap.getLayer(LAYER_ID)) {
            sectorOpsMap.setLayoutProperty(LAYER_ID, 'visibility', visibility);
        }
    }
}

/**
 * --- [NEW] SIGMET Vector Layer (Volanta Style) ---
 * Fetches active aviation hazards (Turbulence, Icing, Convection).
 */
let isSigmetLayerAdded = false;

async function toggleSigmetLayer(show) {
    if (!sectorOpsMap) return;

    const SOURCE_ID = 'aviation-sigmet-source';
    const FILL_LAYER_ID = 'aviation-sigmet-fill';
    const LINE_LAYER_ID = 'aviation-sigmet-outline';

    if (show && !isSigmetLayerAdded) {
        try {
            // Fetch GeoJSON from NOAA Aviation Weather Center
            const response = await fetch('https://aviationweather.gov/api/data/isigmet?format=geojson');
            const geojson = await response.json();

            sectorOpsMap.addSource(SOURCE_ID, {
                'type': 'geojson',
                'data': geojson
            });

            // 1. Fill Layer (Transparent Colors)
            sectorOpsMap.addLayer({
                'id': FILL_LAYER_ID,
                'type': 'fill',
                'source': SOURCE_ID,
                'paint': {
                    'fill-color': [
                        'match',
                        ['get', 'hazard'],
                        'CONVECTIVE', '#ff0000', // Red for storms
                        'TURB', '#ffa500',       // Orange for turbulence
                        'ICING', '#00bfff',      // Blue for icing
                        '#888888'                // Fallback
                    ],
                    'fill-opacity': 0.20
                }
            }, 'sector-ops-live-flights-layer'); 

            // 2. Outline Layer (Solid Lines)
            sectorOpsMap.addLayer({
                'id': LINE_LAYER_ID,
                'type': 'line',
                'source': SOURCE_ID,
                'paint': {
                    'line-color': [
                        'match',
                        ['get', 'hazard'],
                        'CONVECTIVE', '#ff0000',
                        'TURB', '#ffa500',
                        'ICING', '#00bfff',
                        '#888888'
                    ],
                    'line-width': 1.5,
                    'line-opacity': 0.8
                }
            }, 'sector-ops-live-flights-layer');

            // 3. Click interaction for details
            sectorOpsMap.on('click', FILL_LAYER_ID, (e) => {
                const props = e.features[0].properties;
                new mapboxgl.Popup()
                    .setLngLat(e.lngLat)
                    .setHTML(`
                        <div style="color:#333; padding:5px;">
                            <strong>${props.hazard || 'SIGMET'}</strong><br>
                            <span style="font-size: 0.8em; color: #555;">${props.rawSigmet || 'No details'}</span>
                        </div>
                    `)
                    .addTo(sectorOpsMap);
            });

            isSigmetLayerAdded = true;
            console.log('SIGMET vector layer added.');

        } catch (error) {
            console.error('Failed to load SIGMETs:', error);
            // Fallback notification or silent fail
        }

    } else if (isSigmetLayerAdded) {
        const vis = show ? 'visible' : 'none';
        if (sectorOpsMap.getLayer(FILL_LAYER_ID)) sectorOpsMap.setLayoutProperty(FILL_LAYER_ID, 'visibility', vis);
        if (sectorOpsMap.getLayer(LINE_LAYER_ID)) sectorOpsMap.setLayoutProperty(LINE_LAYER_ID, 'visibility', vis);
    }
}

// Add this inside the document.addEventListener('DOMContentLoaded', async () => { ... }) block
window.addEventListener('serverChange', (e) => {
    const serverMapping = {
        'Expert': 'Expert Server',
        'Training': 'Training Server',
        'Casual': 'Casual Server'
    };
    const fullServerName = serverMapping[e.detail.server] || e.detail.server;
    
    // Call the existing switchServer function defined in flight.js
    if (typeof switchServer === 'function') {
        switchServer(fullServerName);
    }
});

function updateMapFilters() {
    if (!sectorOpsMap) return;

    // 1. Handle Projection Changes
    const currentProjection = sectorOpsMap.getProjection().name;
    const targetProjection = mapFilters.useFlatMap ? 'mercator' : 'globe';
    if (currentProjection !== targetProjection) {
        sectorOpsMap.setProjection(targetProjection);
    }

    // 2. Handle Map Style Changes (Dark/Light/Satellite/Pro)
    const styleUrls = {
        'dark': MAP_STYLE_DARK,
        'light': MAP_STYLE_LIGHT,
        'satellite': MAP_STYLE_SATELLITE,
        'outdoors': MAP_STYLE_OUTDOORS,
        'nav-dark': MAP_STYLE_NAV_DARK,
        'nav-light': MAP_STYLE_NAV_LIGHT,
        'traffic-night': MAP_STYLE_TRAFFIC_NIGHT,
        'traffic-day': MAP_STYLE_TRAFFIC_DAY
    };
    
    const targetStyle = styleUrls[mapFilters.mapStyle || 'dark'];

    if (currentFlightInWindow && liveTrailCache.has(currentFlightInWindow)) {
        FlownPath3D.updatePath(
            sectorOpsMap, 
            currentFlightInWindow, 
            liveTrailCache.get(currentFlightInWindow), 
            mapFilters.show3DPath 
        );
    }

    if (currentMapStyle !== targetStyle) {
        currentMapStyle = targetStyle;
        sectorOpsMap.setStyle(targetStyle);
    }

    if (window.globalNatTracks) {
        window.globalNatTracks.setOptions({
            showTracks: mapFilters.showNatTracks,
            showLabels: mapFilters.showNatLabels
        });
    }

    if (sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
        const iconSize = parseFloat(mapFilters.planeIconSize) || 0.05;

        // Re-apply icon-image + icon-color across both aircraft layers (SDF +
        // natural) and the hover layer in one place.
        applyAircraftLayerStyles();

        // Icon size is managed here (and by planeSizeController); keep both
        // aircraft layers in sync.
        sectorOpsMap.setLayoutProperty('sector-ops-live-flights-layer', 'icon-size', iconSize);
        if (sectorOpsMap.getLayer('sector-ops-live-flights-natural-layer')) {
            sectorOpsMap.setLayoutProperty('sector-ops-live-flights-natural-layer', 'icon-size', iconSize);
        }
        if (sectorOpsMap.getLayer('sector-ops-live-flights-hover-layer')) {
            sectorOpsMap.setLayoutProperty('sector-ops-live-flights-hover-layer', 'icon-size', iconSize);
        }
    }

    // 4. Existing Logic
    GroupFlightManager.toggle(mapFilters.showGroupFlights);
    GroupFlightManager.update(currentMapFeatures);

    updateAircraftLayerFilter();
    updateAircraftLabelVisibility();
    renderAirportMarkers();
    applyAtcBoundaryVisibility();
    refreshTerrainMode();
    updateToolbarButtonStates();
}

// Apply a visibility filter to BOTH aircraft layers (SDF + natural) at once.
// The SDF/natural split is handled inside the icon-image expressions, so both
// layers must share the same visibility filter or one half of the fleet would
// ignore the user's tactical/quick-search filters.
function setLiveFlightsFilter(filter) {
    if (!sectorOpsMap) return;
    if (sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
        sectorOpsMap.setFilter('sector-ops-live-flights-layer', filter);
    }
    if (sectorOpsMap.getLayer('sector-ops-live-flights-natural-layer')) {
        sectorOpsMap.setFilter('sector-ops-live-flights-natural-layer', filter);
    }
}

// Re-compute the airport-radius (__inRadius) tag for every cached feature and
// push the result to the source. Called when the proximity filter changes so
// it takes effect immediately, without waiting for the next polling tick.
function retagAirportRadius() {
    const ar = mapFilters.tactical && mapFilters.tactical.airportRadius;
    const apt = (ar && ar.icao && typeof airportsData !== 'undefined') ? airportsData[ar.icao] : null;
    const radiusKm = (ar && ar.radiusNm) ? ar.radiusNm * 1.852 : 0;

    Object.values(currentMapFeatures).forEach(f => {
        if (!apt || !radiusKm) { f.properties.__inRadius = 1; return; }
        try {
            const pos = JSON.parse(f.properties.position);
            const km = getDistanceKm(pos.lat, pos.lon, apt.lat, apt.lon);
            f.properties.__inRadius = (km <= radiusKm) ? 1 : 0;
        } catch (_) {
            f.properties.__inRadius = 1;
        }
    });

    if (sectorOpsMap && sectorOpsMap.getSource && sectorOpsMap.getSource('sector-ops-live-flights-source')) {
        sectorOpsMap.getSource('sector-ops-live-flights-source').setData({
            type: 'FeatureCollection',
            features: Object.values(currentMapFeatures)
        });
    }
}

// Floating compass button: appears only when the map has been rotated or
// tilted (e.g. an accidental two-finger twist) and snaps the view back to
// north / level on tap — the familiar Apple/Google Maps behaviour. The needle
// counter-rotates with the map bearing so it always points to true north.
function setupResetNorthButton() {
    if (!sectorOpsMap) return;
    const mapContainer = document.getElementById('sector-ops-map-fullscreen');
    if (!mapContainer || document.getElementById('reset-north-btn')) return;

    if (!document.getElementById('reset-north-style')) {
        const style = document.createElement('style');
        style.id = 'reset-north-style';
        style.textContent = `
            .reset-north-btn {
                position: absolute;
                top: calc(env(safe-area-inset-top, 0px) + 76px);
                right: 14px;
                width: 42px; height: 42px;
                display: flex; align-items: center; justify-content: center;
                border-radius: 50%;
                background: rgba(15, 23, 42, 0.55);
                border: 1px solid rgba(255, 255, 255, 0.15);
                color: #fff; font-size: 1.15rem;
                backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
                box-shadow: 0 4px 14px rgba(0, 0, 0, 0.4);
                z-index: 55; cursor: pointer;
                opacity: 0; transform: scale(0.8); pointer-events: none;
                transition: opacity 0.25s ease, transform 0.25s ease;
            }
            .reset-north-btn.visible { opacity: 1; transform: scale(1); pointer-events: auto; }
            .reset-north-btn:active { background: rgba(56, 189, 248, 0.35); }
            .reset-north-needle { transition: transform 0.1s linear; }
        `;
        document.head.appendChild(style);
    }

    const btn = document.createElement('button');
    btn.id = 'reset-north-btn';
    btn.className = 'reset-north-btn';
    btn.type = 'button';
    btn.title = 'Reset to North';
    btn.setAttribute('aria-label', 'Reset map orientation to North');
    btn.innerHTML = `<i class="fa-solid fa-compass reset-north-needle"></i>`;
    mapContainer.appendChild(btn);

    const needle = btn.querySelector('.reset-north-needle');
    const sync = () => {
        const bearing = sectorOpsMap.getBearing();
        const pitch = sectorOpsMap.getPitch();
        needle.style.transform = `rotate(${-bearing}deg)`;
        btn.classList.toggle('visible', Math.abs(bearing) > 1 || pitch > 1);
    };

    sectorOpsMap.on('rotate', sync);
    sectorOpsMap.on('pitch', sync);
    sync();

    btn.addEventListener('click', () => {
        window.InflightHaptics?.select?.();
        sectorOpsMap.easeTo({ bearing: 0, pitch: 0, duration: 500, essential: true });
    });
}

function updateAircraftLayerFilter() {
    if (!sectorOpsMap || !sectorOpsMap.getLayer('sector-ops-live-flights-layer')) return;

    let filter = ['all'];

    // 1. Global Toggles (Existing)
    if (mapFilters.hideAllAircraft) {
        setLiveFlightsFilter(['==', 'flightId', '']);
        return;
    }
    if (mapFilters.showStaffOnly) filter.push(['==', 'isStaff', true]);
    if (mapFilters.showVaOnly) filter.push(['==', 'isVAMember', true]);

    // Specific Virtual Airline filter: show only flights whose callsign begins
    // with the selected VA's registered code (e.g. 'DLVA' matches 'DLVA123').
    if (mapFilters.vaFilter && mapFilters.vaFilter.trim() !== '') {
        const vaCode = mapFilters.vaFilter.toUpperCase();
        filter.push(['==', ['slice', ['upcase', ['get', 'callsign']], 0, vaCode.length], vaCode]);
    }

    // 2. Tactical Filters (Injected from landingUI.js)
    const tactical = mapFilters.tactical || {};

    // --- Airport proximity (radius) filter ---
    // Keeps only aircraft within `radiusNm` of the chosen airport. Distance is
    // pre-computed per feature into the __inRadius property (here, for instant
    // response, and in the polling loop for moving traffic).
    const ar = tactical.airportRadius;
    if (ar && ar.icao && ar.radiusNm) {
        retagAirportRadius();
        filter.push(['==', ['get', '__inRadius'], 1]);
    }

    // --- Intelligent Aircraft Type Matching ---
    // Matches if user types "A38" and the aircraft is "Airbus A380-800"
    if (tactical.type && tactical.type.trim() !== '') {
        filter.push(['in', tactical.type.toUpperCase(), ['upcase', ['get', 'aircraftName']]]);
    }


    // --- Intelligent Livery Matching ---
    // Matches if user types "Delta" and livery is "Delta Air Lines"
    if (tactical.livery && tactical.livery.trim() !== '') {
        filter.push(['in', tactical.livery.toUpperCase(), ['upcase', ['get', 'liveryName']]]);
    }

    // --- Airline Code Matching ---
    // Matches the start of the callsign (e.g., "DAL" matches "DAL123")
    if (tactical.airline && tactical.airline.trim() !== '') {
        const code = tactical.airline.toUpperCase();
        filter.push(['==', ['slice', ['upcase', ['get', 'callsign']], 0, code.length], code]);
    }

    // --- Category Filtering (Using your existing icon/category system) ---
    if (tactical.category) {
        const catMap = { 
            'Heavy': 'jumbo', // Maps UI "Heavy" to your 'jumbo' logic (A380/747)
            'Widebody': 'widebody', 
            'Narrowbody': 'narrowbody', 
            'GA': 'cessna' 
        };
        const internalCat = catMap[tactical.category] || tactical.category.toLowerCase();
        filter.push(['==', ['get', 'category'], internalCat]);
    }

    if (tactical.phase) {
        filter.push(['==', ['get', 'phase'], tactical.phase]);
    }

    // Altitude Range (Min/Max)
    if (tactical.altitude) {
        if (tactical.altitude.min !== '') filter.push(['>=', ['get', 'altitude'], parseFloat(tactical.altitude.min)]);
        if (tactical.altitude.max !== '') filter.push(['<=', ['get', 'altitude'], parseFloat(tactical.altitude.max)]);
    }

    // Speed Range (Min/Max)
    if (tactical.speed) {
        if (tactical.speed.min !== '') filter.push(['>=', ['get', 'speed'], parseFloat(tactical.speed.min)]);
        if (tactical.speed.max !== '') filter.push(['<=', ['get', 'speed'], parseFloat(tactical.speed.max)]);
    }

    // Callsign (Partial Text Search - Case Insensitive)
    if (tactical.callsign) {
        filter.push(['in', tactical.callsign.toUpperCase(), ['upcase', ['get', 'callsign']]]);
    }

    // 3. Quick Search Blade
    if (mapFilters.quickSearch) {
        filter.push(['in', mapFilters.quickSearch.toUpperCase(), ['upcase', ['get', 'callsign']]]);
    }

    if (tactical.country && tactical.country !== 'All Countries') {
    // Extract prefix from UI string "United States (N)" -> "N". Guard against
    // free-typed values that omit the "(PREFIX)" part so we never throw.
    const countryMatch = tactical.country.match(/\((.*?)\)/);
    if (countryMatch) {
        const prefix = countryMatch[1];

        // FIX: Prioritize the community 'tailNumber' over the system 'registration'
        filter.push([
            '==',
            ['slice', ['coalesce', ['get', 'tailNumber'], ['get', 'registration'], ''], 0, prefix.length],
            prefix
        ]);
    }
}

    // Existing Filters (Departure/Arrival/Phase/etc.)
    if (tactical.departureIcao) filter.push(['==', ['upcase', ['get', 'departureIcao']], tactical.departureIcao.toUpperCase()]);
    if (tactical.arrivalIcao) filter.push(['==', ['upcase', ['get', 'arrivalIcao']], tactical.arrivalIcao.toUpperCase()]);
    if (tactical.phase) filter.push(['==', ['get', 'phase'], tactical.phase]);
    
    // Altitude and Speed Range logic...
    // [Keep your existing range check logic here]

    setLiveFlightsFilter(filter);

    // Keep the label layer in lock-step with the icon layer so filtered-out
    // aircraft don't leave orphaned tags floating on the map.
    if (sectorOpsMap.getLayer(AIRCRAFT_LABEL_LAYER_ID)) {
        sectorOpsMap.setFilter(AIRCRAFT_LABEL_LAYER_ID, filter);
    }
}

    /**
     * --- [RENAMED & MODIFIED] Updates the main toolbar buttons to show if any layers are active.
     * Now handles both Weather and Filter buttons.
     */
    function updateToolbarButtonStates() {
        // --- Weather Button (Existing) ---
        const openWeatherBtn = document.getElementById('open-weather-settings-btn');
        if (openWeatherBtn) {
            const precipToggle = document.getElementById('weather-toggle-precip');
            const cloudsToggle = document.getElementById('weather-toggle-clouds');
            const windToggle = document.getElementById('weather-toggle-wind');

            const isWeatherActive = (precipToggle && precipToggle.checked) ||
                                (cloudsToggle && cloudsToggle.checked) ||
                                (windToggle && windToggle.checked);

            openWeatherBtn.classList.toggle('active', isWeatherActive);
        }

        // --- [FIXED] Filter Button (Reads from state) ---
        const openFiltersBtn = document.getElementById('filters-settings-btn');
        if (openFiltersBtn) {
            // Check if any filter in mapFilters is true
            const isFilterActive = mapFilters.showVaOnly ||
                                   !!mapFilters.vaFilter ||
                                   mapFilters.hideAtcMarkers ||
                                   mapFilters.hideNoAtcMarkers; // Use the state object
            openFiltersBtn.classList.toggle('active', isFilterActive);
        }
    }

/**
 * [FIXED & MODIFIED BY USER] Fetches reverse geocoded location and updates the UI.
 * The 20km distance-based check has been removed per user request
 * to rely solely on a time-based interval.
 */
async function fetchAndDisplayGeocode(lat, lon) {
    if (!lat || !lon) return;

    // [USER REQ] Distance check removed to force time-based updates.
    
    // 1. Store new coordinates (still useful, though not for distance check)
    lastGeocodeCoords = { lat, lon };
    
    // [FIX] Query all *before* the await to set loading state
    const initialElements = document.querySelectorAll('#ac-location');
    if (initialElements.length === 0) return;

    initialElements.forEach(el => {
        el.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>'; // Loading state
    });

    try {
        // 3. Call your new Netlify Function
        const response = await fetch(`${CURRENT_SITE_URL}/.netlify/functions/reverse-geocode?lat=${lat}&lon=${lon}`);

        // [CRITICAL FIX] Query all *after* the await to get the (potentially) new DOM structure
        const currentElements = document.querySelectorAll('#ac-location');

        if (response.ok) {
            const data = await response.json();
            currentElements.forEach(el => {
                el.textContent = data.location || 'Remote Area';
            });
        } else {
            // API returned an error (e.g., 404 for ocean)
            currentElements.forEach(el => {
                el.textContent = 'Ocean / Remote Area';
            });
        }
    } catch (error) {
        console.error("Geocode fetch error:", error);
        // [CRITICAL FIX] Query all *after* the await, even in the catch block
        const currentElements = document.querySelectorAll('#ac-location');
        currentElements.forEach(el => {
            el.textContent = 'N/A'; // Fetch failed
        });
    }
}


    // --- NEW: Fetch Runway Data ---
async function fetchRunwaysData() {
    try {
        // Make sure the path to your JSON file is correct
        const response = await fetch('runways.json'); 
        if (!response.ok) throw new Error('Could not load runway data.');
        const rawRunways = await response.json();

        // Re-structure data for easier lookup by airport ICAO
        runwaysData = rawRunways.reduce((acc, runway) => {
            const ident = runway.airport_ident;
            if (!acc[ident]) {
                acc[ident] = [];
            }
            acc[ident].push(runway);
            return acc;
        }, {});
        console.log(`Successfully loaded and indexed runway data for ${Object.keys(runwaysData).length} airports.`);
    } catch (error) {
        console.error('Failed to fetch runway data:', error);
        showNotification('Runway data not available; takeoff/landing detection may be limited.', 'error');
    }
}

/**
 * --- [NEW] Gets a simplified, "lite" flight phase based only on position data.
 * This is cheap to calculate and suitable for all-flight map labels.
 * @param {object} position - The flight's position object from the socket.
 * @returns {string} A simple phase string.
 */
function getLiteFlightPhase(position) {
    if (!position) return '';

    const vs = position.vs_fpm || 0;
    const altitude = position.alt_ft || 0;
    const gs = position.gs_kt || 0;

    // On Ground Check (simplified: under 1000ft, low groundspeed, low VS)
    if (altitude < 1000 && gs < 40 && Math.abs(vs) < 150) {
        return 'Ground';
    }
    
    // In-Air Checks
    if (vs > 350) {
        return 'Climb';
    }
    if (vs < -500) {
        return 'Descent';
    }
    if (altitude > 18000 && Math.abs(vs) < 500) {
        return 'Cruise';
    }
    
    return 'Enroute'; // Default for level flight, etc.
}

/**
 * --- [NEW FIX] Fetches the airport database from airports.json
 * This function was missing, causing a 'ReferenceError'.
 */
async function fetchAirportsData() {
    try {
        const response = await fetch('airports.json'); // Assumes airports.json is in the same directory
        if (!response.ok) {
            throw new Error('Could not load airports.json database.');
        }
        
        const rawAirports = await response.json();

        // Check if the file is an array (which needs to be indexed)
        // or an object (which is already indexed)
        if (Array.isArray(rawAirports)) {
            // It's an array, so we must index it by ICAO
            airportsData = rawAirports.reduce((acc, airport) => {
                // Use 'icao' or 'ident' as the key, ensure it's uppercase
                const ikey = airport.icao || airport.ident; 
                if (ikey) {
                    acc[ikey.toUpperCase()] = airport;
                }
                return acc;
            }, {});
        } else {
            // It's already an object, just use it
            airportsData = rawAirports;
        }

        console.log(`Successfully loaded data for ${Object.keys(airportsData).length} airports.`);

    } catch (error) {
        console.error('Failed to fetch airport data:', error);
        // Use the showNotification function if it's available
        if (typeof showNotification === 'function') {
            showNotification('Airport database could not be loaded. Map may be incomplete.', 'error');
        }
    }
}
    /// --- Helper Functions ---

/**
     * --- [NEW] Helper function to update odometer-style text with a fade.
     * Uses a transitionend listener for a smooth update without chained setTimeouts.
     * @param {HTMLElement} el - The DOM element (span) to update.
     * @param {string} newValue - The new text content to display.
     */
    function updateOdometerDigit(el, newValue) {
        if (!el) return;
        
        const currentValue = el.textContent;
        
        if (currentValue !== newValue) {
            // 1. Fade out the old value
            el.style.opacity = 0;
            
            // 2. Listen for the fade-out to finish
            el.addEventListener('transitionend', function handler() {
                // 3. Once faded out, change the text
                el.textContent = newValue;
                
                // 4. Fade back in
                el.style.opacity = 1;
                
                // 5. Clean up the listener
                el.removeEventListener('transitionend', handler);
            }, { once: true });
        }
    }


function getAircraftCategory(aircraftName) {
    if (!aircraftName) return 'default';
    const name = aircraftName.toUpperCase();

    // 1. Military / Fighters
    if (['F-16', 'F-18', 'F-22', 'F-35', 'A-10', 'EUFI'].some(ac => name.includes(ac))) return 'F16';
    if (['C-130', 'C130', 'AC-130'].some(ac => name.includes(ac))) return 'C130';
    if (name.includes('C-17') || name.includes('C5')) return 'C17';

    // 2. Heavy / Jumbo
    if (name.includes('A380') || name.includes('A388')) return 'A380';
    if (name.includes('747')) return 'B747';

    // 3. Widebody
    if (name.includes('777') || name.includes('B77')) return 'B777';
    if (name.includes('787') || name.includes('B78')) return 'B787';
    if (name.includes('A350') || name.includes('A359')) return 'A350';
    if (name.includes('A330') || name.includes('A333') || name.includes('A339')) return 'A330';
    if (name.includes('DC-10') || name.includes('MD-11')) return 'A330'; // Mapping to similar footprint

    // 4. Narrowbody
    if (name.includes('737') || name.includes('B73') || name.includes('B38M')) return 'B737';
    if (name.includes('A320') || name.includes('A321') || name.includes('A319') || name.includes('A20N') || name.includes('A21N')) return 'A320';
    if (name.includes('757') || name.includes('B75')) return 'B757';

    // 5. Regional / GA / Heli
    if (name.includes('CRJ') || name.includes('E175') || name.includes('E190')) return 'E190';
    if (name.includes('DASH 8') || name.includes('DH8D') || name.includes('Q400')) return 'DASH8';
    if (['C172', 'SR22', 'CESSNA', 'SINGLEPROP'].some(ac => name.includes(ac))) return 'SINGLEPROP';
    if (['EUROCOPTER', 'H60', 'H64', 'CHINOOK', 'LYNX'].some(ac => name.includes(ac))) return 'EUROCOPTER';

    return 'B737'; // Default fallback that exists in your sprite sheet
}

// Expose for the ATC replay module (atcReplay.js) so historical flights reuse
// the same aircraft → sprite-category mapping the live map uses.
window.getAircraftCategory = getAircraftCategory;

/**
 * Determines Flight Rules (IFR/VFR) based on aircraft state, equipment, and flight plan.
 */
function determineFlightRules(flightProps, plan) {
    const altitude = flightProps.position.alt_ft;
    const vs = flightProps.position.vs_fpm;
    const category = flightProps.category; // 'jumbo', 'widebody', 'narrowbody', 'cessna', etc.
    const hasPlan = plan && plan.flightPlanItems && plan.flightPlanItems.length > 1;
    
    // --- 1. DEFINE STATES ---
    const IFR = { type: 'IFR', label: 'IFR', class: 'badge-ifr', icon: 'fa-cloud' };
    const VFR = { type: 'VFR', label: 'VFR', class: 'badge-vfr', icon: 'fa-sun' };
    const VFR_FPL = { type: 'VFR', label: 'VFR + FPL', class: 'badge-vfr', icon: 'fa-map' };
    
    // --- 2. GROUND LOGIC (Intent-Based) ---
    // Detect if on ground (low altitude, low speed)
    if (altitude < 2000 && flightProps.position.gs_kt < 50) {
        
        // Rule: Heavy Metal is always IFR
        if (['jumbo', 'widebody', 'fighter'].includes(category)) {
            return IFR;
        }

        // Rule: No Flight Plan = VFR (Pattern work or just spawned)
        if (!hasPlan) {
            return VFR;
        }

        // Rule: Check for Procedures (SIDs/STARs) in Plan
        // If plan has items that are NOT simple coords, likely IFR
        // (Simple heuristic: IFR plans usually have many waypoints)
        if (hasPlan && plan.flightPlanItems.length > 5) {
            return IFR;
        }

        // Rule: GA with Plan = VFR + FPL (Flight Following assumption)
        if (['cessna', 'general', 'private'].includes(category) && hasPlan) {
            return VFR_FPL;
        }

        // Default Ground for Airliners with Plan
        if (['narrowbody', 'regional'].includes(category) && hasPlan) {
            return IFR;
        }

        return VFR; // Fallback
    }

    // --- 3. IN-AIR LOGIC (Behavior-Based) ---

    // Rule: Class A Airspace (Hard limit)
    if (altitude > 18000) {
        return IFR;
    }

    // Rule: No Plan in Air = VFR
    if (!hasPlan) {
        return VFR;
    }

    // Rule: "Hemispheric Rule" (The modulo check)
    // Only apply if in relatively stable cruise (VS < 500)
    if (Math.abs(vs) < 500) {
        const remainder = altitude % 1000;
        
        // VFR is usually X,500 (remainder ~500)
        // Allow buffer of +/- 200ft (300 to 700)
        if (remainder > 300 && remainder < 700) {
            return VFR_FPL;
        }
        
        // IFR is usually X,000 (remainder near 0 or 1000)
        // (e.g. 0-200 or 800-1000)
        if (remainder < 200 || remainder > 800) {
            return IFR;
        }
    }

    // --- 4. CLIMB/DESCENT TRANSITION (Fallback) ---
    // If we are climbing/descending < 18k, fallback to Category
    if (['jumbo', 'widebody', 'narrowbody', 'regional'].includes(category)) {
        return IFR;
    }

    return VFR_FPL; // Default for GA in the air with a plan
}

/**
 * Fetches OAT and Wind data from OpenMeteo and stores it in the flight state.
 */
async function fetchAndDisplayWeather() {
    if (!currentAircraftPositionForGeocode) return;

    const lat = currentAircraftPositionForGeocode.lat;
    const lon = currentAircraftPositionForGeocode.lon;

    // Use OpenMeteo API endpoint (No API key required for this data)
    const OPENMETEO_URL = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,wind_speed_10m,wind_direction_10m&forecast_days=1`;
    
    // Elements to update (optional, but good for debugging)
    const windDisplay = document.getElementById('wind-speed-display');

    try {
        // 1. Fetch data
        const response = await fetch(OPENMETEO_URL);
        if (!response.ok) throw new Error('OpenMeteo fetch failed.');
        
        const data = await response.json();
        const current = data.current;

        if (!current) throw new Error('Invalid OpenMeteo response.');

        // 2. Update the shared state object with new data
        // We use temperature_2m as OAT approximation (simplification)
        currentAircraftPositionForGeocode.oat_c = current.temperature_2m;
        currentAircraftPositionForGeocode.wind_dir = current.wind_direction_10m;
        
        // Convert m/s to knots (1 m/s ≈ 1.944 kts)
        currentAircraftPositionForGeocode.wind_spd_kts = Math.round(current.wind_speed_10m * 1.944);

        // 3. Update the Nav Display iframe *immediately* with new wind data
        const navIframe = document.getElementById('nav-display-frame');
        if (navIframe && navIframe.contentWindow) {
             navIframe.contentWindow.postMessage({
                windDir: currentAircraftPositionForGeocode.wind_dir,
                windSpd: currentAircraftPositionForGeocode.wind_spd_kts
            }, '*');
        }

        console.log(`Weather updated: OAT=${current.temperature_2m}C, Wind=${current.wind_direction_10m}° @ ${currentAircraftPositionForGeocode.wind_spd_kts}kts`);
        
    } catch (error) {
        console.error("Weather fetch error:", error);
        // Clear or set default values on error
        if (currentAircraftPositionForGeocode) {
            currentAircraftPositionForGeocode.oat_c = 15; // Default ISA temp
            currentAircraftPositionForGeocode.wind_dir = 0;
            currentAircraftPositionForGeocode.wind_spd_kts = 0;
        }
    }
}

function getDistanceKm(lat1, lon1, lat2, lon2) {
    const R = 6371; // Radius of the Earth in km
    const toRad = Math.PI / 180;
    const dLat = (lat2 - lat1) * toRad;
    const dLon = (lon2 - lon1) * toRad;
    const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) ** 2;
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
}

/**
 * --- [NEW] Unwraps coordinates to prevent Date Line issues ---
 * Converts a raw [-180, 180] line string into a continuous world-space line
 * (e.g., converts a jump from 179 to -179 into 179 to 181).
 */
function unwrapLineCoordinates(coords) {
    if (!coords || coords.length < 2) return coords;

    const newCoords = [coords[0]]; // Start with first point
    let lastLon = coords[0][0]; // Track the "unwrapped" longitude

    for (let i = 1; i < coords.length; i++) {
        const [rawLon, lat] = coords[i];
        
        // Calculate the jump from the previous *unwrapped* longitude
        // We use modulo to compare against the raw equivalent of the last point
        let delta = rawLon - (lastLon % 360);

        // Normalize delta to be the shortest path (-180 to 180)
        if (delta > 180) delta -= 360;
        if (delta < -180) delta += 360;

        // Apply the delta to the continuous chain
        const newLon = lastLon + delta;
        newCoords.push([newLon, lat]);
        
        lastLon = newLon;
    }
    return newCoords;
}


    /**
 * Calculates True Airspeed (TAS) in knots based on Pressure Altitude and OAT.
 * Uses the approximate TAS formula derived from the speed of sound ratio.
 *
 * @param {number} alt_ft - Pressure altitude in feet (from flight data).
 * @param {number} oat_c - Outside Air Temperature in Celsius (from OpenMeteo).
 * @param {number} gs_kt - Ground Speed in knots (from flight data, used as a starting point).
 * @returns {number} Calculated TAS in knots.
 */
function calculateTas(alt_ft, oat_c, gs_kt) {
    // 1. Convert Altitude to Pressure Altitude in meters (approx)
    const alt_m = alt_ft * 0.3048;

    // 2. Calculate Standard Temperature at Altitude (ISA) in Kelvin (K)
    // T_ISA = 288.15 - 0.0065 * alt_m (up to 11,000m)
    const T_ISA_K = 288.15 - 0.0065 * alt_m; 
    
    // 3. Convert OAT (C) to Kelvin (K)
    const T_OAT_K = oat_c + 273.15;
    
    // 4. TAS is proportional to IAS/CAS times the square root of (T_OAT / T_ISA)
    // For simplicity and avoiding IAS conversion, we use GS as a base,
    // which provides a reasonable wind-corrected approximation for display.
    if (T_ISA_K <= 0) return gs_kt; // Safety check

    const TAS_kt = gs_kt * Math.sqrt(T_OAT_K / T_ISA_K);

    return Math.round(TAS_kt);
}


    /**
     * --- [NEW] Calculates the initial bearing from point 1 to point 2.
     * @param {number} lat1 - Latitude of the starting point in degrees.
     * @param {number} lon1 - Longitude of the starting point in degrees.
     * @param {number} lat2 - Latitude of the ending point in degrees.
     * @param {number} lon2 - Longitude of the ending point in degrees.
     * @returns {number} The initial bearing in degrees (0-360).
     */
    function getBearing(lat1, lon1, lat2, lon2) {
        const toRad = (v) => v * Math.PI / 180;
        const toDeg = (v) => v * 180 / Math.PI;

        const lat1Rad = toRad(lat1);
        const lon1Rad = toRad(lon1);
        const lat2Rad = toRad(lat2);
        const lon2Rad = toRad(lon2);

        const dLon = lon2Rad - lon1Rad;

        const y = Math.sin(dLon) * Math.cos(lat2Rad);
        const x = Math.cos(lat1Rad) * Math.sin(lat2Rad) -
                  Math.sin(lat1Rad) * Math.cos(lat2Rad) * Math.cos(dLon);
        
        let brng = toDeg(Math.atan2(y, x));
        return (brng + 360) % 360; // Normalize to 0-360
    }

    /**
     * --- [NEW] Normalizes a bearing difference to the smallest angle (-180 to 180).
     * @param {number} diff - The difference in degrees.
     * @returns {number} The normalized difference.
     */
    function normalizeBearingDiff(diff) {
        let normalized = diff % 360;
        if (normalized > 180) {
            normalized -= 360;
        }
        if (normalized < -180) {
            normalized += 360;
        }
        return normalized;
    }

/**
 * Calculates an intermediate point along a great-circle path.
 * @param {number} lat1 - Latitude of the starting point in degrees.
 * @param {number} lon1 - Longitude of the starting point in degrees.
 * @param {number} lat2 - Latitude of the ending point in degrees.
 * @param {number} lon2 - Longitude of the ending point in degrees.
 * @param {number} fraction - The fraction of the distance along the path (0.0 to 1.0).
 * @returns {{lat: number, lon: number}} The intermediate point's coordinates.
 */
function getIntermediatePoint(lat1, lon1, lat2, lon2, fraction) {
    const toRad = Math.PI / 180;
    const toDeg = 180 / Math.PI;
    const lat1Rad = lat1 * toRad;
    const lon1Rad = lon1 * toRad;
    const lat2Rad = lat2 * toRad;
    const lon2Rad = lon2 * toRad;
    const d = getDistanceKm(lat1, lon1, lat2, lon2) / 6371; // Angular distance in radians
    
    // Protect against division by zero if points are identical
    if (d === 0) return { lat: lat1, lon: lon1 };
    
    const sinD = Math.sin(d);
    const a = Math.sin((1 - fraction) * d) / sinD;
    const b = Math.sin(fraction * d) / sinD;
    const x = a * Math.cos(lat1Rad) * Math.cos(lon1Rad) + b * Math.cos(lat2Rad) * Math.cos(lon2Rad);
    const y = a * Math.cos(lat1Rad) * Math.sin(lon1Rad) + b * Math.cos(lat2Rad) * Math.sin(lon2Rad);
    const z = a * Math.sin(lat1Rad) + b * Math.sin(lat2Rad);
    const intLat = Math.atan2(z, Math.sqrt(x * x + y * y));
    const intLon = Math.atan2(y, x);
    return { lat: intLat * toDeg, lon: intLon * toDeg };
}

/**
     * --- [UPDATED] ---
     * Fetches community aircraft details from the backend and caches the result.
     * IMPORTS "NEGATIVE CACHING": If a lookup fails or finds nothing, we cache null 
     * to prevent future network attempts for this specific livery.
     */
    async function fetchCommunityAircraftDetails(type, livery) {
        if (!type || !livery) return null;

        const key = `${type}/${livery}`;

        // 1. Check local cache first (Success OR Previous Failure)
        if (communityAircraftCache.has(key)) {
            return communityAircraftCache.get(key);
        }

        // 2. Check if a fetch is already in progress
        if (lookupQueue.has(key)) {
            return lookupQueue.get(key);
        }

        const lookupPromise = (async () => {
            try {
                // Encode parameters for the URL
                const encodedType = encodeURIComponent(type);
                const encodedLivery = encodeURIComponent(livery);

                const response = await fetch(`${API_BASE_URL}/api/aircraft/lookup?type=${encodedType}&livery=${encodedLivery}`);

                if (response.ok) {
                    let data = await response.json();
                    
                    // Handle array response
                    if (Array.isArray(data)) {
                        data = data.length > 0 ? data[0] : null;
                    }

                    const lookupUrls = (Array.isArray(data?.imageUrls) && data.imageUrls.length)
                        ? data.imageUrls.filter(Boolean)
                        : (data?.imageUrl ? [data.imageUrl] : []);
                    if (data && lookupUrls.length) {
                        const lookupContributors = (Array.isArray(data.imageContributors) && data.imageContributors.length)
                            ? data.imageContributors
                            : [{ name: data.contributorName || 'IF Community', id: data.contributorId || null }];
                        const result = {
                            // Legacy single-image fields mirror the first photo so
                            // every existing consumer keeps working untouched.
                            communityImageUrl: lookupUrls[0],
                            contributorName: lookupContributors[0]?.name || data.contributorName || 'IF Community',
                            // Full ordered set (up to 3) for the multi-image carousel.
                            communityImageUrls: lookupUrls,
                            imageContributors: lookupContributors,
                            tailNumber: data.tailNumber || null
                        };
                        communityAircraftCache.set(key, result); // Cache Success
                        return result;
                    }
                }
            } catch (error) {
                // Console warning is optional, keeping it clean as requested
                // console.warn(`Background lookup failed for ${key}`, error); 
            }

            // --- NEGATIVE CACHING FIX ---
            // If we reached here, the fetch failed, or returned 404, or the data was empty.
            // We cache 'null' so we know we checked this already and found nothing.
            communityAircraftCache.set(key, null); 
            return null;
        })();

        // 3. Store the promise in the queue
        lookupQueue.set(key, lookupPromise);

        // 4. Remove the promise from the queue once resolved/rejected
        lookupPromise.finally(() => lookupQueue.delete(key));

        return lookupPromise;
    }

function handleSocketFlightUpdate(data) {
    if (!data || !Array.isArray(data.flights) || !data.timestamp) {
        console.warn('Socket: Received invalid or untimestamped flights data packet.');
        return;
    }

    if (!window.flightNumericIdMap) {
        window.flightNumericIdMap = new Map();
        window.nextFlightNumericId = 1;
    }

    // --- [FIX] Race Condition Check (Case Insensitive) ---
    // Ignore packets that don't match the currently selected server.
    if (data.server && data.server.toLowerCase() !== currentServerName.toLowerCase()) {
        return;
    }

    lastSocketUpdateTimestamp = new Date(data.timestamp).getTime();

    const isMapReady = (sectorOpsMap && sectorOpsMap.isStyleLoaded() && mapAnimator);
    const flights = data.flights;
    const updatedFlightIds = new Set();

    flights.forEach(flight => {
        if (!flight.position || !isFinite(flight.position.lat) || !isFinite(flight.position.lon)) {
            return; // Skip this flight
        }

        const flightId = flight.flightId;

        // --- [CRITICAL FIX] STALENESS CHECK ---
        // 1. Calculate the timestamp of the incoming data
        // We prefer the position report time, falling back to the packet time.
        const newTimestampRaw = flight.position.lastReport || data.timestamp;
        const newTime = new Date(newTimestampRaw).getTime();

        if (!window.flightNumericIdMap.has(flightId)) {
            window.flightNumericIdMap.set(flightId, window.nextFlightNumericId++);
        }
        const numericId = window.flightNumericIdMap.get(flightId);

        // 2. Get the timestamp of the data we already have (if any)
        let existingTime = 0;
        if (currentMapFeatures[flightId] && currentMapFeatures[flightId].properties && currentMapFeatures[flightId].properties.last_update) {
            existingTime = new Date(currentMapFeatures[flightId].properties.last_update).getTime();
        }

        // 3. If new data is OLDER than or EQUAL to existing data, ignore it.
        // This prevents the plane from "jumping back" to a previous position.
        if (newTime <= existingTime) {
            updatedFlightIds.add(flightId); // Mark as active so it doesn't get deleted
            return;
        }
        // --- [END FIX] ---

        updatedFlightIds.add(flightId);

        const litePhase = getLiteFlightPhase(flight.position);
        const aircraftData = flight.aircraft || null;
        const acName = aircraftData?.aircraftName || '';
        const livName = aircraftData?.liveryName || '';
        const lookupKey = `${acName}/${livName}`;

        let existingFeature = currentMapFeatures[flightId] || {};
        let existingProps = existingFeature.properties || {};

        const newProperties = {
            flightId: flight.flightId,
            callsign: flight.callsign,
            username: flight.username,
            altitude: flight.position.alt_ft,
            speed: flight.position.gs_kt || 0,
            verticalSpeed: flight.position.vs_fpm || 0,
            position: JSON.stringify(flight.position),
            aircraft: JSON.stringify(aircraftData),
            aircraftName: acName, // ADD THIS: For direct filtering
            liveryName: livName, // ADD THIS: For direct filtering
            airlineIcao: getAirlineIcaoFromLivery(livName), // drives the label's airline-logo badge
            registration: aircraftData?.registration || '',
            arrivalIcao: flight.arrivalIcao || null, // Map new backend field
            departureIcao: flight.departureIcao || null, // Map new backend field
            userId: flight.userId,
            category: getAircraftCategory(acName),
            heading: flight.position.heading_deg,
            isStaff: flight.isStaff,
            isVAMember: flight.isVAMember,
            phase: litePhase,
            pilotState: flight.pilotState,
            last_update: newTimestampRaw, // Store the specific time used for the check
            
            // Preserve existing cached data (Images + TAIL NUMBER)
            trafficType: (() => {
                if (isTrafficHighlightActive && window.currentAirportTraffic) {
                    if (window.currentAirportTraffic.in.includes(flightId)) return 'inbound';
                    if (window.currentAirportTraffic.out.includes(flightId)) return 'outbound';
                }
                return 'none';
            })(),

            // Airport-radius (proximity) filter tag. 1 = keep, 0 = outside the
            // chosen airport's radius. When the filter is inactive every plane
            // is tagged 1 so the Mapbox filter (added only while active) is a
            // no-op. Mirrored by retagAirportRadius() for instant updates.
            __inRadius: (() => {
                const ar = mapFilters.tactical && mapFilters.tactical.airportRadius;
                if (!ar || !ar.icao || !ar.radiusNm) return 1;
                const apt = (typeof airportsData !== 'undefined') ? airportsData[ar.icao] : null;
                if (!apt) return 1;
                const km = getDistanceKm(flight.position.lat, flight.position.lon, apt.lat, apt.lon);
                return (km <= ar.radiusNm * 1.852) ? 1 : 0;
            })(),

            // --- PREMIUM VISIBILITY FEATURE ---
            // Tag relation (user vs friend) for Mapbox color masking
            pilotRelation: (() => {
                const myIfName = ProfileUI._currentUser?.user_metadata?.if_username?.toLowerCase();
                const flightUser = flight.username?.toLowerCase();
                
                if (myIfName && flightUser === myIfName) {
                    return 'user';
                }
                
                if (ProfileUI._watchlist && ProfileUI._watchlist.some(w => w.watched_username.toLowerCase() === flightUser)) {
                    return 'watchlist';
                }
                
                return 'none';
            })(),

            communityImageUrl: existingProps.communityImageUrl || null,
            contributorName: existingProps.contributorName || null,
            communityImageUrls: existingProps.communityImageUrls || null,
            imageContributors: existingProps.imageContributors || null,
            tailNumber: existingProps.tailNumber || null
        };

        // --- START: ASYNCHRONOUS LOOKUP LOGIC FOR HOVER CARD ---
        if (acName && livName && !existingProps.communityImageUrl) {
            if (communityAircraftCache.has(lookupKey)) {
                const cachedData = communityAircraftCache.get(lookupKey);
                if (cachedData) {
                    newProperties.communityImageUrl = cachedData.communityImageUrl;
                    newProperties.contributorName = cachedData.contributorName;
                    newProperties.communityImageUrls = cachedData.communityImageUrls;
                    newProperties.imageContributors = cachedData.imageContributors;
                    newProperties.tailNumber = cachedData.tailNumber;
                }
            } else if (!lookupQueue.has(lookupKey)) {
                fetchCommunityAircraftDetails(acName, livName)
                    .then(result => {
                        if (result && currentMapFeatures[flightId]) {
                            currentMapFeatures[flightId].properties.communityImageUrl = result.communityImageUrl;
                            currentMapFeatures[flightId].properties.contributorName = result.contributorName;
                            currentMapFeatures[flightId].properties.communityImageUrls = result.communityImageUrls;
                            currentMapFeatures[flightId].properties.imageContributors = result.imageContributors;
                            currentMapFeatures[flightId].properties.tailNumber = result.tailNumber;
                            // Replaced rapid-fire setData with the debounced map source updater
                            scheduleMapSourceUpdate();
                        }
                    })
                    .catch(() => { /* Ignore errors */ });
            }
        }
        // --- END: ASYNCHRONOUS LOOKUP LOGIC ---

        // Manually update the data cache
        if (!currentMapFeatures[flightId]) {
            currentMapFeatures[flightId] = {
                type: 'Feature',
                id: numericId,
                geometry: {
                    type: 'Point',
                    coordinates: [flight.position.lon, flight.position.lat]
                },
                properties: newProperties
            };
        } else {
            currentMapFeatures[flightId].id = numericId;
            currentMapFeatures[flightId].properties = newProperties;
            currentMapFeatures[flightId].geometry.coordinates = [flight.position.lon, flight.position.lat];
        }

        // ================================================================
        // === SELECTED AIRCRAFT UPDATE LOGIC ===
        // ================================================================
        if (flightId === currentFlightInWindow) {
            // 1. Update the shared position object
            currentAircraftPositionForGeocode = flight.position;

            // 2. Retrieve Cached Weather Data
            const cachedOat = currentAircraftPositionForGeocode.oat_c ?? 15;
            const cachedWindDir = currentAircraftPositionForGeocode.wind_dir || 0;
            const cachedWindSpd = currentAircraftPositionForGeocode.wind_spd_kts || 0;

            // 3. Calculate TAS
            let calculatedTas = 0;
            if (flight.position.alt_ft != null) {
                calculatedTas = calculateTas(
                    flight.position.alt_ft, 
                    cachedOat, 
                    flight.position.gs_kt || 0
                );
            }

            // 4. Update Trail Cache
            const localTrail = liveTrailCache.get(flightId);
            
            const fullFlightProps = {
                ...newProperties,
                position: flight.position,
                aircraft: aircraftData
            };
            
            FlownPath3D.updatePath(sectorOpsMap, flightId, localTrail, mapFilters.show3DPath);

            if (localTrail) {
                const newRoutePoint = {
                    latitude: flight.position.lat,
                    longitude: flight.position.lon,
                    altitude: flight.position.alt_ft,
                    groundSpeed: flight.position.gs_kt,
                    track: flight.position.heading_deg,
                    date: new Date(flight.position.lastReport || Date.now()).toISOString()
                };
                localTrail.push(newRoutePoint);
                liveTrailCache.set(flightId, localTrail);

                // --- [NEW] Update Simple Iframe if Active ---
                const simpleIframe = document.getElementById('simple-flight-window-frame');
                if (mapFilters.useSimpleFlightWindow && simpleIframe && simpleIframe.contentWindow) {
                     const freshData = formatDataForSimpleWindow(
                         fullFlightProps,
                         cachedFlightDataForStatsView.plan,
                         liveTrailCache.get(flightId),
                         {
                             imageUrl: fullFlightProps.communityImageUrl,
                             contributorName: fullFlightProps.contributorName,
                             // Carry the full photo set so live telemetry ticks
                             // keep (rather than collapse) the hero carousel.
                             imageUrls: fullFlightProps.communityImageUrls,
                             imageContributors: fullFlightProps.imageContributors,
                             tailNumber: fullFlightProps.tailNumber
                         },
                         cachedFlightDataForStatsView.filedPlanData || null
                     );
                     simpleIframe.contentWindow.postMessage({ type: 'FLIGHT_DATA_UPDATE', payload: freshData }, '*');
                } else if (!mapFilters.useSimpleFlightWindow) {
                    updatePfdDisplay(flight.position);
                    updateNavPanelData(
                        flight.position.lat, 
                        flight.position.lon, 
                        flight.position.heading_deg,
                        cachedOat,
                        cachedWindDir,
                        cachedWindSpd
                    );
                    updateAircraftInfoWindow(fullFlightProps, cachedFlightDataForStatsView.plan, localTrail);
                }

                // 6.5 Update Navigation Display Iframe
                const navIframe = document.getElementById('nav-display-frame');
                if (navIframe && navIframe.contentWindow) {
                    refreshNavDisplayFromCache(); // Reuse helper logic for consistency
                }

                // 8. Update Map Trail
                if (isMapReady) {
                    const layerId = sectorOpsLiveFlightPathLayers[flightId]?.flown;
                    const source = layerId ? sectorOpsMap.getSource(layerId) : null;
                    if (source) {
                        const newRouteData = generateAltitudeColoredRoute(localTrail, flight.position, cachedFlightDataForStatsView.plan);
                        source.setData(newRouteData);
                    }
                }
            }

            // 9. Update Planned Route Line
            if (cachedFlightDataForStatsView.plan && mapFilters.planDisplayMode !== 'none' && isMapReady) {
                updateFlightPlanLayer(flightId, cachedFlightDataForStatsView.plan, flight.position);
            }

            if (document.getElementById('trip-card-takeover')?.classList.contains('active')) {
                updateTripCardRealtime();
            }
        }

        // === NEW: PINNED AIRCRAFT UPDATE LOGIC ===
        if (window.pinnedFlights && window.pinnedFlights.has(flightId) && flightId !== currentFlightInWindow) {
            let localTrail = liveTrailCache.get(flightId) || [];
            
            const newRoutePoint = {
                latitude: flight.position.lat,
                longitude: flight.position.lon,
                altitude: flight.position.alt_ft,
                groundSpeed: flight.position.gs_kt,
                track: flight.position.heading_deg,
                date: new Date(flight.position.lastReport || Date.now()).toISOString()
            };
            localTrail.push(newRoutePoint);
            liveTrailCache.set(flightId, localTrail);
            
            if (typeof FlownPath3D !== 'undefined') {
                FlownPath3D.updatePath(sectorOpsMap, flightId, localTrail, mapFilters.show3DPath);
            }
            
            const flownLayerId = `flown-path-${flightId}`;

            if (sectorOpsMap && sectorOpsMap.getSource(flownLayerId)) {
                // Use the exact same segmented generator for pinned flights so the altitude colors update smoothly
                const newPinnedRouteData = generateAltitudeColoredRoute(localTrail, flight.position);
                sectorOpsMap.getSource(flownLayerId).setData(newPinnedRouteData);
            }

            // Update Mini Card Stats
            const card = document.getElementById(`pinned-flight-${flightId}`);
            if (card) {
                const altEl = card.querySelector('.pinned-stat:nth-child(1) .pinned-val');
                const spdEl = card.querySelector('.pinned-stat:nth-child(2) .pinned-val');
                if (altEl) altEl.innerHTML = `${Math.round(flight.position.alt_ft || 0)} <small>FT</small>`;
                if (spdEl) spdEl.innerHTML = `${Math.round(flight.position.gs_kt || 0)} <small>KTS</small>`;
            }
        }

        // Only update the Map Animation/Icons if the map is actually ready.
        if (isMapReady) {
            mapAnimator.updateFlight(flight.position, newProperties);
        }
    });

    // Clean up old flights
    for (const flightId in currentMapFeatures) {
        if (!updatedFlightIds.has(String(flightId))) {
            if (isMapReady) {
                mapAnimator.removeFlight(flightId);
            }
            delete currentMapFeatures[flightId];
        }
    }

    // Push the new positions to the 3D dot field (no-op unless it's showing).
    if (isMapReady && LiveTraffic3D.isVisible()) LiveTraffic3D.refresh();

    const landingVisible = localStorage.getItem('landingUI_visible') !== 'false';
    if (landingVisible && !currentFlightInWindow && !currentAirportInWindow) {
        LandingUI.update(true, { 
            server: currentServerName, 
            flights: Object.keys(currentMapFeatures).length, 
            atc: activeAtcFacilities.length 
        });
    }
}

function initializeSectorOpsSocket() {
    // Prevent duplicate connections if called multiple times
    if (sectorOpsSocket && sectorOpsSocket.connected) {
        return;
    }

    // If a socket exists but is disconnected, try to reconnect
    if (sectorOpsSocket) {
        sectorOpsSocket.connect();
        return;
    }

    // Create new connection
    if (typeof io === 'undefined') {
        console.error('Socket.IO client library (io) is not loaded. Cannot connect to WebSocket.');
        showNotification('Live service connection failed. Please reload.', 'error');
        return;
    }
    
    console.log(`Socket: Connecting to ${ACARS_SOCKET_URL}...`);
    sectorOpsSocket = io(ACARS_SOCKET_URL, {
    reconnection: true,
    reconnectionAttempts: 10, // Increase attempts
    reconnectionDelay: 3000,   // Wait longer between retries
    transports: ['websocket', 'polling'], // Allow fallback for 10mbps/unstable users
    timeout: 20000 // Increase connection timeout to 20 seconds
});

    // On successful connection, join the server room based on State
    sectorOpsSocket.on('connect', () => {
        // [UPDATED] Use currentServerName
        console.log(`Socket: Connected with ID ${sectorOpsSocket.id}. Joining room: ${currentServerName.toLowerCase()}`);
        sectorOpsSocket.emit('join_server_room', currentServerName);
    });

    // Listen for the broadcasted flight data
    sectorOpsSocket.on('all_flights_update', (data) => {
        handleSocketFlightUpdate(data); // Your existing function
        socketDataHub.publish('all_flights_update', data); // Broadcasts to any new files
    });

    // Inside initializeSectorOpsSocket() in flight.js
    sectorOpsSocket.on('secondary_data_update', (data) => {
        if (!data || data.server.toLowerCase() !== currentServerName.toLowerCase()) return;

        activeAtcFacilities = data.atc || [];
        notifyActiveAtcUpdated();

        // Filter for Center controllers (Type 6)
        const centerControllers = activeAtcFacilities.filter(f => f.type === 6);
        
        // --- FIX: Only draw sectors if the aircraft layer exists (prevents Mapbox crash) ---
        if (sectorOpsMap && sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
            if (typeof updateActiveSectors === 'function') {
                updateActiveSectors(sectorOpsMap, 'fir-fills', centerControllers);
            }
        }

        renderAirportMarkers();
        
        // Broadcasts to any new files
        socketDataHub.publish('secondary_data_update', data); 
    });

    sectorOpsSocket.on('disconnect', (reason) => {
        console.warn(`Socket: Disconnected. Reason: ${reason}`);
    });

    sectorOpsSocket.on('connect_error', (error) => {
        console.error(`Socket: Connection Error. ${error.message}`);
    });
}

/**
 * --- [UPDATED] Smart Route Densification ---
 * Adds intermediate points along the Great Circle path between coordinates.
 * Prevents lines from "cutting through" the globe on long segments.
 * @param {Array<[number, number]>} coordinates - Array of [lon, lat] points.
 * @param {number} maxSegmentLengthKm - Max distance between points (default 100km).
 * @returns {Array<[number, number]>} Densified coordinates.
 */
function densifyRoute(coordinates, maxSegmentLengthKm = 100) {
    if (!coordinates || coordinates.length < 2) return coordinates;
    const densified = [coordinates[0]];
    const toRad = Math.PI / 180;
    
    for (let i = 0; i < coordinates.length - 1; i++) {
        const start = coordinates[i];
        const end = coordinates[i + 1];
        
        // Fast equirectangular approximation for initial distance check to avoid heavy math
        const lat1 = start[1] * toRad;
        const lat2 = end[1] * toRad;
        const lon1 = start[0] * toRad;
        const lon2 = end[0] * toRad;
        
        const x = (lon2 - lon1) * Math.cos((lat1 + lat2) / 2);
        const y = lat2 - lat1;
        const distKm = Math.sqrt(x * x + y * y) * 6371;
        
        if (distKm > maxSegmentLengthKm) {
            const steps = Math.ceil(distKm / maxSegmentLengthKm);
            for (let j = 1; j < steps; j++) {
                const fraction = j / steps;
                const intermediate = getIntermediatePoint(start[1], start[0], end[1], end[0], fraction);
                
                // Maintain the 'unwrapped' longitude continuity
                let lon = intermediate.lon;
                let prevLon = densified[densified.length - 1][0];
                let delta = lon - (prevLon % 360);
                
                // Optimized wrap math
                if (delta > 180) delta -= 360;
                else if (delta < -180) delta += 360;
                
                densified.push([prevLon + delta, intermediate.lat]);
            }
        }
        densified.push(end);
    }
    return densified;
}



/**
 * --- NEW HELPER FUNCTION ---
 * Finds the closest runway end to a given aircraft position and track.
 * @param {object} aircraftPos - { lat, lon, heading_deg } // <-- MODIFIED
 * @param {string} airportIcao - The ICAO of the airport to check.
 * @param {number} maxDistanceNM - The maximum search radius in nautical miles.
 * @returns {object|null} - The runway end details (including distance and heading difference) or null if none are close enough.
 */
function getNearestRunway(aircraftPos, airportIcao, maxDistanceNM = 2.0) {
    const runways = runwaysData[airportIcao];
    if (!runways || runways.length === 0) {
        return null;
    }

    let closestRunway = null;
    let minDistanceKm = maxDistanceNM * 1.852;

    for (const runway of runways) {
        // Check both ends of the runway ('le' = low end, 'he' = high end)
        const ends = [
            // ✅ CORRECTION: Added elevation_ft to each end
            { ident: runway.le_ident, lat: runway.le_latitude_deg, lon: runway.le_longitude_deg, heading: runway.le_heading_degT, elevation_ft: runway.le_elevation_ft },
            { ident: runway.he_ident, lat: runway.he_latitude_deg, lon: runway.he_longitude_deg, heading: runway.he_heading_degT, elevation_ft: runway.he_elevation_ft }
        ];

        for (const end of ends) {
            if (end.lat == null || end.lon == null) continue;

            const distanceKm = getDistanceKm(aircraftPos.lat, aircraftPos.lon, end.lat, end.lon);

            if (distanceKm < minDistanceKm) {
                minDistanceKm = distanceKm;
                closestRunway = {
                    ...end,
                    airport: airportIcao,
                    distanceNM: distanceKm / 1.852
                };
            }
        }
    }

    // If a close runway was found, calculate the heading difference
    if (closestRunway) {
        // ⬇️ MODIFIED: Use heading_deg instead of track_deg
        let headingDiff = Math.abs(aircraftPos.heading_deg - closestRunway.heading);
        if (headingDiff > 180) {
            headingDiff = 360 - headingDiff; // Normalize to the shortest angle
        }
        closestRunway.headingDiff = headingDiff;
    }

    return closestRunway;
}
    

    function formatTime(ms) {
        if (ms < 0) ms = 0;
        let seconds = Math.floor(ms / 1000);
        let minutes = Math.floor(seconds / 60);
        let hours = Math.floor(minutes / 60);
        seconds = seconds % 60;
        minutes = minutes % 60;
        return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
    }

    function formatDuration(seconds) {
        if (isNaN(seconds) || seconds < 0) return '00:00';
        const hours = Math.floor(seconds / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
    }

    function formatTimeFromTimestamp(timestamp) {
        if (!timestamp) return '----';
        const date = (typeof timestamp === 'number' && timestamp.toString().length === 10) ?
            new Date(timestamp * 1000) :
            new Date(timestamp);
        if (isNaN(date.getTime())) return '----';
        return date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' });
    }

    /**
     * Returns a UTC HH:MM string for a Date, or null if the date is invalid.
     */
    function _formatUtcHHMM(d) {
        if (!d || isNaN(d.getTime())) return null;
        return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' });
    }

    /**
     * Computes the best available departure time and tags it with its source.
     * Source priority: SCHEDULED (filed plan) > ACTUAL (GPS history first point) > ESTIMATED (back-calc from current position).
     * Always tries to produce a usable time — only falls through to '--:--' when truly nothing is available.
     *
     * @returns {{time: string, label: string, color: string, timestamp: Date|null}}
     */
    function computeDepartureTimeInfo(flightProps, sortedRoutePoints, filedPlanData, departureIcao) {
        // 1) Filed flight plan = SCHEDULED (highest priority — pilot's own filed time)
        if (filedPlanData && filedPlanData.dep_time) {
            const d = new Date(filedPlanData.dep_time);
            const t = _formatUtcHHMM(d);
            if (t) return { time: t, label: 'SCHEDULED', color: '#fbbf24', timestamp: d };
        }

        // 2) Real GPS history first point = ACTUAL
        if (sortedRoutePoints && sortedRoutePoints.length > 0 && sortedRoutePoints[0].date) {
            const d = new Date(sortedRoutePoints[0].date);
            const t = _formatUtcHHMM(d);
            if (t) return { time: t, label: 'ACTUAL', color: '#38bdf8', timestamp: d };
        }

        // 3) Back-calculate from current position + speed = ESTIMATED
        const dep = (typeof airportsData !== 'undefined' && airportsData) ? airportsData[departureIcao] : null;
        const pos = flightProps && flightProps.position;
        if (dep && typeof dep.lat === 'number' && typeof dep.lon === 'number' &&
            pos && typeof pos.lat === 'number' && typeof pos.lon === 'number' &&
            typeof getDistanceKm === 'function') {

            const distNm = getDistanceKm(dep.lat, dep.lon, pos.lat, pos.lon) * 0.539957;
            const gs = pos.gs_kt || 0;

            // Practically still at the departure airport — treat departure as essentially "now"
            if (distNm < 3) {
                const d = new Date();
                return { time: _formatUtcHHMM(d), label: 'ESTIMATED', color: '#94a3b8', timestamp: d };
            }

            // Use current GS if it looks like cruise speed; otherwise assume ~400 kt jet cruise as a reasonable average
            const effectiveSpeed = gs > 150 ? gs : 400;
            const flightSeconds = (distNm / effectiveSpeed) * 3600;

            // Sanity-cap at 18 h backward (covers the longest commercial flights)
            if (flightSeconds > 0 && flightSeconds < 18 * 3600) {
                const d = new Date(Date.now() - flightSeconds * 1000);
                const t = _formatUtcHHMM(d);
                if (t) return { time: t, label: 'ESTIMATED', color: '#94a3b8', timestamp: d };
            }
        }

        // 4) Truly nothing — fall through to blank
        return { time: '--:--', label: '', color: '#64748b', timestamp: null };
    }

    /**
     * Computes the best available arrival time and tags it with its source.
     * Source priority: SCHEDULED (filed plan dep_time + duration) > ESTIMATED (now + ETE based on remaining distance).
     *
     * @returns {{time: string, label: string, color: string, timestamp: Date|null}}
     */
    function computeArrivalTimeInfo(flightProps, filedPlanData, distanceToDestNM) {
        // 1) Filed plan with both dep_time and duration = SCHEDULED arrival
        if (filedPlanData && filedPlanData.dep_time && filedPlanData.duration_minutes) {
            const d = new Date(new Date(filedPlanData.dep_time).getTime() + filedPlanData.duration_minutes * 60000);
            const t = _formatUtcHHMM(d);
            if (t) return { time: t, label: 'SCHEDULED', color: '#fbbf24', timestamp: d };
        }

        // 2) Compute from current speed + distance remaining = ESTIMATED arrival
        const pos = flightProps && flightProps.position;
        if (pos && typeof distanceToDestNM === 'number' && distanceToDestNM > 0) {
            const gs = pos.gs_kt || 0;
            const effectiveSpeed = gs > 150 ? gs : 400;
            const eteHours = distanceToDestNM / effectiveSpeed;
            if (eteHours > 0 && eteHours < 48) {
                const d = new Date(Date.now() + eteHours * 3600 * 1000);
                const t = _formatUtcHHMM(d);
                if (t) return { time: t, label: 'ESTIMATED', color: '#94a3b8', timestamp: d };
            }
        }

        return { time: '--:--', label: '', color: '#64748b', timestamp: null };
    }

    /**
     * Updates the time + source label DOM for either ATD or ETA.
     * @param {string} suffix 'atd' or 'eta'
     * @param {{time: string, label: string, color: string}} info
     */
    function applyRouteTimeInfoToDom(suffix, info) {
        const timeText = info.time === '--:--' ? info.time : `${info.time} Z`;
        document.querySelectorAll(`#ac-bar-${suffix}`).forEach(el => {
            el.textContent = timeText;
            el.style.color = info.color;
        });
        document.querySelectorAll(`#ac-bar-${suffix}-label`).forEach(el => {
            el.textContent = info.label;
            el.style.color = info.color;
        });
    }


    function extractAirlineCode(flightNumber) {
        if (!flightNumber || typeof flightNumber !== 'string') return 'UNKNOWN';
        const cleanedFlightNumber = flightNumber.trim().toUpperCase();
        const match = cleanedFlightNumber.match(/^([A-Z0-9]{2,3})([0-9]{1,4})([A-Z]?)$/);
        if (match && match[1]) return match[1].substring(0, 2);
        const fallbackMatch = cleanedFlightNumber.match(/^(\D+)/);
        if (fallbackMatch && fallbackMatch[1]) return fallbackMatch[1].substring(0, 2);
        return 'UNKNOWN';
    }

    


    function atcTypeToString(typeId) {
        const types = {
            0: 'Ground', 1: 'Tower', 2: 'Unicom', 3: 'Clearance',
            4: 'Approach', 5: 'Departure', 6: 'Center', 7: 'ATIS',
            8: 'Aircraft', 9: 'Recorded', 10: 'Unknown', 11: 'Unused'
        };
        return types[typeId] || 'Unknown';
    }

    function formatAtcDuration(startTime) {
        if (!startTime) return '';
        const start = new Date(startTime).getTime();
        const now = Date.now();
        const diffMs = Math.max(0, now - start);
        const hours = Math.floor(diffMs / 3600000);
        const minutes = Math.floor((diffMs % 3600000) / 60000);
        return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
    }

    // --- Active ATC API ---------------------------------------------------
    // A small, read-only bridge so the mobile chrome can show a live list of
    // online controllers without reaching into this module's internals. It
    // closes over the in-scope ATC state / map / airport DB.
    window.InflightATC = {
        // Shallow copy so callers can't mutate our live array.
        getFacilities() {
            return Array.isArray(activeAtcFacilities) ? activeAtcFacilities.slice() : [];
        },
        // Airport-centric view for the ATC sheet's board: one row per field with
        // its name, controller count and which positions are open. Staffed
        // airports come first (busiest first); the network's hub/route airports
        // are also listed (dimmed, 0 controllers) so the board reads like a
        // directory even when the network is quiet.
        getAirportBoard() {
            const byIcao = new Map();
            const ensure = (icao) => {
                if (!byIcao.has(icao)) byIcao.set(icao, { icao, count: 0, types: new Set() });
                return byIcao.get(icao);
            };
            // 1. Online ATC, grouped by field (centers have no airport).
            (activeAtcFacilities || []).forEach(f => {
                const icao = f.airportName;
                const type = Number(f.type);
                if (!icao || type === 6) return;
                const e = ensure(icao);
                e.count++;
                e.types.add(type);
            });
            // 2. Hub/route airports, added in their natural order (dimmed).
            try {
                if (typeof ALL_AVAILABLE_ROUTES !== 'undefined' && Array.isArray(ALL_AVAILABLE_ROUTES)) {
                    ALL_AVAILABLE_ROUTES.forEach(r => {
                        if (r && r.departure) ensure(r.departure);
                        if (r && r.arrival) ensure(r.arrival);
                    });
                }
            } catch (_) {}

            const board = [];
            byIcao.forEach(e => {
                const apt = (airportsData && airportsData[e.icao]) || {};
                board.push({
                    icao: e.icao,
                    name: apt.name || '',
                    count: e.count,
                    atis: e.types.has(7),
                    gnd: e.types.has(0) || e.types.has(3), // Ground / Delivery
                    twr: e.types.has(1),
                    app: e.types.has(4),
                    dep: e.types.has(5)
                });
            });
            // Stable sort: staffed (count > 0) first by count; ties keep the
            // insertion order above (online first, then route order).
            board.sort((a, b) => b.count - a.count);
            return board.slice(0, 150);
        },
        typeLabel(typeId) { return atcTypeToString(typeId); },
        formatDuration(startTime) { return formatAtcDuration(startTime); },
        // Pan/zoom the map to a controller's position. Centers use their own
        // lat/lon; airport positions (TWR/GND/APP/etc.) fall back to the
        // airport database so every row is tappable.
        focus(facility) {
            if (!sectorOpsMap || !facility) return false;
            let center = null;
            const lat = Number(facility.latitude);
            const lon = Number(facility.longitude);
            if (Number.isFinite(lat) && Number.isFinite(lon) && (lat !== 0 || lon !== 0)) {
                center = [lon, lat];
            } else if (facility.airportName && airportsData && airportsData[facility.airportName]) {
                const a = airportsData[facility.airportName];
                const alat = Number(a.lat);
                const alon = Number(a.lon ?? a.lng ?? a.longitude);
                if (Number.isFinite(alat) && Number.isFinite(alon)) center = [alon, alat];
            }
            if (!center) return false;
            try {
                sectorOpsMap.flyTo({
                    center,
                    zoom: facility.type === 6 ? 5 : 9, // centers are wide, fields are close
                    essential: true,
                    speed: 1.2
                });
                return true;
            } catch (_) { return false; }
        }
    };

    // Let the mobile chrome refresh its controller list / badge the moment new
    // ATC data lands, from either the socket push or the HTTP poll.
    function notifyActiveAtcUpdated() {
        try {
            window.dispatchEvent(new CustomEvent('activeAtcUpdated', {
                detail: { count: Array.isArray(activeAtcFacilities) ? activeAtcFacilities.length : 0 }
            }));
        } catch (_) {}
    }

    // --- [NEW] PFD Constants and Functions ---
    const PFD_PITCH_SCALE = 8;
    const PFD_SPEED_SCALE = 7;
    const PFD_SPEED_CENTER_Y = 238;
    const PFD_SPEED_REF_VALUE = 120;
    const PFD_ALTITUDE_SCALE = 0.7;
    const PFD_ALTITUDE_CENTER_Y = 234;
    const PFD_ALTITUDE_REF_VALUE = 0;
    const PFD_REEL_SPACING = 30;
    const PFD_HEADING_SCALE = 5;
    const PFD_HEADING_CENTER_X = 406;
    const PFD_HEADING_REF_VALUE = 0;

    function createPfdDisplay() {
        const SVG_NS = "http://www.w3.org/2000/svg";
        
        // --- Existing Groups ---
        const attitudeGroup = document.getElementById('attitude_group');
        const speedTapeGroup = document.getElementById('speed_tape_group');
        const altitudeTapeGroup = document.getElementById('altitude_tape_group');
        const tensReelGroup = document.getElementById('altitude_tens_reel_group');
        const headingTapeGroup = document.getElementById('heading_tape_group');
        
        // --- NEW: Select the main PFD group to attach the FMA ---
        const pfdGroup = document.getElementById('PFD');

        // Safety check
        if (!attitudeGroup || !speedTapeGroup || !altitudeTapeGroup || !tensReelGroup || !headingTapeGroup || !pfdGroup) {
            return;
        }
        
        // Prevent double-initialization
        if (attitudeGroup.dataset.initialized === 'true') return;

        // 1. Generate Attitude Indicators (Existing Logic)
        function generateAttitudeIndicators() {
            const centerX = 401.5;
            const centerY = 312.5;
            for (let p = -90; p <= 90; p += 2.5) {
                if (p === 0) continue;
                const y = centerY - (p * PFD_PITCH_SCALE);
                const isMajor = (p % 10 === 0);
                const isMinor = (p % 5 === 0);
                if (isMajor || isMinor) {
                    const lineWidth = isMajor ? 80 : 40;
                    const line = document.createElementNS(SVG_NS, 'line');
                    line.setAttribute('x1', centerX - lineWidth / 2);
                    line.setAttribute('x2', centerX + lineWidth / 2);
                    line.setAttribute('y1', y);
                    line.setAttribute('y2', y);
                    line.setAttribute('stroke', 'white');
                    line.setAttribute('stroke-width', 2);
                    attitudeGroup.appendChild(line);
                    if (isMajor) {
                        const textLeft = document.createElementNS(SVG_NS, 'text');
                        textLeft.setAttribute('x', centerX - lineWidth / 2 - 10);
                        textLeft.setAttribute('y', y + 5);
                        textLeft.setAttribute('fill', 'white');
                        textLeft.setAttribute('font-size', '18');
                        textLeft.setAttribute('text-anchor', 'end');
                        textLeft.textContent = Math.abs(p);
                        attitudeGroup.appendChild(textLeft);
                        const textRight = document.createElementNS(SVG_NS, 'text');
                        textRight.setAttribute('x', centerX + lineWidth / 2 + 10);
                        textRight.setAttribute('y', y + 5);
                        textRight.setAttribute('fill', 'white');
                        textRight.setAttribute('font-size', '18');
                        textRight.setAttribute('text-anchor', 'start');
                        textRight.textContent = Math.abs(p);
                        attitudeGroup.appendChild(textRight);
                    }
                }
            }
        }

        // 2. Generate Speed Tape (Existing Logic)
        function generateSpeedTape() {
            const MIN_SPEED = 0, MAX_SPEED = 999;
            for (let s = MIN_SPEED; s <= MAX_SPEED; s += 5) {
                const yPos = PFD_SPEED_CENTER_Y - (s - PFD_SPEED_REF_VALUE) * PFD_SPEED_SCALE;
                const tick = document.createElementNS(SVG_NS, 'line');
                tick.setAttribute('y1', yPos); tick.setAttribute('y2', yPos);
                tick.setAttribute('stroke', 'white'); tick.setAttribute('stroke-width', '2');
                if (s % 10 === 0) {
                    tick.setAttribute('x1', '67'); tick.setAttribute('x2', '52');
                    const text = document.createElementNS(SVG_NS, 'text');
                    text.setAttribute('x', '37'); text.setAttribute('y', yPos + 5);
                    text.setAttribute('fill', 'white'); text.setAttribute('font-size', '18');
                    text.setAttribute('text-anchor', 'middle'); text.textContent = s;
                    speedTapeGroup.appendChild(text);
                } else {
                    tick.setAttribute('x1', '67'); tick.setAttribute('x2', '60');
                }
                speedTapeGroup.appendChild(tick);
            }
        }

        // 3. Generate Altitude Tape (Existing Logic)
        function generateAltitudeTape() {
            const MIN_ALTITUDE = 0, MAX_ALTITUDE = 50000;
            for (let alt = MIN_ALTITUDE; alt <= MAX_ALTITUDE; alt += 20) {
                const yPos = PFD_ALTITUDE_CENTER_Y - (alt - PFD_ALTITUDE_REF_VALUE) * PFD_ALTITUDE_SCALE;
                const tick = document.createElementNS(SVG_NS, 'line');
                tick.setAttribute('y1', yPos); tick.setAttribute('y2', yPos);
                tick.setAttribute('stroke', 'white'); tick.setAttribute('stroke-width', '2');
                tick.setAttribute('x1', '72');
                if (alt % 100 === 0) {
                    tick.setAttribute('x2', '52');
                    const text = document.createElementNS(SVG_NS, 'text');
                    text.setAttribute('x', '25'); text.setAttribute('y', yPos + 5);
                    text.setAttribute('fill', 'white'); text.setAttribute('font-size', '18');
                    text.setAttribute('text-anchor', 'middle'); text.textContent = alt / 100;
                    altitudeTapeGroup.appendChild(text);
                } else {
                    tick.setAttribute('x2', '62');
                }
                altitudeTapeGroup.appendChild(tick);
            }
        }

        // 4. Generate Reels (Existing Logic)
        function generateAltitudeTensReel() {
            const center_y = 316;
            for (let i = -5; i < 10; i++) {
                let value = (i * 20); value = (value < 0) ? 100 + (value % 100) : value % 100;
                const displayValue = String(value).padStart(2, '0');
                const yPos = center_y - (i * PFD_REEL_SPACING);
                const text = document.createElementNS(SVG_NS, 'text');
                text.setAttribute('x', '745'); text.setAttribute('y', yPos);
                text.setAttribute('fill', '#00FF00'); text.setAttribute('font-size', '32');
                text.setAttribute('font-weight', 'bold'); text.textContent = displayValue;
                tensReelGroup.appendChild(text);
            }
        }

        // 5. Generate Heading Tape (Existing Logic)
        function generateHeadingTape() {
            const y_text = 650, y_tick_top = 620, y_tick_bottom_major = 635, y_tick_bottom_minor = 628;
            for (let h = -360; h <= 720; h += 5) {
                const xPos = PFD_HEADING_CENTER_X + (h - PFD_HEADING_REF_VALUE) * PFD_HEADING_SCALE;
                const normalizedH = (h + 360) % 360;
                if (normalizedH % 90 === 0) continue;
                const tick = document.createElementNS(SVG_NS, 'line');
                tick.setAttribute('x1', xPos); tick.setAttribute('x2', xPos);
                tick.setAttribute('stroke', 'white'); tick.setAttribute('stroke-width', '1.5');
                tick.setAttribute('y1', y_tick_top); tick.setAttribute('y2', (h % 10 === 0) ? y_tick_bottom_major : y_tick_bottom_minor);
                headingTapeGroup.appendChild(tick);
            }
            for (let h = 0; h < 360; h += 10) {
                for (let offset of [-360, 0, 360]) {
                    const currentH = h + offset;
                    const xPos = PFD_HEADING_CENTER_X + (currentH - PFD_HEADING_REF_VALUE) * PFD_HEADING_SCALE;
                    const text = document.createElementNS(SVG_NS, 'text');
                    text.setAttribute('x', xPos); text.setAttribute('y', y_text);
                    text.setAttribute('fill', 'white'); text.setAttribute('font-size', '16');
                    text.setAttribute('text-anchor', 'middle');
                    let displayVal = '';
                    switch (h) { case 0: displayVal = 'N'; break; case 90: displayVal = 'E'; break; case 180: displayVal = 'S'; break; case 270: displayVal = 'W'; break; default: if (h % 30 === 0) { displayVal = h / 10; } }
                    if (displayVal !== '') { text.textContent = displayVal; headingTapeGroup.appendChild(text); }
                }
            }
        }
        
        // --- 6. NEW: Generate Flight Mode Annunciator (FMA) ---
        function generateFMA() {
            // FMA Container Group
            const fmaGroup = document.createElementNS(SVG_NS, 'g');
            fmaGroup.setAttribute('id', 'fma_group');
            
            // Background Box (Top of PFD)
            // UPDATED: Height 100
            const fmaBg = document.createElementNS(SVG_NS, 'rect');
            fmaBg.setAttribute('x', '0');
            fmaBg.setAttribute('y', '0'); 
            fmaBg.setAttribute('width', '787');
            fmaBg.setAttribute('height', '100'); // Taller
            fmaBg.setAttribute('fill', '#101010'); 
            fmaBg.setAttribute('stroke', '#555');
            fmaBg.setAttribute('stroke-width', '0'); 
            fmaGroup.appendChild(fmaBg);

            // Separator Lines (5 Columns -> 4 lines)
            const colWidth = 157.4;
            for (let i = 1; i < 5; i++) {
                const x = i * colWidth;
                const line = document.createElementNS(SVG_NS, 'line');
                line.setAttribute('x1', x); line.setAttribute('x2', x);
                // UPDATED: y2 is 100
                line.setAttribute('y1', '0'); line.setAttribute('y2', '100');
                line.setAttribute('stroke', '#555'); 
                line.setAttribute('stroke-width', '1');
                fmaGroup.appendChild(line);
            }

            // Text Placeholders
            // UPDATED: Centered vertically for 100px height (~58px) and increased font size
            
            // Col 1: Auto-Thrust
            const textCol1 = document.createElementNS(SVG_NS, 'text');
            textCol1.setAttribute('id', 'fma_col1_text');
            textCol1.setAttribute('x', '78');
            textCol1.setAttribute('y', '58'); 
            textCol1.setAttribute('fill', '#00FF00'); 
            textCol1.setAttribute('font-family', 'monospace');
            textCol1.setAttribute('font-size', '24'); // Larger
            textCol1.setAttribute('font-weight', 'bold');
            textCol1.setAttribute('text-anchor', 'middle');
            textCol1.textContent = ""; 
            fmaGroup.appendChild(textCol1);

            // Col 2: Vertical Mode
            const textCol2 = document.createElementNS(SVG_NS, 'text');
            textCol2.setAttribute('id', 'fma_col2_text');
            textCol2.setAttribute('x', '235');
            textCol2.setAttribute('y', '58');
            textCol2.setAttribute('fill', '#00FF00');
            textCol2.setAttribute('font-family', 'monospace');
            textCol2.setAttribute('font-size', '24');
            textCol2.setAttribute('font-weight', 'bold');
            textCol2.setAttribute('text-anchor', 'middle');
            textCol2.textContent = ""; 
            fmaGroup.appendChild(textCol2);

            // Col 3: Lateral Mode
            const textCol3 = document.createElementNS(SVG_NS, 'text');
            textCol3.setAttribute('id', 'fma_col3_text');
            textCol3.setAttribute('x', '392');
            textCol3.setAttribute('y', '58');
            textCol3.setAttribute('fill', '#00FF00');
            textCol3.setAttribute('font-family', 'monospace');
            textCol3.setAttribute('font-size', '24');
            textCol3.setAttribute('font-weight', 'bold');
            textCol3.setAttribute('text-anchor', 'middle');
            textCol3.textContent = ""; 
            fmaGroup.appendChild(textCol3);

            // Col 4: Approach Capability
            const textCol4 = document.createElementNS(SVG_NS, 'text');
            textCol4.setAttribute('id', 'fma_col4_text');
            textCol4.setAttribute('x', '549');
            textCol4.setAttribute('y', '52'); // Slightly higher
            textCol4.setAttribute('fill', '#FFFFFF'); 
            textCol4.setAttribute('font-family', 'monospace');
            textCol4.setAttribute('font-size', '20'); // Larger
            textCol4.setAttribute('text-anchor', 'middle');
            
            const tspan1 = document.createElementNS(SVG_NS, 'tspan');
            tspan1.setAttribute('x', '549');
            tspan1.setAttribute('dy', '0');
            tspan1.textContent = ""; 
            textCol4.appendChild(tspan1);
            
            const tspan2 = document.createElementNS(SVG_NS, 'tspan');
            tspan2.setAttribute('x', '549');
            tspan2.setAttribute('dy', '22');
            tspan2.textContent = ""; 
            textCol4.appendChild(tspan2);
            
            fmaGroup.appendChild(textCol4);
            
            // --- Add a divider line at the bottom of the FMA ---
            const bottomBorder = document.createElementNS(SVG_NS, 'line');
            bottomBorder.setAttribute('x1', '0'); bottomBorder.setAttribute('x2', '787');
            // UPDATED: y 100
            bottomBorder.setAttribute('y1', '100'); bottomBorder.setAttribute('y2', '100');
            bottomBorder.setAttribute('stroke', '#ffffff');
            bottomBorder.setAttribute('stroke-width', '2');
            fmaGroup.appendChild(bottomBorder);

            // Append FMA to PFD Group (Last = On Top)
            pfdGroup.appendChild(fmaGroup);
        }

        generateAttitudeIndicators();
        generateSpeedTape();
        generateAltitudeTape();
        generateAltitudeTensReel();
        generateHeadingTape();
        generateFMA(); // <-- Call the new generator

        attitudeGroup.dataset.initialized = 'true'; 
    }
    

function updatePfdDisplay(pfdData) {
  if (!pfdData) return;

  // ---- tolerate common key names ----
  const gs_kt =
    pfdData.gs_kt ??
    pfdData.groundspeed_kts ??
    pfdData.groundspeed ??
    pfdData.gs ??
    (pfdData.speed && (pfdData.speed.kt || pfdData.speed.kts)) ??
    0;

  const track_deg =
    pfdData.heading_deg ??
    pfdData.track_deg ??
    pfdData.track ??
    pfdData.hdg ??
    0;

  const alt_ft = pfdData.alt_ft ?? pfdData.altitude_ft ?? pfdData.altitude ?? 0;
  const vs_fpm = pfdData.vs_fpm ?? pfdData.vertical_speed_fpm ?? pfdData.vs ?? 0;

  // ---- [FIX] DOM elements are now selected via querySelectorAll ----
  const attitudeGroups     = document.querySelectorAll('#attitude_group');
  const speedTapeGroups    = document.querySelectorAll('#speed_tape_group');
  const altitudeTapeGroups = document.querySelectorAll('#altitude_tape_group');
  const tensReelGroups     = document.querySelectorAll('#altitude_tens_reel_group');
  const headingTapeGroups  = document.querySelectorAll('#heading_tape_group');
  const speedReadouts      = document.querySelectorAll('#speed_readout');
  const altReadoutHunds    = document.querySelectorAll('#altitude_readout_hundreds');
  const headingReadouts    = document.querySelectorAll('#heading_readout');
  
  if (attitudeGroups.length === 0) return; // No PFDs found, exit
  
  // ---- tunables ----
  const WINDOW_SEC          = 2.4;   // regression window
  const LATCH_ON_TURN       = 0.20;  // deg/s to latch "turning"
  const LATCH_OFF_TURN      = 0.10;  // deg/s to unlatch
  const LATCH_HOLD_MS       = 400;   // chatter guard
  const MAX_BANK_DEG        = 35;
  const MAX_ROLL_RATE       = 60;    // display slew (deg/s)
  const MIN_GS_FOR_TURN     = 1;
  const PITCH_LIMIT         = 25;

  const DATA_HOLD_MS        = 1400;  // hold last turn-rate after last fresh packet
  const STALE_MS            = 4000;  // after this, allow full decay/unlatch
  const HDG_EPS             = 0.4;   // unwrapped degrees to consider heading "changed"
  const GS_EPS              = 0.5;   // kt change to consider GS "changed"
  const DECAY_TO_LEVEL_DPS  = 12;    // decay when not turning
  const MICRO_DECAY_FACTOR  = 0.25;  // softer decay before STALE_MS

  const EMA_ALPHA           = 0.35;  // EMA smoothing on turn-rate (0..1)
  const SIGN_MIN_DEG        = 3.0;   // min magnitude to accept L/R sign flip
  const SIGN_HOLD_MS        = 250;   // new sign must persist this long

  const now = performance.now();

  // ---- persistent state ----
  if (!window.lastPfdState || typeof window.lastPfdState !== 'object') {
    window.lastPfdState = {
      unwrapped: track_deg,
      lastTime: now,
      buf: [],                  // [{t, hdg}] for fresh samples only
      rollDisp: 0,
      turning: false,
      lastTurnLatchTs: 0,

      // freshness / hold
      lastDataTs: 0,
      lastTurnRate: 0,
      lastRawTrack: track_deg,
      lastRawGs: gs_kt,
      prevUnwrapped: track_deg,

      // smoothing & sign guard
      turnRateEma: 0,
      rollSign: 0,
      lastSignChangeTs: 0
    };
  }
  const S = window.lastPfdState;

  // ---- unwrap heading ----
  let delta = track_deg - (S.unwrapped % 360);
  if (delta > 180)  delta -= 360;
  if (delta < -180) delta += 360;
  const unwrapped = S.unwrapped + delta;

  // ---- detect "fresh" API packet vs. render tick (use unwrapped delta) ----
  const unwrappedDelta = Math.abs(unwrapped - S.unwrapped);
  const isFresh =
    unwrappedDelta > HDG_EPS ||
    Math.abs(gs_kt - S.lastRawGs) > GS_EPS;

  // ---- manage regression buffer (only for fresh samples) ----
  const tNow = now / 1000;
  if (isFresh) {
    S.lastDataTs = now;
    S.lastRawTrack = track_deg;
    S.lastRawGs = gs_kt;
    const cutoff = tNow - WINDOW_SEC;
    S.buf.push({ t: tNow, hdg: unwrapped });
    while (S.buf.length && S.buf[0].t < cutoff) S.buf.shift();
  }

  // ---- turn-rate estimate (deg/s): fresh -> compute; else -> hold previous ----
  let turnRate = S.lastTurnRate;
  if (isFresh) {
    if (S.buf.length >= 3 && gs_kt > MIN_GS_FOR_TURN) {
      // linear regression slope
      const t0 = S.buf[0].t;
      let sumT = 0, sumH = 0, sumTT = 0, sumTH = 0, n = S.buf.length;
      for (let i = 0; i < n; i++) {
        const ti = S.buf[i].t - t0;
        const hi = S.buf[i].hdg;
        sumT  += ti;
        sumH  += hi;
        sumTT += ti * ti;
        sumTH += ti * hi;
      }
      const denom = n * sumTT - sumT * sumT;
      if (denom !== 0) {
        turnRate = (n * sumTH - sumT * sumH) / denom; // deg/s
      } else {
        const dtS = Math.max(0.02, (now - S.lastTime) / 1000);
        turnRate = (unwrapped - S.prevUnwrapped) / dtS;
      }
    } else {
      const dtS = Math.max(0.02, (now - S.lastTime) / 1000);
      turnRate = (unwrapped - S.prevUnwrapped) / dtS;
    }
    S.lastTurnRate = turnRate;
  }

  // ---- EMA smoothing on turn-rate ----
  S.turnRateEma = EMA_ALPHA * turnRate + (1 - EMA_ALPHA) * S.turnRateEma;

  // ---- hysteresis + data-hold for "turning" ----
  const sinceFresh = now - S.lastDataTs;
  const rateAbs    = Math.abs(S.turnRateEma);
  const wasTurning = S.turning;
  const forceTurningByHold = sinceFresh <= DATA_HOLD_MS && Math.abs(S.lastTurnRate) >= LATCH_OFF_TURN;

  if (!wasTurning) {
    if (rateAbs >= LATCH_ON_TURN || forceTurningByHold) {
      S.turning = true;
      S.lastTurnLatchTs = now;
    }
  } else {
    const timeSinceLatch = now - S.lastTurnLatchTs;
    const allowUnlatch = rateAbs < LATCH_OFF_TURN && timeSinceLatch > LATCH_HOLD_MS && sinceFresh > DATA_HOLD_MS;
    if (allowUnlatch && sinceFresh > STALE_MS) {
      S.turning = false;
    } else if (rateAbs >= LATCH_OFF_TURN || forceTurningByHold) {
      S.lastTurnLatchTs = now;
    }
  }

  // ---- coordinated-turn bank target from smoothed rate ----
  const Vms   = Math.max(0, gs_kt) * 0.514444;
  const omega = (S.turnRateEma * Math.PI) / 180; // rad/s
  const bankAbs = Math.atan(Math.abs(omega) * Vms / 9.81) * 180 / Math.PI;
  let targetRoll = (S.turnRateEma >= 0 ? 1 : -1) * Math.min(bankAbs, MAX_BANK_DEG);

  // ---- sign stickiness (prevents brief L/R flips) ----
  const desiredSign = Math.sign(targetRoll);
  if (desiredSign !== 0 && desiredSign !== S.rollSign) {
    const bigEnough = Math.abs(targetRoll) >= SIGN_MIN_DEG;
    const persisted = (now - S.lastSignChangeTs) >= SIGN_HOLD_MS;
    if (bigEnough && persisted) {
      S.rollSign = desiredSign;
      S.lastSignChangeTs = now;
    } else {
      targetRoll = Math.abs(targetRoll) * (S.rollSign || desiredSign);
    }
  } else if (S.rollSign === 0 && desiredSign !== 0) {
    S.rollSign = desiredSign;
    S.lastSignChangeTs = now;
  }

  // ---- when not turning: decay toward level (hold pose before STALE_MS) ----
  if (!S.turning) {
    const dt = Math.max(0.01, (now - S.lastTime) / 1000);
    const base = DECAY_TO_LEVEL_DPS * dt;
    const decayStep = sinceFresh <= STALE_MS ? base * MICRO_DECAY_FACTOR : base;
    targetRoll = (Math.abs(S.rollDisp) <= decayStep) ? 0 : S.rollDisp - Math.sign(S.rollDisp) * decayStep;
  }

  // ---- slew-limit the displayed roll ----
  {
    const dt = Math.max(0.01, (now - S.lastTime) / 1000);
    const maxStep = dt * MAX_ROLL_RATE;
    const diff = targetRoll - S.rollDisp;
    S.rollDisp += Math.abs(diff) > maxStep ? Math.sign(diff) * maxStep : diff;
  }

  // ---- update state timestamps/unwraps ----
  S.unwrapped = unwrapped;
  S.prevUnwrapped = unwrapped;
  S.lastTime = now;

  // ---- pitch from VS ----
  const pitch_deg = Math.max(-PITCH_LIMIT, Math.min(PITCH_LIMIT, (vs_fpm / 1000) * 4));

  // ---- [FIX] Apply transforms to ALL found elements ----
  const rollForSvg = -S.rollDisp; // SVG rotation sense
  const attitudeTransform = `translate(0, ${pitch_deg * PFD_PITCH_SCALE}) rotate(${rollForSvg}, 401.5, 312.5)`;
  attitudeGroups.forEach(el => el.setAttribute('transform', attitudeTransform));

  // ---- [FIX] Apply tape/readout updates to ALL found elements ----
  const speedYOffset = (gs_kt - PFD_SPEED_REF_VALUE) * PFD_SPEED_SCALE;
  speedReadouts.forEach(el => el.textContent = Math.round(gs_kt));
  speedTapeGroups.forEach(el => el.setAttribute('transform', `translate(0, ${speedYOffset})`));

  const altitude = Math.max(0, alt_ft);
  const tapeYOffset = altitude * PFD_ALTITUDE_SCALE;
  altReadoutHunds.forEach(el => el.textContent = Math.floor(altitude / 100));
  altitudeTapeGroups.forEach(el => el.setAttribute('transform', `translate(0, ${tapeYOffset})`));

  const tensValue = altitude % 100;
  // [FIXED] Removed negative sign. Moves DOWN (positive Y) as value increases to reveal numbers from above.
  const reelYOffset = (tensValue / 20) * PFD_REEL_SPACING;
  tensReelGroups.forEach(el => el.setAttribute('transform', `translate(0, ${reelYOffset})`));

  const hdg = ((Math.round(track_deg) % 360) + 360) % 360;
  const xOffset = -(track_deg - PFD_HEADING_REF_VALUE) * PFD_HEADING_SCALE;
  headingReadouts.forEach(el => el.textContent = String(hdg).padStart(3, '0'));
  headingTapeGroups.forEach(el => el.setAttribute('transform', `translate(${xOffset}, 0)`));

  // ---------------------------------------------------------
  // ---- NEW: UPDATE FMA TEXT (Flight Mode Annunciator) ----
  // ---------------------------------------------------------
  
  // 1. Determine Modes Logic
  let thrustMode = "SPEED";
  let vertMode = "ALT";
  let latMode = "NAV";
  let catStatus = ""; // E.g., "CAT3\nDUAL"

  // -- Logic: Phase Detection --
  const isClimbing = vs_fpm > 400;
  const isDescending = vs_fpm < -400;
  const isOnGround = alt_ft < 50 && gs_kt > 30; // Pseudo-takeoff
  const isTurning = Math.abs(S.rollDisp) > 3.0;
  
  // Use inferred alignment logic (Low alt, low speed, steady roll)
  // Note: This assumes landing configuration without checking runways directly (simulated)
  const isLandingConfig = alt_ft < 2500 && gs_kt < 180 && !isClimbing; 
  const isEstablished = isLandingConfig && !isTurning;

  // -- Col 1: Auto-Thrust --
  if (isOnGround) {
      thrustMode = "TOGA";
  } else if (isClimbing) {
      thrustMode = "THR CLB";
  } else if (isDescending) {
      thrustMode = "THR IDLE";
  } else {
      thrustMode = "SPEED";
  }

  // -- Col 2: Vertical Mode --
  if (isClimbing) {
      vertMode = "CLB";
  } else if (isDescending) {
      vertMode = "DES";
  } else if (isEstablished && isLandingConfig) {
      vertMode = "G/S";
  } else {
      vertMode = "ALT"; // Level flight
  }

  // -- Col 3: Lateral Mode --
  if (isOnGround) {
      latMode = "RWY";
  } else if (isEstablished && isLandingConfig) {
      latMode = "LOC";
  } else if (isTurning) {
      latMode = "HDG";
  } else {
      latMode = "NAV";
  }

  // -- Col 4: Approach Status (Simulated) --
  if (latMode === "LOC" && vertMode === "G/S" && alt_ft < 1000) {
      catStatus = "CAT3\nDUAL"; 
  }

  // 2. Update DOM
  const fmaCol1 = document.getElementById('fma_col1_text');
  const fmaCol2 = document.getElementById('fma_col2_text');
  const fmaCol3 = document.getElementById('fma_col3_text');
  const fmaCol4 = document.getElementById('fma_col4_text');

  if (fmaCol1) fmaCol1.textContent = thrustMode;
  if (fmaCol2) fmaCol2.textContent = vertMode;
  if (fmaCol3) fmaCol3.textContent = latMode;

  if (fmaCol4) {
      // Handle multiline logic for Col 4
      const lines = catStatus.split('\n');
      const spans = fmaCol4.querySelectorAll('tspan');
      if (spans.length >= 2) {
          spans[0].textContent = lines[0] || "";
          spans[1].textContent = lines[1] || "";
      }
  }
}

    /**
     * --- [NEW] Resets the PFD state and visuals to neutral. ---
     * Call this when selecting a new aircraft to prevent displaying stale data.
     */
    function resetPfdState() {
        // 1. Invalidate the persistent state object.
        //    This forces updatePfdDisplay to re-initialize it on its next run.
        window.lastPfdState = null;

        // 2. Immediately set the core SVG elements to a neutral, "level flight" state.
        const attitudeGroup = document.getElementById('attitude_group');
        const speedReadout = document.getElementById('speed_readout');
        const altReadoutHund = document.getElementById('altitude_readout_hundreds');
        const headingReadout = document.getElementById('heading_readout');
        const speedTapeGroup = document.getElementById('speed_tape_group');
        const altitudeTapeGroup = document.getElementById('altitude_tape_group');
        const headingTapeGroup = document.getElementById('heading_tape_group');

        if (attitudeGroup) {
            // Set to zero pitch translation and zero roll rotation.
            attitudeGroup.setAttribute('transform', 'translate(0, 0) rotate(0, 401.5, 312.5)');
        }
        
        // 3. Clear readouts to avoid showing the last aircraft's data.
        if (speedReadout) speedReadout.textContent = '---';
        if (altReadoutHund) altReadoutHund.textContent = '---';
        if (headingReadout) headingReadout.textContent = '---';

        // 4. Reset tape positions to zero.
        if (speedTapeGroup) speedTapeGroup.setAttribute('transform', 'translate(0, 0)');
        if (altitudeTapeGroup) altitudeTapeGroup.setAttribute('transform', 'translate(0, 0)');
        if (headingTapeGroup) headingTapeGroup.setAttribute('transform', 'translate(0, 0)');
    }

// Add this helper to flight.js
async function fetchAirportData(icao) {
    try {
        const response = await fetch(`${API_BASE_URL}/api/airports/${icao}`);
        if (!response.ok) throw new Error('Airport data not found');
        return await response.ok ? await response.json() : null;
    } catch (error) {
        console.error("Error fetching dynamic airport image:", error);
        return null;
    }
}

// --- ATC Session History (Replay) ----------------------------------------
// The ATC replay backend records every controller session for 48h. The
// /api/atc/sessions/recent endpoint can't filter by airport, so we pull the
// recent sessions for the current server and keep the ones staffing THIS
// field, newest first. Each becomes a "Replay" card in the airport window.
async function fetchAtcSessionsForAirport(icao) {
    try {
        const sessionId = await getValidSessionId();
        const qs = (sessionId && sessionId !== 'default')
            ? `?sessionId=${encodeURIComponent(sessionId)}&limit=200`
            : '?limit=200';
        const res = await fetch(`${ACARS_SOCKET_URL}/api/atc/sessions/recent${qs}`);
        if (!res.ok) return [];
        const json = await res.json();
        if (!json || !json.ok || !Array.isArray(json.sessions)) return [];
        return json.sessions
            .filter(s => s.airportName === icao)
            .sort((a, b) => (b.start || 0) - (a.start || 0));
    } catch (e) {
        console.warn(`Could not fetch ATC sessions for ${icao}`, e);
        return [];
    }
}

// "HH:MMZ · 2h ago" style label for a session start (Unix-ms).
function formatAtcSessionStart(ms) {
    if (!ms) return 'Unknown time';
    const d = new Date(ms);
    const diffMin = Math.floor((Date.now() - ms) / 60000);
    let rel;
    if (diffMin < 1) rel = 'just now';
    else if (diffMin < 60) rel = `${diffMin}m ago`;
    else if (diffMin < 1440) rel = `${Math.floor(diffMin / 60)}h ago`;
    else rel = `${Math.floor(diffMin / 1440)}d ago`;
    const pad = (n) => String(n).padStart(2, '0');
    return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}Z · ${rel}`;
}

function renderAtcSessionCard(s) {
    const dur = (typeof s.durationMin === 'number') ? `${s.durationMin} min` : '';
    const freqs = (s.frequencies || []).length
        ? s.frequencies.map(f => `<span class="atc-history-freq-pill">${f}</span>`).join('')
        : '<span class="atc-history-freq-pill muted">No positions</span>';
    const when = formatAtcSessionStart(s.start);
    const safeUser = String(s.username || 'Controller').replace(/"/g, '&quot;');
    return `
    <div class="atc-history-card">
        <div class="atc-history-main">
            <div class="atc-history-top">
                <span class="atc-history-user"><i class="fa-solid fa-headset"></i> ${s.username || 'Controller'}</span>
                ${s.open ? '<span class="atc-history-live">● LIVE</span>' : ''}
            </div>
            <div class="atc-history-freqs">${freqs}</div>
            <div class="atc-history-meta"><i class="fa-regular fa-clock"></i> ${when}${dur ? ` · ${dur}` : ''}</div>
        </div>
        <button class="atc-replay-session-btn" data-atc-key="${s.key}" data-atc-apt="${s.airportName || ''}" data-atc-user="${safeUser}" data-atc-uid="${s.userId || s.userid || ''}" title="Replay this controller session">
            <i class="fa-solid fa-circle-play"></i> Replay
        </button>
    </div>`;
}

// Skeleton shown while the airport window's data is in flight. Mirrors the
// real layout (hero → stats bar → modules → tabs) so the window — and the
// mobile peek sheet in particular — opens at its final shape and shimmers,
// instead of presenting an empty chunk with a lone spinner. The ICAO is known
// immediately, so it renders for instant feedback; the close button is live
// because the window's delegated click handler is already attached.
function createAirportSkeletonHTML(icao) {
    const skelStat = `
        <div class="apt-stat-cell">
            <div class="apt-skel-block" style="width: 36px; height: 16px;"></div>
            <div class="apt-skel-block" style="width: 52px; height: 8px;"></div>
        </div>`;
    const skelRow = `
        <div class="apt-skel-block" style="height: 64px; border-radius: 10px; margin-bottom: 10px;"></div>`;
    return `
        <div class="apt-skeleton" style="display: flex; flex-direction: column; height: 100%;">
            <div class="airport-hero apt-skel-hero">
                <div class="airport-hero-overlay"></div>
                <div class="hero-actions">
                    <button id="airport-window-close-btn" class="hero-btn" title="Close Window"><i class="fa-solid fa-xmark"></i></button>
                </div>
                <div class="apt-ident-group">
                    <div class="apt-icao">${icao}</div>
                    <div class="apt-skel-block" style="width: 180px; height: 12px; margin-top: 8px;"></div>
                    <div class="apt-skel-block" style="width: 110px; height: 10px; margin-top: 6px;"></div>
                </div>
            </div>
            <div class="apt-stats-bar">${skelStat}${skelStat}${skelStat}${skelStat}</div>
            <div style="display: flex; gap: 8px; padding: 10px 16px; border-bottom: 1px solid var(--border-glass);">
                <div class="apt-skel-block" style="width: 70px; height: 20px; border-radius: 4px;"></div>
                <div class="apt-skel-block" style="width: 86px; height: 20px; border-radius: 4px;"></div>
                <div class="apt-skel-block" style="width: 78px; height: 20px; border-radius: 4px;"></div>
            </div>
            <div style="flex-grow: 1; overflow: hidden; padding: 16px;">
                <div class="apt-dashboard-grid" style="padding: 0; margin-bottom: 16px;">
                    <div class="apt-skel-block" style="height: 92px; border-radius: 8px;"></div>
                    <div class="apt-skel-block" style="height: 92px; border-radius: 8px;"></div>
                </div>
                <div style="display: flex; gap: 8px; margin-bottom: 14px;">
                    <div class="apt-skel-block" style="flex: 1; height: 34px;"></div>
                    <div class="apt-skel-block" style="flex: 1; height: 34px;"></div>
                    <div class="apt-skel-block" style="flex: 1; height: 34px;"></div>
                    <div class="apt-skel-block" style="flex: 1; height: 34px;"></div>
                </div>
                ${skelRow}${skelRow}${skelRow}
            </div>
        </div>`;
}

async function createAirportInfoWindowHTML(icao, requestId) {
        // 1. Get Static Data
        const staticData = airportsData[icao] || {};
        const airportMetadata = await fetchAirportData(icao);
        
        // Use the dynamic image if available, otherwise fall back to a default
        const dynamicImageUrl = airportMetadata?.imageUrl || 'Images/default_airport.webp';

        // 2. Fetch Live Airport Details (Jetbridges, city, state, etc.)
        let liveData = null;
        try {
            const response = await fetch(`${ACARS_SOCKET_URL}/api/airport/${icao}`);
            if (response.ok) {
                const json = await response.json();
                if (json.ok && json.airport) liveData = json.airport;
            }
        } catch (e) {
            console.warn(`Could not fetch live data for ${icao}`, e);
        }

        // 3. Fetch Live Traffic & ATIS using the cached Session ID
        let inbounds = [];
        let outbounds = [];
        let rawAtisText = null;
        let trafficFetchSuccess = false;

        try {
            const sessionId = await getValidSessionId();
            
            if (sessionId && sessionId !== 'default') {
                const [statusRes, atisRes] = await Promise.all([
                    fetch(`${ACARS_SOCKET_URL}/api/live/airport/${sessionId}/${icao}/status`),
                    fetch(`${ACARS_SOCKET_URL}/api/live/airport/${sessionId}/${icao}/atis`)
                ]);

                if (statusRes.ok) {
                    const statusJson = await statusRes.json();
                    if (statusJson.ok && statusJson.status) {
                        inbounds = statusJson.status.inboundFlights || [];
                        outbounds = statusJson.status.outboundFlights || [];
                        trafficFetchSuccess = true;
                    }
                }

                if (atisRes.ok) {
                    const atisJson = await atisRes.json();
                    if (atisJson.ok && atisJson.atis) rawAtisText = atisJson.atis;
                }
            }
        } catch (e) {
            console.error("Error fetching live stats:", e);
        }

        // Update Global Traffic State for Highlighting — but only if this is
        // still the active request. If the user tapped another airport while
        // our /status fetch was in flight, recolouring the map for this (now
        // stale) field would fight with the newer request's highlighting.
        if (requestId === undefined || requestId === airportWindowRequestSeq) {
            window.currentAirportTraffic = { in: inbounds, out: outbounds };
            if (isTrafficHighlightActive) applyTrafficHighlighting();
        }

        // 4. Merge Data
        const airportName = liveData?.name || staticData.name || 'Unknown Airport';
        const city = liveData?.city || staticData.city;
        const state = liveData?.state || staticData.state;
        const cityState = [city, state].filter(Boolean).join(', ') || 'Location N/A';
        const countryCode = (liveData?.country?.isoCode || staticData.country || '').toLowerCase();
        const flagSrc = countryCode ? `https://flagcdn.com/w40/${countryCode}.png` : '';
        const elevation = liveData?.elevation ?? staticData.elevation_ft ?? 0;
        const coords = { lat: liveData?.latitude ?? staticData.lat, lon: liveData?.longitude ?? staticData.lon };
        
        const badge3DHtml = liveData?.has3dBuildings 
            ? `<span style="background: linear-gradient(135deg, #e2e8f0 0%, #94a3b8 100%); color: #0f172a; font-size: 0.65rem; font-weight: 800; padding: 2px 6px; border-radius: 4px; margin-left: 10px;">3D</span>` 
            : '';

        const airportRunways = runwaysData[icao] || [];

        // --- Weather & ATIS Logic ---
        let weatherModuleHtml = '';
        let atisModuleHtml = '';
        let metarString = '';
        // Hoisted so the at-a-glance stats bar can show the field's flight
        // category alongside traffic counts.
        let flightCategory = '---', catColor = '#a1a1aa';

        try {
            if (window.WeatherService) {
                const w = await window.WeatherService.fetchAndParseMetar(icao);
                flightCategory = 'VFR'; catColor = '#4ade80';

                if (w.raw.includes('LIFR')) {
                    flightCategory = 'LIFR'; catColor = '#c084fc';
                } else if (w.raw.includes('IFR') || w.raw.includes('VV')) {
                    flightCategory = 'IFR'; catColor = '#f87171';
                } else if (w.raw.includes('MVFR')) {
                    flightCategory = 'MVFR'; catColor = '#60a5fa';
                }

                metarString = w.raw;

                if (rawAtisText) {
                    const atis = parseAtis(rawAtisText);
                    const infoPill = `<span style="color: #fbbf24; border: 1px solid #fbbf24; padding: 0 4px; border-radius: 3px; font-size: 0.6rem;">INFO ${atis.info}</span>`;
                    const remarksHtml = atis.remarks ? `<div class="apt-mini-footer" title="${atis.remarks}"><i class="fa-solid fa-circle-info"></i> ${atis.remarks}</div>` : '';

                    atisModuleHtml = `
                    <div class="apt-mini-module">
                        <div class="apt-mini-header"><span><i class="fa-solid fa-tower-broadcast"></i> ATIS</span>${infoPill}</div>
                        <div class="apt-mini-body" style="padding-bottom: ${atis.remarks ? '0' : '10px'};">
                            <div class="stat-grid-compact">
                                <div class="compact-stat-box"><span class="compact-label">ARR RWY</span><span class="compact-value" style="color: #4ade80;">${atis.landing}</span></div>
                                <div class="compact-stat-box"><span class="compact-label">DEP RWY</span><span class="compact-value" style="color: #38bdf8;">${atis.departing}</span></div>
                                <div class="compact-stat-box"><span class="compact-label">APPR</span><span class="compact-value">${atis.approach}</span></div>
                                <div class="compact-stat-box"><span class="compact-label">TIME</span><span class="compact-value">${atis.time}</span></div>
                            </div>
                        </div>
                        ${remarksHtml}
                    </div>`;
                } else {
                    const recs = getRunwayRecommendations(airportRunways, w.wind);
                    const activeRunways = recs.slice(0, 2).map(r => r.ident).join('/');
                    atisModuleHtml = `
                    <div class="apt-mini-module">
                        <div class="apt-mini-header"><span><i class="fa-solid fa-calculator"></i> EST. OPS</span><span style="color: #94a3b8; border: 1px solid #475569; padding: 0 4px; border-radius: 3px; font-size: 0.6rem;">NO ATIS</span></div>
                        <div class="apt-mini-body">
                            <div class="stat-grid-compact">
                                <div class="compact-stat-box"><span class="compact-label">EST ARR</span><span class="compact-value" style="color: #4ade80;">${activeRunways || '---'}</span></div>
                                <div class="compact-stat-box"><span class="compact-label">EST DEP</span><span class="compact-value" style="color: #38bdf8;">${activeRunways || '---'}</span></div>
                                <div class="compact-stat-box"><span class="compact-label">WIND</span><span class="compact-value">${w.wind}</span></div>
                                <div class="compact-stat-box"><span class="compact-label">STATUS</span><span class="compact-value">CALC</span></div>
                            </div>
                        </div>
                    </div>`;
                }

                weatherModuleHtml = `
                <div class="apt-mini-module">
                    <div class="apt-mini-header"><span><i class="fa-solid fa-cloud-sun"></i> METAR</span><span style="color: ${catColor}; border: 1px solid ${catColor}; padding: 0 4px; border-radius: 3px; font-size: 0.6rem;">${flightCategory}</span></div>
                    <div class="apt-mini-body"><div class="stat-grid-compact">
                        <div class="compact-stat-box"><span class="compact-label">WIND</span><span class="compact-value" style="color: #38bdf8;">${w.wind}</span></div>
                        <div class="compact-stat-box"><span class="compact-label">VIS</span><span class="compact-value">${w.visibility || '10KM'}</span></div>
                        <div class="compact-stat-box"><span class="compact-label">TEMP</span><span class="compact-value" style="color: #fbbf24;">${w.temp}</span></div>
                        <div class="compact-stat-box"><span class="compact-label">QNH</span><span class="compact-value">${w.qnh || '1013'}</span></div>
                    </div></div>
                </div>`;
            }
        } catch (err) {
            weatherModuleHtml = `<div class="apt-mini-module"><div class="apt-mini-body"><p class="muted-text">Offline</p></div></div>`;
        }

        // --- Feature Strip ---
        let featureStripHtml = '';
        if (liveData) {
            const features = [
                { key: 'hasJetbridges', label: 'Jetbridges', icon: 'fa-person-walking-luggage' },
                { key: 'hasSafedockUnits', label: 'Safedock', icon: 'fa-square-parking' },
                { key: 'hasTaxiwayRouting', label: 'Drag & Taxi', icon: 'fa-route' }
            ];

            const aptClass = liveData.class ? `Class ${liveData.class}` : 'N/A';
            const timezone = liveData.timezone ? liveData.timezone.split(' ')[0] : 'UTC';

            featureStripHtml = `
            <div class="apt-quick-info-strip">
                <div class="apt-feature-pill"><i class="fa-solid fa-earth-americas"></i> ${timezone}</div>
                <div class="apt-feature-pill"><i class="fa-solid fa-ranking-star"></i> ${aptClass}</div>
                ${features.map(f => liveData[f.key] ? `<div class="apt-feature-pill" style="color: #cbd5e1; border-color: rgba(74, 222, 128, 0.3); background: rgba(74, 222, 128, 0.05);"><i class="fa-solid ${f.icon}" style="color: #4ade80;"></i> ${f.label}</div>` : '').join('')}
            </div>`;
        }

        // --- Traffic Visualizer Header & Legend ---
        const visualizerControlsHtml = `
            <div style="display: flex; align-items: center; justify-content: space-between; padding: 10px 16px; background: rgba(0,0,0,0.2); border-bottom: 1px solid var(--border-glass);">
                <div style="display: flex; flex-direction: column; gap: 2px;">
                    <span style="font-size: 0.75rem; font-weight: 700; color: #fff;">TRAFFIC VISUALIZER</span>
                    <span style="font-size: 0.6rem; color: #94a3b8; text-transform: uppercase;">Colorize Radar Map</span>
                </div>
                <label class="toggle-switch">
                    <input type="checkbox" id="traffic-highlight-toggle" ${isTrafficHighlightActive ? 'checked' : ''}>
                    <span class="toggle-slider"></span>
                </label>
            </div>
            <div id="traffic-visualizer-legend" style="display: flex; gap: 12px; padding: 8px 16px; background: rgba(255,255,255,0.02); font-size: 0.65rem; font-weight: 700; border-bottom: 1px solid var(--border-glass);">
            </div>
        `;

        const renderFlightCard = (fid, type) => {
            const f = currentMapFeatures[fid];
            if (!f || !f.properties) return '';
            const p = f.properties;
            
            const callsign = p.callsign || 'Unknown';
            const pilot = p.username || 'Pilot';
            
            // A single malformed aircraft payload must not take down the whole
            // airport window — busy fields have hundreds of flights and the odds
            // of one bad record are high, so parse defensively.
            let acData = {};
            try {
                acData = (typeof p.aircraft === 'string') ? JSON.parse(p.aircraft) : (p.aircraft || {});
            } catch (_) { acData = {}; }
            const acName = acData.aircraftName || '---';
            const shortAc = acName.split(' ')[0].toUpperCase();
            
            const dep = p.departureIcao || '???';
            const arr = p.arrivalIcao || '???';
            
            const imgUrl = p.communityImageUrl || 'Images/default_ac.png';
            
            const al = extractAirlineCode(callsign);
            const logoHtml = `<img src="Images/vas/${al}.png" style="height: 12px; width: auto; max-width: 30px; margin-right: 8px; filter: drop-shadow(0 2px 4px rgba(0,0,0,0.5));" onerror="this.style.display='none'">`;
            
            // The hero image is a lazy <img> rather than a CSS background so
            // WebKit only decodes the cards actually scrolled into view. A busy
            // field can list 50 inbound + 50 outbound cards; decoding 100 remote
            // images at once when the sheet slides open spikes memory enough to
            // get the web view jettisoned (the "crash"). loading="lazy" keeps the
            // off-screen ones from loading until the user scrolls to them.
            return `
            <div class="route-card-reborn">
                <img class="route-card-bg" src="${imgUrl}" loading="lazy" decoding="async" onerror="this.style.display='none'">
                <div class="card-overlay"></div>
                <div class="card-content">
                    <div class="card-header-zone">
                        <div class="callsign-meta">${logoHtml} ${callsign}</div>
                        <div class="aircraft-meta">${shortAc}</div>
                    </div>
                    <div class="card-center-zone">
                        <div class="route-display">
                            <span class="icao-code">${dep}</span>
                            <div class="route-path-arrow">
                                <i class="fa-solid fa-chevron-right" style="opacity: 0.3;"></i>
                            </div>
                            <span class="icao-code destination-focus">${arr}</span>
                        </div>
                    </div>
                    <div class="card-footer-zone">
                        <div class="operated-by-meta">OPERATED BY ${pilot.toUpperCase()}</div>
                        <div class="time-status-meta">ON TIME</div>
                    </div>
                </div>
            </div>
            `;
        };

        // Cap how many flight cards we build at once. At hub airports the
        // inbound/outbound lists can run to many hundreds; concatenating that
        // much HTML synchronously locks up (and can crash) the main thread, so
        // render a sensible slice and note the remainder.
        const MAX_TRAFFIC_CARDS = 50;
        const renderFlightList = (ids, type) => {
            const cards = ids.slice(0, MAX_TRAFFIC_CARDS).map(id => renderFlightCard(id, type)).join('');
            const hidden = ids.length - MAX_TRAFFIC_CARDS;
            const more = hidden > 0
                ? `<div style="padding: 10px 12px; text-align: center; color: #71717a; font-size: 0.72rem;">+${hidden} more not shown</div>`
                : '';
            return cards + more;
        };

        // --- UPDATED TRAFFIC HTML WITH DROPDOWNS ---
        let trafficHtml = (!trafficFetchSuccess) ?
            '<div style="padding: 20px; text-align: center; color: #71717a;">Data unavailable.</div>' :
            (inbounds.length === 0 && outbounds.length === 0) ?
            '<div style="padding: 20px; text-align: center; color: #71717a;">No live traffic.</div>' :
            `
            <div style="padding: 12px; display: flex; flex-direction: column; gap: 4px;">
                ${inbounds.length > 0 ? `
                <details class="traffic-dropdown" open>
                    <summary class="traffic-dropdown-header">
                        <i class="fa-solid fa-plane-arrival" style="margin-right: 10px; color: #4ade80;"></i>
                        <span>Inbounds</span>
                        <span class="traffic-count-badge">${inbounds.length}</span>
                        <i class="fa-solid fa-chevron-down chevron"></i>
                    </summary>
                    <div class="traffic-dropdown-content">
                        ${renderFlightList(inbounds, 'in')}
                    </div>
                </details>
                ` : ''}
                
                ${outbounds.length > 0 ? `
                <details class="traffic-dropdown" ${inbounds.length === 0 ? 'open' : ''}>
                    <summary class="traffic-dropdown-header">
                        <i class="fa-solid fa-plane-departure" style="margin-right: 10px; color: #38bdf8;"></i>
                        <span>Outbounds</span>
                        <span class="traffic-count-badge">${outbounds.length}</span>
                        <i class="fa-solid fa-chevron-down chevron"></i>
                    </summary>
                    <div class="traffic-dropdown-content">
                        ${renderFlightList(outbounds, 'out')}
                    </div>
                </details>
                ` : ''}
            </div>`;

        const airportAtc = activeAtcFacilities.filter(f => f.airportName === icao);
        let atcHtml = airportAtc.length === 0
            ? '<div style="padding: 20px; text-align: center; color: #71717a;">No active frequencies.</div>'
            : `<div style="padding: 12px;">${airportAtc.map(f => `<div class="atc-grid-card" style="padding: 8px;"><div style="display: flex; align-items: center; gap: 12px;"><span class="atc-type-badge ${f.type===1?'atc-type-twr':f.type===0?'atc-type-gnd':(f.type===4||f.type===5)?'atc-type-app':'atc-type-obs'}" style="width: 60px; font-size: 0.65rem;">${atcTypeToString(f.type)}</span><span class="atc-controller" style="font-size: 0.85rem;">${f.username||'Unknown'}</span></div><span class="atc-duration" style="font-size: 0.75rem;"><i class="fa-regular fa-clock"></i> ${formatAtcDuration(f.startTime)}</span></div>`).join('')}</div>`;

        // --- ATC Replay History (recorded controller sessions for this field) ---
        const atcSessions = await fetchAtcSessionsForAirport(icao);
        let atcHistoryHtml = atcSessions.length === 0
            ? '<div style="padding: 20px; text-align: center; color: #71717a;">No recorded ATC sessions in the last 48h.</div>'
            : `<div style="padding: 12px; display: flex; flex-direction: column; gap: 4px;">
                <div style="font-size: 0.65rem; color: #71717a; padding: 0 2px 6px; line-height: 1.4;">
                    Replay a controller's session — their facility, frequency timeline, and every flight that passed through their airspace. Recordings are kept for 48 hours.
                </div>
                ${atcSessions.map(renderAtcSessionCard).join('')}
            </div>`;

        const notamsList = activeNotams.filter(n => n.airportIcao === icao);
        let notamsHtml = notamsList.length === 0
            ? '<div style="padding: 10px 12px; color: #71717a; font-size: 0.75rem; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06); border-radius: 8px;">No active NOTAMs for this field.</div>'
            : `<div style="display: flex; flex-direction: column; gap: 8px;">${notamsList.map(n => `<div style="background: rgba(234, 179, 8, 0.1); border-left: 3px solid #eab308; padding: 8px; border-radius: 4px; color: #fef08a; font-family: monospace; font-size: 0.75rem;"><i class="fa-solid fa-triangle-exclamation"></i> ${n.message}</div>`).join('')}</div>`;

        // --- At-a-glance stats bar (under the hero) ---
        const atcCount = airportAtc.length;
        const statsBarHtml = `
            <div class="apt-stats-bar">
                <div class="apt-stat-cell">
                    <span class="apt-stat-value" style="color: ${trafficFetchSuccess && inbounds.length ? '#4ade80' : '#a1a1aa'};">${trafficFetchSuccess ? inbounds.length : '--'}</span>
                    <span class="apt-stat-label">Inbound</span>
                </div>
                <div class="apt-stat-cell">
                    <span class="apt-stat-value" style="color: ${trafficFetchSuccess && outbounds.length ? '#7dd3fc' : '#a1a1aa'};">${trafficFetchSuccess ? outbounds.length : '--'}</span>
                    <span class="apt-stat-label">Outbound</span>
                </div>
                <div class="apt-stat-cell">
                    <span class="apt-stat-value" style="color: ${atcCount ? '#fafafa' : '#a1a1aa'};">${atcCount}</span>
                    <span class="apt-stat-label">ATC Online</span>
                </div>
                <div class="apt-stat-cell">
                    <span class="apt-stat-value" style="color: ${catColor};">${flightCategory}</span>
                    <span class="apt-stat-label">Category</span>
                </div>
            </div>`;

        // --- INFO tab: airport details + runway database -------------------
        const openRunways = airportRunways.filter(r => !r.closed && (r.le_ident || r.he_ident));

        const surfaceNames = {
            ASP: 'Asphalt', ASPH: 'Asphalt', CON: 'Concrete', CONC: 'Concrete',
            GRVL: 'Gravel', GRV: 'Gravel', TURF: 'Grass', GRS: 'Grass',
            GRASS: 'Grass', DIRT: 'Dirt', WATER: 'Water', SAND: 'Sand'
        };
        const formatSurface = (s) => {
            if (!s) return 'Unknown';
            const key = String(s).toUpperCase().split(/[-/ ]/)[0];
            return surfaceNames[key] || s;
        };

        const runwaysHtml = openRunways.length === 0
            ? '<div style="padding: 10px 12px; color: #71717a; font-size: 0.75rem; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06); border-radius: 8px;">No runway data available.</div>'
            : `<div class="apt-runway-grid">${openRunways.map(r => {
                const ident = [r.le_ident, r.he_ident].filter(Boolean).join(' / ');
                const len = r.length_ft ? `${Number(r.length_ft).toLocaleString()} ft` : '—';
                const width = r.width_ft ? `${Number(r.width_ft).toLocaleString()} ft` : '—';
                return `
                <div class="apt-runway-card">
                    <div class="apt-runway-ident">
                        <span>${ident}</span>
                        ${r.lighted ? '<span class="apt-rwy-tag lit"><i class="fa-solid fa-lightbulb"></i> LIT</span>' : ''}
                    </div>
                    <div class="apt-runway-meta">
                        <span><i class="fa-solid fa-ruler-horizontal"></i>${len}</span>
                        <span><i class="fa-solid fa-ruler-vertical"></i>${width}</span>
                        <span><i class="fa-solid fa-layer-group"></i>${formatSurface(r.surface)}</span>
                    </div>
                </div>`;
            }).join('')}</div>`;

        const detailItems = [
            { icon: 'fa-location-crosshairs', label: 'Coordinates', value: (coords.lat != null && coords.lon != null) ? `${(+coords.lat).toFixed(3)}, ${(+coords.lon).toFixed(3)}` : '—' },
            { icon: 'fa-arrows-up-down', label: 'Elevation', value: `${elevation} ft` },
            { icon: 'fa-earth-americas', label: 'Timezone', value: liveData?.timezone ? liveData.timezone.split(' ')[0] : '—' },
            { icon: 'fa-flag', label: 'Country', value: countryCode ? countryCode.toUpperCase() : '—' },
            { icon: 'fa-ranking-star', label: 'Class', value: liveData?.class ? `Class ${liveData.class}` : '—' },
            { icon: 'fa-road', label: 'Runways', value: openRunways.length ? String(openRunways.length) : '—' }
        ];
        const detailsHtml = `<div class="apt-detail-grid">${detailItems.map(d => `
            <div class="apt-detail-row">
                <span class="apt-detail-label"><i class="fa-solid ${d.icon}" style="margin-right: 5px; opacity: 0.7;"></i>${d.label}</span>
                <span class="apt-detail-value">${d.value}</span>
            </div>`).join('')}</div>`;

        setTimeout(updateTrafficLegendUI, 0);

        return `
            <div class="airport-hero" style="background-image: url('${dynamicImageUrl}')">
                <div class="airport-hero-overlay"></div>
                <div class="hero-actions">
                    <button id="airport-window-close-btn" class="hero-btn" title="Close Window"><i class="fa-solid fa-xmark"></i></button>
                </div>
                <div class="apt-ident-group">
                    <div class="apt-icao">${icao}${flagSrc ? `<img src="${flagSrc}" style="height: 24px; border-radius: 2px; margin-left: 10px;">` : ''}${badge3DHtml}</div>
                    <div class="apt-name">${airportName}</div>
                    <div style="font-size: 0.8rem; color: #fff; margin-top: 2px; text-shadow: 0 1px 3px rgba(0,0,0,0.8);">${cityState}</div>
                </div>
            </div>

            ${statsBarHtml}

            ${featureStripHtml}

            <div style="flex-grow: 1; overflow-y: auto;">
                <div class="apt-dashboard-grid">${weatherModuleHtml}${atisModuleHtml}</div>

                <div class="tech-module" style="margin: 16px; border: 1px solid rgba(255,255,255,0.05);">
                    <div class="apt-tabs-header">
                        <button class="apt-tab-btn active" data-target="apt-traffic"><i class="fa-solid fa-plane-circle-check"></i> TRAFFIC</button>
                        <button class="apt-tab-btn" data-target="apt-atc"><i class="fa-solid fa-headset"></i> FREQS</button>
                        <button class="apt-tab-btn" data-target="apt-replay"><i class="fa-solid fa-circle-play"></i> REPLAY</button>
                        <button class="apt-tab-btn" data-target="apt-info"><i class="fa-solid fa-circle-info"></i> INFO</button>
                    </div>

                    <div id="apt-traffic" class="apt-tab-content active">
                        ${visualizerControlsHtml}
                        ${trafficHtml}
                    </div>

                    <div id="apt-atc" class="apt-tab-content">
                        ${atcHtml}
                    </div>

                    <div id="apt-replay" class="apt-tab-content">
                        ${atcHistoryHtml}
                    </div>

                    <div id="apt-info" class="apt-tab-content">
                        <div style="padding: 16px; display: flex; flex-direction: column; gap: 18px;">
                            <div>
                                <div class="apt-section-title"><i class="fa-solid fa-circle-info"></i> Airport Details</div>
                                ${detailsHtml}
                            </div>
                            <div>
                                <div class="apt-section-title"><i class="fa-solid fa-road"></i> Runways${openRunways.length ? ` (${openRunways.length})` : ''}</div>
                                ${runwaysHtml}
                            </div>
                            <div>
                                <div class="apt-section-title"><i class="fa-solid fa-triangle-exclamation"></i> NOTAMs</div>
                                ${notamsHtml}
                            </div>
                            <div>
                                <div class="apt-section-title"><i class="fa-solid fa-cloud"></i> Raw METAR</div>
                                <div class="metar-strip" style="border-radius: 6px; border: 1px solid var(--border-glass);">${metarString || 'N/A'}</div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }

    // --- Rank & Fleet Models ---
    const PILOT_RANKS = [
        'IndGo Cadet', 'Skyline Observer', 'Route Explorer', 'Skyline Officer',
        'Command Captain', 'Elite Captain', 'Blue Eagle', 'Line Instructor',
        'Chief Flight Instructor', 'IndGo SkyMaster', 'Blue Legacy Commander'
    ];
    const rankIndex = (r) => PILOT_RANKS.indexOf(String(r || '').trim());

    const deduceRankFromAircraftFE = (acStr) => {
        const s = String(acStr || '').toUpperCase();
        const has = (pat) => new RegExp(pat, 'i').test(s);
        if (has('(DH8D|Q400|A320|B738)')) return 'IndGo Cadet';
        if (has('(A321|B737|B739)')) return 'Skyline Observer';
        if (has('(A330|B38M)')) return 'Route Explorer';
        if (has('(787-8|B788|777-200LR|B77L)')) return 'Skyline Officer';
        if (has('(787-9|B789|777-300ER|B77W)')) return 'Command Captain';
        if (has('A350')) return 'Elite Captain';
        if (has('(A380|747|744|B744)')) return 'Blue Eagle';
        return 'Unknown';
    };

    const userCanFlyAircraft = (userRank, aircraftIcao) => {
        const ac = DYNAMIC_FLEET.find(a => a.icao === aircraftIcao);
        if (!ac) return false;
        const ui = rankIndex(userRank);
        const ri = rankIndex(ac.rankUnlock);
        return ui >= 0 && ri >= 0 && ri <= ui;
    };

    const getAllowedFleet = (userRank) => {
        return DYNAMIC_FLEET.filter(ac => {
            const userRankIndex = rankIndex(userRank);
            const aircraftRankIndex = rankIndex(ac.rankUnlock);
            return userRankIndex >= 0 && aircraftRankIndex >= 0 && aircraftRankIndex <= userRankIndex;
        });
    };

    // --- Notifications ---
    function showNotification(message, type) {
        Toastify({
            text: message,
            duration: 3000,
            close: true,
            gravity: "top",
            position: "right",
            stopOnFocus: true,
            style: { background: type === 'success' ? "#28a745" : type === 'error' ? "#dc3545" : "#27272a" }
        }).showToast();
    }

    window.showGlobalNotification = showNotification;

    // Build the Live Activity start payload from whatever state we currently have on the
    // open aircraft info window. Returns null if we don't have enough to fire yet.
    function buildLiveActivityPayload(flightId) {
        if (!flightId) return null;
        const feature = currentMapFeatures[flightId];
        if (!feature || !feature.properties) return null;
        const props = feature.properties;
        const windowEl = document.getElementById('aircraft-info-window');
        const depIcao = windowEl?.dataset.depIcao || props.depIcao || '';
        const arrIcao = windowEl?.dataset.arrIcao || props.arrIcao || '';
        if (!depIcao || !arrIcao || depIcao === 'N/A' || arrIcao === 'N/A') {
            return null;
        }

        const filedDepTime = windowEl?.dataset.filedDepTime || '';
        const filedDuration = parseFloat(windowEl?.dataset.filedDuration || '0');
        const schedDepMs = filedDepTime ? Date.parse(filedDepTime) : null;
        const schedArrMs = (schedDepMs && filedDuration > 0)
            ? schedDepMs + (filedDuration * 60 * 1000)
            : null;

        // Distance to destination (NM) for the live ETA estimate.
        let distanceNm = 0;
        const destLat = airportsData[arrIcao]?.lat;
        const destLon = airportsData[arrIcao]?.lon;
        if (destLat != null && destLon != null && props.position?.lat != null) {
            distanceNm = getDistanceKm(props.position.lat, props.position.lon, destLat, destLon) / 1.852;
        }

        // Total great-circle distance dep → arr. Captured once at start so
        // the Live Activity progress bar can render distance progress
        // without recomputing geometry on every refresh.
        let totalDistanceNm = 0;
        const depLat = airportsData[depIcao]?.lat;
        const depLon = airportsData[depIcao]?.lon;
        if (depLat != null && depLon != null && destLat != null && destLon != null) {
            totalDistanceNm = getDistanceKm(depLat, depLon, destLat, destLon) / 1.852;
        }
        if (totalDistanceNm < distanceNm) totalDistanceNm = distanceNm;

        // Hand the same cascade the in-app card uses (SCHEDULED → ACTUAL →
        // ESTIMATED) so the lock screen agrees with what's on screen.
        const cachedTrail = (typeof liveTrailCache !== 'undefined' && liveTrailCache.has(flightId))
            ? liveTrailCache.get(flightId)
            : null;
        const filedPlan = (schedDepMs && filedDuration > 0)
            ? { dep_time: filedDepTime, duration_minutes: filedDuration }
            : null;
        const depInfo = computeDepartureTimeInfo(props, cachedTrail, filedPlan, depIcao);
        const arrInfo = computeArrivalTimeInfo(props, filedPlan, distanceNm);

        // ETA: prefer the smart cascade's timestamp; fall back to a fresh
        // gs+distance estimate; finally fall back to scheduled arrival. The
        // old code's "now + 1h" fallback was producing wildly wrong ETEs
        // on the lock-screen countdown when the aircraft was slow/taxiing.
        const gs = props.position?.gs_kt || 0;
        let etaMs = arrInfo?.timestamp ? arrInfo.timestamp.getTime() : null;
        if (!etaMs && distanceNm > 0 && gs > 50) {
            etaMs = Date.now() + (distanceNm / gs) * 3600 * 1000;
        }
        if (!etaMs) etaMs = schedArrMs || (Date.now() + 60 * 60 * 1000);

        // ATD: only ACTUAL counts — the scheduled departure is conveyed
        // separately. If we don't have GPS history yet, leave it
        // undefined so the widget shows "scheduledDeparture" verbatim
        // instead of mislabeling the planned time as the actual takeoff.
        let atdMs;
        if (depInfo?.timestamp && depInfo.label === 'ACTUAL') {
            atdMs = depInfo.timestamp.getTime();
        }

        // Aircraft model + livery for the Live Activity. `props.aircraft` may
        // be a JSON blob (string or object) on some feeds, with the flat
        // props.aircraftName / props.liveryName as the fallback.
        let acBlob = {};
        try {
            acBlob = (typeof props.aircraft === 'string')
                ? JSON.parse(props.aircraft || '{}')
                : (props.aircraft || {});
        } catch (_) { acBlob = {}; }
        const aircraftType = acBlob.aircraftName || props.aircraftName || '';
        const liveryName   = acBlob.liveryName || props.liveryName || '';
        const registration = acBlob.registration || props.registration || props.tailNumber || '';

        return {
            flightId,
            callsign: props.callsign || flightId,
            airlineName: liveryName || aircraftType || '',
            aircraftType,
            liveryName,
            registration,
            departureIcao: depIcao,
            arrivalIcao: arrIcao,
            scheduledDeparture: schedDepMs || (atdMs || Date.now()),
            scheduledArrival: schedArrMs || etaMs,
            currentEta: etaMs,
            currentAtd: atdMs,
            distanceToDestinationNm: distanceNm,
            totalDistanceNm,
            isLanded: false
        };
    }
    window.buildLiveActivityPayload = buildLiveActivityPayload;

    // --- DOM elements ---
    const pilotNameElem = document.getElementById('pilot-name');
    const pilotCallsignElem = document.getElementById('pilot-callsign');
    const profilePictureElem = document.getElementById('profile-picture');
    const logoutButton = document.getElementById('logout-button');
    const mainContentContainer = document.querySelector('.main-content');
    const sidebarNav = document.querySelector('.sidebar-nav');
    const dashboardContainer = document.querySelector('.dashboard-container');
    const sidebarToggleBtn = document.getElementById('sidebar-toggle');
    const notificationsBell = document.getElementById('notifications-bell');
    const notificationsModal = document.getElementById('notifications-modal');

    // Modals
    const promotionModal = document.getElementById('promotion-modal');
    const arriveFlightModal = document.getElementById('arrive-flight-modal');

    // --- Mapbox Plotting Functions ---

 
function initializeLiveMap() {
    if (!MAPBOX_ACCESS_TOKEN) return;

    // Check if the container exists and the map hasn't been initialized yet
    if (document.getElementById('live-flights-map-container') && !liveFlightsMap) {
        liveFlightsMap = new mapboxgl.Map({
            container: 'live-flights-map-container',
            style: currentMapStyle, // [SYNCED] Uses global style state
            center: [78.9629, 22.5937],
            zoom: 2,
            minZoom: 0,
            projection: 'globe',
            
            // --- NEW FIX FOR TILE LOADING & LAG ---
            // 1. Removed fadeDuration: 0 (Let Mapbox use its default 300ms smooth crossfade).
            // 2. Disabled preserveDrawingBuffer (This was the #1 cause of panning lag).
            // 3. Increased prefetchZoomDelta to 4 (Stretches cached low-res tiles so you don't see the grid).
            maxTileCacheSize: 2000, 
            prefetchZoomDelta: 4, 
            crossSourceCollisions: false, 
            trackResize: true,
            performanceMetrics: false,
            localIdeographFontFamily: "'Inter', 'sans-serif'",
            preserveDrawingBuffer: false 
        });

        liveFlightsMap.on('load', startLiveLoop);
    } else {
        startLiveLoop();
    }
}

    /**
     * Starts or restarts the live flight update interval.
     */
    function startLiveLoop() {
        if (!liveFlightsInterval) {
            updateLiveFlights();
            liveFlightsInterval = setInterval(updateLiveFlights, 3000);
        }
    }

    /**
     * Helper to remove dynamic flight path layers from the map.
     */
    function removeFlightPathLayers(map) {
        if (map.getLayer('flown-path')) map.removeLayer('flown-path');
        if (map.getSource('flown-path-source')) map.removeSource('flown-path-source');
        if (map.getLayer('planned-path')) map.removeLayer('planned-path');
        if (map.getSource('planned-path-source')) map.removeSource('planned-path-source');
    }

/**
 * Fetches live flight data and updates the map.
 */
async function updateLiveFlights() {
    if (!liveFlightsMap || !liveFlightsMap.isStyleLoaded()) return;

    try {
        const sessionsRes = await fetch('https://site--acars-backend--6dmjph8ltlhv.code.run/if-sessions');
        const expertSession = (await sessionsRes.json()).sessions.find(s => s.name.toLowerCase().includes('expert'));
        if (!expertSession) {
            console.warn('No Expert Server session found for live flights.');
            return;
        }

        const response = await fetch(`${LIVE_FLIGHTS_API_URL}/${expertSession.id}?callsignEndsWith=GO`);
        const flights = (await response.json()).flights || [];
        const activeFlightIds = new Set();

        flights.forEach(f => {
            const { flightId, position: pos, callsign, username } = f;
            if (!flightId || !pos || pos.lat == null || pos.lon == null) return;

            activeFlightIds.add(flightId);
            const lngLat = [pos.lon, pos.lat];

            if (pilotMarkers[flightId]) {
                // Update existing marker
                const entry = pilotMarkers[flightId];
                entry.marker.setLngLat(lngLat);
                // ⬇️ MODIFIED: Use heading_deg as track_deg is no longer sent
                entry.marker.getElement().style.transform = `rotate(${pos.heading_deg ?? 0}deg)`;
            } else {
                // Create new marker
                const el = document.createElement('div');
                el.className = 'plane-marker';
                const marker = new mapboxgl.Marker(el).setLngLat(lngLat).addTo(liveFlightsMap);
                pilotMarkers[flightId] = { marker: marker };

                // Add click event listener
                marker.getElement().addEventListener('click', async () => {
                    removeFlightPathLayers(liveFlightsMap);
                    const popup = new mapboxgl.Popup({ closeButton: false, offset: 25 }).setLngLat(lngLat).setHTML(`<b>${callsign}</b><br><i>Loading flight data...</i>`).addTo(liveFlightsMap);

                    try {
                        const [planRes, routeRes] = await Promise.all([
                            fetch(`${LIVE_FLIGHTS_API_URL}/${expertSession.id}/${flightId}/plan`),
                            fetch(`${LIVE_FLIGHTS_API_URL.replace('/flights', '/api/flights')}/${flightProps.flightId}/history`)
                        ]);
                        const planJson = await planRes.json();
                        const routeJson = await routeRes.json();
let allCoordsForBounds = [];

// Support both the new .path key and coordinate fallback (lat/latitude)
const historyArray = routeJson?.path || routeJson?.route || [];

const flownCoords = (routeRes.ok && routeJson.ok && Array.isArray(historyArray)) 
    ? historyArray.map(p => [p.lon ?? p.longitude, p.lat ?? p.latitude]) 
    : [];
                        if (flownCoords.length > 1) {
                            allCoordsForBounds.push(...flownCoords);
                            liveFlightsMap.addSource('flown-path-source', { type: 'geojson', data: { type: 'Feature', geometry: { type: 'LineString', coordinates: flownCoords } } });
                            liveFlightsMap.addLayer({ id: 'flown-path',
    type: 'line',
    source: 'flown-path-source',
    paint: {
        'line-color': '#81D4FA', // Defaulting to the light blue enroute color
        'line-width': 2          // Matches the thinner width
    } });
                        }

                        // Planned path
                        if (planRes.ok && planJson.ok && Array.isArray(planJson?.plan?.flightPlanItems) && planJson.plan.flightPlanItems.length > 0) {
                            const nextIdx = (typeof planJson?.plan?.nextWaypointIndex === 'number') ? planJson.plan.nextWaypointIndex : 0;
                            const items = Array.isArray(planJson.plan.flightPlanItems) ? planJson.plan.flightPlanItems.slice(nextIdx) : [];
                            const plannedWps = flattenWaypointsFromPlan(items);
                            const remainingPathCoords = [lngLat, ...plannedWps];
                            allCoordsForBounds.push(...remainingPathCoords);
                            liveFlightsMap.addSource('planned-path-source', { type: 'geojson', data: { type: 'Feature', geometry: { type: 'LineString', coordinates: remainingPathCoords } } });
                            liveFlightsMap.addLayer({ id: 'planned-path', type: 'line', source: 'planned-path-source', paint: { 'line-color': '#e84393', 'line-width': 3, 'line-dasharray': [2, 2] } });
                            popup.setHTML(`<b>${callsign}</b> (${username || 'N/A'})<br>Route and flight plan loaded.`);
                        } else {
                            popup.setHTML(`<b>${callsign}</b> (${username || 'N/A'})<br>No flight plan filed.`);
                        }

                        if (allCoordsForBounds.length > 0) {
                            const bounds = allCoordsForBounds.reduce((b, coord) => b.extend(coord), new mapboxgl.LngLatBounds(allCoordsForBounds[0], allCoordsForBounds[0]));
                            liveFlightsMap.fitBounds(bounds, { padding: 60, maxZoom: 10 });
                        }
                    } catch (err) {
                        console.error("Failed to fetch/render flight paths:", err);
                        popup.setHTML(`<b>${callsign}</b> (${username || 'N/A'})<br>Could not load flight data.`);
                    }
                });
            }
        });

        // Remove inactive markers
        Object.keys(pilotMarkers).forEach(fid => {
            if (!activeFlightIds.has(String(fid))) {
                pilotMarkers[fid].marker?.remove();
                delete pilotMarkers[fid];
            }
        });
    } catch (err) {
        console.error('Error updating live flights:', err);
    }
}

/**
 * --- [NEW] Master Handler for Pro 3D Layers ---
 * Called whenever filters change to sync state.
 */
function updatePro3DLayers() {
    if (!sectorOpsMap) return;
    
    // 1. Update Elevation (Terrain)
    if (mapFilters.proMapConfig.showTerrain) {
        if (!sectorOpsMap.getSource('mapbox-dem')) {
            sectorOpsMap.addSource('mapbox-dem', {
                'type': 'raster-dem',
                'url': 'mapbox://mapbox.mapbox-terrain-dem-v1',
                'tileSize': 512,
                'maxzoom': 14
            });
        }
        sectorOpsMap.setTerrain({ 'source': 'mapbox-dem', 'exaggeration': 1.5 });
    } else {
        sectorOpsMap.setTerrain(null);
    }

    // 2. Update 3D Buildings
    const buildingsLayerId = '3d-buildings';
    if (mapFilters.proMapConfig.showBuildings) {
        if (!sectorOpsMap.getLayer(buildingsLayerId)) {
            // Insert buildings below labels but above base map
            const labelLayerId = sectorOpsMap.getStyle().layers.find(
                (l) => l.type === 'symbol' && l.layout['text-field']
            )?.id;

            sectorOpsMap.addLayer({
                'id': buildingsLayerId,
                'source': 'composite',
                'source-layer': 'building',
                'filter': ['==', 'extrude', 'true'],
                'type': 'fill-extrusion',
                'minzoom': 13,
                'paint': {
                    'fill-extrusion-color': '#27272a', // Dark zinc color
                    'fill-extrusion-height': ['get', 'height'],
                    'fill-extrusion-base': ['get', 'min_height'],
                    'fill-extrusion-opacity': 0.9
                }
            }, labelLayerId);
        } else {
            sectorOpsMap.setLayoutProperty(buildingsLayerId, 'visibility', 'visible');
        }
    } else {
        if (sectorOpsMap.getLayer(buildingsLayerId)) {
            sectorOpsMap.setLayoutProperty(buildingsLayerId, 'visibility', 'none');
        }
    }

    // 3. Update Day/Night Terminator
    updateDayNightTerminator();
}

/**
 * --- PRO Day/Night Terminator ---
 * Features: High-res geometry, Twilight gradient blur, Date-line glitch protection.
 */
let dayNightInterval = null;

function updateDayNightTerminator() {
    // Ensure map exists
    if (!sectorOpsMap) return;

    const sourceId = 'day-night-source';
    const fillLayerId = 'day-night-fill';   // The solid night
    const glowLayerId = 'day-night-glow';   // The twilight fade

    // Check if the user wants to see it
    const isVisible = mapFilters.proMapConfig.showDayNight;

    if (isVisible) {
        // 1. Create Source if it doesn't exist
        if (!sectorOpsMap.getSource(sourceId)) {
            sectorOpsMap.addSource(sourceId, {
                type: 'geojson',
                data: generateAccurateTerminator() // Initial Data
            });

            // LAYER A: The Deep Night (Fill)
            // Placed at the very bottom so it covers water/land but sits under routes
            sectorOpsMap.addLayer({
                id: fillLayerId,
                type: 'fill',
                source: sourceId,
                paint: {
                    'fill-color': '#020617', // Deep Navy/Black (Slate-950)
                    'fill-opacity': 0.45     // Subtle darkness
                }
            }, 'sector-ops-live-flights-layer'); // Ensure it's below planes

            // LAYER B: The Twilight (Blurred Line)
            // This creates the soft fade at the edge of darkness
            sectorOpsMap.addLayer({
                id: glowLayerId,
                type: 'line',
                source: sourceId,
                layout: { 'line-join': 'round', 'line-cap': 'round' },
                paint: {
                    'line-color': '#020617', // Match the fill color
                    'line-width': 45,        // Wide stroke
                    'line-blur': 30,         // Heavy blur creates the gradient
                    'line-opacity': 0.4
                }
            }, fillLayerId); // Sit right on top of the fill
        } 
        // 2. If it exists, just ensure it's visible and updated
        else {
            sectorOpsMap.setLayoutProperty(fillLayerId, 'visibility', 'visible');
            sectorOpsMap.setLayoutProperty(glowLayerId, 'visibility', 'visible');
            sectorOpsMap.getSource(sourceId).setData(generateAccurateTerminator());
        }

        // 3. Auto-update every minute (Sun moves!)
        if (!dayNightInterval) {
            dayNightInterval = setInterval(() => {
                if (sectorOpsMap.getSource(sourceId)) {
                    sectorOpsMap.getSource(sourceId).setData(generateAccurateTerminator());
                }
            }, 60000);
        }

    } else {
        // Hide if disabled
        if (sectorOpsMap.getLayer(fillLayerId)) sectorOpsMap.setLayoutProperty(fillLayerId, 'visibility', 'none');
        if (sectorOpsMap.getLayer(glowLayerId)) sectorOpsMap.setLayoutProperty(glowLayerId, 'visibility', 'none');
        
        // Kill the timer to save resources
        if (dayNightInterval) {
            clearInterval(dayNightInterval);
            dayNightInterval = null;
        }
    }
}

/**
 * Generates the geometry for the night side of Earth.
 * Handles the 180-degree meridian wrapping to prevent map glitches.
 */
function generateAccurateTerminator() {
    const now = new Date();
    
    // 1. Calculate Sun Position (Simplified equations for speed/accuracy balance)
    // We need the "Anti-Sun" (the center of the night)
    const rad = Math.PI / 180;
    const deg = 180 / Math.PI;

    // Day of year and time
    const start = new Date(now.getFullYear(), 0, 0);
    const diff = now - start;
    const dayOfYear = Math.floor(diff / (1000 * 60 * 60 * 24));
    const utcHours = now.getUTCHours() + (now.getUTCMinutes() / 60);

    // Solar Declination (Tilt)
    const declination = -23.44 * Math.cos(rad * (360 / 365) * (dayOfYear + 10));
    
    // Solar Longitude (Greenwich Hour Angle)
    // Sun moves 15 deg/hour. Noon UTC = 0 deg (approx). 
    let sunLon = 180 - (15 * utcHours);
    
    // Normalize to -180 to 180
    if (sunLon > 180) sunLon -= 360;
    if (sunLon < -180) sunLon += 360;

    // Night Center is opposite the sun
    let nightLon = sunLon + 180;
    if (nightLon > 180) nightLon -= 360;
    const nightLat = -declination;

    // 2. Generate Circle Coordinates
    const coords = [];
    const steps = 90; // 4 degrees per step is smooth enough with the blur
    const R = 90 * rad; // 90 degrees radius (Hemisphere)
    
    const phi1 = nightLat * rad;
    const lam0 = nightLon * rad;

    for (let i = 0; i <= steps; i++) {
        const theta = (i / steps) * 2 * Math.PI;

        const phi = Math.asin(Math.sin(phi1) * Math.cos(R) + Math.cos(phi1) * Math.sin(R) * Math.cos(theta));
        const lam = lam0 + Math.atan2(Math.sin(theta) * Math.sin(R) * Math.cos(phi1), Math.cos(R) - Math.sin(phi1) * Math.sin(phi));

        let lon = lam * deg;
        let lat = phi * deg;

        coords.push([lon, lat]);
    }

    // 3. Fix the "World Wrap" (The Anti-Meridian Glitch)
    // Mapbox needs the polygon to be continuous. If we cross -180/180, we must split or unwrap.
    // The simplest visual hack for a full world cover is unrolled coordinates or a multi-polygon.
    // However, for the "Shadow", the easiest robust method is:
    // Just ensure the array is closed and clean. 
    coords.push(coords[0]);

    // Note: If you see "triangles" shooting across the screen, 
    // it means the polygon crossed the date line.
    // This simple math usually keeps the circle intact, but if glitches persist, 
    // we simply limit the longitudes or use a library like 'terminator-geojson'. 
    // For this implementation, we assume standard projection handling.

    return {
        type: 'Feature',
        properties: {},
        geometry: {
            type: 'Polygon',
            coordinates: [coords]
        }
    };
}



/**
 * --- [NEW] PRO FEATURE: BASE MAP LAYER MANAGER ---
 * Dynamically toggles visibility and forces CHART COLORS on Mapbox base layers.
 * Aggressively targets 'aeroway' source layers to ensure Taxiways = Yellow, Runways = Dark.
 */
function updateBaseMapLayerVisibility() {
    if (!sectorOpsMap || !sectorOpsMap.getStyle()) return;

    const layers = sectorOpsMap.getStyle().layers;
    const config = mapFilters.proMapConfig;

    // Define Chart Colors
    const COLOR_TAXIWAY = '#FACC15'; // Bright Yellow
    const COLOR_RUNWAY = '#18181b';  // Zinc-950 (Very Dark Concrete)
    const COLOR_RUNWAY_OUTLINE = '#52525b'; // Zinc-600 (Lighter Outline)

    let modifiedCount = 0;

    layers.forEach(layer => {
        const id = layer.id.toLowerCase();
        // Check specific Mapbox source layer if available (more reliable than ID)
        const sourceLayer = (layer['source-layer'] || '').toLowerCase();
        
        // Skip custom app layers
        if (id.includes('sector-ops') || id.includes('rainviewer') || id.includes('active-sectors')) return;

        let isVisible = true;
        let isAeroway = false;

        // --- 1. Airport Layout (Runways, Taxiways, Aprons) ---
        if (id.includes('aeroway') || sourceLayer === 'aeroway' || id.includes('runway') || id.includes('taxiway')) {
            isVisible = (config.showAirportLayout !== false);
            isAeroway = true;

            // FORCE COLORS if enabled
            if (isVisible) {
                const isTaxiway = id.includes('taxiway') || sourceLayer.includes('taxiway');
                const isRunway = id.includes('runway') || sourceLayer.includes('runway');
                
                // We only style Lines and Fills (ignoring symbols/text labels here)
                if (layer.type === 'line') {
                    if (isTaxiway) {
                        sectorOpsMap.setPaintProperty(layer.id, 'line-color', COLOR_TAXIWAY);
                        // Force width to make them visible if they are too thin
                        if(sectorOpsMap.getPaintProperty(layer.id, 'line-width') < 1) {
                             sectorOpsMap.setPaintProperty(layer.id, 'line-width', 2);
                        }
                    } else if (isRunway) {
                        sectorOpsMap.setPaintProperty(layer.id, 'line-color', COLOR_RUNWAY_OUTLINE);
                    }
                } 
                else if (layer.type === 'fill') {
                    if (isTaxiway) {
                        sectorOpsMap.setPaintProperty(layer.id, 'fill-color', COLOR_TAXIWAY);
                        sectorOpsMap.setPaintProperty(layer.id, 'fill-opacity', 1); // Ensure it's not transparent
                    } else if (isRunway) {
                        sectorOpsMap.setPaintProperty(layer.id, 'fill-color', COLOR_RUNWAY);
                        sectorOpsMap.setPaintProperty(layer.id, 'fill-opacity', 1);
                    }
                }
                modifiedCount++;
            }
        }
        
        // --- 2. Political Borders ---
        else if (id.includes('admin') || id.includes('boundary')) {
            isVisible = config.showBorders;
        }
        // --- 3. Roads & Transport ---
        else if (id.includes('road') || id.includes('tunnel') || id.includes('bridge') || id.includes('transit')) {
            isVisible = config.showRoads;
        }
        // --- 4. POIs ---
        else if (id.includes('poi')) {
            isVisible = config.showPois;
        }
        // --- 5. Water Labels ---
        else if (id.includes('water') && (id.includes('label') || id.includes('text'))) {
            isVisible = config.showWaterLabels;
        }
        // --- 6. Terrain Hillshading ---
        else if (id.includes('hillshade')) {
            isVisible = (config.showTerrain !== false);
        }
        // --- 7. Land Use ---
        else if (id.includes('landuse') || id.includes('landcover') || id.includes('national-park')) {
            isVisible = (config.showLandUse !== false);
        }
        // --- 8. General Place Labels ---
        else if ((id.includes('label') || id.includes('text') || id.includes('place')) && !id.includes('water') && !isAeroway) {
            isVisible = config.showLabels;
        }

        // Apply visibility
        if (sectorOpsMap.getLayoutProperty(layer.id, 'visibility') !== (isVisible ? 'visible' : 'none')) {
            sectorOpsMap.setLayoutProperty(layer.id, 'visibility', isVisible ? 'visible' : 'none');
        }
    });
}

function applyTrafficHighlighting() {
    const { in: inbounds, out: outbounds } = window.currentAirportTraffic || { in: [], out: [] };
    const inSet = new Set(inbounds);
    const outSet = new Set(outbounds);

    // Update feature properties in the cache
    Object.values(currentMapFeatures).forEach(f => {
        const fid = f.properties.flightId;
        if (isTrafficHighlightActive) {
            if (inSet.has(fid)) f.properties.trafficType = 'inbound';
            else if (outSet.has(fid)) f.properties.trafficType = 'outbound';
            else f.properties.trafficType = 'none';
        } else {
            f.properties.trafficType = 'none';
        }
    });

    // 1. Update the layer expressions across both aircraft layers + hover.
    //    Inbound/outbound planes now need the SDF sprite so they can be tinted,
    //    which the icon-image expressions handle automatically.
    applyAircraftLayerStyles();

    // 2. Sync the updated data to the Mapbox source
    if (sectorOpsMap && sectorOpsMap.getSource('sector-ops-live-flights-source')) {
        sectorOpsMap.getSource('sector-ops-live-flights-source').setData({
            type: 'FeatureCollection',
            features: Object.values(currentMapFeatures)
        });
    }
}

function updateTrafficLegendUI() {
    const legendEl = document.getElementById('traffic-visualizer-legend');
    if (!legendEl) return;

    const currentMode = mapFilters.iconColorMode || 'default';
    let inColor = '#fff', outColor = '#fff', inLabel = 'AIRCRAFT', outLabel = 'AIRCRAFT';

    if (isTrafficHighlightActive) {
        // Inbound is always cyan and outbound always amber; for Blue/Orange we
        // grey out the dot that matches the fleet tint so the highlight reads.
        if (currentMode === 'blue') { inColor = '#fff'; outColor = '#f59e0b'; }
        else if (currentMode === 'orange') { inColor = '#38bdf8'; outColor = '#fff'; }
        else { inColor = '#38bdf8'; outColor = '#f59e0b'; } // default (White) + custom
        inLabel = 'INBOUND'; outLabel = 'OUTBOUND';
    } else {
        inColor = (currentMode === 'blue') ? '#38bdf8' : (currentMode === 'orange') ? '#f59e0b' : (currentMode === 'custom') ? (mapFilters.proCustomColor || '#38bdf8') : '#fff';
        inLabel = 'ALL TRAFFIC';
    }

    legendEl.innerHTML = `
        <div style="display: flex; align-items: center; gap: 6px;">
            <div style="width: 8px; height: 8px; border-radius: 50%; background: ${inColor}; box-shadow: 0 0 5px ${inColor}80;"></div>
            <span style="color: ${inColor}; opacity: 0.9;">${inLabel}</span>
        </div>
        ${isTrafficHighlightActive ? `
        <div style="display: flex; align-items: center; gap: 6px;">
            <div style="width: 8px; height: 8px; border-radius: 50%; background: ${outColor}; box-shadow: 0 0 5px ${outColor}80;"></div>
            <span style="color: ${outColor}; opacity: 0.9;">${outLabel}</span>
        </div>` : ''}
    `;
}


    // Launch the ATC session replay for a recorded controller session. Mirrors
    // the flight-replay launch flow: get the competing chrome out of the way so
    // the docked replay panel + map are unobstructed, then restore it once the
    // replay tears itself down.
    function launchAtcReplay(key, apt, user, uid) {
        if (!key) {
            showNotification?.('No ATC session selected to replay.', 'error');
            return;
        }
        if (typeof AtcReplay === 'undefined' || !sectorOpsMap) return;

        const replayUrl = `${ACARS_SOCKET_URL}/api/atc/replay?key=${encodeURIComponent(key)}`;
        const isMobile = !!(window.MobileUIHandler && window.MobileUIHandler.isMobile());

        const uiToToggle = [];
        let reopenAirportOnClose = false;
        // Remember which airport to restore on close. We re-open it by replaying
        // the full handleAirportClick() flow rather than just re-showing the
        // sheet, because MobileUIHandler.openWindow() only animates the sheet in
        // when it observes a content mutation — re-showing an already-populated
        // window produces no mutation, so the sheet would stay off-screen.
        const airportToReopen = currentAirportInWindow;

        if (isMobile) {
            // On mobile the airport window is presented through MobileUIHandler
            // as a legacy sheet plus a dimming scrim (#mobile-window-overlay)
            // over the map. The original #airport-info-window isn't even marked
            // .visible, so soft-hiding it does nothing and the scrim stays up,
            // blacking out the map behind the replay. Tear the sheet down
            // properly and reopen it when the replay closes.
            reopenAirportOnClose = !!currentAirportInWindow;
            window.MobileUIHandler.closeActiveWindow(true);
        } else {
            // Desktop: soft-hide the floating chrome that competes with the
            // bottom-docked replay panel and restore it verbatim on close.
            const remember = (el) => {
                if (el && el.classList && el.classList.contains('visible')) {
                    uiToToggle.push(el);
                    el.classList.remove('visible');
                }
            };
            remember(document.getElementById('airport-info-window'));
            remember(document.getElementById('aircraft-info-window'));
            remember(document.getElementById('sector-ops-floating-panel'));
            remember(document.getElementById('weather-settings-window'));
            remember(document.getElementById('filter-settings-window'));
            if (typeof airportInfoWindowRecallBtn !== 'undefined' && airportInfoWindowRecallBtn) {
                airportInfoWindowRecallBtn.classList.remove('visible');
            }
        }

        // The toolbar row is only ours to manage on desktop — on mobile
        // MobileUIHandler owns showing/hiding it around its own windows.
        const toolbarToggleBtnEl = document.getElementById('toolbar-toggle-panel-btn');
        const toolbarRow = toolbarToggleBtnEl ? toolbarToggleBtnEl.parentElement : null;
        let prevToolbarDisplay = null;
        if (!isMobile && toolbarRow) {
            prevToolbarDisplay = toolbarRow.style.display;
            toolbarRow.style.display = 'none';
        }

        // The live 3D dot field (LiveTraffic3D) is a separate THREE custom layer
        // from the flat sector-ops icons the replay hides internally — so it would
        // otherwise keep rendering live contacts on top of the historical replay.
        // Suppress it for the duration (without touching the saved preference) and
        // restore it on close if it was on.
        const wasLive3D = (typeof LiveTraffic3D !== 'undefined') && LiveTraffic3D.isVisible();
        if (wasLive3D) { try { LiveTraffic3D.setVisible(false); } catch (_) {} }

        AtcReplay.open({
            map: sectorOpsMap,
            replayUrl,
            meta: { airportName: apt, username: user, userId: uid || null, apiBase: ACARS_SOCKET_URL },
            onClose: () => {
                if (wasLive3D) { try { LiveTraffic3D.setVisible(true); } catch (_) {} }
                if (isMobile) {
                    // Re-run the full open flow so the sheet's content mutates and
                    // MobileUIHandler animates it back in (a bare openWindow on an
                    // unchanged window never fires its content observer).
                    if (reopenAirportOnClose && airportToReopen && typeof handleAirportClick === 'function') {
                        handleAirportClick(airportToReopen);
                    }
                } else {
                    uiToToggle.forEach(el => { if (el && el.classList) el.classList.add('visible'); });
                    if (toolbarRow) toolbarRow.style.display = prevToolbarDisplay || '';
                }
            }
        });
    }

    function setupAirportWindowEvents() {
    if (!airportInfoWindow || airportInfoWindow.dataset.eventsAttached === 'true') return;

    airportInfoWindow.addEventListener('click', (e) => {
        const closeBtn = e.target.closest('#airport-window-close-btn');
        const hideBtn = e.target.closest('#airport-window-hide-btn');
        const trafficToggle = e.target.closest('#traffic-highlight-toggle');
        const atcReplayBtn = e.target.closest('.atc-replay-session-btn');

        // [NEW] ATC Session Replay launcher
        if (atcReplayBtn) {
            e.preventDefault();
            launchAtcReplay(
                atcReplayBtn.dataset.atcKey,
                atcReplayBtn.dataset.atcApt,
                atcReplayBtn.dataset.atcUser,
                atcReplayBtn.dataset.atcUid
            );
            return;
        }

        // [NEW] Traffic Visualizer Toggle Handler
        if (trafficToggle) {
            isTrafficHighlightActive = trafficToggle.checked;
            applyTrafficHighlighting();
            updateTrafficLegendUI();
        }

        if (closeBtn) {
            // Cleanup: Turn visualizer OFF when closing the window
            isTrafficHighlightActive = false;
            applyTrafficHighlighting();
            airportInfoWindow.classList.remove('visible');
            if (window.MobileUIHandler) MobileUIHandler.closeActiveWindow();
            airportInfoWindowRecallBtn.classList.remove('visible');
            clearRouteLayers();
            if (typeof AirportLayoutManager !== 'undefined' && sectorOpsMap) AirportLayoutManager.clearAll(sectorOpsMap);
            currentAirportInWindow = null;
            if (!currentFlightInWindow) {
        const landingData = {
            server: currentServerName,
            flights: Object.keys(currentMapFeatures).length,
            atc: activeAtcFacilities.length
        };
        LandingUI.update(true, landingData);
        localStorage.setItem('landingUI_visible', 'true');
        localStorage.setItem('landingUI_data', JSON.stringify(landingData));
    }
        }

        if (hideBtn) {
            airportInfoWindow.classList.remove('visible');
            if (currentAirportInWindow) airportInfoWindowRecallBtn.classList.add('visible');
        }
    });

    airportInfoWindow.addEventListener('change', (e) => {
        const typeSelect = e.target.closest('#traffic-type-select');
        if (typeSelect) {
            const val = typeSelect.value;
            const inList = airportInfoWindow.querySelector('#inbound-list');
            const outList = airportInfoWindow.querySelector('#outbound-list');
            
            if (val === 'inbound') {
                if(inList) inList.style.display = 'block';
                if(outList) outList.style.display = 'none';
            } else if (val === 'outbound') {
                if(inList) inList.style.display = 'none';
                if(outList) outList.style.display = 'block';
            } else {
                // Show All
                if(inList) inList.style.display = 'block';
                if(outList) outList.style.display = 'block';
            }
        }
    });

    airportInfoWindowRecallBtn.addEventListener('click', () => {
        if (currentAirportInWindow) {
            airportInfoWindow.classList.add('visible');
            airportInfoWindowRecallBtn.classList.remove('visible');
        }
    });

    airportInfoWindow.dataset.eventsAttached = 'true';
}
    

function setupAircraftWindowEvents() {
        if (!aircraftInfoWindow || aircraftInfoWindow.dataset.eventsAttached === 'true') return;

        // Bell logic extracted so the mobile sector-ops proxy can call it
        // directly against the visible button — the desktop click delegation
        // doesn't see clicks on bells that have been moved into the island.
        async function handleTrackmeBellClick(trackMeBtn) {
            if (!trackMeBtn) return;
            const flightId = trackMeBtn.dataset.flightId || currentFlightInWindow;
            if (!flightId) return;
            if (window.InflightLiveActivity?.isTrackingFlight(flightId)) {
                await window.InflightLiveActivity.end({ flightId });
                showNotification?.('Live Activity stopped.', 'info');
            } else {
                await window.InflightLiveActivity?.requestNotificationPermission?.({ force: true });

                // Plan limit: free tracks 1 flight, Pro tracks up to 3.
                const limit = window.InflightLiveActivity?.getTrackingLimit?.() ?? 1;
                const count = window.InflightLiveActivity?.getTrackedCount?.() ?? 0;
                const isPro = (typeof window.isInflightPro === 'function') ? window.isInflightPro() : false;
                if (count >= limit) {
                    if (isPro) {
                        // At the Pro cap — don't silently drop one of their
                        // flights; ask them to free a slot from the Inflight tab.
                        showNotification?.(`You're tracking the maximum of ${limit} flights. Stop one from the Inflight tab to add another.`, 'info');
                        return;
                    }
                    // Free tier: silently swap out the existing tracked flight.
                    const prior = window.InflightLiveActivity?.getTrackedFlightId();
                    if (prior && prior !== flightId) {
                        await window.InflightLiveActivity.end({ flightId: prior });
                    }
                }
                const payload = (typeof buildLiveActivityPayload === 'function')
                    ? buildLiveActivityPayload(flightId)
                    : null;
                if (!payload) {
                    showNotification?.('Could not read flight data yet — try again in a moment.', 'error');
                    return;
                }
                const res = await window.InflightLiveActivity.start(payload);
                if (res?.ok) {
                    showNotification?.('Tracking on Lock Screen.', 'success');
                } else if (res?.reason === 'unsupported') {
                    showNotification?.('Live Activities not available on this device.', 'error');
                } else {
                    const reason = (res && res.reason) ? String(res.reason) : 'unknown';
                    const short = reason.length > 140 ? reason.slice(0, 140) + '…' : reason;
                    console.error('[LiveActivity] start failed:', res);
                    showNotification?.(`Could not start Live Activity: ${short}`, 'error');
                }
            }
            const icon = trackMeBtn.querySelector('i');
            if (icon) {
                icon.classList.toggle('fa-bell');
                icon.classList.toggle('fa-bell-slash');
            }
        }
        window.handleTrackmeBellClick = handleTrackmeBellClick;

        aircraftInfoWindow.addEventListener('click', async (e) => {
            const closeBtn = e.target.closest('.aircraft-window-close-btn');
            const pinBtn = e.target.closest('.aircraft-window-pin-btn');
            const shareBtn = e.target.closest('.aircraft-window-share-btn');
            const replayBtn = e.target.closest('.aircraft-window-replay-btn');
            const trackMeBtn = e.target.closest('.aircraft-window-trackme-btn');
            const tabBtn = e.target.closest('.ac-info-tab-btn');
            const planBtn = e.target.closest('#plan-this-flight-btn');
            const profileToggleBtn = e.target.closest('.profile-toggle-btn');
            const icaoLink = e.target.closest('.ac-icao-link');

            if (icaoLink) {
                e.preventDefault();
                const icao = icaoLink.dataset.icao;
                if (icao) handleAirportClick(icao, null, true);
                return;
            }

            if (trackMeBtn) {
                e.preventDefault();
                await handleTrackmeBellClick(trackMeBtn);
                return;
            }

            if (shareBtn) {
                e.preventDefault();
                toggleTripCardMode(true);
                return;
            }

            if (replayBtn) {
                e.preventDefault();
                if (!currentFlightInWindow) {
                    showNotification?.('No flight selected to replay.', 'error');
                    return;
                }
                const feature = currentMapFeatures[currentFlightInWindow];
                const props = feature?.properties || {};
                const preloaded = (typeof liveTrailCache !== 'undefined'
                    && liveTrailCache.get(currentFlightInWindow)) || [];
                const historyUrl = `${LIVE_FLIGHTS_API_URL.replace('/flights', '/api/flights')}/${currentFlightInWindow}/history`;

                // ---- Stash + soft-hide overlapping UI for the replay session ----
                // The replay panel docks at the bottom-center of the screen and the
                // floating info / toolbar chrome competes with it visually, so we
                // snapshot which pieces were on screen, hide them, and put them
                // back exactly as we found them when the replay closes. We use a
                // soft hide (toggling the `.visible` class) rather than the full
                // closeAircraftWindow() flow so we don't blow away currentFlightInWindow,
                // active intervals, or the populated DOM — that way restoring is
                // just a class toggle away.
                const uiToToggle = [];
                const remember = (el) => {
                    if (el && el.classList && el.classList.contains('visible')) {
                        uiToToggle.push(el);
                        el.classList.remove('visible');
                    }
                };
                remember(aircraftInfoWindow);
                remember(document.getElementById('airport-info-window'));
                remember(document.getElementById('sector-ops-floating-panel'));
                remember(document.getElementById('weather-settings-window'));
                remember(document.getElementById('filter-settings-window'));

                // The recall buttons live next to the panel-toggle button on
                // the floating toolbar; hide the whole toolbar row so nothing
                // peeks out from behind the replay UI. We track its previous
                // inline display so we restore it (rather than forcing block).
                const toolbarToggleBtnEl = document.getElementById('toolbar-toggle-panel-btn');
                const toolbarRow = toolbarToggleBtnEl ? toolbarToggleBtnEl.parentElement : null;
                let prevToolbarDisplay = null;
                if (toolbarRow) {
                    prevToolbarDisplay = toolbarRow.style.display;
                    toolbarRow.style.display = 'none';
                }

                // The replay module manages the 2D live flown-path layer and
                // the live aircraft icon itself. The 3D extruded flown path,
                // however, is rendered through FlownPath3D — which lives in
                // this module's import scope, not the replay's — so we have
                // to pause it here and restart it in onClose. We snapshot
                // both the trail and flightId at this moment so the restore
                // step is unaffected by anything the user does meanwhile.
                const replayedFlightIdSnapshot = currentFlightInWindow;
                const had3DPath = (typeof FlownPath3D !== 'undefined')
                    && !!mapFilters?.show3DPath;
                if (had3DPath) {
                    try {
                        FlownPath3D.updatePath(sectorOpsMap, replayedFlightIdSnapshot, [], false);
                    } catch (err) {
                        console.warn('[Replay] Failed to clear 3D flown path:', err);
                    }
                }

                FlightReplay.open({
                    map: sectorOpsMap,
                    flightId: currentFlightInWindow,
                    points: preloaded,
                    meta: {
                        callsign: props.callsign,
                        depIcao: props.departureIcao,
                        arrIcao: props.arrivalIcao,
                        category: props.category || 'B737',
                        aircraftName: (typeof props.aircraft === 'string'
                            ? (() => { try { return JSON.parse(props.aircraft).aircraftName; } catch { return ''; } })()
                            : props.aircraft?.aircraftName) || ''
                    },
                    historyUrl,
                    // Fires once the replay has fully torn itself down — whether
                    // the user clicked the X, hit the panel close, or the open
                    // call bailed early (e.g. not enough position data). We use
                    // it to pop the flight info window back out and reveal any
                    // chrome we hid going in.
                    onClose: () => {
                                    // --- CRITICAL FIX: Restore Mobile State correctly ---
                                    if (window.MobileUIHandler && window.MobileUIHandler.isMobile()) {
                                        window.MobileUIHandler.openWindow(aircraftInfoWindow);
                                        uiToToggle.forEach(el => {
                                            // Skip aircraftInfoWindow as openWindow handles it
                                            if (el && el.classList && el.id !== 'aircraft-info-window') {
                                                el.classList.add('visible');
                                            }
                                        });
                                    } else {
                                        uiToToggle.forEach(el => {
                                            // Defensive: element may have been removed from the DOM
                                            // by some unrelated code path while replay was open.
                                            if (el && el.classList) el.classList.add('visible');
                                        });
                                    }

                                    if (toolbarRow) {
                                        toolbarRow.style.display = prevToolbarDisplay || '';
                                    }

                                    // Re-draw the 3D flown path if it was on when we
                                    // started. We use the snapshot flightId so this still
                                    // does the right thing even if the user has since
                                    // selected a different flight in some other code path.
                                    if (had3DPath && typeof FlownPath3D !== 'undefined') {
                                        try {
                                            const trail = (typeof liveTrailCache !== 'undefined' && liveTrailCache.get(replayedFlightIdSnapshot)) || [];
                                            FlownPath3D.updatePath(
                                                sectorOpsMap, 
                                                replayedFlightIdSnapshot, 
                                                trail, 
                                                !!mapFilters?.show3DPath
                                            );
                                        } catch (err) {
                                            console.warn('[Replay] Failed to restore 3D flown path:', err);
                                        }
                                    }
                                }
                });
                return;
            }

            if (profileToggleBtn) {
                e.preventDefault();
                if (profileToggleBtn.classList.contains('active')) return;
                const targetPanelId = profileToggleBtn.dataset.target;
                const profileCard = profileToggleBtn.closest('.ac-profile-card-new');
                if (!targetPanelId || !profileCard) return;

                profileCard.querySelector('.profile-toggle-btn.active')?.classList.remove('active');
                profileCard.querySelector('#vsd-panel.active')?.classList.remove('active');
                profileCard.querySelector('#ssd-panel.active')?.classList.remove('active');

                profileToggleBtn.classList.add('active');
                profileCard.querySelector(`#${targetPanelId}`)?.classList.add('active');
                return;
            }

            if (planBtn) {
                e.preventDefault();
                const departure = planBtn.dataset.departure;
                const arrival = planBtn.dataset.arrival;
                const aircraft = planBtn.dataset.aircraft;

                if (!departure || !arrival || !aircraft) {
                    showNotification("Could not get flight data to plan.", "error");
                    return;
                }

                const depInput = document.getElementById('fp-departure');
                const arrInput = document.getElementById('fp-arrival');
                const acSelect = document.getElementById('fp-aircraft');

                if (!depInput || !arrInput || !acSelect) {
                    showNotification("Flight plan form is not loaded.", "error");
                    return;
                }

                depInput.value = departure;
                arrInput.value = arrival;
                acSelect.value = aircraft;

                const flightPlanTabBtn = document.querySelector('.panel-tab-btn[data-tab="tab-flightplan"]');
                if (flightPlanTabBtn) flightPlanTabBtn.click();
                
                const hideButton = aircraftInfoWindow.querySelector('.aircraft-window-hide-btn');
                if (hideButton) hideButton.click();

                const panel = document.getElementById('sector-ops-floating-panel');
                if (panel && panel.classList.contains('panel-collapsed')) {
                    const toolbarToggleBtn = document.getElementById('toolbar-toggle-panel-btn');
                    if (toolbarToggleBtn) toolbarToggleBtn.click();
                }

                const flightPlanTabContent = document.getElementById('tab-flightplan');
                if (flightPlanTabContent) flightPlanTabContent.scrollTop = 0;

                showNotification("Flight plan form populated.", "success");
                return;
            }

            if (tabBtn) {
                e.preventDefault();
                const tabId = tabBtn.dataset.tab;
                if (!tabId || tabBtn.classList.contains('active')) return;

                const windowContent = tabBtn.closest('.info-window-content');
                if (!windowContent) return;

                tabBtn.closest('.ac-info-window-tabs').querySelector('.ac-info-tab-btn.active')?.classList.remove('active');
                windowContent.querySelector('.ac-tab-pane.active')?.classList.remove('active');

                tabBtn.classList.add('active');
                const newPane = windowContent.querySelector(`#${tabId}`);
                if (newPane) newPane.classList.add('active');

                if (tabId === 'ac-tab-pilot-report') {
                    const statsDisplay = newPane.querySelector('#pilot-stats-display');
                    if (statsDisplay && statsDisplay.innerHTML.trim() === '') {
                        const userId = tabBtn.dataset.userId;
                        const username = tabBtn.dataset.username;
                        if (userId) await displayPilotStats(userId, username);
                    }
                }
            }

            if (pinBtn) {
            e.preventDefault();
            if (currentFlightInWindow) {
                window.toggleFlightPin(currentFlightInWindow);
            }
            return;
        }

            if (closeBtn) {
                closeAircraftWindow();
            }
        });

        // Recall Button Logic
        aircraftInfoWindowRecallBtn.addEventListener('click', () => {
            if (currentFlightInWindow) {
                const layer = sectorOpsMap.getLayer('sector-ops-live-flights-layer');
                if (layer) {
                    const source = sectorOpsMap.getSource('sector-ops-live-flights-source');
                    const features = source._data.features;
                    const feature = features.find(f => f.properties.flightId === currentFlightInWindow);
                    if (feature) {
                        const props = feature.properties;
                        const flightProps = {
                            ...props,
                            position: JSON.parse(props.position),
                            aircraft: JSON.parse(props.aircraft)
                        };
                        
                        getValidSessionId().then(sessionId => {
                            handleAircraftClick(flightProps, sessionId);
                        });
                    }
                }
            }
        });

        aircraftInfoWindow.dataset.eventsAttached = 'true';
    }

function initializeAircraftLayer() {
        if (!sectorOpsMap) return;

        if (!sectorOpsMap.getSource('sector-ops-live-flights-source')) {
            sectorOpsMap.addSource('sector-ops-live-flights-source', {
                type: 'geojson',
                data: {
                    type: 'FeatureCollection',
                    features: []
                },
                generateId: true
            });
        }

        if (typeof MapAnimator !== 'undefined' && !mapAnimator) {
            mapAnimator = new MapAnimator(sectorOpsMap, 'sector-ops-live-flights-source', currentMapFeatures);
        }

        // 3D live-traffic dot field (toggled from the map toolbar / Settings).
        // Reads the same shared feature cache the flat symbol layer does.
        LiveTraffic3D.init(sectorOpsMap, () => Object.values(currentMapFeatures), () => currentFlightInWindow);
        if (mapFilters.live3DTraffic) LiveTraffic3D.setVisible(true);

        const initialIconSize = parseFloat(mapFilters.planeIconSize) || 0.15;

        if (!sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
            sectorOpsMap.addLayer({
                'id': 'sector-ops-live-flights-layer',
                'type': 'symbol',
                'source': 'sector-ops-live-flights-source',
                'layout': {
                    'icon-image': getTintedIconImageExpression(),
                    'icon-size': initialIconSize,
                    'icon-allow-overlap': true,
                    'icon-ignore-placement': true,
                    'icon-rotation-alignment': 'map',
                    'icon-rotate': ['get', 'heading']
                },
                'paint': {
                    // Use the premium expression from the start so the
                    // logged-in user (gold) and watchlist pilots (purple)
                    // are colored correctly on first render, not just after
                    // a traffic-highlight toggle.
                    'icon-color': getPremiumColorExpression()
                }
            });

            // Natural (non-SDF) twin layer for the un-highlighted bulk of
            // traffic. Inserted just below the SDF layer so highlighted planes
            // draw on top. Shares the same source + visibility filter; the
            // SDF/natural split is decided per-feature in the icon-image
            // expressions, so the two layers never both draw the same plane.
            if (!sectorOpsMap.getLayer('sector-ops-live-flights-natural-layer')) {
                sectorOpsMap.addLayer({
                    'id': 'sector-ops-live-flights-natural-layer',
                    'type': 'symbol',
                    'source': 'sector-ops-live-flights-source',
                    'layout': {
                        'icon-image': getNaturalIconImageExpression(),
                        'icon-size': initialIconSize,
                        'icon-allow-overlap': true,
                        'icon-ignore-placement': true,
                        'icon-rotation-alignment': 'map',
                        'icon-rotate': ['get', 'heading']
                    }
                }, 'sector-ops-live-flights-layer');
            }

            sectorOpsMap.addLayer({
                'id': 'sector-ops-live-flights-hover-layer',
                'type': 'symbol',
                'source': 'sector-ops-live-flights-source',
                'filter': ['==', 'flightId', ''],
                'layout': {
                    'icon-image': getHoverIconImageExpression(),
                    'icon-size': initialIconSize,
                    'icon-allow-overlap': true,
                    'icon-ignore-placement': true,
                    'icon-rotation-alignment': 'map',
                    'icon-rotate': ['get', 'heading']
                },
                'paint': {
                    'icon-color': getPremiumColorExpression()
                }
            });

            // Bootstrap pilot-relation colors. Covers the case where flight
            // features were already cached (or where ProfileUI populated
            // before the layer existed) — the auth handler in profileUI.js
            // covers the opposite race direction.
            refreshPilotRelations();

            sectorOpsMap.on('click', (e) => {
                console.log("📍 Raw map tap at:", e.point);
                const features = sectorOpsMap.queryRenderedFeatures(e.point);
                const layerNames = features.map(f => f.layer.id);
                console.log("🔍 Layers under this tap:", layerNames);
            });

            if (activeAtcFacilities && activeAtcFacilities.length > 0) {
                const centerControllers = activeAtcFacilities.filter(f => f.type === 6);
                if (typeof updateActiveSectors === 'function') {
                    updateActiveSectors(sectorOpsMap, 'fir-fills', centerControllers);
                }
            }

            // Aircraft now render across two layers (SDF + natural), so bind
            // the click/hover handlers to both so every plane stays interactive.
            const onLiveFlightClick = async (e) => {
                console.log("✈️ Plane click listener fired!", e.features[0].properties.callsign);
                const props = e.features[0].properties;
                const flightProps = {
                    ...props,
                    position: JSON.parse(props.position),
                    aircraft: JSON.parse(props.aircraft)
                };

                const sessionId = await getValidSessionId();
                handleAircraftClick(flightProps, sessionId, e);
            };
            sectorOpsMap.on('click', 'sector-ops-live-flights-layer', onLiveFlightClick);
            sectorOpsMap.on('click', 'sector-ops-live-flights-natural-layer', onLiveFlightClick);

            const hoverPopup = new mapboxgl.Popup({
                closeButton: false,
                closeOnClick: false,
                offset: 20
            });

            const onLiveFlightEnter = (e) => {
                if (window.isMouseOverAirportTag) return;
                sectorOpsMap.getCanvas().style.cursor = 'pointer';
                const feature = e.features[0];
                if (typeof generateHoverCardHTML !== 'undefined') {
                    hoverPopup.setLngLat(feature.geometry.coordinates).setHTML(generateHoverCardHTML(feature.properties)).addTo(sectorOpsMap);
                }
            };
            sectorOpsMap.on('mouseenter', 'sector-ops-live-flights-layer', onLiveFlightEnter);
            sectorOpsMap.on('mouseenter', 'sector-ops-live-flights-natural-layer', onLiveFlightEnter);

            const onLiveFlightLeave = () => {
                sectorOpsMap.getCanvas().style.cursor = '';
                hoverPopup.remove();
            };
            sectorOpsMap.on('mouseleave', 'sector-ops-live-flights-layer', onLiveFlightLeave);
            sectorOpsMap.on('mouseleave', 'sector-ops-live-flights-natural-layer', onLiveFlightLeave);
        }

        if (!sectorOpsMap.getLayer(AIRCRAFT_LABEL_LAYER_ID)) {
            const labelScale = Math.min(1.6, Math.max(0.7, parseFloat(mapFilters.labelScale) || 1));
            const labelTheme = AIRCRAFT_LABEL_THEMES[mapFilters.labelTheme] || AIRCRAFT_LABEL_THEMES.default;
            sectorOpsMap.addLayer({
                id: AIRCRAFT_LABEL_LAYER_ID,
                type: 'symbol',
                source: 'sector-ops-live-flights-source',
                minzoom: 6.5,
                layout: {
                    'visibility': mapFilters.showAircraftLabels ? 'visible' : 'none',
                    'text-field': getAircraftLabelTextField(),
                    'text-font': ['Inter Regular', 'Arial Unicode MS Regular'],
                    'text-size': getAircraftLabelTextSize(labelScale),
                    'text-offset': getAircraftLabelTextOffset(),
                    'text-anchor': 'top',
                    'text-allow-overlap': false,
                    'text-ignore-placement': false,
                    // Airline logo pill under the plane (text rows beneath it);
                    // loaded on demand by registerAirlineLogoLoader. The icon
                    // never participates in collision — the text's placement
                    // decides if the symbol shows.
                    'icon-image': getAircraftLabelIconImage(),
                    'icon-size': getAircraftLabelIconSize(labelScale),
                    'icon-anchor': 'top',
                    'icon-offset': [0, 16],
                    'icon-allow-overlap': true,
                    'icon-ignore-placement': true
                },
                paint: {
                    'text-color': labelTheme.text,
                    'text-halo-color': labelTheme.halo,
                    'text-halo-width': labelTheme.haloWidth,
                    'text-halo-blur': 1
                }
            });
            registerAirlineLogoLoader(sectorOpsMap);
        }
    }


/**
 * --- [NEW] Prime the collapsed peek height from the saved layout preset. ---
 * Runs before the sheet first snaps to peek so the bar opens at the right
 * height instead of starting at the default and jumping once the iframe loads
 * and re-confirms via SIMPLE_WINDOW_PEEK_HEIGHT. The height table mirrors
 * PEEK_HEIGHTS in flightinfo.html (the source of truth).
 */
function primeSimpleWindowPeekHeight() {
    const HEIGHTS = { minimal: 150, standard: 250, rich: 392 };
    let peek = 'standard';
    try {
        const saved = JSON.parse(localStorage.getItem('inflightSimpleLayout') || '{}');
        if (saved && HEIGHTS[saved.peek]) peek = saved.peek;
    } catch (e) { /* default standard */ }
    const h = HEIGHTS[peek];
    window.__simpleWindowPeekHeight = h;
    if (window.MobileUIHandler && window.MobileUIHandler.CONFIG) {
        window.MobileUIHandler.CONFIG.simplePeekHeight = h;
    }
    return h;
}

/**
 * --- [NEW] Resize / reposition the simple-window host for its collapsed vs expanded phase. ---
 * Desktop: the floating #aircraft-info-window grows from a compact bar to the full panel.
 * Mobile: drive the existing legacy-sheet peek/expanded snap points.
 */
function applySimpleWindowPhase(phase) {
    const windowEl = document.getElementById('aircraft-info-window');
    if (!windowEl) return;
    const expanded = (phase === 'expanded');
    windowEl.classList.toggle('simple-collapsed', !expanded);
    windowEl.classList.toggle('simple-expanded', expanded);

    const onMobile = !!(window.MobileUIHandler && typeof window.MobileUIHandler.isMobile === 'function'
        && window.MobileUIHandler.isMobile());

    if (onMobile && window.MobileUIHandler && typeof window.MobileUIHandler.setLegacySheetState === 'function') {
        // The mobile sheet owns sizing; just snap it to the matching detent.
        // iPads have no peek bar (phones only) — they stay on the expanded "second state".
        const tabletExpandedOnly = typeof window.MobileUIHandler.isSimpleSheetExpandedOnly === 'function'
            && window.MobileUIHandler.isSimpleSheetExpandedOnly();
        window.MobileUIHandler.setLegacySheetState((expanded || tabletExpandedOnly) ? 'expanded' : 'peek');
        return;
    }

    // Desktop: size the floating panel. The iframe uses flex-grow with no intrinsic
    // height, so we must give the host an explicit height for it to fill.
    if (expanded) {
        windowEl.style.width = '440px';
        windowEl.style.height = 'min(760px, calc(100vh - 40px))';
        windowEl.style.maxHeight = 'calc(100vh - 40px)';
    } else {
        // Collapsed bar height tracks the chosen peek preset (reported by the
        // iframe via SIMPLE_WINDOW_PEEK_HEIGHT); falls back to the classic 236.
        const peekH = window.__simpleWindowPeekHeight || 236;
        windowEl.style.width = '380px';
        windowEl.style.height = peekH + 'px';   // compact bar only
        windowEl.style.maxHeight = peekH + 'px';
    }
}

/**
 * --- [NEW] Route simple-window action-bar buttons to the existing flight actions. ---
 * Reuses the battle-tested replay / trip-card / track-me flows rather than duplicating them.
 */
function handleSimpleWindowAction(action) {
    switch (action) {
        case 'tripcard':
            if (typeof toggleTripCardMode === 'function') toggleTripCardMode(true);
            break;
        case 'follow':
            if (typeof window.handleTrackmeBellClick === 'function' && currentFlightInWindow) {
                window.handleTrackmeBellClick({
                    dataset: { flightId: currentFlightInWindow },
                    querySelector: () => null
                });
            }
            break;
        case 'replay':
            triggerSimpleWindowReplay();
            break;
        default:
            break;
    }
}

/**
 * --- [NEW] Fire the existing replay flow from the simple window. ---
 * The replay logic lives in the delegated click handler bound to #aircraft-info-window
 * and depends on that handler's closure. Rather than duplicate it, we drop a hidden
 * `.aircraft-window-replay-btn` into the window and click it so the real handler runs.
 */
function triggerSimpleWindowReplay() {
    const windowEl = document.getElementById('aircraft-info-window');
    if (!windowEl) return;
    if (!currentFlightInWindow) {
        if (typeof showNotification === 'function') showNotification('No flight selected to replay.', 'error');
        return;
    }
    let btn = windowEl.querySelector('.aircraft-window-replay-btn.simple-proxy');
    if (!btn) {
        btn = document.createElement('button');
        btn.className = 'aircraft-window-replay-btn simple-proxy';
        btn.style.display = 'none';
        windowEl.appendChild(btn);
    }
    btn.click();
}

function formatDataForSimpleWindow(flightProps, plan, routePoints, communityData, filedPlanData = null) {
    if (!flightProps) return null;

    // 1. Parsing
    const pos = flightProps.position || {};
    const aircraft = (typeof flightProps.aircraft === 'string') ? JSON.parse(flightProps.aircraft) : (flightProps.aircraft || {});

    // --- REGISTRATION LOGIC ---
    let finalRegistration = '---';
    if (communityData && communityData.tailNumber) {
        finalRegistration = communityData.tailNumber;
    } else if (aircraft.registration) {
        finalRegistration = aircraft.registration;
    }

    // 2. Route Calculations
    let originIcao = '---', destIcao = '---';
    let progress = 0, elapsed = '--:--', eta = '--:--', ete = '--:--', originTime = '--:--';
    let originCountry = '', destCountry = '';
    let originCity = '', destCity = '';
    let distRemainingNm = null, distFlownNm = null;

    // --- TIME & ELAPSED CALCULATIONS ---
    if (routePoints && routePoints.length > 0) {
        const firstPoint = routePoints[0];
        if (firstPoint && firstPoint.date) {
            const startTime = new Date(firstPoint.date).getTime();
            const now = Date.now();
            
            originTime = new Date(startTime).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' });
            
            const diffMs = now - startTime;
            if (diffMs > 0) {
                const h = Math.floor(diffMs / 3600000);
                const m = Math.floor((diffMs % 3600000) / 60000);
                elapsed = `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
            }
        }
    }

    const structuredWaypoints = [];
    if (plan && plan.flightPlanItems && plan.flightPlanItems.length > 1) {
        originIcao = plan.origin?.icao || plan.flightPlanItems[0].identifier || '---';
        destIcao = plan.destination?.icao || plan.flightPlanItems[plan.flightPlanItems.length - 1].identifier || '---';

        if (airportsData[originIcao]) { originCountry = airportsData[originIcao].country; originCity = airportsData[originIcao].name || ''; }
        if (airportsData[destIcao]) { destCountry = airportsData[destIcao].country; destCity = airportsData[destIcao].name || ''; }

        // --- A. FLATTEN AND IDENTIFY GROUPS ---
        const flatList = [];
        plan.flightPlanItems.forEach((item, index) => {
            let groupName = "ENROUTE";
            const children = item.children || [];
            const hasChildren = children.length > 0;
            const ident = (item.identifier || item.name || '').toUpperCase();

            if (hasChildren) {
                if (index <= 1) {
                    groupName = `SID: ${ident}`;
                } else if (/^[A-Z]\d{2}[LRC]?$/.test(ident)) {
                    groupName = `APPR: ${ident}`;
                } else {
                    groupName = `STAR: ${ident}`;
                }
                
                children.forEach(child => {
                    if (child.location) {
                        flatList.push({ ...child, group: groupName });
                    }
                });
            } else if (item.location) {
                flatList.push({ ...item, group: "ENROUTE" });
            }
        });

        // --- B. EFFICIENT ACTIVE WAYPOINT & DISTANCE CALC ---
        let activeIndex = 0;
        let minScore = Infinity;
        let totalDistKm = 0;
        const currentTrack = pos.heading_deg || 0;
        
        if (flatList.length > 0) {
            for (let i = 0; i < flatList.length - 1; i++) {
                totalDistKm += getDistanceKm(flatList[i].location.latitude, flatList[i].location.longitude, flatList[i+1].location.latitude, flatList[i+1].location.longitude);
                
                const wp = flatList[i];
                if (!wp.location) continue;
                const d = getDistanceKm(pos.lat, pos.lon, wp.location.latitude, wp.location.longitude);
                const bearingTo = getBearing(pos.lat, pos.lon, wp.location.latitude, wp.location.longitude);
                const bearingDiff = Math.abs(normalizeBearingDiff(currentTrack - bearingTo));
                
                if (bearingDiff < 100 || d < 5) {
                    if (d < minScore) {
                        minScore = d;
                        activeIndex = i;
                    }
                }
            }
        }

        // --- C. EFFICIENT PROGRESS / ETE ---
        if (totalDistKm > 0 && flatList.length > 0) {
            const destLat = flatList[flatList.length - 1].location.latitude;
            const destLon = flatList[flatList.length - 1].location.longitude;
            const distRemainingKm = getDistanceKm(pos.lat, pos.lon, destLat, destLon);

            progress = Math.max(0, Math.min(100, (1 - (distRemainingKm / totalDistKm)) * 100));
            distRemainingNm = Math.round(distRemainingKm / 1.852);
            distFlownNm = Math.max(0, Math.round((totalDistKm - distRemainingKm) / 1.852));

            const speedKts = pos.gs_kt || 0;
            if (speedKts > 50) {
                const hours = (distRemainingKm / 1.852) / speedKts;
                const h = Math.floor(hours);
                const m = Math.round((hours - h) * 60);
                ete = `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
                
                const arrivalDate = new Date(Date.now() + (hours * 3600000));
                eta = arrivalDate.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' });
            }
        }

        // --- D. FORMAT OUTPUT LIST ---
        flatList.forEach((wp, idx) => {
            const distKm = getDistanceKm(pos.lat, pos.lon, wp.location.latitude, wp.location.longitude);
            const distNM = distKm / 1.852;
            
            structuredWaypoints.push({
                ident: wp.identifier || wp.name,
                name: wp.name,
                type: wp.type,
                group: wp.group,
                active: (idx === activeIndex),
                passed: (idx < activeIndex),
                time: idx === activeIndex ? `${distNM.toFixed(1)} NM` : (idx < activeIndex ? 'PASS' : '')
            });
        });
    }

    // --- Source-tagged times (SCHEDULED / ACTUAL / ESTIMATED), reusing the legacy helpers ---
    let depInfo = null, arrInfo = null;
    try {
        if (typeof computeDepartureTimeInfo === 'function') {
            const di = computeDepartureTimeInfo(flightProps, routePoints, filedPlanData, originIcao);
            if (di) depInfo = { time: di.time, label: di.label, color: di.color };
        }
        if (typeof computeArrivalTimeInfo === 'function') {
            const ai = computeArrivalTimeInfo(flightProps, filedPlanData, distRemainingNm != null ? distRemainingNm : 0);
            if (ai) arrInfo = { time: ai.time, label: ai.label, color: ai.color };
        }
    } catch (e) { /* non-fatal: fall back to plain times */ }

    // --- Explicit four-cell time grid (FR24-style): Scheduled/Actual + Scheduled/Estimated ---
    const fmtUtc = (d) => (d && !isNaN(d.getTime()))
        ? d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' })
        : null;
    const times = { depScheduled: null, depActual: null, arrScheduled: null, arrEstimated: null };
    if (filedPlanData && filedPlanData.dep_time) {
        const d = new Date(filedPlanData.dep_time);
        times.depScheduled = fmtUtc(d);
        if (filedPlanData.duration_minutes) {
            times.arrScheduled = fmtUtc(new Date(d.getTime() + filedPlanData.duration_minutes * 60000));
        }
    }
    if (routePoints && routePoints.length > 0 && routePoints[0].date) {
        times.depActual = fmtUtc(new Date(routePoints[0].date));
    }
    if (eta && eta !== '--:--') times.arrEstimated = eta;

    // --- Detailed flying state (shared source of truth with the full window) ---
    // Reuse the exact phase classifier the avionics window uses so the simple
    // window reports PUSHBACK / TAXIING / LIFTOFF / FLARE / LANDING ROLLOUT etc.
    // instead of its old 4-state Ground/Climb/Cruise/Descent guess.
    const hasPlanForPhase = !!(plan && Array.isArray(plan.flightPlanItems) && plan.flightPlanItems.length > 1);
    const distToDestForPhase = (distRemainingNm != null) ? distRemainingNm : 0;
    const totalDistForPhase = (distFlownNm != null ? distFlownNm : 0) + (distRemainingNm != null ? distRemainingNm : 0);
    let detailedPhase = { flightPhase: flightProps.phase || 'ENROUTE', phaseClass: 'phase-enroute', phaseIcon: 'fa-route' };
    try {
        if (typeof computeDetailedFlightPhase === 'function') {
            detailedPhase = computeDetailedFlightPhase(
                { position: pos },
                plan,
                routePoints,
                progress,
                distToDestForPhase,
                totalDistForPhase,
                hasPlanForPhase
            );
        }
    } catch (e) { /* non-fatal: fall back to coarse phase */ }

    // --- Environment + navigation readouts (parity with the full window) ---
    // currentAircraftPositionForGeocode is kept in sync with the selected
    // flight (the only flight this window renders), so it carries the live
    // OAT / wind sampled for this aircraft.
    const geo = (typeof currentAircraftPositionForGeocode !== 'undefined') ? currentAircraftPositionForGeocode : null;
    const oatC = (geo && geo.oat_c != null) ? geo.oat_c : null;
    const windDir = (geo && geo.wind_dir != null) ? geo.wind_dir : (flightProps.wind_dir != null ? flightProps.wind_dir : null);
    const windSpd = (geo && geo.wind_spd_kts != null) ? geo.wind_spd_kts : (flightProps.wind_spd_kts != null ? flightProps.wind_spd_kts : null);
    const tas = (typeof calculateTas === 'function' && pos.alt_ft != null)
        ? calculateTas(pos.alt_ft, oatC != null ? oatC : 15, pos.gs_kt || 0) : null;
    const activeWp = structuredWaypoints.find(w => w.active);

    return {
        theme: {
            start: mapFilters.themeStartColor || '#18181b',
            end: mapFilters.themeEndColor || '#18181b',
            opacity: mapFilters.themeOpacity || 90
        },
        username: flightProps.username,
        callsign: flightProps.callsign,
        // Compact altitude/speed series for the simple window's Speed & Altitude
        // graph (downsampled here so the postMessage payload stays small).
        chart: (typeof FlightGraph !== 'undefined' && FlightGraph) ? FlightGraph.extractSeries(routePoints) : null,
        phase: detailedPhase.flightPhase || 'ENROUTE',
        phaseClass: detailedPhase.phaseClass || 'phase-enroute',
        phaseIcon: detailedPhase.phaseIcon || 'fa-route',
        pilotState: flightProps.pilotState !== undefined ? flightProps.pilotState : 0,
        telemetry: {
            altitude: pos.alt_ft,
            groundSpeed: pos.gs_kt,
            verticalSpeed: pos.vs_fpm,
            heading: pos.heading_deg,
            squawk: '2000',
            windDir: windDir != null ? windDir : 0,
            windSpd: windSpd != null ? windSpd : 0,
            oat: oatC,
            tas: tas,
            lat: pos.lat,
            lon: pos.lon,
            nextWpName: activeWp ? (activeWp.ident || '---') : '---',
            nextWpDist: activeWp ? (activeWp.time || '') : ''
        },
        aircraft: {
            aircraftName: aircraft.aircraftName,
            liveryName: aircraft.liveryName,
            registration: finalRegistration
        },
        images: (() => {
            // Build the ordered photo list (up to 3) for the simple window's
            // hero carousel. communityData carries the raw lookup keys
            // (imageUrls / imageContributors); the flightProps fallback carries
            // the normalised ones cached on the live feature. Keep url/credit
            // (photo 1) at the top level for back-compat.
            const asArray = (v) => {
                if (Array.isArray(v)) return v;
                if (typeof v === 'string' && v.trim().startsWith('[')) { try { return JSON.parse(v); } catch { return []; } }
                return [];
            };
            const urls = communityData ? asArray(communityData.imageUrls) : asArray(flightProps.communityImageUrls);
            const contributors = communityData ? asArray(communityData.imageContributors) : asArray(flightProps.imageContributors);
            const fallbackUrl = communityData ? communityData.imageUrl : flightProps.communityImageUrl;
            const fallbackCredit = communityData ? communityData.contributorName : flightProps.contributorName;
            let list = urls.filter(Boolean).map((url, i) => ({
                url,
                credit: (contributors[i] && contributors[i].name) || fallbackCredit || ''
            }));
            if (!list.length && fallbackUrl) list = [{ url: fallbackUrl, credit: fallbackCredit || '' }];
            return {
                url: list[0] ? list[0].url : '',
                credit: list[0] ? list[0].credit : '',
                list
            };
        })(),
        route: {
            originIcao,
            originCountry,
            originCity,
            destIcao,
            destCountry,
            destCity,
            originTime: originTime,
            destTime: eta,
            progress: progress,
            elapsed: elapsed,
            eta: eta,
            ete: ete,
            depInfo: depInfo,
            arrInfo: arrInfo,
            times: times,
            distRemainingNm: distRemainingNm,
            distFlownNm: distFlownNm,
            waypoints: structuredWaypoints
        }
    };
}

/**
     * --- [NEW FUNCTION] ---
     * Immediately calculates and sends flight data to the ND iframe.
     * This is called when the iframe signals it is 'ready' via postMessage.
     */
    function refreshNavDisplayFromCache() {
        if (!currentFlightInWindow) return;

        // 1. Get the current flight's feature from the cache
        const myFeature = currentMapFeatures[currentFlightInWindow];
        if (!myFeature || !myFeature.properties) return;

        const flightId = currentFlightInWindow;
        const flightProps = { ...myFeature.properties };
        
        // Parse position string back to object
        let position;
        try {
            position = JSON.parse(flightProps.position);
        } catch (e) { return; }

        // 2. Calculate TAS using the helper and cached OAT
        const cachedOat = currentAircraftPositionForGeocode ? (currentAircraftPositionForGeocode.oat_c || 15) : 15;
        const calculatedTas = calculateTas(position.alt_ft || 0, cachedOat, position.gs_kt || 0);
        const cachedWindDir = (currentAircraftPositionForGeocode && currentAircraftPositionForGeocode.wind_dir) || 0;
        const cachedWindSpd = (currentAircraftPositionForGeocode && currentAircraftPositionForGeocode.wind_spd_kts) || 0;

        // 3. Calculate Traffic
        const ndTraffic = [];
        const myLat = position.lat;
        const myLon = position.lon;
        const myAlt = position.alt_ft;

        Object.values(currentMapFeatures).forEach(feature => {
            const otherProps = feature.properties;
            if (otherProps.flightId === flightId) return;

            let otherPos;
            try {
                otherPos = JSON.parse(otherProps.position);
            } catch(e) { return; }

            const latDiff = Math.abs(otherPos.lat - myLat);
            const lonDiff = Math.abs(otherPos.lon - myLon);
            if (latDiff > 1 || lonDiff > 1) return; 

            const distKm = getDistanceKm(myLat, myLon, otherPos.lat, otherPos.lon);
            const distNM = distKm / 1.852;

            if (distNM < 45) {
                const bearingTo = getBearing(myLat, myLon, otherPos.lat, otherPos.lon);
                let relBearing = bearingTo - position.heading_deg;
                if (relBearing > 180) relBearing -= 360;
                if (relBearing < -180) relBearing += 360;
                const altDiffFt = otherPos.alt_ft - myAlt;
                const altDiff100 = Math.round(altDiffFt / 100);

                ndTraffic.push({
                    id: otherProps.flightId,
                    bearing: relBearing,
                    dist: distNM,
                    altDiff: altDiff100,
                    vs: otherPos.vs_fpm
                });
            }
        });

        // 4. Calculate Flight Plan (Logic copied from handleSocketFlightUpdate)
        let ndFlightPlan = [];
        let ndNextWp = "WYPT";
        let ndDist = 0;
        let ndEte = "00:00";

        if (cachedFlightDataForStatsView && cachedFlightDataForStatsView.plan) {
            const planItems = cachedFlightDataForStatsView.plan.flightPlanItems;
            const flatWaypoints = getFlatWaypointObjects(planItems);
            
            ndFlightPlan = flatWaypoints.map(wp => {
                if (!wp.location || wp.location.latitude == null || wp.location.longitude == null) return null;
                const distKm = getDistanceKm(myLat, myLon, wp.location.latitude, wp.location.longitude);
                const distNM = distKm / 1.852;
                const bearingTo = getBearing(myLat, myLon, wp.location.latitude, wp.location.longitude);
                const rad = bearingTo * Math.PI / 180;
                return {
                    name: wp.identifier || wp.name || 'WP',
                    x: Math.sin(rad) * distNM, 
                    y: Math.cos(rad) * distNM 
                };
            }).filter(Boolean);

            const currentTrack = position.heading_deg;
            let bestIndex = -1;
            let minDist = Infinity;

            if (flatWaypoints.length > 1) {
                for (let i = 1; i < flatWaypoints.length; i++) {
                    const wp = flatWaypoints[i];
                    if (!wp.location) continue;
                    
                    const dKm = getDistanceKm(myLat, myLon, wp.location.latitude, wp.location.longitude);
                    const b = getBearing(myLat, myLon, wp.location.latitude, wp.location.longitude);
                    const bDiff = Math.abs(normalizeBearingDiff(currentTrack - b));
                    
                    if (bDiff <= 100 && dKm < minDist) {
                        minDist = dKm;
                        bestIndex = i;
                    }
                }
            }

            if (bestIndex !== -1) {
                const wp = flatWaypoints[bestIndex];
                const distNM = minDist / 1.852;
                const gs = Math.max(1, position.gs_kt || 0);
                
                ndNextWp = wp.identifier || wp.name || "WPT";
                ndDist = Math.round(distNM);
                
                const totalMinutes = (distNM / gs) * 60;
                const h = Math.floor(totalMinutes / 60);
                const m = Math.floor(totalMinutes % 60);
                ndEte = `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
            }
        }

        // 5. Send to Iframe
        const navIframe = document.getElementById('nav-display-frame');
        if (navIframe && navIframe.contentWindow) {
            navIframe.contentWindow.postMessage({
                heading: position.heading_deg,
                track: position.heading_deg,
                gs: Math.round(position.gs_kt),
                tas: calculatedTas, 
                windDir: cachedWindDir, 
                windSpd: cachedWindSpd,
                traffic: ndTraffic,
                flightPlan: ndFlightPlan,
                nextWp: ndNextWp,
                nextWpDist: ndDist,
                nextWpEte: ndEte
            }, '*');
            console.log(`ND Iframe Handshake successful. Data pushed for ${flightId}`);
        }
    }

const SettingsUI = {
    _isVisible: false,
    _currentCategory: 'map',

    // Mirrors the mobile settings sheet's tab structure (MobileSettingsUI):
    // Map / Aircraft / Labels / Overlays, plus the shared tactical filter
    // board under Filters and the desktop-only window Theme tab.
    categories: {
        map: { label: "Map", icon: "fa-map" },
        aircraft: { label: "Aircraft", icon: "fa-plane-up" },
        labels: { label: "Labels", icon: "fa-tag" },
        overlays: { label: "Overlays", icon: "fa-layer-group" },
        airspace: { label: "Filters", icon: "fa-sliders" },
        theme: { label: "Theme", icon: "fa-palette" }
    },

    _injectStyles() {
        // Idempotent: only inject once
        if (document.getElementById('settings-ui-modal-styles')) return;

        const style = document.createElement('style');
        style.id = 'settings-ui-modal-styles';
        style.textContent = `
            /* === Global Settings Modal — backdrop & visibility === */
            #global-settings-modal-overlay.modal-overlay {
                position: fixed;
                inset: 0;
                background: rgba(8, 10, 16, 0.65);
                backdrop-filter: blur(10px);
                -webkit-backdrop-filter: blur(10px);
                display: none;
                align-items: center;
                justify-content: center;
                z-index: 99999;
                font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                padding: 24px;
                box-sizing: border-box;
                opacity: 0;
                transition: opacity 0.25s ease;
            }
            #global-settings-modal-overlay.modal-overlay.open {
                display: flex;
                opacity: 1;
            }

            /* === The card === */
            #global-settings-modal-overlay .filter-modal.settings-modal {
                width: min(960px, 100%);
                max-height: min(720px, 90vh);
                background: #18181b;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 16px;
                box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6), 0 0 0 1px rgba(255, 255, 255, 0.02);
                display: flex;
                flex-direction: column;
                overflow: hidden;
                transform: scale(0.96) translateY(8px);
                transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1);
            }
            #global-settings-modal-overlay.modal-overlay.open .filter-modal.settings-modal {
                transform: scale(1) translateY(0);
            }

            /* === Header === */
            #global-settings-modal-overlay .modal-header {
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding: 18px 22px;
                border-bottom: 1px solid rgba(255, 255, 255, 0.06);
                background: linear-gradient(180deg, rgba(56, 189, 248, 0.04), transparent);
                flex-shrink: 0;
            }
            #global-settings-modal-overlay .header-main {
                display: flex;
                align-items: center;
                gap: 14px;
            }
            #global-settings-modal-overlay .header-icon-box {
                width: 40px;
                height: 40px;
                border-radius: 10px;
                background: rgba(56, 189, 248, 0.12);
                color: #38bdf8;
                display: grid;
                place-items: center;
                font-size: 1rem;
                border: 1px solid rgba(56, 189, 248, 0.25);
            }
            #global-settings-modal-overlay .header-text h2 {
                margin: 0;
                color: #fafafa;
                font-size: 1.05rem;
                font-weight: 700;
                letter-spacing: -0.2px;
            }
            #global-settings-modal-overlay .header-text span {
                display: block;
                margin-top: 2px;
                color: #71717a;
                font-size: 0.75rem;
                font-weight: 500;
            }
            #global-settings-modal-overlay .close-modal {
                background: transparent;
                border: none;
                color: #71717a;
                font-size: 1.5rem;
                cursor: pointer;
                width: 32px;
                height: 32px;
                border-radius: 8px;
                display: grid;
                place-items: center;
                transition: all 0.15s ease;
                line-height: 1;
            }
            #global-settings-modal-overlay .close-modal:hover {
                background: rgba(239, 68, 68, 0.1);
                color: #ef4444;
            }

            /* === Body: two-pane layout === */
            #global-settings-modal-overlay .modal-body {
                display: grid;
                grid-template-columns: 220px 1fr;
                flex: 1;
                min-height: 0;
            }

            /* Left pane — category list */
            #global-settings-modal-overlay .filter-selection-pane {
                background: #131316;
                border-right: 1px solid rgba(255, 255, 255, 0.05);
                padding: 16px 12px;
                overflow-y: auto;
            }
            #global-settings-modal-overlay .filter-group-wrapper { display: flex; flex-direction: column; gap: 6px; }
            #global-settings-modal-overlay .filter-group-header {
                font-size: 0.65rem;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: #52525b;
                padding: 6px 10px 10px;
            }
            #global-settings-modal-overlay .filter-options-list {
                display: flex;
                flex-direction: column;
                gap: 2px;
            }
            #global-settings-modal-overlay .nexus-item {
                display: flex;
                align-items: center;
                gap: 10px;
                padding: 9px 10px;
                background: transparent;
                border: 1px solid transparent;
                border-radius: 8px;
                color: #a1a1aa;
                font-size: 0.82rem;
                font-weight: 500;
                cursor: pointer;
                text-align: left;
                transition: all 0.15s ease;
                font-family: inherit;
            }
            #global-settings-modal-overlay .nexus-item:hover {
                background: rgba(255, 255, 255, 0.03);
                color: #e4e4e7;
            }
            #global-settings-modal-overlay .nexus-item.active {
                background: rgba(56, 189, 248, 0.08);
                border-color: rgba(56, 189, 248, 0.2);
                color: #38bdf8;
            }
            #global-settings-modal-overlay .nexus-icon {
                width: 22px;
                height: 22px;
                display: grid;
                place-items: center;
                font-size: 0.85rem;
                flex-shrink: 0;
            }
            #global-settings-modal-overlay .nexus-label { flex: 1; }

            /* Right pane — config content (overrides existing orphan rule) */
            #global-settings-modal-overlay .filter-config-pane {
                background: #121214;
                padding: 20px 24px;
                overflow-y: auto;
            }
            #global-settings-modal-overlay .settings-content-wrapper { display: flex; flex-direction: column; gap: 22px; }
            #global-settings-modal-overlay .settings-section { display: flex; flex-direction: column; gap: 8px; }
            #global-settings-modal-overlay .config-header {
                font-size: 0.7rem;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: #71717a;
                margin-bottom: 4px;
            }
            #global-settings-modal-overlay .row-input,
            #global-settings-modal-overlay .row-input-select {
                background: #18181b;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #e4e4e7;
                padding: 6px 10px;
                border-radius: 6px;
                font-size: 0.8rem;
                font-family: inherit;
            }
            #global-settings-modal-overlay .row-input-select { min-width: 160px; cursor: pointer; }
            #global-settings-modal-overlay .input-wrapper.select-wrapper { display: inline-flex; }
            #global-settings-modal-overlay input[type="range"] { accent-color: #38bdf8; }
            #global-settings-modal-overlay .modal-btn {
                padding: 9px 14px;
                border-radius: 8px;
                border: 1px solid rgba(255, 255, 255, 0.08);
                font-size: 0.8rem;
                font-weight: 600;
                cursor: pointer;
                font-family: inherit;
                transition: all 0.15s ease;
            }
            #global-settings-modal-overlay .modal-btn.secondary { background: rgba(255,255,255,0.04); color: #e4e4e7; }
            #global-settings-modal-overlay .modal-btn.secondary:hover { background: rgba(255,255,255,0.08); }

            /* Custom scrollbars inside the modal */
            #global-settings-modal-overlay .custom-scroll::-webkit-scrollbar { width: 8px; }
            #global-settings-modal-overlay .custom-scroll::-webkit-scrollbar-track { background: transparent; }
            #global-settings-modal-overlay .custom-scroll::-webkit-scrollbar-thumb {
                background: rgba(255, 255, 255, 0.08);
                border-radius: 4px;
            }
            #global-settings-modal-overlay .custom-scroll::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.15); }

            /* === Ported mobile components (style cards / tactical board /
                   label designer) restyled for the desktop modal === */
            #global-settings-modal-overlay .mobile-section-header {
                font-size: 0.7rem;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: #71717a;
                margin: 18px 0 8px;
            }
            #global-settings-modal-overlay .mobile-section-header:first-child { margin-top: 0; }
            #global-settings-modal-overlay .mobile-section-header.pro-accent { color: #fbbf24; }

            /* Map style preview cards */
            #global-settings-modal-overlay .m-style-grid {
                display: grid;
                grid-template-columns: repeat(4, 1fr);
                gap: 10px;
            }
            #global-settings-modal-overlay .m-style-card {
                background: transparent;
                border: none;
                padding: 0;
                cursor: pointer;
                display: flex;
                flex-direction: column;
                gap: 6px;
                font-family: inherit;
            }
            #global-settings-modal-overlay .m-style-thumb {
                position: relative;
                display: block;
                aspect-ratio: 16 / 10;
                border-radius: 10px;
                border: 2px solid rgba(255, 255, 255, 0.08);
                overflow: hidden;
                transition: border-color 0.15s ease, box-shadow 0.15s ease;
            }
            #global-settings-modal-overlay .m-style-card:hover .m-style-thumb { border-color: rgba(255, 255, 255, 0.25); }
            #global-settings-modal-overlay .m-style-card.active .m-style-thumb {
                border-color: #38bdf8;
                box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.35);
            }
            #global-settings-modal-overlay .m-style-check {
                position: absolute;
                bottom: 6px;
                right: 6px;
                width: 20px;
                height: 20px;
                border-radius: 50%;
                background: #38bdf8;
                color: #0b1120;
                display: grid;
                place-items: center;
                font-size: 0.6rem;
                opacity: 0;
                transform: scale(0.5);
                transition: all 0.15s ease;
            }
            #global-settings-modal-overlay .m-style-card.active .m-style-check { opacity: 1; transform: scale(1); }
            #global-settings-modal-overlay .m-style-pro {
                position: absolute;
                top: 6px;
                right: 6px;
                background: rgba(0, 0, 0, 0.55);
                color: #fbbf24;
                font-size: 0.55rem;
                padding: 3px 6px;
                border-radius: 5px;
            }
            #global-settings-modal-overlay .m-style-name {
                font-size: 0.72rem;
                color: #a1a1aa;
                font-weight: 600;
                text-align: center;
            }
            #global-settings-modal-overlay .m-style-card.active .m-style-name { color: #fff; }
            #global-settings-modal-overlay .is-pro-feature.locked { opacity: 0.55; }

            /* Settings list rows + iOS-style switches */
            #global-settings-modal-overlay .m-settings-list { display: flex; flex-direction: column; gap: 6px; }
            #global-settings-modal-overlay .m-setting-row {
                display: flex;
                align-items: center;
                justify-content: space-between;
                background: rgba(255, 255, 255, 0.03);
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 10px;
                padding: 10px 12px;
            }
            #global-settings-modal-overlay .m-row-left {
                display: flex;
                align-items: center;
                gap: 10px;
                color: #e4e4e7;
                font-size: 0.82rem;
                font-weight: 500;
            }
            #global-settings-modal-overlay .m-row-left i { width: 18px; text-align: center; color: #a1a1aa; }
            #global-settings-modal-overlay .m-row-right { display: flex; align-items: center; gap: 8px; }
            #global-settings-modal-overlay .m-switch { position: relative; display: inline-block; width: 44px; height: 24px; flex-shrink: 0; }
            #global-settings-modal-overlay .m-switch input { opacity: 0; width: 0; height: 0; }
            #global-settings-modal-overlay .m-slider {
                position: absolute;
                inset: 0;
                background: rgba(255, 255, 255, 0.12);
                border-radius: 999px;
                transition: background 0.2s ease;
                cursor: pointer;
            }
            #global-settings-modal-overlay .m-slider::before {
                content: '';
                position: absolute;
                width: 18px;
                height: 18px;
                left: 3px;
                top: 3px;
                background: #fff;
                border-radius: 50%;
                transition: transform 0.2s ease;
            }
            #global-settings-modal-overlay .m-switch input:checked + .m-slider { background: #38bdf8; }
            #global-settings-modal-overlay .m-switch input:checked + .m-slider::before { transform: translateX(20px); }
            #global-settings-modal-overlay .pro-lock-badge {
                font-size: 0.55rem;
                font-weight: 800;
                color: #fbbf24;
                border: 1px solid rgba(251, 191, 36, 0.4);
                padding: 2px 6px;
                border-radius: 4px;
                display: inline-flex;
                align-items: center;
            }
            #global-settings-modal-overlay .m-color-picker {
                width: 34px;
                height: 26px;
                border: none;
                background: transparent;
                cursor: pointer;
                padding: 0;
            }

            /* Pill rows (icon color, flight plan mode) */
            #global-settings-modal-overlay .settings-mobile-grid {
                display: grid;
                grid-template-columns: repeat(3, 1fr);
                gap: 8px;
            }
            #global-settings-modal-overlay .m-setting-pill {
                background: rgba(255, 255, 255, 0.04);
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #a1a1aa;
                padding: 9px;
                border-radius: 8px;
                cursor: pointer;
                font-weight: 600;
                font-size: 0.78rem;
                font-family: inherit;
                transition: all 0.15s ease;
            }
            #global-settings-modal-overlay .m-setting-pill:hover { color: #fff; background: rgba(255, 255, 255, 0.08); }
            #global-settings-modal-overlay .m-setting-pill.active { background: #38bdf8; border-color: #38bdf8; color: #0b1120; }

            /* Range slider card */
            #global-settings-modal-overlay .m-setting-range-card {
                background: rgba(255, 255, 255, 0.03);
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 10px;
                padding: 12px;
            }
            #global-settings-modal-overlay .m-setting-range-card .range-header {
                display: flex;
                justify-content: space-between;
                color: #a1a1aa;
                font-size: 0.75rem;
                font-weight: 700;
                margin-bottom: 8px;
            }
            #global-settings-modal-overlay .m-setting-range-card .range-header span:last-child {
                color: #38bdf8;
                font-family: 'JetBrains Mono', monospace;
            }
            #global-settings-modal-overlay .m-range-input { width: 100%; }

            /* Tactical filter board */
            #global-settings-modal-overlay .m-filter-bar {
                display: flex;
                justify-content: space-between;
                align-items: center;
                background: rgba(255, 255, 255, 0.03);
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 10px;
                padding: 10px 12px;
            }
            #global-settings-modal-overlay .m-filter-count { font-size: 0.78rem; color: #71717a; font-weight: 600; }
            #global-settings-modal-overlay .m-filter-count.has-filters { color: #38bdf8; }
            #global-settings-modal-overlay .m-filter-reset {
                background: transparent;
                border: none;
                color: #ef4444;
                font-weight: 700;
                font-size: 0.75rem;
                cursor: pointer;
                font-family: inherit;
                opacity: 0;
                pointer-events: none;
                transition: opacity 0.15s ease;
            }
            #global-settings-modal-overlay .m-filter-reset.visible { opacity: 1; pointer-events: auto; }
            #global-settings-modal-overlay .m-combo-list { display: flex; flex-direction: column; gap: 10px; }
            #global-settings-modal-overlay .m-combo { position: relative; }
            #global-settings-modal-overlay .m-combo-label {
                display: flex;
                align-items: center;
                gap: 8px;
                font-size: 0.68rem;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.05em;
                color: #71717a;
                margin-bottom: 6px;
            }
            #global-settings-modal-overlay .m-combo-label i { width: 14px; text-align: center; }
            #global-settings-modal-overlay .m-combo-control { position: relative; display: flex; align-items: center; }
            #global-settings-modal-overlay .m-combo-input {
                width: 100%;
                box-sizing: border-box;
                background: #18181b;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 8px;
                color: #e4e4e7;
                padding: 9px 64px 9px 12px;
                font-size: 0.8rem;
                font-family: inherit;
                outline: none;
            }
            #global-settings-modal-overlay .m-combo-input:focus { border-color: rgba(56, 189, 248, 0.5); }
            #global-settings-modal-overlay .m-combo-caret,
            #global-settings-modal-overlay .m-combo-clear {
                position: absolute;
                background: transparent;
                border: none;
                color: #71717a;
                cursor: pointer;
                width: 26px;
                height: 26px;
                display: grid;
                place-items: center;
            }
            #global-settings-modal-overlay .m-combo-caret { right: 6px; }
            #global-settings-modal-overlay .m-combo-clear { right: 32px; opacity: 0; pointer-events: none; transition: opacity 0.15s ease; }
            #global-settings-modal-overlay .m-combo.has-value .m-combo-clear { opacity: 1; pointer-events: auto; }
            #global-settings-modal-overlay .m-combo-menu {
                position: absolute;
                top: calc(100% + 4px);
                left: 0;
                right: 0;
                background: #1c1c1f;
                border: 1px solid rgba(255, 255, 255, 0.1);
                border-radius: 10px;
                max-height: 200px;
                overflow-y: auto;
                z-index: 50;
                display: none;
                box-shadow: 0 12px 30px rgba(0, 0, 0, 0.5);
            }
            #global-settings-modal-overlay .m-combo.open .m-combo-menu { display: block; }
            #global-settings-modal-overlay .m-combo-opt {
                display: block;
                width: 100%;
                text-align: left;
                background: transparent;
                border: none;
                color: #d4d4d8;
                padding: 9px 12px;
                font-size: 0.78rem;
                cursor: pointer;
                font-family: inherit;
            }
            #global-settings-modal-overlay .m-combo-opt:hover { background: rgba(255, 255, 255, 0.06); color: #fff; }
            #global-settings-modal-overlay .m-tac-pill-row { display: flex; flex-wrap: wrap; gap: 6px; }
            #global-settings-modal-overlay .m-tac-pill {
                background: rgba(255, 255, 255, 0.04);
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #a1a1aa;
                padding: 7px 14px;
                border-radius: 999px;
                cursor: pointer;
                font-weight: 600;
                font-size: 0.75rem;
                font-family: inherit;
                transition: all 0.15s ease;
            }
            #global-settings-modal-overlay .m-tac-pill:hover { color: #fff; }
            #global-settings-modal-overlay .m-tac-pill.active { background: #38bdf8; border-color: #38bdf8; color: #0b1120; }
            #global-settings-modal-overlay .m-range-inputs { display: flex; align-items: center; gap: 8px; }
            #global-settings-modal-overlay .m-range-num {
                flex: 1;
                width: 100%;
                box-sizing: border-box;
                background: #18181b;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 8px;
                color: #e4e4e7;
                padding: 9px 12px;
                font-size: 0.8rem;
                font-family: inherit;
                outline: none;
            }
            #global-settings-modal-overlay .m-range-dash { color: #52525b; }
            #global-settings-modal-overlay .m-select {
                background: #18181b !important;
                border: 1px solid rgba(255, 255, 255, 0.08) !important;
                color: #e4e4e7 !important;
                border-radius: 8px;
                padding: 6px 8px;
                font-size: 0.8rem;
                font-family: inherit;
                max-width: 180px;
            }

            /* Label designer (desktop host) */
            #global-settings-modal-overlay .d-label-preview-stage {
                position: relative;
                min-height: 120px;
                border-radius: 12px;
                border: 1px solid rgba(255, 255, 255, 0.08);
                background:
                    radial-gradient(circle at 30% 40%, rgba(56, 189, 248, 0.06), transparent 60%),
                    repeating-linear-gradient(0deg, rgba(255, 255, 255, 0.03) 0 1px, transparent 1px 24px),
                    repeating-linear-gradient(90deg, rgba(255, 255, 255, 0.03) 0 1px, transparent 1px 24px),
                    #101013;
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 16px;
                padding: 14px;
                overflow: hidden;
            }
            #global-settings-modal-overlay .d-label-plane { color: #e4e4e7; font-size: 1.3rem; }
            #global-settings-modal-overlay .d-label-preview { font-weight: 700; line-height: 1.35; transition: opacity 0.2s ease; }
            #global-settings-modal-overlay .d-label-preview .l-callsign { font-weight: 800; }
            #global-settings-modal-overlay .d-label-preview .l-sub { font-weight: 600; opacity: 0.92; }
            #global-settings-modal-overlay .d-label-preview .d-label-logo {
                display: block; height: 26px; width: auto; max-width: 110px; margin: 0 auto 5px;
                padding: 4px 8px; border-radius: 8px; background: #fff; object-fit: contain;
                border: 1px solid rgba(15,23,42,0.35); box-shadow: 0 1px 5px rgba(0,0,0,0.45);
                box-sizing: border-box;
            }
            #global-settings-modal-overlay .d-label-disclaimer {
                display: flex; gap: 10px; align-items: flex-start;
                margin-top: 10px; padding: 11px 13px; border-radius: 12px;
                background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.07);
                font-size: 0.7rem; line-height: 1.5; color: #71717a;
            }
            #global-settings-modal-overlay .d-label-disclaimer i { color: #38bdf8; font-size: 0.75rem; margin-top: 2px; flex-shrink: 0; }
            #global-settings-modal-overlay .d-label-disclaimer a { color: #7dd3fc; text-decoration: none; word-break: break-all; }
            #global-settings-modal-overlay .m-theme-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; }
            #global-settings-modal-overlay .m-theme-pill {
                position: relative;
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 6px;
                background: rgba(255, 255, 255, 0.03);
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 10px;
                padding: 10px 6px;
                cursor: pointer;
                font-family: inherit;
                transition: all 0.15s ease;
            }
            #global-settings-modal-overlay .m-theme-pill:hover { border-color: rgba(255, 255, 255, 0.2); }
            #global-settings-modal-overlay .m-theme-pill.active {
                border-color: #38bdf8;
                box-shadow: 0 0 0 2px rgba(56, 189, 248, 0.25);
            }
            #global-settings-modal-overlay .m-theme-swatch {
                width: 34px;
                height: 26px;
                border-radius: 6px;
                display: grid;
                place-items: center;
                font-weight: 800;
                font-size: 0.8rem;
            }
            #global-settings-modal-overlay .m-theme-name { font-size: 0.65rem; color: #a1a1aa; font-weight: 600; }
            #global-settings-modal-overlay .m-theme-lock { position: absolute; top: 4px; right: 4px; color: #fbbf24; font-size: 0.55rem; }

            /* Mobile: stack the panes (the modal still renders < 768px on tablets) */
            @media (max-width: 720px) {
                #global-settings-modal-overlay .modal-body { grid-template-columns: 1fr; }
                #global-settings-modal-overlay .filter-selection-pane {
                    border-right: none;
                    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
                }
                #global-settings-modal-overlay .filter-options-list {
                    flex-direction: row;
                    overflow-x: auto;
                }
                #global-settings-modal-overlay .nexus-item { flex-shrink: 0; }
            }
        `;
        document.head.appendChild(style);
    },

    init() {
        this._injectStyles();
        this.render();
        this.attachListeners();

        // The logic to decide which UI to show
        const handleSettingsOpen = (e) => {
            // Prevent the button from keeping focus state during the transition
            // (only available when triggered by a real click event)
            if (e && e.currentTarget && typeof e.currentTarget.blur === 'function') {
                e.currentTarget.blur();
            }

            // Deep link straight to a category — the landing chrome's Filters
            // orb opens the tactical board tab via detail.category.
            const cat = e && e.detail && e.detail.category;
            if (cat && this.categories[cat]) {
                this._currentCategory = cat;
                document.querySelectorAll('.settings-modal .nexus-item').forEach(i =>
                    i.classList.toggle('active', i.dataset.catId === cat));
            }

            if (window.innerWidth <= 768) {
                // Trigger the Mobile Bottom Sheet
                window.dispatchEvent(new CustomEvent('openMobileSettings'));
            } else {
                // Open the Desktop Modal
                this.toggle(true);
            }
        };

        // Primary wiring: listen for the 'openSettings' custom event that
        // LandingUI.js dispatches when the gear tile is clicked. This is more
        // robust than binding directly to #tile-settings, because LandingUI
        // re-renders its markup and any direct click listener on the old node
        // gets dropped on the floor.
        window.addEventListener('openSettings', handleSettingsOpen);

        // Fallback wiring (defensive): also bind to the toolbar gear button,
        // which is owned by initializeSectorOpsView and isn't re-rendered.
        const toolbarSettings = document.getElementById('open-filter-settings-btn');
        if (toolbarSettings) {
            toolbarSettings.addEventListener('click', handleSettingsOpen);
        }
    },

    toggle(state) {
        this._isVisible = state;
        const modal = document.getElementById('global-settings-modal-overlay');
        if (modal) {
            modal.classList.toggle('open', state);
            if (state) this.renderCategory(this._currentCategory);
        }
    },

    render() {
        const html = `
        <div id="global-settings-modal-overlay" class="modal-overlay">
            <div class="filter-modal settings-modal">
                <div class="modal-header">
                    <div class="header-main">
                        <div class="header-icon-box"><i class="fa-solid fa-gear"></i></div>
                        <div class="header-text">
                            <h2>Global Settings</h2>
                            <span>Configure your airspace experience</span>
                        </div>
                    </div>
                    <button class="close-modal" id="close-settings-modal">&times;</button>
                </div>
                <div class="modal-body">
                    <div class="filter-selection-pane custom-scroll">
                        <div class="filter-group-wrapper">
                            <div class="filter-group-header">Configuration</div>
                            <div class="filter-options-list">
                                ${Object.entries(this.categories).map(([key, cat]) => `
                                    <button class="nexus-item ${this._currentCategory === key ? 'active' : ''}" data-cat-id="${key}">
                                        <div class="nexus-icon"><i class="fa-solid ${cat.icon}"></i></div>
                                        <span class="nexus-label">${cat.label}</span>
                                    </button>
                                `).join('')}
                            </div>
                        </div>
                    </div>
                    <div class="filter-config-pane custom-scroll">
                        <div id="settings-category-content" class="settings-content-wrapper">
                            
                        </div>
                    </div>
                </div>
            </div>
        </div>
        `;
        const container = document.getElementById('sector-ops-map-fullscreen');
        if (container) container.insertAdjacentHTML('beforeend', html);
    },

    attachListeners() {
        const modal = document.getElementById('global-settings-modal-overlay');
        modal?.addEventListener('click', (e) => {
            if (e.target === modal || e.target.id === 'close-settings-modal') this.toggle(false);
        });

        document.querySelectorAll('.settings-modal .nexus-item').forEach(item => {
            item.addEventListener('click', () => {
                this._currentCategory = item.dataset.catId;
                document.querySelectorAll('.settings-modal .nexus-item').forEach(i => i.classList.remove('active'));
                item.classList.add('active');
                this.renderCategory(this._currentCategory);
            });
        });
    },

renderCategory(catId) {
            const container = document.getElementById('settings-category-content');
            if (!container) return;

            // Check if the user is currently signed in
            const isSignedIn = !!(typeof ProfileUI !== 'undefined' && ProfileUI?._currentUser);

            let html = '';

            switch(catId) {
                case 'airspace':
                    // The shared tactical filter board — same markup, handlers
                    // and mapFilters.tactical engine as the mobile Filters
                    // sheet. MobileSettingsUI owns the board; this tab just
                    // hosts it (wired after render, see below).
                    html = `
                        <div class="settings-section">
                            <label class="config-header">Live Traffic Filters</label>
                            <div id="desktop-tactical-board" class="m-combo-list" style="gap: 14px;">
                                ${MobileSettingsUI.renderTacticalBoard()}
                            </div>
                        </div>
                    `;
                    break;
                case 'map':
                    html = '';

                    // Only show the upsell banner if the user is NOT signed in,
                    // and never on iOS native (App Store rule 3.1.3(b)).
                    if (!isSignedIn && !(typeof window !== 'undefined' && window.isIOSNative && window.isIOSNative())) {
                        html += `
                            <div class="pro-upsell-card" style="
                                position: relative;
                                margin-bottom: 22px;
                                padding: 16px 18px;
                                border-radius: 12px;
                                background: linear-gradient(135deg, rgba(56, 189, 248, 0.18), rgba(168, 85, 247, 0.14) 55%, rgba(249, 115, 22, 0.12)), #0b1220;
                                border: 1px solid rgba(56, 189, 248, 0.35);
                                box-shadow: 0 8px 28px rgba(56, 189, 248, 0.10), inset 0 1px 0 rgba(255,255,255,0.04);
                                overflow: hidden;
                            ">
                                <div style="
                                    position: absolute;
                                    top: -40px;
                                    right: -40px;
                                    width: 160px;
                                    height: 160px;
                                    background: radial-gradient(circle, rgba(56,189,248,0.35), transparent 70%);
                                    pointer-events: none;
                                "></div>
                                
                                <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 6px;">
                                    <span style="
                                        display: inline-flex;
                                        align-items: center;
                                        justify-content: center;
                                        width: 28px;
                                        height: 28px;
                                        border-radius: 8px;
                                        background: linear-gradient(135deg, #38bdf8, #a855f7);
                                        color: #fff;
                                        font-size: 0.85rem;
                                        box-shadow: 0 4px 12px rgba(56, 189, 248, 0.4);
                                    "><i class="fa-solid fa-gem"></i></span>
                                    <h4 style="margin: 0; color: #fff; font-size: 0.95rem; font-weight: 700; letter-spacing: 0.2px;">
                                        Go Pro · Personalize the Sky
                                    </h4>
                                </div>
                                
                                <p style="margin: 0 0 12px 0; font-size: 0.75rem; color: #94a3b8; line-height: 1.5;">
                                    You're using the standard visual layer. Pro unlocks the rest of it.
                                </p>
                                
                                <ul style="list-style: none; padding: 0; margin: 0 0 14px 0; display: flex; flex-direction: column; gap: 6px;">
                                    <li style="display: flex; align-items: center; gap: 10px; font-size: 0.78rem; color: #cbd5e1;">
                                        <i class="fa-solid fa-palette" style="color: #38bdf8; width: 16px; text-align: center;"></i> Custom color for <strong style="color:#fff;">every aircraft</strong> on the map
                                    </li>
                                    <li style="display: flex; align-items: center; gap: 10px; font-size: 0.78rem; color: #cbd5e1;">
                                        <i class="fa-solid fa-mountain" style="color: #a855f7; width: 16px; text-align: center;"></i> 3D terrain, buildings, and day/night terminator
                                    </li>
                                    <li style="display: flex; align-items: center; gap: 10px; font-size: 0.78rem; color: #cbd5e1;">
                                        <i class="fa-solid fa-droplet" style="color: #f97316; width: 16px; text-align: center;"></i> Custom theme gradients and premium map styles
                                    </li>
                                    <li style="display: flex; align-items: center; gap: 10px; font-size: 0.78rem; color: #cbd5e1;">
                                        <i class="fa-solid fa-bolt" style="color: #fbbf24; width: 16px; text-align: center;"></i> Priority data refresh and smooth radar
                                    </li>
                                </ul>
                                
                                <button id="set-pro-upgrade-btn" style="
                                    display: inline-flex;
                                    align-items: center;
                                    gap: 8px;
                                    padding: 9px 16px;
                                    background: linear-gradient(135deg, #38bdf8, #a855f7);
                                    color: #fff;
                                    border: none;
                                    border-radius: 8px;
                                    cursor: pointer;
                                    font-size: 0.8rem;
                                    font-weight: 700;
                                    letter-spacing: 0.3px;
                                    box-shadow: 0 4px 14px rgba(56, 189, 248, 0.35);
                                    transition: transform 0.15s ease, box-shadow 0.15s ease;
                                " onmouseover="this.style.transform='translateY(-1px)';this.style.boxShadow='0 6px 18px rgba(56,189,248,0.5)';" onmouseout="this.style.transform='';this.style.boxShadow='0 4px 14px rgba(56, 189, 248, 0.35)';">
                                    <i class="fa-solid fa-arrow-up-right-from-square"></i> Upgrade to Pro
                                </button>
                            </div>
                        `;
                    }

                    html += `
                        <div class="settings-section">
                            <label class="config-header">Map Style</label>
                            <div class="m-style-grid">
                                ${MobileSettingsUI.renderMapStyleCards(['dark', 'light', 'satellite'])}
                            </div>
                            <div class="mobile-section-header pro-accent"><i class="fa-solid fa-star"></i> <span class="ios-hide">PRO </span>Premium Styles</div>
                            <div class="m-style-grid">
                                ${MobileSettingsUI.renderMapStyleCards(['outdoors', 'nav-dark', 'nav-light', 'traffic-night', 'traffic-day'])}
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Projection &amp; 3D</label>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-map"></i> Flat Map Projection</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-flat-map" ${mapFilters.useFlatMap ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>
                            <div style="${!isSignedIn ? 'opacity: 0.5; pointer-events: none;' : ''}">
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-mountain"></i> 3D Terrain (Elevation)</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-terrain" ${mapFilters.proMapConfig.showTerrain ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-city"></i> 3D Buildings</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-buildings" ${mapFilters.proMapConfig.showBuildings ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-moon"></i> Day/Night Terminator</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-daynight" ${mapFilters.proMapConfig.showDayNight ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header"><span class="ios-hide">Pro </span>Base Map Detail</label>
                            <div style="${!isSignedIn ? 'opacity: 0.5; pointer-events: none;' : ''}">
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-earth-americas"></i> Political Borders</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-borders" ${mapFilters.proMapConfig.showBorders ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-road"></i> Roads & Highways</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-roads" ${mapFilters.proMapConfig.showRoads ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-font"></i> City & Place Labels</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-labels" ${mapFilters.proMapConfig.showLabels ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-map-pin"></i> Points of Interest</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-pois" ${mapFilters.proMapConfig.showPois ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-water"></i> Water Labels</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-water-labels" ${mapFilters.proMapConfig.showWaterLabels ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-plane-arrival"></i> Airport Layout</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-layout" ${mapFilters.proMapConfig.showAirportLayout !== false ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label"><i class="fa-solid fa-tree"></i> Parks & Forests</div>
                                    <label class="toggle-switch">
                                        <input type="checkbox" id="pro-toggle-landuse" ${mapFilters.proMapConfig.showLandUse ? 'checked' : ''} ${!isSignedIn ? 'disabled' : ''}>
                                        <span class="toggle-slider"></span>
                                    </label>
                                </div>
                            </div>
                        </div>
                    `;
                    break;
                case 'aircraft':
                    html = `
                        <div class="settings-section">
                            <label class="config-header">Pilot Identity</label>

                            <div class="settings-row" style="border-left: 3px solid ${mapFilters.userPlaneColor || '#f97316'}; background: rgba(249, 115, 22, 0.05);">
                                <div class="row-label">
                                    <i class="fa-solid fa-user-astronaut" style="color: ${mapFilters.userPlaneColor || '#f97316'};"></i> Your Plane Color
                                </div>
                                <input type="color" id="set-user-plane-color" class="settings-color-input" value="${mapFilters.userPlaneColor || '#f97316'}">
                            </div>
                            <p style="font-size: 0.65rem; color: #71717a; margin: -10px 0 12px 16px;">
                                How your own aircraft is highlighted on the live map.
                            </p>

                            <div class="settings-row" style="border-left: 3px solid ${mapFilters.friendPlaneColor || '#c084fc'}; background: rgba(192, 132, 252, 0.05);">
                                <div class="row-label">
                                    <i class="fa-solid fa-user-group" style="color: ${mapFilters.friendPlaneColor || '#c084fc'};"></i> Watchlist Plane Color
                                </div>
                                <input type="color" id="set-friend-plane-color" class="settings-color-input" value="${mapFilters.friendPlaneColor || '#c084fc'}">
                            </div>
                            <p style="font-size: 0.65rem; color: #71717a; margin: -10px 0 12px 16px;">
                                Color used for pilots on your watchlist.
                            </p>

                            <div class="settings-row pro-feature-row" style="border-left: 3px solid #38bdf8; background: rgba(56, 189, 248, 0.05); ${!isSignedIn ? 'opacity: 0.5; pointer-events: none;' : ''}">
                                <div class="row-label">
                                    <i class="fa-solid fa-wand-magic-sparkles" style="color: #38bdf8;"></i> Custom Plane Color <span class="ios-hide" style="background: #38bdf8; color: #000; font-size: 0.6rem; padding: 2px 6px; border-radius: 4px; margin-left: 8px; font-weight: 800;">PRO</span>
                                </div>
                                <input type="color" id="set-pro-color" class="settings-color-input" value="${mapFilters.proCustomColor || '#38bdf8'}" ${!isSignedIn ? 'disabled' : ''}>
                            </div>
                            <p style="font-size: 0.65rem; color: #71717a; margin: -10px 0 4px 16px;">
                                Recolor every other aircraft on the map. Doesn't affect your colors above.
                            </p>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Icon Color</label>
                            <div class="settings-mobile-grid">
                                <button class="m-setting-pill ${(mapFilters.iconColorMode || 'default') === 'default' ? 'active' : ''}" data-setting="iconColorMode" data-value="default" type="button">White</button>
                                <button class="m-setting-pill ${mapFilters.iconColorMode === 'blue' ? 'active' : ''}" data-setting="iconColorMode" data-value="blue" type="button">Blue</button>
                                <button class="m-setting-pill ${mapFilters.iconColorMode === 'orange' ? 'active' : ''}" data-setting="iconColorMode" data-value="orange" type="button">Orange</button>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Aircraft Display</label>

                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-cube"></i> 3D Traffic View</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-3d-traffic" ${mapFilters.live3DTraffic ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>

                            <div class="settings-row" style="flex-direction: column; align-items: flex-start; gap: 8px;">
                                <div style="display: flex; justify-content: space-between; width: 100%; align-items: center;">
                                    <div class="row-label"><i class="fa-solid fa-plane-up"></i> Aircraft Scale</div>
                                    <span id="plane-size-display" style="font-family: 'JetBrains Mono', monospace; color: #38bdf8; font-weight: 800; font-size: 0.9rem;">
                                        ${Math.round(mapFilters.planeIconSize * 100)}%
                                    </span>
                                </div>
                                <input type="range" id="set-plane-size" min="0.1" max="1.0" step="0.05" value="${mapFilters.planeIconSize}" style="width: 100%;">
                            </div>

                            <div class="settings-row" style="margin-bottom: 4px;">
                                <div class="row-label">
                                    <i class="fa-solid fa-cube"></i> 3D Path Trail
                                    <span style="background: #f59e0b; color: #000; font-size: 0.6rem; padding: 2px 6px; border-radius: 4px; margin-left: 10px; font-weight: 800; letter-spacing: 0.5px;">EXPERIMENTAL</span>
                                </div>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="setting-toggle-3dpath" ${mapFilters.show3DPath ? 'checked' : ''}>
                                    <span class="toggle-slider"></span>
                                </label>
                            </div>
                            <p style="font-size: 0.7rem; color: #71717a; margin: 0 0 4px 16px; line-height: 1.4;">
                                <i class="fa-solid fa-circle-info" style="font-size: 0.6rem; margin-right: 4px;"></i>
                                Note: This feature is experimental and may be broken at times.
                            </p>
                        </div>
                    `;
                    break;
                case 'labels': {
                    const fieldDefs = MobileSettingsUI.getLabelFieldDefs();
                    const themeDefs = MobileSettingsUI.getLabelThemeDefs();
                    const labelCfg = Object.assign({}, DEFAULT_LABEL_CONFIG, mapFilters.labelConfig || {});
                    const currentTheme = mapFilters.labelTheme || 'default';
                    const labelScale = Math.min(1.4, Math.max(0.8, parseFloat(mapFilters.labelScale) || 1));
                    html = `
                        <div class="settings-section">
                            <label class="config-header">Aircraft Labels</label>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-tag"></i> Show Labels on Map</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-show-labels" ${mapFilters.showAircraftLabels ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Live Preview</label>
                            <div class="d-label-preview-stage">
                                <div class="d-label-plane"><i class="fa-solid fa-plane" style="transform:rotate(45deg)"></i></div>
                                <div id="d-label-preview" class="d-label-preview"></div>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Label Rows</label>
                            <div class="m-settings-list">
                                ${fieldDefs.map(f => `
                                    <div class="m-setting-row">
                                        <div class="m-row-left"><i class="fa-solid ${f.icon}"></i><span>${f.label}</span></div>
                                        <div class="m-row-right">
                                            <label class="m-switch">
                                                <input type="checkbox" class="d-label-field-input" data-label-field="${f.key}" ${labelCfg[f.key] ? 'checked' : ''}>
                                                <span class="m-slider"></span>
                                            </label>
                                        </div>
                                    </div>
                                `).join('')}
                            </div>
                            <div class="d-label-disclaimer">
                                <i class="fa-solid fa-circle-info"></i>
                                <span>Airline names &amp; logos are trademarks of their respective owners, shown for
                                entertainment only to represent the airline of your virtual flight. Inflight is not
                                affiliated with, endorsed by, or sponsored by any airline. Airline representatives can
                                request a logo's removal at
                                <a href="mailto:inflightcustomer@gmail.com">inflightcustomer@gmail.com</a>.</span>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Label Size</label>
                            <div class="m-setting-range-card">
                                <div class="range-header"><span>Scale</span><span id="d-val-labelScale">${labelScale.toFixed(1)}×</span></div>
                                <input type="range" id="set-label-scale" class="m-range-input" min="0.8" max="1.4" step="0.1" value="${labelScale}">
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header"><span class="ios-hide">Pro </span>Label Theme</label>
                            <div class="m-theme-grid">
                                ${themeDefs.map(t => `
                                    <button class="m-theme-pill ${t.pro ? 'is-pro-feature' : ''} ${currentTheme === t.value ? 'active' : ''}"
                                            data-label-theme="${t.value}" ${t.pro ? 'data-pro="true"' : ''} type="button">
                                        <span class="m-theme-swatch" style="color:${t.text}; background:${t.halo};">Aa</span>
                                        <span class="m-theme-name">${t.label}</span>
                                        ${t.pro ? '<span class="m-theme-lock"><i class="fa-solid fa-lock"></i></span>' : ''}
                                    </button>
                                `).join('')}
                            </div>
                        </div>
                    `;
                    break;
                }
                case 'overlays':
                    html = `
                        <div class="settings-section">
                            <label class="config-header">ATC &amp; Airports</label>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-tags"></i> Classic Airport Tags</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-classic-airport-tags" ${mapFilters.useClassicAirportTags ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-circle-dot"></i> Show Unstaffed</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-show-unstaffed" ${mapFilters.showUnstaffedAirports ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-location-dot"></i> Hide No-ATC Dots</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-hide-noatc-dots" ${mapFilters.hideNoAtcMarkers ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-headset"></i> Hide ATC Markers</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-hide-atc-markers" ${mapFilters.hideAtcMarkers ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Flight Plan Routes</label>
                            <div class="settings-mobile-grid">
                                <button class="m-setting-pill ${(mapFilters.planDisplayMode || 'none') === 'none' ? 'active' : ''}" data-setting="planDisplayMode" data-value="none" type="button">None</button>
                                <button class="m-setting-pill ${mapFilters.planDisplayMode === 'direct' ? 'active' : ''}" data-setting="planDisplayMode" data-value="direct" type="button">Direct</button>
                                <button class="m-setting-pill ${mapFilters.planDisplayMode === 'full' ? 'active' : ''}" data-setting="planDisplayMode" data-value="full" type="button">Full Plan</button>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Oceanic Tracks</label>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-route"></i> North Atlantic Tracks</div>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="set-nat-tracks" ${mapFilters.showNatTracks ? 'checked' : ''}>
                                    <span class="toggle-slider"></span>
                                </label>
                            </div>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-font"></i> Track Labels</div>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="set-nat-labels" ${mapFilters.showNatLabels ? 'checked' : ''}>
                                    <span class="toggle-slider"></span>
                                </label>
                            </div>
                        </div>

                        <div class="settings-section">
                            <label class="config-header">Flight Window</label>
                            <div class="settings-row">
                                <div class="row-label"><i class="fa-solid fa-window-maximize"></i> Simple Flight Info</div>
                                <label class="toggle-switch"><input type="checkbox" id="set-simple-window" ${mapFilters.useSimpleFlightWindow ? 'checked' : ''}><span class="toggle-slider"></span></label>
                            </div>
                        </div>
                    `;
                    break;
                case 'theme':
                    html = `
                        <div class="settings-section">
                            <label class="config-header">Window Appearance</label>
                            
                            <div style="${!isSignedIn ? 'opacity: 0.5; pointer-events: none;' : ''}">
                                <div class="settings-row">
                                    <div class="row-label">Gradient Start Color</div>
                                    <input type="color" id="set-theme-start" class="settings-color-input" value="${mapFilters.themeStartColor || '#18181b'}" ${!isSignedIn ? 'disabled' : ''}>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label">Gradient End Color</div>
                                    <input type="color" id="set-theme-end" class="settings-color-input" value="${mapFilters.themeEndColor || '#18181b'}" ${!isSignedIn ? 'disabled' : ''}>
                                </div>
                                <div class="settings-row">
                                    <div class="row-label">Theme Opacity (%)</div>
                                    <input type="number" id="set-theme-opacity" class="row-input" style="width: 80px;" value="${mapFilters.themeOpacity || 90}" ${!isSignedIn ? 'disabled' : ''}>
                                </div>
                                <button id="set-theme-reset" class="modal-btn secondary" style="width: 100%; margin-top: 20px;" ${!isSignedIn ? 'disabled' : ''}>Reset Default Theme</button>
                            </div>
                        </div>
                    `;
                    break;
            }

            container.innerHTML = html;

            // --- Post-render syncs for the ported mobile components ---
            if (catId === 'airspace') {
                // Wire + hydrate the shared tactical board (fresh DOM each
                // render, so the attach guard never blocks a re-bind).
                const board = container.querySelector('#desktop-tactical-board');
                if (board) {
                    MobileSettingsUI.attachTacticalHandlers(board);
                    MobileSettingsUI.syncTacticalControls(board);
                }
            }
            if (catId === 'map') {
                const activeCard = container.querySelector(`.m-style-card[data-value="${mapFilters.mapStyle || 'dark'}"]`);
                if (activeCard) activeCard.classList.add('active');
            }
            if (!isSignedIn) {
                // Signed-out users see pro style cards / label themes locked;
                // clicking them routes to the upsell (see attachConfigListeners).
                container.querySelectorAll('.is-pro-feature').forEach(el => el.classList.add('locked'));
            }

            this.attachConfigListeners();

            if (catId === 'labels') this.updateLabelPreview();
        },

    // Desktop twin of MobileSettingsUI.updateLabelPreview — same field/theme
    // definitions, but its own preview node (#d-label-preview) because the
    // mobile sheet keeps its #m-label-preview in the DOM even on desktop.
    updateLabelPreview() {
        const preview = document.getElementById('d-label-preview');
        if (!preview) return;
        const cfg = Object.assign({}, DEFAULT_LABEL_CONFIG, mapFilters.labelConfig || {});
        const sample = MobileSettingsUI.getLabelPreviewSample();

        const lines = [];
        if (cfg.callsign)     lines.push({ text: sample.callsign, cls: 'l-callsign' });
        if (cfg.pilot)        lines.push({ text: sample.pilot, cls: 'l-sub' });
        if (cfg.aircraftType) lines.push({ text: sample.aircraftType, cls: 'l-sub' });
        if (cfg.registration) lines.push({ text: sample.registration, cls: 'l-sub' });
        if (cfg.route)        lines.push({ text: sample.route, cls: 'l-sub' });
        if (cfg.altSpeed)     lines.push({ text: sample.altSpeed, cls: 'l-sub' });
        if (!lines.length)    lines.push({ text: sample.callsign, cls: 'l-callsign' });

        const themes = MobileSettingsUI.getLabelThemeDefs();
        const theme = themes.find(t => t.value === (mapFilters.labelTheme || 'default')) || themes[0];
        const scale = Math.min(1.4, Math.max(0.8, parseFloat(mapFilters.labelScale) || 1));

        // Mirrors the on-map airline badge (white chip, logo contained inside).
        const logoLine = cfg.airlineLogo
            ? `<img class="d-label-logo" src="${sample.airlineLogo}" alt="" onerror="this.style.display='none'">`
            : '';

        preview.style.color = theme.text;
        preview.style.textShadow = `0 0 3px ${theme.halo}, 0 1px 2px ${theme.halo}, 0 0 4px ${theme.halo}`;
        preview.style.fontSize = `${0.95 * scale}rem`;
        preview.innerHTML = logoLine + lines.map(l => `<div class="${l.cls}">${l.text}</div>`).join('');
        preview.style.opacity = mapFilters.showAircraftLabels ? '1' : '0.35';
    },

    attachConfigListeners() {
        const update = (key, val) => {
            mapFilters[key] = val;
            saveFiltersToLocalStorage();
            updateMapFilters();
        };

        // --- 1. Define Pro Layer IDs (UPDATED) ---
        const proIds = {
    'pro-toggle-borders': 'showBorders',
    'pro-toggle-roads': 'showRoads',
    'pro-toggle-labels': 'showLabels',
    'pro-toggle-pois': 'showPois',
    'pro-toggle-water-labels': 'showWaterLabels',
    'pro-toggle-terrain': 'showTerrain',
    'pro-toggle-layout': 'showAirportLayout',
    'pro-toggle-landuse': 'showLandUse',
    'pro-toggle-buildings': 'showBuildings', // NEW
    'pro-toggle-daynight': 'showDayNight'    // NEW
};

        // --- 2. Define General Settings IDs ---
        const ids = {
            'set-classic-airport-tags': 'useClassicAirportTags',
            'set-staff-only': 'showStaffOnly',
            'set-va-only': 'showVaOnly',
            'set-nat-tracks': 'showNatTracks',
            'set-nat-labels': 'showNatLabels',
            'setting-toggle-3dpath': 'show3DPath',
            'set-flat-map': 'useFlatMap',
            'set-show-unstaffed': 'showUnstaffedAirports',
            'set-hide-noatc-dots': 'hideNoAtcMarkers',
            'set-hide-atc-markers': 'hideAtcMarkers',
            'set-simple-window': 'useSimpleFlightWindow'
        };

        // --- 3. Attach Pro Layer Listeners ---
        Object.keys(proIds).forEach(id => {
            const el = document.getElementById(id);
            if (el) {
                el.addEventListener('change', (e) => {
                    mapFilters.proMapConfig[proIds[id]] = e.target.checked;
                    saveFiltersToLocalStorage();
                    // NEW: Update base map layers specifically
                    if (typeof updateBaseMapLayerVisibility === 'function') {
                        updateBaseMapLayerVisibility(); 
                    }
                    if (typeof updatePro3DLayers === 'function') updatePro3DLayers();
                });
            }
        });

        // --- 4. Attach General Listeners ---
        Object.keys(ids).forEach(id => {
            const el = document.getElementById(id);
            if (el) el.addEventListener('change', (e) => update(ids[id], e.target.checked));
        });

        // 3D Traffic View — routed through the shared toggle so the map toolbar
        // button stays in sync (it's not a plain mapFilters flag like the rest).
        const live3dToggle = document.getElementById('set-3d-traffic');
        if (live3dToggle) {
            live3dToggle.addEventListener('change', (e) => setLive3DTraffic(e.target.checked));
        }

        // Virtual Airline Filter Select
        const vaFilterSelect = document.getElementById('set-va-filter');
        if (vaFilterSelect) {
            vaFilterSelect.addEventListener('change', (e) => {
                update('vaFilter', e.target.value);
                if (typeof updateToolbarButtonStates === 'function') updateToolbarButtonStates();
            });
        }

        // Plane Size Input
        const planeSizeInput = document.getElementById('set-plane-size');
        const planeSizeDisplay = document.getElementById('plane-size-display');
        if (planeSizeInput && planeSizeDisplay) {
            planeSizeInput.addEventListener('input', (e) => {
                const val = parseFloat(e.target.value);
                planeSizeDisplay.textContent = Math.round(val * 100) + '%';
                update('planeIconSize', val);
            });
        }

        // Icon Color Select
        const iconColorSelect = document.getElementById('set-icon-color');
        if (iconColorSelect) {
            iconColorSelect.addEventListener('change', (e) => update('iconColorMode', e.target.value));
        }

        // Pro Custom Color Picker
        const proColorInput = document.getElementById('set-pro-color');
        if (proColorInput) {
            proColorInput.addEventListener('input', (e) => {
                // Switch into the dedicated 'custom' mode so every other
                // aircraft is recolored with the picked color (they move onto
                // the tintable SDF layer). The Default/Blue/Orange radios stay
                // unchecked; selecting "Default (White)" reverts to natural.
                mapFilters.iconColorMode = 'custom';
                document.querySelectorAll('input[name="icon-color-mode"]').forEach(r => { r.checked = false; });
                update('proCustomColor', e.target.value);
            });
        }

        // User Plane Color Picker (logged-in pilot's own plane)
        const userPlaneColorInput = document.getElementById('set-user-plane-color');
        if (userPlaneColorInput) {
            userPlaneColorInput.addEventListener('input', (e) => {
                update('userPlaneColor', e.target.value);
            });
        }

        // Watchlist (Friends) Plane Color Picker
        const friendPlaneColorInput = document.getElementById('set-friend-plane-color');
        if (friendPlaneColorInput) {
            friendPlaneColorInput.addEventListener('input', (e) => {
                update('friendPlaneColor', e.target.value);
            });
        }

 // flight.js
const upgradeBtn = document.getElementById('set-pro-upgrade-btn');
if (upgradeBtn) {
    upgradeBtn.addEventListener('click', () => {
        const isSignedIn = !!(typeof ProfileUI !== 'undefined' && ProfileUI?._currentUser);

        // If not signed in, take them straight to signup
        if (!isSignedIn) {
            if (window.AuthUI && typeof window.AuthUI.open === 'function') {
                window.AuthUI.open('signup');
            }
            return;
        }

        // If already signed in, proceed with standard event or profile view
        let handled = false;
        try {
            const evt = new CustomEvent('pro-upgrade-requested', { bubbles: true, cancelable: true, detail: { source: 'visuals-settings' } });
            handled = !window.dispatchEvent(evt) || evt.defaultPrevented;
        } catch (_) {}

        if (!handled) {
            if (typeof ProfileUI !== 'undefined' && typeof ProfileUI.open === 'function') {
                ProfileUI.open(ProfileUI._currentUser);
            }
        }
    });
}

        // Flight Plan Mode Select
        const planModeSelect = document.getElementById('set-plan-mode');
        if (planModeSelect) {
            planModeSelect.addEventListener('change', (e) => {
                update('planDisplayMode', e.target.value);
                // Redraw the currently-selected flight's plan immediately so the
                // change is visible without waiting for the next data tick.
                if (currentFlightInWindow && cachedFlightDataForStatsView && cachedFlightDataForStatsView.plan) {
                    updateFlightPlanLayer(currentFlightInWindow, cachedFlightDataForStatsView.plan, currentAircraftPositionForGeocode);
                }
            });
        }

        // Theme Configuration
        const themeStart = document.getElementById('set-theme-start');
        const themeEnd = document.getElementById('set-theme-end');
        const themeOpacity = document.getElementById('set-theme-opacity');
        const themeReset = document.getElementById('set-theme-reset');

        const updateTheme = () => {
            mapFilters.themeStartColor = themeStart.value;
            mapFilters.themeEndColor = themeEnd.value;
            mapFilters.themeOpacity = parseInt(themeOpacity.value) || 90;
            saveFiltersToLocalStorage();
            // Optional: Trigger a visual refresh of the window if open
        };

        if (themeStart) themeStart.addEventListener('input', updateTheme);
        if (themeEnd) themeEnd.addEventListener('input', updateTheme);
        if (themeOpacity) themeOpacity.addEventListener('input', updateTheme);
        
        if (themeReset) {
            themeReset.addEventListener('click', () => {
                themeStart.value = '#18181b';
                themeEnd.value = '#18181b';
                themeOpacity.value = 90;
                updateTheme();
            });
        }

        // ---- Ported mobile controls (style cards / pills / label designer) ----
        const content = document.getElementById('settings-category-content');
        const openProUpsell = () => {
            // App Store compliance: no in-app upgrade path on iOS native.
            if (typeof window !== 'undefined' && window.isIOSNative && window.isIOSNative()) return;
            this.toggle(false);
            setTimeout(() => {
                if (window.AuthUI && typeof window.AuthUI.open === 'function') {
                    window.AuthUI.open('signup');
                } else if (window.initInflightPro) {
                    window.initInflightPro();
                }
            }, 250);
        };

        // Map style preview cards
        content?.querySelectorAll('.m-style-card').forEach(card => {
            card.addEventListener('click', () => {
                if (card.classList.contains('locked')) { openProUpsell(); return; }
                mapFilters.mapStyle = card.dataset.value;
                content.querySelectorAll('.m-style-card').forEach(c => c.classList.remove('active'));
                card.classList.add('active');
                saveFiltersToLocalStorage();
                updateMapFilters();
            });
        });

        // Enum pill rows (icon color mode, flight plan mode)
        content?.querySelectorAll('.m-setting-pill[data-setting]').forEach(btn => {
            btn.addEventListener('click', () => {
                const setting = btn.dataset.setting;
                mapFilters[setting] = btn.dataset.value;
                btn.parentElement.querySelectorAll('.m-setting-pill').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                saveFiltersToLocalStorage();
                updateMapFilters();
                // Redraw the open flight's plan immediately on mode change.
                if (setting === 'planDisplayMode' && currentFlightInWindow && cachedFlightDataForStatsView && cachedFlightDataForStatsView.plan) {
                    updateFlightPlanLayer(currentFlightInWindow, cachedFlightDataForStatsView.plan, currentAircraftPositionForGeocode);
                }
            });
        });

        // Label designer — master toggle, per-row toggles, scale, theme pills.
        const showLabelsToggle = document.getElementById('set-show-labels');
        if (showLabelsToggle) {
            showLabelsToggle.addEventListener('change', (e) => {
                update('showAircraftLabels', e.target.checked);
                this.updateLabelPreview();
            });
        }
        content?.querySelectorAll('.d-label-field-input').forEach(input => {
            input.addEventListener('change', (e) => {
                if (!mapFilters.labelConfig) mapFilters.labelConfig = {};
                mapFilters.labelConfig[e.target.dataset.labelField] = e.target.checked;
                this.updateLabelPreview();
                if (typeof applyAircraftLabelStyle === 'function') applyAircraftLabelStyle();
                saveFiltersToLocalStorage();
            });
        });
        const labelScaleInput = document.getElementById('set-label-scale');
        if (labelScaleInput) {
            labelScaleInput.addEventListener('input', (e) => {
                mapFilters.labelScale = parseFloat(e.target.value);
                const disp = document.getElementById('d-val-labelScale');
                if (disp) disp.textContent = `${(parseFloat(e.target.value) || 1).toFixed(1)}×`;
                this.updateLabelPreview();
                if (typeof applyAircraftLabelStyle === 'function') applyAircraftLabelStyle();
                saveFiltersToLocalStorage();
            });
        }
        content?.querySelectorAll('.m-theme-pill').forEach(btn => {
            btn.addEventListener('click', () => {
                if (btn.classList.contains('locked')) { openProUpsell(); return; }
                mapFilters.labelTheme = btn.dataset.labelTheme;
                content.querySelectorAll('.m-theme-pill').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                this.updateLabelPreview();
                if (typeof applyAircraftLabelStyle === 'function') applyAircraftLabelStyle();
                saveFiltersToLocalStorage();
            });
        });
    }
};

// === Desktop Active ATC board ==============================================
// Ports the mobile bottom-bar ATC tab (MobileLandingChromeUI's ATC sheet) to a
// desktop floating panel: one row per staffed field with lit position columns
// (ATS/GND/TWR/APP/DEP), an expandable "on frequency now" controller drawer,
// and click-to-open the airport. Reads the same window.InflightATC bridge and
// refreshes live on 'activeAtcUpdated'. Opened from the landing chrome's ATC
// orb via the 'openAtcBoard' event.
const AtcBoardUI = {
    _visible: false,
    _openIcaos: new Set(),

    init() {
        if (document.getElementById('atc-board-window')) return;
        const mapContainer = document.getElementById('sector-ops-map-fullscreen');
        if (!mapContainer) return;

        this._injectStyles();
        mapContainer.insertAdjacentHTML('beforeend', `
            <div id="atc-board-window" class="info-window">
                <div class="info-window-header">
                    <h3><i class="fa-solid fa-tower-broadcast" style="margin-right: 10px;"></i> Active ATC <span id="atc-board-count" class="atc-board-count"></span></h3>
                    <div class="info-window-actions">
                        <button id="atc-board-close-btn" title="Close"><i class="fa-solid fa-xmark"></i></button>
                    </div>
                </div>
                <div id="atc-board-content" class="info-window-content"></div>
            </div>
        `);

        document.getElementById('atc-board-close-btn')?.addEventListener('click', () => this.toggle(false));
        window.addEventListener('openAtcBoard', () => this.toggle(!this._visible));
        window.addEventListener('activeAtcUpdated', () => { if (this._visible) this.render(); });

        document.getElementById('atc-board-content')?.addEventListener('click', (e) => {
            const expandBtn = e.target.closest('[data-atc-expand]');
            if (expandBtn) {
                const wrap = expandBtn.closest('.d-atc-awrap');
                const icao = wrap?.dataset.icao;
                if (!wrap || !icao) return;
                const open = !wrap.classList.contains('ctrl-open');
                wrap.classList.toggle('ctrl-open', open);
                expandBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
                if (open) this._openIcaos.add(icao); else this._openIcaos.delete(icao);
                return;
            }
            const row = e.target.closest('.d-atc-arow');
            if (row) {
                const icao = row.closest('.d-atc-awrap')?.dataset.icao;
                if (icao && typeof handleAirportClick === 'function') handleAirportClick(icao, null, true);
            }
        });
    },

    toggle(state) {
        const win = document.getElementById('atc-board-window');
        if (!win) return;
        this._visible = state;
        win.classList.toggle('visible', state);
        if (state) this.render();
    },

    _esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, c => (
            { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
        ));
    },

    // Same position-type → label/color mapping as the mobile sheet.
    _typePill(type) {
        const map = {
            7: ['ATIS', 'atis'], 0: ['Ground', 'gnd'], 3: ['Clearance', 'gnd'],
            1: ['Tower', 'twr'], 4: ['Approach', 'app'], 5: ['Departure', 'dep'],
            6: ['Center', 'app']
        };
        const [label, cls] = map[type] || ['Unknown', ''];
        return { label, cls };
    },

    _controllersFor(icao) {
        const api = window.InflightATC;
        if (!api) return [];
        const order = { 7: 0, 3: 1, 0: 2, 1: 3, 4: 4, 5: 5, 6: 6 };
        return api.getFacilities()
            .filter(f => f && f.airportName === icao)
            .sort((x, y) => (order[x.type] ?? 9) - (order[y.type] ?? 9));
    },

    _controllerRowHTML(f) {
        const api = window.InflightATC;
        const pill = this._typePill(Number(f.type));
        const dur = (api && api.formatDuration) ? api.formatDuration(f.startTime) : '';
        let since = '';
        if (f.startTime) {
            const t = new Date(f.startTime).getTime();
            if (Number.isFinite(t)) {
                try {
                    since = new Date(t).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' }) + 'Z';
                } catch (_) {}
            }
        }
        const meta = [dur ? `${dur} online` : '', since ? `since ${since}` : ''].filter(Boolean).join(' · ');
        return `
            <div class="d-atc-ctrl">
                <span class="d-atc-ctrl-pill ${pill.cls}">${this._esc(pill.label)}</span>
                <span class="d-atc-ctrl-main">
                    <span class="d-atc-ctrl-user">${this._esc(f.username || 'Unknown controller')}</span>
                    ${meta ? `<span class="d-atc-ctrl-meta">${this._esc(meta)}</span>` : ''}
                </span>
            </div>`;
    },

    _airportRowHTML(a) {
        const col = (label, on, cls) =>
            `<span class="d-atc-col${on ? ' on ' + cls : ''}">${label}</span>`;
        const controllers = (a.count > 0) ? this._controllersFor(a.icao) : [];
        const drawer = controllers.length ? `
            <div class="d-atc-ctrl-drawer">
                <div class="d-atc-ctrl-head">On frequency now</div>
                ${controllers.map(f => this._controllerRowHTML(f)).join('')}
            </div>` : '';
        const isOpen = controllers.length && this._openIcaos.has(a.icao);
        const chevron = controllers.length ? `
            <button type="button" class="d-atc-expand" data-atc-expand="1"
                    aria-label="Show controllers" aria-expanded="${isOpen ? 'true' : 'false'}">
                <i class="fa-solid fa-chevron-down"></i>
            </button>` : '';
        return `
            <div class="d-atc-awrap${isOpen ? ' ctrl-open' : ''}" data-icao="${this._esc(a.icao)}">
                <div class="d-atc-arow-line">
                    <button type="button" class="d-atc-arow" title="Open ${this._esc(a.icao)}">
                        <span class="d-atc-apt">
                            <span class="d-atc-icao">${this._esc(a.icao)}</span>
                            <span class="d-atc-aptname">${this._esc(a.name || a.icao)}</span>
                        </span>
                        <span class="d-atc-tower">
                            <i class="fa-solid fa-tower-broadcast"></i>
                            <span class="d-atc-num">${a.count}</span>
                        </span>
                        <span class="d-atc-cols">
                            ${col('ATS', a.atis, 'atis')}
                            ${col('GND', a.gnd, 'gnd')}
                            ${col('TWR', a.twr, 'twr')}
                            ${col('APP', a.app, 'app')}
                            ${col('DEP', a.dep, 'dep')}
                        </span>
                    </button>
                    ${chevron}
                </div>
                ${drawer}
            </div>`;
    },

    render() {
        const body = document.getElementById('atc-board-content');
        const countEl = document.getElementById('atc-board-count');
        if (!body) return;

        const api = window.InflightATC;
        const board = (api && api.getAirportBoard) ? api.getAirportBoard() : [];
        const total = board.reduce((s, a) => s + (a.count || 0), 0);
        if (countEl) countEl.textContent = total ? `${total} online` : 'None online';

        if (!board.length) {
            body.innerHTML = `
                <div class="d-atc-empty">
                    <i class="fa-solid fa-tower-broadcast"></i>
                    <p>No controllers online</p>
                    <span>When ATC connects on this server, every staffed airport appears here — click one to jump to it.</span>
                </div>`;
            return;
        }
        body.innerHTML = `<div class="d-atc-board">${board.map(a => this._airportRowHTML(a)).join('')}</div>`;
    },

    _injectStyles() {
        if (document.getElementById('atc-board-ui-styles')) return;
        const style = document.createElement('style');
        style.id = 'atc-board-ui-styles';
        style.textContent = `
            /* The board lives on the LEFT so it can stay open next to the
               airport/aircraft windows that dock top-right. */
            #atc-board-window {
                left: 20px;
                right: auto;
                top: 90px;
                width: 420px;
                max-height: calc(100vh - 120px);
                transform-origin: top left;
                transform: translateX(-28px) translateY(10px) scale(0.96);
            }
            #atc-board-window.visible { transform: translateX(0) translateY(0) scale(1); }
            .atc-board-count {
                font-size: 0.7rem;
                font-weight: 700;
                color: #a1a1aa;
                background: rgba(255, 255, 255, 0.06);
                border: 1px solid rgba(255, 255, 255, 0.1);
                border-radius: 999px;
                padding: 2px 8px;
                margin-left: 8px;
                vertical-align: middle;
            }
            .d-atc-board { display: flex; flex-direction: column; gap: 6px; padding: 12px; }
            .d-atc-awrap {
                background: rgba(255, 255, 255, 0.03);
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 10px;
                overflow: hidden;
            }
            .d-atc-arow-line { display: flex; align-items: stretch; }
            .d-atc-arow {
                flex: 1;
                min-width: 0;
                display: flex;
                align-items: center;
                gap: 10px;
                background: transparent;
                border: none;
                padding: 10px 12px;
                cursor: pointer;
                text-align: left;
                font-family: inherit;
            }
            .d-atc-arow:hover { background: rgba(255, 255, 255, 0.04); }
            .d-atc-apt { display: flex; flex-direction: column; min-width: 0; flex: 1; gap: 2px; }
            .d-atc-icao { font-family: var(--font-data); font-weight: 800; font-size: 0.9rem; color: #fafafa; }
            .d-atc-aptname {
                font-size: 0.65rem;
                color: #71717a;
                font-weight: 600;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .d-atc-tower {
                display: flex;
                align-items: center;
                gap: 5px;
                color: #a1a1aa;
                font-size: 0.7rem;
                font-weight: 700;
                flex-shrink: 0;
            }
            .d-atc-tower .d-atc-num { font-family: var(--font-data); }
            .d-atc-awrap[data-icao] .d-atc-tower i { font-size: 0.65rem; }
            .d-atc-cols { display: flex; gap: 4px; flex-shrink: 0; }
            .d-atc-col {
                font-size: 0.55rem;
                font-weight: 800;
                letter-spacing: 0.5px;
                padding: 3px 5px;
                border-radius: 4px;
                color: #52525b;
                background: rgba(255, 255, 255, 0.03);
                border: 1px solid rgba(255, 255, 255, 0.05);
            }
            .d-atc-col.on { background: rgba(255, 255, 255, 0.06); border-color: rgba(255, 255, 255, 0.14); }
            .d-atc-col.on.atis { color: #c084fc; }
            .d-atc-col.on.gnd { color: #d4d4d8; }
            .d-atc-col.on.twr { color: #60a5fa; }
            .d-atc-col.on.app { color: #818cf8; }
            .d-atc-col.on.dep { color: #38bdf8; }
            .d-atc-expand {
                background: transparent;
                border: none;
                border-left: 1px solid rgba(255, 255, 255, 0.06);
                color: #71717a;
                width: 38px;
                cursor: pointer;
                flex-shrink: 0;
            }
            .d-atc-expand:hover { color: #fff; background: rgba(255, 255, 255, 0.04); }
            .d-atc-expand i { transition: transform 0.2s ease; }
            .d-atc-awrap.ctrl-open .d-atc-expand i { transform: rotate(180deg); }
            .d-atc-ctrl-drawer { display: none; border-top: 1px solid rgba(255, 255, 255, 0.06); padding: 8px 12px 10px; }
            .d-atc-awrap.ctrl-open .d-atc-ctrl-drawer { display: block; }
            .d-atc-ctrl-head {
                font-size: 0.6rem;
                font-weight: 800;
                letter-spacing: 0.8px;
                text-transform: uppercase;
                color: #71717a;
                padding: 4px 0 8px;
            }
            .d-atc-ctrl { display: flex; align-items: center; gap: 10px; padding: 5px 0; }
            .d-atc-ctrl-pill {
                width: 72px;
                text-align: center;
                font-size: 0.6rem;
                font-weight: 800;
                padding: 3px 0;
                border-radius: 5px;
                background: #1c1c1f;
                border: 1px solid #3f3f46;
                color: #a1a1aa;
                flex-shrink: 0;
            }
            .d-atc-ctrl-pill.atis { color: #c084fc; }
            .d-atc-ctrl-pill.gnd { color: #d4d4d8; }
            .d-atc-ctrl-pill.twr { color: #60a5fa; }
            .d-atc-ctrl-pill.app { color: #818cf8; }
            .d-atc-ctrl-pill.dep { color: #38bdf8; }
            .d-atc-ctrl-main { display: flex; flex-direction: column; min-width: 0; gap: 1px; }
            .d-atc-ctrl-user { font-size: 0.78rem; font-weight: 600; color: #e4e4e7; }
            .d-atc-ctrl-meta { font-size: 0.62rem; color: #71717a; font-family: var(--font-data); }
            .d-atc-empty {
                display: flex;
                flex-direction: column;
                align-items: center;
                text-align: center;
                gap: 8px;
                padding: 40px 24px;
                color: #71717a;
            }
            .d-atc-empty i { font-size: 1.6rem; opacity: 0.5; }
            .d-atc-empty p { margin: 0; color: #a1a1aa; font-weight: 700; }
            .d-atc-empty span { font-size: 0.72rem; line-height: 1.5; }
        `;
        document.head.appendChild(style);
    }
};

    async function initializeSectorOpsView() {
    // [FIX] 1. Load saved preferences FIRST
    // This updates the global 'currentMapStyle' before the map creates itself.
    loadFiltersFromLocalStorage(); 

    const mapContainer = document.getElementById('sector-ops-map-fullscreen');
    const viewContainer = document.getElementById('standalone-map-view');
    
    if (!viewContainer || !mapContainer) return;
    

    try {
        // --- 1b. Warm the live data in parallel with the map load ---
        // The map/style/sprite load below takes seconds; neither the first
        // ATC/NOTAM fetch nor the Socket.IO handshake needs the map, so kick
        // both off now. Flight packets that land before the layers exist just
        // fill currentMapFeatures, and startSectorOpsLiveLoop() paints that
        // cache the moment the layers are up — so planes and ATC appear with
        // the map instead of seconds after it.
        updateSectorOpsSecondaryData();
        initializeSectorOpsSocket();

        // --- 2. Initialize Map ---
        // Now that filters are loaded, this will use the correct currentMapStyle
        const selectedHub = "KJFK";
        await initializeSectorOpsMap(selectedHub);
        updatePro3DLayers();

        /*
        // --- 3. Inject Server Selector Pill ---
        if (!document.getElementById('server-selector-container')) {
            const selectorHtml = `
                <div id="server-selector-container">
                    <button class="server-btn ${currentServerName === 'Expert Server' ? 'active' : ''}" data-server="Expert Server">Expert</button>
                    <button class="server-btn ${currentServerName === 'Training Server' ? 'active' : ''}" data-server="Training Server">Training</button>
                    <button class="server-btn ${currentServerName === 'Casual Server' ? 'active' : ''}" data-server="Casual Server">Casual</button>
                </div>
            `;
            mapContainer.insertAdjacentHTML('beforeend', selectorHtml);
        }
        */

        // --- 5. Inject Airport Info Window ---
        if (!document.getElementById('airport-info-window')) {
                const windowHtml = `
                <div id="airport-info-window" class="info-window">
                    <div id="airport-window-content" class="info-window-content"></div>
                </div>
            `;
            mapContainer.insertAdjacentHTML('beforeend', windowHtml);
        }

        // --- 6. Inject Aircraft Info Window ---
        if (!document.getElementById('aircraft-info-window')) {
                const windowHtml = `
                <div id="aircraft-info-window" class="info-window">
                </div>
            `;
            mapContainer.insertAdjacentHTML('beforeend', windowHtml);
        }

        // --- 7. Inject Weather Settings Window ---
        if (!document.getElementById('weather-settings-window')) {
            const windowHtml = `
                <div id="weather-settings-window" class="info-window">
                    <div class="info-window-header">
                        <h3><i class="fa-solid fa-cloud-sun" style="margin-right: 10px;"></i> Weather Settings</h3>
                        <div class="info-window-actions">
                            <button class="weather-window-hide-btn" title="Hide"><i class="fa-solid fa-compress"></i></button>
                            <button class="weather-window-close-btn" title="Close"><i class="fa-solid fa-xmark"></i></button>
                        </div>
                    </div>
        
                    <div id="weather-window-content" class="info-window-content">
                        <ul class="weather-toggle-list">
                            <li class="weather-toggle-item">
                                <span class="weather-toggle-label"><i class="fa-solid fa-cloud-rain"></i> Radar (Precip)</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="weather-toggle-precip">
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                            <li class="weather-toggle-item">
                                <span class="weather-toggle-label"><i class="fa-solid fa-triangle-exclamation"></i> SIGMETs</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="weather-toggle-sigmets">
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                            <li class="weather-toggle-item">
                                <span class="weather-toggle-label"><i class="fa-solid fa-cloud"></i> Cloud Cover</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="weather-toggle-clouds">
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                            <li class="weather-toggle-item">
                                <span class="weather-toggle-label"><i class="fa-solid fa-wind"></i> Wind Speed</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="weather-toggle-wind">
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                        </ul>
                        <div class="weather-disclaimer-note">
                            <i class="fa-solid fa-server"></i>
                            <strong>Note:</strong> ONLY rain radar is provided.
                            Other radars (sigmets, clouds, wind) are not available.
                        </div>
                    </div>
                </div>
            `;
            mapContainer.insertAdjacentHTML('beforeend', windowHtml);
        }

        // --- 8. Inject Settings Window ---
        if (!document.getElementById('filter-settings-window')) {
            const windowHtml = `
                <div id="filter-settings-window" class="info-window">
                    <div class="info-window-header">
                        <h3><i class="fa-solid fa-gear" style="margin-right: 10px;"></i> Settings</h3>
                        <div class="info-window-actions">
                            <button class="filter-window-hide-btn" title="Hide"><i class="fa-solid fa-compress"></i></button>
                            <button class="filter-window-close-btn" title="Close"><i class="fa-solid fa-xmark"></i></button>
                        </div>
                    </div>
          
                    <div id="filter-window-content" class="info-window-content">
                        <ul class="filter-toggle-list">
                            <li class="filter-toggle-item">
                                <span class="filter-toggle-label"><i class="fa-solid fa-tower-broadcast"></i> Hide Staffed Airports</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="filter-toggle-atc">
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                            <li class="filter-toggle-item">
                                <span class="filter-toggle-label"><i class="fa-solid fa-map-marked-alt"></i> Show Unstaffed Airports</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="filter-toggle-unstaffed" ${mapFilters.showUnstaffedAirports ? 'checked' : ''}>
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                            
                            <li class="filter-toggle-item">
                                <span class="filter-toggle-label"><i class="fa-solid fa-tags"></i> Show Aircraft Labels</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="filter-toggle-aircraft-labels">
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                        </ul>

                        <div class="filter-section-divider">
                            <span class="filter-section-title">Map Style</span>
                        </div>
                        <ul class="filter-toggle-list" style="padding-top: 8px;">
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-dark" name="map-style-mode" value="dark" checked>
                            <label for="map-style-dark"><i class="fa-solid fa-moon"></i> Dark (Default)</label>
                        </li>
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-light" name="map-style-mode" value="light">
                            <label for="map-style-light"><i class="fa-solid fa-sun"></i> Light</label>
                        </li>
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-satellite" name="map-style-mode" value="satellite">
                            <label for="map-style-satellite"><i class="fa-solid fa-satellite"></i> Satellite</label>
                        </li>
                        
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-outdoors" name="map-style-mode" value="outdoors">
                            <label for="map-style-outdoors" style="color: #38bdf8;"><i class="fa-solid fa-mountain-sun"></i> Outdoors (Pro)</label>
                        </li>
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-nav-dark" name="map-style-mode" value="nav-dark">
                            <label for="map-style-nav-dark" style="color: #38bdf8;"><i class="fa-solid fa-compass"></i> Nav Night (Pro)</label>
                        </li>
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-nav-light" name="map-style-mode" value="nav-light">
                            <label for="map-style-nav-light" style="color: #38bdf8;"><i class="fa-regular fa-compass"></i> Nav Day (Pro)</label>
                        </li>
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-traffic-night" name="map-style-mode" value="traffic-night">
                            <label for="map-style-traffic-night" style="color: #38bdf8;"><i class="fa-solid fa-car-tunnel"></i> Traffic Night (Pro)</label>
                        </li>
                        <li class="filter-radio-item">
                            <input type="radio" id="map-style-traffic-day" name="map-style-mode" value="traffic-day">
                            <label for="map-style-traffic-day" style="color: #38bdf8;"><i class="fa-solid fa-car"></i> Traffic Day (Pro)</label>
                        </li>

                        <li class="filter-toggle-item" style="margin-top: 10px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 10px;">
                            <span class="filter-toggle-label"><i class="fa-solid fa-map"></i> Flat Map Projection</span>
                            <label class="toggle-switch">
                                <input type="checkbox" id="filter-toggle-flat-map" ${mapFilters.useFlatMap ? 'checked' : ''}>
                                <span class="toggle-slider"></span>
                            </label>
                        </li>
                    </ul>

                        <div class="filter-section-divider">
                            <span class="filter-section-title">Interface Style</span>
                        </div>
                
                        <ul class="filter-toggle-list" style="padding-top: 8px;">
                            <li class="filter-toggle-item">
                                <span class="filter-toggle-label"><i class="fa-solid fa-tablet-screen-button"></i> Simple Flight Window</span>
                                <label class="toggle-switch">
                                    <input type="checkbox" id="filter-toggle-simple-window">
                                    <span class="toggle-slider"></span>
                                </label>
                            </li>
                        </ul>

                        <div class="filter-section-divider">
                            <span class="filter-section-title">Aircraft Icon Color</span>
                        </div>
  
                        <ul class="filter-toggle-list" id="icon-color-filter-group" style="padding-top: 8px;">
                            <li class="filter-radio-item">
                                <input type="radio" id="icon-color-default" name="icon-color-mode" value="default" checked>
                                <label for="icon-color-default"><i class="fa-solid fa-plane" style="color: #fff;"></i> Default (White)</label>
                            </li>
                     
                            <li class="filter-radio-item">
                                <input type="radio" id="icon-color-blue" name="icon-color-mode" value="blue">
                                <label for="icon-color-blue"><i class="fa-solid fa-plane" style="color: #00a8ff;"></i> Blue</label>
                            </li>
                            <li class="filter-radio-item">
                                <input type="radio" id="icon-color-orange" name="icon-color-mode" value="orange">
                                <label for="icon-color-orange"><i class="fa-solid fa-plane" style="color: #ff9900;"></i> Orange</label>
                            </li>
                        </ul>
                        
                        <div class="mobile-only-filter-section">
                            <div class="filter-section-divider">
                                <span class="filter-section-title">Mobile Display Mode</span>
                            </div>
                            <ul class="filter-toggle-list" id="mobile-mode-filter-group" style="padding-top: 8px;">
        
                                <li class="filter-radio-item">
                                    <input type="radio" id="mobile-mode-hud" name="mobile-display-mode" value="hud" checked>
                                    <label for="mobile-mode-hud"><i class="fa-solid fa-rocket"></i> HUD View</label>
                                </li>
                                <li class="filter-radio-item">
                                    <input type="radio" id="mobile-mode-legacy" name="mobile-display-mode" value="legacy">
                                    <label for="mobile-mode-legacy"><i class="fa-solid fa-layer-group"></i> Legacy Sheet</label>
                                </li>
                            </ul>
                        </div>

                       
                        <div class="filter-section-divider">
                            <span class="filter-section-title">Window Appearance</span>
                        </div>
                        <div class="filter-appearance-controls" style="padding: 10px; display: flex; flex-direction: column; gap: 10px;">
                            <div style="display: flex; justify-content: space-between; align-items: center;">
                                <span style="color: #ccc; font-size: 0.9rem;">Gradient Start Color</span>
                                <input type="color" id="theme-color-start" value="#121426" style="background: none; border: none; width: 50px; height: 30px; cursor: pointer;">
                            </div>
                            <div style="display: flex; justify-content: space-between; align-items: center;">
                                <span style="color: #ccc; font-size: 0.9rem;">Gradient End Color</span>
                                <input type="color" id="theme-color-end" value="#121426" style="background: none; border: none; width: 50px; height: 30px; cursor: pointer;">
                            </div>
                            <div style="display: flex; gap: 10px;">
                                 <button id="theme-reset-btn" class="cta-button" style="width: 100%; padding: 8px; font-size: 0.85rem; border-radius: 4px; background: rgba(255,255,255,0.1); border: 1px solid #444; color: #fff; cursor: pointer;">Reset Default Theme</button>
                            </div>
                        </div>
                    </div>
                </div>
            `;
            mapContainer.insertAdjacentHTML('beforeend', windowHtml);
        }

        // Inject the trip-card container. Contents are rendered/replaced by
        // toggleTripCardMode(true), so we just need the host element here.
if (!document.getElementById('trip-card-takeover')) {
    mapContainer.insertAdjacentHTML('beforeend', '<div id="trip-card-takeover"></div>');
}
        
        // --- 9. Inject Toolbar Buttons (if missing) ---
        const toolbarToggleBtn = document.getElementById('toolbar-toggle-panel-btn');

        if (toolbarToggleBtn) {
             if (!document.getElementById('airport-recall-btn')) {
                toolbarToggleBtn.parentElement.insertAdjacentHTML('beforeend', `
                    <button id="airport-recall-btn" class="toolbar-btn" title="Show Airport Info">
                        <i class="fa-solid fa-location-dot"></i>
                    </button>
                `);
             }
             if (!document.getElementById('aircraft-recall-btn')) {
                toolbarToggleBtn.parentElement.insertAdjacentHTML('beforeend', `
                    <button id="aircraft-recall-btn" class="toolbar-btn" title="Show Aircraft Info">
                        <i class="fa-solid fa-plane-up"></i>
                    </button>
                `);
             }
             if (!document.getElementById('live-3d-toggle-btn')) {
                toolbarToggleBtn.parentElement.insertAdjacentHTML('beforeend', `
                    <button id="live-3d-toggle-btn" class="toolbar-btn" title="3D Traffic View">
                        <i class="fa-solid fa-cube"></i>
                    </button>
                `);
             }
             if (!document.getElementById('open-weather-settings-btn')) {
                toolbarToggleBtn.parentElement.insertAdjacentHTML('beforeend', `
                    <button id="open-weather-settings-btn" class="toolbar-btn" title="Weather Settings">
                        <i class="fa-solid fa-cloud-sun"></i>
                    </button>
                `);
             }
             if (!document.getElementById('open-filter-settings-btn')) {
                toolbarToggleBtn.parentElement.insertAdjacentHTML('beforeend', `
                    <button id="open-filter-settings-btn" class="toolbar-btn" title="Settings">
                        <i class="fa-solid fa-gear"></i>
                     </button>
                `);
             }
        }
        
        // --- 10. Assign Global Variables ---
        airportInfoWindow = document.getElementById('airport-info-window');
        airportInfoWindowRecallBtn = document.getElementById('airport-recall-btn');
        aircraftInfoWindow = document.getElementById('aircraft-info-window');
        aircraftInfoWindowRecallBtn = document.getElementById('aircraft-recall-btn');
        weatherSettingsWindow = document.getElementById('weather-settings-window');
        filterSettingsWindow = document.getElementById('filter-settings-window');

        LandingUI.init();
        
        // 3. Set Initial Visibility
        LandingUI.update(true, {
            server: currentServerName,
            flights: Object.keys(currentMapFeatures).length,
            atc: activeAtcFacilities.length
        });

        const natTracks = new NatTracksLayer(sectorOpsMap);
        natTracks.setOptions({
    showTracks: mapFilters.showNatTracks,
    showLabels: mapFilters.showNatLabels
});

natTracks.fetchTracks();
window.globalNatTracks = natTracks;
        
        // (Optional) Store it globally if you need to reference it later
        window.globalNatTracks = natTracks;

        // --- 11. Load Content and Setup Listeners ---
        await loadExternalPanelContent();
        setupSectorOpsEventListeners();
        setupAirportWindowEvents();
        setupAircraftWindowEvents();
        setupWeatherSettingsWindowEvents();
        setupFilterSettingsWindowEvents();
        AtcBoardUI.init();
        initPlaneSizeSlider(sectorOpsMap, mapFilters);
        
        // --- 12. Setup Search Listeners (Now that elements exist) ---
        setupSearchEventListeners();

        // --- 13. Initialize Smart Map Click ---
        setupSmartMapBackgroundClick();

        // --- 14. Listen for iframe messages (ND_READY, simple-window stats/actions/resize) ---
        window.addEventListener('message', (event) => {
            if (event.data && event.data.type === 'ND_READY') {
                refreshNavDisplayFromCache();
            }
            // Route simple-flight-window iframe messages (pilot stats request, etc.)
            if (event.data && (
                event.data.type === 'REQUEST_PILOT_STATS' ||
                event.data.type === 'SIMPLE_WINDOW_STATE' ||
                event.data.type === 'SIMPLE_WINDOW_ACTION' ||
                event.data.type === 'SIMPLE_WINDOW_PEEK_HEIGHT' ||
                event.data.type === 'SIMPLE_WINDOW_EDIT_MODE' ||
                event.data.type === 'NAVIGATE_TO_AIRPORT'
            )) {
                handleIframeMessage(event);
            }
        });

        // --- 15. Start Live Loop ---
        startSectorOpsLiveLoop();
    } catch (error) {
        console.error("Error initializing Sector Ops view:", error);
        showNotification(error.message, 'error');
        const panelContentWrapper = document.querySelector('#sector-ops-floating-panel .panel-content-wrapper');
        if (panelContentWrapper) {
            panelContentWrapper.innerHTML = `<p class="error-text" style="padding: 20px;">${error.message}</p>`;
        }
    } finally {
        console.log(`Loading complete in ${Date.now() - window.loadingStartTime}ms.`);
    }
}

async function setupMapLayersAndFog() {
    if (!sectorOpsMap) return;

    sectorOpsMap.setFog({
        'color': 'rgb(186, 210, 235)',
        'high-color': 'rgb(36, 92, 223)',
        'horizon-blend': 0.02,
        'space-color': 'rgb(27, 27, 54)',
        'star-intensity': 0.3
    });

    // Load the sprite sheet once
    try {
        await loadSpriteSheetAndGenerateIcons(sectorOpsMap);
    } catch (err) {
        console.error("Sprite sheet failed to load:", err);
    }

    // Initialize boundaries
    await initializeMapBoundaries(sectorOpsMap);

    // Initialize the aircraft layers now that icons are ready
    initializeAircraftLayer();

    // Restore Terrain Awareness mode (survives cold start and style swaps).
    refreshTerrainMode();
}

/**
 * [UPDATED] Initializes the Sector Ops map with high-performance configurations.
 */
function initializeSectorOpsMap(centerICAO) {
    if (!MAPBOX_ACCESS_TOKEN) {
        document.getElementById('sector-ops-map-fullscreen').innerHTML = '<p class="map-error-msg">Map service not available.</p>';
        return;
    }

    if (sectorOpsMap) {
        sectorOpsMap.remove();
        sectorOpsMap = null;
    }

    const centerCoords = airportsData[centerICAO] ? [airportsData[centerICAO].lon, airportsData[centerICAO].lat] : [77.2, 28.6];

    // --- ENHANCED PERFORMANCE CONFIGURATION ---
    sectorOpsMap = new mapboxgl.Map({
        container: 'sector-ops-map-fullscreen',
        style: currentMapStyle,
        center: centerCoords,
        zoom: 1.3,
        minZoom: 0,
        interactive: true,
        projection: mapFilters.useFlatMap ? 'mercator' : 'globe',
        // --- SMOOTH ZOOM/RENDER CONFIG ---
        // fadeDuration intentionally omitted — Mapbox's default 300 ms crossfade
        // is what makes tiles dissolve in/out instead of popping. The previous
        // `fadeDuration: 0` was the root cause of the "inorganic load-in/load-out"
        // feel during zoom.
        maxTileCacheSize: 2000,    // Keep more tiles cached so zooming back in is instant
        prefetchZoomDelta: 4,      // Stretch cached low-res tiles to hide the empty grid while high-res loads
        crossSourceCollisions: false,
        trackResize: true,
        performanceMetrics: false,
        localIdeographFontFamily: "'Inter', 'sans-serif'",
        preserveDrawingBuffer: false
        // [PERF FIX] Removed `preserveDrawingBuffer: true` — it forces an
        // extra GPU framebuffer copy on every frame and degrades FPS noticeably.
        // Only re-enable temporarily if you need to capture a screenshot via
        // map.getCanvas().toDataURL().
    });

    // ── Map camera bookmark API ────────────────────────────────────────────
    // Lets overlays (e.g. the pilot profile sheet) temporarily fly the map to a
    // live flight while the user reads their stats, then snap the camera back to
    // exactly where the user left it once the overlay closes.
    window.InflightMapCamera = {
        _saved: null,
        save() {
            if (!sectorOpsMap) return;
            this._saved = {
                center: sectorOpsMap.getCenter(),
                zoom: sectorOpsMap.getZoom(),
                bearing: sectorOpsMap.getBearing(),
                pitch: sectorOpsMap.getPitch(),
            };
        },
        // Fly to a coordinate, offset upward so the aircraft sits in the visible
        // band of map above a bottom sheet (sheet covers the lower portion).
        preview(coords, { zoom = 8, bottomInsetPx = 0 } = {}) {
            if (!sectorOpsMap || !coords) return;
            try {
                sectorOpsMap.flyTo({
                    center: coords,
                    zoom,
                    pitch: 0,
                    bearing: 0,
                    offset: [0, bottomInsetPx ? -bottomInsetPx / 2 : 0],
                    speed: 1.1,
                    curve: 1.4,
                    essential: true,
                });
            } catch (_) {}
        },
        restore() {
            if (!sectorOpsMap || !this._saved) return;
            const s = this._saved;
            try {
                sectorOpsMap.flyTo({
                    center: s.center, zoom: s.zoom, bearing: s.bearing, pitch: s.pitch,
                    speed: 1.2, curve: 1.4, essential: true,
                });
            } catch (_) {}
            this._saved = null;
        },
    };

    sectorOpsMap.on('style.load', async () => {
    console.log("Map style reloading. Rebuilding layers...");

    await setupMapLayersAndFog();

    // --- NEW: Apply Pro Layer Filters on Style Load ---
    if (typeof updateBaseMapLayerVisibility === 'function') {
        // Small timeout ensures Mapbox has fully parsed the style layers
        setTimeout(updateBaseMapLayerVisibility, 500);
    }

    if (typeof rebuildDynamicLayers !== 'undefined') rebuildDynamicLayers();
});

    return new Promise(resolve => {
        sectorOpsMap.on('load', async () => {
            GroupFlightManager.init(sectorOpsMap);
            setupResetNorthButton();
            await setupMapLayersAndFog();
            // [PERF FIX] Removed two redundant initializeMapBoundaries calls
            // here — setupMapLayersAndFog() already invokes it internally,
            // so previously the boundaries were being computed 3× on cold start.
            resolve();
        });
    });
}

// Call this function whenever you fetch new ATC data
function onAtcDataReceived(newAtcData) {
    // Import and use the function from atcHighlights.js
    updateActiveSectors(sectorOpsMap, 'fir-fills', newAtcData);
}

    /**
     * (REFACTORED) Clears only the route line layers from the map.
     */
    function clearRouteLayers() {
        sectorOpsMapRouteLayers.forEach(id => {
            if (sectorOpsMap.getLayer(id)) sectorOpsMap.removeLayer(id);
            if (sectorOpsMap.getSource(id)) sectorOpsMap.removeSource(id);
        });
        sectorOpsMapRouteLayers = [];
    }

    // NEW: Helper to clear the live flight trail from the map
    function clearLiveFlightPath(flightId) {
        if (!sectorOpsMap || !flightId) return;

        // Get all layers associated with this flight
        const layersObj = sectorOpsLiveFlightPathLayers[flightId];
        if (!layersObj) return;

        const ids = Object.values(layersObj);

        // --- PASS 1: Remove ALL Layers first ---
        ids.forEach(layerId => {
            if (layerId && sectorOpsMap.getLayer(layerId)) {
                sectorOpsMap.removeLayer(layerId);
            }
        });

        // --- PASS 2: Remove Sources ---
        // We do this only after all layers are gone to prevent "Source in use" errors.
        ids.forEach(sourceId => {
            if (sourceId && sectorOpsMap.getSource(sourceId)) {
                sectorOpsMap.removeSource(sourceId);
            }
        });
        
        delete sectorOpsLiveFlightPathLayers[flightId];
    }

    
/**
     * --- [UPDATED] Rebuilds all dynamic layers after a map style change.
     * Ensures Volanta-style Radar, SIGMETs, and NAT Tracks are restored correctly.
     */
    function rebuildDynamicLayers() {
        console.log("Rebuilding dynamic layers...");

        // 1. Re-apply FIR Boundaries (Boundaries usually wipe on style change)
        if (typeof initializeMapBoundaries === 'function') {
            initializeMapBoundaries(sectorOpsMap);
        }

        // 2. Re-apply NAT Tracks
        if (window.globalNatTracks) {
            // Re-initialize the source and layers for the new style
            window.globalNatTracks.initSource();
            
            // Sync visibility and labels with current mapFilters state
            window.globalNatTracks.setOptions({
                showTracks: mapFilters.showNatTracks,
                showLabels: mapFilters.showNatLabels
            });

            // Trigger the render to add them to the map
            window.globalNatTracks.render();
            console.log("NAT Tracks restored.");
        }

        // 3. Re-apply SIGMETS (Volanta Style)
        if (document.getElementById('weather-toggle-sigmets')?.checked) {
            isSigmetLayerAdded = false; // Force re-fetch/re-add
            toggleSigmetLayer(true);
        }

        // 4. Re-apply Radar (Precip - RainViewer)
        if (document.getElementById('weather-toggle-precip')?.checked) {
            isWeatherLayerAdded = false; 
            toggleWeatherLayer(true);
        }

        // 5. Re-apply Clouds
        if (document.getElementById('weather-toggle-clouds')?.checked) {
            isCloudLayerAdded = false; // Force re-creation
            toggleCloudLayer(true);
        }

        // 6. Re-apply Wind
        if (document.getElementById('weather-toggle-wind')?.checked) {
            isWindLayerAdded = false; // Force re-creation
            toggleWindLayer(true);
        }

        // 7. Re-apply airport routes
        if (currentAirportInWindow) {
            plotRoutesFromAirport(currentAirportInWindow);
        }

        // 8. Re-apply active flight trail
        if (currentFlightInWindow) {
            const flightId = currentFlightInWindow;
            
            clearLiveFlightPath(flightId); 
            delete sectorOpsLiveFlightPathLayers[flightId]; 

            const { flightProps, plan } = cachedFlightDataForStatsView;
            // Inside rebuildDynamicLayers() -> section 8 (active flight trail)
if (flightProps) {
    const localTrail = liveTrailCache.get(flightId) || [];
    const currentPosition = currentAircraftPositionForGeocode || flightProps.position;
    const routeFeature = generateAltitudeColoredRoute(localTrail, currentPosition, plan);

    sectorOpsMap.addSource(`flown-path-${flightId}`, { 
        type: 'geojson', 
        data: routeFeature,
        lineMetrics: true, // CRITICAL for gradients
        tolerance: 0       // Don't simplify segments away at low zoom
    });

    sectorOpsMap.addLayer({
                id: `flown-path-${flightId}`,
                type: 'line',
                source: `flown-path-${flightId}`,
                layout: {
                    'line-join': 'round',
                    'line-cap': 'round'
                },
                paint: {
                    'line-width': 4,
                    'line-opacity': 1,
                    'line-color': [
                        'interpolate',
                        ['linear'],
                        ['get', 'altitude'],
                        0, '#94a3b8',       // Ground / Taxi / Parked (Grey)
                        3000, '#c084fc',    // Approach / Initial Climb (Purple)
                        12000, '#f59e0b',   // Lower Descent / Climb (Orange)
                        20000, '#10b981',   // Climb / High Descent (Green)
                        30000, '#38bdf8',   // Cruise (Blue)
                        45000, '#0284c7'    // High Cruise (Darker Blue)
                    ]
                }
            }, 'sector-ops-live-flights-layer');

    sectorOpsLiveFlightPathLayers[flightId] = { flown: `flown-path-${flightId}` };
}
        }
        
        // 9. Re-apply aircraft filters
        updateAircraftLayerFilter();

        // 10. Re-render airport markers
        renderAirportMarkers();
    }

function updateFlightPlanLayer(flightId, plan, currentPosition) {
    if (!sectorOpsMap || !plan || !plan.flightPlanItems || plan.flightPlanItems.length < 2) {
        return; // Not enough data
    }

    const layerIdDirect = `plan-path-direct-${flightId}`;
    const layerIdDirectGlow = `plan-path-direct-glow-${flightId}`;
    const layerIdFull = `plan-path-full-${flightId}`;
    const layerIdFullGlow = `plan-path-full-glow-${flightId}`;
    const layerIdFullDots = `plan-path-full-dots-${flightId}`;
    const layerIdFullLabels = layerIdFull + '-labels';

    if (!sectorOpsLiveFlightPathLayers[flightId]) {
        sectorOpsLiveFlightPathLayers[flightId] = {};
    }

    // Register all layers
    sectorOpsLiveFlightPathLayers[flightId].planDirect = layerIdDirect;
    sectorOpsLiveFlightPathLayers[flightId].planDirectGlow = layerIdDirectGlow;
    sectorOpsLiveFlightPathLayers[flightId].planFull = layerIdFull;
    sectorOpsLiveFlightPathLayers[flightId].planFullGlow = layerIdFullGlow;
    sectorOpsLiveFlightPathLayers[flightId].planFullDots = layerIdFullDots;
    sectorOpsLiveFlightPathLayers[flightId].planFullLabels = layerIdFullLabels;

    // --- Get coords ---
    const allWaypointsForLine = flattenWaypointsFromPlan(plan.flightPlanItems);
    if (allWaypointsForLine.length < 2) return;

    const currentCoords = [currentPosition.lon, currentPosition.lat];
    const destinationCoords = unwrapLineCoordinates([currentCoords, allWaypointsForLine[allWaypointsForLine.length - 1]])[1];

    // --- 1. Handle "Direct to Destination" Line ---
    if (mapFilters.planDisplayMode === 'direct') {
        const directPath = densifyRoute([currentCoords, destinationCoords], 100);

        const directLineData = {
            type: 'Feature',
            geometry: { type: 'LineString', coordinates: directPath }
        };

        const source = sectorOpsMap.getSource(layerIdDirect);
        if (source) {
            source.setData(directLineData);
        } else {
            sectorOpsMap.addSource(layerIdDirect, { type: 'geojson', data: directLineData });

            sectorOpsMap.addLayer({
                id: layerIdDirectGlow,
                type: 'line',
                source: layerIdDirect,
                paint: {
                    'line-color': '#06b6d4',
                    'line-width': 6,
                    'line-opacity': 0.25,
                    'line-blur': 4
                }
            }, 'sector-ops-live-flights-layer');

            sectorOpsMap.addLayer({
                id: layerIdDirect,
                type: 'line',
                source: layerIdDirect,
                paint: {
                    'line-color': '#67e8f9',
                    'line-width': 2,
                    'line-opacity': 0.9,
                    'line-dasharray': [3, 4]
                }
            }, 'sector-ops-live-flights-layer');
        }
    } else {
        if (sectorOpsMap.getLayer(layerIdDirectGlow)) sectorOpsMap.removeLayer(layerIdDirectGlow);
        if (sectorOpsMap.getLayer(layerIdDirect)) sectorOpsMap.removeLayer(layerIdDirect);
        if (sectorOpsMap.getSource(layerIdDirect)) sectorOpsMap.removeSource(layerIdDirect);
    }

    // --- 2. Handle "Full Filed Plan" Line ---
    if (mapFilters.planDisplayMode === 'full') {
        const source = sectorOpsMap.getSource(layerIdFull);
        if (!source) {
            let rawWaypoints = flattenWaypointsFromPlan(plan.flightPlanItems);
            let unwrappedWaypoints = unwrapLineCoordinates(rawWaypoints);
            const densifiedWaypoints = densifyRoute(unwrappedWaypoints, 100);
            const waypointObjects = getFlatWaypointObjects(plan.flightPlanItems);

            // --- SMART LOGIC: Determine passed waypoints ---
            let activeWpIndex = 0;
            let minDist = Infinity;

            // Find the closest waypoint to mark as the "active" one
            waypointObjects.forEach((wp, idx) => {
                if (!wp.location) return;
                if (typeof getDistanceKm === 'function') {
                    const d = getDistanceKm(currentPosition.lat, currentPosition.lon, wp.location.latitude, wp.location.longitude);
                    if (d < minDist) {
                        minDist = d;
                        activeWpIndex = idx;
                    }
                }
            });

            const features = [];

            // Feature 1: The Core Flight Plan Curve
            features.push({
                type: 'Feature',
                geometry: { type: 'LineString', coordinates: densifiedWaypoints }
            });

            // Feature 2: Points for Labels & Tactical Nav Dots
            waypointObjects.forEach((wp, idx) => {
                if (wp.location && wp.location.longitude != null && wp.location.latitude != null) {
                    const isPassed = idx < activeWpIndex; // If the index is before the closest active point, it's passed

                    features.push({
                        type: 'Feature',
                        geometry: {
                            type: 'Point',
                            coordinates: [wp.location.longitude, wp.location.latitude]
                        },
                        properties: {
                            name: (wp.identifier || wp.name || '').toUpperCase(),
                            isPassed: isPassed
                        }
                    });
                }
            });

            const fullLineData = { type: 'FeatureCollection', features: features };
            sectorOpsMap.addSource(layerIdFull, { type: 'geojson', data: fullLineData });

            // 1. Direct-Style Glow Layer
            sectorOpsMap.addLayer({
                id: layerIdFullGlow,
                type: 'line',
                source: layerIdFull,
                'filter': ['==', '$type', 'LineString'],
                paint: {
                    'line-color': '#06b6d4',
                    'line-width': 6,
                    'line-opacity': 0.25,
                    'line-blur': 4
                }
            }, 'sector-ops-live-flights-layer');

            // 2. Direct-Style Core Path (Premium Dashed)
            sectorOpsMap.addLayer({
                id: layerIdFull,
                type: 'line',
                source: layerIdFull,
                tolerance: 0,
                buffer: 0,
                'filter': ['==', '$type', 'LineString'],
                paint: {
                    'line-color': '#67e8f9',
                    'line-width': 2,
                    'line-opacity': 0.9,
                    'line-dasharray': [3, 4]
                }
            }, 'sector-ops-live-flights-layer');

            // 3. Dynamic Waypoint Dots (Refined, Miniaturized Size)
            sectorOpsMap.addLayer({
                id: layerIdFullDots,
                type: 'circle',
                source: layerIdFull,
                'filter': ['==', '$type', 'Point'],
                paint: {
                    'circle-radius': 1.5,
                    'circle-color': [
                        'case',
                        ['==', ['get', 'isPassed'], true],
                        '#eab308', // Solid yellow if passed
                        '#1e1b4b'  // Hollow indigo center if upcoming
                    ],
                    'circle-stroke-width': 1,
                    'circle-stroke-color': [
                        'case',
                        ['==', ['get', 'isPassed'], true],
                        '#ca8a04', // Darker yellow border if passed
                        '#67e8f9'  // Cyan rim if upcoming (color-matched to new path)
                    ]
                }
            }, 'sector-ops-live-flights-layer');

            // 4. Advanced High-Contrast Typography Layer (Hidden if passed, smaller font)
            sectorOpsMap.addLayer({
                id: layerIdFullLabels,
                type: 'symbol',
                source: layerIdFull,
                // Only show text if the waypoint is NOT passed
                'filter': ['all', ['==', '$type', 'Point'], ['==', ['get', 'isPassed'], false]],
                layout: {
                    'text-field': ['get', 'name'],
                    'text-font': ['Mapbox Txt Regular', 'Arial Unicode MS Regular'],
                    'text-size': 9, // Reduced size for cleaner zooming
                    'text-offset': [0.6, -0.6],
                    'text-anchor': 'bottom-left',
                    'text-allow-overlap': false,
                    'text-ignore-placement': false,
                    'text-letter-spacing': 0.1
                },
                paint: {
                    'text-color': '#fdf4ff',
                    'text-halo-color': 'rgba(15, 23, 42, 0.9)',
                    'text-halo-width': 2,
                    'text-halo-blur': 1
                }
            }, 'sector-ops-live-flights-layer');
        }
    } else {
        if (sectorOpsMap.getLayer(layerIdFullLabels)) sectorOpsMap.removeLayer(layerIdFullLabels);
        if (sectorOpsMap.getLayer(layerIdFullDots)) sectorOpsMap.removeLayer(layerIdFullDots);
        if (sectorOpsMap.getLayer(layerIdFull)) sectorOpsMap.removeLayer(layerIdFull);
        if (sectorOpsMap.getLayer(layerIdFullGlow)) sectorOpsMap.removeLayer(layerIdFullGlow);
        if (sectorOpsMap.getSource(layerIdFull)) sectorOpsMap.removeSource(layerIdFull);
    }
}

    /**
 * Handles clicks on airport markers/tags. 
 * High priority: This will always close the aircraft window if it is open.
 */
async function handleAirportClick(icao, event = null, recenter = false) {
    if (!icao) return;

    // The window element is cached during init. If a tap somehow lands before
    // that (or the node was torn down), re-resolve it — and bail gracefully
    // rather than dereferencing null below, which on the iOS web view surfaces
    // as a hard crash instead of a recoverable miss.
    if (!airportInfoWindow) airportInfoWindow = document.getElementById('airport-info-window');
    if (!airportInfoWindow) {
        console.warn('[handleAirportClick] airport window not ready');
        if (typeof showNotification === 'function') showNotification('Airport info is still loading — try again in a moment.', 'error');
        return;
    }

    // Claim this as the newest open request. Any in-flight request for a
    // previously tapped airport will see a higher seq and abort its DOM write.
    const requestId = ++airportWindowRequestSeq;

    LandingUI.update(false);
    localStorage.setItem('landingUI_visible', 'false');

    // --- MUTUAL EXCLUSION ---
    // If the aircraft window is open, close it immediately
    if (currentFlightInWindow) {
        closeAircraftWindow();
    }

    // 1. Cleanup existing airport state if switching to a different airport
    if (currentAirportInWindow && currentAirportInWindow !== icao) {
        airportInfoWindow.classList.remove('visible');
        if (typeof airportInfoWindowRecallBtn !== 'undefined' && airportInfoWindowRecallBtn) {
            airportInfoWindowRecallBtn.classList.remove('visible');
        }
        if (typeof clearRouteLayers === 'function') clearRouteLayers();
        if (typeof AirportLayoutManager !== 'undefined' && sectorOpsMap) {
            AirportLayoutManager.clearAll(sectorOpsMap);
        }
    }

    // 2. Initialize Map Visuals for the Airport. These touch map layers /
    // external managers that can throw on a half-loaded style or WebGL hiccup —
    // none of them is essential to showing the info window, so isolate failures.
    try {
        if (typeof plotRoutesFromAirport === 'function') plotRoutesFromAirport(icao);
    } catch (e) { console.warn('[handleAirportClick] plotRoutesFromAirport failed:', e); }

    const airport = airportsData ? airportsData[icao] : null;
    if (airport && typeof AirportLayoutManager !== 'undefined' && sectorOpsMap) {
        try {
            AirportLayoutManager.plotTaxiways(sectorOpsMap, icao, airport.lat, airport.lon);
        } catch (e) { console.warn('[handleAirportClick] plotTaxiways failed:', e); }
    }

    // Travel to the airport when navigated here from a link (e.g. a clickable
    // ICAO in a flight window). Marker clicks pass recenter=false since the
    // airport is already where the user tapped.
    if (recenter && airport && sectorOpsMap
        && typeof airport.lat === 'number' && typeof airport.lon === 'number') {
        try {
            sectorOpsMap.flyTo({
                center: [airport.lon, airport.lat],
                zoom: Math.max(sectorOpsMap.getZoom(), 11),
                duration: 1200,
                essential: true
            });
        } catch (_) {}
    }

    // 3. Prepare UI Container — show a full-shape skeleton instead of a lone
    // spinner so the window (and the mobile peek sheet) opens looking like the
    // final layout while data loads.
    const contentEl = document.getElementById('airport-window-content');
    if (contentEl) {
        contentEl.classList.remove('apt-ready');
        contentEl.innerHTML = createAirportSkeletonHTML(icao);
    }

    // 4. Show Window
    if (window.MobileUIHandler && window.MobileUIHandler.isMobile()) {
        window.MobileUIHandler.openWindow(airportInfoWindow);
    } else {
        airportInfoWindow.classList.add('visible');
    }

    if (typeof airportInfoWindowRecallBtn !== 'undefined' && airportInfoWindowRecallBtn) {
        airportInfoWindowRecallBtn.classList.remove('visible');
    }
    
    currentAirportInWindow = icao;

    // 5. Fetch and Render Data
    try {
        const windowContentHTML = await createAirportInfoWindowHTML(icao, requestId);

        // If the user tapped another airport while we were fetching, a newer
        // request now owns the window. Bail out silently rather than overwrite
        // its content — or, worse, close the window it just opened.
        if (requestId !== airportWindowRequestSeq) return;

        if (windowContentHTML && contentEl) {
            contentEl.innerHTML = windowContentHTML;
            // Triggers the staggered fade-up of the new sections replacing
            // the skeleton (see #airport-window-content.apt-ready CSS).
            contentEl.classList.add('apt-ready');
            contentEl.scrollTop = 0;

            // Re-attach tab listeners for the new content
            const tabContainer = contentEl.querySelector('.apt-tabs-header');
            if (tabContainer) {
                tabContainer.addEventListener('click', (e) => {
                    const btn = e.target.closest('.apt-tab-btn');
                    if (!btn) return;
                    const allBtns = tabContainer.querySelectorAll('.apt-tab-btn');
                    allBtns.forEach(b => b.classList.remove('active'));
                    btn.classList.add('active');
                    const allContent = contentEl.querySelectorAll('.apt-tab-content');
                    allContent.forEach(content => content.classList.remove('active'));
                    const targetId = btn.dataset.target;
                    const targetContent = contentEl.querySelector(`#${targetId}`);
                    if (targetContent) targetContent.classList.add('active');
                });
            }
        } else if (!windowContentHTML) {
            closeAirportWindow();
        }
    } catch (err) {
        console.error("Failed to load airport info:", err);
        // Only tear the window down if this request still owns it; a stale
        // failure must not close the window a newer tap just opened.
        if (requestId === airportWindowRequestSeq) closeAirportWindow();
    }
}

/**
 * Recursively flattens the nested flightPlanItems from the SimBrief API plan
 * into a single, clean array of the full waypoint objects.
 */
function getFlatWaypointObjects(items) {
    const waypoints = [];
    if (!Array.isArray(items)) return waypoints;

    const extract = (planItems) => {
        for (const item of planItems) {
            if (Array.isArray(item.children) && item.children.length > 0) {
                extract(item.children);
            } else if (item.location && typeof item.location.longitude === 'number' && typeof item.location.latitude === 'number' && (item.location.latitude !== 0 || item.location.longitude !== 0)) {
                waypoints.push(item);
            }
        }
    };

    extract(items);
    return waypoints;
}

/**
 * Recursively flattens the nested flightPlanItems into a single array of [lon, lat].
 */
function flattenWaypointsFromPlan(items) {
    const waypoints = [];
    if (!Array.isArray(items)) return waypoints;

    const extract = (planItems) => {
        for (const item of planItems) {
            if (Array.isArray(item.children) && item.children.length > 0) {
                extract(item.children);
            } else if (item.location && typeof item.location.longitude === 'number' && typeof item.location.latitude === 'number' && (item.location.latitude !== 0 || item.location.longitude !== 0)) {
                waypoints.push([item.location.longitude, item.location.latitude]);
            }
        }
    };

    extract(items);
    return waypoints;
}
/**
 * --- REMADE: FLIGHT PATH GENERATION ENGINE ---
 * Re-coded from scratch to handle high-fidelity trails, 
 * altitude gradients, and globe-aware densification.
 */

/**
 * Normalizes coordinates to ensure a continuous line when crossing the Date Line.
 * Prevents the "snap back" effect across the world map.
 */
function unwrapLineCoordinates(coords) {
    if (!coords || coords.length < 2) return coords;

    const unwrapped = [coords[0]];
    let referenceLon = coords[0][0];

    for (let i = 1; i < coords.length; i++) {
        let currentLon = coords[i][0];
        const lat = coords[i][1];

        // Find the shortest path around the circle (360 degrees)
        let delta = currentLon - referenceLon;
        while (delta > 180) delta -= 360;
        while (delta < -180) delta += 360;

        const newLon = referenceLon + delta;
        unwrapped.push([newLon, lat]);
        referenceLon = newLon;
    }
    return unwrapped;
}

/**
 * Injects intermediate points along a great-circle path.
 * Required for Mapbox Globe to prevent lines from cutting through the Earth.
 */
function densifyRoute(coordinates, maxSegmentLengthKm = 100) {
    if (!coordinates || coordinates.length < 2) return coordinates;

    const densified = [coordinates[0]];

    for (let i = 0; i < coordinates.length - 1; i++) {
        const start = coordinates[i];
        const end = coordinates[i + 1];

        const dist = getDistanceKm(start[1], start[0], end[1], end[0]);

        if (dist > maxSegmentLengthKm) {
            const steps = Math.ceil(dist / maxSegmentLengthKm);
            for (let j = 1; j < steps; j++) {
                const fraction = j / steps;
                const intermediate = getIntermediatePoint(start[1], start[0], end[1], end[0], fraction);
                
                // Maintain the 'unwrapped' longitude continuity
                let lon = intermediate.lon;
                let prevLon = densified[densified.length - 1][0];
                let delta = lon - (prevLon % 360);
                while (delta > 180) delta -= 360;
                while (delta < -180) delta += 360;
                
                densified.push([prevLon + delta, intermediate.lat]);
            }
        }
        densified.push(end);
    }
    return densified;
}

/**
 * Smoothes a path using Catmull-Rom Splines with high-fidelity resolution.
 * Makes aircraft turns look "smooth as hell" by increasing interpolation steps.
 */
function generateSmoothPath(points, tension = 0.5) {
    if (points.length < 4) return points;
    const result = [];
    const interpolate = (p0, p1, p2, p3, t) => {
        const t2 = t * t;
        const t3 = t2 * t;
        // Standard Catmull-Rom Spline formula
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        );
    };

    for (let i = 0; i < points.length - 1; i++) {
        const p0 = points[i === 0 ? i : i - 1];
        const p1 = points[i];
        const p2 = points[i + 1];
        const p3 = points[i + 2 >= points.length ? i + 1 : i + 2];

        // --- Resolution: dense enough that consecutive segment angles are imperceptible (~3°) ---
        // For typical IF trail spacing (~0.01–0.05° between samples), the old formula
        // collapsed to floor(d*2) = 0, clamped to a paltry 2 steps — so smooth curves
        // were being sampled as 2-point chords. We now guarantee a minimum of 24 steps,
        // and scale up generously for long inter-sample gaps (e.g. early-flight cold trails).
        const d = Math.sqrt(Math.pow(p2.unwrappedLon - p1.unwrappedLon, 2) + Math.pow(p2.lat - p1.lat, 2));
        const steps = Math.max(24, Math.min(64, Math.ceil(d * 400))); 
        
        for (let t = 0; t < 1; t += 1 / steps) {
            result.push({
                unwrappedLon: interpolate(p0.unwrappedLon, p1.unwrappedLon, p2.unwrappedLon, p3.unwrappedLon, t),
                lat: interpolate(p0.lat, p1.lat, p2.lat, p3.lat, t),
                alt: p1.alt + (p2.alt - p1.alt) * t
            });
        }
    }
    result.push(points[points.length - 1]);
    return result;
}

function generateAltitudeColoredRoute(trailPoints, currentPosition, plan) {
    const features = [];
    const allPoints = [...(trailPoints || [])];

    // Push the live current position to complete the line
    if (currentPosition) {
        allPoints.push({
            latitude: currentPosition.lat,
            longitude: currentPosition.lon,
            altitude: currentPosition.alt_ft || 0
        });
    }

    if (allPoints.length < 2) {
        return { type: 'FeatureCollection', features: [] };
    }

    // Unwrap longitudes to prevent the line from stretching across the globe at the anti-meridian.
    // We carry the unwrapped longitude on each point (as `unwrappedLon`) so generateSmoothPath
    // can interpolate without hopping the dateline.
    const unwrappedPoints = [];
    let prevLon = allPoints[0].longitude || allPoints[0].lon;

    unwrappedPoints.push({
        unwrappedLon: prevLon,
        lat: allPoints[0].latitude || allPoints[0].lat,
        alt: allPoints[0].altitude || allPoints[0].alt || 0
    });

    for (let i = 1; i < allPoints.length; i++) {
        let lon = allPoints[i].longitude || allPoints[i].lon;
        const lat = allPoints[i].latitude || allPoints[i].lat;
        const alt = allPoints[i].altitude || allPoints[i].alt || 0;

        while (lon - prevLon > 180) lon -= 360;
        while (prevLon - lon > 180) lon += 360;

        unwrappedPoints.push({ unwrappedLon: lon, lat, alt });
        prevLon = lon;
    }

    // --- Bend-it-like-Beckham: Catmull-Rom smoothing ---
    // Subdivides each segment into an interpolated curve passing through every sample point.
    // Altitude is linearly interpolated between samples, preserving the altitude→color relation.
    // generateSmoothPath needs >= 4 points; with fewer (very early in a flight), draw raw.
    const smoothedPoints = unwrappedPoints.length >= 4
        ? generateSmoothPath(unwrappedPoints, 0.5)
        : unwrappedPoints;

    // Create a distinct LineString feature for EVERY segment so each can be colored
    // by its own altitude property via the layer's interpolate expression.
    for (let i = 0; i < smoothedPoints.length - 1; i++) {
        const p1 = smoothedPoints[i];
        const p2 = smoothedPoints[i + 1];

        features.push({
            type: 'Feature',
            geometry: {
                type: 'LineString',
                coordinates: [
                    [p1.unwrappedLon, p1.lat],
                    [p2.unwrappedLon, p2.lat]
                ]
            },
            properties: {
                altitude: p1.alt
            }
        });
    }

    return { type: 'FeatureCollection', features: features };
}

/**
 * --- [NEW] Reusable function to close the aircraft window and clean up resources ---
 */
function closeAircraftWindow() {
    if (!aircraftInfoWindow) return;
    
    // Clear 3D paths if active
    if (typeof FlownPath3D !== 'undefined') {
        FlownPath3D.updatePath(sectorOpsMap, currentFlightInWindow, [], false);
    }

    aircraftInfoWindow.classList.remove('visible');
    if (window.MobileUIHandler) window.MobileUIHandler.closeActiveWindow();
    
    // Clear the map layers using the ID tracker
    clearLiveFlightPath(currentFlightInWindow);

    // Reset intervals
    if (activePfdUpdateInterval) clearInterval(activePfdUpdateInterval);
    if (activeGeocodeUpdateInterval) clearInterval(activeGeocodeUpdateInterval);
    if (activeWeatherUpdateInterval) clearInterval(activeWeatherUpdateInterval);

    // CRITICAL FIX: Reset state
    currentFlightInWindow = null; 
    currentAircraftPositionForGeocode = null;
    resetPfdState();

    // Trigger Landing UI only if airport window is also closed
    if (!currentAirportInWindow) {
        LandingUI.update(true, {
            server: currentServerName,
            flights: Object.keys(currentMapFeatures).length,
            atc: activeAtcFacilities.length
        });
    }
}

async function handleAircraftClick(flightProps, optionalSessionId = null, event = null) {
    if (!flightProps || !flightProps.flightId) return;

    LandingUI.update(false);
    localStorage.setItem('landingUI_visible', 'false');

    if (event && sectorOpsMap) {
        try {
            const layersToCheck = [];
            if (sectorOpsMap.getLayer('airport-symbols-layer')) layersToCheck.push('airport-symbols-layer');
            if (sectorOpsMap.getLayer('airport-label-layer')) layersToCheck.push('airport-label-layer');

            if (layersToCheck.length > 0) {
                const airportFeatures = sectorOpsMap.queryRenderedFeatures(event.point, { layers: layersToCheck });
                if (airportFeatures.length > 0) {
                    console.log("Airport detected at click point, prioritizing airport over aircraft.");
                    return;
                }
            }
        } catch (mapboxError) {
            console.warn("Bypassed Mapbox rendering error during airport check.", mapboxError.message);
        }
    }

    if (currentAirportInWindow) closeAirportWindow();

    if (typeof trackPilotView === 'function') trackPilotView(flightProps);

    if (isAircraftWindowLoading) return;

    if (currentFlightInWindow === flightProps.flightId && aircraftInfoWindow.classList.contains('visible')) return;

    isAircraftWindowLoading = true;

    if (activePfdUpdateInterval) {
        clearInterval(activePfdUpdateInterval);
        activePfdUpdateInterval = null;
    }
    if (activeGeocodeUpdateInterval) {
        clearInterval(activeGeocodeUpdateInterval);
        activeGeocodeUpdateInterval = null;
    }
    
    if (typeof resetPfdState === 'function') resetPfdState();

    if (currentFlightInWindow && currentFlightInWindow !== flightProps.flightId) {
        if (!window.pinnedFlights || !window.pinnedFlights.has(currentFlightInWindow)) {
            if (typeof clearLiveFlightPath === 'function') clearLiveFlightPath(currentFlightInWindow);
            if (typeof liveTrailCache !== 'undefined') liveTrailCache.delete(currentFlightInWindow);
        }
    }

    currentFlightInWindow = flightProps.flightId;
    currentAircraftPositionForGeocode = flightProps.position;

    if (window.MobileUIHandler && window.MobileUIHandler.isMobile()) {
        window.MobileUIHandler.openWindow(aircraftInfoWindow);
    } else {
        aircraftInfoWindow.classList.add('visible');
    }

    if (typeof aircraftInfoWindowRecallBtn !== 'undefined' && aircraftInfoWindowRecallBtn) {
        aircraftInfoWindowRecallBtn.classList.remove('visible');
    }

    const windowEl = document.getElementById('aircraft-info-window');
    if (windowEl) {
        windowEl.innerHTML = `
            <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 300px; color: #fff;">
                <div class="spinner-small" style="margin-bottom: 1rem;"></div>
                <p style="font-family: 'Inter', sans-serif; font-size: 0.9rem; color: #94a3b8;">Acquiring Flight Data...</p>
            </div>
        `;
    }

    try {
        let sessionId = optionalSessionId;
        if (!sessionId || sessionId === 'default') {
            sessionId = await getValidSessionId();
        }

        // Prefer the nested aircraft object, but fall back to the flat
        // aircraftName/liveryName fields the live feature also carries. Callers
        // that pass raw (unparsed) feature properties leave `aircraft` as a
        // JSON string, which would otherwise yield empty lookups and a missing
        // plane photo.
        const acName = flightProps.aircraft?.aircraftName || flightProps.aircraftName || '';
        const livName = flightProps.aircraft?.liveryName || flightProps.liveryName || '';

        const planUrl = `${LIVE_FLIGHTS_API_URL}/${sessionId || 'default'}/${flightProps.flightId}/plan`;
        const historyUrl = `${LIVE_FLIGHTS_API_URL.replace('/flights', '/api/flights')}/${flightProps.flightId}/history`;
        const aircraftLookupUrl = `${API_BASE_URL}/api/aircraft/lookup?type=${encodeURIComponent(acName)}&livery=${encodeURIComponent(livName)}`;

        const routePromise = fetch(historyUrl).catch(() => ({ ok: false }));

        const [planRes, aircraftLookupRes] = await Promise.all([
            fetch(planUrl).catch(() => ({ ok: false })),
            fetch(aircraftLookupUrl).catch(() => ({ ok: false }))
        ]);

        const planData = planRes.ok ? await planRes.json() : null;
        const plan = (planData && planData.ok) ? planData.plan : null;

        let communityAircraftData = aircraftLookupRes.ok ? await aircraftLookupRes.json() : null;

        let depIcao = flightProps.departureIcao;
        let arrIcao = flightProps.arrivalIcao;

        if (plan && plan.flightPlanItems && plan.flightPlanItems.length >= 2) {
            const extractWaypoints = (items) => {
                const wps = [];
                const extract = (pItems) => {
                    for (const item of pItems) {
                        if (item.children && item.children.length > 0) extract(item.children);
                        else if (item.location && typeof item.location.latitude === 'number') wps.push(item);
                    }
                };
                extract(items);
                return wps;
            };
            const flatWps = extractWaypoints(plan.flightPlanItems);
            if (flatWps.length >= 2) {
                if (!depIcao) depIcao = flatWps[0].identifier || flatWps[0].name;
                if (!arrIcao) arrIcao = flatWps[flatWps.length - 1].identifier || flatWps[flatWps.length - 1].name;
            }
        }

        const filedPlanData = await FlightDispatchService.getFiledPlan(
            flightProps.username,
            depIcao,
            arrIcao
        ).catch(e => null);

        cachedFlightDataForStatsView = { flightProps, plan };

        if (typeof mapFilters !== 'undefined' && mapFilters.useSimpleFlightWindow) {
            // Cache filed-plan data so the live-update path can compute SCHEDULED/ACTUAL times too.
            cachedFlightDataForStatsView = { flightProps, plan, filedPlanData };
            // Prime the peek height from the saved layout preset, then choose the
            // opening phase. Mobile starts in the compact (collapsed) peek bar that
            // expands on tap. Desktop has no bottom-sheet/peek concept, so it opens
            // straight into the full information window instead of the peek state.
            primeSimpleWindowPeekHeight();
            const onMobile = !!(window.MobileUIHandler && typeof window.MobileUIHandler.isMobile === 'function'
                && window.MobileUIHandler.isMobile());
            const initialPhase = onMobile ? 'collapsed' : 'expanded';
            applySimpleWindowPhase(initialPhase);
            windowEl.innerHTML = `<iframe id="simple-flight-window-frame" src="flightinfo.html" style="width:100%; flex-grow: 1; border:none;" scrolling="no"></iframe>`;
            const simpleData = formatDataForSimpleWindow(flightProps, plan, [], communityAircraftData, filedPlanData);
            const iframe = document.getElementById('simple-flight-window-frame');
            iframe.onload = () => {
                iframe.contentWindow.postMessage({ type: 'FLIGHT_DATA_UPDATE', payload: simpleData }, '*');
                // The iframe defaults to its collapsed body class; on desktop force it
                // into the expanded full-info layout to match the host phase above.
                if (initialPhase === 'expanded') {
                    iframe.contentWindow.postMessage({ type: 'SET_PHASE', phase: 'expanded' }, '*');
                }
            };
        } else if (typeof populateAircraftInfoWindow === 'function') {
            populateAircraftInfoWindow(flightProps, plan, [], communityAircraftData, filedPlanData);
        }

        if (typeof fetchAndDisplayGeocode === 'function') {
            fetchAndDisplayGeocode(flightProps.position.lat, flightProps.position.lon);
        }

        if (plan && typeof updateFlightPlanLayer === 'function') {
            updateFlightPlanLayer(flightProps.flightId, plan, flightProps.position);
        }

        const routeRes = await routePromise;
        const routeData = routeRes.ok ? await routeRes.json() : null;

        let sortedRoutePoints = [];
        const historyArray = routeData?.path || routeData?.route || [];
        if (routeData && routeData.ok && Array.isArray(historyArray)) {
            sortedRoutePoints = historyArray.sort((a, b) => new Date(a.date) - new Date(b.date));
        }

        if (typeof liveTrailCache !== 'undefined') liveTrailCache.set(flightProps.flightId, sortedRoutePoints);

        if (typeof FlownPath3D !== 'undefined') {
            FlownPath3D.updatePath(sectorOpsMap, flightProps.flightId, sortedRoutePoints, mapFilters.show3DPath);
        }

        if (currentFlightInWindow === flightProps.flightId) {
            // Recompute time info now that route history (sortedRoutePoints) has arrived,
            // so an initially-ESTIMATED time can upgrade to ACTUAL once GPS data is in.
            // SCHEDULED still wins when filedPlanData exists.
            let _distRemainingNM = 0;
            try {
                const wpObjs = (plan && plan.flightPlanItems && typeof getFlatWaypointObjects === 'function')
                    ? getFlatWaypointObjects(plan.flightPlanItems) : [];
                const lastWp = wpObjs[wpObjs.length - 1];
                if (lastWp && lastWp.location && flightProps.position) {
                    _distRemainingNM = getDistanceKm(
                        flightProps.position.lat, flightProps.position.lon,
                        lastWp.location.latitude, lastWp.location.longitude
                    ) / 1.852;
                }
            } catch (_) { /* fall through with 0 */ }

            const _depInfo = computeDepartureTimeInfo(flightProps, sortedRoutePoints, filedPlanData, depIcao);
            const _arrInfo = computeArrivalTimeInfo(flightProps, filedPlanData, _distRemainingNM);
            applyRouteTimeInfoToDom('atd', _depInfo);
            applyRouteTimeInfoToDom('eta', _arrInfo);

            if (filedPlanData) {
                injectFiledGateInfoUI(filedPlanData, flightProps, plan);
            } else if (depIcao && depIcao !== 'N/A' && typeof injectGateInfoUI === 'function') {
                injectGateInfoUI(depIcao, sortedRoutePoints);
            }

            // Now that the full /history breadcrumb trail has arrived, push it
            // into whichever window is open so the Speed & Altitude graph spans
            // the entire flight (departure → now) immediately, rather than only
            // the live samples captured since the window was opened. Live ticks
            // keep extending it from here.
            try {
                if (mapFilters.useSimpleFlightWindow) {
                    const simpleIframe = document.getElementById('simple-flight-window-frame');
                    if (simpleIframe && simpleIframe.contentWindow) {
                        const freshData = formatDataForSimpleWindow(flightProps, plan, sortedRoutePoints, communityAircraftData, filedPlanData);
                        simpleIframe.contentWindow.postMessage({ type: 'FLIGHT_DATA_UPDATE', payload: freshData }, '*');
                    }
                } else if (typeof updateAircraftInfoWindow === 'function') {
                    updateAircraftInfoWindow(flightProps, plan, sortedRoutePoints);
                }
            } catch (_) { /* non-fatal: live ticks will populate the graph */ }
        }

        const flownLayerId = `flown-path-${flightProps.flightId}`;

        // Sync the initial flown-path render to whatever the live marker is
        // actually showing on the map. Two failure modes used to produce a
        // path that visibly extended past the aircraft icon on first open:
        //   1. `flightProps.position` is the snapshot from click time, often
        //      a few hundred ms (sometimes seconds) stale by the time the
        //      history fetch resolves — using it would anchor the path to
        //      an older spot than the icon.
        //   2. The history endpoint can return GPS samples that are newer
        //      than the latest socket frame the marker has consumed;
        //      appending them stretches the line past the icon until the
        //      next socket tick catches the marker up.
        // Reading the live feature from currentMapFeatures + filtering
        // trail points to <= marker last_update fixes both.
        const liveFeature = (typeof currentMapFeatures !== 'undefined')
            ? currentMapFeatures[flightProps.flightId] : null;
        const liveLastUpdateMs = liveFeature?.properties?.last_update
            ? new Date(liveFeature.properties.last_update).getTime() : null;
        const livePosition = liveFeature?.geometry?.coordinates
            ? {
                lat: liveFeature.geometry.coordinates[1],
                lon: liveFeature.geometry.coordinates[0],
                alt_ft: liveFeature.properties?.altitude ?? flightProps.position?.alt_ft ?? 0
              }
            : flightProps.position;
        const trailUpToMarker = (liveLastUpdateMs != null)
            ? sortedRoutePoints.filter(p => !p.date || new Date(p.date).getTime() <= liveLastUpdateMs)
            : sortedRoutePoints;

        // Generate the segmented FeatureCollection using our new function
        const initialRouteData = generateAltitudeColoredRoute(trailUpToMarker, livePosition, plan);

        if (!sectorOpsMap.getSource(flownLayerId)) {
            sectorOpsMap.addSource(flownLayerId, {
                type: 'geojson',
                data: initialRouteData, // Feed it the FeatureCollection segments
                tolerance: 0            // Don't simplify segments away at low zoom
            });
            
            sectorOpsMap.addLayer({
                id: flownLayerId,
                type: 'line',
                source: flownLayerId,
                layout: {
                    'line-join': 'round',
                    'line-cap': 'round'
                },
                paint: {
                    'line-width': 3,
                    'line-opacity': 1,
                    'line-color': [
                        'interpolate',
                        ['linear'],
                        ['get', 'altitude'],
                        0, '#94a3b8',       
                        3000, '#c084fc',    
                        12000, '#f59e0b',   
                        20000, '#10b981',   
                        30000, '#38bdf8',   
                        45000, '#0284c7'    
                    ]
                }
            }, 'sector-ops-live-flights-layer');

            if (typeof sectorOpsLiveFlightPathLayers !== 'undefined') {
                if (!sectorOpsLiveFlightPathLayers[flightProps.flightId]) sectorOpsLiveFlightPathLayers[flightProps.flightId] = {};
                sectorOpsLiveFlightPathLayers[flightProps.flightId].flown = flownLayerId;
            }
        }

        isAircraftWindowLoading = false;

    } catch (error) {
        console.error("Error fetching aircraft details:", error);
        closeAircraftWindow();
    }
}

// Exposed so other modules (e.g. the first-run onboarding's live window demo)
// can open and tear down a real flight info window through the normal app path.
if (typeof window !== 'undefined') {
    window.handleAircraftClick = handleAircraftClick;
    window.closeAircraftWindow = closeAircraftWindow;
}

/**
 * Closes the airport information window and cleans up associated map layers/states.
 * This is called whenever an aircraft is selected or the airport window is closed manually.
 */
// In flight.js - Update this function to include the null reset
function closeAirportWindow() {
    if (!airportInfoWindow) return;

    airportInfoWindow.classList.remove('visible');
    if (window.MobileUIHandler) window.MobileUIHandler.closeActiveWindow();
    if (airportInfoWindowRecallBtn) airportInfoWindowRecallBtn.classList.remove('visible');

    isTrafficHighlightActive = false;
    applyTrafficHighlighting();
    clearRouteLayers();
    if (typeof AirportLayoutManager !== 'undefined' && sectorOpsMap) AirportLayoutManager.clearAll(sectorOpsMap);

    // CRITICAL FIX: Reset the state variable
    currentAirportInWindow = null; 

    // Now LandingUI can safely trigger
    if (!currentFlightInWindow) {
        const landingData = {
            server: currentServerName,
            flights: Object.keys(currentMapFeatures).length,
            atc: activeAtcFacilities.length
        };
        LandingUI.update(true, landingData);
    }
}

// In flight.js - Ensure the Aircraft close also checks for nulled states
function closeAircraftWindow() {
    if (!aircraftInfoWindow) return;
    
    // Clear 3D paths if active
    if (typeof FlownPath3D !== 'undefined') {
        FlownPath3D.updatePath(sectorOpsMap, currentFlightInWindow, [], false);
    }

    aircraftInfoWindow.classList.remove('visible');
    if (window.MobileUIHandler) window.MobileUIHandler.closeActiveWindow();
    
    // Clear the map layers using the ID tracker ONLY IF NOT PINNED
    if (!window.pinnedFlights || !window.pinnedFlights.has(currentFlightInWindow)) {
        clearLiveFlightPath(currentFlightInWindow);
    }

    // Reset intervals
    if (activePfdUpdateInterval) clearInterval(activePfdUpdateInterval);
    if (activeGeocodeUpdateInterval) clearInterval(activeGeocodeUpdateInterval);
    if (activeWeatherUpdateInterval) clearInterval(activeWeatherUpdateInterval);

    // CRITICAL FIX: Reset state
    currentFlightInWindow = null; 
    currentAircraftPositionForGeocode = null;
    resetPfdState();

    // Trigger Landing UI only if airport window is also closed
    if (!currentAirportInWindow) {
        LandingUI.update(true, {
            server: currentServerName,
            flights: Object.keys(currentMapFeatures).length,
            atc: activeAtcFacilities.length
        });
    }
}

// Make the aircraft-window hero swipeable when the airframe has more than one
// community photo. Rather than overlaying a second image layer (which would
// cover the callsign/route content and changed the photo's framing), this
// reuses the hero's own background-image — the exact same rendering the single
// -photo hero already uses — and just swaps the source on swipe or dot tap. The
// only things added on top are small dot indicators and a per-photo credit,
// placed in the empty lower strip so nothing existing is hidden.
function buildHeroPhotoCarousel(panel, photos, fallbackPath) {
    if (!panel) return;
    // Re-render replaces innerHTML, so any prior carousel is already gone; this
    // guard just avoids double-building within a single render pass.
    if (panel.dataset.heroCarousel === '1') return;
    if (!Array.isArray(photos) || photos.length < 2) return;
    panel.dataset.heroCarousel = '1';

    const dots = document.createElement('div');
    dots.style.cssText = 'position:absolute;bottom:48px;left:0;right:0;z-index:4;display:flex;justify-content:center;gap:6px;';
    const dotEls = photos.map((_, i) => {
        const d = document.createElement('span');
        d.style.cssText = 'width:7px;height:7px;border-radius:50%;cursor:pointer;transition:all .2s ease;box-shadow:0 1px 2px rgba(0,0,0,.6);';
        d.addEventListener('click', (e) => { e.stopPropagation(); show(i); });
        dots.appendChild(d);
        return d;
    });

    // Credit sits bottom-right at the flight-state badge's height, but it must
    // read as a faint photo watermark — not a solid UI badge that could be
    // mistaken for pilot info — so it's deliberately see-through with no border.
    const credit = document.createElement('div');
    credit.style.cssText = 'position:absolute;bottom:45px;right:24px;z-index:4;max-width:48%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:9px;font-weight:500;letter-spacing:0.3px;color:rgba(255,255,255,0.72);background:rgba(0,0,0,0.22);-webkit-backdrop-filter:blur(2px);backdrop-filter:blur(2px);padding:3px 9px;border-radius:20px;text-shadow:0 1px 2px rgba(0,0,0,0.6);pointer-events:none;';

    let index = 0;
    const show = (i) => {
        index = (i + photos.length) % photos.length;
        panel.style.backgroundImage = `url('${photos[index].src}'), url('${fallbackPath}')`;
        panel.dataset.currentPath = photos[index].src;
        dotEls.forEach((d, k) => { d.style.background = `rgba(255,255,255,${k === index ? '0.95' : '0.45'})`; });
        const n = photos[index].photographer;
        credit.textContent = (n && n !== 'IF Community') ? `© ${n}` : '';
        credit.style.display = credit.textContent ? '' : 'none';
    };

    panel.appendChild(dots);
    panel.appendChild(credit);

    // Horizontal swipe to page through photos. Pointer events cover both touch
    // (iOS) and mouse; taps on the hero buttons are ignored so they still work.
    let downX = null, downY = null, moved = false;
    panel.addEventListener('pointerdown', (e) => {
        if (e.target.closest('.hero-btn, .overview-actions')) return;
        downX = e.clientX; downY = e.clientY; moved = false;
    });
    panel.addEventListener('pointermove', (e) => {
        if (downX == null) return;
        if (Math.abs(e.clientX - downX) > 10 && Math.abs(e.clientX - downX) > Math.abs(e.clientY - downY)) moved = true;
    });
    panel.addEventListener('pointerup', (e) => {
        if (downX == null) return;
        const dx = e.clientX - downX;
        if (moved && Math.abs(dx) > 40) show(index + (dx < 0 ? 1 : -1));
        downX = downY = null; moved = false;
    });

    show(0);
}

function populateAircraftInfoWindow(baseProps, plan, sortedRoutePoints, communityAircraftData, filedPlanData = null) {
    // --- Safety Check: Ensure the container exists ---
    const windowEl = document.getElementById('aircraft-info-window');
    if (!windowEl) return;

    // Clickable origin/destination ICAOs — inject the hover affordance once.
    if (!document.getElementById('ac-icao-link-style')) {
        const s = document.createElement('style');
        s.id = 'ac-icao-link-style';
        s.textContent = `.ac-icao-link{cursor:pointer;border-radius:4px;transition:color .15s ease,text-shadow .15s ease;}`
            + `.ac-icao-link:hover{color:#38bdf8;text-shadow:0 0 12px rgba(56,189,248,0.5);}`;
        document.head.appendChild(s);
    }

    // --- Helper function to update all elements matching a selector ---
    const updateAll = (selector, value, isHTML = false) => {
        const elements = document.querySelectorAll(selector);
        elements.forEach(el => {
            if (isHTML) {
                el.innerHTML = value;
            } else {
                el.textContent = value;
            }
        });
    };

    // --- Get Original Data ---
    const originalFlatWaypoints = (plan && plan.flightPlanItems && typeof flattenWaypointsFromPlan === 'function') ? flattenWaypointsFromPlan(plan.flightPlanItems) : [];
    const originalFlatWaypointObjects = (plan && plan.flightPlanItems && typeof getFlatWaypointObjects === 'function') ? getFlatWaypointObjects(plan.flightPlanItems) : [];
    const hasPlan = originalFlatWaypoints.length >= 2;

    // --- State Persistence Logic ---
    const currentActiveTab = windowEl.querySelector('.ac-info-tab-btn.active')?.dataset.tab || 'ac-tab-flight-data';
    const currentViewTarget = windowEl.querySelector('.display-toggle-btn.active')?.dataset.target || 'nd-view';

    // --- Aircraft Info ---
    const aircraftName = baseProps.aircraft?.aircraftName || 'Unknown Type';
    const airlineName = baseProps.aircraft?.liveryName || 'Generic Livery';
    const liveryName = baseProps.aircraft?.liveryName || '';
    const reg = baseProps.aircraft?.registration || 'N/A';
    const flightPhase = baseProps.flightPhase || "CRUISE";

let totalDistanceNM = 0;
    let distanceToDestNM = 0;
    let progress = 0;
    let ete = '--:--';
    let eta = '--:--';

    if (hasPlan && originalFlatWaypoints.length >= 2) {
        let totalDistanceKm = 0;
        for (let i = 0; i < originalFlatWaypoints.length - 1; i++) {
            const [lon1, lat1] = originalFlatWaypoints[i];
            const [lon2, lat2] = originalFlatWaypoints[i + 1];
            totalDistanceKm += getDistanceKm(lat1, lon1, lat2, lon2);
        }
        totalDistanceNM = totalDistanceKm / 1.852;

        if (totalDistanceNM > 0) {
            const [destLon, destLat] = originalFlatWaypoints[originalFlatWaypoints.length - 1];
            const remainingDistanceKm = getDistanceKm(baseProps.position.lat, baseProps.position.lon, destLat, destLon);
            distanceToDestNM = remainingDistanceKm / 1.852;
            
            // Use direct distance from origin to destination to fix the sluggish scaling
            const [originLon, originLat] = originalFlatWaypoints[0];
            const totalDirectDistanceNM = getDistanceKm(originLat, originLon, destLat, destLon) / 1.852;
            const scaleDist = totalDirectDistanceNM > 0 ? totalDirectDistanceNM : totalDistanceNM;

            progress = Math.max(0, Math.min(100, (1 - (distanceToDestNM / scaleDist)) * 100));

            if (baseProps.position.gs_kt > 50) {
                const timeHours = distanceToDestNM / baseProps.position.gs_kt;
                const hours = Math.floor(timeHours);
                const minutes = Math.round((timeHours - hours) * 60);
                ete = `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;

                // Compute the actual clock time the user will arrive (UTC HH:MM)
                if (timeHours > 0 && timeHours < 48) {
                    const arrivalDate = new Date(Date.now() + (timeHours * 3600000));
                    eta = arrivalDate.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' });
                }
            }
        }
    }

    // --- Logo Logic ---
    const words = liveryName.trim().split(/\s+/);
    let logoName = words.length > 1 && /[^a-zA-Z0-9]/.test(words[1]) ? words[0] : (words[0] + (words[1] ? ' ' + words[1] : ''));
    const sanitizedLogoName = logoName.toLowerCase().replace(/[^a-z0-9\s]/g, '').replace(/\s+/g, '_');
    const logoPath = sanitizedLogoName ? `Images/airline_logos/${sanitizedLogoName}.png` : '';
    const logoHtml = logoPath ? `<img src="${logoPath}" alt="${liveryName}" class="ac-header-logo" onerror="this.style.display='none'">` : '';

    // --- Times ---
    const atdTimestamp = (sortedRoutePoints && sortedRoutePoints.length > 0) ? sortedRoutePoints[0].date : null;
    const atdTime = atdTimestamp ? formatTimeFromTimestamp(atdTimestamp) : '--:--';

    const departureIcao = hasPlan ? originalFlatWaypointObjects[0]?.identifier || originalFlatWaypointObjects[0]?.name : 'N/A';
    const arrivalIcao = hasPlan ? originalFlatWaypointObjects[originalFlatWaypointObjects.length - 1]?.identifier || originalFlatWaypointObjects[originalFlatWaypointObjects.length - 1]?.name : 'N/A';

    // Make the origin/destination ICAOs clickable so the user can jump straight
    // to that airport's window. Only codes we actually have airport data for
    // become links — fixes/waypoints and 'N/A' stay as plain text.
    const renderClickableIcao = (icao) => {
        const code = (icao == null) ? '' : String(icao).trim();
        const isAirport = code && typeof airportsData !== 'undefined' && airportsData[code];
        if (!isAirport) return code || 'N/A';
        return `<span class="ac-icao-link" data-icao="${code}" role="button" tabindex="0" title="View ${code} airport">${code}</span>`;
    };
    const departureIcaoHtml = renderClickableIcao(departureIcao);
    const arrivalIcaoHtml = renderClickableIcao(arrivalIcao);

    // --- Source-tagged time info (SCHEDULED / ACTUAL / ESTIMATED) ---
    // Falls back to a back-calculated estimate so we never render '--:--' when we have any data at all.
    const depTimeInfo = computeDepartureTimeInfo(baseProps, sortedRoutePoints, filedPlanData, departureIcao);
    const arrTimeInfo = computeArrivalTimeInfo(baseProps, filedPlanData, distanceToDestNM);

    // Cache filed-plan info on the window element so the live-update path (which doesn't receive
    // filedPlanData as an arg) can still produce SCHEDULED-tagged times.
    if (filedPlanData && filedPlanData.dep_time) {
        windowEl.dataset.filedDepTime = filedPlanData.dep_time;
    } else {
        delete windowEl.dataset.filedDepTime;
    }
    if (filedPlanData && filedPlanData.duration_minutes) {
        windowEl.dataset.filedDuration = String(filedPlanData.duration_minutes);
    } else {
        delete windowEl.dataset.filedDuration;
    }
    windowEl.dataset.depIcao = departureIcao || '';
    windowEl.dataset.arrIcao = arrivalIcao || '';

    // --- Derive a cruise altitude target from the highest waypoint altitude in the plan ---
    // Used by the redesigned VSD card to show CRZ TGT and ALT Δ readouts.
    let cruiseAltFt = null;
    try {
        const _wpAlts = (originalFlatWaypointObjects || [])
            .map(wp => (typeof wp.altitude === 'number' ? wp.altitude : null))
            .filter(a => a != null && a > 0);
        if (_wpAlts.length > 0) cruiseAltFt = Math.max(..._wpAlts);
    } catch (_) { /* leave as null */ }
    const cruiseAltText = cruiseAltFt
        ? (cruiseAltFt >= 18000 ? `FL${Math.round(cruiseAltFt / 100)}` : `${Math.round(cruiseAltFt).toLocaleString()} ft`)
        : '---';
    if (cruiseAltFt) {
        windowEl.dataset.cruiseAltFt = String(cruiseAltFt);
    } else {
        delete windowEl.dataset.cruiseAltFt;
    }
    
    const pilotUsername = baseProps.username || 'N/A';
    const pilotReportTabText = (pilotUsername !== 'N/A' && pilotUsername) ? pilotUsername : 'Pilot Report';

    // --- DYNAMIC IMAGE & CONTRIBUTOR LOGIC ---
    let techCardImagePath = '/CommunityPlanes/default.png';
    let photographerName = 'IF Community';
    let techCardTail = reg;
    // Ordered list of {src, photographer} for the hero carousel (up to 3). A
    // single photo renders as a static background exactly as before; two or
    // more become a swipeable carousel (see buildHeroPhotoCarousel below).
    let techCardPhotos = [];

    // Zip a set of image URLs with their aligned contributor entries, falling
    // back to a single legacy url/name when the arrays are absent.
    const collectCommunityPhotos = (urls, contributors, fallbackUrl, fallbackName) => {
        // Feature properties can survive a Mapbox round-trip as JSON strings, so
        // tolerate both real arrays and their stringified form.
        const asArray = (v) => {
            if (Array.isArray(v)) return v;
            if (typeof v === 'string' && v.trim().startsWith('[')) { try { return JSON.parse(v); } catch { return []; } }
            return [];
        };
        urls = asArray(urls);
        contributors = asArray(contributors);
        let list = urls.filter(Boolean);
        if (!list.length && fallbackUrl) list = [fallbackUrl];
        return list.map((src, i) => ({
            src,
            photographer: (contributors && contributors[i] && contributors[i].name) || fallbackName || 'IF Community'
        }));
    };

    if (Array.isArray(communityAircraftData)) {
        communityAircraftData = communityAircraftData.length > 0 ? communityAircraftData[0] : null;
    }
    if (communityAircraftData && (communityAircraftData.imageUrl || (Array.isArray(communityAircraftData.imageUrls) && communityAircraftData.imageUrls.length))) {
        techCardPhotos = collectCommunityPhotos(
            communityAircraftData.imageUrls, communityAircraftData.imageContributors,
            communityAircraftData.imageUrl, communityAircraftData.contributorName
        );
        if (communityAircraftData.tailNumber) {
            techCardTail = communityAircraftData.tailNumber;
        }
    } else if (baseProps.communityImageUrl || (Array.isArray(baseProps.communityImageUrls) && baseProps.communityImageUrls.length)) {
        // Fallback to the photo(s) already cached on the live feature (populated
        // by the background hover-card lookup). Keeps the Standard window's
        // hero photo in sync with the Simple window, which already uses this
        // fallback, so the plane image still shows when the synchronous
        // lookup comes back empty.
        techCardPhotos = collectCommunityPhotos(
            baseProps.communityImageUrls, baseProps.imageContributors,
            baseProps.communityImageUrl, baseProps.contributorName
        );
        if (baseProps.tailNumber) {
            techCardTail = baseProps.tailNumber;
        }
    }
    if (techCardPhotos.length) {
        techCardImagePath = techCardPhotos[0].src;
        photographerName = techCardPhotos[0].photographer || 'IF Community';
    }

    // --- REAL-TIME COCKPIT STATE LOGIC ---
    const pilotStateValue = (typeof baseProps.pilotState !== 'undefined') ? Number(baseProps.pilotState) : 0;

    let psTitle = "ACTIVE";
    let psIcon = "fa-user-check";
    let psColor = "#4ade80";
    let psDesc = "Pilot is active";
    switch (pilotStateValue) {
        case 1: psTitle = "AWAY"; psIcon = "fa-plane-slash"; psColor = "#facc15"; psDesc = "Online (No Input)"; break;
        case 2: psTitle = "PARKED"; psIcon = "fa-square-parking"; psColor = "#94a3b8"; psDesc = "Away (On Ground)"; break;
        case 3: psTitle = "AUTO-PILOT+"; psIcon = "fa-cloud-arrow-up"; psColor = "#60a5fa"; psDesc = "Cloud Session"; break;
    }

    // --- GENERATE FMS LEGS HTML ---
    let fmsLegsHtml = '';
    const safeGetDistance = (typeof getDistanceKm === 'function') ? getDistanceKm : (lat1, lon1, lat2, lon2) => 0;
    if (originalFlatWaypointObjects.length > 0) {
        originalFlatWaypointObjects.forEach((wp, index) => {
            const ident = wp.identifier || wp.name || `WP${index + 1}`;
            let distDisplay = '----';
            if (index > 0) {
                const prev = originalFlatWaypointObjects[index - 1];
                if (prev.location && wp.location) {
                    const d = safeGetDistance(prev.location.latitude, prev.location.longitude, wp.location.latitude, wp.location.longitude);
                    distDisplay = (d / 1.852).toFixed(0);
                }
            }
            let procTag = '';
            if (index <= 1 && hasPlan) procTag = `<span class="proc-tag sid">SID</span>`;
            else if (index >= originalFlatWaypointObjects.length - 2 && hasPlan) procTag = `<span class="proc-tag star">STAR</span>`;

            fmsLegsHtml += `
            <div class="fms-row ${index === 0 ? 'active-leg' : ''}" style="display: flex; justify-content: space-between; padding: 10px 14px; border-bottom: 1px solid rgba(255,255,255,0.03);">
                 <span style="display:flex; align-items:center; gap:8px; flex: 2; text-align: left; font-weight: 500; font-family: 'JetBrains Mono', monospace;">
                    <i class="fa-solid fa-diamond" style="font-size: 6px; color: ${index === 0 ? '#4ade80' : '#475569'};"></i> ${ident} ${procTag}
                 </span>
                 <span class="text-center" style="color:#94a3b8; flex: 1; font-size: 11px;">---°</span>
                 <span class="text-right" style="flex: 1; color: #fff; font-weight: 600;">${distDisplay} <small style="font-size: 8px; color: #64748b;">NM</small></span>
            </div>`;
        });
    } else {
        fmsLegsHtml = `<div class="fms-empty-state" style="padding: 40px; text-align: center; color: #475569; font-size: 12px; font-weight: 600; letter-spacing: 1px;">NO ROUTE DATA AVAILABLE</div>`;
    }

    // Determine initial active classes for rendering
    const flightDataActiveClass = currentActiveTab === 'ac-tab-flight-data' ? 'active' : '';
    const pilotReportActiveClass = currentActiveTab === 'ac-tab-pilot-report' ? 'active' : '';
    const flightDataDisplay = currentActiveTab === 'ac-tab-flight-data' ? 'flex' : 'none';
    const pilotReportDisplay = currentActiveTab === 'ac-tab-pilot-report' ? 'block' : 'none';
    const highlightX = currentActiveTab === 'ac-tab-pilot-report' ? '100%' : '0%';

    // --- Lookup City Names ---
    const depCity = (typeof airportsData !== 'undefined' && airportsData[departureIcao]?.city) || 'Departure';
    const arrCity = (typeof airportsData !== 'undefined' && airportsData[arrivalIcao]?.city) || 'Arrival';

    // --- Determine Phase Color/Icon ---
    let statusColor = '#4ade80'; // Green
    let statusPulse = 'pulse';
    if (flightPhase.includes('CRUISE')) statusColor = '#38bdf8'; // Blue 
    if (flightPhase.includes('DESCENT')) statusColor = '#fbbf24'; // Orange 
    if (flightPhase.includes('GROUND') || flightPhase.includes('PARKED')) {
        statusColor = '#94a3b8'; // Grey 
        statusPulse = '';
    }

    // --- HTML Construction ---
    windowEl.innerHTML = `
    <div class="ac-header-modern" id="ac-overview-panel" style=" background-image: url('${techCardImagePath}'), url('/CommunityPlanes/default.png'); position: relative; display: flex; flex-direction: column; flex-shrink: 0; min-height: 200px; background-size: cover; background-position: center; transition: background-image 0.5s ease-in-out;">
            <div class="ac-header-overlay" style="position: absolute; inset: 0; background: linear-gradient(to bottom, rgba(0,0,0,0.04) 0%, rgba(0,0,0,0.08) 38%, rgba(58,58,58,0.18) 62%, rgba(58,58,58,0.72) 88%, #3a3a3a 100%); z-index: 0; pointer-events: none;"></div>
            <div class="ac-header-top" style=" position: relative; z-index: 1; padding: 20px 24px; display: flex; justify-content: space-between; align-items: flex-start;">
                <div class="ac-identity-group" style="max-width: calc(100% - 168px);">
                    <h1 style="font-size: 24px; font-weight: 800; color: #fff; margin: 0; line-height: 1.1; text-shadow: 0 2px 4px rgba(0,0,0,0.8);">${logoHtml} ${baseProps.callsign}</h1>
                    <div class="ac-sub-identity" style=" font-size: 11px; font-weight: 500; color: #cbd5e1; margin-top: 6px; text-shadow: 0 1px 2px rgba(0,0,0,0.8); display: flex; gap: 8px; align-items: center; flex-wrap: wrap;">
                        <span>${aircraftName}</span>
                        <span style="width: 3px; height: 3px; background: #94a3b8; border-radius: 50%;"></span>
                        <span>${liveryName}</span>
                    </div>
                </div>
            </div>

            <div class="overview-actions">
    <button id="pin-flight-btn" class="hero-btn aircraft-window-pin-btn" title="Pin Flight">
        <i class="fa-solid fa-thumbtack"></i>
    </button>

    ${(typeof window !== 'undefined' && window.isIOSNative && window.isIOSNative() && window.InflightLiveActivity && window.InflightLiveActivity.isSupported()) ? `
    <button class="hero-btn aircraft-window-trackme-btn" id="trackme-btn-${baseProps.flightId}" data-flight-id="${baseProps.flightId}" title="This is my flight">
        <i class="fa-solid ${window.InflightLiveActivity.isTrackingFlight(baseProps.flightId) ? 'fa-bell-slash' : 'fa-bell'}"></i>
    </button>` : ''}

    <button class="hero-btn aircraft-window-replay-btn" title="Replay Flight">
        <i class="fa-solid fa-circle-play"></i>
    </button>

    <button class="hero-btn aircraft-window-share-btn" title="Trip Card">
        <i class="fa-solid fa-camera"></i>
    </button>
</div>

            <div class="phase-badge-hero" style=" position: absolute; bottom: 45px; left: 24px; z-index: 2; background: rgba(0,0,0,0.6); backdrop-filter: blur(8px); padding: 4px 10px; border-radius: 20px; border: 1px solid rgba(255,255,255,0.15); display: flex; align-items: center; gap: 6px;">
                <div class="phase-dot" id="ac-phase-dot" style="width: 6px; height: 6px; border-radius: 50%; background: ${statusColor}; box-shadow: 0 0 8px ${statusColor}; animation: ${statusPulse} 2s infinite;"></div>
                <span id="ac-phase-text" style="font-size: 9px; font-weight: 700; color: #fff; letter-spacing: 0.5px;">${flightPhase}</span>
            </div>
        </div>

        <div class="ac-route-bar-backdrop" style="background: #3a3a3a; position: relative; box-shadow: 0 -24px 36px rgba(58,58,58,0.32);">
        <div class="ac-route-info-bar" style=" background: #3a3a3a; backdrop-filter: blur(16px); margin: -32px 16px 0 16px; border-radius: 12px; padding: 14px 24px; border: 1px solid rgba(255,255,255,0.1); display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-shrink: 0; position: relative; z-index: 5; box-shadow: 0 8px 32px rgba(0,0,0,0.4);">
            <div class="route-node">
        <span class="city-name" style="color: #94a3b8; font-size: 9px; font-weight: 600; text-transform: uppercase;">${depCity}</span>
        <span class="icao-large" style="display: flex; align-items: center; gap: 8px; color: #fff; font-size: 20px; font-weight: 800; font-family: 'JetBrains Mono', monospace; line-height: 1.1;">
            ${departureIcaoHtml}
            <img id="ac-bar-dep-flag" src="" style="height: 14px; border-radius: 2px; display: none; opacity: 0.8;" onerror="this.style.display='none'">
        </span>
        <span class="time-small" id="ac-bar-atd" style="color: ${depTimeInfo.color}; font-size: 11px; font-weight: 600;">${depTimeInfo.time === '--:--' ? '--:--' : depTimeInfo.time + ' Z'}</span>
        <span class="time-source-label" id="ac-bar-atd-label" style="color: ${depTimeInfo.color}; opacity: 0.75; font-size: 8px; font-weight: 700; letter-spacing: 0.6px; margin-top: 1px; text-transform: uppercase;">${depTimeInfo.label}</span>
    </div>
            
            <div class="route-visual" style="flex: 1; max-width: 240px; display: flex; flex-direction: column; justify-content: center;">
                <div class="flight-progress-track" style="height: 4px; background: rgba(255,255,255,0.1); border-radius: 4px; position: relative;">
<div class="flight-progress-fill" id="ac-progress-bar" style="width: ${progress}%; background: #38bdf8; height: 100%; border-radius: 4px; position: relative; transition: width 0.5s ease;">
    <i class="fa-solid fa-plane flight-progress-plane" style="position: absolute; right: -6px; top: 50%; transform: translateY(-50%) rotate(0deg); color: #fff; font-size: 10px; filter: drop-shadow(0 0 4px #38bdf8);"></i>
</div>
                </div>
                <div style="display: flex; justify-content: space-between; width: 100%; margin-top: 6px; font-size: 9px; color: #cbd5e1; font-weight: 700;">
                    <span>${Math.round(totalDistanceNM)} NM</span>
                    <span>ETE: ${ete}</span>
                </div>
            </div>

            <div class="route-node end" style="text-align: right; align-items: flex-end;">
                <span class="city-name" style="color: #94a3b8; font-size: 9px; font-weight: 600; text-transform: uppercase;">${arrCity}</span>
                <span class="icao-large" style="display: flex; align-items: center; gap: 8px; flex-direction: row-reverse; color: #fff; font-size: 20px; font-weight: 800; font-family: 'JetBrains Mono', monospace; line-height: 1.1;">
                    ${arrivalIcaoHtml}
                    <img id="ac-bar-arr-flag" src="" style="height: 14px; border-radius: 2px; display: none; opacity: 0.8;" onerror="this.style.display='none'">
                </span>
                <span class="time-small" id="ac-bar-eta" style="color: ${arrTimeInfo.color}; font-size: 11px; font-weight: 600;">${arrTimeInfo.time === '--:--' ? '--:--' : arrTimeInfo.time + ' Z'}</span>
                <span class="time-source-label" id="ac-bar-eta-label" style="color: ${arrTimeInfo.color}; opacity: 0.75; font-size: 8px; font-weight: 700; letter-spacing: 0.6px; margin-top: 1px; text-transform: uppercase;">${arrTimeInfo.label}</span>
            </div>
        </div>
        </div>

    <div class="ac-info-window-tabs" style="background: #3a3a3a; padding: 16px 16px 8px 16px; display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-shrink: 0; border-top: 1px solid rgba(255,255,255,0.04); border-bottom: 1px solid rgba(0,0,0,0.24);">
            <div class="modern-view-switcher" id="main-data-switcher" style="flex: 1; min-width: 0; background: #24272f; border-radius: 12px; padding: 4px; display: flex; position: relative; border: 1px solid rgba(255,255,255,0.08); height: 44px; box-shadow: inset 0 1px 0 rgba(255,255,255,0.04);">
                 <button class="ac-info-tab-btn ${flightDataActiveClass}" data-tab="ac-tab-flight-data" style="flex: 1; min-width: 0; overflow: hidden; border: none; background: transparent; color: #fff; font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 1.2px; padding: 0 10px; cursor: pointer; z-index: 1; transition: color 0.3s ease; display: flex; align-items: center; justify-content: center; gap: 8px;">
                    <i class="fa-solid fa-gauge-high" style="flex-shrink: 0;"></i>
                    <span style="min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">Flight Display</span>
                 </button>
                 <button class="ac-info-tab-btn pilot-tab-btn ${pilotReportActiveClass}" data-tab="ac-tab-pilot-report" data-user-id="${baseProps.userId}" data-username="${pilotUsername}" title="${pilotReportTabText}" style="flex: 1; min-width: 0; overflow: hidden; border: none; background: transparent; color: #94a3b8; font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 1.2px; padding: 0 10px; cursor: pointer; z-index: 1; transition: color 0.3s ease; display: flex; align-items: center; justify-content: center; gap: 8px;">
                    <i class="fa-solid fa-chart-simple" style="flex-shrink: 0;"></i>
                    <span style="min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">${pilotReportTabText}</span>
                 </button>
                 <div class="switcher-highlight" id="main-switcher-highlight" style="position: absolute; top: 4px; left: 4px; width: calc(50% - 4px); height: calc(100% - 8px); background: #3a3f4a; border: 1px solid rgba(255,255,255,0.12); border-radius: 8px; transition: transform 0.3s cubic-bezier(0.4, 0, 0.2, 1); transform: translateX(${highlightX}); box-shadow: 0 6px 16px rgba(0,0,0,0.22);"></div>
            </div>
            <button id="ac-dock-toggle-btn" class="ac-dock-toggle-btn" title="Move Window">
    <i class="fa-solid fa-arrows-left-right-to-line"></i>
</button>
    </div>

    <div class="unified-display-main-content">
            <div id="ac-tab-flight-data" class="ac-tab-pane ${flightDataActiveClass}" style="gap: 6px; display: ${flightDataDisplay};">
                <div class="pfd-and-location-grid">
                     <div class="pfd-main-panel">
                      <div class="display-bezel" style="background: rgba(15, 23, 42, 0.4); border: 1px solid rgba(255,255,255,0.05); border-radius: 12px; overflow: hidden; box-shadow: 0 4px 24px rgba(0,0,0,0.4);">
                            <div class="crt-container scanlines" id="pfd-container">
                                <svg width="787" height="800" viewBox="0 0 787 800" fill="none" xmlns="http://www.w3.org/2000/svg">
                                     <defs>
                                        <clipPath id="clip0_1_2890"><rect width="787" height="800" fill="white"/></clipPath>
                                        <clipPath id="tensReelClip"><rect x="732" y="269" width="50" height="75"/></clipPath>
                                        <clipPath id="headingClip"><rect x="243" y="620" width="326" height="45"/></clipPath>
                                        <clipPath id="speedTapeClip"><rect x="28" y="73" width="97" height="477"/></clipPath>
                                        <clipPath id="altTapeClip"><rect x="675" y="73" width="72" height="476"/></clipPath>
                                    </defs>
                                    <g id="PFD" clip-path="url(#clip0_1_2890)">
                                        <g transform="translate(0, 100)">
                                            <g id="attitude_group">
                                                <rect id="Sky" x="-186" y="-222" width="1121" height="600" fill="#0596FF"/>
                                                <rect id="Ground" x="-138" y="307" width="1024" height="527" fill="#9A4710"/>
                                            </g>
                                            
                                            <rect id="Rectangle 1" x="-6" y="5" width="191" height="566" fill="#030309"/>
                                            <rect id="Rectangle 9" x="609" width="185" height="566" fill="#030309"/>
                                            <path id="Rectangle 2" d="M273.905 84.9424L180.983 183.181L-23 -9.76114L69.9218 -108L273.905 84.9424Z" fill="#030309"/>
                                            <path id="Rectangle 8" d="M303.215 77.0814L187.591 147.198L42 -92.8829L157.624 -163L303.215 77.0814Z" fill="#030309"/>
                                            <path id="Rectangle 7" d="M372.606 54.0171L244.59 97.5721L154.152 -168.242L282.169 -211.796L372.606 54.0171Z" fill="#030309"/>
                                            <rect id="Rectangle 10" x="25" y="487.905" width="168.696" height="262.947" transform="rotate(-31.8041 25 487.905)" fill="#030309"/>
                                            <rect id="Rectangle 14" width="67.3639" height="53.5561" transform="matrix(-0.972506 0.23288 0.23288 0.972506 482.512 537)" fill="#030309"/>
                                            <rect id="Rectangle 19" width="80.8905" height="53.5561" transform="matrix(-0.999899 0.0142423 0.0142423 0.999899 442.882 549.506)" fill="#030309"/>
                                            <rect id="Rectangle 18" width="46.2297" height="53.5561" transform="matrix(-0.988103 -0.153795 -0.153795 0.988103 369.916 549.11)" fill="#030309"/>
                                            <rect id="Rectangle 17" width="46.2297" height="53.5561" transform="matrix(-0.940186 -0.340662 -0.340662 0.940186 337.709 546.749)" fill="#030309"/>
                                            <rect id="Rectangle 16" width="46.2297" height="53.5561" transform="matrix(-0.940186 -0.340662 -0.340662 0.940186 299.709 531.749)" fill="#030309"/>
                                            <rect id="Rectangle 15" x="387" y="587.269" width="168.696" height="262.947" transform="rotate(-27.6434 387 587.269)" fill="#030309"/>
                                            <rect id="Rectangle 13" x="86" y="584.104" width="168.696" height="262.947" transform="rotate(-46.8648 86 584.104)" fill="#030309"/>
                                            <rect id="Rectangle 11" x="527" y="532.777" width="168.696" height="262.947" transform="rotate(-51.9135 527 532.777)" fill="#030309"/>
                                            <rect id="Rectangle 12" x="503" y="527.247" width="168.696" height="262.947" transform="rotate(-31.9408 503 527.247)" fill="#030309"/>
                                            <rect id="Rectangle 6" x="456.715" y="60.2651" width="131.991" height="278.153" transform="rotate(-177.303 456.715 60.2651)" fill="#030309"/>
                                            <rect id="Rectangle 5" x="525.118" y="90.4898" width="131.991" height="274.627" transform="rotate(-158.368 525.118 90.4898)" fill="#030309"/>
                                            <rect id="Rectangle 4" x="570.695" y="127.633" width="109.94" height="223.222" transform="rotate(-142.051 570.695 127.633)" fill="#030309"/>
                                            <rect id="Rectangle 3" x="613.292" y="189.098" width="99.2768" height="223.222" transform="rotate(-128.125 613.292 189.098)" fill="#030309"/>
                                            <path id="Vector 3" d="M609 183V422.5" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 1" d="M185.5 425.5L185 180" stroke="#DBDBDC" stroke-width="4"/>
                                            <path id="Vector 2" d="M185 181.502C185 181.502 269.8 52.0936 397 56.0907C524.2 60.0879 576.603 135.189 609 184" stroke="#DBDBDC" stroke-width="4"/>
                                            <path id="Vector 4" d="M608.5 424.5C608.5 424.5 557 548 396 550.5C235 553 185 424.5 185 424.5" stroke="#DBDBDC" stroke-width="4"/>
                                            <path id="Polygon 1" d="M396.252 65.2333L377.848 35.8138L414.647 35.8079L396.252 65.2333Z" fill="#E7F013"/>
                                            <path id="Polygon 2" d="M407.919 38.9482L396.431 59.4193L384.446 38.7244L407.919 38.9482Z" fill="#030309"/>
                                            <path id="Vector 6" d="M307 76L302 64.5L312 60.5L317 71" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 7" d="M279.5 91L268.5 73.5L259 79L269.5 97.5" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 8" d="M225 135L206.5 117" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 9" d="M477.153 71.5794L479.366 59.3018L489.886 61.5697L488.226 73.0218" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 10" d="M347.928 61.4888L346.352 49.0483L357.072 48.0112L358.929 59.4917" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 11" d="M435.153 59.5794L437.366 47.3018L447.886 49.5697L446.226 61.0218" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 12" d="M514.032 86.1754L522.756 72.2658L533.956 78.0405L525.5 93.5" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 13" d="M569.5 131.5L585.5 116" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 15" d="M183.5 193.5L173 187" stroke="#029705" stroke-width="4"/>
                                            <path id="Vector 16" d="M184 203L173.5 196.5" stroke="#029705" stroke-width="4"/>
                                            <path id="Vector 17" d="M610 193.5L619 188" stroke="#029705" stroke-width="3"/>
                                            <path id="Vector 18" d="M610 199.5L619 194" stroke="#029705" stroke-width="3"/>
                                            <line id="Line 1" x1="184" y1="211" x2="184" y2="184" stroke="#DBDBDC" stroke-width="2"/>
                                            <line id="Line 2" x1="610" y1="211" x2="610" y2="184" stroke="#DBDBDC" stroke-width="2"/>
                                            <rect id="altitude_bg" x="675" y="73" width="72" height="476" fill="#76767A"/>
                                            <g clip-path="url(#altTapeClip)">
                                                <svg x="675" y="73" width="72" height="476"><g id="altitude_tape_group"></g></svg>
                                            </g>
                                            <g id="altitude_indicator_static">
                                                <rect id="altitude_1" x="675" y="280" width="73" height="49" fill="#030309"/>
                                                <text id="altitude_readout_hundreds" x="740" y="316" fill="#00FF00" font-size="32" text-anchor="end" font-weight="bold">0</text>
                                                <g id="altitude_tens_reel_container" clip-path="url(#tensReelClip)"><g id="altitude_tens_reel_group"></g></g>
                                                <line id="Line 8" x1="669" y1="307" x2="618" y2="307" stroke="#DDDF07" stroke-width="8"/>
                                            </g>
                                            <path id="limit" d="M636 336.08L621.413 307.511L650.858 307.651L636 336.08Z" fill="#C477C6"/>
                                            <path id="limit2" d="M636 279L650.722 307.5H621.278L636 279Z" fill="#C477C6"/>
                                            <path id="limit3" d="M636 285L643.794 303H628.206L636 285Z" fill="#100010"/>
                                            <path id="limit4" d="M636.191 329.14L628.276 311.242L643.534 310.999L636.191 329.14Z" fill="#030309"/>
                                            <line id="Line 6" x1="746.5" y1="263" x2="746.5" y2="281" stroke="#ECED06" stroke-width="3"/>
                                            <line id="Line 4" x1="746.5" y1="329" x2="746.5" y2="347" stroke="#ECED06" stroke-width="3"/>
                                            <path id="Ellipse 1" d="M636 481C636 484.866 632.866 488 629 488C625.134 488 622 484.866 622 481C622 477.134 625.134 474 629 474C632.866 474 636 477.134 636 481Z" fill="#D9D9D9"/>
                                            <path id="Ellipse 4" d="M636 147C636 150.866 632.866 154 629 154C625.134 154 622 150.866 622 147C622 143.134 625.134 140 629 140C632.866 140 636 147Z" fill="#D9D9D9"/>
                                            <g id="Ellipse 3">
                                                <path d="M636 229C636 232.866 632.866 236 629 236C625.134 236 622 232.866 622 229C622 225.134 625.134 222 629 222C632.866 222 636 225.134 636 229Z" fill="#D9D9D9"/>
                                                <path d="M636 395C636 398.866 632.866 402 629 402C625.134 402 622 398.866 622 395C622 391.134 625.134 388 629 388C632.866 388 636 391.134 636 395Z" fill="#D9D9D9"/>
                                            </g>
                                            <rect id="speed" x="28" y="73" width="97" height="477" fill="#76767A"/>
                                            <g clip-path="url(#speedTapeClip)">
                                                <svg x="28" y="73" width="97" height="477"><g id="speed_tape_group"></g></svg>
                                            </g>
                                            <g id="speed_indicator_static">
                                                <path id="Polygon 9" d="M128.036 311.591L150.451 301.561L150.513 321.482L128.036 311.591Z" fill="#FDFD03"/>
                                                <path id="Vector 20" d="M137 311H96.5" stroke="#FDFD03" stroke-width="4"/>
                                                <rect x="50" y="296" width="45" height="30" fill="black" stroke="#999" stroke-width="1"/>
                                                <text id="speed_readout" x="72.5" y="318" fill="#00FF00" font-size="20" text-anchor="middle" font-weight="bold">0</text>
                                            </g>
                                            <path id="Vector 19" d="M19.5 311H31" stroke="#FDFD03" stroke-width="4"/>
                                            <path id="Vector 21" d="M29 73H151.5" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 22" d="M28 549H151.5" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 23" d="M672.5 73H774" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 24" d="M672 548.5H773" stroke="#E7E6E8" stroke-width="4"/>
                                            <path id="Vector 25" d="M745 549.5L746 347" stroke="#E7E6E8" stroke-width="3"/>
                                            <path id="Vector 26" d="M745 73V265" stroke="#E7E6E8" stroke-width="3"/>
                                            <g id="wings">
                                                <rect id="Rectangle 21" x="280" y="315" width="11" height="25" fill="#030309"/>
                                                <rect id="Rectangle 23" x="522" y="304" width="71" height="12" fill="#030309"/>
                                                <rect id="Rectangle 22" x="512" y="305" width="13" height="35" fill="#030309"/>
                                                <rect id="Rectangle 20" x="208" y="304" width="83" height="13" fill="#030309"/>
                                                <g id="wing">
                                                    <path d="M278.591 316.857H208V304H291.608V340H278.591V316.857Z" stroke="#FEFE03" stroke-width="3"/>
                                                    <path d="M511.392 340V304H595V316.857H524.409V340H511.392Z" stroke="#FEFE03" stroke-width="3"/>
                                                </g>
                                            </g>
                                            <g id="middle">
                                                <rect id="middle_2" x="393" y="304" width="17" height="17" fill="#0CC704"/>
                                                <rect id="Rectangle 24" x="395" y="307" width="13" height="11" fill="#030309"/>
                                            </g>
                                            <rect id="Rectangle 25" y="571" width="787" height="140" fill="#030309"/>
                                            <rect id="header" x="243" y="599" width="326" height="66" fill="#76767A"/>
                                            <g id="heading_indicator">
                                                <g id="heading_tape_container" clip-path="url(#headingClip)"><g id="heading_tape_group"></g></g>
                                                <g id="heading_static_elements">
                                                    <line x1="406" y1="620" x2="406" y2="635" stroke="#FDFD03" stroke-width="3"/>
                                                    <rect x="381" y="599" width="50" height="20" fill="black" stroke="#FFFFFF" stroke-width="1"/>
                                                    <text id="heading_readout" x="406" y="615" fill="#00FF00" font-size="16" text-anchor="middle" font-weight="bold">000</text>
                                                </g>
                                            </g>
                                            <path id="Vector 27" d="M243 599V667" stroke="#FCFCFF" stroke-width="4"/>
                                            <g id="Line 5"><line id="Line 5_2" x1="745" y1="264.5" x2="787" y2="264.5" stroke="#ECED06" stroke-width="3"/></g>
                                            <line id="Line 6_2" x1="671" y1="279.5" x2="748" y2="279.5" stroke="#ECED06" stroke-width="3"/>
                                            <line id="Line 7" x1="671" y1="329.5" x2="748" y2="329.5" stroke="#ECED06" stroke-width="3"/>
                                            <line id="Line 3" x1="746" y1="345.5" x2="786" y2="345.5" stroke="#ECED06" stroke-width="3"/>
                                        </g>
                                    </g>
                                </svg>
                            </div>
                         </div>
                    </div> 
                    
                <div class="info-right-col" style="gap: 6px; display: flex; flex-direction: column; height: 100%; justify-content: space-between;">
    <div class="modern-status-card" style="background: linear-gradient(165deg, rgba(255,255,255,0.08) 0%, rgba(255,255,255,0.01) 100%); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 10px 12px; position: relative; overflow: hidden; backdrop-filter: blur(12px); flex: 1; display: flex; flex-direction: column; justify-content: center;">
        <div class="status-glow" style="position: absolute; top: -20px; right: -20px; width: 60px; height: 60px; background: ${psColor}; filter: blur(35px); opacity: 0.2;"></div>
        
        <div style="display: flex; flex-direction: column; gap: 8px; position: relative; z-index: 2;">
            <div style="display: flex; align-items: center; justify-content: space-between;">
                <div style="width: 30px; height: 30px; border-radius: 8px; background: rgba(0,0,0,0.2); display: flex; align-items: center; justify-content: center; color: ${psColor}; border: 1px solid ${psColor}40;">
                     <i class="fa-solid ${psIcon}" style="font-size: 14px; filter: drop-shadow(0 0 8px ${psColor}60);"></i>
                </div>
                <div class="tech-ping" style="width: 6px; height: 6px; position: relative;">
                    <span class="animate" style="background: ${psColor}; position: absolute; inset: 0; border-radius: 50%; opacity: 0.6;"></span>
                    <span style="background: ${psColor}; position: absolute; inset: 0; border-radius: 50%;"></span>
                </div>
            </div>
            <div>
                <span style="display: block; font-size: 8px; color: #94a3b8; font-weight: 800; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 1px;">Pilot Status</span>
                <span style="display: block; font-size: 14px; color: #fff; font-weight: 800; letter-spacing: 0.5px;">${psTitle}</span>
                <span style="display: block; font-size: 9px; color: #64748b; font-weight: 500; margin-top: 1px;">${psDesc}</span>
            </div>
        </div>
    </div>

    <div class="modern-timer-stack" style="display: flex; flex-direction: column; gap: 4px;">
        <div class="timer-node" style="background: rgba(15, 23, 42, 0.4); border-left: 3px solid #64748b; padding: 8px 10px; border-radius: 4px 10px 10px 4px; border-top: 1px solid rgba(255,255,255,0.03);">
            <div style="display: flex; align-items: center; gap: 4px; margin-bottom: 2px;">
                <i class="fa-solid fa-stopwatch" style="color: #64748b; font-size: 8px;"></i>
                <span style="display: block; font-size: 7px; color: #64748b; text-transform: uppercase; font-weight: 700; letter-spacing: 1px;">Elapsed</span>
            </div>
            <span id="ac-sensor-elapsed" style="display: block; font-family: 'JetBrains Mono', monospace; font-size: 16px; color: #fff; font-weight: 500;">--:--</span>
        </div>

        <div class="timer-node" style="background: rgba(15, 23, 42, 0.4); border-left: 3px solid #38bdf8; padding: 8px 10px; border-radius: 4px 10px 10px 4px; border-top: 1px solid rgba(255,255,255,0.03);">
            <div style="display: flex; align-items: center; gap: 4px; margin-bottom: 2px;">
                <i class="fa-solid fa-hourglass-half" style="color: #38bdf8; font-size: 8px;"></i>
                <span style="display: block; font-size: 7px; color: #38bdf8; text-transform: uppercase; font-weight: 700; letter-spacing: 1px;">Remaining</span>
            </div>
            <span id="ac-sensor-ete" style="display: block; font-family: 'JetBrains Mono', monospace; font-size: 16px; color: #38bdf8; font-weight: 700;">--:--</span>
        </div>

        <div class="timer-node" style="background: transparent; padding: 4px 10px; display: flex; justify-content: space-between; align-items: center; border-top: 1px solid rgba(255,255,255,0.05);">
            <span style="font-size: 7px; color: #475569; text-transform: uppercase; font-weight: 700;">Total</span>
            <span id="ac-sensor-total" style="font-family: 'JetBrains Mono', monospace; font-size: 11px; color: #475569; font-weight: 600;">--:--</span>
        </div>
    </div>
</div>
                </div> 

                <div class="nd-full-width-section">
                    <div class="modern-view-switcher" style="margin-bottom: 12px; background: rgba(15, 23, 42, 0.4); border-radius: 12px; padding: 4px; display: flex; position: relative; border: 1px solid rgba(255,255,255,0.05);">
                         <button class="display-toggle-btn ${currentViewTarget === 'nd-view' ? 'active' : ''}" data-target="nd-view" style="flex: 1; border: none; background: transparent; color: #94a3b8; font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 1.5px; padding: 10px; cursor: pointer; z-index: 1; transition: color 0.3s ease;">
                            <i class="fa-solid fa-compass" style="margin-right: 6px;"></i> Navigation
                         </button>
                         <button class="display-toggle-btn ${currentViewTarget === 'fmc-view' ? 'active' : ''}" data-target="fmc-view" style="flex: 1; border: none; background: transparent; color: #94a3b8; font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 1.5px; padding: 10px; cursor: pointer; z-index: 1; transition: color 0.3s ease;">
                            <i class="fa-solid fa-list-ul" style="margin-right: 6px;"></i> Flight Plan
                         </button>
                         <div class="switcher-highlight" style="position: absolute; top: 4px; left: 4px; width: calc(50% - 4px); height: calc(100% - 8px); background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.1); border-radius: 8px; transition: transform 0.3s cubic-bezier(0.4, 0, 0.2, 1); transform: translateX(${currentViewTarget === 'fmc-view' ? '100%' : '0%'});"></div>
                    </div>

                    <div class="display-bezel" style="background: rgba(15, 23, 42, 0.4); border: 1px solid rgba(255,255,255,0.05); border-radius: 12px; overflow: hidden; box-shadow: 0 4px 24px rgba(0,0,0,0.4);">
                        <div class="crt-container scanlines" style="aspect-ratio: 1/1; display: flex; flex-direction: column; overflow: hidden;">
                             <div id="nd-view-container" style="width: 100%; height: 100%; display: ${currentViewTarget === 'nd-view' ? 'block' : 'none'};">
                                <div id="nd-container">
                                    <iframe id="nav-display-frame" src="nav.html" scrolling="no"></iframe>
                                 </div>
                            </div>

                            <div id="fmc-view-container" style="display: ${currentViewTarget === 'fmc-view' ? 'flex' : 'none'}; width: 100%; height: 100%; background: #000; flex-direction: column;">
                                <div class="fms-module-container" style="height: 100%; max-height: 100%; width: 100%; border: none; background: transparent; box-shadow: none; border-radius: 0; display: flex; flex-direction: column; overflow: hidden;">
                                    <div class="fms-header" style="background: rgba(255,255,255,0.05); padding: 14px 18px; border-bottom: 1px solid rgba(255,255,255,0.05); flex-shrink: 0; display: flex; justify-content: space-between; align-items: center;">
                                        <span class="tech-module-title" style="font-weight: 700; font-size: 11px; letter-spacing: 1px;"><i class="fa-solid fa-route" style="color: #38bdf8;"></i> ROUTE PROFILE</span>
                                        <span class="fms-page-count" style="font-family: monospace; font-size: 10px; color: #475569;">PAGE 01/01</span>
                                    </div>
                                    <div class="fms-columns" style="border-bottom: 1px dashed rgba(255,255,255,0.1); display: flex; justify-content: space-between; padding: 8px 14px; flex-shrink: 0; background: rgba(0,0,0,0.2);">
                                        <span class="col-wpt" style="flex: 2; text-align: left; font-size: 9px; color: #64748b; text-transform: uppercase;">Waypoint Ident</span>
                                        <span class="col-data text-center" style="flex: 1; font-size: 9px; color: #64748b; text-transform: uppercase;">CRS</span>
                                        <span class="col-data text-right" style="flex: 1; font-size: 9px; color: #64748b; text-transform: uppercase;">DIST</span>
                                    </div>
                                    <div id="fms-legs-list" class="fms-list-scrollarea" style="flex: 1; overflow-y: auto; min-height: 0; scrollbar-width: none;">
                                        ${fmsLegsHtml}
                                    </div>
                                     <div class="fms-footer" style="background: rgba(15, 23, 42, 0.8); border-top: 1px solid rgba(255,255,255,0.05); flex-shrink: 0; padding: 12px 18px; display: flex; gap: 24px;">
                                        <div class="fms-stat">
                                            <span class="stat-label" style="display: block; font-size: 8px; color: #64748b; text-transform: uppercase; margin-bottom: 2px;">Total Distance</span>
                                            <span id="fms-total-dist" class="stat-value" style="font-size: 16px; color: #fff; font-weight: 700;">---- NM</span>
                                        </div>
                                        <div class="fms-stat">
                                             <span class="stat-label" style="display: block; font-size: 8px; color: #64748b; text-transform: uppercase; margin-bottom: 2px;">Estimated Time</span>
                                            <span id="fms-total-ete" class="stat-value" style="font-size: 16px; color: #38bdf8; font-weight: 700;">--:--</span>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Hidden legacy elements: FMS-view footer copies their innerHTML/textContent. Keep them so legacy code keeps working. -->
                <span id="ac-dist" style="display:none;"></span>
                <span id="ac-ete" style="display:none;"></span>

                <!-- ════════════ NAVIGATION CARD (ac-bar style) ════════════ -->
                <div class="ac-info-card-bar nav-card" style="background: var(--bg-glass); border-radius: var(--radius-md); padding: 16px 20px; border: 1px solid var(--border-glass); box-shadow: 0 4px 15px rgba(0,0,0,0.5);">
                    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px;">
                        <span style="font-size: 9px; color: #fff; text-transform: uppercase; font-weight: 800; letter-spacing: 1.2px; display: flex; align-items: center; gap: 8px;">
                            <i class="fa-solid fa-location-crosshairs" style="color: #38bdf8;"></i> Navigation
                        </span>
                        <span style="font-size: 8px; color: #4ade80; font-weight: 700; letter-spacing: 0.6px; display: flex; align-items: center; gap: 6px;">
                            <span class="nav-status-indicator" style="width: 6px; height: 6px; background: #4ade80; border-radius: 50%; box-shadow: 0 0 6px #4ade80;"></span> SYNC
                        </span>
                    </div>

                    <!-- Position grid: compact iOS-friendly live flight data -->
                    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(86px, 1fr)); gap: 12px;">
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">LAT</span>
                            <span id="ac-lat" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">---</span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">LON</span>
                            <span id="ac-lon" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">---</span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">ALT</span>
                            <span id="ac-alt" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">--- <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">ft</span></span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">HDG</span>
                            <span id="ac-heading" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">---°</span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">G/S</span>
                            <span id="ac-gs" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">--- <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">kt</span></span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">V/S</span>
                            <span id="ac-vs" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">---</span>
                        </div>
                    </div>

                    <!-- Atmosphere and plan row: WIND / SAT / TAS / CRZ / ALT delta -->
                    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(86px, 1fr)); gap: 12px; margin-top: 12px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,0.06);">
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">WIND</span>
                            <span id="ac-env-wind" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">---/--</span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">SAT</span>
                            <span id="ac-env-oat" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">--°C</span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">TAS</span>
                            <span id="ac-tas" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">--- <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">kt</span></span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">CRZ</span>
                            <span id="ac-cruise-tgt" style="color: #38bdf8; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">${cruiseAltText}</span>
                        </div>
                        <div style="display: flex; flex-direction: column; min-width: 0;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">ALT Δ</span>
                            <span id="ac-alt-delta" style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">---</span>
                        </div>
                    </div>

                    <!-- Next waypoint pill -->
                    <div style="margin-top: 14px; padding: 10px 14px; background: rgba(15, 23, 42, 0.5); border-radius: 10px; border: 1px solid rgba(255,255,255,0.04); display: flex; align-items: center; justify-content: space-between; gap: 10px;">
                        <div style="display: flex; align-items: center; gap: 10px; min-width: 0;">
                            <i class="fa-solid fa-diamond" style="color: #facc15; font-size: 7px;"></i>
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px;">NEXT WP</span>
                            <span id="ac-next-wp" style="color: #facc15; font-size: 14px; font-weight: 800; font-family: 'JetBrains Mono', monospace;">---</span>
                        </div>
                        <div style="white-space: nowrap;">
                            <span id="ac-next-wp-dist" style="color: #fff; font-size: 13px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">--.-</span>
                            <span style="color: #94a3b8; font-size: 9px; margin-left: 4px;">NM</span>
                        </div>
                    </div>

                    <!-- Nearest facility pill -->
                    <div style="margin-top: 8px; padding: 10px 14px; background: rgba(15, 23, 42, 0.5); border-radius: 10px; border: 1px solid rgba(255,255,255,0.04); display: flex; align-items: center; justify-content: space-between; gap: 10px;">
                        <div style="display: flex; align-items: center; gap: 10px; min-width: 0;">
                            <i class="fa-solid fa-tower-cell" style="color: #38bdf8; font-size: 10px;"></i>
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px;">NEAREST</span>
                            <span id="ac-nearest-apt" style="color: #38bdf8; font-size: 14px; font-weight: 800; font-family: 'JetBrains Mono', monospace;">---</span>
                        </div>
                        <div style="white-space: nowrap;">
                            <span id="ac-nearest-apt-dist" style="color: #fff; font-size: 13px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">--.-</span>
                            <span style="color: #94a3b8; font-size: 9px; margin-left: 4px;">NM</span>
                        </div>
                    </div>

                    <!-- Geocoded position text -->
                    <div style="margin-top: 12px; padding-top: 10px; border-top: 1px solid rgba(255,255,255,0.05);">
                        <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 3px;">CURRENT POSITION</span>
                        <span id="ac-location" style="color: #fff; font-size: 12px; font-weight: 500;">Scanning...</span>
                    </div>
                </div>

               <!-- ════════════ AIRCRAFT CARD (slimmed — no duplicate name/callsign/airline) ════════════ -->
               <div class="ac-info-card-bar aircraft-card" style="background: var(--bg-glass); border-radius: var(--radius-md); padding: 16px 20px; border: 1px solid var(--border-glass); box-shadow: 0 4px 15px rgba(0,0,0,0.5);">
                    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px;">
                        <span style="font-size: 9px; color: #fff; text-transform: uppercase; font-weight: 800; letter-spacing: 1.2px; display: flex; align-items: center; gap: 8px;">
                            <i class="fa-solid fa-plane" style="color: #38bdf8;"></i> Aircraft
                        </span>
                        <span style="font-size: 8px; color: #94a3b8; font-weight: 600; letter-spacing: 0.6px;">SPECIFICATIONS</span>
                    </div>

                    <div style="display: grid; grid-template-columns: ${filedPlanData ? 'repeat(4, 1fr)' : 'repeat(2, 1fr)'}; gap: 12px;">
                        <div style="display: flex; flex-direction: column;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">Reg</span>
                            <span style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">${techCardTail}</span>
                        </div>
                        <div style="display: flex; flex-direction: column;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">Class</span>
                            <span style="color: #fff; font-size: 14px; font-weight: 700; text-transform: capitalize;">${baseProps.category || 'Commercial'}</span>
                        </div>
                        ${filedPlanData ? `
                        <div style="display: flex; flex-direction: column;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">PAX</span>
                            <span style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">${filedPlanData.passengers != null ? filedPlanData.passengers : '—'}</span>
                        </div>
                        <div style="display: flex; flex-direction: column;">
                            <span style="color: #94a3b8; font-size: 8px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; display: block; margin-bottom: 2px;">Block Fuel</span>
                            <span style="color: #fff; font-size: 14px; font-weight: 700; font-family: 'JetBrains Mono', monospace;">${filedPlanData.fuel_used ? Math.round(filedPlanData.fuel_used / 1000) + 'k' : '—'} <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">kg</span></span>
                        </div>` : ''}
                    </div>

                    ${photographerName && photographerName !== 'IF Community' && techCardPhotos.length <= 1 ? `
                    <div style="margin-top: 12px; padding-top: 10px; border-top: 1px solid rgba(255,255,255,0.05); display: flex; align-items: center; gap: 6px;">
                        <i class="fa-solid fa-camera" style="color: #38bdf8; font-size: 9px;"></i>
                        <span style="font-size: 9px; color: #94a3b8;">Photo · ${photographerName}</span>
                    </div>` : ''}
                </div>
            </div>
 
            <div id="ac-tab-pilot-report" class="ac-tab-pane ${pilotReportActiveClass}" style="display: ${pilotReportDisplay}; padding: 12px;">
                 <div id="pilot-stats-display" style="width: 100%; min-height: 200px;"></div>
            </div>
        </div>
    </div>
    `;

    // --- POST-RENDER LOGIC ---
    if(typeof createPfdDisplay === 'function') createPfdDisplay();
    if(typeof updatePfdDisplay === 'function') updatePfdDisplay(baseProps.position);
    
    if (currentActiveTab === 'ac-tab-pilot-report' && typeof displayPilotStats === 'function') {
        displayPilotStats(baseProps.userId, pilotUsername);
    }

    const imagePath = techCardImagePath;
    const fallbackPath = '/CommunityPlanes/default.png';
    const newImageUrl = `url('${imagePath}'), url('${fallbackPath}')`;

    const overviewPanels = document.querySelectorAll('#ac-overview-panel');
    overviewPanels.forEach(overviewPanel => {
        overviewPanel.style.backgroundImage = newImageUrl;
        overviewPanel.dataset.currentPath = imagePath;
        buildHeroPhotoCarousel(overviewPanel, techCardPhotos, fallbackPath);
    });

    // --- SENSOR TIMER LOGIC ---
    const updateSensorTimers = () => {
        const elElapsed = document.getElementById('ac-sensor-elapsed');
        const elEte = document.getElementById('ac-sensor-ete');
        const elTotal = document.getElementById('ac-sensor-total');
        const sourceEte = document.getElementById('ac-ete');
        
        if (elElapsed && atdTimestamp) {
            const now = Date.now();
            const start = new Date(atdTimestamp).getTime();
            const diff = now - start;
            if (diff >= 0) {
                const h = Math.floor(diff / 3600000);
                const m = Math.floor((diff % 3600000) / 60000);
                elElapsed.textContent = `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
            }
        }

        if (elEte && sourceEte && elTotal) {
            const currentEte = sourceEte.textContent;
            if (currentEte && currentEte.includes(':')) {
                elEte.textContent = currentEte;
                if (elElapsed && elElapsed.textContent !== '--:--') {
                    const [eH, eM] = elElapsed.textContent.split(':').map(Number);
                    const [rH, rM] = currentEte.split(':').map(Number);
                    let tM = eM + rM;
                    let tH = eH + rH + Math.floor(tM / 60);
                    tM = tM % 60;
                    elTotal.textContent = `${String(tH).padStart(2, '0')}:${String(tM).padStart(2, '0')}`;
                }
            }
        }
    };
    
    if (window.sensorTimerInterval) clearInterval(window.sensorTimerInterval);
    updateSensorTimers();
    window.sensorTimerInterval = setInterval(updateSensorTimers, 1000);

    // --- REDESIGNED DISPLAY TOGGLE LOGIC ---
    const mainTabBtns = windowEl.querySelectorAll('.ac-info-tab-btn');
    const mainHighlight = windowEl.querySelector('#main-switcher-highlight');
    const tabPanes = windowEl.querySelectorAll('.ac-tab-pane');

    mainTabBtns.forEach((btn, index) => {
        btn.addEventListener('click', (e) => {
            mainTabBtns.forEach(b => {
                b.classList.remove('active');
                b.style.color = '#94a3b8';
            });
            e.currentTarget.classList.add('active');
            e.currentTarget.style.color = '#fff';

            if (mainHighlight) {
                mainHighlight.style.transform = `translateX(${index * 100}%)`;
            }

            const targetId = e.currentTarget.dataset.tab;
            tabPanes.forEach(pane => {
                pane.classList.remove('active');
                const displayType = targetId === 'ac-tab-pilot-report' ? 'block' : 'flex';
                pane.style.display = pane.id === targetId ? displayType : 'none';
            });
       
             if (e.currentTarget.classList.contains('pilot-tab-btn')) {
                const uid = e.currentTarget.dataset.userId;
                const uname = e.currentTarget.dataset.username;
                if (typeof displayPilotStats === 'function') displayPilotStats(uid, uname);
            }
        });
        if (btn.classList.contains('active')) btn.style.color = '#fff';
    });

    const toggleBtns = windowEl.querySelectorAll('.display-toggle-btn');
    const displayHighlight = windowEl.querySelector('.switcher-highlight:not(#main-switcher-highlight)');
    const ndContainer = windowEl.querySelector('#nd-view-container');
    const fmcContainer = windowEl.querySelector('#fmc-view-container');

    toggleBtns.forEach((btn, index) => {
        btn.addEventListener('click', (e) => {
            toggleBtns.forEach(b => {
                b.classList.remove('active');
                b.style.color = '#94a3b8';
            });
            e.currentTarget.classList.add('active');
            e.currentTarget.style.color = '#fff';
            
            if (displayHighlight) {
                displayHighlight.style.transform = `translateX(${index * 100}%)`;
            }

            const target = e.currentTarget.dataset.target; 
            if (target === 'nd-view') {
                if(ndContainer) ndContainer.style.display = 'block';
               if(fmcContainer) fmcContainer.style.display = 'none';
            } else {
                if(ndContainer) ndContainer.style.display = 'none';
                if(fmcContainer) fmcContainer.style.display = 'flex';
            }
        });
        if (btn.classList.contains('active')) btn.style.color = '#fff';
    });

    // --- Run an immediate update pass so the phase badge / live data
    // render correctly on first paint instead of lingering on the
    // "CRUISE" default for several seconds.
    try {
        if (typeof updateAircraftInfoWindow === 'function') {
            updateAircraftInfoWindow(baseProps, plan, sortedRoutePoints);
        }
    } catch (err) {
        console.warn('Initial phase update pass failed:', err);
    }

    // --- POST-RENDER LOGIC: Inject Multi-Track Pin Button ---
    const actionsContainer = windowEl.querySelector('.info-window-actions');
    if (actionsContainer && !document.getElementById('pin-flight-btn')) {
        const isPinned = window.pinnedFlights.has(baseProps.flightId);
        const pinBtnHTML = `
            <button id="pin-flight-btn" class="pin-btn ${isPinned ? 'active-pin' : ''}" title="Pin Flight (Multi-Track)" onclick="window.toggleFlightPin('${baseProps.flightId}')" style="background: transparent; border: none; font-size: 0.9rem; margin-right: 8px; cursor: pointer; transition: all 0.2s; color: ${isPinned ? '#38bdf8' : '#94a3b8'};">
                <i class="fa-solid fa-thumbtack"></i>
            </button>
        `;
        actionsContainer.insertAdjacentHTML('afterbegin', pinBtnHTML);
    }

    // --- DOCK TOGGLE LOGIC ---
const dockBtn = windowEl.querySelector('#ac-dock-toggle-btn');
if (dockBtn) {
    // Check saved preference on load
    const isDockedLeft = localStorage.getItem('acWindowDock') === 'left';
    if (isDockedLeft) {
        windowEl.classList.add('dock-left');
        dockBtn.classList.add('docked-left');
    } else {
        windowEl.classList.remove('dock-left');
        dockBtn.classList.remove('docked-left');
    }
    
    // Attach listener
    dockBtn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation(); // Prevent tab switching from intercepting
        
        const isLeft = windowEl.classList.toggle('dock-left');
        dockBtn.classList.toggle('docked-left', isLeft);
        
        // Save preference to localStorage
        localStorage.setItem('acWindowDock', isLeft ? 'left' : 'right');
    });
}
} // <-- End of populateAircraftInfoWindow

/**
 * --- [UPDATED] Updates the Navigation Data Panel ---
 */
function updateNavPanelData(lat, lon, heading, oat, windDir, windSpd) {
    // 1. Update Coordinates (Clean formatting)
    const latEl = document.getElementById('ac-lat');
    const lonEl = document.getElementById('ac-lon');
    
    // Use toFixed(3) to save space and prevent "falling out"
    if (latEl) latEl.textContent = lat.toFixed(3);
    if (lonEl) lonEl.textContent = lon.toFixed(3);

    // 1b. Heading — previously this argument was passed in but never displayed.
    if (heading != null && !isNaN(heading)) {
        const hdgInt = Math.round(((heading % 360) + 360) % 360);
        document.querySelectorAll('#ac-heading').forEach(el => {
            el.textContent = `${String(hdgInt).padStart(3, '0')}°`;
        });
    }

    // 2. Update Environment
    const windEl = document.getElementById('ac-env-wind');
    const oatEl = document.getElementById('ac-env-oat');
    
    // Format: 270 / 15
    if (windEl) windEl.textContent = `${String(windDir).padStart(3, '0')}° / ${windSpd}`;
    if (oatEl) oatEl.textContent = `${oat}°C`;

    // 3. Nearest Airport Logic (Unchanged, just targets)
    if (airportsData && Object.keys(airportsData).length > 0) {
        let nearestICAO = '---';
        let minDist = Infinity;
        
        // Optimization: Only check airports within ~2 degrees lat/lon
        for (const icao in airportsData) {
            const apt = airportsData[icao];
            if (!apt || apt.lat == null || apt.lon == null) continue;

            const latDiff = Math.abs(apt.lat - lat);
            const lonDiff = Math.abs(apt.lon - lon);

            if (latDiff > 2 || lonDiff > 2) continue;

            const dist = getDistanceKm(lat, lon, apt.lat, apt.lon);
            if (dist < minDist) {
                minDist = dist;
                nearestICAO = icao;
            }
        }

        const nearestEl = document.getElementById('ac-nearest-apt');
        const nearestDistEl = document.getElementById('ac-nearest-apt-dist');
        
        if (nearestEl && minDist !== Infinity) {
            nearestEl.textContent = nearestICAO;
            const distNM = (minDist / 1.852).toFixed(1);
            // The "NM" unit is rendered as a sibling <span> in the markup, so write only the number.
            nearestDistEl.textContent = distNM;
        }
    }
}

function updateSeatSensor(flightProps) {
    const seatCpt = document.getElementById('seat-cpt');
    const seatFo = document.getElementById('seat-fo');
    const statusCpt = document.getElementById('status-cpt-text');
    const statusFo = document.getElementById('status-fo-text');
    const narrative = document.getElementById('seat-narrative-text');
    
    // Overlays
    const parkingOverlay = document.getElementById('icon-parking-overlay');
    const coffeeOverlay = document.getElementById('icon-coffee-overlay');
    const cloudOverlay = document.getElementById('icon-cloud-overlay');

    if (!seatCpt || !seatFo) return;

    // 1. DETERMINE STATE
    // Default to 0 (Active) if undefined
    let state = flightProps.pilotState !== undefined ? flightProps.pilotState : 0;

    // 2. RESET VISUALS
    // Remove all active color classes
    seatCpt.classList.remove('active-green', 'active-amber', 'active-blue');
    seatFo.classList.remove('active-green', 'active-amber', 'active-blue');
    
    // Reset pills
    statusCpt.className = 'status-pill';
    statusFo.className = 'status-pill';
    
    // Hide all overlays
    if(parkingOverlay) parkingOverlay.classList.remove('visible');
    if(coffeeOverlay) coffeeOverlay.classList.remove('visible');
    if(cloudOverlay) cloudOverlay.classList.remove('visible');

    // Reset Narrative Display
    if(narrative) narrative.style.display = 'block';

    // 3. APPLY LOGIC
    switch (state) {
        case 0: // ACTIVE
            seatCpt.classList.add('active-green');
            
            statusCpt.classList.add('green');
            statusCpt.textContent = 'CMD: PILOT';
            
            statusFo.textContent = 'FO: MONITOR';
            
            narrative.textContent = "Manual inputs detected. Pilot has controls.";
            break;

        case 1: // AWAY (IN FLIGHT) - Monitoring
            seatCpt.classList.add('active-amber');
            
            statusCpt.classList.add('amber');
            statusCpt.textContent = 'CMD: AUTO';
            
            statusFo.textContent = 'FO: MONITOR';
            
            if(coffeeOverlay) coffeeOverlay.classList.add('visible');
            narrative.textContent = "No recent inputs. Pilot is monitoring cruise systems.";
            break;

        case 2: // AWAY (PARKED) - Secured
            // Seats remain dark/grey (no active class)
            
            statusCpt.classList.add('red'); // Use red border/text for park brake
            statusCpt.textContent = 'PARK BRK: SET';
            statusCpt.style.width = '100%'; // Span full width
            statusCpt.style.textAlign = 'center';
            
            statusFo.style.display = 'none'; // Hide FO pill in this specific state
            
            if(parkingOverlay) parkingOverlay.classList.add('visible');
            narrative.textContent = "Cockpit secured. Parking brake set.";
            break;

        case 3: // BACKGROUND - Relief Pilot / Rest
            seatFo.classList.add('active-blue');
            
            statusCpt.textContent = 'CMD: REST';
            
            statusFo.classList.add('blue');
            statusFo.textContent = 'FO: ACTIVE';
            
            if(cloudOverlay) cloudOverlay.classList.add('visible');
            
            // [MODIFIED] Removed the "Relief Pilot" text and hid the element to push content up
            if(narrative) {
                narrative.textContent = ""; 
                narrative.style.display = 'none';
            }
            break;

        default:
            narrative.textContent = "No telemetry data available.";
            break;
    }

    // Restore FO display if not in state 2
    if (state !== 2) {
        statusFo.style.display = 'block';
        statusCpt.style.width = 'auto';
        statusCpt.style.textAlign = 'left';
    }
}

/**
 * --- [SPICED UP v3.0] Renders the Pilot Report with enhanced typography 
 * and dynamic styling for high-ranking controllers.
 */
function renderPilotStatsHTML(stats, username) {
    if (!stats) return '<p class="error-text">Could not load pilot statistics.</p>';

    // --- ATC Rank Logic ---
    const atcRankId = stats.atcRank;
    const atcRankMap = { 
        0: 'Observer', 1: 'Trainee', 2: 'Apprentice', 
        3: 'Specialist', 4: 'Officer', 5: 'Supervisor', 
        6: 'Recruiter', 7: 'Manager' 
    };
    const atcRankName = atcRankId in atcRankMap ? atcRankMap[atcRankId] : 'N/A';
    
    // Determine "Spice" level for Controllers
    let spiceClass = '';
    let spiceIcon = '<i class="fa-solid fa-headset"></i>';
    if (atcRankId === 3) { spiceClass = 'atc-specialist'; spiceIcon = '<i class="fa-solid fa-star-of-life"></i>'; }
    if (atcRankId === 4) { spiceClass = 'atc-officer'; spiceIcon = '<i class="fa-solid fa-shield-halved"></i>'; }
    if (atcRankId === 5) { spiceClass = 'atc-supervisor'; spiceIcon = '<i class="fa-solid fa-crown"></i>'; }

    // --- KPI Extraction ---
    const currentGradeIndex = stats.gradeDetails?.gradeIndex;
    const currentGrade = stats.gradeDetails?.grades?.[currentGradeIndex];
    const nextGrade = stats.gradeDetails?.grades?.[currentGradeIndex + 1];
    
    const kpis = {
        grade: currentGrade?.name.replace('Grade ', '') || 'N/A',
        xp: (stats.totalXP || 0).toLocaleString(),
        atcRank: atcRankName,
        totalViolations: (stats.violationCountByLevel?.level1 || 0) + 
                         (stats.violationCountByLevel?.level2 || 0) + 
                         (stats.violationCountByLevel?.level3 || 0)
    };

    // Helper for progression cards
    const createProgressCard = (title, gradeData) => {
        if (!gradeData) return `<div class="progress-card complete"><h4><i class="fa-solid fa-crown"></i> Max Grade</h4></div>`;
        const reqXp = gradeData.rules.find(r => r.definition?.name === 'XP')?.referenceValue || 0;
        const xpProgress = reqXp > 0 ? Math.min(100, (stats.totalXP / reqXp) * 100) : 100;
        return `
            <div class="progress-card">
                <h4>${title}</h4>
                <div class="progress-item">
                    <div class="progress-label"><span>XP</span><span>${kpis.xp} / ${reqXp.toLocaleString()}</span></div>
                    <div class="progress-bar-bg"><div class="progress-bar-fg" style="width: ${xpProgress}%"></div></div>
                </div>
            </div>`;
    };

    return `
    <div class="stats-rehaul-container ${spiceClass}">
        <div class="stats-hero">
            <div class="hero-left">
                <span class="hero-rank-tag">${spiceIcon} ${kpis.atcRank}</span>
                <h2 class="hero-username">${username}</h2>
                <a href="https://community.infiniteflight.com/u/${username}/summary" target="_blank" class="hero-profile-link">
                    COMMUNITY PROFILE <i class="fa-solid fa-external-link"></i>
                </a>
            </div>
            <div class="hero-right">
                <div class="grade-badge">
                    <span class="grade-label">GRADE</span>
                    <span class="grade-val">${kpis.grade}</span>
                </div>
            </div>
        </div>

        <div class="spiced-kpi-grid">
            <div class="kpi-card">
                <span class="kpi-label">TOTAL EXPERIENCE</span>
                <span class="kpi-value">${kpis.xp} <small>XP</small></span>
            </div>
            <div class="kpi-card">
                <span class="kpi-label">VIOLATIONS</span>
                <span class="kpi-value ${kpis.totalViolations > 0 ? 'warn' : ''}">${kpis.totalViolations}</span>
            </div>
        </div>

        <div class="stats-accordion">
            <div class="accordion-item active">
                <button class="accordion-header">
                    <span><i class="fa-solid fa-chart-line"></i> PROGRESSION</span>
                    <i class="fa-solid fa-chevron-down toggle-icon"></i>
                </button>
                <div class="accordion-content" style="max-height: 500px;">
                    <div class="progression-container">
                        ${createProgressCard(`CURRENT: GRADE ${kpis.grade}`, currentGrade)}
                        ${nextGrade ? createProgressCard(`NEXT: GRADE ${nextGrade.name.replace('Grade ', '')}`, nextGrade) : ''}
                    </div>
                </div>
            </div>
        </div>
    </div>
    `;
}

// --- [NEW & FIXED] Fetches and displays the pilot stats, and attaches its own event listeners ---
    async function displayPilotStats(userId, username) {
        if (!userId) return;

        // Get the containers
        // const statsPane = document.getElementById('ac-tab-pilot-report'); // No longer needed
        // const flightPane = document.getElementById('ac-tab-flight-data'); // No longer needed
        const statsDisplay = document.getElementById('pilot-stats-display');
        
        if (!statsDisplay) return;

        // Show loading spinner in stats panel
        statsDisplay.innerHTML = `<div class="spinner-small" style="margin: 2rem auto;"></div><p style="text-align: center;">Loading pilot report for ${username}...</p>`;
        
        // --- [REMOVED] Toggle visibility ---
        // flightPane.classList.remove('active');
        // statsPane.classList.add('active');

        try {
            const res = await fetch(`${ACARS_USER_API_URL.replace('/users', '/api/users')}/${userId}/stats`);
            if (!res.ok) throw new Error('Could not fetch pilot data.');

            const data = await res.json();
            const pilotStats = data.stats || data.gradeInfo;
            if (data.ok && pilotStats) {
                statsDisplay.innerHTML = renderPilotStatsHTML(pilotStats, username);
                
                // --- Accordion event listeners ---
                const accordionHeaders = statsDisplay.querySelectorAll('.accordion-header');
                accordionHeaders.forEach(header => {
                    header.addEventListener('click', () => {
                        const item = header.closest('.accordion-item');
                        const content = header.nextElementSibling;
                        const isExpanded = item.classList.contains('active');
                        
                        item.classList.toggle('active');

                        if (isExpanded) {
                            content.style.maxHeight = null;
                        } else {
                            content.style.maxHeight = content.scrollHeight + 'px';
                        }
                    });
                });

                // The main delegate in setupAircraftWindowEvents will catch the back button click
                
            } else {
                throw new Error('Pilot data not found or invalid.');
            }
        } catch (error) {
            console.error('Error fetching pilot stats:', error);
            // [MODIFIED] Removed back button from error message
            statsDisplay.innerHTML = `<div class="stats-rehaul-container">
                <p class="error-text">${error.message}</p>
            </div>`;
        }
    }



/**
 * --- [SHARED] Detailed flying-state / phase detection. ---
 * Single source of truth for the 15+ flight phases (PUSHBACK, TAXIING,
 * HOLDING SHORT, LINED UP, TAKEOFF ROLL, LIFTOFF, CLIMB, CRUISE, DESCENT,
 * APPROACH, FINAL, FLARE, LANDING ROLLOUT, …). Both the full avionics window
 * and the simple flight-info window call this so they always report the same
 * state instead of the simple window's old 4-state guess.
 * @returns {{flightPhase:string, phaseClass:string, phaseIcon:string}}
 */
function computeDetailedFlightPhase(baseProps, plan, sortedRoutePoints, progress, distanceToDestNM, totalDistanceNM, hasPlan) {
    let flightPhase = 'ENROUTE';
    let phaseClass = 'phase-enroute';
    let phaseIcon = 'fa-route';

    if (!baseProps || !baseProps.position) {
        return { flightPhase, phaseClass, phaseIcon };
    }

    const vs = baseProps.position.vs_fpm || 0;
    const altitude = baseProps.position.alt_ft || 0;
    const gs = baseProps.position.gs_kt || 0;

    let departureIcao = null;
    let arrivalIcao = null;

    if (plan && Array.isArray(plan.flightPlanItems) && plan.flightPlanItems.length >= 2) {
        departureIcao = plan.flightPlanItems[0]?.identifier?.trim().toUpperCase();
        arrivalIcao = plan.flightPlanItems[plan.flightPlanItems.length - 1]?.identifier?.trim().toUpperCase();
    }

    const aircraftPos = { lat: baseProps.position.lat, lon: baseProps.position.lon, heading_deg: baseProps.position.heading_deg };
    let nearestRunwayInfo = null;

    if (hasPlan) {
        const distanceFlownKm = totalDistanceNM * 1.852 - distanceToDestNM * 1.852;
        if (distanceToDestNM * 1.852 < distanceFlownKm && arrivalIcao) {
            nearestRunwayInfo = getNearestRunway(aircraftPos, arrivalIcao, 1.5);
        } else if (departureIcao) {
            nearestRunwayInfo = getNearestRunway(aircraftPos, departureIcao, 1.5);
        }
    }

    let altitudeAGL = null;
    if (nearestRunwayInfo && nearestRunwayInfo.elevation_ft != null) {
        altitudeAGL = altitude - nearestRunwayInfo.elevation_ft;
    } else {
        const originElevationFt = (plan?.origin?.elevation_ft) ? parseFloat(plan.origin.elevation_ft) : null;
        const destElevationFt = (plan?.destination?.elevation_ft) ? parseFloat(plan.destination.elevation_ft) : null;
        const relevantElevationFt = (totalDistanceNM > 0 && distanceToDestNM < totalDistanceNM / 2) ? destElevationFt : originElevationFt;
        if (relevantElevationFt !== null) {
            altitudeAGL = altitude - relevantElevationFt;
        }
    }

    const aglCheck = altitudeAGL !== null && altitudeAGL < 75;
    const fallbackGroundCheck = altitudeAGL === null && gs < 35 && Math.abs(vs) < 150;
    const isOnGround = aglCheck || fallbackGroundCheck;
    const isLinedUpForLanding = nearestRunwayInfo && nearestRunwayInfo.airport === arrivalIcao && nearestRunwayInfo.headingDiff < 10;

    if (isOnGround) {
        if (gs > 35) {
            if (progress > 90) {
                flightPhase = 'LANDING ROLLOUT';
                phaseClass = 'phase-approach';
                phaseIcon = 'fa-plane-arrival';
            } else if (progress < 10) {
                flightPhase = 'TAKEOFF ROLL';
                phaseClass = 'phase-climb';
                phaseIcon = 'fa-plane-departure';
            } else {
                flightPhase = 'HIGH-SPEED TAXI';
                phaseIcon = 'fa-road';
                phaseClass = 'phase-enroute';
            }
        } else {
            const isStopped = gs <= 2.0;
            const isAtTerminal = (progress < 2) || (progress > 98);
            const relevantIcao = progress < 50 ? departureIcao : arrivalIcao;
            const closeRunwayInfo = getNearestRunway(aircraftPos, relevantIcao, 0.15);
            const isLinedUp = closeRunwayInfo && closeRunwayInfo.headingDiff < 10;

            // --- PUSHBACK DETECTION ---
            // Look at the flown path: if the aircraft is moving slowly at the start
            // of its route and recent travel is roughly opposite to its heading
            // (tug pushing tail-first), it's pushing back from the gate.
            let isPushingBack = false;
            if (progress < 10 && gs > 0.3 && gs < 10 && hasPlan && !closeRunwayInfo &&
                sortedRoutePoints && sortedRoutePoints.length >= 2) {

                const lastPoint = sortedRoutePoints[sortedRoutePoints.length - 1];
                // Reference a point a few samples back to smooth GPS jitter at low speeds
                const refIdx = Math.max(0, sortedRoutePoints.length - 4);
                const refPoint = sortedRoutePoints[refIdx];
                const lastLat = lastPoint.lat ?? lastPoint.latitude;
                const lastLon = lastPoint.lon ?? lastPoint.longitude;
                const refLat = refPoint.lat ?? refPoint.latitude;
                const refLon = refPoint.lon ?? refPoint.longitude;

                if (lastLat != null && refLat != null && refIdx !== sortedRoutePoints.length - 1) {
                    const recentDistKm = getDistanceKm(refLat, refLon, lastLat, lastLon);
                    // Require a meaningful displacement (>1m) to trust the bearing
                    if (recentDistKm > 0.001) {
                        const movementBearing = getBearing(refLat, refLon, lastLat, lastLon);
                        const heading = baseProps.position.heading_deg || 0;
                        const bearingDiff = Math.abs(normalizeBearingDiff(heading - movementBearing));
                        // Moving roughly opposite to where the nose is pointing
                        if (bearingDiff > 120) isPushingBack = true;
                    }
                }
            }

            if (isLinedUp) {
                flightPhase = `LINED UP RWY ${closeRunwayInfo.ident}`;
                phaseIcon = 'fa-arrow-up';
                phaseClass = 'phase-climb';
            } else if (isPushingBack) {
                flightPhase = 'PUSHBACK';
                phaseIcon = 'fa-truck';
                phaseClass = 'phase-enroute';
            } else if (isStopped) {
                if (closeRunwayInfo) {
                    flightPhase = `HOLDING SHORT RWY ${closeRunwayInfo.ident}`;
                    phaseIcon = 'fa-pause-circle';
                    phaseClass = 'phase-enroute';
                } else if (isAtTerminal) {
                    if (progress < 50 && hasPlan) {
                        flightPhase = 'BOARDING';
                        phaseIcon = 'fa-door-open';
                    } else {
                        flightPhase = 'PARKED';
                        phaseIcon = 'fa-parking';
                    }
                    phaseClass = 'phase-enroute';
                } else {
                    flightPhase = 'HOLDING POSITION';
                    phaseIcon = 'fa-hand';
                    phaseClass = 'phase-enroute';
                }
            } else {
                flightPhase = 'TAXIING';
                phaseIcon = 'fa-road';
                phaseClass = 'phase-enroute';
                if (progress > 50) {
                    flightPhase = 'TAXIING TO GATE';
                } else if (progress < 10) {
                    flightPhase = 'TAXIING TO RUNWAY';
                }
            }
        }
    } else {
        const isInLandingSequence = isLinedUpForLanding && altitudeAGL !== null;

        if (isInLandingSequence && altitudeAGL < 2500) {
            if (altitudeAGL < 60 && vs < -50) {
                flightPhase = 'FLARE';
            } else if (altitudeAGL < 500) {
                flightPhase = 'SHORT FINAL';
            } else {
                flightPhase = 'FINAL APPROACH';
            }
            phaseClass = 'phase-approach';
            phaseIcon = 'fa-plane-arrival';
        } else if (hasPlan && distanceToDestNM < 40 && progress > 5) {
            flightPhase = 'APPROACH';
            phaseClass = 'phase-approach';
            phaseIcon = 'fa-plane-arrival';
        } else if (vs > 300) {
            flightPhase = 'CLIMB';
            phaseClass = 'phase-climb';
            phaseIcon = 'fa-arrow-trend-up';
            if (progress < 10 && altitudeAGL !== null && altitudeAGL < 1500) {
                flightPhase = 'LIFTOFF';
                phaseIcon = 'fa-plane-up';
            }
        } else if (vs < -500) {
            flightPhase = 'DESCENT';
            phaseClass = 'phase-descent';
            phaseIcon = 'fa-arrow-trend-down';
        } else if (altitude > 18000 && Math.abs(vs) < 500) {
            flightPhase = 'CRUISE';
            phaseClass = 'phase-cruise';
            phaseIcon = 'fa-minus';
        }
    }

    return { flightPhase, phaseClass, phaseIcon };
}

function updateAircraftInfoWindow(baseProps, plan, sortedRoutePoints) {
    const updateAll = (selector, value, isHTML = false) => {
        const elements = document.querySelectorAll(selector);
        elements.forEach(el => {
            if (isHTML) {
                el.innerHTML = value;
            } else {
                el.textContent = value;
            }
        });
    };

    const styleAll = (selector, property, value) => {
        const elements = document.querySelectorAll(selector);
        elements.forEach(el => {
            el.style[property] = value;
        });
    };

    const originalFlatWaypoints = (plan && plan.flightPlanItems) ? flattenWaypointsFromPlan(plan.flightPlanItems) : [];
    const originalFlatWaypointObjects = (plan && plan.flightPlanItems) ? getFlatWaypointObjects(plan.flightPlanItems) : [];
    const hasPlan = originalFlatWaypoints.length >= 2;

    let progress = 0, ete = '--:--', distanceToDestNM = 0;
    let totalDistanceNM = 0;
    let nextWpName = '---', nextWpDistNM = '---';

    if (hasPlan) {
        let totalDistanceKm = 0;
        for (let i = 0; i < originalFlatWaypoints.length - 1; i++) {
            const [lon1, lat1] = originalFlatWaypoints[i];
            const [lon2, lat2] = originalFlatWaypoints[i + 1];
            totalDistanceKm += getDistanceKm(lat1, lon1, lat2, lon2);
        }
        totalDistanceNM = totalDistanceKm / 1.852;

        if (totalDistanceNM > 0) {
            const [destLon, destLat] = originalFlatWaypoints[originalFlatWaypoints.length - 1];
            const remainingDistanceKm = getDistanceKm(baseProps.position.lat, baseProps.position.lon, destLat, destLon);
            distanceToDestNM = remainingDistanceKm / 1.852;
            
            // Use direct distance from origin to destination to fix the sluggish scaling
            const [originLon, originLat] = originalFlatWaypoints[0];
            const totalDirectDistanceNM = getDistanceKm(originLat, originLon, destLat, destLon) / 1.852;
            const scaleDist = totalDirectDistanceNM > 0 ? totalDirectDistanceNM : totalDistanceNM;

            progress = Math.max(0, Math.min(100, (1 - (distanceToDestNM / scaleDist)) * 100));

            if (baseProps.position.gs_kt > 50) {
                const timeHours = distanceToDestNM / baseProps.position.gs_kt;
                const hours = Math.floor(timeHours);
                const minutes = Math.round((timeHours - hours) * 60);
                ete = `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
            }

            let minScore = Infinity;
            const currentTrack = baseProps.position.heading_deg;
            for (let i = 1; i < originalFlatWaypointObjects.length; i++) {
                const wp = originalFlatWaypointObjects[i];
                if (!wp.location) continue;
                
                const distanceToWpKm = getDistanceKm(baseProps.position.lat, baseProps.position.lon, wp.location.latitude, wp.location.longitude);
                const bearingToWp = getBearing(baseProps.position.lat, baseProps.position.lon, wp.location.latitude, wp.location.longitude);
                const bearingDiff = Math.abs(normalizeBearingDiff(currentTrack - bearingToWp));
                
                if (bearingDiff <= 95 && distanceToWpKm < minScore) {
                    minScore = distanceToWpKm;
                    nextWpName = wp.identifier || wp.name || 'N/A';
                    nextWpDistNM = (minScore / 1.852).toFixed(1);
                }
            }

            if (nextWpName === '---' && distanceToDestNM < 10) {
                nextWpName = "DEST";
                nextWpDistNM = distanceToDestNM.toFixed(1);
            }
        }
    }

    updateAll('#ac-next-wp', nextWpName);
    updateAll('#ac-next-wp-dist', `${nextWpDistNM === '---' ? '--.-' : nextWpDistNM}`, false);
    updateAll('#ac-dist', `${Math.round(distanceToDestNM)}<span class="unit">NM</span>`, true);
    updateAll('#ac-ete', ete);

    // The Live Activity push used to live here, but it was computing
    // its own ETA / ATD with a broken fallback ("now + 1h" when the
    // aircraft was slow) and a typo (filedPlanData.departureTime — the
    // real field is dep_time). It now lives below, after the same
    // SCHEDULED/ACTUAL/ESTIMATED cascade the in-app card consumes, so
    // the lock screen and the card always agree.

    // --- New nav-card live readouts (heading / G·S / TAS / ALT / ALT Δ) ---
    {
        const _gs = baseProps.position.gs_kt || 0;
        const _alt = baseProps.position.alt_ft || 0;
        const _hdg = baseProps.position.heading_deg;
        const _vs = baseProps.position.vs_fpm || 0;
        const _oat_c = (typeof currentAircraftPositionForGeocode !== 'undefined' && currentAircraftPositionForGeocode)
            ? (currentAircraftPositionForGeocode.oat_c ?? 15)
            : 15;
        const _tas = (typeof calculateTas === 'function') ? calculateTas(_alt, _oat_c, _gs) : Math.round(_gs);

        if (_hdg != null && !isNaN(_hdg)) {
            updateAll('#ac-heading', `${String(Math.round(((_hdg % 360) + 360) % 360)).padStart(3, '0')}°`);
        }
        updateAll('#ac-gs', `${Math.round(_gs)} <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">kt</span>`, true);
        updateAll('#ac-tas', `${Math.round(_tas)} <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">kt</span>`, true);
        updateAll('#ac-alt', `${Math.round(_alt).toLocaleString()} <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">ft</span>`, true);

        // V/S — always live, independent of whether a flight plan is loaded.
        const _vsArrow = _vs > 100 ? '▲' : _vs < -100 ? '▼' : '·';
        const _vsColor = _vs > 100 ? '#4ade80' : _vs < -100 ? '#fbbf24' : '#94a3b8';
        const _vsSign = _vs > 0 ? '+' : '';
        updateAll('#ac-vs',
            `<span style="color: ${_vsColor};">${_vsArrow}</span> ${_vsSign}${Math.round(_vs).toLocaleString()} <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">fpm</span>`,
            true);

        // ALT delta vs cached cruise target
        const _windowEl2 = document.getElementById('aircraft-info-window');
        const _cruiseAlt = (_windowEl2 && _windowEl2.dataset.cruiseAltFt)
            ? parseFloat(_windowEl2.dataset.cruiseAltFt) : null;
        if (_cruiseAlt && _cruiseAlt > 0) {
            const _delta = Math.round(_alt - _cruiseAlt);
            const _arrow = _delta > 50 ? '▲' : _delta < -50 ? '▼' : '·';
            const _color = _delta > 50 ? '#fbbf24' : _delta < -50 ? '#fbbf24' : '#4ade80';
            const _sign = _delta > 0 ? '+' : '';
            const _txt = `<span style="color: ${_color};">${_arrow}</span> ${_sign}${Math.abs(_delta) >= 1000 ? (_delta / 1000).toFixed(1) + 'k' : _delta} <span style="font-size: 9px; color: #94a3b8; font-weight: 600;">ft</span>`;
            updateAll('#ac-alt-delta', _txt, true);
        } else {
            updateAll('#ac-alt-delta', '---', false);
        }
    }

    const altitude = baseProps.position.alt_ft || 0;

    let departureIcao = null;
    let arrivalIcao = null;

    if (plan && Array.isArray(plan.flightPlanItems) && plan.flightPlanItems.length >= 2) {
        departureIcao = plan.flightPlanItems[0]?.identifier?.trim().toUpperCase();
        arrivalIcao = plan.flightPlanItems[plan.flightPlanItems.length - 1]?.identifier?.trim().toUpperCase();
    }

    // Detailed flying-state detection is shared with the simple flight-info
    // window (see computeDetailedFlightPhase) so both surfaces report the same
    // phase rather than diverging.
    let { flightPhase, phaseClass, phaseIcon } = computeDetailedFlightPhase(
        baseProps, plan, sortedRoutePoints, progress, distanceToDestNM, totalDistanceNM, hasPlan
    );

    const vsdPanels = document.querySelectorAll('#vsd-panel');
    const planId = (plan && (plan.flightPlanId || plan.id)) || 'unknown';

    vsdPanels.forEach(vsdPanel => {
        if (!hasPlan) return;

        const vsdAircraftIcon = vsdPanel.querySelector('#vsd-aircraft-icon');
        const vsdGraphWindow = vsdPanel.querySelector('#vsd-graph-window');
        const vsdGraphContent = vsdPanel.querySelector('#vsd-graph-content');
        const vsdProfilePath = vsdPanel.querySelector('#vsd-profile-path');
        const vsdFlownPath = vsdPanel.querySelector('#vsd-flown-path');
        const vsdWpLabels = vsdPanel.querySelector('#vsd-waypoint-labels');

        if (!vsdGraphContent || !vsdAircraftIcon) return;

        const VSD_HEIGHT_PX = vsdGraphContent.clientHeight || 210;
        const MAX_ALT_FT = 45000;
        const Y_SCALE_PX_PER_FT = VSD_HEIGHT_PX / MAX_ALT_FT;
        const FIXED_X_SCALE_PX_PER_NM = 4;

        if (vsdPanel.dataset.profileBuilt !== 'true' || vsdPanel.dataset.planId !== planId) {
            let flatWaypointObjects = JSON.parse(JSON.stringify(originalFlatWaypointObjects));

            if (flatWaypointObjects.length > 0) {
                let cumulativeNM = 0;
                for(let i = 0; i < flatWaypointObjects.length; i++) {
                    if(i > 0) {
                        cumulativeNM += getDistanceKm(flatWaypointObjects[i-1].location.latitude, flatWaypointObjects[i-1].location.longitude, flatWaypointObjects[i].location.latitude, flatWaypointObjects[i].location.longitude) / 1.852;
                    }
                    flatWaypointObjects[i].cumulativeNM = cumulativeNM;
                }

                const lastIdx = flatWaypointObjects.length - 1;
                if (flatWaypointObjects[0].altitude == null) {
                    flatWaypointObjects[0].altitude = plan?.origin?.elevation_ft || 0;
                }
                if (flatWaypointObjects[lastIdx].altitude == null) {
                    const prevAlt = (lastIdx > 0) ? flatWaypointObjects[lastIdx - 1]?.altitude : null;
                    flatWaypointObjects[lastIdx].altitude = (prevAlt != null) ? prevAlt : (plan?.destination?.elevation_ft || 0);
                }

                for (let i = 1; i < lastIdx; i++) {
                    const wp = flatWaypointObjects[i];
                    if (wp.altitude == null || (typeof wp.altitude === 'number' && wp.altitude <= 0)) {
                        wp.altitude = null;
                    }
                }

                let lastValidAltIndex = 0;
                for (let i = 1; i < flatWaypointObjects.length; i++) {
                    const wp = flatWaypointObjects[i];
                    if (wp.altitude != null && typeof wp.altitude === 'number') {
                        if (i > lastValidAltIndex + 1) {
                            const gapStartIndex = lastValidAltIndex;
                            const gapEndIndex = i;
                            const startAlt = flatWaypointObjects[gapStartIndex].altitude;
                            const endAlt = flatWaypointObjects[gapEndIndex].altitude;
                            const numStepsInGap = gapEndIndex - gapStartIndex;

                            for (let j = 1; j < numStepsInGap; j++) {
                                const stepIndex = gapStartIndex + j;
                                const fraction = j / numStepsInGap;
                                const interpolatedAlt = startAlt + (endAlt - startAlt) * fraction;
                                flatWaypointObjects[stepIndex].altitude = Math.round(interpolatedAlt);
                            }
                        }
                        lastValidAltIndex = i;
                    }
                }
            }

            if (vsdGraphWindow && !vsdGraphWindow.querySelector('#vsd-y-axis')) {
                let yAxisHtml = '<div id="vsd-y-axis">';
                const altLabels = [10000, 20000, 30000, 40000];
                for (const alt of altLabels) {
                    const yPos = VSD_HEIGHT_PX - (alt * Y_SCALE_PX_PER_FT);
                    yAxisHtml += `<div class="y-axis-label" style="top: ${yPos}px;">${alt / 1000}K</div>`;
                }
                yAxisHtml += '</div>';
                vsdGraphWindow.insertAdjacentHTML('afterbegin', yAxisHtml);
            }

            let path_d = "";
            let labels_html = "";
            let current_x_px = 0;
            let last_label_x_px = -1000;
            let stagger_level = 0;
            const MIN_LABEL_SPACING_PX = 80;

            if (flatWaypointObjects.length > 0) {
                for (let i = 0; i < flatWaypointObjects.length; i++) {
                    const wp = flatWaypointObjects[i];
                    const wpAltFt = (typeof wp.altitude === 'number' && !isNaN(wp.altitude)) ? wp.altitude : 0;
                    const wpAltPx = VSD_HEIGHT_PX - (wpAltFt * Y_SCALE_PX_PER_FT);
                    const cumulativeNM = (typeof wp.cumulativeNM === 'number' && !isNaN(wp.cumulativeNM)) ? wp.cumulativeNM : 0;
                    
                    current_x_px = cumulativeNM * FIXED_X_SCALE_PX_PER_NM;
                    const safeX = isNaN(current_x_px) ? 0 : current_x_px;
                    const safeY = isNaN(wpAltPx) ? 0 : wpAltPx;

                    if (i === 0) {
                        path_d = `M ${safeX} ${safeY}`;
                    } else {
                        path_d += ` L ${safeX} ${safeY}`;
                    }

                    let label_top_px;
                    let label_class = '';
                    if (current_x_px - last_label_x_px < MIN_LABEL_SPACING_PX) {
                        stagger_level = 1 - stagger_level;
                    } else {
                        stagger_level = 0;
                    }

                    if (stagger_level === 1) {
                        label_class = 'low-label';
                        label_top_px = safeY + 12;
                    } else {
                        label_class = 'high-label';
                        label_top_px = safeY - 42;
                    }
                    last_label_x_px = current_x_px;

                    labels_html += `
                    <div class="vsd-wp-label ${label_class}" style="left: ${safeX}px; top: ${label_top_px}px;">
                        <span class="wp-name">${wp.identifier || 'WPT'}</span>
                        <span class="wp-alt">${Math.round(wpAltFt)}ft</span>
                    </div>`;
                }
                vsdGraphContent.style.width = `${current_x_px + 100}px`;
                vsdProfilePath.closest('svg').style.width = `${current_x_px + 100}px`;
                vsdProfilePath.setAttribute('d', path_d);
                vsdWpLabels.innerHTML = labels_html;
                vsdPanel.dataset.profileBuilt = 'true';
                vsdPanel.dataset.planId = planId;
            }
        }

        if (vsdFlownPath && hasPlan && originalFlatWaypointObjects.length > 0) {
            let flown_path_d = "";
            let lastFlownLat, lastFlownLon;
            let currentFlightRoutePoints = [...sortedRoutePoints];

            const originLat = plan?.origin?.latitude;
            const originLon = plan?.origin?.longitude;

            if (originLat != null && originLon != null && sortedRoutePoints.length > 10) {
                let startIndex = -1;
                for (let i = sortedRoutePoints.length - 1; i > 0; i--) {
                    const point = sortedRoutePoints[i];
                    if (!point.latitude || !point.longitude || point.altitude == null) continue;
                    const distKm = getDistanceKm(point.latitude, point.longitude, originLat, originLon);
                    if (point.altitude < 1000 && distKm < 25) {
                        startIndex = i;
                        break;
                    }
                }
                if (startIndex !== -1) {
                    currentFlightRoutePoints = sortedRoutePoints.slice(startIndex);
                }
            }

            const fullFlownRoute = [];
            if (currentFlightRoutePoints && currentFlightRoutePoints.length > 0) {
                fullFlownRoute.push(...currentFlightRoutePoints);
                lastFlownLat = currentFlightRoutePoints[0].latitude;
                lastFlownLon = currentFlightRoutePoints[0].longitude;
            }
            fullFlownRoute.push({
                latitude: baseProps.position.lat,
                longitude: baseProps.position.lon,
                altitude: baseProps.position.alt_ft,
                groundSpeed: baseProps.position.gs_kt
            });

            const flownPathPoints = [];
            let totalActualFlownNM = 0;

            if (fullFlownRoute.length > 0) {
                if (!lastFlownLat) {
                    lastFlownLat = fullFlownRoute[0].latitude;
                    lastFlownLon = fullFlownRoute[0].longitude;
                }

                const startAltFt = originalFlatWaypointObjects[0]?.altitude || fullFlownRoute[0].altitude;
                const startAltPx = VSD_HEIGHT_PX - (startAltFt * Y_SCALE_PX_PER_FT);

                for (let i = 0; i < fullFlownRoute.length; i++) {
                    const point = fullFlownRoute[i];
                    const wpAltFt = typeof point.altitude === 'number' ? point.altitude : 0;
                    const wpAltPx = VSD_HEIGHT_PX - (wpAltFt * Y_SCALE_PX_PER_FT);
                    const wpLat = point.latitude;
                    const wpLon = point.longitude;

                    let segmentDistNM = 0;
                    if (i > 0) {
                        segmentDistNM = getDistanceKm(lastFlownLat, lastFlownLon, wpLat, wpLon) / 1.852;
                    }
                    totalActualFlownNM += segmentDistNM;

                    flownPathPoints.push({
                        x_nm: totalActualFlownNM,
                        y_px_alt: wpAltPx
                    });

                    lastFlownLat = wpLat;
                    lastFlownLon = wpLon;
                }

                const safePlannedProgressNM = totalDistanceNM - distanceToDestNM;
                const safeTotalActualFlownNM = (typeof totalActualFlownNM === 'number' && !isNaN(totalActualFlownNM)) ? totalActualFlownNM : 0;
                const scaleFactor = (safeTotalActualFlownNM > 0.1 && safePlannedProgressNM > 0.01) ? (safePlannedProgressNM / safeTotalActualFlownNM) : 1;
                const safeScaleFactor = isNaN(scaleFactor) ? 1 : scaleFactor;

                for (let i = 0; i < flownPathPoints.length; i++) {
                    const point = flownPathPoints[i];
                    const safeXNm = (typeof point.x_nm === 'number' && !isNaN(point.x_nm)) ? point.x_nm : 0;
                    const safeYPxAlt = (typeof point.y_px_alt === 'number' && !isNaN(point.y_px_alt)) ? point.y_px_alt : VSD_HEIGHT_PX;

                    const scaled_x_px = safeXNm * safeScaleFactor * FIXED_X_SCALE_PX_PER_NM;
                    const finalX = isNaN(scaled_x_px) ? 0 : scaled_x_px;

                    if (i === 0) {
                        const safeStartAltPx = isNaN(startAltPx) ? VSD_HEIGHT_PX : startAltPx;
                        flown_path_d = `M 0 ${safeStartAltPx}`;
                        if (flownPathPoints.length === 1) {
                            flown_path_d += ` L ${finalX} ${safeYPxAlt}`;
                        }
                    } else {
                        flown_path_d += ` L ${finalX} ${safeYPxAlt}`;
                    }
                }
                vsdFlownPath.setAttribute('d', flown_path_d);
            }
        }

        const safeAltitude = (typeof altitude === 'number' && !isNaN(altitude)) ? altitude : 0;
        const currentAltPx = VSD_HEIGHT_PX - (safeAltitude * Y_SCALE_PX_PER_FT);
        vsdAircraftIcon.style.top = `${isNaN(currentAltPx) ? 0 : currentAltPx}px`;

        if (vsdGraphWindow && vsdGraphWindow.clientWidth > 0) {
            const distanceFlownNM = Math.max(0, totalDistanceNM - distanceToDestNM);
            const scrollOffsetPx = (distanceFlownNM * FIXED_X_SCALE_PX_PER_NM);
            const vsdViewportWidth = vsdGraphWindow.clientWidth;
            const totalProfileWidthPx = vsdGraphContent.scrollWidth;

            const centerOffset = (vsdViewportWidth / 2) + 35;
            const desiredTranslateX = centerOffset - scrollOffsetPx;
            const maxTranslateX = 0;
            const minTranslateX = Math.min(0, vsdViewportWidth - totalProfileWidthPx);

            const finalTranslateX = Math.max(minTranslateX, Math.min(maxTranslateX, desiredTranslateX));

            vsdGraphContent.style.transform = `translateX(${isNaN(finalTranslateX) ? 0 : finalTranslateX - 35}px)`;

            const iconLeftPx = scrollOffsetPx + finalTranslateX;
            vsdAircraftIcon.style.left = `${isNaN(iconLeftPx) ? 0 : iconLeftPx}px`;
        } else {
            const distanceFlownNM = Math.max(0, totalDistanceNM - distanceToDestNM);
            const scrollOffsetPx = (distanceFlownNM * FIXED_X_SCALE_PX_PER_NM);
            const translateX = 75 - scrollOffsetPx;
            vsdGraphContent.style.transform = `translateX(${isNaN(translateX) ? 0 : translateX - 35}px)`;
            vsdAircraftIcon.style.left = `75px`;
        }

        // Note: #ac-vs is now updated centrally in the live readouts block above so the
        // formatting stays consistent across the nav/VSD card. We keep this hook in case
        // future code re-introduces a VSD-specific V/S display.
    });

    const flightDataTabContainer = document.getElementById('ac-tab-flight-data');
    
    // Check if the user is Pro (replace with your actual auth/pro flag logic)
    // Assuming true for implementation testing
    const isProUser = true; 

    if (flightDataTabContainer && isProUser) {
        // Because populateAircraftInfoWindow resets innerHTML, we must re-init the layout engine
        // to re-apply the grid orders and sizes to the freshly generated DOM nodes.
    
    }

    styleAll('#ac-progress-bar', 'width', `${progress.toFixed(1)}%`);
    updateAll('#ac-phase-indicator', `<i class="fa-solid ${phaseIcon}"></i> ${flightPhase}`, true);

    const phaseIndicators = document.querySelectorAll('#ac-phase-indicator');
    phaseIndicators.forEach(el => {
        el.className = `flight-phase-indicator ${phaseClass}`;
    });

    // --- Update floating route bar phase badge (text + dot color) ---
    let badgeStatusColor = '#4ade80'; // default green
    let badgeStatusPulse = 'pulse';
    if (flightPhase.includes('CRUISE')) badgeStatusColor = '#38bdf8';
    else if (flightPhase.includes('DESCENT') || flightPhase.includes('APPROACH') || flightPhase.includes('FINAL') || flightPhase.includes('FLARE') || flightPhase.includes('LANDING')) badgeStatusColor = '#fbbf24';
    else if (flightPhase.includes('PUSHBACK')) badgeStatusColor = '#fb923c'; // orange, pulsing (transition out of gate)
    else if (flightPhase.includes('BOARDING')) badgeStatusColor = '#4ade80'; // green, pulsing (active prep)
    else if (flightPhase.includes('CLIMB') || flightPhase.includes('LIFTOFF') || flightPhase.includes('TAKEOFF')) badgeStatusColor = '#4ade80';
    else if (flightPhase.includes('GROUND') || flightPhase.includes('PARKED') || flightPhase.includes('TAXI') || flightPhase.includes('HOLDING')) {
        badgeStatusColor = '#94a3b8';
        badgeStatusPulse = 'none';
    }

    document.querySelectorAll('#ac-phase-text').forEach(el => {
        el.textContent = flightPhase;
    });
    document.querySelectorAll('#ac-phase-dot').forEach(el => {
        el.style.background = badgeStatusColor;
        el.style.boxShadow = `0 0 8px ${badgeStatusColor}`;
        el.style.animation = badgeStatusPulse === 'none' ? 'none' : `${badgeStatusPulse} 2s infinite`;
    });
    // VSD card phase chip — color tracks the same palette as the route-bar phase badge
    document.querySelectorAll('#ac-vsd-phase').forEach(el => {
        el.textContent = flightPhase;
        el.style.color = badgeStatusColor;
    });

    const atdTimestamp = (sortedRoutePoints && sortedRoutePoints.length > 0) ? sortedRoutePoints[0].date : null;
    const atdTime = atdTimestamp ? formatTimeFromTimestamp(atdTimestamp) : '--:--';

    // --- Source-aware time updates (SCHEDULED / ACTUAL / ESTIMATED) ---
    // updateAircraftInfoWindow doesn't receive filedPlanData directly, so we read it from
    // the cache that populateAircraftInfoWindow stashed on the window element.
    const _windowEl = document.getElementById('aircraft-info-window');
    const _cachedFiledPlan = (_windowEl && _windowEl.dataset.filedDepTime) ? {
        dep_time: _windowEl.dataset.filedDepTime,
        duration_minutes: _windowEl.dataset.filedDuration ? parseFloat(_windowEl.dataset.filedDuration) : null
    } : null;
    const _depIcaoLive = (_windowEl && _windowEl.dataset.depIcao) || departureIcao || '';
    const _arrIcaoLive = (_windowEl && _windowEl.dataset.arrIcao) || arrivalIcao || '';

    const _depInfoLive = computeDepartureTimeInfo(baseProps, sortedRoutePoints, _cachedFiledPlan, _depIcaoLive);
    const _arrInfoLive = computeArrivalTimeInfo(baseProps, _cachedFiledPlan, distanceToDestNM);

    // --- Live Activity push (iOS Lock Screen / Dynamic Island) ---
    // Fires only when the user has marked this flight as "mine" via the
    // bell button. We reuse the same SCHEDULED/ACTUAL/ESTIMATED cascade
    // the in-app card just consumed (_depInfoLive / _arrInfoLive), so
    // the lock-screen ETE countdown agrees with the card and the
    // departure time only shows ACTUAL once we have real GPS history.
    try {
        if (window.InflightLiveActivity?.isTrackingFlight(baseProps.flightId)) {
            const _gsLA = baseProps.position?.gs_kt || 0;
            const etaMs = _arrInfoLive?.timestamp
                ? _arrInfoLive.timestamp.getTime()
                : (distanceToDestNM > 0 && _gsLA > 50
                    ? Date.now() + (distanceToDestNM / _gsLA) * 3600 * 1000
                    : null);
            // ATD only counts when we have real GPS history (label
            // ACTUAL). Otherwise leave it undefined so the widget shows
            // the scheduled departure verbatim instead of pretending
            // we know the takeoff time.
            const atdMs = (_depInfoLive?.timestamp && _depInfoLive.label === 'ACTUAL')
                ? _depInfoLive.timestamp.getTime()
                : undefined;
            const isLanded = !!(baseProps.position?.alt_ft != null && baseProps.position.alt_ft < 100
                                && _gsLA < 40 && distanceToDestNM < 5);
            // Bail without an update if we genuinely have no ETA value
            // to send. The Swift `update` defaults a missing ETA to
            // Date.now(), which would zero out the lock-screen
            // countdown ("0 min remaining") -- much worse than just
            // skipping a tick.
            if (etaMs) {
                window.InflightLiveActivity.update({
                    flightId: baseProps.flightId,
                    currentEta: etaMs,
                    currentAtd: atdMs,
                    distanceToDestinationNm: distanceToDestNM,
                    isLanded
                });
            }
            if (isLanded) {
                setTimeout(() => {
                    window.InflightLiveActivity?.end({ flightId: baseProps.flightId, immediate: false });
                }, 30000);
            }
        }
    } catch (laErr) {
        console.warn('[LiveActivity] update tick failed:', laErr);
    }

    const depCountryCode = airportsData[departureIcao]?.country ? airportsData[departureIcao].country.toLowerCase() : '';
    const arrCountryCode = airportsData[arrivalIcao]?.country ? airportsData[arrivalIcao].country.toLowerCase() : '';
    const depFlagSrc = depCountryCode ? `https://flagcdn.com/w20/${depCountryCode}.png` : '';
    const arrFlagSrc = arrCountryCode ? `https://flagcdn.com/w20/${arrCountryCode}.png` : '';

    applyRouteTimeInfoToDom('atd', _depInfoLive);
    applyRouteTimeInfoToDom('eta', _arrInfoLive);
    
    document.querySelectorAll('#ac-bar-dep-flag').forEach(el => {
        el.src = depFlagSrc;
        el.alt = depCountryCode;
        el.style.display = depCountryCode ? 'block' : 'none';
    });

    document.querySelectorAll('#ac-bar-arr-flag').forEach(el => {
        el.src = arrFlagSrc;
        el.alt = arrCountryCode;
        el.style.display = arrCountryCode ? 'block' : 'none';
    });

    updateFmsLegsModule(plan, baseProps.position);
    updateSeatSensor(baseProps);

    const rulesDisplay = document.getElementById('flight-rules-display');
        if (rulesDisplay) {
            if (typeof determineFlightRules === 'function') {
                const rule = determineFlightRules(baseProps, plan);
                rulesDisplay.className = `flight-rules-badge ${rule.class}`;
                rulesDisplay.innerHTML = `<i class="fa-solid ${rule.icon}"></i> ${rule.label}`;
            } else {
                console.warn("determineFlightRules helper missing.");
                rulesDisplay.textContent = "RULES UNKNOWN";
            }
        }

        const routeBar = document.querySelector('.ac-route-info-bar');
        if (routeBar) {
            const depNode = routeBar.querySelector('.route-node:not(.end)');
            const arrNode = routeBar.querySelector('.route-node.end');
            
            if (depNode && !document.getElementById('ac-dep-gate')) {
                depNode.style.display = 'flex';
                depNode.style.flexDirection = 'column';
                const depGateEl = document.createElement('span');
                depGateEl.id = 'ac-dep-gate';
                depGateEl.style.cssText = 'color: #cbd5e1; font-size: 10px; font-weight: 700; margin-top: 4px; background: rgba(0,0,0,0.2); padding: 2px 6px; border-radius: 4px; width: fit-content; display: inline-block;';
                depGateEl.innerHTML = '<i class="fa-solid fa-door-open"></i> Loading...';
                depNode.appendChild(depGateEl);
            }
            
            if (arrNode && !document.getElementById('ac-arr-gate')) {
                arrNode.style.display = 'flex';
                arrNode.style.flexDirection = 'column';
                arrNode.style.alignItems = 'flex-end';
                const arrGateEl = document.createElement('span');
                arrGateEl.id = 'ac-arr-gate';
                arrGateEl.style.cssText = 'color: #cbd5e1; font-size: 10px; font-weight: 700; margin-top: 4px; background: rgba(0,0,0,0.2); padding: 2px 6px; border-radius: 4px; width: fit-content; display: inline-block;';
                arrGateEl.innerHTML = '<i class="fa-solid fa-door-closed"></i> Loading...';
                arrNode.appendChild(arrGateEl);
            }
        }
    }

function updateFmsLegsModule(plan, currentPos) {
    const listContainer = document.getElementById('fms-legs-list');
    const totalDistEl = document.getElementById('fms-total-dist');
    const totalEteEl = document.getElementById('fms-total-ete');
    
    if (!listContainer) return;

    // 1. Basic Validation
    if (!plan || !plan.flightPlanItems || plan.flightPlanItems.length === 0) {
        listContainer.innerHTML = '<div class="fms-empty-state">NO ROUTE LOADED</div>';
        if(totalDistEl) totalDistEl.textContent = '---- NM';
        if(totalEteEl) totalEteEl.textContent = '--:--';
        return;
    }

    // --- Capture current scroll position ---
    const previousScrollTop = listContainer.scrollTop;

    let html = '';
    let globalLeafIndex = 0; // Tracks index of actual flyable waypoints
    
    // Find the "Active" waypoint index
    const flatWaypoints = getFlatWaypointObjects(plan.flightPlanItems);
    let activeWpIndex = 0;
    let minDist = Infinity;
    
    if (currentPos && flatWaypoints.length > 0) {
        flatWaypoints.forEach((wp, idx) => {
            if (!wp.location) return;
            const d = getDistanceKm(currentPos.lat, currentPos.lon, wp.location.latitude, wp.location.longitude);
            if (d < minDist) {
                minDist = d;
                activeWpIndex = idx;
            }
        });
    }

    // Track previous coords for Distance/Bearing calc
    let prevLat = (plan.origin && plan.origin.latitude) || currentPos.lat;
    let prevLon = (plan.origin && plan.origin.longitude) || currentPos.lon;

    // --- MAIN LOOP: Iterate the Top-Level Items ---
    plan.flightPlanItems.forEach((item, index) => {
        const hasChildren = Array.isArray(item.children) && item.children.length > 0;
        
        // --- 2. HEADER LOGIC (SID/STAR/APPR detection) ---
        if (hasChildren) {
            let typeTag = 'PROC'; 
            let typeClass = '';
            const ident = (item.identifier || item.name || '').toUpperCase();
            
            // A. SID Logic (Start of plan)
            if (index <= 1) { 
                typeTag = 'SID'; 
                typeClass = 'sid';
            } 
            // B. Approach Logic (Pattern match or explicit type)
            else {
                // Regex: Starts with exactly 1 Letter [A-Z], followed by 2 digits \d{2}, 
                // optionally followed by L, R, or C.
                const isApproachPattern = /^[A-Z]\d{2}[LRC]?$/.test(ident);

                if (isApproachPattern) {
                    typeTag = 'APPR';
                    typeClass = 'appr';
                } else {
                    typeTag = 'STAR'; 
                    typeClass = 'star';
                }
            }

            // Render The Header Row
            html += `
                <div class="fms-proc-header">
                    <span class="proc-tag ${typeClass}">${typeTag}</span>
                    <span>${ident}</span>
                </div>
            `;

            // --- 3. CHILDREN LOOP (With isLast detection) ---
            item.children.forEach((child, cIdx) => {
                const isLast = cIdx === item.children.length - 1;
                html += renderLegRow(child, true, isLast); 
            });

        } else {
            // --- 4. STANDARD ROW ---
            html += renderLegRow(item, false, false);
        }
    });

    // --- Helper to Render a Single Waypoint Row ---
    function renderLegRow(wp, isChild, isLastChild) {
        if (!wp.location || wp.location.latitude == null) return '';

        // Calc Leg Data
        const distKm = getDistanceKm(prevLat, prevLon, wp.location.latitude, wp.location.longitude);
        const distNM = distKm / 1.852;
        const bearing = getBearing(prevLat, prevLon, wp.location.latitude, wp.location.longitude);

        // Determine Row State
        let rowClass = '';
        if (globalLeafIndex < activeWpIndex) rowClass = 'passed-leg';
        else if (globalLeafIndex === activeWpIndex) rowClass = 'active-leg';
        
        const ident = wp.identifier || wp.name || 'WPT';
        const crsDisplay = Math.round(bearing).toString().padStart(3, '0') + '°';
        const distDisplay = distNM.toFixed(1);

        // Update Prev coords for next loop
        prevLat = wp.location.latitude;
        prevLon = wp.location.longitude;

        globalLeafIndex++;
        
        // --- NEW: Add is-last-child class if applicable ---
        const childClasses = isChild ? `is-child ${isLastChild ? 'is-last-child' : ''}` : '';

        return `
            <div class="fms-row ${rowClass} ${childClasses}" id="leg-${globalLeafIndex}">
                <span class="col-wpt">${ident}</span>
                <span class="col-data text-center">${crsDisplay}</span>
                <span class="col-data text-right">${distDisplay}</span>
            </div>
        `;
    }

    listContainer.innerHTML = html;

    // --- Restore scroll position ---
    if (previousScrollTop > 0) {
        listContainer.scrollTop = previousScrollTop;
    }

    // --- [FIXED] Scroll Active Leg into View (ONCE) without scrolling parent window ---
    if (listContainer.dataset.initialScrollComplete !== 'true') {
        setTimeout(() => {
            const activeRow = listContainer.querySelector('.active-leg');
            if (activeRow) {
                // Calculate position manually to avoid 'scrollIntoView' bubbling up to the main window
                const rowTop = activeRow.offsetTop;
                const rowHeight = activeRow.offsetHeight;
                const containerHeight = listContainer.clientHeight;
                
                // Center the row: Row Top - Half Container + Half Row
                listContainer.scrollTo({
                    top: rowTop - (containerHeight / 2) + (rowHeight / 2),
                    behavior: 'smooth'
                });

                listContainer.dataset.initialScrollComplete = 'true';
            }
        }, 100);
    }

    // --- Footer Stats ---
    if(totalDistEl && document.getElementById('ac-dist')) {
        totalDistEl.innerHTML = document.getElementById('ac-dist').innerHTML;
    }
    if(totalEteEl && document.getElementById('ac-ete')) {
        totalEteEl.textContent = document.getElementById('ac-ete').textContent;
    }

    // --- Speed & Altitude history graph (drawn from the /history breadcrumbs) ---
    // Lazily injected into the Flight Display tab so we never touch the giant
    // window template literal; re-rendered whenever the trail length changes.
    if (typeof FlightGraph !== 'undefined' && FlightGraph) {
        const tabPane = document.querySelector('#ac-tab-flight-data');
        if (tabPane) {
            if (!document.getElementById('ac-sa-graph-card')) {
                const cardHTML =
                    '<div id="ac-sa-graph-card" style="margin:8px 0;background:rgba(15,23,42,0.4);border:1px solid rgba(255,255,255,0.05);border-radius:12px;padding:12px;overflow:hidden;">'
                    + '<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;color:#cbd5e1;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.6px;"><i class="fa-solid fa-chart-area" style="color:#38bdf8;"></i> Speed &amp; Altitude</div>'
                    + '<div id="ac-sa-graph"></div></div>';
                // Place it directly under the PFD/location row so it sits in view
                // rather than below the long tail of the pane.
                const anchor = tabPane.querySelector('.pfd-and-location-grid');
                if (anchor) anchor.insertAdjacentHTML('afterend', cardHTML);
                else tabPane.insertAdjacentHTML('afterbegin', cardHTML);
            }
            const graphHost = document.getElementById('ac-sa-graph');
            const ptsLen = (sortedRoutePoints && sortedRoutePoints.length) || 0;
            if (graphHost && (graphHost.dataset.pts !== String(ptsLen) || !graphHost.firstChild)) {
                FlightGraph.render(graphHost, sortedRoutePoints, { height: 190 });
                graphHost.dataset.pts = String(ptsLen);
            }
        }
    }
}

    /**
     * (NEW) Clears old routes and draws all new routes originating from a selected airport.
     */
    function plotRoutesFromAirport(departureICAO) {
        clearRouteLayers(); // Clear only the lines, not the airport markers

        const departureAirport = airportsData[departureICAO];
        if (!departureAirport) return;

        const departureCoords = [departureAirport.lon, departureAirport.lat];
        const routesFromHub = ALL_AVAILABLE_ROUTES.filter(r => r.departure === departureICAO);

        if (routesFromHub.length === 0) {
            return;
        }

        // Create line features for each route
        const routeLineFeatures = routesFromHub.map(route => {
            const arrivalAirport = airportsData[route.arrival];
            if (arrivalAirport) {
                return {
                    type: 'Feature',
                    geometry: {
                        type: 'LineString',
                        coordinates: [departureCoords, [arrivalAirport.lon, arrivalAirport.lat]]
                    }
                };
            }
            return null;
        }).filter(Boolean); // Filter out any routes with missing arrival data

        const routeLinesId = `routes-from-${departureICAO}`;
        sectorOpsMap.addSource(routeLinesId, {
            type: 'geojson',
            data: { type: 'FeatureCollection', features: routeLineFeatures }
        });

        sectorOpsMap.addLayer({
            id: routeLinesId,
            type: 'line',
            source: routeLinesId,
            paint: {
                'line-color': '#00a8ff', // A bright blue for visibility
                'line-width': 2,
                'line-opacity': 0.8
            }
        });

        sectorOpsMapRouteLayers.push(routeLinesId); // Track the new layer for cleanup

        // Fly to the selected airport
        sectorOpsMap.flyTo({
            center: departureCoords,
            zoom: 5,
            essential: true
        });
    }

function setupSectorOpsEventListeners() {
    const panel = document.getElementById('sector-ops-floating-panel');
    if (!panel || panel.dataset.listenersAttached === 'true') return;
    panel.dataset.listenersAttached = 'true';

    // Initialize Flight Hover Popups
    setupFlightHoverPopups();

    // --- Toolbar and Panel Toggle ---
    const internalToggleBtn = document.getElementById('sector-ops-toggle-btn');
    const toolbarToggleBtn = document.getElementById('toolbar-toggle-panel-btn');
    
    const togglePanel = () => {
        const isNowVisible = panel.classList.toggle('visible');
        if (internalToggleBtn) internalToggleBtn.setAttribute('aria-expanded', isNowVisible);
        if (toolbarToggleBtn) toolbarToggleBtn.classList.toggle('active', isNowVisible);
        if (sectorOpsMap) {
            setTimeout(() => { sectorOpsMap.resize(); }, 400);
        }
    };

    if (internalToggleBtn) internalToggleBtn.addEventListener('click', togglePanel);
    if (toolbarToggleBtn) toolbarToggleBtn.addEventListener('click', togglePanel);

    // --- Weather Settings ---
    const openWeatherBtn = document.getElementById('open-weather-settings-btn');
    if (openWeatherBtn) {
        openWeatherBtn.addEventListener('click', () => {
            if (weatherSettingsWindow) {
                const isVisible = weatherSettingsWindow.classList.toggle('visible');
                if (isVisible && typeof MobileUIHandler !== 'undefined') MobileUIHandler.openWindow(weatherSettingsWindow);
            }
        });
    }

    // --- 3D Traffic Toggle ---
    // Swaps the flat plane icons for the elevated 3D dot field and back.
    const live3dBtn = document.getElementById('live-3d-toggle-btn');
    if (live3dBtn) {
        live3dBtn.classList.toggle('active', !!mapFilters.live3DTraffic);
        live3dBtn.addEventListener('click', () => {
            setLive3DTraffic(!LiveTraffic3D.isVisible());
        });
    }

    // --- Filter Settings ---
    // NOTE: The gear button (#open-filter-settings-btn) is now wired up exclusively
    // by SettingsUI.init() to open the new global settings modal. The legacy
    // floating panel (#filter-settings-window) used to be toggled here, but having
    // two click handlers on the same button caused the legacy panel to pop up
    // on top of (or instead of) the new modal — that's why settings appeared
    // not to open. Binding intentionally removed.

    const unstaffedToggle = document.getElementById('filter-toggle-unstaffed');
    if (unstaffedToggle) {
        unstaffedToggle.addEventListener('change', (e) => {
            mapFilters.showUnstaffedAirports = e.target.checked;
            saveFiltersToLocalStorage();
            renderAirportMarkers(); // Refresh the map immediately
        });
    }

    // --- Server Selector ---
    const serverBtns = document.querySelectorAll('.server-btn');
    serverBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            switchServer(btn.dataset.server);
        });
    });
}

function setupFlightHoverPopups() {
    if (!sectorOpsMap) return;

    const hoverPopup = new mapboxgl.Popup({
        closeButton: false,
        closeOnClick: false,
        offset: 15,
        maxWidth: 'none',
        className: 'flight-hover-popup'
    });

    let hoveredFlightId = null;

    const onAircraftRichHover = (e) => {
        const isHoverDevice = window.matchMedia('(hover: hover)').matches;
        if (!isHoverDevice || (e.originalEvent && e.originalEvent.pointerType === 'touch')) {
            return;
        }

        sectorOpsMap.getCanvas().style.cursor = 'pointer';
        const feature = e.features[0];
        const props = feature.properties;

        // Data Parsing
        const acData = props.aircraft ? JSON.parse(props.aircraft) : {};
        const callsign = props.callsign || '---';
        const username = props.username || 'Unknown';
        const depIcao = props.departureIcao || '---';
        const arrIcao = props.arrivalIcao || '---';
        
        const imgUrl = props.communityImageUrl || '/CommunityPlanes/default.png';
        const credit = props.contributorName || 'IF Community';
        const alt = Math.round(props.altitude || 0).toLocaleString();
        const gs = Math.round(props.speed || 0);

        // --- Calculate Route Progress ---
        let progressPercent = 0;
        if (depIcao !== '---' && arrIcao !== '---') {
            const depData = typeof airportsData !== 'undefined' ? airportsData[depIcao] : null;
            const arrData = typeof airportsData !== 'undefined' ? airportsData[arrIcao] : null;
            
            if (depData && arrData && props.position) {
                try {
                    const pos = JSON.parse(props.position);
                    const totalDist = getDistanceKm(depData.lat, depData.lon, arrData.lat, arrData.lon);
                    const remainingDist = getDistanceKm(pos.lat, pos.lon, arrData.lat, arrData.lon);
                    
                    if (totalDist > 0) {
                        progressPercent = Math.max(0, Math.min(100, (1 - (remainingDist / totalDist)) * 100));
                    }
                } catch(err) {
                    console.warn("Failed to calculate hover progress");
                }
            }
        }
        
        // Clamp visually so the icon doesn't overflow the container edges completely
        const displayPercent = Math.max(2, Math.min(98, progressPercent));

        // Logo Generation
        const livName = acData.liveryName || '';
        const words = livName.trim().split(/\s+/);
        let logoName = words.length > 1 && /[^a-zA-Z0-9]/.test(words[1]) ? words[0] : (words[0] + (words[1] ? ' ' + words[1] : ''));
        const sanitizedLogoName = logoName.toLowerCase().replace(/[^a-z0-9\s]/g, '').replace(/\s+/g, '_');
        const logoPath = `Images/airline_logos/${sanitizedLogoName}.png`;

        const html = `
            <div class="fr24-card-container">
                <div class="fr24-image-box" style="background-image: url('${imgUrl}')">
                    <div class="fr24-image-overlay"></div>
                    <div class="fr24-copyright">© ${credit}</div>
                </div>
                
                <div class="fr24-info-box">
                    <div class="fr24-header-row" style="margin-bottom: 2px;">
                        <img src="${logoPath}" class="fr24-airline-logo" onerror="this.style.display='none'">
                        <div class="fr24-ident-group">
                            <span class="fr24-callsign">${callsign}</span>
                        </div>
                        <span style="margin-left: auto; font-size: 8.5px; color: #38bdf8; font-weight: 800; text-transform: uppercase; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 65px;" title="${username}">
                            ${username}
                        </span>
                    </div>
                    
                    <div class="fr24-route-premium" style="display: flex; align-items: center; justify-content: space-between; gap: 10px; margin: 8px 0 6px 0;">
                        <span style="font-family: 'JetBrains Mono', monospace; font-weight: 800; font-size: 10.5px; color: #f8fafc; letter-spacing: 0.5px;">${depIcao}</span>
                        
                        <div style="flex-grow: 1; height: 2px; background: rgba(255, 255, 255, 0.1); border-radius: 2px; position: relative; display: flex; align-items: center;">
                            <div style="position: absolute; left: 0; top: 0; height: 100%; background: linear-gradient(90deg, rgba(56,189,248,0.1) 0%, #38bdf8 100%); width: ${displayPercent}%; border-radius: 2px; box-shadow: 0 0 6px rgba(56, 189, 248, 0.5);"></div>
                            
                            <svg style="position: absolute; left: ${displayPercent}%; transform: translateX(-50%); filter: drop-shadow(0 1px 3px rgba(0,0,0,0.8)); z-index: 2;" width="12" height="12" viewBox="0 0 24 24" fill="#ffffff" xmlns="http://www.w3.org/2000/svg">
                                <path d="M2 2L22 12L2 22L6 12L2 2Z" fill="#ffffff"/>
                            </svg>
                        </div>
                        
                        <span style="font-family: 'JetBrains Mono', monospace; font-weight: 800; font-size: 10.5px; color: #94a3b8; letter-spacing: 0.5px;">${arrIcao}</span>
                    </div>
                    
                    <div class="fr24-stats-row" style="display: flex; justify-content: space-between;">
                        <span><i class="fa-solid fa-arrow-up-right-dots" style="font-size: 8px; margin-right: 3px;"></i>${alt} <span style="font-size:8px;">FT</span></span>
                        <span><i class="fa-solid fa-gauge-high" style="font-size: 8px; margin-right: 3px;"></i>${gs} <span style="font-size:8px;">KTS</span></span>
                    </div>
                </div>
            </div>
        `;

        hoverPopup.setLngLat(feature.geometry.coordinates).setHTML(html).addTo(sectorOpsMap);
    };
    sectorOpsMap.on('mouseenter', 'sector-ops-live-flights-layer', onAircraftRichHover);
    sectorOpsMap.on('mouseenter', 'sector-ops-live-flights-natural-layer', onAircraftRichHover);

    const onAircraftRichLeave = () => {
        sectorOpsMap.getCanvas().style.cursor = '';
        hoverPopup.remove();
    };
    sectorOpsMap.on('mouseleave', 'sector-ops-live-flights-layer', onAircraftRichLeave);
    sectorOpsMap.on('mouseleave', 'sector-ops-live-flights-natural-layer', onAircraftRichLeave);
}

/**
 * --- [UPDATED] Handles messages from the Simple Flight Window Iframe ---
 * Now includes logic to parse raw API data into the format flightinfo.html expects.
 */
async function handleIframeMessage(event) {
    // 1. ND Ready Check (Existing)
    if (event.data && event.data.type === 'ND_READY') {
        refreshNavDisplayFromCache();
        return;
    }

    // 2. Flight Data Update (Existing Loopback - ignored here)
    if (event.data && event.data.type === 'FLIGHT_DATA_UPDATE') {
        return;
    }

    // 2a. [NEW] Simple Window expand/collapse — resize the host container.
    if (event.data && event.data.type === 'SIMPLE_WINDOW_STATE') {
        applySimpleWindowPhase(event.data.state);
        return;
    }

    // 2b. [NEW] Simple Window action buttons (replay / trip card / follow).
    if (event.data && event.data.type === 'SIMPLE_WINDOW_ACTION') {
        handleSimpleWindowAction(event.data.action);
        return;
    }

    // 2b-ii. [NEW] Simple Window peek-size customization. The chosen peek
    // preset reports the height its collapsed bar wants; size the host (desktop)
    // or the mobile sheet detent to match so the bar isn't clipped or padded.
    if (event.data && event.data.type === 'SIMPLE_WINDOW_PEEK_HEIGHT') {
        const h = Math.max(120, Math.min(parseInt(event.data.height, 10) || 236, 900));
        window.__simpleWindowPeekHeight = h;
        const onMobile = !!(window.MobileUIHandler && typeof window.MobileUIHandler.isMobile === 'function'
            && window.MobileUIHandler.isMobile());
        if (onMobile && window.MobileUIHandler && typeof window.MobileUIHandler.setSimplePeekHeight === 'function') {
            window.MobileUIHandler.setSimplePeekHeight(h);
        } else {
            // Desktop: only resize while collapsed; the expanded panel owns its own size.
            const w = document.getElementById('aircraft-info-window');
            if (w && w.classList.contains('simple-collapsed')) {
                w.style.height = h + 'px';
                w.style.maxHeight = h + 'px';
            }
        }
        return;
    }

    // 2b-iii. [NEW] Simple Window layout-edit mode — lock the mobile sheet drag
    // so rearranging blocks inside the iframe doesn't drag the sheet itself.
    if (event.data && event.data.type === 'SIMPLE_WINDOW_EDIT_MODE') {
        if (window.MobileUIHandler && typeof window.MobileUIHandler.setEditLock === 'function') {
            window.MobileUIHandler.setEditLock(!!event.data.active);
        }
        return;
    }

    // 2c. [NEW] Tapping an ICAO in the simple flight window jumps to that airport.
    if (event.data && event.data.type === 'NAVIGATE_TO_AIRPORT') {
        const icao = event.data.icao;
        if (icao && typeof handleAirportClick === 'function') handleAirportClick(icao, null, true);
        return;
    }

    // 3. [UPDATED] Handle Stats Request
    if (event.data && event.data.type === 'REQUEST_PILOT_STATS') {
        const iframe = document.getElementById('simple-flight-window-frame');
        if (!iframe || !iframe.contentWindow) return;

        // Get the current user ID from the active flight
        if (!currentFlightInWindow || !currentMapFeatures[currentFlightInWindow]) {
            iframe.contentWindow.postMessage({
                type: 'PILOT_STATS_ERROR',
                message: 'No active flight selected.'
            }, '*');
            return;
        }

        const props = currentMapFeatures[currentFlightInWindow].properties;
        const userId = props.userId;
        const username = props.username;

        if (!userId) {
            iframe.contentWindow.postMessage({
                type: 'PILOT_STATS_ERROR',
                message: 'User ID not available.'
            }, '*');
            return;
        }

        try {
            // Use the global API URL defined at top of file
            // Note: ACARS_USER_API_URL must be defined in your global scope (it is in your file: '.../users')
            const res = await fetch(`${ACARS_USER_API_URL.replace('/users', '/api/users')}/${userId}/stats`);

            if (!res.ok) throw new Error('Failed to fetch pilot grade.');

            const data = await res.json();
            const pilotStats = data.stats || data.gradeInfo;

            if (data.ok && pilotStats) {
                // Process the raw IF API data into the UI-ready format
                const formattedProfile = processRawPilotData(pilotStats);

                // Thread the pilot identity through so the manifest can show the
                // username + Community profile link, mirroring the profile UI.
                if (formattedProfile && username) {
                    formattedProfile.username = username;
                    formattedProfile.communityUrl = `https://community.infiniteflight.com/u/${username}/summary`;
                }

                // Send the specific payload structure expected by flightinfo.html
                iframe.contentWindow.postMessage({
                    type: 'PILOT_STATS_DATA',
                    payload: {
                        profile: formattedProfile
                    }
                }, '*');
            } else {
                throw new Error('Invalid data format received from server.');
            }

        } catch (error) {
            console.error("Iframe Stats Fetch Error:", error);
            iframe.contentWindow.postMessage({
                type: 'PILOT_STATS_ERROR',
                message: 'Could not load pilot statistics.'
            }, '*');
        }
    }
}

/**
 * --- [NEW HELPER] Processes Raw Infinite Flight Grade Data for the UI ---
 * Maps complex rule definitions into simple progress bars.
 */
function processRawPilotData(gradeInfo) {
    if (!gradeInfo) return null;

    // Helper to extract specific rule values safely
    const getRule = (rules, name) => {
        if (!Array.isArray(rules)) return null;
        return rules.find(r => r.definition && r.definition.name === name);
    };

    const currentGradeIdx = gradeInfo.gradeDetails?.gradeIndex || 0;
    const gradesList = gradeInfo.gradeDetails?.grades || [];
    const currentGradeObj = gradesList[currentGradeIdx];
    const nextGradeObj = gradesList[currentGradeIdx + 1]; // Can be undefined if max grade

    // 1. Basic Stats
    const totalXP = gradeInfo.totalXP || 0;
    const violations = gradeInfo.violationCountByLevel || { level1: 0, level2: 0, level3: 0 };
    const totalViolations = (violations.level1 || 0) + (violations.level2 || 0) + (violations.level3 || 0);
    
    // Map ATC Rank ID to Name
    const atcRankMap = { 0: 'Observer', 1: 'Trainee', 2: 'Apprentice', 3: 'Specialist', 4: 'Officer', 5: 'Supervisor', 6: 'Recruiter', 7: 'Manager' };
    const atcRankName = atcRankMap[gradeInfo.atcRank] || 'Observer';

    // 2. Build Progression Array
    // We compare current stats against the requirements for the NEXT grade.
    // If max grade, we just show current stats vs current requirements.
    const targetGrade = nextGradeObj || currentGradeObj;
    const progression = [];

    if (targetGrade && Array.isArray(targetGrade.rules)) {
        
        // A. XP Progression
        const xpRule = getRule(targetGrade.rules, 'XP');
        if (xpRule) {
            progression.push({
                label: 'Total XP',
                current: totalXP,
                target: xpRule.referenceValue,
                type: 'ACCUMULATE'
            });
        }

        // B. Landing Count (90 Days)
        const landingsRule = getRule(targetGrade.rules, 'Landings (90 days)');
        if (landingsRule) {
            progression.push({
                label: 'Landings (90d)',
                current: landingsRule.userValue, // The API provides the user's current value here
                target: landingsRule.referenceValue,
                type: 'ACCUMULATE'
            });
        }

        // C. Flight Time (90 Days)
        const timeRule = getRule(targetGrade.rules, 'Flight Time (90 days)');
        if (timeRule) {
            progression.push({
                label: 'Flight Time (90d)',
                // Convert minutes to hours for display, usually API sends minutes
                current: Math.floor(timeRule.userValue / 60), 
                target: Math.floor(timeRule.referenceValue / 60),
                type: 'ACCUMULATE'
            });
        }

        // D. Violation Limits (Level 2/3 in 1 year) - Inverse logic (Max Limit)
        const vioRule = getRule(targetGrade.rules, 'All Level 2/3 Violations (1 year)');
        if (vioRule) {
            progression.push({
                label: 'Violations (1yr)',
                current: gradeInfo.total12MonthsViolations || 0,
                target: vioRule.referenceValue, // This is a MAX limit
                type: 'MAX_LIMIT'
            });
        }
    }

    return {
        grade: currentGradeObj && currentGradeObj.name ? currentGradeObj.name.replace('Grade ', '') : `${currentGradeIdx + 1}`,
        xp: totalXP,
        atcRank: atcRankName,
        virtualAirline: gradeInfo.virtualAirline || 'N/A',
        totalViolations: totalViolations,
        violationDetails: violations,
        lastViolationDate: gradeInfo.lastLevel1ViolationDate ? new Date(gradeInfo.lastLevel1ViolationDate).toLocaleDateString() : 'None',
        flightTime90: 'N/A', // Calculated in progression
        landings90: 'N/A',   // Calculated in progression
        progression: progression
    };
}

/**
     * --- [NEW] Smart Map Background Click Handler ---
     * Closes the flight window when clicking the map background.
     * Distinguishes between a "Click" ( < 5px movement) and a "Map Pan/Drag" ( > 5px movement).
     */
    function setupSmartMapBackgroundClick() {
        if (!sectorOpsMap) return;

        let startPoint = null;

        // 1. Record position when mouse/finger goes DOWN
        sectorOpsMap.on('mousedown', (e) => {
            startPoint = e.point;
        });
        
        // 2. Handle Touch devices (touchstart)
        sectorOpsMap.on('touchstart', (e) => {
            startPoint = e.point;
        });

        // 3. Listen for the actual Click event
        sectorOpsMap.on('click', (e) => {
            // Validation: Must have a start point to compare
            if (!startPoint) return;

            // A. Calculate Distance Moved (Pythagorean theorem)
            const endPoint = e.point;
            const dist = Math.sqrt(
                Math.pow(endPoint.x - startPoint.x, 2) + 
                Math.pow(endPoint.y - startPoint.y, 2)
            );

            // B. Define "Drag Tolerance" (pixels)
            // If moved < 5 pixels, it is a deliberate click.
            const IS_CLICK = dist < 5;

            // C. Check if we clicked on an existing Aircraft Feature
            // We do NOT want to close the window if the user clicked another plane (that logic handles the switch).
            // HTML Markers (Airports) handle their own clicks and stop propagation, so they won't trigger this.
            const features = sectorOpsMap.queryRenderedFeatures(e.point, {
                layers: ['sector-ops-live-flights-layer', 'sector-ops-live-flights-natural-layer'] // The aircraft icon layers (SDF + natural)
            });
            
            const clickedOnAircraft = features.length > 0;

            // D. EXECUTE CLOSE LOGIC
            // Condition: It was a Click + Not on a Plane + A flight is currently selected
            if (IS_CLICK && !clickedOnAircraft && currentFlightInWindow) {
                // Check if window is actually visible to avoid redundant calls
                if (aircraftInfoWindow.classList.contains('visible')) {
                    console.log("Smart Click: Closing flight window (Map clicked, not dragged).");
                    closeAircraftWindow(); 
                }
            }
            
            // Reset
            startPoint = null;
        });
    }

    /**
     * Updates the main weather toolbar button to show if any layers are active.
     */
    function updateWeatherToolbarButtonState() {
        const openWeatherBtn = document.getElementById('open-weather-settings-btn');
        if (!openWeatherBtn) return;

        const precipToggle = document.getElementById('weather-toggle-precip');
        const cloudsToggle = document.getElementById('weather-toggle-clouds');
        const windToggle = document.getElementById('weather-toggle-wind');

        const isAnyActive = (precipToggle && precipToggle.checked) ||
                            (cloudsToggle && cloudsToggle.checked) ||
                            (windToggle && windToggle.checked);

        openWeatherBtn.classList.toggle('active', isAnyActive);
    }

    window.addEventListener('weatherToggle', (e) => {
    const { type, isActive } = e.detail;
    
    switch(type) {
        case 'precip':
            toggleWeatherLayer(isActive);
            break;
        case 'sigmets':
            toggleSigmetLayer(isActive);
            break;
        case 'clouds':
            // Ensure toggleCloudLayer is defined or show notification
            if (typeof toggleCloudLayer === 'function') toggleCloudLayer(isActive);
            else showNotification("Cloud layer currently unavailable", "info");
            break;
        case 'wind':
            if (typeof toggleWindLayer === 'function') toggleWindLayer(isActive);
            else showNotification("Wind layer currently unavailable", "info");
            break;
    }
    
    // Optional: Keep the old toolbar button synced if it exists
    updateWeatherToolbarButtonState(); 
});

    /**
     * Sets up event listeners for the Weather Settings info window.
     */
    function setupWeatherSettingsWindowEvents() {
        if (!weatherSettingsWindow || weatherSettingsWindow.dataset.eventsAttached === 'true') {
            return;
        }

        // Use a single listener on the window for better performance
        weatherSettingsWindow.addEventListener('click', (e) => {
            const target = e.target;

            // Handle Close or Hide buttons
            if (target.closest('.weather-window-close-btn') || target.closest('.weather-window-hide-btn')) {
                weatherSettingsWindow.classList.remove('visible');
                if (typeof MobileUIHandler !== 'undefined') MobileUIHandler.closeActiveWindow();
            }
        });

        // Use a 'change' listener for the toggles
        weatherSettingsWindow.addEventListener('change', (e) => {
            const target = e.target;

            if (target.type === 'checkbox') {
                const isChecked = target.checked;
                
                switch (target.id) {
                    case 'weather-toggle-precip':
                        toggleWeatherLayer(isChecked);
                        break;
                    case 'weather-toggle-sigmets':
                        toggleSigmetLayer(isChecked);
                        break;
                    case 'weather-toggle-clouds':
                        toggleCloudLayer(isChecked);
                        break;
                    case 'weather-toggle-wind':
                        toggleWindLayer(isChecked);
                        break;
                }
                
                // Update the toolbar button's active state
                // This assumes updateWeatherToolbarButtonState() checks all boxes including the new SIGMET one
                const openWeatherBtn = document.getElementById('open-weather-settings-btn');
                if (openWeatherBtn) {
                    const isAnyActive = document.querySelectorAll('.weather-toggle-list input[type="checkbox"]:checked').length > 0;
                    openWeatherBtn.classList.toggle('active', isAnyActive);
                }
            }
        });

        weatherSettingsWindow.dataset.eventsAttached = 'true';
    }



function setupFilterSettingsWindowEvents() {
    if (!filterSettingsWindow || filterSettingsWindow.dataset.eventsAttached === 'true') {
        return;
    }

    const flatMapToggle = document.getElementById('filter-toggle-flat-map');
if (flatMapToggle) {
    flatMapToggle.addEventListener('change', (e) => {
        const useFlat = e.target.checked;
        mapFilters.useFlatMap = useFlat;
        
        // Save to local storage so it persists
        saveFiltersToLocalStorage();

        // Update the Mapbox projection
        if (sectorOpsMap) {
            sectorOpsMap.setProjection(useFlat ? 'mercator' : 'globe');
        }
    });
}

    // --- Helper: Convert Hex to RGBA ---
    const hexToRgba = (hex, alpha) => {
        const r = parseInt(hex.slice(1, 3), 16);
        const g = parseInt(hex.slice(3, 5), 16);
        const b = parseInt(hex.slice(5, 7), 16);
        return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    };

    // --- Helper: Apply Theme to CSS Vars ---
    const applyWindowTheme = (startHex, endHex) => {
        const root = document.documentElement;
        const opacity = (mapFilters.themeOpacity || 95) / 100;
        root.style.setProperty('--iw-bg-start', hexToRgba(startHex, opacity));
        root.style.setProperty('--iw-bg-end', hexToRgba(endHex, opacity));
    };

    // --- Helper: Set UI from State ---
    const setUIFromState = () => {
        // Toggles
        document.getElementById('filter-toggle-atc').checked = mapFilters.hideAtcMarkers;
        
        // [MODIFIED] Set Map Style Radio
        // This ensures the correct radio (Dark, Light, or Satellite) is checked on load
        const styleMode = mapFilters.mapStyle || 'dark'; // Default to dark if undefined
        const styleRadio = document.querySelector(`input[name="map-style-mode"][value="${styleMode}"]`);
        if (styleRadio) styleRadio.checked = true;

        document.getElementById('filter-toggle-aircraft-labels').checked = mapFilters.showAircraftLabels;

        // Simple Window Toggle
        const simpleWindowToggle = document.getElementById('filter-toggle-simple-window');
        if (simpleWindowToggle) {
            simpleWindowToggle.checked = mapFilters.useSimpleFlightWindow;
        }

        // Radios
        const colorRadio = document.querySelector(`input[name="icon-color-mode"][value="${mapFilters.iconColorMode}"]`);
        if (colorRadio) colorRadio.checked = true;

        // Colors
        document.getElementById('theme-color-start').value = mapFilters.themeStartColor || '#121426';
        document.getElementById('theme-color-end').value = mapFilters.themeEndColor || '#121426';
        
        // Apply immediately on load
        applyWindowTheme(mapFilters.themeStartColor, mapFilters.themeEndColor);

        // Mobile-specific
        const currentMobileMode = localStorage.getItem('mobileDisplayMode') || 'legacy';
        // Default to legacy
        const mobileModeHud = document.getElementById('mobile-mode-hud');
        const mobileModeLegacy = document.getElementById('mobile-mode-legacy');
        if (mobileModeHud && mobileModeLegacy) {
            // [UPDATED] If Simple Window is active, force UI to reflect Locked Legacy Mode
            if (mapFilters.useSimpleFlightWindow) {
                mobileModeLegacy.checked = true;
                mobileModeHud.disabled = true; // Lock HUD option
                mobileModeHud.parentElement.style.opacity = '0.5'; // Visual feedback
            } else {
                mobileModeHud.disabled = false;
                mobileModeHud.parentElement.style.opacity = '1';
                if (currentMobileMode === 'legacy') {
                    mobileModeLegacy.checked = true;
                } else {
                    mobileModeHud.checked = true;
                }
            }
        }
    };

    // --- Set the UI when the window is first set up ---
    setUIFromState();

    // --- Event Listener: Color Inputs (Input = Realtime Preview) ---
    const startPicker = document.getElementById('theme-color-start');
    const endPicker = document.getElementById('theme-color-end');
    const resetBtn = document.getElementById('theme-reset-btn');

    const handleColorChange = () => {
        const s = startPicker.value;
        const e = endPicker.value;
        applyWindowTheme(s, e);
        // Update state
        mapFilters.themeStartColor = s;
        mapFilters.themeEndColor = e;
        saveFiltersToLocalStorage();

        const iframe = document.getElementById('simple-flight-window-frame');
        if (iframe && iframe.contentWindow) {
            iframe.contentWindow.postMessage({
                type: 'THEME_UPDATE',
                payload: {
                    start: s,
                    end: e,
                    opacity: mapFilters.themeOpacity || 90
                }
            }, '*');
        }
    };

    if (startPicker) startPicker.addEventListener('input', handleColorChange);
    if (endPicker) endPicker.addEventListener('input', handleColorChange);
    if (resetBtn) {
        resetBtn.addEventListener('click', () => {
            const defColor = '#121426';
            startPicker.value = defColor;
            endPicker.value = defColor;
            applyWindowTheme(defColor, defColor);
            mapFilters.themeStartColor = defColor;
            mapFilters.themeEndColor = defColor;
   
            saveFiltersToLocalStorage();
            showNotification("Window theme reset to default.", "success");
        });
    }

    // Use a single listener on the window for better performance
    filterSettingsWindow.addEventListener('click', (e) => {
        const target = e.target;
        if (target.closest('.filter-window-close-btn') || target.closest('.filter-window-hide-btn')) {
            filterSettingsWindow.classList.remove('visible');
            if (typeof MobileUIHandler !== 'undefined') MobileUIHandler.closeActiveWindow();
        }
    });

    // Use a 'change' listener for all toggles and radios
    filterSettingsWindow.addEventListener('change', (e) => {
        const target = e.target;

        // [UPDATED] Handle Simple Window Toggle & Interdependency
        if (target.id === 'filter-toggle-simple-window') {
            mapFilters.useSimpleFlightWindow = target.checked;
            saveFiltersToLocalStorage();

            const mobileModeHud = document.getElementById('mobile-mode-hud');
            const mobileModeLegacy = document.getElementById('mobile-mode-legacy');

            if (target.checked) {
                // LOCK OUT HUD MODE
                if (mobileModeHud) {
                    mobileModeHud.disabled = true;
                    mobileModeHud.parentElement.style.opacity = '0.5';
                }
                if (mobileModeLegacy) {
                    mobileModeLegacy.checked = true;
                }
                // Force save 'legacy' to storage so UI Handler picks it up next time
                localStorage.setItem('mobileDisplayMode', 'legacy');
            } else {
                // RESTORE HUD ACCESS
                if (mobileModeHud) {
                    mobileModeHud.disabled = false;
                    mobileModeHud.parentElement.style.opacity = '1';
                }
            }
        }
        else if (target.id === 'filter-toggle-atc') {
            mapFilters.hideAtcMarkers = target.checked;
            saveFiltersToLocalStorage();
            updateMapFilters();
        }
        else if (target.name === 'map-style-mode') {
            const mode = target.value;
            
            // Re-enforce Pro Auth for Legacy dropdown items
            const proModes = ['outdoors', 'nav-dark', 'nav-light', 'traffic-night', 'traffic-day'];
            const isSignedIn = !!(typeof ProfileUI !== 'undefined' && ProfileUI?._currentUser);
            
            if (proModes.includes(mode) && !isSignedIn) {
                showNotification((typeof window !== 'undefined' && window.isIOSNative && window.isIOSNative()) ? "This map style isn't available on this account." : "This map style requires a Pro account.", "error");
                // Revert the radio UI to current state
                const currentRadio = document.querySelector(`input[name="map-style-mode"][value="${mapFilters.mapStyle || 'dark'}"]`);
                if (currentRadio) currentRadio.checked = true;
                
                if (window.AuthUI && typeof window.AuthUI.open === 'function') {
                    window.AuthUI.open('signup');
                }
                return;
            }

            mapFilters.mapStyle = mode;
            saveFiltersToLocalStorage();
            
            let newStyleUrl = MAP_STYLE_DARK;
            if (mode === 'light') newStyleUrl = MAP_STYLE_LIGHT;
            else if (mode === 'satellite') newStyleUrl = MAP_STYLE_SATELLITE;
            else if (mode === 'outdoors') newStyleUrl = MAP_STYLE_OUTDOORS;
            else if (mode === 'nav-dark') newStyleUrl = MAP_STYLE_NAV_DARK;
            else if (mode === 'nav-light') newStyleUrl = MAP_STYLE_NAV_LIGHT;
            else if (mode === 'traffic-night') newStyleUrl = MAP_STYLE_TRAFFIC_NIGHT;
            else if (mode === 'traffic-day') newStyleUrl = MAP_STYLE_TRAFFIC_DAY;

            if (currentMapStyle !== newStyleUrl) {
                currentMapStyle = newStyleUrl;
                // Switch style and rebuild layers on load
                sectorOpsMap.setStyle(newStyleUrl);
                sectorOpsMap.once('style.load', () => {
                    rebuildDynamicLayers();
                });
            }
        }
        else if (target.id === 'filter-toggle-aircraft-labels') {
            mapFilters.showAircraftLabels = target.checked;
            saveFiltersToLocalStorage();
            updateAircraftLabelVisibility(); // Call the specific updater
        } else if (target.name === 'icon-color-mode') {
            mapFilters.iconColorMode = target.value;
            saveFiltersToLocalStorage();
            // Re-render aircraft icons. Switching White <-> colored swaps which
            // planes live on the SDF vs. natural layer, so re-apply icon-image
            // (and icon-color) across both, not just the tint.
            applyAircraftLayerStyles();
        } else if (target.name === 'mobile-display-mode') {
            // Save to local storage for MobileUIHandler to pick up
            localStorage.setItem('mobileDisplayMode', target.value);
            showNotification("Mobile display mode updated (Reload to apply).", "info");
        }
    });

    filterSettingsWindow.dataset.eventsAttached = 'true';
}


function setupSearchEventListeners() {
    const searchInput = document.getElementById('sector-ops-search-input');
    const searchClear = document.getElementById('sector-ops-search-clear');
    const searchContainer = document.getElementById('sector-ops-search-container');
    const dropdown = document.getElementById('search-results-dropdown');
    const searchBar = searchContainer ? searchContainer.querySelector('.search-bar-container') : null;

    if (!searchInput || !searchClear || !searchContainer || !dropdown) return;
    
    // Prevent attaching listeners multiple times
    if (searchContainer.dataset.searchListeners === 'true') return; 

    // --- Helper Functions ---
    const openDropdown = () => {
        if (searchInput.value.length >= 2 && dropdown.children.length > 0) {
            dropdown.style.display = 'block';
            searchBar.classList.add('has-results');
        }
    };

    const closeDropdown = () => {
        dropdown.style.display = 'none';
        searchBar.classList.remove('has-results');
    };

    // --- 1. FORCE FOCUS ON CLICK (The Fix) ---
    // This ensures clicking the glass bar actually activates the hidden input
    searchBar.addEventListener('click', () => {
        searchInput.focus();
    });

    // --- 2. Input Typing ---
    searchInput.addEventListener('input', () => {
        const val = searchInput.value;
        searchClear.style.display = val ? 'flex' : 'none';

        if (val.length >= 2) {
            handleSearchInput(val);
            // Slight delay to allow render to finish
            setTimeout(() => {
                if (dropdown.children.length > 0) openDropdown();
                else closeDropdown();
            }, 50);
        } else {
            closeDropdown();
        }
    });

    // --- 3. Re-open on Focus ---
    searchInput.addEventListener('focus', () => {
        if (searchInput.value.length >= 2) {
            handleSearchInput(searchInput.value); // Refresh data
            openDropdown();
        }
    });

    // --- 4. Clear Button ---
    searchClear.addEventListener('click', (e) => {
        e.stopPropagation(); 
        searchInput.value = '';
        handleSearchInput('');
        searchClear.style.display = 'none';
        closeDropdown();
        searchInput.focus(); 
    });

    // Prevent blur when clicking dropdown
    dropdown.addEventListener('mousedown', (e) => e.preventDefault());

    // --- 6. Click Outside to Close ---
    document.addEventListener('click', (e) => {
        if (!searchContainer.contains(e.target)) {
            closeDropdown();
        }
    }, true); 
    
    searchContainer.dataset.searchListeners = 'true';
}

    // ==========================================================
    // END: SECTOR OPS / ROUTE EXPLORER LOGIC
    // ==========================================================

    // ====================================================================
    // START: NEW LIVE FLIGHTS & ATC/NOTAM LOGIC FOR SECTOR OPS MAP
    // ====================================================================


// --- [REPLACEMENT] ---
// Starts the data polling AND the animation loop.
function startSectorOpsLiveLoop() {
    // Keep the warm pipeline: boot opens the socket and starts buffering
    // flights while the map is still loading (see initializeSectorOpsView),
    // so a full teardown here would throw away that head start.
    // initializeSectorOpsSocket() below reuses/reconnects an existing socket.
    stopSectorOpsLiveLoop({ keepLiveData: true }); // Clear any old loops

    // ATC that arrived during the map load can render right away — don't
    // make it wait for the fetch below to round-trip again.
    if (activeAtcFacilities.length) renderAirportMarkers();

    // 1. Start the data fetching loop for ATC/NOTAMs (infrequent)
    updateSectorOpsSecondaryData(); // Fetch immediately
    sectorOpsAtcNotamInterval = setInterval(updateSectorOpsSecondaryData, DATA_REFRESH_INTERVAL_MS);

    // 2. Initialize and connect the WebSocket
    initializeSectorOpsSocket();

    // 3. Start the MapAnimator loop
    if (mapAnimator) {
        mapAnimator.start();
        // Paint whatever flights arrived while the map was loading. The
        // teleport animator only pushes the source when a packet lands, so
        // without this the first planes wait for the next socket broadcast.
        mapAnimator._updateMapSource();
    }
}

// Stops the data polling AND the animation loop.
// `keepLiveData: true` (the boot path) stops the timers without tearing down
// the socket or the buffered flight features, so data that arrived while the
// map was still loading survives into the freshly started loop.
function stopSectorOpsLiveLoop({ keepLiveData = false } = {}) {
    // 1. Clear the data-fetching interval for ATC/NOTAMs
    if (sectorOpsAtcNotamInterval) {
        clearInterval(sectorOpsAtcNotamInterval);
        sectorOpsAtcNotamInterval = null;
    }

    // 2. Disconnect the WebSocket
    if (!keepLiveData && sectorOpsSocket) {
        console.log('Socket: Disconnecting from Sector Ops...');
        sectorOpsSocket.disconnect();
        sectorOpsSocket = null;
    }

    // 3. Stop the MapAnimator loop
    if (mapAnimator) {
        mapAnimator.stop();
    }

    // 4. Clear the feature state
    // FIX: Clear in place so MapAnimator keeps the reference
    if (!keepLiveData) {
        for (const key in currentMapFeatures) {
            delete currentMapFeatures[key];
        }
    }
}

// --- PRO: Custom active-ATC tag appearance --------------------------------
// Resolves the user's custom ATC tag design (mapFilters.atcTagConfig), or
// null when the stock look should be used: feature toggled off or missing
// config. Like the other studio features (custom plane colors, label
// themes), access is gated by the settings UI lock — the map honors
// whatever config it was allowed to write.

// Every tag shape the designer can pick. Unknown values (old saved configs,
// hand-edited storage) fall back to 'classic'.
const ATC_TAG_STYLES = ['classic', 'chip', 'pill', 'outline', 'neon', 'glass', 'flag', 'mono'];

function getAtcTagAppearance() {
    const cfg = mapFilters && mapFilters.atcTagConfig;
    if (!cfg || !cfg.enabled) return null;
    const opacity = Math.min(1, Math.max(0.2, parseFloat(cfg.opacity) || 0.9));
    return {
        style: ATC_TAG_STYLES.includes(cfg.style) ? cfg.style : 'classic',
        bg: cfg.bg || '#0a0f19',
        text: cfg.text || '#ffffff',
        border: cfg.border || '#ffffff',
        opacity,
        showFreqs: cfg.showFreqs !== false,
        showPulse: cfg.showPulse !== false
    };
}

function atcTagHexToRgba(hex, alpha) {
    const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || '').trim());
    if (!m) return hex;
    const n = parseInt(m[1], 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
}

// Applies (or clears) the custom design on one ATC tag element. Colors ride
// on CSS custom properties so the stylesheet stays the single source of
// truth for the tag's layout; the element only carries the user's values.
function applyAtcTagAppearance(el, appearance) {
    const cfg = appearance === undefined ? getAtcTagAppearance() : appearance;
    el.classList.toggle('atc-tag-custom', !!cfg);
    ATC_TAG_STYLES.forEach(s => {
        if (s === 'classic') return; // classic is the unstyled base look
        el.classList.toggle(`atc-tag-${s}`, !!cfg && cfg.style === s);
    });
    el.classList.toggle('atc-tag-no-freqs', !!cfg && !cfg.showFreqs);
    el.classList.toggle('atc-tag-no-pulse', !!cfg && !cfg.showPulse);
    if (cfg) {
        el.style.setProperty('--atc-tag-bg', atcTagHexToRgba(cfg.bg, cfg.opacity));
        el.style.setProperty('--atc-tag-text', cfg.text);
        el.style.setProperty('--atc-tag-border', cfg.border);
    } else {
        el.style.removeProperty('--atc-tag-bg');
        el.style.removeProperty('--atc-tag-text');
        el.style.removeProperty('--atc-tag-border');
    }
}

// Re-skins existing DOM tags in place, then re-runs the airport renderer so
// the glance-layer <-> DOM-tag handoff matches the new mode. Exposed for the
// settings UI (MobileSettingsUI.js).
window.refreshAtcTagAppearance = function () {
    const cfg = getAtcTagAppearance();
    Object.values(airportAndAtcMarkers).forEach(entry => {
        if (entry.hasAtc) applyAtcTagAppearance(entry.marker.getElement(), cfg);
    });
    renderAirportMarkers();
};

// Re-skin whenever the account entitlement state changes so the tags always
// reflect what the (re)authenticated user last saved.
window.addEventListener('proStatusChanged', () => {
    try { window.refreshAtcTagAppearance(); } catch (_) {}
});

// renderAirportMarkers needs a loaded style; when one isn't ready yet the
// render is queued (once) for the next idle frame instead of being dropped,
// so settings changes still land "on the fly" instead of waiting for the
// next ATC data poll.
let airportMarkersRenderQueued = false;

function renderAirportMarkers() {
    if (!sectorOpsMap) return;
    if (!sectorOpsMap.isStyleLoaded()) {
        if (!airportMarkersRenderQueued) {
            airportMarkersRenderQueued = true;
            sectorOpsMap.once('idle', () => {
                airportMarkersRenderQueued = false;
                renderAirportMarkers();
            });
        }
        return;
    }

    const showUnstaffed = mapFilters.showUnstaffedAirports;
    const hideNoAtc = mapFilters.hideNoAtcMarkers;
    const hideAtc = mapFilters.hideAtcMarkers;
    // Glance mode (default): active-ATC airports are drawn by the GPU glance
    // layer instead of DOM tags. Classic mode keeps the old per-airport tags.
    // A custom (PRO) tag design is DOM-based, so it forces the classic path.
    const customAtcTag = getAtcTagAppearance();
    const classic = mapFilters.useClassicAirportTags || !!customAtcTag;

    // Helper: Identify "Major" airports (Class A/B/C) without explicit class data
    const isMajorAirport = (icao, airport) => {
        if (!icao || icao.length !== 4) return false;
        if (/\d/.test(icao)) return false; // Exclude IDs with numbers
        const name = (airport.name || "").toLowerCase();
        const junk = ['water', 'seaplane', 'heliport', 'helipad', 'strip', 'field', 'glider'];
        if (junk.some(k => name.includes(k))) return false;
        return true;
    };

    // 1. Identify Staffed Airports (ATC + Routes)
    const atcAirportIcaos = new Set(activeAtcFacilities.map(f => f.airportName).filter(Boolean));
    const allRouteAirports = new Set();
    if (typeof ALL_AVAILABLE_ROUTES !== 'undefined') {
        ALL_AVAILABLE_ROUTES.forEach(route => {
            allRouteAirports.add(route.departure);
            allRouteAirports.add(route.arrival);
        });
    }
    const staffedIcaos = new Set([...allRouteAirports, ...atcAirportIcaos]);

    // 2. Manage DOM Markers (Staffed Only)
    Object.keys(airportAndAtcMarkers).forEach(icao => {
        const hasAtc = atcAirportIcaos.has(icao);
        // ATC airports only live in the DOM layer when classic tags are on;
        // otherwise the glance layer owns them.
        const shouldBeDom = staffedIcaos.has(icao) && (classic || !hasAtc);
        const isFiltered = (hideNoAtc && !hasAtc) || (hideAtc && hasAtc);
        if (!shouldBeDom || isFiltered) {
            airportAndAtcMarkers[icao].marker.remove();
            delete airportAndAtcMarkers[icao];
        }
    });

    staffedIcaos.forEach(icao => {
        const airport = airportsData[icao];
        if (!airport || airport.lat == null || airport.lon == null) return;

        const hasAtc = atcAirportIcaos.has(icao);
        if ((hideNoAtc && !hasAtc) || (hideAtc && hasAtc)) return;

        // Filter unstaffed/minor airports
        if (!hasAtc && !isMajorAirport(icao, airport)) return;

        // In glance mode the GPU layer renders active-ATC airports, so don't
        // also build a DOM tag for them.
        if (hasAtc && !classic) return;

        if (airportAndAtcMarkers[icao]) {
            // Update existing marker instead of destroying it
            const el = airportAndAtcMarkers[icao].marker.getElement();
            if (hasAtc !== airportAndAtcMarkers[icao].hasAtc) {
                // Class changed (e.g., ATC came online or went offline)
                el.className = hasAtc ? 'apt-live-tag' : 'destination-marker';
                airportAndAtcMarkers[icao].hasAtc = hasAtc;
            }
            // Keep reused tags on the current (custom or stock) design.
            if (hasAtc) applyAtcTagAppearance(el, customAtcTag);
            
            // Only update innerHTML if it's an ATC marker to refresh the timer
            if (hasAtc) {
                // (Build your innerHTML string here exactly as you currently do)
                // el.innerHTML = `<div class="apt-tag-extra">...</div><div class="apt-tag-base">...</div>`;
            }
            return; // Skip creating a new marker
        }

        // If it doesn't exist, create a new one
        const el = document.createElement('div');
        
        // --- ADDED: Hover Suppression Logic ---
        el.addEventListener('mouseenter', () => {
            window.isMouseOverAirportTag = true;
            // Forcefully remove any aircraft hover card if it appears
            const activePopups = document.querySelectorAll('.mapboxgl-popup');
            activePopups.forEach(popup => popup.remove());
        });

        el.addEventListener('mouseleave', () => {
            window.isMouseOverAirportTag = false;
        });

        if (hasAtc) {
            el.className += ' apt-live-tag';
            const airportAtc = activeAtcFacilities.filter(f => f.airportName === icao);
            const earliestStart = airportAtc.reduce((min, f) => {
                const start = new Date(f.startTime).getTime();
                return start < min ? start : min;
            }, Date.now());
            const diffMins = Math.floor((Date.now() - earliestStart) / 60000);
            const durationText = diffMins > 60 ? `${Math.floor(diffMins/60)}h ${diffMins%60}m` : `${diffMins}m online`;

            const hasGnd = airportAtc.some(f => f.type === 0);
            const hasTwr = airportAtc.some(f => f.type === 1);
            const hasApp = airportAtc.some(f => f.type === 4 || f.type === 5);
            const hasAtis = airportAtc.some(f => f.type === 7);

            if (hasApp) {
                const aura = document.createElement('div');
                aura.className = 'tag-pulse-aura';
                el.appendChild(aura);
            }

            const extra = document.createElement('div');
            extra.className = 'apt-tag-extra';
            extra.innerHTML = `<div class="apt-tag-extra-item">Oldest Session</div><div class="apt-tag-extra-val">${durationText}</div>`;
            el.appendChild(extra);

            const base = document.createElement('div');
            base.className = 'apt-tag-base';
            base.innerHTML = `<div class="apt-tag-ident">${icao}</div>`;

            const freqs = document.createElement('div');
            freqs.className = 'apt-tag-freqs';
            if (hasAtis) freqs.innerHTML += `<div class="freq-mini-badge f-atis">A</div>`;
            if (hasGnd) freqs.innerHTML += `<div class="freq-mini-badge f-gnd">G</div>`;
            if (hasTwr) freqs.innerHTML += `<div class="freq-mini-badge f-twr">T</div>`;
            if (hasApp) freqs.innerHTML += `<div class="freq-mini-badge f-app">R</div>`;
            
            base.appendChild(freqs);
            el.appendChild(base);
            applyAtcTagAppearance(el, customAtcTag);
        } else {
            el.className += ' destination-marker';
            el.textContent = icao;
        }

        const marker = new mapboxgl.Marker({ element: el })
            .setLngLat([airport.lon, airport.lat])
            .addTo(sectorOpsMap);

        // --- ADDED: Click Priority Logic ---
        el.addEventListener('click', (e) => {
            // Stop the click from reaching the Mapbox canvas layers (aircraft icons)
            e.stopPropagation(); 
            handleAirportClick(icao);
        });

        airportAndAtcMarkers[icao] = { marker, hasAtc };
    });

    // 3. Update the high-performance background layer
    updateUnstaffedLayer(showUnstaffed, staffedIcaos);

    // 4. Update the active-airport glance layer (active ATC, GPU-rendered)
    updateActiveAirportsGlanceLayer();
}

async function updateUnstaffedLayer(show, excludeIcaos) {
    const SOURCE_ID = 'unstaffed-airports-source';
    const LAYER_ID = 'unstaffed-airports-layer';

    if (!show) {
        if (sectorOpsMap.getLayer(LAYER_ID)) sectorOpsMap.setLayoutProperty(LAYER_ID, 'visibility', 'none');
        return;
    }

    // 1. DO THE HEAVY MATH NON-BLOCKING (CHUNKED)
    if (!precalculatedMajorAirports) {
        console.log("Pre-calculating major airports in chunks to prevent lag...");
        precalculatedMajorAirports = [];
        const junk = ['water', 'seaplane', 'heliport', 'helipad', 'strip', 'field', 'glider'];
        
        const icaoKeys = Object.keys(airportsData);
        const BATCH_SIZE = 1000; // Process 1000 airports per frame
        
        for (let i = 0; i < icaoKeys.length; i += BATCH_SIZE) {
            const batch = icaoKeys.slice(i, i + BATCH_SIZE);
            
            batch.forEach(icao => {
                const airport = airportsData[icao];
                // Optimized filters: Fast string checks instead of regex
                if (!icao || icao.length !== 4) return;
                
                let hasNumber = false;
                for (let c = 0; c < 4; c++) {
                    if (icao.charCodeAt(c) >= 48 && icao.charCodeAt(c) <= 57) {
                        hasNumber = true;
                        break;
                    }
                }
                if (hasNumber) return;

                const name = (airport.name || "").toLowerCase();
                
                let isJunk = false;
                for (let j = 0; j < junk.length; j++) {
                    if (name.indexOf(junk[j]) !== -1) {
                        isJunk = true;
                        break;
                    }
                }
                
                if (!isJunk) {
                    precalculatedMajorAirports.push({ icao: icao, lon: airport.lon, lat: airport.lat });
                }
            });
            
            // Yield to the main thread so the browser doesn't freeze
            await new Promise(resolve => setTimeout(resolve, 0));
        }
    }

    // 2. BLAZING FAST FILTERING
    // Just map the pre-calculated list and exclude the 1-6 currently staffed ones
    const features = precalculatedMajorAirports
        .filter(apt => !excludeIcaos.has(apt.icao)) // <--- The only dynamic part
        .map(apt => ({
            type: 'Feature',
            geometry: { type: 'Point', coordinates: [apt.lon, apt.lat] },
            properties: { icao: apt.icao }
        }));

    const sourceData = { type: 'FeatureCollection', features };

    if (sectorOpsMap.getSource(SOURCE_ID)) {
        sectorOpsMap.getSource(SOURCE_ID).setData(sourceData);
    } else {
        sectorOpsMap.addSource(SOURCE_ID, {
            type: 'geojson',
            data: sourceData,
            tolerance: 0 // Prevent Mapbox from over-simplifying clusters of text
        });

        sectorOpsMap.addLayer({
            id: LAYER_ID,
            type: 'symbol',
            source: SOURCE_ID,
            layout: {
                'text-field': '{icao}',
                'text-font': ['JetBrains Mono Bold', 'Arial Unicode MS Bold'], // Aviation font
                'text-size': [
                    'interpolate', ['linear'], ['zoom'],
                    4, 8,
                    8, 12
                ],
                // Show ONLY when zoomed in to prevent lag
                'text-allow-overlap': false,
                'text-ignore-placement': false,
                'text-padding': 2,
                'symbol-spacing': 20, // Prevent overlapping
            },
            paint: {
                'text-color': '#475569', // Muted slate gray
                'text-halo-color': '#0f172a', // Dark halo
                'text-halo-width': 1.5,
                // Fade out when zooming out
                'text-opacity': [
                    'interpolate', ['linear'], ['zoom'],
                    4, 0,
                    5, 1
                ]
            }
        }, 'sector-ops-live-flights-layer'); // Place UNDER planes
    }

    if (sectorOpsMap.getLayer(LAYER_ID)) {
        sectorOpsMap.setLayoutProperty(LAYER_ID, 'visibility', 'visible');
    }
}

// ====================================================================
// Active-airport "glance" layer — GPU symbol/circle layer that replaces the
// per-airport DOM tags. It shows each staffed airport's ICAO plus the
// positions that are online (GND / TWR / APP / ATIS) at a glance, colored by
// the most advanced service present. Because it's a single GeoJSON source
// updated via setData() there are no DOM nodes to build each refresh, so it
// stays fast no matter how many fields are staffed. The classic DOM tags are
// still available via the "Classic Airport Tags" setting.
// ====================================================================
const ACTIVE_APT_SRC = 'active-airports-source';
const ACTIVE_APT_DOT = 'active-airports-dot';
const ACTIVE_APT_LBL = 'active-airports-label';

// Shared, GPU data-driven color ramp (top service present).
const ACTIVE_APT_COLOR = [
    'match', ['get', 'rank'],
    5, '#bf5af2', // Approach / Departure
    4, '#ff9f0a', // Tower
    3, '#0a84ff', // Ground / Delivery
    2, '#30d158', // ATIS only
    '#e5e7eb'     // other
];

// Dedup lock so a single click landing on both the dot and the label layer
// only opens the airport once.
let _activeAptClickLock = false;
function _onActiveAptClick(e) {
    if (_activeAptClickLock) return;
    const f = e.features && e.features[0];
    const icao = f && f.properties && f.properties.icao;
    if (!icao) return;
    _activeAptClickLock = true;
    setTimeout(() => { _activeAptClickLock = false; }, 0);
    if (typeof handleAirportClick === 'function') handleAirportClick(icao);
}
function _onActiveAptEnter() { if (sectorOpsMap) sectorOpsMap.getCanvas().style.cursor = 'pointer'; }
function _onActiveAptLeave() { if (sectorOpsMap) sectorOpsMap.getCanvas().style.cursor = ''; }
function wireActiveAirportsLayerEvents() {
    // off-then-on with stable handlers is idempotent across style reloads.
    [ACTIVE_APT_DOT, ACTIVE_APT_LBL].forEach(id => {
        sectorOpsMap.off('click', id, _onActiveAptClick);
        sectorOpsMap.on('click', id, _onActiveAptClick);
        sectorOpsMap.off('mouseenter', id, _onActiveAptEnter);
        sectorOpsMap.on('mouseenter', id, _onActiveAptEnter);
        sectorOpsMap.off('mouseleave', id, _onActiveAptLeave);
        sectorOpsMap.on('mouseleave', id, _onActiveAptLeave);
    });
}

function updateActiveAirportsGlanceLayer() {
    if (!sectorOpsMap || !sectorOpsMap.isStyleLoaded()) return;

    // A custom (PRO) tag design renders as DOM tags, so it hides the glance
    // layer exactly like classic mode does.
    const classic = mapFilters.useClassicAirportTags || !!getAtcTagAppearance();
    const hideAtc = mapFilters.hideAtcMarkers;

    const setVisible = (vis) => {
        [ACTIVE_APT_DOT, ACTIVE_APT_LBL].forEach(id => {
            if (sectorOpsMap.getLayer(id)) sectorOpsMap.setLayoutProperty(id, 'visibility', vis);
        });
    };

    // Classic mode (or ATC hidden): clear + hide the glance layer entirely.
    if (classic || hideAtc) {
        if (sectorOpsMap.getSource(ACTIVE_APT_SRC)) {
            sectorOpsMap.getSource(ACTIVE_APT_SRC).setData({ type: 'FeatureCollection', features: [] });
        }
        setVisible('none');
        return;
    }

    // Group online facilities by airport (centers have no airport — skip them;
    // they're drawn as FIR sectors elsewhere).
    const byAirport = new Map();
    (activeAtcFacilities || []).forEach(f => {
        const icao = f.airportName;
        const type = Number(f.type);
        if (!icao || type === 6) return;
        if (!byAirport.has(icao)) byAirport.set(icao, new Set());
        byAirport.get(icao).add(type);
    });

    const features = [];
    byAirport.forEach((types, icao) => {
        const apt = airportsData[icao];
        if (!apt || apt.lat == null || apt.lon == null) return;

        const hasGnd = types.has(0) || types.has(3);
        const hasTwr = types.has(1);
        const hasApp = types.has(4) || types.has(5);
        const hasAtis = types.has(7);

        const codes = [];
        if (hasGnd) codes.push('GND');
        if (hasTwr) codes.push('TWR');
        if (hasApp) codes.push('APP');
        if (hasAtis) codes.push('ATIS');
        if (!codes.length) codes.push('ATC');

        const rank = hasApp ? 5 : hasTwr ? 4 : hasGnd ? 3 : hasAtis ? 2 : 1;

        features.push({
            type: 'Feature',
            geometry: { type: 'Point', coordinates: [apt.lon, apt.lat] },
            properties: { icao, codes: codes.join('  '), rank }
        });
    });

    const data = { type: 'FeatureCollection', features };

    if (sectorOpsMap.getSource(ACTIVE_APT_SRC)) {
        sectorOpsMap.getSource(ACTIVE_APT_SRC).setData(data);
    } else {
        try {
            sectorOpsMap.addSource(ACTIVE_APT_SRC, { type: 'geojson', data, tolerance: 0 });

            // Place just under the aircraft layer when it exists, else on top.
            const beforeId = sectorOpsMap.getLayer('sector-ops-live-flights-layer')
                ? 'sector-ops-live-flights-layer' : undefined;

            sectorOpsMap.addLayer({
                id: ACTIVE_APT_DOT,
                type: 'circle',
                source: ACTIVE_APT_SRC,
                paint: {
                    'circle-radius': ['interpolate', ['linear'], ['zoom'], 3, 3.5, 8, 6],
                    'circle-color': ACTIVE_APT_COLOR,
                    'circle-stroke-width': 1.5,
                    'circle-stroke-color': 'rgba(255,255,255,0.92)',
                    'circle-opacity': ['interpolate', ['linear'], ['zoom'], 2, 0.25, 4, 1]
                }
            }, beforeId);

            sectorOpsMap.addLayer({
                id: ACTIVE_APT_LBL,
                type: 'symbol',
                source: ACTIVE_APT_SRC,
                layout: {
                    // Crisp white ICAO with the staffed positions below, tinted
                    // by the top service online (per-section colors, Mapbox v3).
                    'text-field': [
                        'format',
                        ['get', 'icao'], { 'font-scale': 1.2, 'text-color': '#ffffff' },
                        '\n', {},
                        ['get', 'codes'], { 'font-scale': 0.82, 'text-color': ACTIVE_APT_COLOR }
                    ],
                    'text-font': ['JetBrains Mono Bold', 'Arial Unicode MS Bold'],
                    'text-size': ['interpolate', ['linear'], ['zoom'], 3, 11, 8, 14],
                    'text-offset': [0, -1.1],
                    'text-anchor': 'bottom',
                    'text-line-height': 1.25,
                    'text-allow-overlap': false,
                    'text-ignore-placement': false,
                    'text-padding': 4,
                    // Lower sort key = placed first; advanced services win collisions.
                    'symbol-sort-key': ['-', 10, ['get', 'rank']]
                },
                paint: {
                    'text-color': '#ffffff',
                    'text-halo-color': 'rgba(8,10,14,0.95)',
                    'text-halo-width': 1.7,
                    'text-halo-blur': 0.5,
                    'text-opacity': ['interpolate', ['linear'], ['zoom'], 2, 0, 3.2, 1]
                }
            }, beforeId);

            wireActiveAirportsLayerEvents();
        } catch (err) {
            console.warn('Active-airports glance layer init failed:', err);
            return;
        }
    }

    setVisible('visible');
}


// --- [UPDATED] Fetches ATC & NOTAMs for the CURRENTLY SELECTED SERVER ---
async function updateSectorOpsSecondaryData() {
    // Deliberately no map/style guard here — this is a pure data fetch. The
    // map-dependent consumers below (FIR sectors, airport markers) each guard
    // themselves, and renderAirportMarkers() queues itself until the style is
    // ready. The old isStyleLoaded() early-return silently skipped the
    // boot-time fetch whenever the style was still settling, leaving the map
    // with no ATC until the next 50-second polling tick.
    const LIVE_FLIGHTS_BACKEND = 'https://site--acars-backend--6dmjph8ltlhv.code.run';

    try {
        const sessionsRes = await fetch(`${LIVE_FLIGHTS_BACKEND}/if-sessions`);
        if (!sessionsRes.ok) {
            console.warn('Sector Ops Map: Could not fetch server sessions. Skipping secondary data update.');
            return;
        }
        const sessionsData = await sessionsRes.json();
        
        // [UPDATED] Use helper to get ID for currentServerName
        const targetSessionId = getCurrentSessionId(sessionsData);

        if (!targetSessionId) {
            console.warn(`Sector Ops Map: Session ID not found for ${currentServerName}`);
            return;
        }

        const [atcRes, notamsRes] = await Promise.all([
            fetch(`${LIVE_FLIGHTS_BACKEND}/atc/${targetSessionId}`),
            fetch(`${LIVE_FLIGHTS_BACKEND}/notams/${targetSessionId}`)
        ]);
        
        // Update ATC & NOTAMs
        // Update ATC & NOTAMs
        if (atcRes.ok) {
            const atcData = await atcRes.json();
            activeAtcFacilities = (atcData.ok && Array.isArray(atcData.atc)) ? atcData.atc : [];
            notifyActiveAtcUpdated();

            // --- FIX: Initial draw for FIRs if the map is ready ---
            if (sectorOpsMap && sectorOpsMap.getLayer('sector-ops-live-flights-layer')) {
                const centerControllers = activeAtcFacilities.filter(f => f.type === 6);
                if (typeof updateActiveSectors === 'function') {
                    updateActiveSectors(sectorOpsMap, 'fir-fills', centerControllers);
                }
            }
        }
        if (notamsRes.ok) {
            const notamsData = await notamsRes.json();
            activeNotams = (notamsData.ok && Array.isArray(notamsData.notams)) ? notamsData.notams : [];
        }
        // Re-render airport markers with fresh ATC data
        renderAirportMarkers();

    } catch (error) {
        console.error('Error updating Sector Ops secondary data (ATC/NOTAMs):', error);
    }
}
    // ====================================================================
    // END: NEW LIVE FLIGHTS & ATC/NOTAM LOGIC FOR SECTOR OPS MAP
    // ====================================================================



    // --- Initial Load ---
async function initializeApp() {

        PerformanceMonitor.init();

        loadFiltersFromLocalStorage();

        // Resolve Pro entitlement early so multi-flight tracking limits and
        // other gated features have a real answer to gate on. Fire-and-forget;
        // window.isInflightPro() returns false until this lands.
        refreshProStatus();

        // Inject all custom CSS
        injectCustomStyles();
        

        // [PERF FIX] Parallelize: kick off all 3 fetches at once, but only
        // block on the two the map actually needs (token + airport coords).
        // Runways finish in the background while the map is rendering.
        const apiKeysPromise = fetchApiKeys();
        const airportsPromise = fetchAirportsData();
        const runwaysPromise = fetchRunwaysData();

        await Promise.all([apiKeysPromise, airportsPromise]);

        // Initialize the Sector Ops view (map render starts now)
        await initializeSectorOpsView();

        // First-launch gate: on the very first run (or after the legal docs
        // are re-versioned) play the cinematic map intro and require the user
        // to accept the Privacy Policy + Terms before the app is usable.
        // Returning users skip this instantly. Fire-and-forget so it doesn't
        // block the rest of boot from finishing underneath the modal.
        runFirstRunExperience(sectorOpsMap);

        // Make sure runways finished too before we move on to anything that needs them
        await runwaysPromise;

        await LandingUI.init();
        SettingsUI.init();

        MobileSettingsUI.init();
        // Reflect any persisted tactical filters in the chrome badges (the
        // Filters orb dot / mobile tab dot) without waiting for the settings
        // UI to be opened first.
        MobileSettingsUI.updateFilterBadge();

        // Default to true if not explicitly set to 'false'
        const isVisible = localStorage.getItem('landingUI_visible') !== 'true'; 

        if (isVisible) {
            LandingUI.update(true, {
                server: currentServerName,
                // These will update to real numbers as soon as data arrives
                flights: Object.keys(currentMapFeatures).length || 0, 
                atc: activeAtcFacilities.length || 0
            });
        }

        window.addEventListener('filterUpdate', (e) => {
            const { filters, quickSearch } = e.detail;
            
            // Store incoming tactical filters into global state
            mapFilters.tactical = filters;
            mapFilters.quickSearch = quickSearch;

            // Handle boolean group toggle
            mapFilters.showGroupFlights = !!filters.group;
            
            // Run the filter update logic
            updateMapFilters();
        });
        

    }

    window.displayPilotStats = displayPilotStats;

    // flight.js
// Handle direct signup requests from the landing page
const urlParams = new URLSearchParams(window.location.search);
if (urlParams.get('auth') === 'signup') {
    const { data: sessionData } = await supabase.auth.getSession();
    const isSignedIn = !!sessionData?.session?.user;

    // Only open if the user isn't already logged in
    if (!isSignedIn && window.AuthUI && typeof window.AuthUI.open === 'function') {
        window.AuthUI.open('signup');
    }
}

    initializeApp();
});
