import SwiftUI
import SnorecardKit

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
    #if os(iOS)
    /// Current sheet detent for the iOS settings presentation.
    /// Seeded to `.large` so Settings opens at full height — users
    /// can still drag down to `.medium` or dismiss entirely.
    @State private var presentationDetent: PresentationDetent = .large
    #endif

    private var hasCard: Bool {
        library.card?.identification?.serialNumber != nil
    }

    private var currentSerial: String? {
        library.card?.identification?.serialNumber
    }

    private var currentDefaultName: String {
        if let product = library.card?.identification?.productName,
           !product.isEmpty {
            return product
        }
        return "ResMed \(library.deviceType(for: library.card).displayName)"
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
                        .navigationTitle("Machine")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Machine", systemImage: "externaldrive")
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
                    journalTab
                        .navigationTitle("Journal")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Journal", systemImage: "note.text")
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
        // Default to full-height on present — leaves `.medium` as a
        // reachable pull-down detent so the user can still collapse
        // the sheet without dismissing it. Without the explicit
        // `selection` binding iOS picks the first detent, which
        // would open the sheet at half height.
        .presentationDetents([.medium, .large], selection: $presentationDetent)
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
                .tabItem { Label("Machine", systemImage: "externaldrive") }
            backupsTab
                .tabItem { Label("Backups", systemImage: "icloud") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            journalTab
                .tabItem { Label("Journal", systemImage: "note.text") }
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
                Picker("Type", selection: Binding(
                    get: { library.deviceType(for: library.card) },
                    set: { library.setDeviceType(
                        $0,
                        for: serial,
                        productName: library.card?.identification?.productName
                    ) }
                )) {
                    ForEach(DeviceType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
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

    /// Per-device compliance-hours target. A Picker with whole-hour
    /// choices from 2–8 covers the insurer-standard 4h plus the
    /// typical user-goal band without offering meaningless values.
    /// The binding rounds any legacy half-hour values to the nearest
    /// valid choice on read, so previously-saved overrides still
    /// resolve to a selected row.
    @ViewBuilder
    private var complianceSection: some View {
        if let serial = currentSerial {
            let binding = Binding<Int>(
                get: {
                    let raw = library.complianceTarget(for: serial)
                    return min(max(Int(raw.rounded()), 2), 8)
                },
                set: { library.setComplianceTarget(Double($0), for: serial) }
            )
            Section {
                Picker("Compliance Target", selection: binding) {
                    ForEach(2...8, id: \.self) { hours in
                        Text("\(hours) hr").tag(hours)
                    }
                }
            } header: {
                Text("Compliance")
            } footer: {
                Text("Hours of usage per night that count a night as compliant. Insurers and sleep clinics typically use 4 hours.")
            }
        }
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
            Text("Uses on-device models to provide insights into your sleep patterns.")
        }
    }

    /// Master switch for the Apple Watch sleep-stage integration.
    /// Flipping on triggers an authorization request followed by a
    /// backfill against the currently-loaded card; flipping off
    /// clears the in-memory map but leaves sidecars on disk so
    /// re-enabling picks up where the user left off.
    @ViewBuilder
    private var appleWatchSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { library.appleWatchSleepEnabled },
                set: { library.setAppleWatchSleepEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Watch Sleep")
                    if library.healthSleep.authState == .unsupported {
                        Text("Health data isn't available on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(library.healthSleep.authState == .unsupported)

            if library.appleWatchSleepEnabled {
                Button("Re-sync now") {
                    library.resyncAppleWatchSleep()
                }
                .disabled(library.card == nil
                          || library.healthSleep.backfillProgress != nil)
            }
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("Reads sleep stages from the Health app so Snorecard can show them next to each night's CPAP data. Snorecard never writes anything to Health.")
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
            Text("Automatically populates the interface with sleep data imported from another device.")
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
            Text("Rebuilds the cached analysis for this \(library.deviceType(for: library.card).displayName) from the original source data. Useful if the analysis appears stale or incorrect.")
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
                    title: "No Machine Loaded",
                    message: "Import a ResMed SD card to see machine details here."
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
                    title: "No Machine Loaded",
                    message: "Import a ResMed SD card to back it up to iCloud Drive."
                )
            }
        }
        .formStyle(.grouped)
    }

    /// Appearance tab — app-icon picker (iOS-only) followed by the
    /// sidebar appearance controls on both platforms. Alternate app
    /// icons on macOS depend on `NSApp.applicationIconImage`, which
    /// doesn't play nicely with `.icon` packages and isn't worth an
    /// AppKit bridge for a cosmetic feature, so that section stays
    /// iOS-only.
    @ViewBuilder
    private var appearanceTab: some View {
        Form {
            sidebarAppearanceSection
            eventPaletteSection
            #if os(iOS)
            appIconSection
            #endif
        }
        .formStyle(.grouped)
    }

    /// Picker for the event-marker colour palette — drives the OA /
    /// H / CA colours in the event donut and the Events-by-Hour
    /// chart. Named presets swap in alternative schemes for users
    /// who find the default muted red/yellow/blue hard to read.
    @ViewBuilder
    private var eventPaletteSection: some View {
        Section {
            Picker(
                "Color Theme",
                selection: Binding(
                    get: { library.eventColorPalette },
                    set: { library.eventColorPalette = $0 }
                )
            ) {
                ForEach(EventColorPalette.allCases) { palette in
                    Text(palette.displayName).tag(palette)
                }
            }
        } header: {
            Text("Charting")
        } footer: {
            Text("Controls the colors used in Trends, Daily View and Detailed Waveforms.")
        }
    }

    /// Sidebar row styling — AHI-severity color toggle plus the
    /// right-hand metric picker. Both prefs live on `Library` and
    /// are persisted via `UserDefaults` so the controls read/write
    /// a single source of truth.
    @ViewBuilder
    private var sidebarAppearanceSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { library.sidebarSeverityColorsEnabled },
                set: { library.sidebarSeverityColorsEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Color Code by AHI")
                    Text("Tints each day's icon green, orange, or red based on AHI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker(
                "Show in Sidebar",
                selection: Binding(
                    get: { library.sidebarRowMetric },
                    set: { library.sidebarRowMetric = $0 }
                )
            ) {
                ForEach(SidebarRowMetric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
        } header: {
            Text("Sidebar")
        } footer: {
            Text("Controls how each day appears in the sidebar.")
        }
    }

    /// Journal tab — lets the user pick tags to auto-attach to every
    /// newly-imported night. Applied in `Library.load()` during the
    /// stats-backfill pass, and only to days that don't already have
    /// a journal sidecar, so manual edits always win.
    @ViewBuilder
    private var journalTab: some View {
        Form {
            Section {
                ForEach(NoteTagCategory.allCases, id: \.self) { category in
                    journalTagGroup(category)
                }
            } header: {
                Text("Default Tags")
            } footer: {
                Text("These tags are added to every newly imported night. Edit a night's tags in the Sleep Journal to change them.")
            }

            if !library.defaultJournalTags.isEmpty {
                Section {
                    Button("Clear All Defaults", role: .destructive) {
                        library.defaultJournalTags = []
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func journalTagGroup(
        _ category: NoteTagCategory
    ) -> some View {
        DisclosureGroup {
            ForEach(category.tags, id: \.self) { tag in
                Toggle(tag.displayLabel, isOn: Binding(
                    get: { library.defaultJournalTags.contains(tag) },
                    set: { isOn in
                        var current = library.defaultJournalTags
                        if isOn { current.insert(tag) }
                        else { current.remove(tag) }
                        library.defaultJournalTags = current
                    }
                ))
            }
        } label: {
            HStack {
                Text(category.displayLabel)
                Spacer()
                let count = category.tags.filter {
                    library.defaultJournalTags.contains($0)
                }.count
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            appleWatchSection
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
        // Live SwiftUI composition of the shared waveform SVG over
        // the option's background fill — avoids shipping per-icon
        // preview PNGs and stays in step with the `.icon` package
        // automatically.
        AppIconPreview(option: option)
    }
}
