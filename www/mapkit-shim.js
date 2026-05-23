/**
 * mapkit-shim.js
 *
 * Exposes a `mapboxgl`-compatible surface on `window` that routes calls to the
 * native MapKit Capacitor plugin (`InflightMapkit`) when running inside the iOS
 * app, and falls back to a no-op stub elsewhere.
 *
 * Goal: existing call sites (`new mapboxgl.Map(...)`, `addSource`, `addLayer`,
 * `setData`, `setFilter`, `setPaintProperty`, `Marker`, `Popup`, `LngLatBounds`)
 * keep working without code changes. The shim translates mapbox-style sources
 * + layers + filters into MapKit annotation/overlay calls.
 *
 * What works:
 *  - Map creation, camera, fitBounds, style switching (8 named styles → MKMapType)
 *  - GeoJSON sources for Point/LineString/Polygon features
 *  - symbol/circle layers → native annotations
 *  - line layers → MKPolyline overlays
 *  - fill layers → MKPolygon overlays
 *  - setFilter (equality + simple comparisons)
 *  - visibility via setLayoutProperty
 *  - on('load'), on('style.load') events
 *  - Markers and basic LngLatBounds math
 *
 * What is intentionally stubbed (see MIGRATION.md):
 *  - mapbox-gl style expressions beyond constants
 *  - feature-state hover effects
 *  - queryRenderedFeatures hit-testing (use annotationTap event instead)
 *  - HTML popups overlaid on the map
 *  - custom WebGL layers / MercatorCoordinate / Three.js 3D paths
 *  - globe projection (MapKit always renders on its own projection)
 *  - terrain / hillshade / sky layers
 */

