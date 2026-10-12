import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

/// A photograph of the map, so a choice about how the world is drawn can be
/// made by looking at it rather than by reading an adjective.
///
/// ## Why it is a real snapshot rather than a drawn swatch
///
/// The same reason the flight window's settings draw the actual window instead
/// of a picture of one. A swatch hand-tuned to look like "faded" is a claim
/// about Mapbox's cartography, and it drifts the first time Mapbox changes it —
/// silently, because nobody re-checks a decoration. Mapbox's `Snapshotter`
/// renders through the very style the map itself is handed:
/// `MapLook.mapStyle(isLight:)`, one method, both callers. A preview that is
/// wrong is now a map that is wrong.
///
/// ## Round for the globe
///
/// The one thing a snapshot cannot show is the shape of the world — the
/// snapshotter draws the flat map whatever it is asked for. So the shape is the
/// frame rather than the picture: the flat map is a rectangle of chart, the
/// globe is a disc of the same imagery it actually wears. Which is the honest
/// version of the difference, and reads at forty-eight points where a tilted
/// hemisphere would not.
struct MapStyleThumbnail: View {

    /// Exactly the look this thumbnail is a picture of. Handed to the same
    /// `configuration()` the map uses.
    let look: MapLook

    /// Whether the picture is taken in daylight or at night. The palettes that
    /// fix one or the other say so; `auto` and imagery follow the app.
    let scheme: ColorScheme

    var side: CGFloat = 48

    @StateObject private var loader = MapThumbnailLoader()
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    /// Whether this look is the app's own drawn planet, which is previewed by
    /// drawing it rather than by photographing Mapbox — the snapshotter has no
    /// idea this map exists.
    private var isDrawn: Bool { look.projection.isDrawn }

    /// The planet is round; the chart is not.
    private var isPlanet: Bool { look.projection != .flat }

    private var radius: CGFloat { theme.radiusSmall }

    var body: some View {
        picture
            .frame(width: side, height: side)
            .clipped()
            .modifier(ThumbnailFrame(isRound: isPlanet, radius: radius, stroke: theme.strokeStrong))
            // Re-taken when the look or the light changes, and only then — the
            // cache behind this means flipping through the list a second time
            // costs nothing.
            .task(id: loader.key(for: look, scheme: scheme, side: side)) {
                guard !isDrawn else { return }
                loader.load(look: look, scheme: scheme, side: side)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var picture: some View {
        if isDrawn {
            // What the planet is actually drawn in, not what is stored: the
            // shape row is a picture of the map you would get by tapping it,
            // and editing the planet is Pro. See
            // `FlightInfoAppearance.resolvedGlobeSkin`.
            GlobeSwatch(
                skin: appearance.resolvedGlobeSkin,
                backdrop: appearance.resolvedGlobeBackdrop,
                side: side
            )
        } else {
            ZStack {
                // Drawn at once, and what stays if the photograph never comes.
                // This used to be a blank piece of the panel's surface until
                // Mapbox answered, and when Mapbox did not answer it stayed
                // blank: a window whose whole purpose is to show what each map
                // looks like, showing nothing. See `MapLookSketch`.
                MapLookSketch(look: look, scheme: scheme)

                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        // The snapshot arrives a beat after the row does, and a
                        // picture appearing is the one thing on this screen
                        // that happens without anybody touching it.
                        .transition(.opacity)
                }
            }
        }
    }
}

/// A drawing of a look — its water, its land, its roads and its light, in the
/// colours that look draws them in.
///
/// What every tile shows the moment it appears, with the photograph of the real
/// map laid over it when that lands. Mapbox's snapshotter is a whole offscreen
/// map per picture, and it can be slow, or fail, or never answer; a tile that
/// waits on it shows nothing for as long as that takes. This is not a claim
/// about Mapbox's cartography to the pixel — the photograph is — but it is
/// every difference between the choices a person is making: day or night,
/// faded or full detail, chart or imagery, flat or round, the colours a Pro
/// tint picks, and how far the brightness has been turned.
struct MapLookSketch: View {

