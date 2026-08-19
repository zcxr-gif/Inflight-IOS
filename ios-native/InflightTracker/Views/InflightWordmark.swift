import SwiftUI

/// The Inflight logo, as the app draws it everywhere it appears.
///
/// One view rather than an `Image` at each call site, because a wordmark that
/// is 20pt in one place and 24pt in another with a different opacity reads as
/// two logos. The asset carries an ink version and a white one and the catalog
/// picks between them by luminosity, so the only thing a caller ever chooses is
/// how tall it is.
///
/// Height rather than width: the mark is a word, and a word is sized by its
/// cap height. Fixing the width instead would make a long logo and a short one
/// set at different text sizes.
struct InflightWordmark: View {

    /// Cap-to-cap height in points. The default is the size it sits at above a
    /// panel's own title.
    var height: CGFloat = 22

    var body: some View {
        Image("InflightLogo")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            // The asset is the brand's own artwork; nothing here recolours it.
            // The catalog's dark variant is what makes it legible on carbon.
            .accessibilityLabel("Inflight")
    }
}
