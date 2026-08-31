import SwiftUI
import UIKit

/// A small picture of the planet, drawn by the thing that draws the planet.
///
/// The flat map's thumbnails are real `MKMapSnapshotter` renders for a stated
/// reason: a hand-tuned swatch is a *claim* about Apple's cartography, and it
/// drifts silently the first time Apple changes it. The same argument applies
/// here and has an easier answer — the planet's cartography is ours, so the
/// preview is not a picture of the renderer, it is the renderer, at forty-eight
/// points with nothing flying over it.
///
/// Which means a skin cannot be previewed wrongly. If the swatch is wrong, the
/// planet is wrong.
struct GlobeSwatch: View {

    let skin: GlobeSkin
    var backdrop: GlobeBackdrop = .app
    var side: CGFloat = 48

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// One scene, empty, shared by every swatch on screen. There is no traffic
    /// on a preview and no reason for a dozen rows to hold a dozen empty
    /// arrays.
    private static let empty = GlobeScene()

    private var scheme: ColorScheme { appearance.resolvedScheme }

    var body: some View {
        GlobeCanvas(
            camera: GlobeCamera(
                // Africa and Europe over the shoulder of the Atlantic: the one
                // face of the planet that is unmistakably the planet at this
                // size, and the one with enough coastline in it to show what a
                // skin does to a coastline.
                latitude: 18,
                longitude: 10,
                radius: side * 0.44,
                center: CGPoint(x: side / 2, y: side / 2)
            ),
            palette: skin.palette(scheme: scheme),
            backdrop: backdrop.style(
                skin: skin,
                scheme: scheme,
                windowFill: UIColor(appearance.theme.windowFill)
            ),
            scene: Self.empty,
            revision: 0,
            showsPlanes: false,
            showsFields: false,
            sun: nil,
            // Not a lie about a finger being down — it is the flag that asks
            // for the coarse cartography, which at twenty-one points of radius
            // is the only level of detail that is not waste.
            isInteracting: true
        )
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
