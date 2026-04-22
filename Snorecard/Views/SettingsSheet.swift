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
                NavigationLink {
                    AboutView()
                        .navigationTitle("About")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("About", systemImage: "info.circle")
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
                LabeledContent("Alias") {
                    TextField(
                        "",
                        text: $deviceNameDraft,
                        prompt: Text(currentDefaultName)
                    )
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    #endif
                    .onSubmit(commitDeviceName)
                }
                LabeledContent("Model", value: currentDefaultName)
                LabeledContent("Serial") {
                    Text(serial).monospaced()
                }
                if currentOverride != nil {
                    Button("Use Default Name", role: .destructive) {
                        deviceNameDraft = ""
                        library.setDeviceName(nil, for: serial)
                    }
                }
            } header: {
                Text("Details")
            } footer: {
                Text("Shown in the sidebar. Syncs between your devices via iCloud.")
            }
        }
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
                Stepper(value: binding, in: 1...12, step: 0.5) {
                    LabeledContent(
                        "Compliance Target",
                        value: complianceTargetLabel(current)
                    )
                }
                if current != Library.defaultComplianceHours {
                    Button("Reset to 4 Hours", role: .destructive) {
                        library.setComplianceTarget(
                            Library.defaultComplianceHours,
                            for: serial
                        )
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

    /// Cadence picker for the in-app auto-reload. Mirrors the
    /// existing Apple Intelligence toggle pattern (Binding wrapping
    /// a Library property) so both controls read from one source of
    /// truth without `@AppStorage` in the view.
    @ViewBuilder
    private var backgroundReloadSection: some View {
        Section {
            Picker(
                "Background Refresh",
                selection: Binding(
                    get: { library.backgroundReloadIntervalMinutes },
                    set: { library.backgroundReloadIntervalMinutes = $0 }
                )
            ) {
                ForEach(Library.backgroundReloadIntervalChoices, id: \.self) { minutes in
                    Text(backgroundReloadLabel(minutes)).tag(minutes)
                }
            }
        } header: {
            Text("Background Refresh")
        } footer: {
            Text("Automatically populates the Snorecard interface with new sleep data via iCloud while Snorecard is open, so new nights imported on another device show up without you hitting Reload.")
        }
    }

    private func backgroundReloadLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Off"
        case 60: return "Every hour"
        default: return "Every \(minutes) min"
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section {
            Button("Rebuild Cache", role: .destructive) {
                NotificationCenter.default.post(
                    name: .snorecardRebuildCache,
                    object: nil
                )
                onClose()
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
            backgroundReloadSection
            maintenanceSection
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
