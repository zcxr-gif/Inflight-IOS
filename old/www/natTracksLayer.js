/**
 * natTracksLayer.js (Mapbox GL JS Version)
 * Updated: Added support for toggling labels, full track visibility, 
 * and persistent rendering across map style changes.
 */

const ACARS_SOCKET_URL = 'https://site--acars-backend--6dmjph8ltlhv.code.run';

const TRACK_COLOR_EXPRESSION = [
    'match',
    ['get', 'name'],
    'A', '#ff4d4d',
    'B', '#ffcc00',
    'C', '#2ecc71',
    'D', '#a29bfe',
    'E', '#e67e22',
    'F', '#00cec9',
    '#3498db'
];

export class NatTracksLayer {
    constructor(map) {
        this.map = map;
        this.sourceId = 'nat-tracks-source';
        this.lineLayerId = 'nat-tracks-layer';
        this.labelLayerId = 'nat-tracks-labels';
        this.bgLayerId = 'nat-tracks-bg-circles';
        this.airplaneLayerId = 'sector-ops-live-flights-layer'; 
        this.tracks = [];
        this.refreshInterval = null;
        this.hoveredTrackId = null;

        // Internal State for settings
        this.showTracks = true;
        this.showLabels = true;
        
        // Listen for style changes to re-inject layers and sources
        this.map.on('style.load', () => {
            this.initSource();
        });

        // Initial setup
        this.initSource();
        this.setupInteractions();
        this.fetchTracks();
    }

    /**
     * Re-initializes the GeoJSON source and all associated layers.
     * This is called on construction and every time the map style changes.
     */
    initSource() {
        // Prevent duplicate source errors if called multiple times within one style life-cycle
        if (this.map.getSource(this.sourceId)) return;

        this.map.addSource(this.sourceId, {
            type: 'geojson',
            data: { type: 'FeatureCollection', features: [] },
            generateId: true 
        });

        const beforeId = this.map.getLayer(this.airplaneLayerId) ? this.airplaneLayerId : undefined;

        // 1. Line Layer (The track paths)
        this.map.addLayer({
            id: this.lineLayerId,
            type: 'line',
            source: this.sourceId,
            filter: ['==', ['geometry-type'], 'LineString'],
            layout: { 
                'line-join': 'round', 
                'line-cap': 'round',
                'visibility': this.showTracks ? 'visible' : 'none' 
            },
            paint: {
                'line-color': TRACK_COLOR_EXPRESSION,
                'line-width': ['case', ['boolean', ['feature-state', 'hover'], false], 3.5, 1.8],
                'line-opacity': ['case', ['boolean', ['feature-state', 'hover'], false], 0.8, 0.4]
            }
        }, beforeId);

        // 2. Circle Background (The markers at start/end points)
        this.map.addLayer({
            id: this.bgLayerId,
            type: 'circle',
            source: this.sourceId,
            filter: ['==', ['geometry-type'], 'Point'],
            layout: {
                'visibility': (this.showTracks && this.showLabels) ? 'visible' : 'none'
            },
            paint: {
                'circle-color': TRACK_COLOR_EXPRESSION,
                'circle-radius': ['case', ['boolean', ['feature-state', 'hover'], false], 8, 6.5],
                'circle-opacity': 0.9,
                'circle-stroke-width': 1,
                'circle-stroke-color': 'rgba(0,0,0,0.1)'
            }
        }, beforeId);

        // 3. Label Layer (The text identifying the track)
        this.map.addLayer({
            id: this.labelLayerId,
            type: 'symbol',
            source: this.sourceId,
            filter: ['==', ['geometry-type'], 'Point'],
            layout: {
                'text-field': ['get', 'name'],
                'text-font': ['Open Sans Bold', 'Arial Unicode MS Bold'],
                'text-size': 7.5,
                'text-justify': 'center',
                'text-allow-overlap': true,
                'text-ignore-placement': true,
                'visibility': (this.showTracks && this.showLabels) ? 'visible' : 'none'
            },
            paint: {
                'text-color': '#ffffff'
            }
        }, beforeId);

        // If we already have tracks in memory (e.g., after a style change), render them immediately
        if (this.tracks.length > 0) {
            this.render();
        }
    }

    /**
     * Updates visibility and settings from external UI components.
     * @param {Object} options - { showTracks: boolean, showLabels: boolean }
     */
    setOptions(options) {
        if (options.showTracks !== undefined) this.showTracks = options.showTracks;
        if (options.showLabels !== undefined) this.showLabels = options.showLabels;
        this.updateVisibility();
    }

