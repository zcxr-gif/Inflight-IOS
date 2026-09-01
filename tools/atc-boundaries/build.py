#!/usr/bin/env python3
"""Turns the VATSIM FIR boundary set into the blob the ATC layer draws.

    ./tools/atc-boundaries/build.py [Boundaries.geojson] [VATSpy.dat]

writes `ios-native/InflightTracker/Resources/atc-boundaries.bin`. The sources
are the two files the Capacitor build shipped and drew from, kept in `old/www/`:
`Boundaries.geojson` (the polygons) and `VATSpy.dat` (the lookup tables). Same
data, so the two builds cannot disagree about where a sector edge is.

## Why a blob and not the GeoJSON

The same argument as `tools/globe-borders/build.py`, one size up. The GeoJSON is
1.7 MB of text and 58,000 coordinates; parsing that into Foundation objects
costs more than a launch has to spare, and it would be paid by everybody rather
than by the people who turn the layer on. Decided here, once.

## Why the lookup tables are in it

This is the part the web build never solved and the reason its highlighting was
unreliable. It matched a controller to a sector by `controller.fir_id` -- a field
the API does not actually send -- and otherwise by sweeping every polygon for the
controller's own coordinates, which the feed does not carry either. What is left
is the station name, and a station name is not a boundary id: Infinite Flight
names a centre after a FIR (`BIRD`) or after an airport inside it (`BIKF`), and
the boundary set calls that sector `BIRD-N`.

`VATSpy.dat` is exactly the table that closes that gap -- `[FIRs]` maps a FIR
ICAO to its boundary, `[Airports]` maps 17,000 airport ICAOs to their FIR -- so
both spellings are resolved here, at build time, into one flat alias table the
app reads as a dictionary.

## The format

Little-endian throughout, sequential, length-prefixed. Read once on first use.

    magic        4 bytes   "IFAB"
    version      uint8     1
    reserved     uint8     0
    sectorCount  uint16
    per sector:
        idLen    uint8     ASCII bytes of the boundary id
        id       idLen bytes
        labelLon int16     quantised, where the sector writes its name
        labelLat int16
        ringCount uint16
        lengths  uint16 x ringCount    points in each ring
    aliasCount   uint32
    per alias:
        keyLen   uint8
        key      keyLen bytes          a station name, upper case
        sector   uint16                index into the sector table
    pointCount   uint32
    points       int16 x 2 x pointCount    lon, lat, quantised, ring order

Quantised the same way and for the same reason as the globe's borders: two
bytes a coordinate is about 600 m at the equator, which is a third of a pixel
on a sector that spans a country, and it keeps the point array one contiguous
block the app reads in a single pass.
"""

import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
DEFAULT_BOUNDARIES = os.path.join(REPO, 'old', 'www', 'Boundaries.geojson')
DEFAULT_VATSPY = os.path.join(REPO, 'old', 'www', 'VATSpy.dat')
OUTPUT = os.path.join(REPO, 'ios-native', 'InflightTracker', 'Resources', 'atc-boundaries.bin')

LON_SCALE = 32767.0 / 180.0
LAT_SCALE = 32767.0 / 90.0

# A ring smaller than this is a rounding artefact rather than airspace anybody
# will see -- the same threshold the globe's coastlines use.
MIN_POINTS = 4


def quantise(ring):
    """The ring as integer pairs, with consecutive duplicates collapsed."""
    out = []
    for point in ring:
        lon, lat = point[0], point[1]
        x = int(round(max(-180.0, min(180.0, lon)) * LON_SCALE))
        y = int(round(max(-90.0, min(90.0, lat)) * LAT_SCALE))
        x = max(-32767, min(32767, x))
        y = max(-32767, min(32767, y))
        if out and out[-1] == (x, y):
            continue
        out.append((x, y))

    # Closed here, so the drawing side never has to think about it.
    if len(out) >= 2 and out[0] != out[-1]:
        out.append(out[0])
    return out


def rings_of(geometry):
    kind = geometry.get('type')
    if kind == 'Polygon':
        polygons = [geometry['coordinates']]
    elif kind == 'MultiPolygon':
        polygons = geometry['coordinates']
    else:
        return
    for polygon in polygons:
        for ring in polygon:
            yield ring


def label_of(properties, rings):
    """Where the sector writes its name.

    The dataset's own `label_lon`/`label_lat` where it has them, which is a
    cartographer's choice and better than any centroid -- an FIR shaped like a
    crescent has a centroid in the sea outside it. The mean of the outer ring
    is the fallback, and it is only reached by a handful of sectors.
    """
    try:
        lon = float(properties['label_lon'])
        lat = float(properties['label_lat'])
        if -180 <= lon <= 180 and -90 <= lat <= 90:
            return lon, lat
    except (KeyError, TypeError, ValueError):
        pass

    if not rings:
        return None
    ring = rings[0]
    return (
        sum(p[0] for p in ring) / len(ring) / LON_SCALE,
        sum(p[1] for p in ring) / len(ring) / LAT_SCALE,
    )


def read_sections(path):
    """VATSpy.dat as {section name: [line, ...]}, comments and blanks dropped."""
    sections = {}
    current = None
    with open(path, encoding='utf-8', errors='replace') as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith(';'):
                continue
            if line.startswith('[') and line.endswith(']'):
                current = line[1:-1]
                sections[current] = []
                continue
            if current:
                sections[current].append(line)
    return sections


