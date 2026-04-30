import SwiftUI

/// Payload threaded through SwiftUI's `openWindow(value:)` so the
/// detailed-statistics window can render without a back-reference
/// to the loaded `WaveformBundle`. Hashable + Codable per
/// SwiftUI's window-restoration requirements.
struct DetailedStatisticsPayload: Hashable, Codable, Identifiable {
    let dayDate: Date
    let deviceName: String?
    let rows: [WaveformBundle.SignalSummaryRow]

    var id: Date { dayDate }
}

/// Trigger-only "Detailed Statistics" button. macOS opens the table
/// in its own window via `openWindow(value:)`; iOS pops a sheet.
/// Renders nothing when the payload has no rows.
struct DailySignalSummaryTable: View {
    let payload: DetailedStatisticsPayload

    @Environment(\.openWindow) private var openWindow
    @State private var isShowingSheet = false

    var body: some View {
        if !payload.rows.isEmpty {
            Button {
                #if os(macOS)
                openWindow(value: payload)
                #else
                isShowingSheet = true
                #endif
            } label: {
                DayActionButtonLabel(
                    title: "Detailed Statistics",
                    subtitle: "Median, 95%, and 99.5% per signal",
                    systemImage: "tablecells",
                    tint: .chartBlue
                )
            }
            .buttonStyle(DayActionButtonStyle())
            #if os(iOS)
            .sheet(isPresented: $isShowingSheet) {
                NavigationStack {
                    // ScrollView keeps the content from sliding
                    // up under the inline nav bar at the medium
                    // detent — without it the table renders as
                    // a fixed-height view and the date / device
                    // rows poke into the title area until the
                    // user drags up to the large detent.
                    ScrollView {
                        DetailedStatisticsView(payload: payload)
                            .padding(20)
                    }
                    .navigationTitle("Detailed Statistics")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            #endif
        }
    }
}

/// Card-style label used by the "Detailed Statistics" and
/// "Advanced Charting" buttons on the day-detail view. Shared so
/// the two entry points to secondary windows / sheets read as one
/// set, with a tinted-icon chip on the leading edge, a two-line
/// title/subtitle stack, and a trailing chevron to hint at the
/// "opens elsewhere" action.
struct DayActionButtonLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.15))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Button chrome for `DayActionButtonLabel` — subtle material
/// background, thin hairline border, and a small scale / opacity
/// dip on press so the card reads as a tappable surface on both
/// platforms without the default bordered-button look.
struct DayActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Per-night signal summary table — Median / 95% / 99.5%
/// percentiles for every PLD signal we tracked. Renders as a
/// Grid so the columns line up across both platforms.
struct DetailedStatisticsView: View {
    let payload: DetailedStatisticsPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.dayDate, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.headline)
                if let deviceName = payload.deviceName, !deviceName.isEmpty {
                    Text(deviceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .gridColumnAlignment(.leading)
                    Text("Median")
                        .gridColumnAlignment(.trailing)
                    Text("95%")
                        .gridColumnAlignment(.trailing)
                    Text("99.5%")
                        .gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(payload.rows) { row in
                    Divider()
                        .gridCellColumns(4)
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                                .font(.body)
                            if !row.unit.isEmpty {
                                Text(row.unit)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(row.displayMedian)
                            .gridColumnAlignment(.trailing)
                        Text(row.displayP95)
                            .gridColumnAlignment(.trailing)
                        Text(row.displayP99_5)
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.body.monospacedDigit())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        #if os(macOS)
        // Populates the macOS title bar so the floating window
        // reads as "Detailed Statistics" instead of inheriting the
        // generic app name. Subtitle carries the night the table
        // covers, so a stack of these windows is distinguishable
        // at a glance from Mission Control.
        .navigationTitle("Detailed Statistics")
        .navigationSubtitle(Text(payload.dayDate, format: .dateTime.weekday(.wide).month(.wide).day()))
        #endif
    }
}