    /**
     * Applies visibility state to the Mapbox layers based on internal class state.
     */
    updateVisibility() {
        const trackVisibility = this.showTracks ? 'visible' : 'none';
        const labelVisibility = (this.showTracks && this.showLabels) ? 'visible' : 'none';

        if (this.map.getLayer(this.lineLayerId)) {
            this.map.setLayoutProperty(this.lineLayerId, 'visibility', trackVisibility);
        }
        if (this.map.getLayer(this.bgLayerId)) {
            this.map.setLayoutProperty(this.bgLayerId, 'visibility', labelVisibility);
        }
        if (this.map.getLayer(this.labelLayerId)) {
            this.map.setLayoutProperty(this.labelLayerId, 'visibility', labelVisibility);
        }
    }

    /**
     * Fetches current NAT tracks from the ACARS API.
     */
    async fetchTracks() {
        try {
            const response = await fetch(`${ACARS_SOCKET_URL}/api/live/tracks`);
            const data = await response.json();
            if (data.ok) {
                this.tracks = data.tracks;
                this.render();
            }
        } catch (error) {
            console.error('Error fetching NAT tracks:', error);
        }
    }

    /**
     * Converts track data into GeoJSON Features and updates the map source.
     */
    render() {
        const features = [];
        this.tracks.forEach(track => {
            const coordinates = this.parsePath(track.path);
            if (coordinates.length < 2) return;

            const commonProps = {
                name: track.name,
                type: track.type,
                eastLevels: track.eastLevels?.join(', ') || 'None',
                westLevels: track.westLevels?.join(', ') || 'None',
                pathString: track.path.join(' → ')
            };

            // Add the track line
            features.push({
                type: 'Feature',
                properties: commonProps,
                geometry: { type: 'LineString', coordinates }
            });

            // Add point markers at start and end
            features.push({
                type: 'Feature',
                properties: commonProps,
                geometry: { type: 'Point', coordinates: coordinates[0] }
            });

            features.push({
                type: 'Feature',
                properties: commonProps,
                geometry: { type: 'Point', coordinates: coordinates[coordinates.length - 1] }
            });
        });

        const source = this.map.getSource(this.sourceId);
        if (source) {
            source.setData({ type: 'FeatureCollection', features });
        }
    }

    /**
     * Parses various coordinate formats into [lon, lat] arrays.
     */
    parsePath(path) {
        return path.map(point => {
            if (point.includes('/')) {
                const [lat, lon] = point.split('/').map(parseFloat);
                return [-lon, lat];
            }
            const match = point.match(/(\d+)([NS])(\d+)([EW])/);
            if (match) {
                let lat = parseFloat(match[1]), lon = parseFloat(match[3]);
                if (match[2] === 'S') lat = -lat;
                if (match[4] === 'W') lon = -lon;
                return [lon, lat];
            }
            return null; 
        }).filter(c => c !== null);
    }

    /**
     * Configures mouse events for highlighting tracks and showing popups.
     */
    setupInteractions() {
        const popup = new mapboxgl.Popup({ closeButton: false, closeOnClick: false, offset: 15 });

        this.map.on('mousemove', this.lineLayerId, (e) => {
            if (e.features.length > 0) {
                if (this.hoveredTrackId !== null) {
                    this.map.setFeatureState({ source: this.sourceId, id: this.hoveredTrackId }, { hover: false });
                }
                this.hoveredTrackId = e.features[0].id;
                this.map.setFeatureState({ source: this.sourceId, id: this.hoveredTrackId }, { hover: true });
                this.map.getCanvas().style.cursor = 'pointer';
            }
        });

        this.map.on('mouseleave', this.lineLayerId, () => {
            if (this.hoveredTrackId !== null) {
                this.map.setFeatureState({ source: this.sourceId, id: this.hoveredTrackId }, { hover: false });
            }
            this.hoveredTrackId = null;
            this.map.getCanvas().style.cursor = '';
            popup.remove();
        });

        this.map.on('click', this.lineLayerId, (e) => {
            const props = e.features[0].properties;
            const html = `
                <div style="font-family: 'Inter', sans-serif; padding: 4px;">
                    <b style="font-size: 14px;">Track ${props.name}</b><br/>
                    <small>Levels: ${props.eastLevels} / ${props.westLevels}</small>
                </div>
            `;
            popup.setLngLat(e.lngLat).setHTML(html).addTo(this.map);
        });
    }

    /**
     * Starts the automated data polling loop.
     */
    startAutoRefresh(ms = 300000) {
        this.fetchTracks();
        this.refreshInterval = setInterval(() => this.fetchTracks(), ms);
    }

    /**
     * Stops the automated data polling loop.
     */
    stopAutoRefresh() {
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
            this.refreshInterval = null;
        }
    }

    /**
     * Public helper to toggle track visibility.
     */
    toggle(show) {
        this.showTracks = show;
        this.updateVisibility();
    }
}

export default NatTracksLayer;