    let look: MapLook
    let scheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let ink = Ink(look: look, scheme: scheme)
            let width = size.width
            let height = size.height
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * width, y: y * height) }
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * width, y: y * height, width: w * width, height: h * height)
            }
            let whole = Path(CGRect(origin: .zero, size: size))

            // The sea, then the land: a coast with a bay in it, the far shore
            // across the water, and an island.
            context.fill(whole, with: .color(ink.water))

            var land = Path()
            land.move(to: at(0, 0))
            land.addLine(to: at(0.60, 0))
            land.addCurve(to: at(0.66, 0.34), control1: at(0.56, 0.12), control2: at(0.72, 0.22))
            land.addCurve(to: at(0.50, 0.52), control1: at(0.60, 0.44), control2: at(0.48, 0.42))
            land.addCurve(to: at(0.62, 0.74), control1: at(0.52, 0.62), control2: at(0.66, 0.64))
            land.addCurve(to: at(0.50, 1), control1: at(0.58, 0.84), control2: at(0.46, 0.90))
            land.addLine(to: at(0, 1))
            land.closeSubpath()
            land.move(to: at(0.84, 0))
            land.addLine(to: at(1, 0))
            land.addLine(to: at(1, 0.56))
            land.addCurve(to: at(0.84, 0), control1: at(0.86, 0.46), control2: at(0.92, 0.16))
            land.closeSubpath()
            land.addEllipse(in: box(0.74, 0.70, 0.16, 0.09))

            if ink.isImagery {
                context.fill(land, with: .linearGradient(
                    Gradient(colors: [ink.land, ink.landFar]),
                    startPoint: at(0, 0),
                    endPoint: at(0.7, 1)
                ))
            } else {
                context.fill(land, with: .color(ink.land))
            }

            // Parkland, or in imagery a stretch of forest.
            context.fill(Path(ellipseIn: box(0.10, 0.48, 0.24, 0.16)), with: .color(ink.park))

            // Relief, where the look has real elevation under it.
            if look.hasTerrain {
                var ridges = Path()
                ridges.move(to: at(0.06, 0.12))
                ridges.addQuadCurve(to: at(0.38, 0.16), control: at(0.22, 0.02))
                ridges.move(to: at(0.10, 0.88))
                ridges.addQuadCurve(to: at(0.38, 0.90), control: at(0.24, 0.78))
                ridges.move(to: at(0.88, 0.10))
                ridges.addQuadCurve(to: at(0.98, 0.34), control: at(0.96, 0.18))
                context.stroke(ridges, with: .color(ink.ridge), style: StrokeStyle(lineWidth: max(width * 0.03, 1.2), lineCap: .round))
            }

            // The roads, on cartography only: imagery is a photograph of them.
            if let road = ink.road {
                var major = Path()
                major.move(to: at(0, 0.24))
                major.addQuadCurve(to: at(0.58, 0.30), control: at(0.30, 0.20))
                major.move(to: at(0.30, 0))
                major.addQuadCurve(to: at(0.22, 1), control: at(0.20, 0.50))

                var minor = Path()
                minor.move(to: at(0.04, 0.72))
                minor.addLine(to: at(0.52, 0.66))
                minor.move(to: at(0.90, 0.06))
                minor.addLine(to: at(1, 0.30))
                if look.isDetailed {
                    minor.move(to: at(0.42, 0.02))
                    minor.addLine(to: at(0.46, 0.48))
                    minor.move(to: at(0.02, 0.44))
                    minor.addLine(to: at(0.40, 0.40))
                }

                let majorWidth = max(width * 0.045, 1.6)
                let minorWidth = max(width * 0.025, 1)
                if let casing = ink.casing {
                    context.stroke(major, with: .color(casing), style: StrokeStyle(lineWidth: majorWidth + 1, lineCap: .round))
                    context.stroke(minor, with: .color(casing), style: StrokeStyle(lineWidth: minorWidth + 1, lineCap: .round))
                }
                context.stroke(minor, with: .color(road), style: StrokeStyle(lineWidth: minorWidth, lineCap: .round))
                context.stroke(major, with: .color(ink.majorRoad ?? road), style: StrokeStyle(lineWidth: majorWidth, lineCap: .round))
            }

            // A place name, as the bar a name reads as at this size.
            if let label = ink.label {
                context.fill(
                    Path(roundedRect: box(0.08, 0.36, 0.26, 0.06), cornerRadius: height * 0.03),
                    with: .color(label)
                )
            }

            // The light of the hour, then a tint taken through the night.
            if let warmth = ink.warmth { context.fill(whole, with: .color(warmth)) }
            if ink.darkensTint { context.fill(whole, with: .color(.black.opacity(0.55))) }

            // A sphere, lit from above and falling away to its edge.
            if look.projection == .globe {
                context.fill(whole, with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.18), .white.opacity(0)]),
                    center: at(0.34, 0.28),
                    startRadius: 0,
                    endRadius: width * 0.55
                ))
                context.fill(whole, with: .radialGradient(
                    Gradient(colors: [.black.opacity(0), .black.opacity(0.5)]),
                    center: at(0.5, 0.5),
                    startRadius: width * 0.30,
                    endRadius: width * 0.52
                ))
            }

            // And the map's own wash, exactly as the map lays it on.
            let wash = look.wash
            if wash.isVisible {
                context.fill(whole, with: .color(Color(uiColor: wash.color).opacity(Double(wash.alpha))))
            }
        }
    }

    /// The colours one look is drawn in.
    private struct Ink {
        var water: Color
        var land: Color
        var landFar: Color
        var park: Color
        var road: Color?
        var majorRoad: Color?
        var casing: Color?
        var label: Color?
        var ridge: Color
        var warmth: Color?
        var isImagery: Bool
        var darkensTint = false

        init(look: MapLook, scheme: ColorScheme) {
            func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

            let custom = look.custom
            let night: Bool
            switch custom.light {
            case .auto: night = scheme == .dark
            case .day, .dawn: night = false
            case .dusk, .night: night = true
            }
            switch custom.light {
            case .dawn: warmth = rgb(1, 0.72, 0.52).opacity(0.2)
            case .dusk: warmth = rgb(0.62, 0.38, 0.62).opacity(0.22)
            default: warmth = nil
            }

            isImagery = look.resolvedPalette.usesImagery
            if isImagery {
                water = rgb(0.05, 0.12, 0.20)
                land = rgb(0.36, 0.38, 0.24)
                landFar = rgb(0.52, 0.46, 0.34)
                park = rgb(0.19, 0.27, 0.15)
                road = nil
                majorRoad = nil
                casing = nil
                ridge = .black.opacity(0.28)
                // Flat imagery carries no names at all; the globe keeps them.
                label = look.projection == .globe && custom.showsPlaceNames ? Color.white.opacity(0.75) : nil
                return
            }

            let detailed = look.isDetailed
            if night {
                water = detailed ? rgb(0.07, 0.11, 0.20) : rgb(0.10, 0.12, 0.16)
                land = detailed ? rgb(0.17, 0.19, 0.24) : rgb(0.18, 0.19, 0.21)
                park = detailed ? rgb(0.14, 0.23, 0.19) : rgb(0.17, 0.21, 0.19)
                road = detailed ? rgb(0.34, 0.36, 0.43) : rgb(0.26, 0.27, 0.30)
                majorRoad = detailed ? rgb(0.50, 0.43, 0.30) : nil
                casing = nil
                label = rgb(0.62, 0.64, 0.70)
                ridge = .black.opacity(0.35)
            } else {
                water = detailed ? rgb(0.60, 0.80, 0.95) : rgb(0.78, 0.85, 0.91)
                land = detailed ? rgb(0.96, 0.95, 0.91) : rgb(0.95, 0.95, 0.94)
                park = detailed ? rgb(0.76, 0.89, 0.70) : rgb(0.87, 0.91, 0.85)
                road = Color.white
                majorRoad = detailed ? rgb(0.99, 0.85, 0.52) : nil
                casing = rgb(0.80, 0.81, 0.84)
                label = rgb(0.45, 0.47, 0.52)
                ridge = .black.opacity(0.14)
            }
            landFar = land
            if !custom.showsPlaceNames { label = nil }

            // A Pro tint is the map's own water and land, and Mapbox's light
            // still takes it through the night.
            if let swatch = custom.tint.swatch {
                water = swatch.water
                land = swatch.land
                landFar = swatch.land
                darkensTint = night
            }
        }
    }
}

