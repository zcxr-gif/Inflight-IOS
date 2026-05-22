// AirportViewer3D.js — Premium ATC Digital Twin Viewer
// Purpose:
// Renders a cinematic 3D view of a specified airport with an unlocked, free-roam camera.
// Projects holographic distance rings (3NM, 5NM, 10NM) onto the terrain.
// Features 3D aircraft models and premium HTML/CSS tactical data cards.

import { socketDataHub } from './SocketDataHub.js';

export const AirportViewer3D = {
    _viewer: null,
    _containerId: 'pui-airport-3d-wrapper',
    
    // Tracking state for live radar cards
    _liveFlights: new Map(),
    _htmlTags: new Map(),
    _dataUnsubscribe: null,
    _renderTagsHandler: null,

    // Helper: Haversine distance in Nautical Miles
    _getDistanceNM(lat1, lon1, lat2, lon2) {
        const R = 3440.065; 
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                  Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
                  Math.sin(dLon / 2) * Math.sin(dLon / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    },

    // Cesium loading
    _loadCesium() {
        const CESIUM_VERSION = '1.122';
        return new Promise((resolve, reject) => {
            if (window.Cesium) { resolve(window.Cesium); return; }
            if (!document.getElementById('cesium-widget-css')) {
                const link  = document.createElement('link');
                link.id     = 'cesium-widget-css';
                link.rel    = 'stylesheet';
                link.href   = `https://cesium.com/downloads/cesiumjs/releases/${CESIUM_VERSION}/Build/Cesium/Widgets/widgets.css`;
                document.head.appendChild(link);
            }
            const script   = document.createElement('script');
            script.src     = `https://cesium.com/downloads/cesiumjs/releases/${CESIUM_VERSION}/Build/Cesium/Cesium.js`;
            script.onload  = () => resolve(window.Cesium);
            script.onerror = () => reject(new Error('[AirportViewer3D] Failed to load CesiumJS from CDN'));
            document.head.appendChild(script);
        });
    },

    // AWS Terrarium Terrain Provider
    _createTerrariumProvider(Cesium) {
        class TerrariumTerrainProvider {
            constructor() {
                this.tilingScheme = new Cesium.WebMercatorTilingScheme();
                this.hasWaterMask = false;
                this.hasVertexNormals = false;
                this.credit = new Cesium.Credit('Terrain data via AWS Open Data');
                this.ready = true;
                this.readyPromise = Promise.resolve(true);
                this.errorEvent = new Cesium.Event();
                this.urlTemplate = 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png';
                this.canvas = document.createElement('canvas');
                this.canvas.width = 256;
                this.canvas.height = 256;
                this.context = this.canvas.getContext('2d', { willReadFrequently: true });
            }
            requestTileGeometry(x, y, level) {
                if (level > 15) return Promise.reject(new Error('Max zoom reached'));
                const url = this.urlTemplate.replace('{z}', level).replace('{x}', x).replace('{y}', y);
                return Cesium.Resource.fetchImage({ url: url }).then((image) => {
                    this.context.drawImage(image, 0, 0, 256, 256);
                    const pixels = this.context.getImageData(0, 0, 256, 256).data;
                    const heights = new Float32Array(256 * 256);
                    for (let i = 0; i < pixels.length; i += 4) {
                        const r = pixels[i]; const g = pixels[i + 1]; const b = pixels[i + 2];
                        heights[i / 4] = (r * 256 + g + b / 256) - 32768;
                    }
                    return new Cesium.HeightmapTerrainData({
                        buffer: heights, width: 256, height: 256,
                        structure: { heightScale: 1.0, heightOffset: 0.0, elementsPerHeight: 1, stride: 1, highestEncodedValue: 256 * 256, isBigEndian: false }
                    });
                }).catch(() => new Cesium.HeightmapTerrainData({ buffer: new Float32Array(256 * 256), width: 256, height: 256 }));
            }
            getLevelMaximumGeometricError(level) { return 77850 / Math.pow(2, level); }
            getTileDataAvailable() { return true; }
        }
        return new TerrariumTerrainProvider();
    },

    getHTML(icao) {
        return `
        <div id="${this._containerId}" 
             style="position:fixed; top:0; left:0; width:100vw; height:100vh; z-index:10000; background:#0a1628; opacity:0; transition: opacity 0.5s ease;">
            
            <div id="airport-cesium-container" style="width:100%; height:100%;"></div>
            
            <div style="position:absolute; top:0; left:0; width:100%; height:100%; background:radial-gradient(circle, rgba(0,0,0,0) 40%, rgba(0,0,0,0.6) 100%); pointer-events:none; z-index:5;"></div>
            
            <div id="airport-3d-flight-tags" style="position:absolute; top:0; left:0; width:100%; height:100%; pointer-events:none; z-index:15; overflow:hidden;"></div>

            <div style="position:absolute; top:40px; left:40px; z-index:10; pointer-events:none; display:flex; flex-direction:column; gap:8px;">
                <div style="display:flex; align-items:center; gap:12px;">
                    <div style="width:12px; height:12px; background:#39ff14; border-radius:50%; box-shadow: 0 0 10px #39ff14; animation: puiPulseDot 2s infinite;"></div>
                    <h1 style="margin:0; font-family:'JetBrains Mono', monospace; font-size:2.5rem; color:#fff; text-shadow: 0 2px 10px rgba(0,0,0,0.8);">${icao}</h1>
                </div>
                <div style="font-family:'JetBrains Mono', monospace; color:#39ff14; font-size:0.85rem; letter-spacing:0.2em; text-transform:uppercase; background:rgba(0,0,0,0.6); padding:4px 10px; border-radius:4px; width:fit-content; border:1px solid rgba(57,255,20,0.3);">
                    Live Digital Twin Active
                </div>
            </div>

            <button id="close-airport-3d" 
                    style="position:absolute; top:40px; right:40px; z-index:10; background:rgba(0,0,0,0.6); border:1px solid rgba(255,255,255,0.2); color:#fff; padding:12px 24px; border-radius:8px; font-family:'DM Sans', sans-serif; font-weight:700; cursor:pointer; backdrop-filter:blur(4px); transition: all 0.2s ease; display:flex; align-items:center; gap:8px;">
                <i class="fa-solid fa-xmark"></i> Close Terminal View
            </button>

            <div id="airport-loader" style="position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); color:#39ff14; font-family:'JetBrains Mono', monospace; letter-spacing:0.1em; z-index:20; text-align:center;">
                <i class="fa-solid fa-circle-notch fa-spin" style="font-size:2rem; margin-bottom:12px;"></i><br>
                INITIALIZING SPATIAL GEOMETRY...
            </div>
            
            <style>
                #${this._containerId} .cesium-widget-credits,
                #${this._containerId} .cesium-credit-logoContainer,
                #${this._containerId} .cesium-credit-expand-link { display:none !important; }
                
                @keyframes puiPulseDot {
                    0% { box-shadow: 0 0 0 0 rgba(57,255,20, 0.7); }
                    70% { box-shadow: 0 0 0 10px rgba(57,255,20, 0); }
                    100% { box-shadow: 0 0 0 0 rgba(57,255,20, 0); }
                }

                /* Premium Tactical Card CSS */
                .pui-3d-tactical-card {
                    position: absolute;
                    transform: translate(25px, -50%); /* Shifted right to clear the 3D model */
                    width: 240px;
                    background: rgba(10, 22, 40, 0.85);
                    backdrop-filter: blur(8px);
                    -webkit-backdrop-filter: blur(8px);
                    border: 1px solid rgba(56, 189, 248, 0.2);
                    border-left: 3px solid #38bdf8;
                    border-radius: 6px;
                    overflow: hidden;
                    font-family: 'JetBrains Mono', monospace;
                    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.6);
                    pointer-events: auto;
                    transition: border-color 0.2s ease;
                }
                .pui-3d-tactical-card:hover {
                    border-color: rgba(56, 189, 248, 0.6);
                    z-index: 100;
                }
                .pui-3d-card-body {
                    padding: 10px 14px;
                }
                .pui-3d-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: flex-start;
                    margin-bottom: 10px;
                    border-bottom: 1px solid rgba(255,255,255,0.1);
                    padding-bottom: 8px;
                }
                .pui-3d-callsign {
                    font-size: 16px;
                    font-weight: 800;
                    color: #ffffff;
                    margin: 0;
                    line-height: 1.1;
                }
                .pui-3d-pilot {
                    font-size: 9px;
                    color: #38bdf8;
                    text-transform: uppercase;
                    max-width: 80px;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    text-align: right;
                }
                .pui-3d-route {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                    margin-bottom: 10px;
                }
                .pui-3d-icao {
                    font-size: 11px;
                    font-weight: 800;
                    color: #f8fafc;
                }
                .pui-3d-progress {
                    flex-grow: 1;
                    height: 2px;
                    background: rgba(255, 255, 255, 0.1);
                    position: relative;
                    border-radius: 2px;
                }
                .pui-3d-progress-fill {
                    position: absolute;
                    left: 0;
                    top: 0;
                    height: 100%;
                    background: linear-gradient(90deg, rgba(56,189,248,0.1) 0%, #38bdf8 100%);
                    box-shadow: 0 0 6px rgba(56, 189, 248, 0.5);
                    border-radius: 2px;
                }
                .pui-3d-telemetry {
                    display: flex;
                    justify-content: space-between;
                    color: #94a3b8;
                    font-size: 10px;
                }
                .pui-3d-val {
                    color: #ffffff;
                    font-weight: 700;
                }
            </style>
        </div>
        `;
    },

    async init(icao, lat, lon) {
        // Inject DOM
        if (document.getElementById(this._containerId)) return;
        document.body.insertAdjacentHTML('beforeend', this.getHTML(icao));
        
        const wrapper = document.getElementById(this._containerId);
        
        // Fade in
        requestAnimationFrame(() => {
            wrapper.style.opacity = '1';
        });

        // Wire close button
        document.getElementById('close-airport-3d').addEventListener('click', () => {
            wrapper.style.opacity = '0';
            setTimeout(() => this.destroy(), 500);
        });

        let Cesium;
        try { Cesium = await this._loadCesium(); } catch (err) { console.error(err); return; }
        Cesium.Ion.defaultAccessToken = null;

        const creditDiv = document.createElement('div');
        creditDiv.style.display = 'none';

        this._viewer = new Cesium.Viewer('airport-cesium-container', {
            baseLayerPicker: false, navigationHelpButton: false, animation: false,
            timeline: false, geocoder: false, homeButton: false, sceneModePicker: false,
            infoBox: false, selectionIndicator: false, fullscreenButton: false, vrButton: false,
            creditContainer: creditDiv, shouldAnimate: true, imageryProvider: false,
            terrainProvider: this._createTerrariumProvider(Cesium)
        });

        const viewer = this._viewer;
        viewer.scene.backgroundColor = Cesium.Color.fromCssColorString('#0a1628');
        viewer.scene.globe.depthTestAgainstTerrain = true;
        viewer.resolutionScale = Math.min(window.devicePixelRatio || 1.0, 1.5);
        viewer.scene.msaaSamples = 4;
        viewer.scene.highDynamicRange = true;

        // ESRI High-Res Satellite Imagery
        try {
            viewer.imageryLayers.removeAll();
            const esriProvider = await Cesium.ArcGisMapServerImageryProvider.fromUrl(
                'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer'
            );
            viewer.imageryLayers.addImageryProvider(esriProvider);
        } catch (e) { console.warn('Imagery unavailable'); }

        // --- Holographic Radar Rings (3NM, 5NM, 10NM) ---
        const rings = [
            { radiusNM: 3,  color: '#39ff14', alpha: 0.15 },
            { radiusNM: 5,  color: '#39ff14', alpha: 0.10 },
            { radiusNM: 10, color: '#39ff14', alpha: 0.05 }
        ];

        rings.forEach(ring => {
            const radiusMeters = ring.radiusNM * 1852;
            viewer.entities.add({
                position: Cesium.Cartesian3.fromDegrees(lon, lat),
                ellipse: {
                    semiMinorAxis: radiusMeters,
                    semiMajorAxis: radiusMeters,
                    material: new Cesium.ColorMaterialProperty(Cesium.Color.fromCssColorString(ring.color).withAlpha(ring.alpha)),
                    outline: true,
                    outlineColor: Cesium.Color.fromCssColorString(ring.color).withAlpha(ring.alpha * 3),
                    outlineWidth: 3.0,
                    height: 20
                }
            });

            viewer.entities.add({
                position: Cesium.Cartesian3.fromDegrees(lon, lat + (ring.radiusNM / 60)),
                label: {
                    text: `${ring.radiusNM} NM`,
                    font: 'bold 14pt "JetBrains Mono"',
                    fillColor: Cesium.Color.fromCssColorString(ring.color),
                    style: Cesium.LabelStyle.FILL_AND_OUTLINE,
                    outlineWidth: 2,
                    outlineColor: Cesium.Color.BLACK,
                    verticalOrigin: Cesium.VerticalOrigin.BOTTOM,
                    heightReference: Cesium.HeightReference.RELATIVE_TO_GROUND
                }
            });
        });

        // Add a central beacon pillar
        viewer.entities.add({
            position: Cesium.Cartesian3.fromDegrees(lon, lat, 500),
            cylinder: {
                length: 1000,
                topRadius: 10,
                bottomRadius: 10,
                material: new Cesium.ColorMaterialProperty(Cesium.Color.fromCssColorString('#39ff14').withAlpha(0.4))
            }
        });

        // --- LIVE SOCKET DATA INTEGRATION ---
        this._dataUnsubscribe = socketDataHub.subscribe('all_flights_update', (payload) => {
            const nowTime = Date.now();
            
            // Filter and store flights within 15 Nautical Miles
            payload.flights.forEach(flight => {
                const dist = this._getDistanceNM(lat, lon, flight.position.lat, flight.position.lon);
                if (dist <= 15) {
                    this._liveFlights.set(flight.flightId, { ...flight, lastSeen: nowTime });
                }
            });

            // Cleanup stale flights
            for (const [id, flight] of this._liveFlights.entries()) {
                if (nowTime - flight.lastSeen > 10000) {
                    this._liveFlights.delete(id);
                    const tag = this._htmlTags.get(id);
                    if (tag) {
                        tag.element.remove();
                        if (tag.entity) viewer.entities.remove(tag.entity);
                        this._htmlTags.delete(id);
                    }
                }
            }
        });

        // --- HOLOGRAPHIC HTML RENDERING LOOP (3D Models + Premium Cards) ---
        this._renderTagsHandler = () => {
            const tagsContainer = document.getElementById('airport-3d-flight-tags');
            if (!tagsContainer || !this._viewer) return;

            for (const [id, flight] of this._liveFlights.entries()) {
                let tagData = this._htmlTags.get(id);
                const altMeters = flight.position.alt_ft * 0.3048;
                const cartesianPos = Cesium.Cartesian3.fromDegrees(flight.position.lon, flight.position.lat, altMeters);
                
                // Calculate rotation (-90 offset is required because standard 3D aircraft models face +X/East natively)
                const headingRad = Cesium.Math.toRadians((flight.position.heading_deg || 0) - 90);
                const orientation = Cesium.Transforms.headingPitchRollQuaternion(
                    cartesianPos,
                    new Cesium.HeadingPitchRoll(headingRad, 0, 0)
                );

                // Initialize the physical 3D Model and HTML card
                if (!tagData) {
                    const entity = viewer.entities.add({
                        position: cartesianPos,
                        orientation: orientation,
                        model: {
                            // Free standard commercial airplane provided by Cesium's Sandcastle repo
                            uri: 'https://sandcastle.cesium.com/SampleData/models/CesiumAir/Cesium_Air.glb',
                            minimumPixelSize: 64, // Ensures the plane is visible even when zoomed out
                            maximumScale: 100,    // Caps the size when zoomed in closely
                            silhouetteColor: Cesium.Color.fromCssColorString('#00ffff'), // Tactical glow
                            silhouetteSize: 1.5,
                            color: Cesium.Color.WHITE,
                            colorBlendMode: Cesium.ColorBlendMode.HIGHLIGHT
                        }
                    });

                    const el = document.createElement('div');
                    el.className = 'pui-3d-tactical-card';
                    tagsContainer.appendChild(el);
                    tagData = { element: el, entity: entity };
                    this._htmlTags.set(id, tagData);
                }

                // Push new coordinate data and rotation to the 3D entity smoothly
                tagData.entity.position = cartesianPos;
                tagData.entity.orientation = orientation;

                // Sync the 3D position to the 2D Screen Canvas for the floating card (Cesium 1.122 compatible)
                const screenPos = Cesium.SceneTransforms.worldToWindowCoordinates(viewer.scene, cartesianPos);
                
                if (screenPos) {
                    tagData.element.style.display = 'block';
                    tagData.element.style.left = `${screenPos.x}px`;
                    tagData.element.style.top = `${screenPos.y}px`;
                    
                    // Parse data
                    const callsign = flight.callsign || '---';
                    const username = flight.username || 'Unknown';
                    const type = flight.aircraft?.aircraftName || 'Unknown Airframe';
                    const depIcao = flight.departureIcao || '----';
                    const arrIcao = flight.arrivalIcao || '----';
                    const alt = Math.round(flight.position.alt_ft || 0).toLocaleString();
                    const gs = Math.round(flight.position.gs_kt || 0);

                    // Default fill for the progress bar
                    const displayPercent = (depIcao !== '----' && arrIcao !== '----') ? 50 : 0;
                    
                    tagData.element.innerHTML = `
                        <div class="pui-3d-card-body">
                            <div class="pui-3d-header">
                                <div>
                                    <h2 class="pui-3d-callsign">${callsign}</h2>
                                    <span style="font-size: 9px; color: #94a3b8; display: block; margin-top: 4px;">${type}</span>
                                </div>
                                <div class="pui-3d-pilot" title="${username}">${username}</div>
                            </div>
                            
                            <div class="pui-3d-route">
                                <span class="pui-3d-icao">${depIcao}</span>
                                <div class="pui-3d-progress">
                                    <div class="pui-3d-progress-fill" style="width: ${displayPercent}%;"></div>
                                    <svg style="position: absolute; left: ${displayPercent}%; transform: translate(-50%, -50%); top: 50%; filter: drop-shadow(0 1px 3px rgba(0,0,0,0.8));" width="12" height="12" viewBox="0 0 24 24" fill="#ffffff" xmlns="http://www.w3.org/2000/svg">
                                        <path d="M2 2L22 12L2 22L6 12L2 2Z"/>
                                    </svg>
                                </div>
                                <span class="pui-3d-icao">${arrIcao}</span>
                            </div>
                            
                            <div class="pui-3d-telemetry">
                                <span><i class="fa-solid fa-arrow-up-right-dots" style="font-size: 9px; margin-right: 4px;"></i><span class="pui-3d-val">${alt}</span> FT</span>
                                <span><i class="fa-solid fa-gauge-high" style="font-size: 9px; margin-right: 4px;"></i><span class="pui-3d-val">${gs}</span> KTS</span>
                            </div>
                        </div>
                    `;
                } else {
                    tagData.element.style.display = 'none';
                }
            }
        };
        viewer.scene.preRender.addEventListener(this._renderTagsHandler);

        // --- Free-Roam Camera Setup ---
        const centerPoint = Cesium.Cartesian3.fromDegrees(lon, lat);
        const initialRadius = 15000; 
        const heading = Cesium.Math.toRadians(0); 
        const pitch = Cesium.Math.toRadians(-25); 
        
        viewer.camera.lookAt(centerPoint, new Cesium.HeadingPitchRange(heading, pitch, initialRadius));
        viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY); // Unlocks the camera

        // Remove Loader when tiles are ready
        const tileListener = viewer.scene.globe.tileLoadProgressEvent.addEventListener((queued) => {
            if (queued === 0) {
                const loader = document.getElementById('airport-loader');
                if (loader) loader.style.display = 'none';
                tileListener();
            }
        });
        setTimeout(() => {
            const loader = document.getElementById('airport-loader');
            if (loader) loader.style.display = 'none';
        }, 5000);
    },

    destroy() {
        // Disconnect Event Bus
        if (this._dataUnsubscribe) {
            this._dataUnsubscribe();
            this._dataUnsubscribe = null;
        }

        if (this._viewer) {
            if (this._renderTagsHandler) {
                this._viewer.scene.preRender.removeEventListener(this._renderTagsHandler);
            }
            this._viewer.destroy();
            this._viewer = null;
        }
        
        this._liveFlights.clear();
        this._htmlTags.clear();

        const wrapper = document.getElementById(this._containerId);
        if (wrapper) wrapper.remove();
    }
};