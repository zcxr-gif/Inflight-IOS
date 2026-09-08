import SwiftUI
import UIKit

/// What kind of thing the app is running on.
///
/// ## Why this is not a size class
///
/// The app used to decide "is this an iPad" by asking whether the horizontal
/// size class was `.regular`, and that is a different question with a
/// different answer in both directions:
///
/// - **A large iPhone in landscape is `.regular`.** Every Plus and Pro Max
///   since the 6 Plus reports a regular horizontal size class when it is
///   turned on its side. That phone was being handed the iPad's docked flight
///   pane — a four-hundred-point column on a screen with about eight hundred
///   points of width — while the setting that chooses where the pane goes was
///   hidden from it, because *that* was gated on the idiom. The two disagreed,
///   and the phone got the half of the behaviour with no way to change it.
/// - **An iPad in Slide Over is `.compact`.** A real iPad, held by a person who
///   has bought an iPad, dropped back to the phone's sheet — which is actually
///   the right layout for a column that narrow, but it meant the app had no
///   idea it was on an iPad at any point.
///
/// So the two questions are asked separately and both are honest. `Device`
/// answers *what this is*, from the idiom, which is the only thing that
/// actually knows. Whether there is room to lay something out is a size class,
/// and stays one — see `ContentView.usesFlightPane`, which needs both: an iPad,
/// and an iPad currently wide enough for a column beside the map.
///
/// ## The idiom's own edges
///
/// - An **iPhone-only app running on an iPad** in compatibility mode reports
///   `.phone`, which is correct: it is drawing into a phone-shaped window.
/// - A **"Designed for iPad" build on Apple silicon** reports `.pad`, and gets
///   the tablet layout, which is what a desktop window wants.
/// - **Mac Catalyst** reports `.mac`, and **visionOS** `.vision`. Neither is a
///   phone and both have a desk's worth of room, so `hasRoomForPanes` counts
///   them with the tablet rather than leaving them on the phone's sheet by
///   accident of an enum this file did not think about.
///
/// Read once. The idiom cannot change while the process is alive — a window
/// being resized changes the size class, never this — so there is nothing to
/// observe and nothing to invalidate.
enum Device {

    /// Lazily initialised on first use, which is from a view body on the main
    /// thread. `UIDevice` is main-actor work and this is the only place the app
    /// does it.
    static let idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom

    /// A real iPad — including a "Designed for iPad" build running in a window
    /// on a Mac, which is the same layout problem.
    static var isPad: Bool { idiom == .pad }

    /// A real iPhone, or an iPhone-shaped window on an iPad.
    static var isPhone: Bool { idiom == .phone }

    /// Whether this is the kind of device that can be *offered* a pane at all.
    ///
    /// Not whether there is room for one right now — that is the size class,
    /// and an iPad in a narrow split has none. This is the prior question: is
    /// there a desk here, or is this a phone. A phone has one answer for where
    /// the flight window goes and no setting worth showing.
    static var hasRoomForPanes: Bool {
        switch idiom {
        case .pad, .mac, .vision: return true
        default: return false
        }
    }
}
