import SwiftUI
import SnorecardKit

struct DayListView: View {
    let card: ResMedSDCard
    @Binding var selection: SidebarSelection?
    @Environment(Library.self) private var library

    var body: some View {
        List(selection: $selection) {
            #if os(macOS)
            // macOS sidebar keeps the app-level "Snorecard" title in
            // the window chrome, so surface the device name as the
            // first section header.
            Section {
                overviewRow(isSelected: selection == .overview)
                    .tag(SidebarSelection.overview)
            } header: {
                Text(library.displayName(for: card))
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 10)
                    .textCase(nil)
            }
            #else
            // iOS uses the navigation title for the device name (see
            // the .navigationTitle override below) so there's no
            // secondary header — the Overview row sits directly
            // under the nav bar like a normal list.
            overviewRow(isSelected: selection == .overview)
                .tag(SidebarSelection.overview)
            #endif

            ForEach(daysByMonth, id: \.month) { group in
                Section {
                    ForEach(group.days) { day in
                        row(for: day, isSelected: selection == .day(day.id))
                            .tag(SidebarSelection.day(day.id))
                    }
                } header: {
                    Text(group.month, format: .dateTime.month(.wide).year())
                        .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        #if os(iOS)
        .navigationTitle(library.displayName(for: card))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            // Pull-to-refresh mirrors the Refresh menu item. The
            // async variant holds the spinner open until prefetch +
            // scan + backfill have all settled, which now completes
            // in well under a second on warm caches — previously
            // this gesture felt pointless because the work was
            // invisible and took minutes on cold loads.
            await library.reloadCurrentAndWait()
        }
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let progress = hydrationProgress {
                hydrationFooter(done: progress.done, total: progress.total)
            }
        }
    }