/// Clips and outlines the picture, round or square.
///
/// A modifier rather than an `AnyShape`, because `strokeBorder` — which insets
/// the line rather than straddling the edge, and is the difference between a
/// clean disc and one with a shaved outline — is only on `InsettableShape`, and
/// `AnyShape` is not one.
private struct ThumbnailFrame: ViewModifier {

    let isRound: Bool
    let radius: CGFloat
    let stroke: Color

    func body(content: Content) -> some View {
        if isRound {
            content
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(stroke, lineWidth: 1) }
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 1)
                }
        }
    }
}

/// Takes the pictures, and remembers them.
///
/// Shaped like `RemoteImageLoader`, which does the same job for the aircraft
/// photographs: not an actor, hops to the main queue to publish, and holds the
/// one request it is waiting on so a stale answer can be recognised and
/// dropped.
final class MapThumbnailLoader: ObservableObject {

    @Published private(set) var image: UIImage?

    /// Shared across every row and every visit to the panel: six looks times
    /// two schemes is a dozen small images, and re-rendering them each time
    /// somebody opens the map settings would be a visible stutter for nothing.
    private static let cache = NSCache<NSString, UIImage>()

    /// Where the picture is taken.
    ///
    /// Wanted: a coastline, so the palettes that change the sea have a sea to
    /// change; relief, so imagery and terrain have something to be about; and a
    /// city, so muted and full-detail cartography visibly differ. The bay at
    /// San Francisco is all three inside forty kilometres, and is recognisable
    /// enough that somebody looking down a list of six can see that the only
    /// thing changing is the drawing.
    private static let centre = CLLocationCoordinate2D(latitude: 37.80, longitude: -122.42)
    private static let span: CLLocationDistance = 44_000