def build_aliases(sections, index_of_id):
    """Every station name that should light a sector, mapped to sector indices.

    Three sources, most specific first, and a key may resolve to several
    sectors -- a FIR split into North and South is two boundaries one controller
    covers, and lighting both is right.
    """
    aliases = {}

    def add(key, sector):
        if key is None:
            return
        key = key.strip().upper()
        # One and two-letter keys are prefixes of hundreds of ICAOs; lighting a
        # sector off one would be a wrong answer rather than a vague one.
        if len(key) < 3:
            return
        bucket = aliases.setdefault(key, [])
        if sector not in bucket:
            bucket.append(sector)

    # 1. The boundary ids themselves, so a station already named like the
    #    dataset resolves without going through any table.
    for boundary_id, index in index_of_id.items():
        add(boundary_id, index)

    # 2. [FIRs]: ICAO|NAME|CALLSIGN PREFIX|FIR BOUNDARY. The first column is
    #    what a centre is usually called; the fourth is what the polygon is
    #    called, and they differ whenever a FIR is split.
    fir_to_sectors = {}
    for line in sections.get('FIRs', []):
        parts = line.split('|')
        if len(parts) < 4:
            continue
        icao, _, prefix, boundary = parts[0], parts[1], parts[2], parts[3]
        boundary = boundary.strip() or icao.strip()
        index = index_of_id.get(boundary.upper())
        if index is None:
            continue
        add(icao, index)
        # A callsign prefix is written `BIRD_E`; a station name is not, but the
        # underscore form shows up often enough to be worth accepting.
        add(prefix.replace('_', ''), index)
        add(prefix, index)
        fir_to_sectors.setdefault(icao.strip().upper(), []).append(index)

    # 3. [Airports]: ICAO|Name|Lat|Lon|IATA|FIR|IsPseudo. This is the one that
    #    makes a centre named after an airport inside its own airspace resolve.
    for line in sections.get('Airports', []):
        parts = line.split('|')
        if len(parts) < 6:
            continue
        icao, fir = parts[0].strip().upper(), parts[5].strip().upper()
        if not icao or not fir:
            continue
        for index in fir_to_sectors.get(fir, []):
            add(icao, index)

    return aliases


def main():
    boundaries_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BOUNDARIES
    vatspy_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_VATSPY

    with open(boundaries_path, encoding='utf-8') as handle:
        collection = json.load(handle)

    sectors = []
    seen = {}
    for feature in collection.get('features', []):
        geometry = feature.get('geometry')
        properties = feature.get('properties') or {}
        boundary_id = (properties.get('id') or '').strip().upper()
        if not geometry or not boundary_id:
            continue

        rings = []
        for ring in rings_of(geometry):
            points = quantise(ring)
            if len(points) < MIN_POINTS:
                continue
            if len(points) > 65535:
                raise SystemExit(f'{boundary_id}: ring of {len(points)} points exceeds the uint16 length')
            rings.append(points)
        if not rings:
            continue

        label = label_of(properties, rings)
        if label is None:
            continue

        # The dataset has a handful of ids twice -- one sector whose airspace is
        # two disjoint lumps, written as two features. Merged rather than
        # dropped: both lumps are the same sector and both should light.
        if boundary_id in seen:
            sectors[seen[boundary_id]]['rings'].extend(rings)
            continue

        seen[boundary_id] = len(sectors)
        sectors.append({'id': boundary_id, 'label': label, 'rings': rings})

    if len(sectors) > 65535:
        raise SystemExit(f'{len(sectors)} sectors exceeds the uint16 sector count')

    aliases = build_aliases(read_sections(vatspy_path), seen)

    blob = bytearray()
    blob += b'IFAB'
    blob += struct.pack('<BBH', 1, 0, len(sectors))

    for sector in sectors:
        name = sector['id'].encode('ascii', 'ignore')
        if len(name) > 255:
            raise SystemExit(f'{sector["id"]}: id longer than the uint8 length')
        lon, lat = sector['label']
        blob += struct.pack('<B', len(name)) + name
        blob += struct.pack(
            '<hhH',
            max(-32767, min(32767, int(round(lon * LON_SCALE)))),
            max(-32767, min(32767, int(round(lat * LAT_SCALE)))),
            len(sector['rings']),
        )
        for ring in sector['rings']:
            blob += struct.pack('<H', len(ring))

    # Encoded before the count is written, not after. Writing the count and
    # then skipping an entry that failed to encode would leave the file
    # claiming more aliases than it holds -- and the reader, which walks this
    # section to find where the points begin, would start reading coordinates
    # one alias early. Nothing in the current data fails, which is exactly what
    # makes that the kind of bug that ships.
    flat_aliases = []
    for key in sorted(aliases):
        encoded = key.encode('ascii', 'ignore')
        if not encoded or len(encoded) > 255:
            continue
        for index in aliases[key]:
            flat_aliases.append((encoded, index))

    blob += struct.pack('<I', len(flat_aliases))
    for encoded, index in flat_aliases:
        blob += struct.pack('<B', len(encoded)) + encoded + struct.pack('<H', index)

    total_points = sum(len(r) for s in sectors for r in s['rings'])
    blob += struct.pack('<I', total_points)
    for sector in sectors:
        for ring in sector['rings']:
            for x, y in ring:
                blob += struct.pack('<hh', x, y)

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, 'wb') as handle:
        handle.write(blob)

    rings = sum(len(s['rings']) for s in sectors)
    print(
        f'{len(sectors)} sectors, {rings} rings, {total_points} points, '
        f'{len(flat_aliases)} aliases -> {OUTPUT} ({len(blob) / 1024:.1f} KB)'
    )


if __name__ == '__main__':
    main()
