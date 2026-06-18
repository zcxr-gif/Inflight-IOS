#!/usr/bin/env node
/**
 * generate-airspace.js — builds www/Airspace.geojson, the bundled global
 * airspace overlay used by the Pro "Airspace" map layer (see
 * updateAirspaceOverlay() in www/flight.js).
 *
 * WHY THIS EXISTS / DATA PROVENANCE
 * --------------------------------
 * A live global airspace feed (e.g. OpenAIP) needs an API key and network
 * access we don't want to require at runtime, so the overlay ships as a static
 * file generated here. To avoid fabricating positions, the controlled-airspace
 * rings are drawn around REAL airport coordinates read straight out of
 * www/airports.json. Each ring uses a class-standard lateral radius — a
 * deliberate simplification of the real "upside-down wedding cake" shelves,
 * which is appropriate for situational-awareness at map zoom levels.
 *
 * Special-use areas (prohibited / restricted / danger / MOA) are a small
 * curated set with documented—but APPROXIMATE—boundaries. Everything carries a
 * "not for real-world navigation" expectation; the UI shows a matching
 * disclaimer.
 *
 * TO REFRESH / EXPAND
 * -------------------
 *   node tools/generate-airspace.js
 * To swap in authoritative data later, replace buildClassAirspaces()/SUA with
 * a parser that consumes an OpenAIP export and keep the same output schema:
 *   properties: { kind, cat, name, ident, floor, ceiling }
 *   cat ∈ B C D E   (controlled classes)   P R DGR MOA W A   (special use)
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const AIRPORTS = JSON.parse(fs.readFileSync(path.join(ROOT, 'www/airports.json'), 'utf8'));
const OUT = path.join(ROOT, 'www/Airspace.geojson');

// Class-standard lateral radii (nautical miles). Approximations for overlay use.
const DEFAULT_RADIUS_NM = { B: 30, C: 10, D: 4.3, E: 4.3 };
const NM_TO_DEG_LAT = 1 / 60; // 1 NM ≈ 1 arc-minute of latitude

// Build a closed circle ring [ [lon,lat], ... ] around a center.
function circle(lat, lon, radiusNm, points = 72) {
  const ring = [];
  const dLat = radiusNm * NM_TO_DEG_LAT;
  const dLon = (radiusNm * NM_TO_DEG_LAT) / Math.cos((lat * Math.PI) / 180);
  for (let i = 0; i <= points; i++) {
    const t = (i / points) * 2 * Math.PI;
    ring.push([
      +(lon + dLon * Math.cos(t)).toFixed(5),
      +(lat + dLat * Math.sin(t)).toFixed(5),
    ]);
  }
  return ring;
}

// Curated global set of major controlled terminal airspaces. Real-world class
// letters vary by country (Europe largely uses CTR/TMA); we map the busy
// internationals to "B" and a representative US set to "C"/"D" so the overlay
// demonstrates each style. icao must exist in airports.json.
const CLASS_AIRPORTS = [
  // ---- North America: Class B ----
  ['KATL', 'B'], ['KLAX', 'B'], ['KORD', 'B'], ['KDFW', 'B'], ['KJFK', 'B'],
  ['KSFO', 'B'], ['KSEA', 'B'], ['KLAS', 'B'], ['KDEN', 'B'], ['KMIA', 'B'],
  ['KBOS', 'B'], ['KIAH', 'B'], ['KPHX', 'B'], ['KCLT', 'B'], ['KMSP', 'B'],
  ['KDTW', 'B'], ['KPHL', 'B'], ['KEWR', 'B'], ['KLGA', 'B'], ['KIAD', 'B'],
  ['KDCA', 'B'], ['KSAN', 'B'], ['PHNL', 'B'], ['CYYZ', 'B'], ['CYVR', 'B'],
  ['CYUL', 'B'], ['MMMX', 'B'],
  // ---- North America: Class C ----
  ['KSMF', 'C'], ['KSJC', 'C'], ['KOAK', 'C'], ['KSNA', 'C'], ['KABQ', 'C'],
  ['KAUS', 'C'], ['KBNA', 'C'], ['KRDU', 'C'], ['KCLE', 'C'], ['KPDX', 'C'],
  // ---- North America: Class D ----
  ['KSBA', 'D'], ['KBUR', 'D'], ['KAPA', 'D'], ['KHIO', 'D'], ['KPAO', 'D'],
  // ---- Europe (major TMA → B) ----
  ['EGLL', 'B'], ['EGKK', 'B'], ['EGCC', 'B'], ['LFPG', 'B'], ['EHAM', 'B'],
  ['EDDF', 'B'], ['EDDM', 'B'], ['LEMD', 'B'], ['LEBL', 'B'], ['LIRF', 'B'],
  ['LSZH', 'B'], ['LOWW', 'B'], ['EKCH', 'B'], ['ENGM', 'B'], ['ESSA', 'B'],
  ['EIDW', 'B'], ['LPPT', 'B'], ['LTFM', 'B'], ['UUEE', 'B'],
  // ---- Middle East / Asia ----
  ['OMDB', 'B'], ['OTHH', 'B'], ['OERK', 'B'], ['OEJN', 'B'], ['VHHH', 'B'],
  ['VTBS', 'B'], ['WSSS', 'B'], ['WMKK', 'B'], ['WIII', 'B'], ['RJTT', 'B'],
  ['RJAA', 'B'], ['RKSI', 'B'], ['ZBAA', 'B'], ['ZSPD', 'B'], ['ZGGG', 'B'],
  ['VABB', 'B'], ['VIDP', 'B'], ['VOMM', 'B'],
  // ---- Oceania ----
  ['YSSY', 'B'], ['YMML', 'B'], ['YBBN', 'B'], ['YPPH', 'B'], ['NZAA', 'B'],
  // ---- South America ----
  ['SBGR', 'B'], ['SBGL', 'B'], ['SAEZ', 'B'], ['SCEL', 'B'], ['SKBO', 'B'],
  ['SPIM', 'B'],
  // ---- Africa ----
  ['FAOR', 'B'], ['FACT', 'B'], ['HECA', 'B'], ['GMMN', 'B'], ['DNMM', 'B'],
  ['HKJK', 'B'], ['DGAA', 'B'],
];

function buildClassAirspaces() {
  const feats = [];
  let missing = 0;
  for (const [icao, cls, radiusOverride] of CLASS_AIRPORTS) {
    const ap = AIRPORTS[icao];
    if (!ap) { console.warn(`  ! ${icao} not in airports.json — skipped`); missing++; continue; }
    const r = radiusOverride || DEFAULT_RADIUS_NM[cls];
    feats.push({
      type: 'Feature',
      properties: {
        kind: 'class',
        cat: cls,
        name: ap.name || icao,
        ident: icao,
        floor: 'SFC',
        ceiling: cls === 'B' ? 'FL100' : cls === 'C' ? '4000ft' : '2500ft',
      },
      geometry: { type: 'Polygon', coordinates: [circle(ap.lat, ap.lon, r)] },
    });
  }
  if (missing) console.warn(`  (${missing} airports missing — list may need updating)`);
  return feats;
}

// Box helper [ [lon,lat]... ] from a lat/lon bounding rectangle.
function box(latMin, latMax, lonMin, lonMax) {
  return [[
    [lonMin, latMin], [lonMax, latMin], [lonMax, latMax],
    [lonMin, latMax], [lonMin, latMin],
  ].map(([x, y]) => [+x.toFixed(5), +y.toFixed(5)])];
}

// Small curated set of well-known special-use airspaces. Boundaries are
// APPROXIMATE and for situational awareness only.
function buildSUA() {
  return [
    {
      type: 'Feature',
      properties: { kind: 'sua', cat: 'P', name: 'Washington National Mall', ident: 'P-56A', floor: 'SFC', ceiling: '18000ft' },
      geometry: { type: 'Polygon', coordinates: [circle(38.8895, -77.0353, 1.6, 48)] },
    },
    {
      type: 'Feature',
      properties: { kind: 'sua', cat: 'P', name: 'Camp David', ident: 'P-40', floor: 'SFC', ceiling: '5000ft' },
      geometry: { type: 'Polygon', coordinates: [circle(39.6483, -77.4655, 3, 48)] },
    },
    {
      type: 'Feature',
      properties: { kind: 'sua', cat: 'R', name: 'Groom Lake (Nellis Range)', ident: 'R-4808N', floor: 'SFC', ceiling: 'UNLTD' },
      geometry: { type: 'Polygon', coordinates: box(36.85, 37.65, -116.45, -115.40) },
    },
    {
      type: 'Feature',
      properties: { kind: 'sua', cat: 'R', name: 'Edwards / China Lake Complex', ident: 'R-2508', floor: 'SFC', ceiling: 'UNLTD' },
      geometry: { type: 'Polygon', coordinates: box(34.90, 36.55, -118.30, -116.60) },
    },
    {
      type: 'Feature',
      properties: { kind: 'sua', cat: 'MOA', name: 'Sells MOA (AZ)', ident: 'SELLS MOA', floor: '500ft AGL', ceiling: 'FL180' },
      geometry: { type: 'Polygon', coordinates: box(31.60, 32.55, -112.55, -111.30) },
    },
    {
      type: 'Feature',
      properties: { kind: 'sua', cat: 'DGR', name: 'Salisbury Plain Danger Area', ident: 'EG D123', floor: 'SFC', ceiling: 'FL500' },
      geometry: { type: 'Polygon', coordinates: box(51.12, 51.32, -2.10, -1.55) },
    },
  ];
}

const fc = {
  type: 'FeatureCollection',
  name: 'Inflight Airspace Overlay',
  generated: new Date().toISOString(),
  note: 'Approximate airspace for situational awareness only. NOT for real-world navigation.',
  features: [...buildClassAirspaces(), ...buildSUA()],
};

fs.writeFileSync(OUT, JSON.stringify(fc));
const kb = (fs.statSync(OUT).size / 1024).toFixed(0);
console.log(`✓ Wrote ${fc.features.length} airspace features → www/Airspace.geojson (${kb} KB)`);
