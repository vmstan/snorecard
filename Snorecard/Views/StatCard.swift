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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: StatCard.cardHeight, alignment: .topLeading)
        .padding(12)
        .background(
            backgroundFill,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// Neutral cards (no meaningful severity) and "good" cards both
    /// get the same translucent plate — green-tinting every healthy
    /// metric made the grid feel noisy, so green is now the implicit
    /// default and only amber/red wash the plate with severity colour.
    /// The tinted cases stay low-opacity so amber/red cards read as
    /// attention cues rather than alarms.
    private var backgroundFill: Color {
        if isNeutralTint {
            return Color.primary.opacity(0.05)
        }
        return tint.opacity(0.18)
    }

    private var isNeutralTint: Bool {
        tint == .primary || tint == .severityGood
    }

    /// Shared minimum card height so rows in the grid line up regardless of
    /// which cards have subtitles.
    static let cardHeight: CGFloat = 74
}
