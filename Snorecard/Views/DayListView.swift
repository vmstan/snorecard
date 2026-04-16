import SwiftUI
import SnorecardKit

struct DayListView: View {
    let card: ResMedSDCard
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "chart.bar.xaxis")
                    .tag(SidebarSelection.overview)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.identification?.productName ?? "ResMed Device")
                        .font(.headline)
                    if let serial = card.identification?.serialNumber {
                        Text("Serial \(serial)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 10)
                .textCase(nil)
            }

            Section("Days") {
                ForEach(card.days.reversed()) { day in
                    row(for: day, isSelected: selection == .day(day.id))
                        .tag(SidebarSelection.day(day.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(for day: ResMedDay, isSelected: Bool) -> some View {
        let hasData = !day.files.isEmpty || day.stats?.hasUsage == true
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(day.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.body)
                if let stats = day.stats, stats.hasUsage {
                    Text(formatUsage(stats.usageHours))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(day.date, format: .dateTime.year())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let stats = day.stats, stats.hasUsage {
                VStack(alignment: .trailing, spacing: 1) {
                    // When the row is selected the accent-tinted background
                    // makes the severity colours unreadable, so fall back to
                    // the selected-row foreground (white) in that case.
                    Text(String(format: "%.1f", stats.ahi))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white : ahiColor(stats.ahi))
                    Text("AHI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(hasData ? .primary : .tertiary)
    }

    private func formatUsage(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(m)m"
    }

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<5: .green
        case ..<15: .yellow
        case ..<30: .orange
        default: .red
        }
    }
}
