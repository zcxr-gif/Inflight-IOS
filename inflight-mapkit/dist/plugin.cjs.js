'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

const core = require('@capacitor/core');

const InflightMapkit = core.registerPlugin('InflightMapkit', {
    web: async () => {
        const { WebPlugin } = require('@capacitor/core');
        class InflightMapkitWeb extends WebPlugin {
            async create() {}
            async destroy() {}
            async setFrame() {}
            async setCamera() {}
            async fitBounds() {}
            async setMapType() {}
            async setMarkers() {}
            async setPolylines() {}
            async setPolygons() {}
            async setVisible() {}
        }
        return new InflightMapkitWeb();
    }
});

exports.InflightMapkit = InflightMapkit;
