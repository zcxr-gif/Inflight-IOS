import SafariServices
import SwiftUI

/// Stripe's checkout page, in a sheet over the app.
///
/// Paying used to send the pilot to the Safari *app*: the tracker went away
/// mid-decision, the map stopped, and getting back meant a return page whose
/// only job was to bounce them here again. This is the same page in the same
/// browser engine — `SFSafariViewController`, so it is Safari that renders it,
/// keeps its own cookies and shows the padlock and the real domain — presented
/// the way every other window in this app is: up from the bottom, over what
/// the pilot was already looking at.
///
/// ## What it deliberately is not
///
/// Not a `WKWebView`. A checkout drawn inside a view this app owns is one this
/// app could read, and "we cannot see your card details" stops being a fact
/// about the architecture and becomes a promise. Safari's own controller is
/// walled off from the host app — no delegate sees the page, its DOM or its
/// form fields — which is also why the sheet cannot notice the payment finish
/// for itself and `WebSubscription` learns it from the return link instead.
///
/// ## Chrome
///
/// `.cancel` rather than `.done` on the dismiss button: at the moment somebody
/// is looking at a card form, the honest label for backing out is Cancel.
/// Collapsing is off because a checkout is a form, not an article — the bar
/// that names the domain being paid should not slide away while they scroll.
struct WebCheckoutSheet: UIViewControllerRepresentable {

    /// The hosted checkout page Stripe handed back.
    let page: URL

    /// The app's accent, so the browser's controls belong to the same app.
    var tint: Color

    /// The pilot closed it themselves. Distinct from the checkout ending —
    /// that arrives as a deep link, not through here.
    var onClose: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false

        let controller = SFSafariViewController(url: page, configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .cancel
        controller.preferredControlTintColor = UIColor(tint)
        return controller
    }

    /// Nothing to update — the URL is fixed for the life of the sheet, and
    /// handing `SFSafariViewController` a new one is not a thing it does. Only
    /// the closure is refreshed, so a re-rendered parent's callback is the one
    /// that runs.
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.onClose = onClose
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {

        var onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        /// Cancel tapped. The controller is inside a SwiftUI sheet, so it has
        /// nothing to dismiss itself from — the binding that presented it has
        /// to be cleared, which is what this is for.
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onClose()
        }
    }
}
