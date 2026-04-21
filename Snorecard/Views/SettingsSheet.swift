import SwiftUI

/// Top-level Settings sheet / inspector pane. Currently hosts just
/// the App Icon picker, but structured as a sectioned list so more
/// preference groups can slot in without reshaping the surface.
struct SettingsSheet: View {
    let onClose: () -> Void

    @Environment(Library.self) private var library
    @State private var selection: AppIconOption = AppIconController.current
    /// Draft of the PAP-device alias. Synced from Library on
    /// appear / card change and committed back via `commitDeviceName`
    /// on submit and on dismiss, so the user's edits are trimmed
    /// and persisted without hammering the iCloud store on every
    /// keystroke.
    @State private var deviceNameDraft: String = ""
    /// Serial the draft belongs to — used to re-sync when the
    /// user swaps devices while Settings is open.
    @State private var draftSerial: String?

    private var hasCard: Bool {
        library.card?.identification?.serialNumber != nil
    }

    private var currentSerial: String? {
        library.card?.identification?.serialNumber
    }

    private var currentDefaultName: String {
        library.card?.identification?.productName ?? "ResMed PAP-device"
    }

    private var currentOverride: String? {
        guard let serial = currentSerial else { return nil }
        let value = library.deviceNameOverrides[serial]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Fixed row-content height for every trailing value on the
    /// Device tab — TextField, plain Text, monospaced Text, and
    /// the Compliance Stepper. A hard-coded height is the
    /// simplest way to get a TextField (which has its own
    /// intrinsic height on macOS) and a plain Text to share the
    /// same vertical center so the labels in the leading column
    /// line up row-to-row.
    private var detailRowHeight: CGFloat { 22 }

    var body: some View {
        #if os(iOS)
        // iOS mirrors the macOS TabView split — four top-level
        // NavigationLinks on the Settings root (Device, Backups,
        // Appearance, Advanced) so each concern gets its own
        // pushed screen instead of one long scroll. Matches the
        // iOS system Settings app idiom.
        NavigationStack {
            List {
                NavigationLink {
                    deviceTab
                        .navigationTitle("Device")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Device", systemImage: "externaldrive")
                }
                NavigationLink {
                    backupsTab
                        .navigationTitle("Backups")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Backups", systemImage: "icloud")
                }
                NavigationLink {
                    appearanceTab
                        .navigationTitle("Appearance")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
                NavigationLink {
                    advancedTab
                        .navigationTitle("Advanced")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: syncDeviceDraft)
        .onChange(of: currentSerial) { _, _ in syncDeviceDraft() }
        .onDisappear(perform: commitDeviceName)
        #else
        // macOS Settings is a tabbed window following the standard
        // System Settings / Mac-app Preferences idiom — one focused
        // pane per concern so the window chrome + tab bar carry
        // context instead of the content repeating it.
        TabView {
            deviceTab
                .tabItem { Label("Device", systemImage: "externaldrive") }
            backupsTab
                .tabItem { Label("Backups", systemImage: "icloud") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .scenePadding()
        .onAppear(perform: syncDeviceDraft)
        .onChange(of: currentSerial) { _, _ in syncDeviceDraft() }
        .onDisappear(perform: commitDeviceName)
        #endif
    }

    @ViewBuilder
    private var deviceSection: some View {
        if hasCard, let serial = currentSerial {
            Section {
                detailRow("Alias") {
                    // Borderless TextField with an explicit `.secondary`
                    // prompt (lighter weight) so the default-device-name
                    // hint reads as a subdued placeholder and vanishes
                    // on first keystroke — matching the iOS Settings
                    // look on both platforms.
                    TextField(
                        "",
                        text: $deviceNameDraft,
                        prompt: Text(currentDefaultName)
                            .foregroundStyle(.secondary)
                            .fontWeight(.light)
                    )
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    #endif
                    .onSubmit(commitDeviceName)
                }
                detailRow("Model") {
                    Text(currentDefaultName)
                }
                detailRow("Serial") {
                    Text(serial).monospaced()
                }
                if currentOverride != nil {
                    Button(role: .destructive) {
                        deviceNameDraft = ""
                        library.setDeviceName(nil, for: serial)
                    } label: {
                        #if os(iOS)
                        Text("Use Default Name")
                            .frame(maxWidth: .infinity, alignment: .center)
                        #else
                        Text("Use Default Name")
                        #endif
                    }
                }
            } header: {
                Text("Details")
            } footer: {
                Text("Shown in the sidebar. Syncs between your devices via iCloud.")
            }
        }
    }

    /// Label-on-left + content-on-right row with both sides
    /// vertically centered in a fixed-height frame. Written as an
    /// explicit HStack (rather than `LabeledContent`) because
    /// `LabeledContent` baselines a TextField's text differently
    /// from a plain `Text`, which visibly shifted the "Alias"
    /// leading label off the Model / Serial row baselines.
    @ViewBuilder
    private func detailRow<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: detailRowHeight)
    }

    /// Per-device compliance-hours target. A Stepper keeps the UI
    /// small on both platforms; the range (1–12 in 0.5-hour steps)
    /// is wide enough to cover the insurer-standard 4h, typical
    /// 6–8h user goals, and unusually long-usage outliers without
    /// offering meaningless values (< 1h is noise, > 12h is the
    /// mask-on-while-awake bucket).
    @ViewBuilder
    private var complianceSection: some View {
        if let serial = currentSerial {
            let current = library.complianceTarget(for: serial)
            let binding = Binding<Double>(
                get: { library.complianceTarget(for: serial) },
                set: { library.setComplianceTarget($0, for: serial) }
            )
            Section {
                LabeledContent("Compliance Target") {
                    #if os(macOS)
                    // On macOS, the stepper's own label renders next to
                    // the arrows (and we want to hide it so it doesn't
                    // duplicate the LabeledContent leading label), so
                    // the value has to live in a sibling Text.
                    HStack(spacing: 8) {
                        Text(complianceTargetLabel(current))
                            .monospacedDigit()
                        Stepper("", value: binding, in: 1...12, step: 0.5)
                            .labelsHidden()
                    }
                    .frame(height: detailRowHeight)
                    #else
                    Stepper(
                        value: binding,
                        in: 1...12,
                        step: 0.5
                    ) {
                        Text(complianceTargetLabel(current))
                            .monospacedDigit()
                    }
                    #endif
                }
                if current != Library.defaultComplianceHours {
                    Button(role: .destructive) {
                        library.setComplianceTarget(
                            Library.defaultComplianceHours,
                            for: serial
                        )
                    } label: {
                        #if os(iOS)
                        Text("Reset to 4 Hours")
                            .frame(maxWidth: .infinity, alignment: .center)
                        #else
                        Text("Reset to 4 Hours")
                        #endif
                    }
                }
            } header: {
                Text("Compliance")
            } footer: {
                Text("Hours of usage per night that count a night as compliant. Insurers and sleep clinics typically use 4 hours. Applies only to this device and syncs across your devices via iCloud.")
            }
        }
    }

    private func complianceTargetLabel(_ hours: Double) -> String {
        if hours.rounded() == hours {
            return "\(Int(hours)) hr"
        }
        return String(format: "%.1f hr", hours)
    }

    @ViewBuilder
    private var backupsSection: some View {
        if hasCard {
            // Both platforms inline the backups UI directly in the
            // Settings surface — no NavigationLink push on iOS, no
            // inspector swap on macOS. The user sees every
            // preference surface in one scroll and the iCloud
            // plumbing lives next to Rename / App Icon instead of
            // being hidden behind a disclosure chevron.
            BackupsFormSections(onRestoreComplete: {})
        }
    }

    private func syncDeviceDraft() {
        let serial = currentSerial
        if serial != draftSerial {
            draftSerial = serial
            deviceNameDraft = currentOverride ?? ""
        }
    }

    private func commitDeviceName() {
        guard let serial = currentSerial else { return }
        let trimmed = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = library.deviceNameOverrides[serial]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed != stored else { return }
        library.setDeviceName(trimmed.isEmpty ? nil : trimmed, for: serial)
        deviceNameDraft = trimmed
    }

    @ViewBuilder
    private var appIconSection: some View {
        Section("App Icon") {
            ForEach(AppIconOption.allCases) { option in
                row(for: option)
            }
        }
    }

    /// User-facing master switch for on-device Apple Intelligence
    /// features (Sleep Analysis, Explain This Metric, correlation
    /// hints). Disabled on devices that can't run the models in the
    /// first place, since the toggle would be inert there.
    @ViewBuilder
    private var appleIntelligenceSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { library.intelligence.isEnabled },
                set: { library.intelligence.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence")
                    if !library.intelligence.isSupported {
                        Text("Not available on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!library.intelligence.isSupported)
        } header: {
            Text("Sleep Analysis")
        } footer: {
            Text("Turn on to see on-device Sleep Analysis, contextual metric explanations, and correlation hints from your Sleep Journal. Everything runs on your device — nothing is sent to a server.")
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section {
            Button(role: .destructive) {
                NotificationCenter.default.post(
                    name: .snorecardRebuildCache,
                    object: nil
                )
                onClose()
            } label: {
                Text("Rebuild Cache")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(!hasCard)
        } footer: {
            Text("Rebuilds the cached analysis for this PAP device from the original source data. Useful if the analysis appears stale or incorrect.")
        }
    }

    /// Device tab — PAP-device alias + model + serial plus the
    /// per-device compliance-hours target. Falls back to an
    /// empty-state message when no card is loaded so the tab
    /// isn't a blank pane. Shared by the macOS TabView and the
    /// iOS NavigationLink destination.
    @ViewBuilder
    private var deviceTab: some View {
        Form {
            if hasCard {
                deviceSection
                complianceSection
            } else {
                settingsEmptyState(
                    icon: "externaldrive",
                    title: "No PAP Device Loaded",
                    message: "Import a ResMed SD card to see device details here."
                )
            }
        }
        .formStyle(.grouped)
    }

    /// Backups tab — iCloud backup + restore controls. Gated on a
    /// loaded card since backups are per-device.
    @ViewBuilder
    private var backupsTab: some View {
        Form {
            if hasCard {
                BackupsFormSections(onRestoreComplete: {})
            } else {
                settingsEmptyState(
                    icon: "icloud",
                    title: "No PAP Device Loaded",
                    message: "Import a ResMed SD card to back it up to iCloud Drive."
                )
            }
        }
        .formStyle(.grouped)
    }

    /// Appearance tab — app-icon picker. Available regardless of
    /// whether a card is loaded since it's a purely presentational
    /// preference.
    @ViewBuilder
    private var appearanceTab: some View {
        Form {
            appIconSection
        }
        .formStyle(.grouped)
    }

    /// Advanced tab — Apple Intelligence master switch at the top,
    /// followed by destructive maintenance (rebuild cache).
    /// Separated from the rest so the user has to deliberately
    /// navigate here before a one-click rebuild is even in reach.
    /// The two platforms render the maintenance row differently
    /// (full-width red button on iOS, two-column title + hammer
    /// icon on macOS) so the section body is picked per-platform.
    @ViewBuilder
    private var advancedTab: some View {
        Form {
            appleIntelligenceSection
            #if os(macOS)
            macOSMaintenanceSection
            #else
            maintenanceSection
            #endif
        }
        .formStyle(.grouped)
    }

    /// Centered icon + title + caption used by tabs that have no
    /// content to show when no card is loaded. Matches the voice of
    /// the sidebar empty state without pulling in that view's
    /// layout machinery.
    @ViewBuilder
    private func settingsEmptyState(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    #if os(macOS)
    /// Two-column Maintenance row on macOS — description + caption
    /// on the leading edge, destructive action on the trailing
    /// edge. Kept inside the `Form` (instead of a sibling below it)
    /// because grouped `Form` + sibling in the same `VStack`
    /// triggers a layout loop in AppKit ("more Update Constraints
    /// in Window passes than there are views"), which hangs then
    /// crashes the app.
    @ViewBuilder
    private var macOSMaintenanceSection: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rebuild Cache")
                        .font(.callout.weight(.medium))
                    Text("Regenerate cached analysis for this PAP-device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button(role: .destructive) {
                    onClose()
                    NotificationCenter.default.post(
                        name: .snorecardRebuildCache,
                        object: nil
                    )
                } label: {
                    Image(systemName: "hammer")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(!hasCard)
                .help("Rebuild cache")
            }
            .padding(.vertical, 4)
        }
    }
    #endif

    @ViewBuilder
    private func row(for option: AppIconOption) -> some View {
        let isSelected = option == selection
        Button {
            selection = option
            AppIconController.apply(option)
        } label: {
            HStack(spacing: 14) {
                preview(for: option)
                    .frame(width: 24, height: 24)
                Text(option.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func preview(for option: AppIconOption) -> some View {
        // Pre-rendered PNG from the asset catalog. Plain imageset
        // (not a `.icon` package), so SwiftUI's `.resizable()`
        // works cleanly on both platforms.
        Image(option.previewAssetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}
