import SwiftUI

/// A single-metric summary card used in the day-detail header grid.
/// Label / primary value / optional subtitle, wrapped in a Liquid Glass
/// material background that adapts to both macOS 26 and iOS 26.
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
                .foregroundStyle(tint)
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
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// Shared minimum card height so rows in the grid line up regardless of
    /// which cards have subtitles.
    static let cardHeight: CGFloat = 74
}
