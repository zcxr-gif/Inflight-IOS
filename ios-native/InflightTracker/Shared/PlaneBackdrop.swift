import SwiftUI
import UIKit

/// The aircraft photo a widget is drawn on.
///
/// The photo is the widget — a tile carrying a real 777 in a real livery is
/// the reason to put one on a home screen at all, and the readouts are laid
/// over it rather than beside it. Which means the whole job here is making
/// arbitrary user-uploaded photography safe to put white text on: a shot into
/// a bright overcast sky and a shot of a tail on a night ramp have to end up
/// at the same legibility without either of them looking processed.
///
/// Three things do that, in order:
///
///   1. a grade — the app's palette is monochrome carbon, and a fully
///      saturated photo underneath white-on-carbon typography reads as a
///      screenshot of a different app. Pulling saturation back and laying a
///      thin carbon wash over the top settles the photo into the design
///      without draining it.
///   2. a scrim shaped to the layout — the text in a widget sits in known
///      places, so the darkening is put exactly there rather than spread
///      evenly. An even scrim has to be heavy enough for the worst case
///      everywhere, which is how a photo backdrop turns into a grey slab.
///   3. a floor — a minimum darkening across the whole tile, because a
///      shaped scrim still leaves the corners, and a caption that drifts a
///      few points on a larger device must not fall off the treated area.
///
/// When there is no photo the same surface is drawn instead of fetched, and
/// it is deliberately not a grey box: an empty tile reads as a broken widget
/// and gets removed from the home screen.
public struct PlaneBackdrop: View {

    /// Which cached photo to draw. Miss → the drawn sky.
    public let photoKey: String

    /// Where the text is, and therefore where the scrim goes.
    public let style: Style

    /// Feeds the drawn fallback's mood — how high the aircraft is. Ignored
    /// when a photo is found.
    public var altitudeFt: Int = 0

    public enum Style {
        /// Small tiles: text covers most of the face, so the whole thing is
        /// darkened and the photo is atmosphere rather than subject.
        case dense

        /// Medium and large tiles: a header at the top and a block at the
        /// bottom, with the middle left clear for the aircraft to be seen.
        case framed

        /// Live Activity and lock-screen banners, which are already on a dark
        /// system surface and want the least treatment that still works.
        case banner

        var topScrim: Double {
            switch self {
            case .dense: return 0.55
            case .framed: return 0.62
            case .banner: return 0.45
            }
        }

        var bottomScrim: Double {
            switch self {
            case .dense: return 0.80
            case .framed: return 0.88
            case .banner: return 0.72
            }
        }

        /// The even darkening under everything else.
        var floor: Double {
            switch self {
            case .dense: return 0.32
            case .framed: return 0.16
            case .banner: return 0.14
            }
        }

        /// How far up the tile the bottom scrim reaches.
        var bottomReach: Double {
            switch self {
            case .dense: return 1.0
            case .framed: return 0.62
            case .banner: return 0.70
            }
        }
    }

    public init(photoKey: String, style: Style = .framed, altitudeFt: Int = 0) {
        self.photoKey = photoKey
        self.style = style
        self.altitudeFt = altitudeFt
    }

