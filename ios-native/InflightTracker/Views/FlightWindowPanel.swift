import SwiftUI
import UIKit

/// Where the flight window is set up, with the window itself on the screen.
///
/// ## Why these settings moved here
///
/// They were four rows in a list, each describing in a sentence something you
/// can only really judge by looking at it. "Opens on the aircraft photo" is an
/// accurate description of the photo peek and tells you nothing about whether
/// you want it; the same is true of every other choice on this screen. So they
/// are together, above a drawing of what they do, and the drawing changes as
/// you touch them.
///
/// ## The preview is the real thing
///
/// Not a picture of the window, and not a simplified version of it: the actual
/// `FlightInfoPeak` and the actual board, handed a made-up flight and the same
/// theme the window would get. That is the whole reason it is worth having —
/// a mock-up drifts from what it is a mock-up of, and this one cannot, because
/// there is nothing to drift from.
///
/// The flight is invented, and obviously so. A real one would need the feed to
/// have something in it, would change under you while you were choosing, and
/// would show whoever is nearest rather than the case worth seeing — a long
/// route with both ends filed, which is the only case the board has anything to
/// draw.
struct FlightWindowPanel: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// Which half of the window the preview is showing. The peek and the open
    /// window are two different sets of choices, and each one is worth seeing
    /// while it is being made.
    @State private var stage: Stage = .peek

    /// How wide the drawing actually came out.
    ///
    /// The peek's header is a photograph laid edge to edge, and it is handed a
    /// width rather than filling one — the real window has the sheet's width to
    /// give it and this does not. Measured rather than assumed, so the preview
    /// is the width of the panel on a phone, on a tablet, and in a sheet
    /// somebody has dragged narrow.
    @State private var width: CGFloat = 340

    enum Stage: String, CaseIterable, Identifiable {
        case peek
        case open

        var id: String { rawValue }

        var label: String {
            switch self {
            case .peek: return "Peek"
            case .open: return "Open"
            }
        }
    }

    private var theme: FlightInfoTheme {
        appearance.theme.accented(by: accent)
    }

    /// The preview's airline colour, so the switch below it does something
    /// visible the moment it is thrown.
    private var accent: AirlineAccent.Colours? {
        guard appearance.showsAirlineAccent else { return nil }
        return AirlineAccent.colours(
            forLivery: Self.sample.liveryName,
            isLight: appearance.theme.isLight
        )
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        MapPanel(title: "Flight window", subtitle: "What opens when you tap an aircraft") {
            preview

            PanelSection(title: "PEEK") {
                PanelPickerRow(
                    title: "Peek",
                    symbol: "rectangle.portrait.bottomhalf.filled",
                    options: FlightInfoPeakStyle.allCases,
                    label: { $0.label },
                    detail: appearance.peakStyle.detail,
                    selection: $appearance.peakStyle
                )
            }
            .panelEntrance(1)

            PanelSection(title: "OPEN WINDOW") {
                PanelPickerRow(
                    title: "Layout",
                    symbol: appearance.windowStyle.symbol,
                    options: FlightInfoWindowStyle.allCases,
                    label: { $0.label },
                    detail: appearance.windowStyle.detail,
                    selection: $appearance.windowStyle
                )
            }
            .panelEntrance(2)

            PanelSection(title: "COLOUR") {
                PanelToggleRow(
                    title: "Airline colours",
                    symbol: "paintpalette",
                    detail: "Puts the airline's own colour on the window's edges, its dividers and the few pieces already drawn in the accent — the window itself stays as it is. Nothing is drawn for a livery we hold no colour for.",
                    isOn: $appearance.showsAirlineAccent
                )
            }
            .panelEntrance(3)

            // Only where there is a choice to make. A phone has one place to
            // put this window; see the note this was moved from.
            if isPad {
                PanelSection(title: "PLACEMENT") {
                    PanelPickerRow(
                        title: "Window",
                        symbol: "sidebar.right",
                        options: FlightWindowPlacement.allCases,
                        label: { $0.label },
                        detail: appearance.flightWindowPlacement.detail,
                        selection: $appearance.flightWindowPlacement
                    )
                }
                .panelEntrance(4)
            }
        }
    }

    // MARK: - The window, drawn

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preview", selection: $stage) {
                ForEach(Stage.allCases) { stage in
                    Text(stage.label).tag(stage)
                }
            }
            .pickerStyle(.segmented)

            window

            Text(caption)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .motionWords(caption)
        }
        .panelEntrance(0)
    }

    /// The drawn window: the sheet's own ground, its corner radius, and its
    /// grabber, so what is on screen is a window rather than a card with some
    /// window contents in it.
    private var window: some View {
        VStack(spacing: 0) {
            // In a band of its own rather than floating over the photograph.
            // The real window floats it because the photo runs to the top edge
            // of the sheet; here there is a card border above it either way.
            WindowGrabber(theme: theme)

            content
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: theme.radiusLarge + 6, style: .continuous)
                .fill(appearance.theme.windowFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge + 6, style: .continuous)
                .strokeBorder(accent?.tint.opacity(0.55) ?? theme.stroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge + 6, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PreviewWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(PreviewWidthKey.self) { measured in
            guard measured > 200 else { return }
            width = measured
        }
        // Nothing in here is a control. Every tap on the preview is a tap on a
        // drawing of a control, and letting one of them do something — open an
        // airport, page a photo — would be a preview that navigates.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        // The whole point: the drawing changes under the choice being made.
        .motion(Motion.panel, value: appearance.peakStyle)
        .motion(Motion.panel, value: appearance.windowStyle)
        .motion(Motion.panel, value: appearance.showsAirlineAccent)
        .motion(Motion.panel, value: stage)
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .peek:
            FlightInfoPeak(
                flight: Self.sample,
                image: nil,
                contributor: nil,
                registration: Self.registration,
                theme: theme,
                style: appearance.peakStyle,
                width: width,
                // Shorter than the window's own ceiling: this is a drawing of a
                // peek inside a list of settings, and the photo is the part of
                // it that can be made smaller without the layout stopping being
                // the layout.
                heroCeiling: 128
            )

        case .open:
            openHead
                .padding(.horizontal, 14)
                .padding(.top, 4)
        }
    }

    /// The head of the open window, in whichever layout is chosen — which is
    /// the whole of what that setting changes.
    @ViewBuilder
    private var openHead: some View {
        switch appearance.windowStyle {
        case .cards:
            VStack(spacing: 12) {
                FlightIdentityBlock(
                    flight: Self.sample,
                    registration: Self.registration,
                    theme: theme
                )

                RouteCard(
                    flight: Self.sample,
                    progress: FlightProgress(flight: Self.sample),
                    theme: theme
                )
            }

        case .board:
            FlightInfoBoard(
                flight: Self.sample,
                registration: Self.registration,
                theme: theme,
                progress: FlightProgress(flight: Self.sample),
                began: Self.departed
            )
        }
    }

    private var caption: String {
        switch stage {
        case .peek:
            return appearance.peakStyle == .rich
                ? "The peek opens on the aircraft's photograph, and the window grows around it."
                : "The peek is a bar: who it is and where it is going, over the map."
        case .open:
            return appearance.windowStyle == .board
                ? "Open, the window leads with the route and the times. The cards follow underneath."
                : "Open, the window leads with the aircraft and a card for the route."
        }
    }

    // MARK: - The aeroplane that does not exist

    private static let registration = "ET-APX"

    /// Two hours ago, so the board has something to put under "departed" and
    /// the progress bar has somewhere to be.
    private static var departed: Date { Date().addingTimeInterval(-6_300) }

    /// Dubai to Addis Ababa, at cruise, half way down the Red Sea.
    ///
    /// Built through the feed's own initialiser rather than a second one added
    /// for previews: the window is being shown exactly the kind of value it
    /// gets in flight, and a made-up `Flight` that skipped the parsing could
    /// hold a combination the real one never produces.
    private static let sample: Flight = {
        let payload: [String: Any] = [
            "flightId": "preview.window",
            "callsign": "ETH613",
            "username": "Inflight",
            "departureIcao": "OMDB",
            "arrivalIcao": "HAAB",
            "pilotState": 0,
            "position": [
                "lat": 20.6,
                "lon": 45.1,
                "alt_ft": 37_000,
                "gs_kt": 512,
                "vs_fpm": 0,
                "heading_deg": 216
            ],
            "aircraft": [
                "aircraftName": "Boeing 777-300ER",
                "liveryName": "Ethiopian Airlines",
                "registration": registration
            ]
        ]

        // The initialiser only fails on a payload with no identity or no
        // position, and this one has both — so the fallback is unreachable and
        // exists so a typo above is a preview of nothing rather than a crash on
        // the settings screen.
        return Flight(payload: payload) ?? Flight(payload: [
            "flightId": "preview.window",
            "position": ["lat": 0.1, "lon": 0.1]
        ])!
    }()
}

/// Carries the drawn window's width back up to the panel, so the peek can be
/// handed the one it actually got.
private struct PreviewWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
