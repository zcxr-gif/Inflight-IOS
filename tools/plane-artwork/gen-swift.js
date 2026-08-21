const fs = require('fs');
const path = require('path');
const art = JSON.parse(fs.readFileSync(__dirname + '/artwork.json', 'utf8'));
delete art.vehicle; // the source file is a placeholder checkerboard, not a vehicle


const header = `import CoreGraphics

//  Aircraft artwork.
//
//  Generated — do not edit by hand. The shapes are the map markers from
//  Virtual Radar Server and the community marker pack written for it, flattened
//  from their SVGs into plain path data (see tools/plane-artwork).
//
//  Virtual Radar Server markers (heavy/medium/light families, helicopter,
//  balloon, glider, generic, A340, A380):
//
//      Copyright (C) 2010 onwards, Andrew Whewell. All rights reserved.
//
//      Redistribution and use in source and binary forms, with or without
//      modification, are permitted provided that the following conditions are
//      met:
//
//      * Redistributions of source code must retain the above copyright
//        notice, this list of conditions and the following disclaimer.
//      * Redistributions in binary form must reproduce the above copyright
//        notice, this list of conditions and the following disclaimer in the
//        documentation and/or other materials provided with the distribution.
//      * Neither the name of the author nor the names of the program's
//        contributors may be used to endorse or promote products derived from
//        this software without specific prior written permission.
//
//      THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//      "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//      LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
//      PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHORS OF THE
//      SOFTWARE BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
//      EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
//      PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
//      PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
//      LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
//      NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//      SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//  Everything else here (the type-specific military, warbird, rotary and
//  unmanned markers) comes from VRSCustomMarkers by rikgale and shish0r,
//  released under CC0 1.0 Universal — no conditions attached.

/// The drawn shapes, as SVG path data in each drawing's own coordinate space.
/// \`PlaneIconRenderer\` fits them to the canvas, so the numbers here only ever
/// matter relative to each other.
enum PlaneArtwork {

    struct Part {
        let path: String
        /// The source drawing's fill rule. Several of these carry their own
        /// cut-outs — cabin windows, rotor discs — which close up under the
        /// non-zero rule.
        var evenOdd: Bool = true
    }

    static let parts: [String: [Part]] = [
`;

const body = Object.entries(art).map(([key, parts]) => {
  const rendered = parts.map(p =>
    `            Part(path: "${p.d}"${p.rule === 'evenodd' ? '' : ', evenOdd: false'}),`
  ).join('\n');
  return `        "${key}": [\n${rendered}\n        ],`;
}).join('\n');

fs.writeFileSync(path.join(__dirname, '../../ios-native/InflightTracker/Map/PlaneArtwork.swift'),
  header + body + '\n    ]\n}\n');
console.log('wrote PlaneArtwork.swift', Object.keys(art).length, 'shapes');