    /// Held so it is not deallocated mid-render, and so a row that changes
    /// under a slow snapshot can drop the one it no longer wants.
    ///
    /// Held for the length of the render and no longer, and that matters:
    /// Mapbox's snapshotter drops its answer without a word if it has been let
    /// go by the time the render finishes. A picture is only ever taken from
    /// the snapshotter this row is still holding — see `finished`.
    private var snapshotter: Snapshotter?
    private var snapshotCancelables: Set<AnyCancelable> = []
    private var requested: String?

    /// This row's turn in `MapThumbnailQueue`, while it is taking a picture:
    /// handed back when the picture lands, fails, or runs out of time, and on
    /// the way out if the row goes first.
    private var turn: (() -> Void)?

    /// How long one picture is given before it is given up on. A snapshot is
    /// a whole map — style, fonts, tiles — and the first one of a look on a
    /// slow connection takes a few seconds; one that has not come in this long
    /// is not coming, and the tiles behind it are waiting.
    private static let timeout: TimeInterval = 12

    deinit {
        MapThumbnailQueue.withdraw(self)
        snapshotter?.cancel()
        turn?()
    }

    /// The snapshot as Mapbox drew it, before the map's wash goes over it, and
    /// the wash currently on the published picture.
    ///
    /// Held apart because they change at completely different rates. The
    /// snapshot is a render, cached across every row and every visit; the wash
    /// is a finger on a slider, and re-photographing San Francisco for each
    /// tick of it would be a hundred snapshots on the way across the panel. So
    /// a change of brightness re-composites what is already here and takes no
    /// picture at all.
    private var base: UIImage?
    private var appliedWash: MapWash?

