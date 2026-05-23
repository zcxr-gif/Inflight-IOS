import { WebPlugin } from '@capacitor/core';

// Web fallback is a no-op stub. The real implementation runs natively on iOS.
// On web we keep the existing Mapbox/Leaflet path; this stub only exists so
// the JS API surface is callable in dev tooling without errors.

export class InflightMapkitWeb extends WebPlugin {
    async create() { return; }
    async destroy() { return; }
    async setFrame() { return; }
    async setCamera() { return; }
    async fitBounds() { return; }
    async setMapType() { return; }
    async setMarkers() { return; }
    async setPolylines() { return; }
    async setPolygons() { return; }
    async setVisible() { return; }
}
