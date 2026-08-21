import SwiftUI

/// Where the artwork came from.
///
/// The aircraft marks are other people's work, used under licences that ask for
/// their notices to travel with the app. This panel is where they travel: the
/// BSD text is reproduced in full because that licence asks for exactly that,
/// and the CC0 set is credited because it deserves to be even though it asks
/// for nothing.
struct AcknowledgementsPanel: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Acknowledgements", subtitle: "The people whose work is on the map") {
            PanelSection(title: "AIRCRAFT MARKS") {
                credit(
                    title: "Virtual Radar Server",
                    detail: """
                    The airliner, turboprop, light aircraft, helicopter, balloon \
                    and glider marks are Virtual Radar Server's, by Andrew \
                    Whewell, used under the BSD 3-Clause licence.
                    """
                )

                PanelDivider()

                credit(
                    title: "VRSCustomMarkers",
                    detail: """
                    The military, warbird, rotary and unmanned marks are from \
                    VRSCustomMarkers by rikgale and shish0r, released into the \
                    public domain under CC0 1.0.
                    """
                )
            }

            PanelSection(title: "BSD 3-CLAUSE") {
                Text(Self.bsdNotice)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .textSelection(.enabled)
                    .padding(14)
            }
        }
    }

    private func credit(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private static let bsdNotice = """
    Copyright (C) 2010 onwards, Andrew Whewell
    All rights reserved.

    Redistribution and use in source and binary forms, with or without \
    modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, \
    this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice, \
    this list of conditions and the following disclaimer in the documentation \
    and/or other materials provided with the distribution.
    * Neither the name of the author nor the names of the program's contributors \
    may be used to endorse or promote products derived from this software \
    without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE \
    ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHORS OF THE SOFTWARE BE LIABLE FOR \
    ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL \
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT \
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY \
    OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH \
    DAMAGE.
    """
}
