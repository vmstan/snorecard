import SwiftUI
import SnorecardKit

struct DayListView: View {
    let card: ResMedSDCard
    @Binding var selection: SidebarSelection?
    @Environment(Library.self) private var library

    var body: some View {
        List(selection: $selection) {
            #if os(macOS)
            // App name as the prominent header with the device
            // name as a subheading — mirrors the iOS layout
            // (`navigationTitle("Snorecard")` +
            // `navigationSubtitle(deviceName)`) so both
            // platforms read the same at a glance.
            Section {
                overviewRow(isSelected: selection == .overview)
                    .tag(SidebarSelection.overview)
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snorecard")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(library.displayName(for: card))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
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
        // App name as the large title; device name lives in the
        // navigation subtitle slot (iOS 26+) so the user sees
        // "Snorecard" prominently with the active device as a
        // smaller subheading underneath. UIKit collapses both
        // into the nav bar inset as the list scrolls.
        .navigationTitle("Snorecard")
        .navigationSubtitle(library.displayName(for: card))
        .navigationBarTitleDisplayMode(.large)
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
                    // Plain text — colour now lives on the
                    // calendar / overview glyph instead, which
                    // reads as a glanceable severity indicator
                    // without dragging the number into the
                    // green/amber/red palette.
                    Text(String(format: "%.1f", avg))
                        .font(.body.monospacedDigit())
                    Text("AHI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            disclosureChevron
        }
        .padding(.vertical, 4)
        .compactiOSRowInsets()
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
        let calendarTint: Color = {
            guard let stats = day.stats, stats.hasUsage else { return .secondary }
            return iconSeverityColor(stats.ahi)
        }()
        HStack(alignment: .center, spacing: 10) {
            CalendarDayTile(
                date: day.date,
                isSelected: isSelected,
                tint: calendarTint
            )
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
                    // Colour lives on the calendar glyph to the
                    // left now; the number stays in the row's
                    // default foreground so it reads cleanly.
                    Text(String(format: "%.1f", stats.ahi))
                        .font(.body.monospacedDigit())
                    Text("AHI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            disclosureChevron
        }
        .padding(.vertical, 4)
        .foregroundStyle(hasData ? .primary : .tertiary)
        .compactiOSRowInsets()
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

    /// Higher-contrast variant of the severity palette used only
    /// for the calendar-tile icon. The chart palette is
    /// deliberately muted so stacked bars don't look harsh; an
    /// 18 pt SF Symbol against a sidebar row needs more punch
    /// to register as green / amber / red at a glance, and the
    /// system colours give that contrast for free in both
    /// light and dark mode.
    private func iconSeverityColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<2: .green
        case ..<5: .orange
        default: .red
        }
    }
}

/// Glyph placed next to the Overview label in the sidebar. Bare
/// SF Symbol — same treatment as the day rows' calendar icons,
/// so the column of glyphs reads as one consistent set.
private struct OverviewGlyph: View {
    var isSelected: Bool = false

    private var iconColor: Color {
        // Accent tint when idle so the sidebar icon column has a
        // splash of brand colour. Selected rows on iOS get a
        // full-strength accent fill behind them, so the glyph
        // flips to white for legibility.
        isSelected ? .white : .accentColor
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
    /// Tint applied to the SF Symbol when the row is idle —
    /// callers pass an AHI-severity colour so each calendar
    /// icon doubles as a glanceable severity indicator. Days
    /// with no usage get `.secondary` from the caller, which
    /// keeps unrecorded nights visually quiet.
    var tint: Color = .accentColor

    private var symbolName: String {
        let day = Calendar.current.component(.day, from: date)
        return "\(day).calendar"
    }

    private var iconColor: Color {
        // Selected rows on iOS get a full-strength accent fill
        // behind them, so the glyph flips to white for legibility
        // regardless of severity tint.
        isSelected ? .white : tint
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(iconColor)
            .frame(width: 21, height: 22)
    }
}

private extension View {
    /// Tighten sidebar row insets on iOS so the day list packs
    /// more entries on screen at once. Default `.sidebar` row
    /// insets are generous (~11 pt vertical); this trims them
    /// to ~4 pt so the rows feel denser without losing the tap
    /// target. macOS keeps system defaults — its sidebar
    /// already uses tighter row spacing out of the box.
    @ViewBuilder
    func compactiOSRowInsets() -> some View {
        #if os(iOS)
        self.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        #else
        self
        #endif
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
    /// Explicit close callback supplied by the caller — we avoid
    /// `@Environment(\.dismiss)` because the shared macOS
    /// inspector attaches to the root `NavigationSplitView`, and
    /// `dismiss` in that hierarchy resolves to the window, which
    /// would close the main window (and quit the app) instead of
    /// collapsing the inspector column.
    let onClose: () -> Void

    @State private var name: String

    init(
        serial: String,
        defaultName: String,
        currentOverride: String?,
        onSave: @escaping (String?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.serial = serial
        self.defaultName = defaultName
        self.currentOverride = currentOverride
        self.onSave = onSave
        self.onClose = onClose
        self._name = State(initialValue: currentOverride ?? "")
    }

    var body: some View {
        #if os(iOS)
        // `InspectorPaneHeader` inside `formBody` carries the
        // "Rename Device" title, so we skip `.navigationTitle`
        // on iOS to avoid duplicating it in the top bar.
        NavigationStack {
            formBody
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // iOS keeps the standard sheet pattern: X close
                    // on the leading edge, Save as the trailing
                    // confirmation action.
                    ToolbarItem(placement: .topBarLeading) {
                        CloseSheetButton { onClose() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        // macOS hosts this in the shared inspector column. A
        // NavigationStack wrapper would cause `dismiss()` to
        // target the stack instead of the inspector and crash
        // once the owning state mutates, so we skip it and rely
        // on `.navigationTitle` bubbling up to the column's
        // chrome — matching `DailySettingsInspector`.
        formBody
            .navigationTitle("Rename PAP-device")
        #endif
    }

    @ViewBuilder
    private var formBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorPaneHeader(
                title: "Rename PAP-device",
                caption: currentCaption
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Form {
                Section {
                    nameField
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the sidebar. Syncs between your devices via iCloud.")
                }

                Section {
                    LabeledContent("PAP-device", value: defaultName)
                    LabeledContent("Serial") {
                        Text(serial).monospaced()
                    }
                } header: {
                    Text("PAP-device")
                }

                if currentOverride != nil {
                    Section {
                        Button("Use Default Name", role: .destructive) {
                            onSave(nil)
                            onClose()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            #if os(macOS)
            // macOS pulls Cancel + Save into a bottom action
            // bar matching BackupsView's pattern — keeps both
            // surfaces visually consistent. No divider above
            // the bar; the form's section spacing already
            // separates the buttons from the last row.
            HStack {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            #endif
        }
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
        onClose()
    }

    /// Caption under the "Rename Device" header. Shows the
    /// current override when one exists (so the user sees the
    /// name they're about to edit) and falls back to the ResMed
    /// product name when nothing custom has been set yet.
    private var currentCaption: String {
        if let override = currentOverride,
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return defaultName
    }
}
