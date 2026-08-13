// AircraftViewer3D.js — First-Person HUD Edition with AWS Terrarium 3D Terrain
// Purpose:
//   Renders a first-person "out the windscreen" view over a high-resolution 3D Cesium 
//   globe. A dynamic holographic HUD is projected over the view, interpreting real-time 
//   pitch, roll, speed, altitude, and heading data. Features a license-free 3D terrain 
//   provider using AWS Open Data.

export const AircraftViewer3D = {

    _currentPos: { pitch: 0, roll: 0, speed: 450, heading: 45 },
    _currentAlt: 35000,

    // Live Cesium viewer + the observer that watches for its container being
    // detached. Held on the singleton so destroy() can tear them down — each
    // Viewer owns a full WebGL context, and iOS WebViews crash once a handful
    // leak, so cleanup must be deterministic rather than GC-dependent.
    _viewer: null,
    _domObserver: null,

    updateFlightData(positionObj) {
        if (!positionObj) return;
        this._currentPos.pitch   = positionObj.pitch_deg || 0;
        this._currentPos.roll    = positionObj.roll_deg  || 0;
        this._currentPos.speed   = positionObj.gs_kt     || 450;
        this._currentPos.heading = positionObj.track ?? positionObj.heading ?? positionObj.heading_deg ?? this._currentPos.heading;
        if (positionObj.alt_ft != null) this._currentAlt = positionObj.alt_ft;
    },

    // ----- HUD geometry constants (SVG viewBox is 1000 x 700) -----
    _PFD: {
        ai:       { cx: 500, cy: 350, w: 600, h: 500, x: 200, y: 100 },
        spd:      { x: 180,  y: 150, w: 100, h: 400, cy: 350, pxPerKt: 3, backboneX: 200 },
        alt:      { x: 720,  y: 150, w: 100, h: 400, cy: 350, pxPerFt: 0.3, backboneX: 800 },
        hdg:      { x: 300,  y: 50,  w: 400, h: 60,  cx: 500, cy: 80, pxPerDeg: 5, backboneY: 100 },
        pitchPxPerDeg: 9,
        bankRadius:    220
    },

    _buildPitchLadder() {
        const { ai, pitchPxPerDeg: pxd } = this._PFD;
        const out = [];
        
        out.push(
            `<line x1="${ai.cx - 400}" y1="${ai.cy}" x2="${ai.cx - 80}" y2="${ai.cy}" stroke="#39ff14" stroke-width="2"/>`,
            `<line x1="${ai.cx + 80}" y1="${ai.cy}" x2="${ai.cx + 400}" y2="${ai.cy}" stroke="#39ff14" stroke-width="2"/>`
        );

        for (let p = -90; p <= 90; p += 5) {
            if (p === 0) continue; 
            const y = ai.cy - p * pxd;
            const isMajor = (p % 10 === 0);
            const halfW = isMajor ? 90 : 40;
            
            const dashArray = p < 0 ? 'stroke-dasharray="8, 6"' : '';
            const sw = isMajor ? 2 : 1.5;

            const legDir = p > 0 ? 10 : -10; 

            out.push(
                `<polyline points="${ai.cx - halfW},${y + legDir} ${ai.cx - halfW},${y} ${ai.cx - 60},${y}" ` +
                `stroke="#39ff14" stroke-width="${sw}" fill="none" ${dashArray}/>`,
                
                `<polyline points="${ai.cx + 60},${y} ${ai.cx + halfW},${y} ${ai.cx + halfW},${y + legDir}" ` +
                `stroke="#39ff14" stroke-width="${sw}" fill="none" ${dashArray}/>`
            );

            if (isMajor && Math.abs(p) <= 80) {
                out.push(
                    `<text x="${ai.cx - halfW - 12}" y="${y + 5}" font-size="16" fill="#39ff14" ` +
                    `text-anchor="end" font-family="'JetBrains Mono','IBM Plex Mono',monospace">${Math.abs(p)}</text>`,
                    `<text x="${ai.cx + halfW + 12}" y="${y + 5}" font-size="16" fill="#39ff14" ` +
                    `text-anchor="start" font-family="'JetBrains Mono','IBM Plex Mono',monospace">${Math.abs(p)}</text>`
                );
            }
        }
        return out.join('');
    },

    _buildBankScale() {
        const { ai, bankRadius: r } = this._PFD;
        const markers = [
            { a: -60, major: true  }, { a: -45, major: true  },
            { a: -30, major: true  }, { a: -20, major: false },
            { a: -10, major: false }, { a:   0, major: true  },
            { a:  10, major: false }, { a:  20, major: false },
            { a:  30, major: true  }, { a:  45, major: true  },
            { a:  60, major: true  }
        ];
        const out = [];
        
        out.push(`<path d="M ${ai.cx - r} ${ai.cy} A ${r} ${r} 0 0 1 ${ai.cx + r} ${ai.cy}" fill="none" stroke="#39ff14" stroke-width="1" opacity="0.4"/>`);

        for (const m of markers) {
            const rad = (m.a - 90) * Math.PI / 180; 
            const tickLen = m.major ? 14 : 8;
            const x1 = ai.cx + r * Math.cos(rad);
            const y1 = ai.cy + r * Math.sin(rad);
            const x2 = ai.cx + (r - tickLen) * Math.cos(rad);
            const y2 = ai.cy + (r - tickLen) * Math.sin(rad);
            out.push(
                `<line x1="${x1.toFixed(1)}" y1="${y1.toFixed(1)}" ` +
                `x2="${x2.toFixed(1)}" y2="${y2.toFixed(1)}" ` +
                `stroke="#39ff14" stroke-width="${m.major ? 2 : 1.5}" stroke-linecap="round"/>`
            );
        }
        out.push(
            `<polygon points="${ai.cx - 7},${ai.cy - r - 3} ${ai.cx + 7},${ai.cy - r - 3} ${ai.cx},${ai.cy - r + 9}" ` +
            `fill="none" stroke="#39ff14" stroke-width="2"/>`
        );
        return out.join('');
    },

    getHTML() {
        return `
        <div id="pui-hero-3d-container"
             style="width:100%;height:100%;position:relative;overflow:hidden;background:#0a1628;">

            <div id="pui-3d-loader"
                 style="position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);
                        font-family:'Inter',sans-serif;color:rgba(57,255,20,0.85);
                        font-weight:600;font-size:0.78rem;z-index:10;
                        letter-spacing:0.12em;text-transform:uppercase;pointer-events:none;">
                <div style="display:flex;align-items:center;gap:10px;">
                    <div style="width:7px;height:7px;background:#39ff14;border-radius:50%;
                                animation:fr24Blink 1.1s ease-in-out infinite;"></div>
                    Aligning Optical Systems & Loading Terrain
                </div>
            </div>

            <div id="pui-hud-overlay"
                 style="position:absolute;top:0;left:0;width:100%;height:100%;
                        pointer-events:none;z-index:5; display:flex; align-items:center; justify-content:center;">
                
                <svg viewBox="0 0 1000 700" preserveAspectRatio="xMidYMid meet"
                     xmlns="http://www.w3.org/2000/svg"
                     style="width:100%;height:100%;max-width:1400px;display:block;">

                    <defs>
                        <filter id="hud-glow" x="-20%" y="-20%" width="140%" height="140%">
                            <feGaussianBlur stdDeviation="2" result="blur" />
                            <feComponentTransfer in="blur" result="glow">
                                <feFuncA type="linear" slope="0.8"/>
                            </feComponentTransfer>
                            <feMerge>
                                <feMergeNode in="glow" />
                                <feMergeNode in="SourceGraphic" />
                            </feMerge>
                        </filter>

                        <clipPath id="pui-hud-ai-clip">
                            <rect x="150" y="80" width="700" height="540" rx="40"/>
                        </clipPath>
                        <clipPath id="pui-hud-spd-clip">
                            <rect x="80" y="150" width="160" height="400"/>
                        </clipPath>
                        <clipPath id="pui-hud-alt-clip">
                            <rect x="760" y="150" width="160" height="400"/>
                        </clipPath>
                        <clipPath id="pui-hud-hdg-clip">
                            <rect x="300" y="30" width="400" height="70"/>
                        </clipPath>
                    </defs>

                    <g filter="url(#hud-glow)">
                        <g clip-path="url(#pui-hud-ai-clip)">
                            <g id="pui-hud-ai-roll" transform="rotate(0 500 350)">
                                <g id="pui-hud-ai-pitch" transform="translate(0 0)">
                                    ${this._buildPitchLadder()}
                                </g>
                            </g>
                        </g>

                        ${this._buildBankScale()}

                        <g id="pui-hud-bank-pointer" transform="rotate(0 500 350)">
                            <polygon points="492,120 508,120 500,134" fill="none" stroke="#39ff14" stroke-width="2"/>
                        </g>

                        <g stroke="#39ff14" stroke-width="2.5" fill="none">
                            <circle cx="500" cy="350" r="10" />
                            <line x1="430" y1="350" x2="470" y2="350"/>
                            <line x1="530" y1="350" x2="570" y2="350"/>
                            <line x1="500" y1="310" x2="500" y2="330"/>
                        </g>

                        <g>
                            <line x1="200" y1="150" x2="200" y2="550" stroke="#39ff14" stroke-width="2" opacity="0.6"/>
                            <text x="185" y="135" font-size="14" fill="#39ff14"
                                  text-anchor="end" font-family="'Inter',sans-serif"
                                  letter-spacing="2" font-weight="600">CAS</text>
                            
                            <g clip-path="url(#pui-hud-spd-clip)">
                                <g id="pui-hud-speed-ticks"></g>
                            </g>
                            
                            <polygon points="198,335 130,335 130,365 198,365 210,350"
                                     fill="rgba(0,0,0,0.5)" stroke="#39ff14" stroke-width="2"/>
                            <text id="pui-hud-speed-value" x="188" y="357"
                                  font-size="24" font-weight="700" fill="#39ff14"
                                  text-anchor="end"
                                  font-family="'JetBrains Mono','IBM Plex Mono',monospace">450</text>
                        </g>

                        <g>
                            <line x1="800" y1="150" x2="800" y2="550" stroke="#39ff14" stroke-width="2" opacity="0.6"/>
                            <text x="815" y="135" font-size="14" fill="#39ff14"
                                  text-anchor="start" font-family="'Inter',sans-serif"
                                  letter-spacing="2" font-weight="600">ALT</text>
                            
                            <g clip-path="url(#pui-hud-alt-clip)">
                                <g id="pui-hud-alt-ticks"></g>
                            </g>
                            
                            <polygon points="802,335 870,335 870,365 802,365 790,350"
                                     fill="rgba(0,0,0,0.5)" stroke="#39ff14" stroke-width="2"/>
                            <text id="pui-hud-alt-value" x="812" y="357"
                                  font-size="22" font-weight="700" fill="#39ff14"
                                  text-anchor="start"
                                  font-family="'JetBrains Mono','IBM Plex Mono',monospace">35000</text>
                        </g>

                        <g>
                            <line x1="300" y1="100" x2="700" y2="100" stroke="#39ff14" stroke-width="2" opacity="0.6"/>
                            
                            <g clip-path="url(#pui-hud-hdg-clip)">
                                <g id="pui-hud-hdg-ticks"></g>
                            </g>
                            
                            <polygon points="475,70 525,70 525,92 508,92 500,102 492,92 475,92"
                                     fill="rgba(0,0,0,0.5)" stroke="#39ff14" stroke-width="2"/>
                            <text id="pui-hud-hdg-value" x="500" y="87"
                                  font-size="20" font-weight="700" fill="#39ff14"
                                  text-anchor="middle"
                                  font-family="'JetBrains Mono','IBM Plex Mono',monospace">045</text>
                        </g>
                    </g>
                </svg>
            </div>
            
            <div style="position:absolute;top:0;left:0;width:100%;height:100%;
                        background:radial-gradient(circle, rgba(0,0,0,0) 50%, rgba(0,0,0,0.4) 100%);
                        pointer-events:none;z-index:8;"></div>
        </div>
        
        <style>
            #pui-hero-3d-container .cesium-widget-credits,
            #pui-hero-3d-container .cesium-credit-logoContainer,
            #pui-hero-3d-container .cesium-credit-expand-link { display:none !important; }
            @keyframes fr24Blink {
                0%,100% { opacity:1; transform:scale(1); box-shadow:0 0 0 0 rgba(57,255,20,0.6); }
                50%      { opacity:0.35; transform:scale(1.6); box-shadow:0 0 0 4px rgba(57,255,20,0); }
            }
        </style>
        `;
    },

    _updatePFD() {
        const pos = this._currentPos;
        const alt = this._currentAlt;
        const { ai, spd, alt: A, hdg, pitchPxPerDeg: pxd } = this._PFD;

        const aiPitch = document.getElementById('pui-hud-ai-pitch');
        if (aiPitch) aiPitch.setAttribute('transform', `translate(0 ${(pos.pitch * pxd).toFixed(2)})`);
        
        const aiRoll = document.getElementById('pui-hud-ai-roll');
        if (aiRoll) aiRoll.setAttribute('transform', `rotate(${pos.roll.toFixed(2)} ${ai.cx} ${ai.cy})`);
        
        const bankPointer = document.getElementById('pui-hud-bank-pointer');
        if (bankPointer) bankPointer.setAttribute('transform', `rotate(${pos.roll.toFixed(2)} ${ai.cx} ${ai.cy})`);

        const speedTicks = document.getElementById('pui-hud-speed-ticks');
        if (speedTicks) {
            const base = Math.floor(pos.speed / 10) * 10;
            const out = [];
            for (let i = -8; i <= 8; i++) {
                const v = base + i * 10;
                if (v < 0) continue;
                const y = spd.cy + (pos.speed - v) * spd.pxPerKt;
                if (y >= 140 && y <= 560) {
                    out.push(
                        `<line x1="${spd.backboneX}" y1="${y.toFixed(1)}" x2="${spd.backboneX - 15}" y2="${y.toFixed(1)}" ` +
                        `stroke="#39ff14" stroke-width="2"/>`,
                        `<text x="${spd.backboneX - 22}" y="${(y + 5).toFixed(1)}" font-size="16" fill="#39ff14" ` +
                        `text-anchor="end" font-family="'JetBrains Mono','IBM Plex Mono',monospace">${v}</text>`
                    );
                }
                const v5 = v + 5;
                const y5 = spd.cy + (pos.speed - v5) * spd.pxPerKt;
                if (v5 >= 0 && y5 >= 140 && y5 <= 560) {
                    out.push(`<line x1="${spd.backboneX}" y1="${y5.toFixed(1)}" x2="${spd.backboneX - 8}" y2="${y5.toFixed(1)}" ` +
                             `stroke="#39ff14" stroke-width="1.5" opacity="0.7"/>`);
                }
            }
            speedTicks.innerHTML = out.join('');
        }
        const speedValue = document.getElementById('pui-hud-speed-value');
        if (speedValue) speedValue.textContent = Math.max(0, Math.round(pos.speed));

        const altTicks = document.getElementById('pui-hud-alt-ticks');
        if (altTicks) {
            const base = Math.floor(alt / 100) * 100;
            const out = [];
            for (let i = -8; i <= 8; i++) {
                const v = base + i * 100;
                const y = A.cy + (alt - v) * A.pxPerFt;
                if (y >= 140 && y <= 560) {
                    out.push(
                        `<line x1="${A.backboneX}" y1="${y.toFixed(1)}" x2="${A.backboneX + 15}" y2="${y.toFixed(1)}" ` +
                        `stroke="#39ff14" stroke-width="2"/>`,
                        `<text x="${A.backboneX + 22}" y="${(y + 5).toFixed(1)}" font-size="16" fill="#39ff14" ` +
                        `text-anchor="start" font-family="'JetBrains Mono','IBM Plex Mono',monospace">${v}</text>`
                    );
                }
                const v5 = v + 50;
                const y5 = A.cy + (alt - v5) * A.pxPerFt;
                if (y5 >= 140 && y5 <= 560) {
                    out.push(`<line x1="${A.backboneX}" y1="${y5.toFixed(1)}" x2="${A.backboneX + 8}" y2="${y5.toFixed(1)}" ` +
                             `stroke="#39ff14" stroke-width="1.5" opacity="0.7"/>`);
                }
            }
            altTicks.innerHTML = out.join('');
        }
        const altValue = document.getElementById('pui-hud-alt-value');
        if (altValue) altValue.textContent = Math.round(alt);

        const hdgTicks = document.getElementById('pui-hud-hdg-ticks');
        if (hdgTicks) {
            const base = Math.floor(pos.heading / 10) * 10;
            const out = [];
            for (let i = -8; i <= 8; i++) {
                const vRaw = base + i * 10;
                const vNorm = ((vRaw % 360) + 360) % 360;
                const x = hdg.cx + (vRaw - pos.heading) * hdg.pxPerDeg;
                if (x >= 290 && x <= 710) {
                    out.push(`<line x1="${x.toFixed(1)}" y1="${hdg.backboneY}" x2="${x.toFixed(1)}" y2="${hdg.backboneY - 12}" stroke="#39ff14" stroke-width="2"/>`);
                    let label;
                    if      (vNorm === 0)   label = 'N';
                    else if (vNorm === 90)  label = 'E';
                    else if (vNorm === 180) label = 'S';
                    else if (vNorm === 270) label = 'W';
                    else label = String(Math.floor(vNorm / 10)).padStart(2, '0');
                    
                    const isCardinal = (vNorm % 90 === 0);
                    out.push(`<text x="${x.toFixed(1)}" y="${hdg.backboneY - 18}" font-size="${isCardinal ? 18 : 14}" ` +
                             `fill="#39ff14" font-weight="${isCardinal ? 700 : 500}" text-anchor="middle" ` +
                             `font-family="'JetBrains Mono','IBM Plex Mono',monospace">${label}</text>`);
                }
                const x5 = hdg.cx + (vRaw + 5 - pos.heading) * hdg.pxPerDeg;
                if (x5 >= 290 && x5 <= 710) {
                    out.push(`<line x1="${x5.toFixed(1)}" y1="${hdg.backboneY}" x2="${x5.toFixed(1)}" y2="${hdg.backboneY - 6}" ` +
                             `stroke="#39ff14" stroke-width="1.5" opacity="0.7"/>`);
                }
            }
            hdgTicks.innerHTML = out.join('');
        }
        const hdgValue = document.getElementById('pui-hud-hdg-value');
        if (hdgValue) {
            const h = ((Math.round(pos.heading) % 360) + 360) % 360;
            hdgValue.textContent = String(h).padStart(3, '0');
        }
    },

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
            script.onerror = () => reject(new Error('[AircraftViewer3D] Failed to load CesiumJS from CDN'));
            document.head.appendChild(script);
        });
    },

    // --- Custom License-Free Terrarium Terrain Decoder ---
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
                
                const url = this.urlTemplate
                    .replace('{z}', level)
                    .replace('{x}', x)
                    .replace('{y}', y);

                return Cesium.Resource.fetchImage({ url: url }).then((image) => {
                    this.context.drawImage(image, 0, 0, 256, 256);
                    const pixels = this.context.getImageData(0, 0, 256, 256).data;
                    const heights = new Float32Array(256 * 256);
                    
                    for (let i = 0; i < pixels.length; i += 4) {
                        const r = pixels[i];
                        const g = pixels[i + 1];
                        const b = pixels[i + 2];
                        heights[i / 4] = (r * 256 + g + b / 256) - 32768;
                    }

                    return new Cesium.HeightmapTerrainData({
                        buffer: heights,
                        width: 256,
                        height: 256,
                        structure: {
                            heightScale: 1.0,
                            heightOffset: 0.0,
                            elementsPerHeight: 1,
                            stride: 1,
                            highestEncodedValue: 256 * 256,
                            isBigEndian: false
                        }
                    });
                }).catch(() => {
                    return new Cesium.HeightmapTerrainData({
                        buffer: new Float32Array(256 * 256),
                        width: 256,
                        height: 256
                    });
                });
            }

            getLevelMaximumGeometricError(level) {
                return 77850 / Math.pow(2, level);
            }

            getTileDataAvailable(x, y, level) {
                return true;
            }
        }

        return new TerrariumTerrainProvider();
    },

    // --- Premium Procedural SkyBox Generator ---
    // Instead of stars or flat color, creates a beautiful canvas-based atmospheric gradient
    _generatePremiumSkybox(Cesium) {
        const zenithColor = '#0b1d3a';  // Deep rich blue for the stratosphere
        const horizonColor = '#7ea8d9'; // Hazy light blue for the horizon blend

        const createFace = (type) => {
            const canvas = document.createElement('canvas');
            canvas.width = 512;
            canvas.height = 512;
            const ctx = canvas.getContext('2d');

            if (type === 'up') {
                ctx.fillStyle = zenithColor;
                ctx.fillRect(0, 0, 512, 512);
            } else if (type === 'down') {
                ctx.fillStyle = horizonColor;
                ctx.fillRect(0, 0, 512, 512);
            } else {
                const grad = ctx.createLinearGradient(0, 0, 0, 512);
                grad.addColorStop(0, zenithColor);
                grad.addColorStop(1, horizonColor);
                ctx.fillStyle = grad;
                ctx.fillRect(0, 0, 512, 512);
            }
            return canvas.toDataURL('image/png');
        };

        return new Cesium.SkyBox({
            sources: {
                positiveX: createFace('side'),
                negativeX: createFace('side'),
                positiveY: createFace('side'),
                negativeY: createFace('side'),
                positiveZ: createFace('up'),
                negativeZ: createFace('down')
            }
        });
    },

