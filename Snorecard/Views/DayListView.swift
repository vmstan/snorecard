import SwiftUI
import SnorecardKit

struct DayListView: View {
    let card: ResMedSDCard
    @Binding var selection: SidebarSelection?
    @Environment(Library.self) private var library
    @State private var isRenaming = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "chart.bar.xaxis")
                    .tag(SidebarSelection.overview)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(library.displayName(for: card))
                            .font(.headline)
                        if card.identification?.serialNumber != nil {
                            Button {
                                isRenaming = true
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.callout)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            .help("Rename device")
                        }
                    }
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
        .sheet(isPresented: $isRenaming) {
            if let serial = card.identification?.serialNumber {
                RenameDeviceSheet(
                    serial: serial,
                    defaultName: card.identification?.productName ?? "ResMed Device",
                    currentOverride: library.deviceNameOverrides[serial],
                    onSave: { newName in
                        library.setDeviceName(newName, for: serial)
                    }
                )
            }
        }
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
        case ..<5: .severityGood
        case ..<15: .severityLow
        case ..<30: .severityMedium
        default: .severityHigh
        }
    }
}

/// Sheet presented when the user wants to set or clear a custom name for
/// the currently-loaded CPAP device. Saves via the shared Library so the
/// value syncs to iCloud.
private struct RenameDeviceSheet: View {
    let serial: String
    let defaultName: String
    let currentOverride: String?
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(
        serial: String,
        defaultName: String,
        currentOverride: String?,
        onSave: @escaping (String?) -> Void
    ) {
        self.serial = serial
        self.defaultName = defaultName
        self.currentOverride = currentOverride
        self.onSave = onSave
        self._name = State(initialValue: currentOverride ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Device")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Serial \(serial)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Default: \(defaultName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Custom name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Button("Use Default", role: .destructive) {
                    onSave(nil)
                    dismiss()
                }
                .disabled(currentOverride == nil)

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
        dismiss()
    }
}
