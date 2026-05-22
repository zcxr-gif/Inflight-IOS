/**
 * flownPath3D.js
 * Handles the rendering of 3D flight trails, vertical curtains, and 3D path-aligned labels.
 */

export const FlownPath3D = {
    flightObjects: {},
    font: null,
    
    // Performance Constants
    MAX_POINTS: 5000, 
    SAMPLES_PER_POINT: 8, 
    RADIAL_SEGMENTS: 6,   
    BASE_THICKNESS: 0.0000035,

    // Altitude Color Config (Feet)
    ALTITUDE_STOPS: [
        { alt: 0, color: new window.THREE.Color(0xf97316) },     
        { alt: 10000, color: new window.THREE.Color(0xfacc15) }, 
        { alt: 25000, color: new window.THREE.Color(0x38bdf8) }, 
        { alt: 40000, color: new window.THREE.Color(0x818cf8) }  
    ],

    /**
     * Loads the font required for 3D labels.
     */
    async _loadFont() {
        if (this.font) return this.font;
        
        const THREE = window.THREE;
        
        if (!THREE.FontLoader) {
            await this._loadScript('https://cdn.jsdelivr.net/npm/three@0.145.0/examples/js/loaders/FontLoader.js');
        }

        const loader = new THREE.FontLoader();
        return new Promise((resolve, reject) => {
            loader.load('https://cdn.jsdelivr.net/npm/three@0.145.0/examples/fonts/helvetiker_regular.typeface.json', (response) => {
                this.font = response;
                resolve(response);
            }, undefined, reject);
        });
    },

    _loadScript(url) {
        return new Promise((resolve) => {
            const script = document.createElement('script');
            script.src = url;
            script.onload = resolve;
            document.head.appendChild(script);
        });
    },

    _getColorForAlt(alt) {
        const stops = this.ALTITUDE_STOPS;
        if (alt <= stops[0].alt) return stops[0].color;
        if (alt >= stops[stops.length - 1].alt) return stops[stops.length - 1].color;

        for (let i = 0; i < stops.length - 1; i++) {
            const s1 = stops[i];
            const s2 = stops[i + 1];
            if (alt >= s1.alt && alt <= s2.alt) {
                const t = (alt - s1.alt) / (s2.alt - s1.alt);
                return new window.THREE.Color().copy(s1.color).lerp(s2.color, t);
            }
        }
        return stops[0].color;
    },

    async updatePath(map, flightId, trailData, is3DEnabled) {
        if (!map || !flightId) return;
        const layerId = `layer-3d-path-${flightId}`;

        if (!is3DEnabled || !trailData || trailData.length < 2) {
            this.clearPath(map, flightId);
            return;
        }

        try {
            await this._loadFont();
        } catch (e) {
            console.error("Failed to load 3D Font for labels", e);
        }

        if (!map.getLayer(layerId)) {
            const customLayer = this._createCustomLayer(layerId, flightId, trailData);
            map.addLayer(customLayer);
        } else {
            this._updateGeometry(map, flightId, trailData);
        }
        map.triggerRepaint();
    },

    _createCustomLayer(layerId, flightId, trailData) {
        const THREE = window.THREE;
        const self = this;
        
        return {
            id: layerId,
            type: 'custom',
            renderingMode: '3d',
            onAdd: function (map, gl) {
                this.camera = new THREE.Camera();
                this.scene = new THREE.Scene();

                this.geometry = new THREE.BufferGeometry();
                const totalTubeVertices = self.MAX_POINTS * self.SAMPLES_PER_POINT * (self.RADIAL_SEGMENTS + 1);
                this.geometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(totalTubeVertices * 3), 3));
                this.geometry.setAttribute('normal', new THREE.BufferAttribute(new Float32Array(totalTubeVertices * 3), 3));
                this.geometry.setAttribute('color', new THREE.BufferAttribute(new Float32Array(totalTubeVertices * 3), 3));
                
                this.material = new THREE.MeshBasicMaterial({ 
                    vertexColors: true,
                    side: THREE.DoubleSide
                });
                this.mesh = new THREE.Mesh(this.geometry, this.material);
                this.mesh.frustumCulled = false; 
                this.scene.add(this.mesh);

                this.curtainGeometry = new THREE.BufferGeometry();
                const totalCurtainVertices = self.MAX_POINTS * self.SAMPLES_PER_POINT * 2;
                this.curtainGeometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(totalCurtainVertices * 3), 3));
                this.curtainGeometry.setAttribute('color', new THREE.BufferAttribute(new Float32Array(totalCurtainVertices * 3), 3));
                
                this.curtainMaterial = new THREE.MeshBasicMaterial({
                    vertexColors: true,
                    transparent: true,
                    opacity: 0.4,
                    side: THREE.DoubleSide
                });
                this.curtainMesh = new THREE.Mesh(this.curtainGeometry, this.curtainMaterial);
                this.curtainMesh.frustumCulled = false;
                this.scene.add(this.curtainMesh);

                this.labelGroup = new THREE.Group();
                this.scene.add(this.labelGroup);

                FlownPath3D.flightObjects[flightId] = this;

                this.renderer = new THREE.WebGLRenderer({
                    canvas: map.getCanvas(),
                    context: gl,
                    antialias: true
                });
                this.renderer.autoClear = false;

                FlownPath3D._updateGeometry(map, flightId, trailData);
            },
            render: function (gl, matrix) {
                const m = new THREE.Matrix4().fromArray(matrix);
                this.camera.projectionMatrix = m;
                this.renderer.resetState(); 
                this.renderer.render(this.scene, this.camera);
            }
        };
    },

    _updateGeometry(map, flightId, trailData) {
        if (!trailData || trailData.length < 2) return;
        
        const THREE = window.THREE;
        const layerObj = this.flightObjects[flightId];
        if (!layerObj) return;

        const points = [];
        const rawAltitudes = []; 
        
        trailData.forEach((p) => {
            const alt = p.altitude || p.alt || 0;
            const altMeters = alt * 0.3048; 
            const coord = window.mapboxgl.MercatorCoordinate.fromLngLat([p.longitude || p.lon, p.latitude || p.lat], altMeters);
            points.push(new THREE.Vector3(coord.x, coord.y, coord.z));
            rawAltitudes.push(alt);
        });

        const curve = new THREE.CatmullRomCurve3(points, false, 'centripetal');
        const tubularSegments = Math.min((points.length - 1) * this.SAMPLES_PER_POINT, this.MAX_POINTS - 1);
        
        const tempTube = new THREE.TubeGeometry(curve, tubularSegments, this.BASE_THICKNESS, this.RADIAL_SEGMENTS, false);
        
        const posAttr = layerObj.geometry.attributes.position;
        const colorAttr = layerObj.geometry.attributes.color;
        const tempPos = tempTube.attributes.position;

        for (let i = 0; i < tempPos.count; i++) {
            const ringIdx = Math.floor(i / (this.RADIAL_SEGMENTS + 1));
            const progress = ringIdx / tubularSegments;
            const floatIdx = progress * (rawAltitudes.length - 1);
            const idx1 = Math.floor(floatIdx);
            const idx2 = Math.min(idx1 + 1, rawAltitudes.length - 1);
            const weight = floatIdx - idx1;
            const currentAlt = (rawAltitudes[idx1] * (1 - weight)) + (rawAltitudes[idx2] * weight);
            const color = this._getColorForAlt(currentAlt);
            
            posAttr.setXYZ(i, tempPos.getX(i), tempPos.getY(i), tempPos.getZ(i));
            colorAttr.setXYZ(i, color.r, color.g, color.b);
        }

        layerObj.geometry.setIndex(tempTube.index);
        posAttr.needsUpdate = true;
        colorAttr.needsUpdate = true;
        layerObj.geometry.setDrawRange(0, tempTube.index.count);

        const curtainPosAttr = layerObj.curtainGeometry.attributes.position;
        const curtainColorAttr = layerObj.curtainGeometry.attributes.color;
        const curvePoints = curve.getPoints(tubularSegments);
        const curtainIndices = [];

        for (let i = 0; i <= tubularSegments; i++) {
            const p = curvePoints[i];
            const idx = i * 2;
            const floatIdx = (i / tubularSegments) * (rawAltitudes.length - 1);
            const alt = rawAltitudes[Math.round(floatIdx)];
            const color = this._getColorForAlt(alt);

            curtainPosAttr.setXYZ(idx, p.x, p.y, p.z);     
            curtainPosAttr.setXYZ(idx + 1, p.x, p.y, 0); 
            curtainColorAttr.setXYZ(idx, color.r, color.g, color.b);
            curtainColorAttr.setXYZ(idx + 1, color.r, color.g, color.b);

            if (i > 0) {
                const curr = i * 2; const prev = (i - 1) * 2;
                curtainIndices.push(prev, prev + 1, curr, prev + 1, curr + 1, curr);
            }
        }
        curtainPosAttr.needsUpdate = true;
        curtainColorAttr.needsUpdate = true;
        layerObj.curtainGeometry.setIndex(curtainIndices);
        layerObj.curtainGeometry.setDrawRange(0, curtainIndices.length);

        this._updateLabels(layerObj, curve, trailData);

        tempTube.dispose();
    },

    /**
     * Renders labels that adjust their size based on the vertical space (curtain height).
     */
    _updateLabels(layerObj, curve, trailData) {
        const THREE = window.THREE;
        if (!this.font) return;

        // Clear existing labels
        while(layerObj.labelGroup.children.length > 0){ 
            const child = layerObj.labelGroup.children[0];
            if (child.geometry) child.geometry.dispose();
            if (child.material) child.material.dispose();
            layerObj.labelGroup.remove(child); 
        }

        // Labels at 35% and 70% of the path
        const labelIntervals = [0.35, 0.70]; 
        const offsetDist = 0.000004;

        labelIntervals.forEach(t => {
            const pos = curve.getPointAt(t);
            const tangent = curve.getTangentAt(t).normalize();
            const rawIdx = Math.floor(t * (trailData.length - 1));
            const point = trailData[rawIdx];
            const alt = point.altitude || point.alt || 0;

            const lines = [ `${Math.round(alt).toLocaleString()} FT` ];

            /**
             * SPACE ADJUSTMENT LOGIC
             * Available vertical space is pos.z (altitude in Mercator units).
             */
            const curtainHeight = pos.z; 
            const maxAllowedHeight = curtainHeight * 0.75; // Leave 25% padding
            
            // Standard size for high altitudes
            const baseSize = 0.000040; 
            
            // Calculate total height if we used the base size
            const estimatedTotalHeight = lines.length * (baseSize * 1.3);
            
            // If the estimated height is too big for the curtain, scale it down
            const scaleFactor = estimatedTotalHeight > maxAllowedHeight 
                ? maxAllowedHeight / estimatedTotalHeight 
                : 1;

            const labelSize = baseSize * scaleFactor;
            const lineHeight = labelSize * 1.3;

            const up = new THREE.Vector3(0, 0, 1);
            const side = new THREE.Vector3().crossVectors(tangent, up).normalize();
            
            // Anchor label perfectly in the middle of the curtain
            const centeredZ = curtainHeight / 2; 

            const createLabelLine = (text, lineOffset, direction) => {
                const shapes = this.font.generateShapes(text, labelSize);
                const textGeo = new THREE.ShapeGeometry(shapes);
                
                textGeo.computeBoundingBox();
                const centerOffset = new THREE.Vector3();
                textGeo.boundingBox.getCenter(centerOffset).multiplyScalar(-1);
                textGeo.translate(centerOffset.x, centerOffset.y, centerOffset.z);

                const textMat = new THREE.MeshBasicMaterial({ 
                    color: 0xffffff,
                    side: THREE.FrontSide,
                    transparent: true,
                    opacity: 0.9,
                    depthTest: true, 
                    depthWrite: true,
                    polygonOffset: true,
                    polygonOffsetFactor: -1,
                    polygonOffsetUnits: -1
                });

                const mesh = new THREE.Mesh(textGeo, textMat);
                // Position is centered in curtain, then adjusted by lineOffset
                mesh.position.set(pos.x, pos.y, centeredZ - lineOffset);
                
                const horizontalOffset = side.clone().multiplyScalar(direction * offsetDist);
                mesh.position.add(horizontalOffset);

                const zAxis = side.clone().multiplyScalar(-direction); 
                const yAxis = up.clone();
                const xAxis = new THREE.Vector3().crossVectors(yAxis, zAxis).normalize();
                
                const matrix = new THREE.Matrix4();
                matrix.makeBasis(xAxis, yAxis, zAxis);
                mesh.quaternion.setFromRotationMatrix(matrix);

                layerObj.labelGroup.add(mesh);
            };

            lines.forEach((lineText, index) => {
                const verticalOffset = (index - (lines.length - 1) / 2) * lineHeight;
                createLabelLine(lineText, verticalOffset, -1); // Side A
                createLabelLine(lineText, verticalOffset, 1);  // Side B
            });
        });
    },
    
    clearPath(map, flightId) {
        const layerId = `layer-3d-path-${flightId}`;
        const layerObj = this.flightObjects[flightId];

        if (layerObj) {
            [layerObj.mesh, layerObj.curtainMesh].forEach(mesh => {
                if (mesh) {
                    if (mesh.geometry) mesh.geometry.dispose();
                    if (mesh.material) mesh.material.dispose();
                }
            });
            layerObj.labelGroup.children.forEach(label => {
                if (label.geometry) label.geometry.dispose();
                if (label.material) label.material.dispose();
            });
        }

        if (map.getLayer(layerId)) map.removeLayer(layerId);
        delete this.flightObjects[flightId];
    },

    clearAllPaths(map) {
        if (!map) return;
        Object.keys(this.flightObjects).forEach(id => this.clearPath(map, id));
    }
};