(function () {
    'use strict';

    const NativePlugin = (window.Capacitor && window.Capacitor.registerPlugin)
        ? window.Capacitor.registerPlugin('InflightMapkit')
        : null;

    const isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());

    const STYLE_TO_MAPTYPE = {
        'dark': 'dark',
        'light': 'light',
        'satellite': 'satellite',
        'outdoors': 'outdoors',
        'nav-dark': 'nav-dark',
        'nav-light': 'nav-light',
        'traffic-night': 'traffic-night',
        'traffic-day': 'traffic-day'
    };

    function resolveMapType(style) {
        if (!style) return 'standard';
        if (typeof style !== 'string') return 'standard';
        const s = style.toLowerCase();
        for (const key of Object.keys(STYLE_TO_MAPTYPE)) {
            if (s.includes(key)) return STYLE_TO_MAPTYPE[key];
        }
        if (s.includes('satellite')) return 'satellite';
        if (s.includes('dark')) return 'dark';
        if (s.includes('light')) return 'light';
        return 'standard';
    }

    function evaluateFilter(filter, feature) {
        // Mapbox filter expressions: ['==', key, val], ['!=', key, val], ['in', key, ...vals], ['all', ...subs]
        if (!filter || !Array.isArray(filter) || filter.length === 0) return true;
        const op = filter[0];
        const props = (feature && feature.properties) || {};
        const get = (k) => k === '$type' ? (feature.geometry && feature.geometry.type) : props[k];
        switch (op) {
            case 'all':
                return filter.slice(1).every(sub => evaluateFilter(sub, feature));
            case 'any':
                return filter.slice(1).some(sub => evaluateFilter(sub, feature));
            case '==':
                return get(filter[1]) === filter[2];
            case '!=':
                return get(filter[1]) !== filter[2];
            case '>':
                return get(filter[1]) > filter[2];
            case '<':
                return get(filter[1]) < filter[2];
            case '>=':
                return get(filter[1]) >= filter[2];
            case '<=':
                return get(filter[1]) <= filter[2];
            case 'in':
                return filter.slice(2).indexOf(get(filter[1])) >= 0;
            case '!in':
                return filter.slice(2).indexOf(get(filter[1])) < 0;
            case 'has':
                return get(filter[1]) !== undefined && get(filter[1]) !== null;
            case '!has':
                return get(filter[1]) === undefined || get(filter[1]) === null;
            default:
                return true;
        }
    }

    function resolvePaint(value, feature) {
        // Only constant values are supported. Anything else falls through to default.
        if (value == null) return undefined;
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value;
        if (Array.isArray(value)) {
            // ['get', 'prop'] style
            if (value[0] === 'get' && feature && feature.properties) return feature.properties[value[1]];
        }
        return undefined;
    }

    function flattenFeatures(geojson) {
        if (!geojson) return [];
        if (geojson.type === 'FeatureCollection') return geojson.features || [];
        if (geojson.type === 'Feature') return [geojson];
        if (geojson.type && geojson.coordinates) return [{ type: 'Feature', geometry: geojson, properties: {} }];
        return [];
    }

    function rgbaFromAny(c) {
        if (!c) return undefined;
        if (typeof c !== 'string') return undefined;
        const s = c.trim();
        if (s.startsWith('#')) return s;
        const rgba = s.match(/rgba?\(([^)]+)\)/i);
        if (rgba) {
            const parts = rgba[1].split(',').map(p => parseFloat(p.trim()));
            const r = Math.max(0, Math.min(255, parts[0] | 0)).toString(16).padStart(2, '0');
            const g = Math.max(0, Math.min(255, parts[1] | 0)).toString(16).padStart(2, '0');
            const b = Math.max(0, Math.min(255, parts[2] | 0)).toString(16).padStart(2, '0');
            const a = parts.length > 3
                ? Math.max(0, Math.min(255, Math.round(parts[3] * 255))).toString(16).padStart(2, '0')
                : 'ff';
            return '#' + r + g + b + a;
        }
        return s;
    }

    // ----------------------------------------------------------------------
    // LngLatBounds
    // ----------------------------------------------------------------------
    class LngLatBounds {
        constructor(sw, ne) {
            this._sw = sw ? this._coerce(sw) : null;
            this._ne = ne ? this._coerce(ne) : null;
        }
        _coerce(c) {
            if (Array.isArray(c)) return { lng: c[0], lat: c[1] };
            if (c && typeof c.lng === 'number') return { lng: c.lng, lat: c.lat };
            return null;
        }
        extend(coord) {
            const c = this._coerce(coord);
            if (!c) return this;
            if (!this._sw) { this._sw = { lng: c.lng, lat: c.lat }; this._ne = { lng: c.lng, lat: c.lat }; return this; }
            this._sw.lng = Math.min(this._sw.lng, c.lng);
            this._sw.lat = Math.min(this._sw.lat, c.lat);
            this._ne.lng = Math.max(this._ne.lng, c.lng);
            this._ne.lat = Math.max(this._ne.lat, c.lat);
            return this;
        }
        getSouthWest() { return this._sw; }
        getNorthEast() { return this._ne; }
        isEmpty() { return !this._sw || !this._ne; }
    }

    // ----------------------------------------------------------------------
    // MercatorCoordinate stub (3D paths are deferred — see MIGRATION.md)
    // ----------------------------------------------------------------------
    const MercatorCoordinate = {
        fromLngLat(lngLat, altitude = 0) {
            const lng = Array.isArray(lngLat) ? lngLat[0] : lngLat.lng;
            const lat = Array.isArray(lngLat) ? lngLat[1] : lngLat.lat;
            return { x: lng, y: lat, z: altitude, meterInMercatorCoordinateUnits: () => 1 };
        }
    };

    // ----------------------------------------------------------------------
    // Marker
    // ----------------------------------------------------------------------
    let markerSeq = 0;
    class Marker {
        constructor(elOrOpts, opts) {
            let element = null;
            let options = {};
            if (elOrOpts instanceof HTMLElement) {
                element = elOrOpts;
                options = opts || {};
            } else if (elOrOpts && typeof elOrOpts === 'object') {
                options = elOrOpts;
                element = options.element || null;
            }
            this._element = element;
            this._options = options;
            this._lngLat = null;
            this._map = null;
            this._id = 'marker_' + (++markerSeq);
            this._rotation = options.rotation || 0;
            this._color = options.color || '#3A8DFF';
        }
        setLngLat(lngLat) {
            this._lngLat = Array.isArray(lngLat) ? { lng: lngLat[0], lat: lngLat[1] } : lngLat;
            if (this._map) this._map._upsertStandaloneMarker(this);
            return this;
        }
        getLngLat() { return this._lngLat; }
        setRotation(deg) {
            this._rotation = deg;
            if (this._map) this._map._upsertStandaloneMarker(this);
            return this;
        }
        getElement() { return this._element; }
        setPopup() { return this; }
        addTo(map) {
            this._map = map;
            map._upsertStandaloneMarker(this);
            return this;
        }
        remove() {
            if (this._map) this._map._removeStandaloneMarker(this);
            this._map = null;
            return this;
        }
    }

    // ----------------------------------------------------------------------
    // Popup (no-op visual; APIs preserved so existing code doesn't crash)
    // ----------------------------------------------------------------------
    class Popup {
        constructor(opts) { this._opts = opts || {}; this._html = ''; this._lngLat = null; this._map = null; }
        setLngLat(c) { this._lngLat = c; return this; }
        setHTML(h) { this._html = h; return this; }
        setText(t) { this._html = t; return this; }
        setDOMContent(node) { this._html = node && node.outerHTML; return this; }
        addTo(map) { this._map = map; return this; }
        remove() { this._map = null; return this; }
        isOpen() { return !!this._map; }
        getElement() { return null; }
        addClassName() { return this; }
        removeClassName() { return this; }
        trackPointer() { return this; }
    }

    // ----------------------------------------------------------------------
    // Map
    // ----------------------------------------------------------------------
    let mapSeq = 0;

    class InflightMap {
        constructor(opts) {
            this._id = 'map_' + (++mapSeq);
            this._opts = opts || {};
            this._container = (opts.container instanceof HTMLElement)
                ? opts.container
                : document.getElementById(opts.container);
            if (!this._container) {
                console.warn('[mapkit-shim] container not found:', opts.container);
            } else {
                this._container.style.background = 'transparent';
            }
            this._listeners = {};
            this._sources = new Map();
            this._layers = new Map();      // layerId -> { id, type, source, paint, layout, filter, visibility }
            this._layerOrder = [];
            this._standaloneMarkers = new Map();
            this._style = opts.style || 'standard';
            this._mapType = resolveMapType(this._style);
            this._loaded = false;
            this._destroyed = false;
            this._pendingPushes = new Set();
            this._pushTimer = null;

            this._resizeObserver = null;
            this._lastFrame = null;
            this._frameRetryTimer = null;

            if (NativePlugin && isNative) {
                this._initNative();
            } else {
                // Fallback for web/dev: fire load on next tick so consumers don't hang.
                setTimeout(() => this._fireLoaded(), 0);
            }
        }

        _initNative() {
            const frame = this._measureFrame();
            this._lastFrame = frame;

            NativePlugin.addListener('load', (data) => {
                if (data && data.mapId === this._id) this._fireLoaded();
            });
            NativePlugin.addListener('regionChange', (data) => {
                if (data && data.mapId === this._id) this._fire('move', data);
            });
            NativePlugin.addListener('mapTap', (data) => {
                if (data && data.mapId === this._id) this._fire('click', { lngLat: { lng: data.lng, lat: data.lat } });
            });
            NativePlugin.addListener('annotationTap', (data) => {
                if (data && data.mapId === this._id) this._fire('annotationTap', data);
            });

            const center = this._opts.center || [0, 0];
            NativePlugin.create({
                mapId: this._id,
                frame,
                center: { lng: center[0], lat: center[1] },
                zoom: this._opts.zoom || 2,
                mapType: this._mapType
            }).catch(err => console.error('[mapkit-shim] create failed', err));

            this._watchFrame();
        }

        _measureFrame() {
            if (!this._container) return { x: 0, y: 0, width: 0, height: 0 };
            const r = this._container.getBoundingClientRect();
            const scale = window.visualViewport && window.visualViewport.scale ? window.visualViewport.scale : 1;
            return {
                x: r.left * scale,
                y: r.top * scale,
                width: r.width * scale,
                height: r.height * scale
            };
        }

        _watchFrame() {
            if (!this._container) return;
            const pushIfChanged = () => {
                if (this._destroyed) return;
                const f = this._measureFrame();
                const prev = this._lastFrame;
                if (!prev || prev.x !== f.x || prev.y !== f.y || prev.width !== f.width || prev.height !== f.height) {
                    this._lastFrame = f;
                    if (NativePlugin) NativePlugin.setFrame({ mapId: this._id, frame: f }).catch(() => {});
                }
            };
            this._resizeObserver = new ResizeObserver(pushIfChanged);
            this._resizeObserver.observe(this._container);
            window.addEventListener('resize', pushIfChanged, { passive: true });
            window.addEventListener('scroll', pushIfChanged, { passive: true });
        }

        _fireLoaded() {
            if (this._loaded) return;
            this._loaded = true;
            this._fire('load');
            this._fire('style.load');
            this._fire('styledata');
            this._fire('idle');
        }

        _fire(event, payload) {
            const handlers = this._listeners[event] || [];
            handlers.slice().forEach(h => {
                try { h(payload || { type: event, target: this }); }
                catch (e) { console.error('[mapkit-shim] handler error for ' + event, e); }
            });
        }

        // ---- Public API mirrors mapbox-gl ----

        on(event, cb) {
            (this._listeners[event] = this._listeners[event] || []).push(cb);
            if (event === 'load' && this._loaded) {
                setTimeout(() => cb({ type: 'load', target: this }), 0);
            }
            return this;
        }
        off(event, cb) {
            const arr = this._listeners[event];
            if (!arr) return this;
            const i = arr.indexOf(cb);
            if (i >= 0) arr.splice(i, 1);
            return this;
        }
        once(event, cb) {
            const wrapped = (e) => { this.off(event, wrapped); cb(e); };
            this.on(event, wrapped);
            return this;
        }

        isStyleLoaded() { return this._loaded; }
        loaded() { return this._loaded; }

        getCanvas() {
            // Return a phantom element so callers that read .style.cursor don't crash.
            return this._container || document.createElement('div');
        }
        getContainer() { return this._container; }

        getStyle() { return { name: this._style, layers: Array.from(this._layers.values()), sources: {} }; }
        setStyle(style) {
            this._style = style;
            this._mapType = resolveMapType(style);
            if (NativePlugin) NativePlugin.setMapType({ mapId: this._id, mapType: this._mapType }).catch(() => {});
            // mapbox preserves sources/layers on setStyle; we do the same.
            setTimeout(() => { this._fire('style.load'); this._fire('styledata'); }, 0);
            this._reapplyAllLayers();
            return this;
        }

        setProjection() { return this; }
        setTerrain() { return this; }
        setFog() { return this; }
        setLight() { return this; }

        addControl() { return this; }
        removeControl() { return this; }
        hasControl() { return false; }

        loadImage(url, cb) { setTimeout(() => cb(null, null), 0); }
        addImage() { return this; }
        hasImage() { return false; }
        removeImage() { return this; }

        // ---- Camera ----

        setCenter(c) {
            const center = Array.isArray(c) ? { lng: c[0], lat: c[1] } : c;
            if (NativePlugin) NativePlugin.setCamera({ mapId: this._id, center }).catch(() => {});
            return this;
        }
        setZoom(z) {
            if (NativePlugin) NativePlugin.setCamera({ mapId: this._id, zoom: z }).catch(() => {});
            return this;
        }
        flyTo(opts) { return this.jumpTo(opts); }
        easeTo(opts) { return this.jumpTo(opts); }
        jumpTo(opts) {
            const center = Array.isArray(opts.center)
                ? { lng: opts.center[0], lat: opts.center[1] }
                : opts.center;
            if (NativePlugin) {
                NativePlugin.setCamera({
                    mapId: this._id,
                    center,
                    zoom: opts.zoom,
                    pitch: opts.pitch,
                    bearing: opts.bearing,
                    animated: opts.duration !== 0
                }).catch(() => {});
            }
            return this;
        }
        fitBounds(bounds, opts) {
            opts = opts || {};
            let sw, ne;
            if (bounds instanceof LngLatBounds) {
                sw = bounds.getSouthWest(); ne = bounds.getNorthEast();
            } else if (Array.isArray(bounds)) {
                sw = Array.isArray(bounds[0]) ? { lng: bounds[0][0], lat: bounds[0][1] } : bounds[0];
                ne = Array.isArray(bounds[1]) ? { lng: bounds[1][0], lat: bounds[1][1] } : bounds[1];
            } else { return this; }
            const pad = opts.padding;
            const p = typeof pad === 'number'
                ? { top: pad, right: pad, bottom: pad, left: pad }
                : (pad || { top: 40, right: 40, bottom: 40, left: 40 });
            if (NativePlugin) {
                NativePlugin.fitBounds({
                    mapId: this._id, sw, ne,
                    paddingTop: p.top, paddingRight: p.right,
                    paddingBottom: p.bottom, paddingLeft: p.left
                }).catch(() => {});
            }
            return this;
        }

        // ---- Sources ----

        addSource(id, source) {
            this._sources.set(id, { id, ...source, _data: source.data || { type: 'FeatureCollection', features: [] } });
            this._scheduleSync();
            return this;
        }
        getSource(id) {
            const src = this._sources.get(id);
            if (!src) return undefined;
            const self = this;
            return {
                setData(data) {
                    src._data = data;
                    self._invalidateLayersUsingSource(id);
                    return this;
                },
                _data: src._data,
                id
            };
        }
        removeSource(id) {
            this._sources.delete(id);
            // remove all layers depending on it
            for (const [layerId, layer] of this._layers) {
                if (layer.source === id) this.removeLayer(layerId);
            }
            return this;
        }
        getSourceData(id) {
            const s = this._sources.get(id);
            return s && s._data;
        }
        isSourceLoaded() { return true; }
        areTilesLoaded() { return true; }

        // ---- Layers ----

        addLayer(layerSpec, beforeId) {
            if (!layerSpec || !layerSpec.id) return this;
            const layer = {
                id: layerSpec.id,
                type: layerSpec.type || 'symbol',
                source: typeof layerSpec.source === 'string' ? layerSpec.source : null,
                inlineSource: typeof layerSpec.source === 'object' ? layerSpec.source : null,
                paint: layerSpec.paint || {},
                layout: layerSpec.layout || {},
                filter: layerSpec.filter || null,
                visibility: (layerSpec.layout && layerSpec.layout.visibility) || 'visible'
            };
            if (layer.inlineSource) {
                this._sources.set(layer.id + '__inline', { id: layer.id + '__inline', ...layer.inlineSource, _data: layer.inlineSource.data });
                layer.source = layer.id + '__inline';
            }
            this._layers.set(layer.id, layer);
            if (!this._layerOrder.includes(layer.id)) this._layerOrder.push(layer.id);
            this._invalidateLayer(layer.id);
            return this;
        }
        getLayer(id) { return this._layers.get(id); }
        removeLayer(id) {
            const layer = this._layers.get(id);
            if (!layer) return this;
            this._layers.delete(id);
            this._layerOrder = this._layerOrder.filter(x => x !== id);
            if (NativePlugin) {
                if (layer.type === 'symbol' || layer.type === 'circle') {
                    NativePlugin.setMarkers({ mapId: this._id, layerId: id, markers: [] }).catch(() => {});
                } else if (layer.type === 'line') {
                    NativePlugin.setPolylines({ mapId: this._id, layerId: id, polylines: [] }).catch(() => {});
                } else if (layer.type === 'fill') {
                    NativePlugin.setPolygons({ mapId: this._id, layerId: id, polygons: [] }).catch(() => {});
                }
            }
            return this;
        }
        setFilter(id, filter) {
            const layer = this._layers.get(id);
            if (!layer) return this;
            layer.filter = filter;
            this._invalidateLayer(id);
            return this;
        }
        getFilter(id) { const l = this._layers.get(id); return l ? l.filter : null; }
        setPaintProperty(id, prop, value) {
            const layer = this._layers.get(id);
            if (!layer) return this;
            layer.paint = layer.paint || {};
            layer.paint[prop] = value;
            this._invalidateLayer(id);
            return this;
        }
        setLayoutProperty(id, prop, value) {
            const layer = this._layers.get(id);
            if (!layer) return this;
            layer.layout = layer.layout || {};
            layer.layout[prop] = value;
            if (prop === 'visibility') {
                layer.visibility = value;
                if (NativePlugin) {
                    NativePlugin.setVisible({
                        mapId: this._id, layerId: id, visible: value !== 'none'
                    }).catch(() => {});
                }
            } else {
                this._invalidateLayer(id);
            }
            return this;
        }
        getLayoutProperty(id, prop) { const l = this._layers.get(id); return l && l.layout && l.layout[prop]; }
        getPaintProperty(id, prop) { const l = this._layers.get(id); return l && l.paint && l.paint[prop]; }

        setFeatureState() { return; }
        getFeatureState() { return {}; }
        removeFeatureState() { return; }

        queryRenderedFeatures() {
            // Hit-testing is delivered via annotationTap events natively.
            return [];
        }
        querySourceFeatures(sourceId) {
            const s = this._sources.get(sourceId);
            return s ? flattenFeatures(s._data) : [];
        }

        project(lngLat) { return { x: 0, y: 0 }; }
        unproject(point) { return { lng: 0, lat: 0 }; }

        resize() {
            if (NativePlugin && this._container) {
                NativePlugin.setFrame({ mapId: this._id, frame: this._measureFrame() }).catch(() => {});
            }
            return this;
        }

        remove() {
            this._destroyed = true;
            if (this._resizeObserver) this._resizeObserver.disconnect();
            if (NativePlugin) NativePlugin.destroy({ mapId: this._id }).catch(() => {});
        }

        // ---- Standalone markers ----

        _upsertStandaloneMarker(marker) {
            this._standaloneMarkers.set(marker._id, marker);
            this._pushStandaloneMarkers();
        }
        _removeStandaloneMarker(marker) {
            this._standaloneMarkers.delete(marker._id);
            this._pushStandaloneMarkers();
        }
        _pushStandaloneMarkers() {
            if (!NativePlugin) return;
            const markers = [];
            for (const m of this._standaloneMarkers.values()) {
                if (!m._lngLat) continue;
                markers.push({
                    id: m._id,
                    coord: { lng: m._lngLat.lng, lat: m._lngLat.lat },
                    color: rgbaFromAny(m._color) || '#3A8DFF',
                    rotation: m._rotation || 0
                });
            }
            NativePlugin.setMarkers({
                mapId: this._id, layerId: '__standalone__', markers
            }).catch(() => {});
        }

        // ---- Layer sync ----

        _invalidateLayer(id) { this._pendingPushes.add(id); this._scheduleSync(); }
        _invalidateLayersUsingSource(sourceId) {
            for (const [layerId, layer] of this._layers) {
                if (layer.source === sourceId) this._pendingPushes.add(layerId);
            }
            this._scheduleSync();
        }
        _scheduleSync() {
            if (this._pushTimer || !NativePlugin) return;
            this._pushTimer = setTimeout(() => {
                this._pushTimer = null;
                const ids = Array.from(this._pendingPushes);
                this._pendingPushes.clear();
                for (const id of ids) this._pushLayer(id);
            }, 16);
        }
        _reapplyAllLayers() {
            for (const id of this._layers.keys()) this._invalidateLayer(id);
        }

        _pushLayer(id) {
            const layer = this._layers.get(id);
            if (!layer || !NativePlugin) return;
            const src = layer.source ? this._sources.get(layer.source) : null;
            const data = src ? src._data : null;
            const features = flattenFeatures(data);

            if (layer.type === 'symbol' || layer.type === 'circle') {
                const markers = [];
                for (const f of features) {
                    if (!evaluateFilter(layer.filter, f)) continue;
                    const g = f.geometry;
                    if (!g) continue;
                    const coords = g.type === 'Point' ? [g.coordinates] : [];
                    for (const c of coords) {
                        markers.push({
                            id: id + ':' + ((f.properties && (f.properties.flightId || f.id)) || (markers.length)),
                            coord: { lng: c[0], lat: c[1] },
                            color: rgbaFromAny(resolvePaint(layer.paint['icon-color'] || layer.paint['circle-color'], f)) || '#3A8DFF',
                            rotation: resolvePaint(layer.layout['icon-rotate'], f) || (f.properties && (f.properties.heading || f.properties.heading_deg)) || 0,
                            title: f.properties && (f.properties.title || f.properties.name)
                        });
                    }
                }
                NativePlugin.setMarkers({ mapId: this._id, layerId: id, markers }).catch(() => {});
            } else if (layer.type === 'line') {
                const polylines = [];
                const color = rgbaFromAny(resolvePaint(layer.paint['line-color'])) || '#3A8DFF';
                const width = resolvePaint(layer.paint['line-width']) || 3;
                const dashed = !!layer.paint['line-dasharray'];
                for (const f of features) {
                    if (!evaluateFilter(layer.filter, f)) continue;
                    const g = f.geometry;
                    if (!g) continue;
                    const lines = g.type === 'LineString' ? [g.coordinates]
                                : g.type === 'MultiLineString' ? g.coordinates
                                : [];
                    let idx = 0;
                    for (const ln of lines) {
                        polylines.push({
                            id: id + ':' + (f.id || polylines.length) + ':' + (idx++),
                            coords: ln.map(c => ({ lng: c[0], lat: c[1] })),
                            color, width, dashed
                        });
                    }
                }
                NativePlugin.setPolylines({ mapId: this._id, layerId: id, polylines }).catch(() => {});
            } else if (layer.type === 'fill') {
                const polygons = [];
                const fillColor = rgbaFromAny(resolvePaint(layer.paint['fill-color'])) || '#3A8DFF33';
                const strokeColor = rgbaFromAny(resolvePaint(layer.paint['fill-outline-color'])) || fillColor;
                for (const f of features) {
                    if (!evaluateFilter(layer.filter, f)) continue;
                    const g = f.geometry;
                    if (!g) continue;
                    const polys = g.type === 'Polygon' ? [g.coordinates]
                                : g.type === 'MultiPolygon' ? g.coordinates
                                : [];
                    let idx = 0;
                    for (const rings of polys) {
                        polygons.push({
                            id: id + ':' + (f.id || polygons.length) + ':' + (idx++),
                            rings: rings.map(r => r.map(c => ({ lng: c[0], lat: c[1] }))),
                            fillColor, strokeColor, strokeWidth: 1
                        });
                    }
                }
                NativePlugin.setPolygons({ mapId: this._id, layerId: id, polygons }).catch(() => {});
            }
        }
    }

    // ----------------------------------------------------------------------
    // Public surface — `window.mapboxgl`
    // ----------------------------------------------------------------------
    const mapboxgl = {
        accessToken: '', // accepted but ignored on native
        Map: InflightMap,
        Marker: Marker,
        Popup: Popup,
        LngLatBounds: LngLatBounds,
        LngLat: function (lng, lat) { return { lng, lat }; },
        MercatorCoordinate: MercatorCoordinate,
        supported: () => true,
        clearStorage: () => {},
        prewarm: () => {},
        version: 'inflight-mapkit-shim/0.1'
    };

    Object.defineProperty(mapboxgl, 'accessToken', {
        get() { return this._token; },
        set(v) { this._token = v; },
        configurable: true,
        enumerable: true
    });

    window.mapboxgl = mapboxgl;
})();