    func key(for look: MapLook, scheme: ColorScheme, side: CGFloat) -> String {
        [
            look.projection.rawValue,
            // Resolved rather than raw: the globe is imagery whatever the
            // palette says, and two rows that render identically should share
            // one picture.
            look.resolvedPalette.rawValue,
            look.isDetailed ? "detail" : "muted",
            look.hasTerrain ? "terrain" : "flat",
            look.custom.key,
            scheme == .dark ? "night" : "day",
            String(Int(side))
        ].joined(separator: "|")
    }

    /// The picture this row wants, taking it if it is not already had.
    ///
    /// The key deliberately says nothing about the wash — see `base` — so a
    /// brightness that has moved under an unchanged look is answered by
    /// recolouring the picture in hand.
    func load(look: MapLook, scheme: ColorScheme, side: CGFloat) {
        let key = self.key(for: look, scheme: scheme, side: side)
        let wash = look.wash

        if requested == key {
            guard appliedWash != wash else { return }
            appliedWash = wash
            if let base = base { image = Self.washed(base, with: wash) }
            return
        }

        requested = key
        appliedWash = wash

        if let cached = Self.cache.object(forKey: key as NSString) {
            base = cached
            image = Self.washed(cached, with: wash)
            return
        }

        // Whatever was on its way is a picture of a look this row is no longer
        // showing.
        snapshotter?.cancel()
        snapshotter = nil
        snapshotCancelables.removeAll()
        handBackTurn()
        base = nil
        image = nil

        // In the queue rather than at once: see `MapThumbnailQueue`.
        let style = look.mapStyle(isLight: scheme == .light)
        MapThumbnailQueue.enqueue(self) { [weak self] turn in
            // Gone, or moved on to another look while it waited.
            guard let self = self, self.requested == key else { return turn() }
            self.turn = turn
            self.snapshot(key: key, style: style, side: side, wash: wash, attempt: 1)
        }
    }

