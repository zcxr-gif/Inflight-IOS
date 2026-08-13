/**
 * groupFlightManager.js
 * Logic for visualizing group flights (pilots flying together).
 * Optimized to use groupId provided by the backend socket.
 */

export const GroupFlightManager = {
    _map: null,
    _isVisible: false,
    _sourceId: 'group-flights-source',
    _layerIds: ['group-links-layer', 'group-glow-layer'],

    init(map) {
        this._map = map;
        this.setupLayers();
    },

    setupLayers() {
        if (!this._map || this._map.getSource(this._sourceId)) return;

        this._map.addSource(this._sourceId, {
            type: 'geojson',
            data: { type: 'FeatureCollection', features: [] }
        });

        // 1. The "Web" Links (Lines connecting pilots in a group)
        this._map.addLayer({
            id: 'group-links-layer',
            type: 'line',
            source: this._sourceId,
            layout: { 'line-cap': 'round', 'line-join': 'round' },
            paint: {
                'line-color': '#00e6ff',
                'line-width': 1.5,
                'line-opacity': 0.6,
                'line-dasharray': [2, 1]
            },
            filter: ['==', ['geometry-type'], 'LineString']
        });

        // 2. Group Area Glow (Visual emphasis around group members)
        this._map.addLayer({
            id: 'group-glow-layer',
            type: 'circle',
            source: this._sourceId,
            paint: {
                'circle-radius': 35,
                'circle-color': '#00e6ff',
                'circle-opacity': 0.15,
                'circle-blur': 1
            },
            filter: ['==', ['geometry-type'], 'Point']
        });

        this.updateVisibility();
    },

    /**
     * Updates the group visualization using data from the socket.
     * @param {Array} flights - The array of simplified flight objects from the socket.
     */
    update(flights) {
        if (!this._isVisible || !flights || !Array.isArray(flights)) {
            this.clear();
            return;
        }

        // 1. Organize flights by their groupId provided by the backend
        const groups = {};
        flights.forEach(f => {
            if (f.groupId) {
                if (!groups[f.groupId]) groups[f.groupId] = [];
                groups[f.groupId].push(f);
            }
        });

        const features = [];

        // 2. Generate GeoJSON for each detected group
        Object.values(groups).forEach(members => {
            // Only visualize groups with 2 or more members
            if (members.length < 2) return;

            // Add Points for the Glow effect
            members.forEach(m => {
                if (m.position && m.position.lon !== null) {
                    features.push({
                        type: 'Feature',
                        geometry: {
                            type: 'Point',
                            coordinates: [m.position.lon, m.position.lat]
                        },
                        properties: { type: 'glow', groupId: m.groupId }
                    });
                }
            });

            // Create a "Star" network: Connect every member to the first member (the "Lead")
            const lead = members[0];
            for (let i = 1; i < members.length; i++) {
                if (lead.position && members[i].position) {
                    features.push({
                        type: 'Feature',
                        geometry: {
                            type: 'LineString',
                            coordinates: [
                                [lead.position.lon, lead.position.lat],
                                [members[i].position.lon, members[i].position.lat]
                            ]
                        },
                        properties: { type: 'link', groupId: lead.groupId }
                    });
                }
            }
        });

        const source = this._map.getSource(this._sourceId);
        if (source) {
            source.setData({
                type: 'FeatureCollection',
                features: features
            });
        }
    },

    clear() {
        const source = this._map?.getSource(this._sourceId);
        if (source) {
            source.setData({ type: 'FeatureCollection', features: [] });
        }
    },

    toggle(visible) {
        this._isVisible = visible;
        this.updateVisibility();
    },

    updateVisibility() {
        if (!this._map) return;
        const status = this._isVisible ? 'visible' : 'none';
        this._layerIds.forEach(id => {
            if (this._map.getLayer(id)) {
                this._map.setLayoutProperty(id, 'visibility', status);
            }
        });
    }
};