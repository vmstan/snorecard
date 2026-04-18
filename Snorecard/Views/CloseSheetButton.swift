import SwiftUI

/// Standardised X-shaped sheet-dismiss control. Apple's modern
/// iOS sheets use a filled `xmark.circle.fill` with hierarchical
/// rendering for the dismiss affordance — Mail, Notes, Reminders,
/// Music all paint it the same way. Centralised here so every
/// sheet in Snorecard reaches for the same glyph instead of
/// hand-rolling a slightly different one each time.
struct CloseSheetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