    /// One attempt at a picture.
    private func snapshot(key: String, style: MapStyle, side: CGFloat, wash: MapWash, attempt: Int) {
        // Square, and rendered at twice the drawn side so the disc the globe is
        // clipped to still has a sharp edge on a retina screen.
        let snapshotter = Snapshotter(
            options: MapSnapshotOptions(size: CGSize(width: side, height: side), pixelRatio: 2)
        )
        self.snapshotter = snapshotter
        snapshotCancelables.removeAll()

        let circumference = 40_075_016.686 * cos(Self.centre.latitude * .pi / 180)
        let zoom = log2(circumference * Double(side) / (512 * Self.span))
        let camera = CameraOptions(center: Self.centre, zoom: CGFloat(zoom))
        snapshotter.setCamera(to: camera)

        snapshotter.onStyleLoaded.observeNext { [weak self, weak snapshotter] _ in
            guard let snapshotter = snapshotter else { return }
            // Again, once the style is in: a style can carry a camera of its
            // own, and the picture has to be of the bay whatever it says.
            snapshotter.setCamera(to: camera)
            snapshotter.start(overlayHandler: nil) { [weak snapshotter] result in
                // The attribution is composited off the main thread, so the
                // answer can arrive on any queue.
                DispatchQueue.main.async {
                    self?.finished(result, from: snapshotter, key: key, style: style, side: side, wash: wash, attempt: attempt)
                }
            }
        }.store(in: &snapshotCancelables)

        snapshotter.load(mapStyle: style)

        // And a limit, so one picture that never comes cannot hold up every
        // tile behind it. Let go of here, so an answer that does turn up later
        // is recognised as stale in `finished` and dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self, weak snapshotter] in
            guard let self = self, let snapshotter = snapshotter, self.snapshotter === snapshotter else { return }
            NSLog("[Map] thumbnail %@ timed out after %.0fs (attempt %ld)", key, Self.timeout, attempt)
            self.snapshotter = nil
            self.snapshotCancelables.removeAll()
            snapshotter.cancel()
            self.handBackTurn()
        }
    }

    /// What one attempt came back with.
    private func finished(
        _ result: Result<UIImage, Snapshotter.SnapshotError>,
        from snapshotter: Snapshotter?,
        key: String,
        style: MapStyle,
        side: CGFloat,
        wash: MapWash,
        attempt: Int
    ) {
        // From a snapshotter this row has since let go of — a look it no longer
        // shows, or one that ran out of time — this answers nothing.
        guard let snapshotter = snapshotter, self.snapshotter === snapshotter else { return }
        self.snapshotter = nil
        snapshotCancelables.removeAll()

        switch result {
        case .success(let taken):
            // Cached bare. The wash goes on below, against whatever the slider
            // says by the time this lands rather than what it said when the
            // picture was asked for.
            Self.cache.setObject(taken, forKey: key as NSString)
            if requested == key {
                base = taken
                let picture = Self.washed(taken, with: appliedWash ?? wash)
                withAnimation(Motion.content) { image = picture }
            }
            handBackTurn()

        case .failure(let error):
            // Said rather than swallowed: a failed snapshot used to leave its
            // tile blank with nothing anywhere to say why.
            NSLog("[Map] thumbnail %@ failed (attempt %ld): %@", key, attempt, String(describing: error))
            // Once more, keeping the turn: the usual failure is a tile or a
            // font that did not arrive, and the second try has the rest cached.
            if attempt < 2, requested == key {
                snapshot(key: key, style: style, side: side, wash: wash, attempt: attempt + 1)
            } else {
                handBackTurn()
            }
        }
    }

    private func handBackTurn() {
        let turn = self.turn
        self.turn = nil
        turn?()
    }

    /// The snapshot with the map's own wash laid over it, so a row is a
    /// picture of what you will actually be looking at rather than of the
    /// cartography underneath it.
    ///
    /// Returns the picture untouched when there is nothing to lay on, which is
    /// the ordinary case and costs a comparison rather than a redraw.
    private static func washed(_ picture: UIImage, with wash: MapWash) -> UIImage {
        guard wash.isVisible else { return picture }

        let format = UIGraphicsImageRendererFormat()
        format.scale = picture.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: picture.size, format: format).image { context in
            picture.draw(at: .zero)
            wash.color.withAlphaComponent(wash.alpha).setFill()
            context.fill(CGRect(origin: .zero, size: picture.size))
        }
    }
}

/// Takes the thumbnails' pictures one at a time, for every tile in the app.
///
/// The map's window asked for seven at once — four finishes and three shapes —
/// and every one of them is a whole offscreen Mapbox map, loading the whole of
/// Standard, its fonts and its tiles, on top of the live map that is already
/// running one. One at a time they arrive in order and each one has the
/// resources the last one fetched; the tiles show their drawing until then.
/// Main thread only, like everything that touches it.
enum MapThumbnailQueue {

    private static var waiting: [(owner: ObjectIdentifier, job: (@escaping () -> Void) -> Void)] = []
    private static var isBusy = false

    /// Puts a picture in the line, in place of any this owner already has
    /// waiting. The job is handed its turn, and must hand it back exactly
    /// when it is finished with it — a second hand-back is ignored.
    static func enqueue(_ owner: AnyObject, job: @escaping (_ turn: @escaping () -> Void) -> Void) {
        let id = ObjectIdentifier(owner)
        waiting.removeAll { $0.owner == id }
        waiting.append((owner: id, job: job))
        startNext()
    }

    /// Takes an owner's picture out of the line, if it has not started.
    static func withdraw(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        waiting.removeAll { $0.owner == id }
    }

    private static func startNext() {
        guard !isBusy, !waiting.isEmpty else { return }
        isBusy = true
        let job = waiting.removeFirst().job
        var isHandedBack = false
        job {
            guard !isHandedBack else { return }
            isHandedBack = true
            // On the next turn of the main queue, so a job that hands back at
            // once does not start the next one inside itself.
            DispatchQueue.main.async {
                Self.isBusy = false
                Self.startNext()
            }
        }
    }
}
