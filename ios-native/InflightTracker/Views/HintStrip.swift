import SwiftUI

/// A hint, where it applies.
///
/// One line, dim, dismissible, and gone for good once it has been read a few
/// times — see `HintsStore`. It never covers anything, never animates in to be
/// noticed, and a place that has run out of things to say draws nothing at all.
///
/// Which is the reason there is no state in here. The obvious build — resolve
/// the line in `onAppear`, hold it in `@State` — needs a view present to run
/// the modifier on, and this view's whole job is to disappear; a container kept
/// alive to host the modifier would go on claiming its parent's spacing after
/// the last hint retired. The store memoises per launch instead, so `body` can
/// simply ask.
struct HintStrip: View {

    let placement: HintPlacement

    /// Floating over the map rather than sitting at the foot of a panel. The
    /// map has no card to sit on, so this variant brings its own chrome — the
    /// same glass every other floating control uses.
    var isFloating = false

    @ObservedObject private var hints = HintsStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        if hints.isEnabled, let hint = hints.current(for: placement) {
            strip(hint)
        }
    }

    @ViewBuilder
    private func strip(_ hint: Hint) -> some View {
        if isFloating {
            row(hint)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .environment(\.colorScheme, theme.colorScheme)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            // Level with a panel's own footnotes rather than boxed: on a card
            // it would read as another section, and it is an aside.
            row(hint)
                .padding(.horizontal, 2)
                .transition(.opacity)
        }
    }

    private func row(_ hint: Hint) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // The glyph and the line are one thing to read; the button beside
            // them stays its own control, so combining stops at this stack.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
                    // Nudged onto the first line's baseline, which a
                    // top-aligned glyph misses next to text this small.
                    .padding(.top, 1)

                Text(hint.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hint: \(hint.text)")

            Button {
                withAnimation(Motion.row) {
                    hints.dismiss(hint)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textDim)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss this hint")
        }
    }
}
