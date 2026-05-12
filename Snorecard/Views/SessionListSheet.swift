import SwiftUI
import SnorecardKit

/// List of every CPAP session recorded for a day, with a per-row
/// Include / Exclude switch. Toggling a row routes through
/// `Library.toggleSessionExclusion(_:forDate:)` which re-aggregates
/// the day on the spot, so the headline stat cards reflect the new
/// totals before the sheet even closes.
///
/// Sessions whose recorded duration is below the auto-exclude
/// threshold (currently 2 min, mirrored from
/// `DailyStatistics.aggregate`) render with a "Under 2 min" trailing
/// chip and no switch — the auto-rule already drops them and a
/// manual flip wouldn't move the totals.
///
/// Layout follows `DailySettingsInspector`: a padded
/// `InspectorPaneHeader` at the top with the night's date, then a
/// grouped Form below that runs edge-to-edge so the inspector pane
/// reads identically to Therapy Details and Sleep Journal.
struct SessionListSheet: View {
    @Environment(Library.self) private var library
    let day: ResMedDay

    @State private var rows: [Row] = []
    @State private var loadState: LoadState = .loading

    private static let briefThresholdSeconds: Double = 120

    private enum LoadState {
        case loading
        case ready
        case empty
    }

    private struct Row: Identifiable {
        let id: String        // sessionKey
        let start: Date
        let end: Date
        let duration: TimeInterval
    }

    var body: some View {
        #if os(iOS)
        // Fresh NavigationStack so this sheet's own toolbar / dismiss
        // don't bleed up into the day-detail header. The
        // `InspectorPaneHeader` at the top of `content` already
        // shows the pane label and date, so we skip
        // `.navigationTitle` on iOS. Matches `DailySettingsInspector`
        // exactly so all the day-level inspectors line up.
        NavigationStack {
            content
                .padding(.top, 12)
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        content
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorPaneHeader(
                title: "Therapy Sessions",
                caption: day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)

            switch loadState {
            case .loading:
                // Same `IssueCallout` chrome the day-detail loading
                // placeholder uses, so the two reading states read
                // as one set. `minHeight: 200` keeps it from
                // dwarfing the inspector header on macOS where the
                // pane is narrower than the day view.
                IssueCallout(
                    icon: "clock",
                    iconTint: AnyShapeStyle(.tint),
                    pulsing: true,
                    title: "Reading sessions…",
                    showsProgress: true,
                    minHeight: 200
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "moon.zzz",
                    description: Text("This day has no recorded CPAP sessions.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                form
            }
        }
        .task(id: day.id) {
            await loadRows()
        }
    }

    @ViewBuilder
    private var form: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    sessionRow(row)
                }
            } footer: {
                Text(footerText)
            }
        }
        .formStyle(.grouped)
    }

    private var footerText: String {
        let base = "Brief sessions under 2 minutes are excluded automatically — they're almost always mask tests or fittings rather than therapy. Flip a session off to drop it from this day's AHI, usage, and pressure totals."
        if library.userMasks.isEmpty {
            return base + " Add masks in Settings → Mask to label which mask you wore for each session."
        }
        return base
    }

    @ViewBuilder
    private func sessionRow(_ row: Row) -> some View {
        let state = state(for: row)
        let isIncluded = state == .included
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeRange(for: row))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(isIncluded ? .primary : .secondary)
                    .lineLimit(1)
                Text(durationLabel(row.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if shouldShowMaskMenu(for: state) {
                    maskMenu(for: row)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            trailing(for: row, state: state)
        }
        .padding(.vertical, 2)
    }

    private func shouldShowMaskMenu(for state: RowState) -> Bool {
        guard !library.userMasks.isEmpty else { return false }
        return state != .autoExcluded
    }

    @ViewBuilder
    private func trailing(for row: Row, state: RowState) -> some View {
        switch state {
        case .autoExcluded:
            // Compact icon-only chip — the title would force the
            // duration label above to wrap on narrow rows. The
            // tooltip / VoiceOver label still carries the explanatory
            // text so the meaning isn't lost.
            Image(systemName: "clock.badge.exclamationmark")
                .font(.body)
                .foregroundStyle(.secondary)
                .help("Auto-excluded — under 2 min")
                .accessibilityLabel("Auto-excluded — under 2 min")
        case .included, .manuallyExcluded:
            Toggle(
                "Include this session",
                isOn: Binding(
                    get: { !library.isSessionExcluded(row.id) },
                    set: { _ in
                        library.toggleSessionExclusion(row.id, forDate: day.date)
                    }
                )
            )
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func maskMenu(for row: Row) -> some View {
        let resolved = library.mask(forSessionKey: row.id, on: day)
        Menu {
            ForEach(library.userMasks) { mask in
                Button {
                    library.setMask(mask.id, forSessionKey: row.id, on: day)
                } label: {
                    if mask.id == resolved?.id {
                        Label(mask.displayLabel, systemImage: "checkmark")
                    } else {
                        Text(mask.displayLabel)
                    }
                }
            }
            if resolved != nil {
                Divider()
                Button(role: .destructive) {
                    library.setMask(nil, forSessionKey: row.id, on: day)
                } label: {
                    Label("Clear Mask", systemImage: "xmark.circle")
                }
            }
        } label: {
            Text(resolved?.displayLabel ?? "Set Mask")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(resolved == nil ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(
            resolved.map { "Mask: \($0.displayLabel)" } ?? "No mask assigned"
        )
    }

    private enum RowState { case included, manuallyExcluded, autoExcluded }

    private func state(for row: Row) -> RowState {
        if row.duration < Self.briefThresholdSeconds { return .autoExcluded }
        if library.isSessionExcluded(row.id) { return .manuallyExcluded }
        return .included
    }

    private func timeRange(for row: Row) -> String {
        let start = row.start.formatted(date: .omitted, time: .shortened)
        let end = row.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            let h = total / 3600
            let m = (total % 3600) / 60
            return "\(h)h \(m)m"
        }
        if total >= 60 {
            let m = total / 60
            let s = total % 60
            return s == 0 ? "\(m) min" : "\(m)m \(s)s"
        }
        return "\(total) sec"
    }

    /// Decode each BRP header off the main thread to surface its
    /// recorded duration. Headers are tiny (a few hundred bytes each)
    /// so even a 10-session night reads in well under a second.
    private func loadRows() async {
        loadState = .loading
        let brpFiles = day.files(of: .breath)
        guard !brpFiles.isEmpty else {
            rows = []
            loadState = .empty
            return
        }
        let decoded: [Row] = await Task.detached(priority: .userInitiated) {
            var out: [Row] = []
            for file in brpFiles {
                guard let key = file.sessionKey,
                      let edf = try? EDFFile(contentsOf: file.url),
                      edf.header.recordCount > 0 else { continue }
                let duration = Double(edf.header.recordCount) * edf.header.recordDuration
                let start = file.timestamp ?? edf.header.startDate
                let end = start.addingTimeInterval(duration)
                out.append(
                    Row(
                        id: key,
                        start: start,
                        end: end,
                        duration: duration
                    )
                )
            }
            out.sort { $0.start < $1.start }
            return out
        }.value
        rows = decoded
        loadState = decoded.isEmpty ? .empty : .ready
    }
}
