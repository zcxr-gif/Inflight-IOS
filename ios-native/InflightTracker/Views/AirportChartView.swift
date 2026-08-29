import PDFKit
import SwiftUI

/// The airport diagram, full screen.
///
/// A chart is a document rather than a piece of the app's chrome, so it is
/// shown the way a document is: the sheet on its own ground, at whatever zoom
/// the reader wants, with nothing drawn over it. The theme reaches the frame
/// around it and stops at the paper — an FAA diagram is black on white and
/// tinting it would be editing a published chart.
struct AirportChartView: View {

    let icao: String
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        SheetWindow(theme: theme) {
            header
        } content: {
            ChartSheet(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(icao) AIRPORT DIAGRAM")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.textPrimary)

                // Said out loud rather than assumed. A chart is a legal
                // document with a date on it, and this one is the FAA's,
                // fetched for the cycle that was current when it was cached.
                Text("Published by the FAA · not for real-world navigation")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }

            Spacer(minLength: 8)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .flightInfoSurface(theme, in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the airport diagram")
        }
    }
}

/// `PDFView`, which is the whole of why this is not drawn by hand.
///
/// A chart is a vector sheet with type on it at every size, and PDFKit already
/// knows how to draw one, scroll it and let somebody pinch into the corner of
/// an apron to read a stand number. Rendering it to an image at some chosen
/// resolution would take all of that away in exchange for nothing.
private struct ChartSheet: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        // The paper is white and the app may not be. A neutral ground around
        // the sheet stops a dark theme from putting a black surround on a
        // black-on-white chart, which reads as a rendering fault.
        view.backgroundColor = UIColor(white: 0.35, alpha: 1)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
    }
}