async init(aircraftName, positionOrAlt = 35000, speedArg = 450, timeOverride = 'realtime') {
        const container = document.getElementById("pui-hero-3d-container");
        if (!container) return;

        // Never stack viewers: free any previous Cesium context before booting
        // a new one. Repeated mounts without this leak WebGL contexts and
        // eventually OOM-crash the iOS WebView (the "profile crashes sometimes"
        // symptom).
        this.destroy();

        let lat = 46.0, lon = 7.5, altitude = 35000, speed = 450, pitch = 0, roll = 0, heading = 45;
        if (typeof positionOrAlt === 'object' && positionOrAlt !== null) {
            lat      = positionOrAlt.lat       ?? 46.0;
            lon      = positionOrAlt.lon       ?? 7.5;
            altitude = positionOrAlt.alt_ft    ?? 35000;
            speed    = positionOrAlt.gs_kt     ?? 450;
            pitch    = positionOrAlt.pitch_deg ?? 0;
            roll     = positionOrAlt.roll_deg  ?? 0;
            heading  = positionOrAlt.track     ?? positionOrAlt.heading ?? positionOrAlt.heading_deg ?? 45;
            if (positionOrAlt.timeOfDay) timeOverride = positionOrAlt.timeOfDay;
        } else {
            altitude = positionOrAlt;
            speed    = speedArg;
        }
        this._currentPos = { pitch, roll, speed, heading };
        this._currentAlt = altitude;
        const viewerRef  = this;

        let Cesium;
        try { Cesium = await this._loadCesium(); }
        catch (err) { console.error(err); return; }

        Cesium.Ion.defaultAccessToken = null;

        const creditDiv = document.createElement('div');
        creditDiv.style.display = 'none';

        const terrainProvider = this._createTerrariumProvider(Cesium);

        const viewer = new Cesium.Viewer(container, {
            baseLayerPicker:      false,
            navigationHelpButton: false,
            animation:            false,
            timeline:             false,
            geocoder:             false,
            homeButton:           false,
            sceneModePicker:      false,
            infoBox:              false,
            selectionIndicator:   false,
            fullscreenButton:     false,
            vrButton:             false,
            creditContainer:      creditDiv,
            shouldAnimate:        true,
            imageryProvider:      false,
            terrainProvider:      terrainProvider
        });

        // Track the live viewer so destroy() (and the next init) can tear it
        // down deterministically.
        this._viewer = viewer;

        viewer.scene.backgroundColor = Cesium.Color.BLACK;

        viewer.scene.globe.terrainExaggeration = 1.25; 
        viewer.scene.globe.depthTestAgainstTerrain = true;
        viewer.scene.globe.showGroundAtmosphere = true;
        viewer.scene.globe.dynamicAtmosphereLighting = true; 
        viewer.scene.globe.enableLighting = true; 
        
        viewer.scene.screenSpaceCameraController.enableInputs = false;
        
        // PROGRESSIVE FIDELITY: Stage 1 (Fast Boot)
        viewer.resolutionScale                = Math.min(window.devicePixelRatio || 1.0, 1.5);
        viewer.scene.msaaSamples              = 1;
        viewer.scene.globe.maximumScreenSpaceError = 8.0;
        viewer.scene.globe.tileCacheSize      = 500;
        viewer.scene.globe.preloadAncestors   = false;
        viewer.scene.globe.preloadSiblings    = false;
        viewer.targetFrameRate                = 60;
        viewer.scene.requestRenderMode = false;

        try {
            viewer.imageryLayers.removeAll();
            const esriProvider = await Cesium.ArcGisMapServerImageryProvider.fromUrl(
                'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer'
            );
            viewer.imageryLayers.addImageryProvider(esriProvider);
        } catch (e) {
            console.warn('[AircraftViewer3D] Imagery resources unavailable:', e.message);
        }

        viewer.scene.skyAtmosphere.show   = true;
        viewer.scene.skyAtmosphere.hueShift = -0.05; 
        viewer.scene.skyAtmosphere.saturationShift = 0.2; 
        viewer.scene.skyAtmosphere.brightnessShift = 0.2;
        
        viewer.scene.fog.enabled          = true;
        viewer.scene.fog.density          = 0.00015; 
        viewer.scene.fog.minimumBrightness = 0.8; 

        // --- PREMIUM SOLAR TIME CALCULATOR ---
        if (timeOverride !== 'realtime') {
            const date = new Date();
            const hourMap = {
                'sunrise': 6.5,
                'morning': 9.0,
                'noon': 12.0,
                'afternoon': 15.0,
                'sunset': 18.5,
                'evening': 20.0,
                'night': 2.0,
                'midnight': 0.0
            };
            
            const targetLocalHour = hourMap[timeOverride.toLowerCase()] ?? 12.0;
            const lonOffsetHours = lon / 15.0;
            let utcDecimalHours = targetLocalHour - lonOffsetHours;
            
            while (utcDecimalHours < 0) utcDecimalHours += 24;
            while (utcDecimalHours >= 24) utcDecimalHours -= 24;
            
            const utcHours = Math.floor(utcDecimalHours);
            const utcMinutes = Math.floor((utcDecimalHours - utcHours) * 60);
            
            date.setUTCFullYear(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
            date.setUTCHours(utcHours, utcMinutes, 0, 0);
            
            viewer.clock.currentTime = Cesium.JulianDate.fromDate(date);
            viewer.clock.shouldAnimate = false; 
            viewer.scene.globe.enableLighting = true;
        } else {
            viewer.clock.currentTime = Cesium.JulianDate.now();
            viewer.clock.shouldAnimate = true;
            viewer.clock.multiplier = 1.0;
        }

        viewer.scene.light = new Cesium.SunLight();

        // PROGRESSIVE FIDELITY: Stage 2 (Heavy Assets Injection)
        setTimeout(() => {
            if (viewer.isDestroyed()) return;

            viewer.scene.msaaSamples = 4;
            viewer.scene.globe.maximumScreenSpaceError = 4.0;
            viewer.scene.globe.preloadAncestors = true;
            viewer.scene.globe.preloadSiblings = true;
            viewer.scene.globe.tileCacheSize = 1000;
            
            try { viewer.scene.postProcessStages.fxaa.enabled = true; } catch (_) {}
            try { viewer.scene.highDynamicRange = true; } catch (_) {}

            try {
                const altMetersInit = this._currentAlt * 0.3048;
                const clouds = viewer.scene.primitives.add(new Cesium.CloudCollection({
                    noiseDetail: 16.0,
                    noiseOffset: Cesium.Cartesian3.ZERO,
                }));
                for (let i = 0; i < 32; i++) {
                    clouds.add({
                        position: Cesium.Cartesian3.fromDegrees(
                            lon + (Math.random() - 0.5) * 0.5,
                            lat + (Math.random() - 0.5) * 0.5,
                            altMetersInit + (Math.random() - 0.5) * 600
                        ),
                        scale:       new Cesium.Cartesian2(2000 + Math.random() * 5000, 400 + Math.random() * 600),
                        maximumSize: new Cesium.Cartesian3(60, 30, 18),
                        slice:       0.30 + Math.random() * 0.15,
                        brightness:  0.85 + Math.random() * 0.15,
                    });
                }
            } catch (e) {
                console.warn('[AircraftViewer3D] CloudCollection unavailable:', e.message);
            }
        }, 1200);

        let animAlt   = this._currentAlt * 0.3048;
        let animPitch = pitch;
        let animRoll  = roll;

        const EARTH_RADIUS = 6378137.0;
        const t0           = performance.now();
        let lastFrameT     = performance.now();
        let loaderRemoved  = false;

        viewer.scene.postRender.addEventListener(() => {
            const now = performance.now();
            const dt  = (now - lastFrameT) / 1000.0;
            const t   = (now - t0) / 1000.0;
            lastFrameT = now;

            const currentSpeedKts   = viewerRef._currentPos.speed;
            const currentHeadingDeg = viewerRef._currentPos.heading;
            const currentHeadingRad = Cesium.Math.toRadians(currentHeadingDeg);
            const inMotion          = currentSpeedKts > 100;

            if (inMotion) {
                const speedMs        = currentSpeedKts * 0.514444;
                const distanceMeters = speedMs * dt;

                const latRad     = Cesium.Math.toRadians(lat);
                const safeLatRad = Cesium.Math.clamp(latRad, -1.5707, 1.5707);

                const dLat = (distanceMeters * Math.cos(currentHeadingRad)) / EARTH_RADIUS;
                const dLon = (distanceMeters * Math.sin(currentHeadingRad)) / (EARTH_RADIUS * Math.cos(safeLatRad));
                lat += Cesium.Math.toDegrees(dLat);
                lon += Cesium.Math.toDegrees(dLon);
            }

            const baseAltMeters = viewerRef._currentAlt * 0.3048;
            animAlt   = baseAltMeters + (inMotion ? Math.sin(t * 0.72) * 15  : 0);
            animPitch = viewerRef._currentPos.pitch + (inMotion ? Math.sin(t * 0.37) * 0.46 : 0);
            animRoll  = viewerRef._currentPos.roll  + (inMotion ? Math.sin(t * 0.25) * 0.46 : 0);

            const currentPos = Cesium.Cartesian3.fromDegrees(lon, lat, animAlt);

            viewer.camera.setView({
                destination: currentPos,
                orientation: {
                    heading: currentHeadingRad,
                    pitch:   Cesium.Math.toRadians(animPitch),
                    roll:    Cesium.Math.toRadians(animRoll)
                }
            });

            viewerRef._updatePFD();

            if (!loaderRemoved && viewer.scene.globe.tilesLoaded) {
                document.getElementById("pui-3d-loader")?.remove();
                loaderRemoved = true;
            }
        });

        setTimeout(() => {
            document.getElementById("pui-3d-loader")?.remove();
            loaderRemoved = true;
        }, 8000);

        // Safety net: if the host container is ever yanked from the DOM without
        // an explicit destroy() (e.g. a parent re-render), tear the viewer down
        // so we don't leak its WebGL context.
        const observer = new MutationObserver(() => {
            if (this._viewer === viewer && !document.contains(container)) {
                this.destroy();
            }
        });
        observer.observe(document.body, { childList: true, subtree: true });
        this._domObserver = observer;
    },

    /**
     * Tear down the live Cesium viewer and stop its render loop, releasing the
     * WebGL context. Safe to call when nothing is mounted. Callers (profile
     * close, 3D-HUD close, and the start of every init) rely on this to keep
     * exactly one viewer alive at a time — without it the iOS WebView OOM-
     * crashes after a few profile opens.
     */
    destroy() {
        try {
            if (this._domObserver) {
                this._domObserver.disconnect();
                this._domObserver = null;
            }
        } catch (_) { /* ignore */ }

        try {
            if (this._viewer && !this._viewer.isDestroyed()) {
                this._viewer.destroy();
            }
        } catch (_) { /* ignore */ }

        this._viewer = null;
    }
};