import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// A photograph of the map, so a choice about how the world is drawn can be
/// made by looking at it rather than by reading an adjective.
///
/// ## Why it is a real snapshot rather than a drawn swatch
///
/// The same reason the flight window's settings draw the actual window instead
/// of a picture of one. A swatch hand-tuned to look like "muted" is a claim
/// about Apple's cartography, and it drifts the first time Apple changes it —
/// silently, because nobody re-checks a decoration. `MKMapSnapshotter` renders
/// through the very `MKMapConfiguration` the map itself is handed:
/// `MapLook.configuration()`, one method, both callers. A preview that is wrong
/// is now a map that is wrong.
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
    /// drawing it rather than by photographing MapKit — the snapshotter has no
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
        } else if let image = loader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                // The snapshot arrives a beat after the row does, and a picture
                // appearing is the one thing on this screen that happens
                // without anybody touching it.
                .transition(.opacity)
        } else {
            // Not a spinner. A thumbnail this size with a spinner in it is a
            // row that looks broken while it works; a piece of the panel's own
            // surface is a row that looks like it is loading, which it is.
            Rectangle().fill(theme.surfaceFill)
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
    /// under a slow snapshot can cancel the one it no longer wants.
    private var snapshotter: MKMapSnapshotter?
    private var requested: String?

    func key(for look: MapLook, scheme: ColorScheme, side: CGFloat) -> String {
        [
            look.projection.rawValue,
            // Resolved rather than raw: the globe is imagery whatever the
            // palette says, and two rows that render identically should share
            // one picture.
            look.resolvedPalette.rawValue,
            look.isDetailed ? "detail" : "muted",
            look.hasTerrain ? "terrain" : "flat",
            scheme == .dark ? "night" : "day",
            String(Int(side))
        ].joined(separator: "|")
    }

    func load(look: MapLook, scheme: ColorScheme, side: CGFloat) {
        let key = self.key(for: look, scheme: scheme, side: side)
        guard requested != key else { return }
        requested = key

        if let cached = Self.cache.object(forKey: key as NSString) {
            image = cached
            return
        }

        // Whatever was on its way is a picture of a look this row is no longer
        // showing.
        snapshotter?.cancel()
        image = nil

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: Self.centre,
            latitudinalMeters: Self.span,
            longitudinalMeters: Self.span
        )
        // Square, and rendered at twice the drawn side so the disc the globe is
        // clipped to still has a sharp edge on a retina screen.
        options.size = CGSize(width: side * 2, height: side * 2)
        options.preferredConfiguration = look.configuration()
        options.traitCollection = UITraitCollection(
            userInterfaceStyle: scheme == .dark ? .dark : .light
        )

        let snapshotter = MKMapSnapshotter(options: options)
        self.snapshotter = snapshotter

        snapshotter.start(with: .global(qos: .userInitiated)) { [weak self] snapshot, _ in
            guard let picture = snapshot?.image else { return }
            Self.cache.setObject(picture, forKey: key as NSString)

            // The outer capture is the weak one; this closure only needs the
            // optional it already holds.
            DispatchQueue.main.async {
                guard let self = self, self.requested == key else { return }
                withAnimation(Motion.content) { self.image = picture }
            }
        }
    }
}
