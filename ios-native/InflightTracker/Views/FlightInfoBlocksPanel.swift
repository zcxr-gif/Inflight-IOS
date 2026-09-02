import SwiftUI

/// Where the open window's third look is arranged.
///
/// ## Why it is a panel of its own
///
/// The flight-window panel is a page of *choices* — which peek, which layout,
/// airline colours on or off — and each is one row you read and answer. This is
/// not that. It is a list with an order, eight switches and a colour well per
/// row, and dropped into the middle of those choices it would be the only thing
/// on the screen anybody could see. It also only exists for one of the three
/// layouts, and a section that is there for one option of a picker and gone for
/// the other two makes the picker itself hard to read.
///
/// ## Buttons rather than a drag
///
/// Each row moves with an up and a down, not by being dragged. A drag is the
/// nicer gesture and this is the wrong place for it: the list lives inside a
/// sheet that is itself dragged to size, and a long press that starts a reorder
/// is a long press the sheet was about to treat as a pull. The buttons also
/// give the whole thing to VoiceOver for free, which a custom drag does not.
struct FlightInfoBlocksPanel: View {

    @ObservedObject private var arrangement = FlightInfoBlocks.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    /// Which row has its colour and treatment open. One at a time: every row
    /// expanded at once is the list nobody can see the order of.
    @State private var expanded: FlightInfoBlockKind?

    var body: some View {
        MapPanel(
            title: "Blocks",
            subtitle: "What the Detail window is made of, and in what order"
        ) {
            PanelSection(title: "ORDER") {
                ForEach(arrangement.blocks) { block in
                    if position(of: block) > 0 { PanelDivider() }

                    row(block)
                }
            }
            .panelEntrance(0)

            if !arrangement.isStandard {
                PanelSection(title: "START AGAIN") {
                    PanelActionRow(
                        title: "Put the blocks back",
                        symbol: "arrow.uturn.backward",
                        detail: "The order and the colours the window ships with.",
                        action: { arrangement.reset() }
                    )
                }
                .panelEntrance(1)
            }

            Text(Self.note)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .panelEntrance(2)
        }
        // The window behind this is redrawn as the list is edited, and the
        // whole point of the panel is watching that happen.
        .motion(Motion.panel, value: arrangement.blocks)
    }

    private static let note = """
        Switching a block off hides it here and nowhere else — every number in \
        this window is on the app's own cards too. The identity band stays on, \
        because a window that doesn't say which aircraft it is about isn't one.
        """

    // MARK: - A block's row

    /// Where this block currently sits, which is what greys the movers at the
    /// ends of the list. Looked up rather than carried in from an enumeration:
    /// the rows are identified by what they are, and the list reorders under
    /// them.
    private func position(of block: FlightInfoBlock) -> Int {
        arrangement.blocks.firstIndex { $0.kind == block.kind } ?? 0
    }

    private func row(_ block: FlightInfoBlock) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                mover(block)

                Button {
                    guard block.kind.wearsColour else { return }
                    expanded = expanded == block.kind ? nil : block.kind
                } label: {
                    HStack(spacing: 10) {
                        PanelRowLabel(title: block.kind.label, symbol: block.kind.symbol)

                        Spacer(minLength: 6)

                        if block.kind.wearsColour {
                            if block.tint.usesColour { swatch(block) }

                            Image(systemName: expanded == block.kind ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textDim)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!block.kind.wearsColour)
                .accessibilityLabel("\(block.kind.label). \(block.kind.detail)")
                .accessibilityHint(block.kind.wearsColour ? "Opens this block's colour" : "")

                Toggle("", isOn: onBinding(block))
                    .labelsHidden()
                    .tint(theme.accent)
                    .disabled(!block.kind.isRemovable)
                    .accessibilityLabel("Show \(block.kind.label)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // A block that is off is still in the list, in its place, so
            // putting it back is finding it rather than hunting for it.
            .opacity(block.isOn ? 1 : 0.5)

            if expanded == block.kind, block.kind.wearsColour {
                colours(block)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motion(Motion.panel, value: expanded)
    }

    /// Up and down, greyed at the ends of the list.
    private func mover(_ block: FlightInfoBlock) -> some View {
        let index = position(of: block)

        return VStack(spacing: 2) {
            step(block, by: -1, symbol: "chevron.up", enabled: index > 0)
            step(block, by: 1, symbol: "chevron.down", enabled: index < arrangement.blocks.count - 1)
        }
    }

    private func step(
        _ block: FlightInfoBlock,
        by amount: Int,
        symbol: String,
        enabled: Bool
    ) -> some View {
        Button {
            arrangement.move(block.kind, by: amount)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? theme.textSecondary : theme.textDim.opacity(0.4))
                .frame(width: 22, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(amount < 0 ? "Move \(block.kind.label) up" : "Move \(block.kind.label) down")
    }

    /// The colour half of a row: how the colour is worn, and which one.
    private func colours(_ block: FlightInfoBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Colour", selection: tintBinding(block)) {
                ForEach(FlightInfoBlockTint.allCases) { tint in
                    Text(tint.label).tag(tint)
                }
            }
            .pickerStyle(.segmented)

            Text(block.tint.detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if block.tint.usesColour {
                HStack(spacing: 10) {
                    ColorPicker(
                        "",
                        selection: colourBinding(block),
                        supportsOpacity: false
                    )
                    .labelsHidden()

                    Text(block.colour == nil ? "The window's own accent" : "This block's colour")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .flightInfoLine(minimumScale: 0.7)

                    Spacer(minLength: 6)

                    if block.colour != nil {
                        Button {
                            arrangement.setColour(nil, for: block.kind)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textDim)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Put \(block.kind.label) back on the window's accent")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func swatch(_ block: FlightInfoBlock) -> some View {
        Circle()
            .fill(block.colour ?? theme.accent)
            .frame(width: 14, height: 14)
            .overlay { Circle().strokeBorder(theme.stroke, lineWidth: 1) }
            .accessibilityHidden(true)
    }

    // MARK: - Bindings

    /// Written through the store rather than into the array, so every edit goes
    /// down the one path that persists and repairs.
    private func onBinding(_ block: FlightInfoBlock) -> Binding<Bool> {
        Binding(
            get: { arrangement.block(block.kind).isOn },
            set: { arrangement.setOn($0, for: block.kind) }
        )
    }

    private func tintBinding(_ block: FlightInfoBlock) -> Binding<FlightInfoBlockTint> {
        Binding(
            get: { arrangement.block(block.kind).tint },
            set: { arrangement.setTint($0, for: block.kind) }
        )
    }

    /// The colour well shows the window's accent for a block that has not been
    /// given one, so opening it starts from what is on screen rather than from
    /// black — and the first drag of the picker is what makes the colour the
    /// block's own.
    private func colourBinding(_ block: FlightInfoBlock) -> Binding<Color> {
        Binding(
            get: { arrangement.block(block.kind).colour ?? theme.accent },
            set: { arrangement.setColour($0, for: block.kind) }
        )
    }
}
