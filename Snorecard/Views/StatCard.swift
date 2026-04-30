import SwiftUI

/// A single-metric summary card used in the day-detail header grid.
/// Label / primary value / optional subtitle, wrapped in a Liquid Glass
/// material background that adapts to both macOS 26 and iOS 26.
///
/// Severity is conveyed through a subtle tint on the card's background
/// rather than by colouring the value text — big monochrome numbers
/// read faster at a glance and stay legible in both light and dark
/// modes, while the tinted plate gives peripheral-vision feedback on
/// which cards are in a concerning range.
struct StatCard: View {
    let label: String
    let value: String
    var subtitle: String? = nil
    var tint: Color = .primary
    /// Optional tap handler — when set, the card renders as a
    /// button (with a subtle hint chip) so it's obvious the metric
    /// is interactive. Used by `DayDetailView` to open the
    /// on-device "Explain this metric" sheet.
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Explain this metric")
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        // `.contentShape` is load-bearing on tappable cards:
        // `.glassEffect(...)` doesn't extend the view's hit-test
        // area the way a solid `.background(...)` fill does, so
        // without it the wrapping Button only fires on the actual
        // text glyphs and the empty space inside the card swallows
        // taps. Setting the shape on the padded card before the
        // glass effect means hits land anywhere inside the card
        // outline.
        let card = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if onTap != nil {
                    // Muted instead of accent-tinted so the cue
                    // reads as a subtle hint, not a highlight
                    // competing with the metric value.
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            // Always render the subtitle row — hidden when nil —
            // so the primary value lands at the same vertical
            // offset across every card in the grid. Without this
            // reservation, a subtitle-less card like EPAP-on-CPAP
            // has its value float up while its neighbours sit
            // lower, making the row look ragged.
            Text(subtitle ?? " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(subtitle == nil ? 0 : 1)
                .accessibilityHidden(subtitle == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: StatCard.cardHeight, alignment: .topLeading)
        .padding(12)
        .contentShape(RoundedRectangle(cornerRadius: 12))

        // Every card sits on Liquid Glass so the chrome stays
        // visually consistent with the per-hour and Trends panels
        // below. Severity-tinted cards (amber / red) layer the
        // colour onto the glass material via `tint(_:)` rather
        // than swapping in a solid fill — that way the wash still
        // reads as an attention cue without flattening the
        // material's blur and depth.
        if isNeutralTint {
            card.glassEffect(in: RoundedRectangle(cornerRadius: 12))
        } else {
            card.glassEffect(
                .regular.tint(tint.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
    }

    private var isNeutralTint: Bool {
        tint == .primary || tint == .severityGood
    }

    /// Shared minimum card height so rows in the grid line up regardless of
    /// which cards have subtitles.
    static let cardHeight: CGFloat = 74
}