    public var body: some View {
        ZStack {
            if let image = SharedStore.photo(for: photoKey) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Aircraft photography is overwhelmingly side-on with the
                    // fuselage through the middle, so a centre crop lands on
                    // the subject. The 2% overscale is for the hairline of
                    // background that rounding otherwise leaves down one edge.
                    .scaleEffect(1.02)
                    .saturation(0.88)
                    .overlay(BackdropTokens.carbon.opacity(0.12))
            } else {
                DrawnSky(altitudeFt: altitudeFt)
            }

            scrim
        }
        .clipped()
    }

    /// Shaped darkening. Three passes rather than one because the top and the
    /// bottom carry different amounts of text and a single gradient across the
    /// whole tile can only be right for one of them.
    private var scrim: some View {
        ZStack {
            Color.black.opacity(style.floor)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(style.topScrim), location: 0),
                    .init(color: .black.opacity(style.topScrim * 0.35), location: 0.18),
                    .init(color: .clear, location: 0.42)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 1 - style.bottomReach),
                    .init(color: .black.opacity(style.bottomScrim * 0.45), location: 1 - style.bottomReach * 0.45),
                    .init(color: .black.opacity(style.bottomScrim), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// What gets drawn when no photo has been cached yet.
///
/// A high-altitude dusk, which is the app's own mood, with the aircraft as a
/// silhouette bleeding off the corner the way it would in a real shot. It has
/// to survive being the *first* thing a new user sees — the widget gallery
/// renders before the app has ever fetched a photo — so it is built to look
/// like a considered empty state rather than a missing asset.
struct DrawnSky: View {

    let altitudeFt: Int

    /// The higher it is, the deeper and colder the sky gets, and the thinner
    /// the horizon band. On the ground it is a warm ramp at dusk.
    private var isHigh: Bool { altitudeFt >= 18_000 }

    private var skyColours: [Color] {
        isHigh
            ? [BackdropTokens.nightTop, BackdropTokens.nightMid, BackdropTokens.nightHorizon]
            : [BackdropTokens.duskTop, BackdropTokens.duskMid, BackdropTokens.duskHorizon]
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                LinearGradient(colors: skyColours, startPoint: .top, endPoint: .bottom)

                // Sun low and off to one side, well out of the way of the
                // readouts, which sit left and bottom.
                RadialGradient(
                    colors: [BackdropTokens.glow.opacity(isHigh ? 0.22 : 0.38), .clear],
                    center: UnitPoint(x: 0.82, y: isHigh ? 0.70 : 0.62),
                    startRadius: 0,
                    endRadius: max(w, h) * 0.62
                )

                // A single soft cloud band. More than one starts to look like
                // a drawing rather than a horizon.
                Ellipse()
                    .fill(Color.white.opacity(isHigh ? 0.05 : 0.10))
                    .frame(width: w * 1.5, height: h * 0.22)
                    .blur(radius: h * 0.06)
                    .offset(x: -w * 0.1, y: h * (isHigh ? 0.30 : 0.24))

                // The aircraft, big and cropped by the tile edge — the framing
                // a photographer would use, rather than a centred icon.
                Image(systemName: "airplane")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: w * 0.95)
                    .rotationEffect(.degrees(-8))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.20), .white.opacity(0.07)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.35), radius: h * 0.04, y: h * 0.01)
                    .offset(x: w * 0.16, y: -h * 0.04)
            }
        }
    }
}

enum BackdropTokens {

    /// The app's window fill, reused so a widget and the flight window are
    /// recognisably the same product.
    static let carbon = Color(red: 0.09, green: 0.09, blue: 0.11)

    static let duskTop = Color(red: 0.10, green: 0.13, blue: 0.24)
    static let duskMid = Color(red: 0.21, green: 0.19, blue: 0.30)
    static let duskHorizon = Color(red: 0.42, green: 0.27, blue: 0.26)

    static let nightTop = Color(red: 0.04, green: 0.06, blue: 0.14)
    static let nightMid = Color(red: 0.07, green: 0.11, blue: 0.22)
    static let nightHorizon = Color(red: 0.16, green: 0.21, blue: 0.34)

    static let glow = Color(red: 1.0, green: 0.72, blue: 0.45)
}

/// Type tokens for the widgets.
///
/// Rounded and heavy, matching the flight window's headers — the ICAO codes
/// in particular are the thing you read from across a desk, so they are sized
/// to be the first thing the eye lands on.
public enum WidgetType {
    public static func icao(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    public static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    public static func label(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    public static func readout(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    public static func caption(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .rounded) }
}

public enum WidgetPalette {
    public static let text = Color.white
    public static let secondary = Color.white.opacity(0.78)
    public static let dim = Color.white.opacity(0.55)
    public static let track = Color.white.opacity(0.28)
    public static let success = Color(red: 0.35, green: 0.88, blue: 0.52)
}
