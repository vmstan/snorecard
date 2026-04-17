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
                Label("Detailed Statistics", systemImage: "tablecells")
            }
            .buttonStyle(.bordered)
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
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            #endif
        }
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
    }
}
