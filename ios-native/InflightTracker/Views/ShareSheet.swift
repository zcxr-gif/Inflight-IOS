import SwiftUI
import UIKit

/// What gets shared out of the flight window.
///
/// A struct rather than a bare `String` so the share sheet has a subject to
/// put on an email and a title to show in its own header. Sharing a loose
/// string gives an activity sheet with no heading at all, which is most of
/// what made the old one look broken.
struct FlightShare: Identifiable {

    /// Stable per share, so presenting twice in a row re-presents rather than
    /// being treated as the same item still showing.
    let id = UUID()

    let subject: String
    let body: String
}

/// `UIActivityViewController`, presented from a `.sheet(item:)`.
///
/// This deliberately replaces `ShareLink`. The flight window is rebuilt on
/// every packet from the live socket — several times a minute — and its share
/// control was being handed a freshly computed string each time. Driving the
/// presentation from state instead means the sheet is created once, from a
/// snapshot taken at the moment of the tap, and nothing the feed does while it
/// is open can disturb it.
///
/// Taking a snapshot is also the honest thing to share: the telemetry in the
/// message is true as of when the button was pressed, and the message says so,
/// rather than being a live reading pasted into a conversation with no time
/// attached to it.
struct ShareSheet: UIViewControllerRepresentable {

    let share: FlightShare

    /// Called when the activity controller finishes — shared, cancelled, or
    /// dismissed. The presenting state has to be cleared by hand: the
    /// controller dismisses *itself*, which SwiftUI's `sheet(item:)` binding
    /// never hears about, and a binding left set means the next tap on Share
    /// is a no-op because the item hasn't changed.
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [FlightShareSource(share: share)],
            applicationActivities: nil
        )
        // The subject is supplied by the item source's
        // `subjectForActivityType`, which is the supported route. Setting a
        // "subject" key by KVC is a long-lived piece of folklore that is not
        // API and can raise on a system that doesn't implement it.
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    /// Anchors the popover on iPad.
    ///
    /// The app is universal, and an activity controller that ends up in a
    /// popover presentation without a source view raises rather than
    /// degrading — the "you must provide sourceView, sourceRect or
    /// barButtonItem" exception. Hosting it inside a SwiftUI sheet usually
    /// avoids that path entirely, but "usually" is not a good enough reason to
    /// leave a crash reachable, so it is anchored to its own view's centre as
    /// a fallback. On iPhone there is no popover and this does nothing.
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        guard let popover = controller.popoverPresentationController else { return }
        if popover.sourceView == nil {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
    }
}

/// Gives each destination the right thing.
///
/// Mail gets a subject line, Messages and the pasteboard get the text, and the
/// sheet's own header gets the flight's name instead of the first line of the
/// body — which is what an activity controller falls back to when it is handed
/// a plain string and has nothing better to show.
private final class FlightShareSource: NSObject, UIActivityItemSource {

    private let share: FlightShare

    init(share: FlightShare) {
        self.share = share
        super.init()
    }

    /// Returned before the sheet is shown, purely to size its preview. It must
    /// be the same *type* as the real item, so this is a short stand-in rather
    /// than an empty string — an empty placeholder makes some destinations
    /// decide there is nothing to share and hide themselves.
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        share.subject
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        share.body
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        share.subject
    }
}