    /// Small footer chip shown while the backfill pass is still
    /// running. Disappears the moment `library.state` transitions
    /// from `.hydrating` to `.loaded`.
    @ViewBuilder
    private func hydrationFooter(done: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Updating · \(done) of \(total) days")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    /// `(completed, total)` backfill progress, or `nil` when not
    /// hydrating / nothing needs aggregating. Mirrors the
    /// `SDCardImporter.needsBackfill` check so the count lines up
    /// with what the importer is actually doing.
    private var hydrationProgress: (done: Int, total: Int)? {
        guard library.isHydrating else { return nil }
        let candidates = card.days.filter { !$0.files.isEmpty }
        let total = candidates.count
        guard total > 0 else { return nil }
        let done = candidates.filter(Self.hasAggregatedStats).count
        // Don't flash a "0 of 0" chip — and if the count is already
        // at the total we're a frame or two away from `.loaded`.
        guard done < total else { return nil }
        return (done, total)
    }

    /// Day rows with any PLD/EVE-derived field filled in have been
    /// through the full aggregate pass already.
    private static func hasAggregatedStats(_ day: ResMedDay) -> Bool {
        guard let s = day.stats else { return false }
        return s.flowLimit95 != nil
            || s.glasgowIndex != nil
            || s.timeInApneaSeconds != nil
            || s.largeLeakSeconds != nil
    }

    /// Sidebar row for the "Overview" entry. Mirrors the day-row layout
    /// (same-size glyph + label + right-aligned AHI) so the first entry
    /// in the sidebar lines up visually with everything below.
    @ViewBuilder
    private func overviewRow(isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            OverviewGlyph(isSelected: isSelected)
            Text("Overview")
                .font(.body)
            Spacer()
            if let avg = overallAHI {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.2f", avg))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white : ahiColor(avg))
                    Text("AHI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            disclosureChevron
        }
        .padding(.vertical, 4)
    }

    /// Average AHI across every day that has recorded usage. `nil` when
    /// there aren't any yet.
    private var overallAHI: Double? {
        let values = card.days
            .compactMap(\.stats)
            .filter(\.hasUsage)
            .map(\.ahi)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    @ViewBuilder
    private func row(for day: ResMedDay, isSelected: Bool) -> some View {
        let hasData = !day.files.isEmpty || day.stats?.hasUsage == true
        HStack(alignment: .center, spacing: 10) {
            CalendarDayTile(date: day.date, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 1) {
                Text(day.date, format: .dateTime.weekday(.wide))
                    .font(.body)
                if let stats = day.stats, stats.hasUsage {
                    Text(formatUsage(stats.usageHours))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let stats = day.stats, stats.hasUsage {
                VStack(alignment: .trailing, spacing: 1) {
                    // When the row is selected the accent-tinted background
                    // makes the severity colours unreadable, so fall back to
                    // the selected-row foreground (white) in that case.
                    Text(String(format: "%.2f", stats.ahi))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white : ahiColor(stats.ahi))
                    Text("AHI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            disclosureChevron
        }
        .padding(.vertical, 4)
        .foregroundStyle(hasData ? .primary : .tertiary)
    }

    /// Trailing tap-affordance shown on iOS only — pairs with the
    /// system selection treatment to make each row read as a
    /// navigable entry. macOS uses the sidebar's hover/select
    /// styling and doesn't need it.
    @ViewBuilder
    private var disclosureChevron: some View {
        #if os(iOS)
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        #else
        EmptyView()
        #endif
    }

    /// Groups card days by calendar month+year, sorted newest-first, with
    /// each month's days sorted newest-first inside.
    private var daysByMonth: [(month: Date, days: [ResMedDay])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: card.days) { day -> Date in
            calendar.date(from: calendar.dateComponents([.year, .month], from: day.date))
                ?? day.date
        }
        return groups
            .sorted { $0.key > $1.key }
            .map { key, days in
                (month: key, days: days.sorted { $0.date > $1.date })
            }
    }

    private func formatUsage(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(m)m"
    }

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<2: .severityGood
        case ..<5: .severityLow
        default: .severityHigh
        }
    }
}

/// Glyph placed next to the Overview label in the sidebar. Bare
/// SF Symbol — same treatment as the day rows' calendar icons,
/// so the column of glyphs reads as one consistent set.
private struct OverviewGlyph: View {
    var isSelected: Bool = false

    private var iconColor: Color {
        isSelected ? .white : .primary
    }

    var body: some View {
        Image(systemName: "chart.bar.xaxis")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(iconColor)
            .frame(width: 21, height: 22)
    }
}

/// Tiny calendar glyph — uses the SF Symbols `<day>.calendar`
/// family (added in SF Symbols 6) so the day number is baked
/// into the icon instead of composited via Text + a custom
/// rounded-rectangle. Sidebar rows show the day-of-month
/// inline with the weekday so the eye lands on the date first.
private struct CalendarDayTile: View {
    let date: Date
    var isSelected: Bool = false

    private var symbolName: String {
        let day = Calendar.current.component(.day, from: date)
        return "\(day).calendar"
    }

    private var iconColor: Color {
        isSelected ? .white : .primary
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(iconColor)
            .frame(width: 21, height: 22)
    }
}

/// Sheet presented when the user wants to set or clear a custom name for
/// the currently-loaded CPAP device. Saves via the shared Library so the
/// value syncs to iCloud.
struct RenameDeviceSheet: View {
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
        NavigationStack {
            Form {
                Section {
                    nameField
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the sidebar. Syncs between your devices via iCloud.")
                }

                Section {
                    LabeledContent("Device", value: defaultName)
                    LabeledContent("Serial") {
                        Text(serial).monospaced()
                    }
                } header: {
                    Text("Device")
                }

                if currentOverride != nil {
                    Section {
                        Button("Use Default Name", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Rename Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private var nameField: some View {
        let field = TextField("Custom name", text: $name)
            .autocorrectionDisabled()
            .onSubmit(save)
        #if os(iOS)
        field
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
        #else
        field
        #endif
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
        dismiss()
    }
}
