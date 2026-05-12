import SwiftUI

/// Shared status surface used by every "loading / error / nothing
/// here yet" placeholder that occupies a hero slot in the app: large
/// 36 pt SF Symbol, headline, optional centered caption, optional
/// spinner. Tint travels with the symbol so callers can dial up
/// alarm (red), progress (tint), or neutral (secondary) without
/// restating the layout.
///
/// Drop this in anywhere a screen is empty for a recoverable reason
/// — decoding sessions, no summary recorded, the user excluded
/// everything, a load failed. Inline status rows that need to sit
/// inside a card row use `AIWorkingRow` instead.
struct IssueCallout: View {
    let icon: String
    var iconTint: AnyShapeStyle = AnyShapeStyle(.secondary)
    var pulsing: Bool = false
    let title: String
    var subtitle: String? = nil
    var showsProgress: Bool = false
    /// Frame's `minHeight`. Defaults to 260 so the callout reads as
    /// a hero surface; tight containers (sheets, narrow inspectors)
    /// can shrink it without re-laying out the children.
    var minHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(iconTint)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .padding(.vertical, 20)
    }
}
