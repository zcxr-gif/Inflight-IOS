import { registerPlugin } from '@capacitor/core';

const InflightMapkit = registerPlugin('InflightMapkit', {
    web: () => import('./web.js').then((m) => new m.InflightMapkitWeb())
});

export { InflightMapkit };
