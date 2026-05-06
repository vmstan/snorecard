import SwiftUI
import SnorecardKit

/// Retroactively stamp a mask across many existing sessions. Mirrors
/// `MaskEditorView`'s presentation contract:
///
/// - iOS pushes this view onto the outer Settings `NavigationStack`,
///   so the toolbar `Apply` button + back chevron handle the trip.
/// - macOS opens it as a sheet because pushing inside a Settings
///   `TabView` pane leaves no usable back affordance. Footer row
///   carries explicit Cancel + Apply buttons.
///
/// Confirmation runs inline in this view (a single alert that
/// summarises the day / session counts before any sidecar is
/// rewritten). Results stay visible after the apply so the user can
/// see what changed before dismissing manually.
struct BulkApplyMaskView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var maskID: UUID?
    @State private var usesDateRange: Bool = false
    @State private var startDate: Date = Calendar.current
        .date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var confirmation: BulkApplyPlan?
    @State private var result: String?

    private struct BulkApplyPlan: Identifiable {
        let id = UUID()
        let mask: Mask
        let dateRange: ClosedRange<Date>?
        let dayCount: Int
        let sessionCount: Int
    }

    private var canApply: Bool {
        maskID != nil && library.card != nil && !library.userMasks.isEmpty
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apply Mask to Existing Sessions")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form { detailsSection }
                .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { prepareApply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear(perform: syncMaskSelection)
        .alert(item: $confirmation) { plan in
            confirmationAlert(for: plan)
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private var iosBody: some View {
        Form { detailsSection }
            .formStyle(.grouped)
            .navigationTitle("Apply to Existing Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply", action: prepareApply)
                        .disabled(!canApply)
                }
            }
            .onAppear(perform: syncMaskSelection)
            .alert(item: $confirmation) { plan in
                confirmationAlert(for: plan)
            }
    }
    #endif

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            Picker(
                "Mask",
                selection: Binding<UUID?>(
                    get: { maskID },
                    set: { maskID = $0 }
                )
            ) {
                ForEach(library.userMasks) { mask in
                    Text(mask.displayLabel).tag(Optional(mask.id))
                }
            }
            Toggle("Limit to Date Range", isOn: $usesDateRange)
            if usesDateRange {
                DatePicker(
                    "From",
                    selection: $startDate,
                    displayedComponents: .date
                )
                DatePicker(
                    "To",
                    selection: $endDate,
                    in: startDate...,
                    displayedComponents: .date
                )
            }
            if let result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Overwrites any existing per-session mask in the chosen scope, including sessions you've manually labelled.")
        }
    }

    private func confirmationAlert(for plan: BulkApplyPlan) -> Alert {
        Alert(
            title: Text("Apply mask to existing sessions?"),
            message: Text(message(for: plan)),
            primaryButton: .default(Text("Apply"), action: {
                runApply(plan: plan)
            }),
            secondaryButton: .cancel()
        )
    }

    private func message(for plan: BulkApplyPlan) -> String {
        let scope: String
        if let range = plan.dateRange {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            scope = "from \(formatter.string(from: range.lowerBound)) to \(formatter.string(from: range.upperBound))"
        } else {
            scope = "across this device's history"
        }
        return "Apply \"\(plan.mask.displayLabel)\" to \(plan.sessionCount) session(s) on \(plan.dayCount) day(s) \(scope)? Existing per-session mask labels will be overwritten."
    }

    private func syncMaskSelection() {
        if let current = maskID,
           library.userMasks.contains(where: { $0.id == current }) {
            return
        }
        maskID = library.defaultMaskID ?? library.userMasks.first?.id
    }

    private func prepareApply() {
        result = nil
        guard let id = maskID,
              let mask = library.mask(id: id),
              let card = library.card else { return }
        let range: ClosedRange<Date>?
        let cal = Calendar.current
        if usesDateRange {
            let lower = cal.startOfDay(for: startDate)
            let upper = cal.startOfDay(for: endDate)
            guard lower <= upper else { return }
            range = lower...upper
        } else {
            range = nil
        }
        let candidateDays = card.days.filter { day in
            guard let range else { return true }
            return range.contains(day.date)
        }
        let sessions = candidateDays.reduce(0) { acc, day in
            acc + Set(day.files.compactMap(\.sessionKey)).count
        }
        confirmation = BulkApplyPlan(
            mask: mask,
            dateRange: range,
            dayCount: candidateDays.count,
            sessionCount: sessions
        )
    }

    private func runApply(plan: BulkApplyPlan) {
        let updated = library.applyMaskToSessions(
            plan.mask.id,
            in: plan.dateRange
        )
        result = updated == 0
            ? "No sessions needed updating."
            : "Updated \(updated) session(s)."
    }
}
