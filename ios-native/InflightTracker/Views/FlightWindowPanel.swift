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

    @State private var isShowingPaywall = false

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

    /// The peek picker's binding, with the Pro case intercepted.
    ///
    /// A binding rather than a `.proLocked` on the row, because what is sold
    /// here is ONE OPTION of several and not the row: locking the row would
    /// take Compact and Photo away from a free account to sell Detail, which is
    /// charging for something they already have.
    ///
    /// Reads `resolvedPeakStyle` so the segment that appears chosen is the one
    /// actually being drawn — a picker showing Detail on an account whose
    /// window is drawing Compact is a lie about the app's own state.
    private var peakSelection: Binding<FlightInfoPeakStyle> {
        Binding(
            get: { appearance.resolvedPeakStyle },
            set: { style in
                guard !style.isPro || appearance.canUseDetailLook else {
                    isShowingPaywall = true
                    return
                }
                appearance.peakStyle = style
            }
        )
    }

    /// The same for the open window's layout.
    private var windowSelection: Binding<FlightInfoWindowStyle> {
        Binding(
            get: { appearance.resolvedWindowStyle },
            set: { style in
                guard !style.isPro || appearance.canUseDetailLook else {
                    isShowingPaywall = true
                    return
                }
                appearance.windowStyle = style
            }
        )
    }

    var body: some View {
        MapPanel(title: "Flight window", subtitle: "What opens when you tap an aircraft") {
            preview

            PanelSection(title: "PEEK") {
                PanelPickerRow(
                    title: "Peek",
                    symbol: "rectangle.portrait.bottomhalf.filled",
                    options: FlightInfoPeakStyle.allCases,
                    label: { $0.label },
                    detail: appearance.resolvedPeakStyle.detail,
                    selection: peakSelection
                )
            }
            .panelEntrance(1)

            PanelSection(title: "OPEN WINDOW") {
                PanelPickerRow(
                    title: "Layout",
                    symbol: appearance.resolvedWindowStyle.symbol,
                    options: FlightInfoWindowStyle.allCases,
                    label: { $0.label },
                    detail: appearance.resolvedWindowStyle.detail,
                    selection: windowSelection
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
        .sheet(isPresented: $isShowingPaywall) {
            ProPanel(highlighted: .flightInfoLook)
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
        .motion(Motion.panel, value: appearance.resolvedPeakStyle)
        .motion(Motion.panel, value: appearance.resolvedWindowStyle)
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
                style: appearance.resolvedPeakStyle,
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
        switch appearance.resolvedWindowStyle {
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

        case .detail:
            // No theme: the detail look owns its own palette and takes nothing
            // from the app's switches — which is exactly what this preview has
            // to show, since the row above it is a list of the switches.
            FlightDetailHead(
                flight: Self.sample,
                registration: Self.registration,
                // No photograph in the preview: there is no lookup behind an
                // aeroplane that does not exist, so the hero draws its sprite
                // fallback — which is what a real one does until the picture
                // lands, and is honest about what this look is shaped like.
                image: nil,
                contributor: nil,
                // The head's own width: this one is inset fourteen either side
                // by `content`, exactly as the real window insets it.
                width: max(0, width - 28),
                began: Self.departed
            )
        }
    }

    private var caption: String {
        switch stage {
        case .peek:
            switch appearance.resolvedPeakStyle {
            case .rich:
                return "The peek opens on the aircraft's photograph, and the window grows around it."
            case .detail:
                return "The peek says the height, the speed, the type and the tail before the window is opened at all."
            case .compact:
                return "The peek is a bar: who it is and where it is going, over the map."
            }
        case .open:
            switch appearance.resolvedWindowStyle {
            case .board:
                return "Open, the window leads with the route and the times. The cards follow underneath."
            case .detail:
                return "Open, the window leads with the photograph under the operator's own bar, then the route and the live numbers."
            case .cards:
                return "Open, the window leads with the aircraft and a card for the route."
            }
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
