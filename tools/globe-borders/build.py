#!/usr/bin/env python3
"""Turns Natural Earth's country outlines into the blob the globe draws.

The vector globe needs country borders, and a GeoJSON is the wrong thing to
ship for it twice over: it is about a megabyte of text, and parsing that into
Foundation objects on a launch costs more than drawing the globe does. So the
shape is decided here, once, and the app gets a file it can read with a memcpy.

    ./tools/globe-borders/build.py [ne_110m_admin_0_countries.geojson]

writes `ios-native/InflightTracker/Resources/world-borders.bin`. The source is
Natural Earth 1:110m admin-0, which is public domain -- the same dataset the
web build's card basemap already uses in `database/data/world-land.json`, at
the same scale, so the two cannot disagree about where a coastline is.

## The format

Little-endian throughout, because every device this runs on is.

    magic       4 bytes   "IFGB"
    version     uint8     1
    reserved    uint8     0
    ringCount   uint16
    lengths     uint16 x ringCount    points in each ring
    points      int16 x 2 x total     lon, lat, quantised

Quantised rather than float: a border drawn on a globe a thousand points wide
does not need six decimal places, and two bytes per coordinate halves the file
against Float32 for an error of about 600 m at the equator -- which is a third
of a pixel on a globe filling a phone. `Int16` also means the whole point
array is one contiguous block the app reads in a single pass.

Rings are kept whole and closed. Nothing is stitched into a shared-edge
network: two countries either side of a border each carry their own copy of it,
which draws that line twice. That is deliberate -- de-duplicating shared edges
means matching floating point coordinates between features, which Natural Earth
does not promise, and the failure mode is a border that vanishes rather than
one drawn twice at the same opacity.
"""

import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
DEFAULT_SOURCE = os.path.join(HERE, 'ne_110m_admin_0_countries.geojson')
OUTPUT = os.path.join(REPO, 'ios-native', 'InflightTracker', 'Resources', 'world-borders.bin')

LON_SCALE = 32767.0 / 180.0
LAT_SCALE = 32767.0 / 90.0

# A ring with fewer than this many points is a rounding artefact at 110m rather
# than an island anybody will see -- a triangle a pixel wide on a globe.
MIN_POINTS = 4


def rings_of(geometry):
    kind = geometry['type']
    if kind == 'Polygon':
        polygons = [geometry['coordinates']]
    elif kind == 'MultiPolygon':
        polygons = geometry['coordinates']
    else:
        return
    for polygon in polygons:
        for ring in polygon:
            yield ring


def quantise(ring):
    """The ring as integer pairs, with consecutive duplicates collapsed.

    Quantising can put two neighbouring points on the same integer coordinate,
    and a zero-length segment is a wasted four bytes and a wasted moveTo.
    """
    out = []
    for lon, lat in ring:
        x = int(round(max(-180.0, min(180.0, lon)) * LON_SCALE))
        y = int(round(max(-90.0, min(90.0, lat)) * LAT_SCALE))
        x = max(-32767, min(32767, x))
        y = max(-32767, min(32767, y))
        if out and out[-1] == (x, y):
            continue
        out.append((x, y))

    # Closed, so the drawing side never has to think about it.
    if len(out) >= 2 and out[0] != out[-1]:
        out.append(out[0])
    return out


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SOURCE
    with open(source) as handle:
        collection = json.load(handle)

    rings = []
    for feature in collection['features']:
        geometry = feature.get('geometry')
        if not geometry:
            continue
        for ring in rings_of(geometry):
            points = quantise(ring)
            if len(points) < MIN_POINTS:
                continue
            if len(points) > 65535:
                # Nothing in 110m comes close; the length field is uint16 and a
                # silent truncation would be a country with a straight line
                # through it.
                raise SystemExit(f'ring of {len(points)} points exceeds the uint16 length field')
            rings.append(points)

    if len(rings) > 65535:
        raise SystemExit(f'{len(rings)} rings exceeds the uint16 ring count')

    blob = bytearray()
    blob += b'IFGB'
    blob += struct.pack('<BBH', 1, 0, len(rings))
    for ring in rings:
        blob += struct.pack('<H', len(ring))
    for ring in rings:
        for x, y in ring:
            blob += struct.pack('<hh', x, y)

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, 'wb') as handle:
        handle.write(blob)

    total = sum(len(r) for r in rings)
    print(f'{len(rings)} rings, {total} points -> {OUTPUT} ({len(blob) / 1024:.1f} KB)')


if __name__ == '__main__':
    main()
