import SwiftUI
import SnorecardKit

// Notifications used by the iOS Options menu to drive the daily
// view's per-night sheets. Defined in the shared codebase so both
// ContentView (the menu owner) and DayDetailView (the sheet
// owner) can reference them without a cross-target import.
extension Notification.Name {
    static let snorecardOpenDailyNotes = Notification.Name("Snorecard.OpenDailyNotes")
    static let snorecardOpenDailySettings = Notification.Name("Snorecard.OpenDailySettings")
    static let snorecardOpenDeviceNotes = Notification.Name("Snorecard.OpenDeviceNotes")
    /// Per-night AI narrative — fired from the day view.
    static let snorecardOpenSleepAnalysis = Notification.Name("Snorecard.OpenSleepAnalysis")
    /// Per-range AI narrative — fired from the Overview. Routes
    /// to `OverviewView` so it can populate the trigger state
    /// with its current range and filtered stats before the
    /// sheet / inspector opens.
    static let snorecardOpenOverviewAnalysis = Notification.Name("Snorecard.OpenOverviewAnalysis")
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var isRenamingDevice = false
    @State private var isConfirmingRebuild = false
    @State private var isShowingBackups = false
    @State private var knownDevices: [Library.DeviceFolder] = []

    #if os(macOS)
    /// Which pane the shared macOS inspector is currently showing.
    /// A single third column hosts all library- and day-level
    /// accessory views (rename, backups, sleep journal, therapy
    /// details, metric explain) so they behave consistently —
    /// opening one replaces whatever was there, and the column
    /// slides out when the pane is nil. Matches the Finder Get
    /// Info / Mail Viewer precedent where one inspector swaps
    /// content instead of spawning extra windows.
    enum InspectorPane { case rename, backups, notes, deviceNotes, settings, explainMetric, sleepAnalysis, overviewAnalysis }
    @State private var inspectorPane: InspectorPane? = nil
    #endif
    #if os(iOS)
    @State private var isShowingDeviceNotes = false
    #endif

    private var otherDevices: [Library.DeviceFolder] {
        let currentSerial = library.card?.identification?.serialNumber
        return knownDevices.filter { $0.serial != currentSerial }
    }

    private func deviceMenuLabel(for folder: Library.DeviceFolder) -> String {
        if let override = library.deviceNameOverrides[folder.serial], !override.isEmpty {
            return "\(override) (\(folder.serial))"
        }
        if let product = folder.productName, !product.isEmpty {
            return "\(product) (\(folder.serial))"
        }
        return "Device \(folder.serial)"
    }

    /// Best-effort display name to show while a given URL is loading —
    /// resolved by matching the folder's serial against any known
    /// iCloud device folder and applying the same override →
    /// productName precedence as the sidebar.
    private func loadingDeviceName(for url: URL) -> String? {
        let serial = url.lastPathComponent
        if let override = library.deviceNameOverrides[serial], !override.isEmpty {
            return override
        }
        if let match = knownDevices.first(where: { $0.serial == serial }),
           let product = match.productName, !product.isEmpty {
            return product
        }
        return nil
    }

    var body: some View {
        @Bindable var library = library

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                #if os(iOS)
                .toolbar { toolbarButtons }
                #endif
        } detail: {
            detail
        }
        #if os(macOS)
        .toolbar { toolbarButtons }
        .inspector(isPresented: Binding(
            get: { inspectorPane != nil },
            set: { shown in
                if !shown {
                    withAnimation(.smooth(duration: 0.32)) {
                        inspectorPane = nil
                        // Clear both request properties when the
                        // user manually closes the inspector, so
                        // re-triggering the same surface opens it
                        // again cleanly.
                        library.pendingExplain = nil
                        library.pendingOverviewAnalysis = nil
                    }
                }
            }
        )) {
            inspectorContent
                .id(inspectorPane)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
        }
        .inspectorColumnWidth(min: 420, ideal: 500, max: 640)
        .onChange(of: library.selection) { _, newSelection in
            // Day-level panes are meaningless once the user leaves
            // the day they were looking at, so retract the
            // inspector whenever selection flips away from a day.
            // Symmetrically, the device-wide journal is only offered
            // from the Overview, so retract it when the user drills
            // into a day.
            if case .notes = inspectorPane, case .day = newSelection { return }
            if case .settings = inspectorPane, case .day = newSelection { return }
            if case .sleepAnalysis = inspectorPane, case .day = newSelection { return }
            if case .deviceNotes = inspectorPane, case .overview = newSelection { return }
            if case .overviewAnalysis = inspectorPane, case .overview = newSelection { return }
            if inspectorPane == .notes
                || inspectorPane == .settings
                || inspectorPane == .deviceNotes
                || inspectorPane == .explainMetric
                || inspectorPane == .sleepAnalysis
                || inspectorPane == .overviewAnalysis {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = nil
                    library.pendingExplain = nil
                    library.pendingOverviewAnalysis = nil
                }
            }
        }
        // Any tap on a stat card — either in DayDetailView or in
        // OverviewView — sets `library.pendingExplain`. Open the
        // inspector in the shared column so the metric
        // explanation matches how Sleep Journal / Therapy Details
        // are presented. Closing the inspector later clears the
        // request back to nil so the same tap can re-open.
        .onChange(of: library.pendingExplain) { _, newRequest in
            if newRequest != nil {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = .explainMetric
                }
            } else if inspectorPane == .explainMetric {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = nil
                }
            }
        }
        // OverviewView sets `pendingOverviewAnalysis` when the
        // user triggers Sleep Analysis from the Overview. Open
        // the inspector to the trend narrative; clearing the
        // state retracts it. Same pattern as pendingExplain.
        .onChange(of: library.pendingOverviewAnalysis) { _, newRequest in
            if newRequest != nil {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = .overviewAnalysis
                }
            } else if inspectorPane == .overviewAnalysis {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = nil
                }
            }
        }
        #endif
        // iOS keeps these as sheets; macOS routes them through the
        // shared inspector column declared above.
        #if os(iOS)
        .sheet(isPresented: $isShowingBackups) {
            BackupsView(onClose: { isShowingBackups = false })
                .environment(library)
        }
        .sheet(isPresented: $isRenamingDevice) {
            if let card = library.card,
               let serial = card.identification?.serialNumber {
                RenameDeviceSheet(
                    serial: serial,
                    defaultName: card.identification?.productName ?? "ResMed Device",
                    currentOverride: library.deviceNameOverrides[serial],
                    onSave: { newName in
                        library.setDeviceName(newName, for: serial)
                    },
                    onClose: { isRenamingDevice = false }
                )
            }
        }
        .sheet(isPresented: $isShowingDeviceNotes) {
            NavigationStack {
                DeviceNotesCard()
                    .padding(20)
                    .navigationTitle("Sleep Journal")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            CloseSheetButton { isShowingDeviceNotes = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .environment(library)
        }
        .sheet(item: $library.pendingExplain) { request in
            // iOS keeps the metric explanation as a sheet; macOS
            // routes the same request through the shared
            // inspector column instead. Binding `pendingExplain`
            // through `$library` so dismissal clears it
            // automatically.
            NavigationStack {
                MetricExplainSheet(request: request)
                    .navigationTitle(request.displayLabel)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            CloseSheetButton {
                                library.pendingExplain = nil
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .environment(library)
        }
        .sheet(item: $library.pendingOverviewAnalysis) { request in
            // Same pattern as Sleep Analysis on the day view —
            // iOS presents as a sheet here at the ContentView
            // root so OverviewView doesn't have to host it
            // directly.
            NavigationStack {
                TrendNarrativeCard(
                    stats: request.stats,
                    rangeStart: request.rangeStart,
                    rangeEnd: request.rangeEnd
                )
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("Sleep Analysis")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        CloseSheetButton {
                            library.pendingOverviewAnalysis = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .environment(library)
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenDeviceNotes)) { _ in
            if library.card != nil {
                isShowingDeviceNotes = true
            }
        }
        #endif
        .alert(
            "Rebuild Statistics?",
            isPresented: $isConfirmingRebuild
        ) {
            // Order matters — on iOS alerts place Cancel leading
            // and the default-action trailing when both are present;
            // placing Cancel first keeps that layout consistent and
            // guarantees the Cancel button is always rendered
            // (which `.confirmationDialog` didn't on iOS when the
            // message grew past a few lines).
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.cancelAction)
            Button("Rebuild Statistics", role: .destructive) {
                library.invalidateStatsCacheAndReload()
            }
        } message: {
            Text(rebuildStatisticsWarning)
        }
        .task(id: library.card?.rootURL) {
            knownDevices = Library.iCloudDeviceFolders()
        }
        #if os(macOS)
        // Bridges from the macOS File menu, Options menu, and the
        // day-detail toolbar. All routes funnel into the same
        // inspector state so the third column is the one surface
        // hosting these accessory views.
        .onReceive(NotificationCenter.default.publisher(for: .snorecardRenameDevice)) { _ in
            if library.card?.identification?.serialNumber != nil {
                toggleInspector(.rename)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardRebuildStatistics)) { _ in
            if library.card?.identification?.serialNumber != nil {
                isConfirmingRebuild = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardShowBackups)) { _ in
            if library.card?.identification?.serialNumber != nil {
                toggleInspector(.backups)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenDailyNotes)) { _ in
            if case .day = library.selection {
                toggleInspector(.notes)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenDailySettings)) { _ in
            if case .day = library.selection {
                toggleInspector(.settings)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenDeviceNotes)) { _ in
            if library.card != nil {
                toggleInspector(.deviceNotes)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardOpenSleepAnalysis)) { _ in
            if case .day = library.selection, library.intelligence.isReady {
                toggleInspector(.sleepAnalysis)
            }
        }
        #endif
    }

    #if os(macOS)
    /// Toggle the given pane: tapping the button for the
    /// already-visible pane collapses the inspector; tapping
    /// another swaps content in place without a close/reopen
    /// flicker. Matches the behavior the day-detail toolbar had
    /// before these panes were unified here.
    private func toggleInspector(_ pane: InspectorPane) {
        withAnimation(.smooth(duration: 0.32)) {
            inspectorPane = (inspectorPane == pane) ? nil : pane
        }
    }

    /// Contents of the shared inspector column. Each case is
    /// wrapped in a `NavigationStack` so the pane gets its own
    /// title bar, matching how `DailySettingsInspector` and
    /// `NotesCard` already present themselves on iOS.
    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorPane {
        case .rename:
            renameInspectorPane
        case .backups:
            BackupsView(onClose: {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = nil
                }
            })
                .environment(library)
        case .notes:
            if let day = library.selectedDay {
                NotesCard(day: day)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationTitle("Sleep Journal")
            } else {
                EmptyView()
            }
        case .deviceNotes:
            if library.card != nil {
                DeviceNotesCard()
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationTitle("Sleep Journal")
            } else {
                EmptyView()
            }
        case .settings:
            if let day = library.selectedDay {
                DailySettingsInspector(
                    settings: day.stats?.settings,
                    productName: day.stats?.productName
                        ?? library.card?.identification?.productName,
                    serialNumber: library.card?.identification?.serialNumber,
                    deviceAlias: deviceAliasForInspector
                )
            } else {
                EmptyView()
            }
        case .explainMetric:
            if let request = library.pendingExplain {
                MetricExplainSheet(request: request)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationTitle(request.displayLabel)
            } else {
                EmptyView()
            }
        case .sleepAnalysis:
            if let day = library.selectedDay {
                NightSummaryCard(day: day)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationTitle("Sleep Analysis")
            } else {
                EmptyView()
            }
        case .overviewAnalysis:
            if let request = library.pendingOverviewAnalysis {
                TrendNarrativeCard(
                    stats: request.stats,
                    rangeStart: request.rangeStart,
                    rangeEnd: request.rangeEnd
                )
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("Sleep Analysis")
            } else {
                EmptyView()
            }
        case .none:
            EmptyView()
        }
    }

    /// Rename Device rendered as a Spotlight-style panel inside
    /// the inspector. Closes by driving `inspectorPane` back to
    /// nil — we can't use `@Environment(\.dismiss)` here because
    /// inside an `.inspector` attached to the root
    /// `NavigationSplitView` it resolves to the host window and
    /// would quit the app via
    /// `applicationShouldTerminateAfterLastWindowClosed`.
    @ViewBuilder
    private var renameInspectorPane: some View {
        if
            let card = library.card,
            let serial = card.identification?.serialNumber
        {
            RenameDeviceSheet(
                serial: serial,
                defaultName: card.identification?.productName ?? "ResMed Device",
                currentOverride: library.deviceNameOverrides[serial],
                onSave: { newName in
                    library.setDeviceName(newName, for: serial)
                },
                onClose: {
                    withAnimation(.smooth(duration: 0.32)) {
                        inspectorPane = nil
                    }
                }
            )
        } else {
            EmptyView()
        }
    }

    /// User-set alias for the current card, or nil when unset.
    /// The settings inspector hides the device row when this is
    /// nil so the product name doesn't duplicate across rows.
    private var deviceAliasForInspector: String? {
        guard let serial = library.card?.identification?.serialNumber,
              let alias = library.deviceNameOverrides[serial],
              !alias.isEmpty
        else { return nil }
        return alias
    }
    #endif

    private var isLoading: Bool {
        if case .loading = library.state { return true }
        return false
    }

    /// Long-form explanation for the Rebuild Statistics confirmation
    /// dialog. Mentions the concrete consequences (cache wiped, iCloud
    /// re-sync, time cost) so the user can make an informed call
    /// rather than treating it as a trivial refresh button.
    private var rebuildStatisticsWarning: String {
        let dayCount = library.card?.days.count ?? 0
        let scope: String
        if dayCount == 0 {
            scope = "every day of data on this device"
        } else if dayCount == 1 {
            scope = "the one day of data on this device"
        } else {
            scope = "all \(dayCount) days of data on this device"
        }

        return """
        This will recompute every metric for \(scope) from the raw EDF files and replace the current summary data in iCloud.
        
        Use this if your statistic numbers look wrong — if you're missing full nights because you just imported data on another device, use Refresh instead.

        While charting, AHI, computed percentiles and other scoring data will still be available, any therapy settings for nights your CPAP no longer keeps in its rolling summary may be lost.
        
        Based on your dataset this process may take \(estimatedRebuildDuration(dayCount: dayCount)).
        """
    }

    /// Rough "this-will-take-X" string based on the day count.
    /// Deliberately conservative — under-promising beats having the
    /// user staring at a progress footer wondering why the quoted
    /// estimate already passed. Assumes ~0.75 s per day (roughly 5×
    /// the ~150 ms measured on Apple silicon) and biases each
    /// bucket toward the longer end of the likely range so older
    /// iPhones, busy iCloud writes, and cold caches still fit.
    private func estimatedRebuildDuration(dayCount: Int) -> String {
        guard dayCount > 0 else { return "a few seconds" }
        let seconds = Int((Double(dayCount) * 0.75).rounded(.up))
        switch seconds {
        case ..<10:   return "a few seconds"
        case ..<45:   return "approximately a minute"
        case ..<180:  return "a couple of minutes"
        case ..<600:  return "several minutes"
        case ..<1800: return "up to half an hour"
        default:      return "over half an hour"
        }
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if !isLoading {
                #if os(macOS)
                // macOS: every other library command is reachable
                // from the File menu, so the toolbar only surfaces
                // Import SD Card — the one action a user reaches
                // for often enough to justify a visible button.
                Button {
                    openSDCard()
                } label: {
                    Label("Import SD Card", systemImage: "sdcard")
                }
                .keyboardShortcut("o", modifiers: [.command])
                .help("Import a ResMed SD card or DATALOG folder")
                #else
                optionsMenu
                #endif
            }
        }
    }

    /// iOS detail toolbar — always renders the Options menu, but
    /// the menu's contents change with the active selection so a
    /// day view can include Notes / Device Settings actions
    /// alongside the library-level commands without growing
    /// extra top-bar buttons.
    @ToolbarContentBuilder
    private var detailToolbarButtonsForiOS: some ToolbarContent {
        toolbarButtons
    }

    private var isViewingDay: Bool {
        if case .day = library.selection { return true }
        return false
    }

    @ViewBuilder
    private var optionsMenu: some View {
        Menu {
            // Import sits at the top on iOS across every view so
            // "get more data in" is always the first option the
            // user reaches for. macOS inherits the same ordering —
            // there's no reason to differ, and the File menu
            // carries the primary ⌘O entry anyway.
            Button {
                openSDCard()
            } label: {
                Label("Import SD Card", systemImage: "sdcard")
            }
            #if os(macOS)
            .keyboardShortcut("o", modifiers: [.command])
            #endif

            #if os(iOS)
            // Day-detail-specific actions piggyback on the
            // shared Options menu when the user is viewing a
            // day, so the nav bar only ever shows one button.
            // macOS keeps these in the day-detail toolbar
            // proper because there's room for the extra glyphs.
            if isViewingDay {
                Divider()
                if library.intelligence.isReady {
                    Button {
                        NotificationCenter.default.post(
                            name: .snorecardOpenSleepAnalysis,
                            object: nil
                        )
                    } label: {
                        Label("Sleep Analysis", systemImage: "sparkles")
                    }
                }
                Button {
                    NotificationCenter.default.post(
                        name: .snorecardOpenDailyNotes,
                        object: nil
                    )
                } label: {
                    Label("Sleep Journal", systemImage: "note.text")
                }
                Button {
                    NotificationCenter.default.post(
                        name: .snorecardOpenDailySettings,
                        object: nil
                    )
                } label: {
                    Label("Therapy Details", systemImage: "gauge.with.needle")
                }
            } else if library.card != nil {
                // Overview-scoped entries — Sleep Analysis leads
                // the cluster (same ordering as the day view),
                // followed by the device-wide Sleep Journal.
                Divider()
                if library.intelligence.isReady {
                    Button {
                        NotificationCenter.default.post(
                            name: .snorecardOpenOverviewAnalysis,
                            object: nil
                        )
                    } label: {
                        Label("Sleep Analysis", systemImage: "sparkles")
                    }
                }
                Button {
                    NotificationCenter.default.post(
                        name: .snorecardOpenDeviceNotes,
                        object: nil
                    )
                } label: {
                    Label("Sleep Journal", systemImage: "note.text")
                }
            }
            #endif

            if library.card?.identification?.serialNumber != nil {
                Divider()
                Button {
                    #if os(macOS)
                    toggleInspector(.rename)
                    #else
                    isRenamingDevice = true
                    #endif
                } label: {
                    Label("Rename Device", systemImage: "pencil")
                }
                if !otherDevices.isEmpty {
                    Menu {
                        ForEach(otherDevices) { folder in
                            Button(deviceMenuLabel(for: folder)) {
                                library.load(folder.url)
                            }
                        }
                    } label: {
                        Label("Switch Device", systemImage: "rectangle.2.swap")
                    }
                }

                Divider()
                Button {
                    #if os(macOS)
                    toggleInspector(.backups)
                    #else
                    isShowingBackups = true
                    #endif
                } label: {
                    Label("Backup & Restore", systemImage: "externaldrive.badge.timemachine")
                }
                Button(role: .destructive) {
                    isConfirmingRebuild = true
                } label: {
                    Label("Rebuild Statistics", systemImage: "hammer")
                }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
    }

    // MARK: - Actions

    private func openSDCard() {
        #if os(macOS)
        if let url = presentFolderPicker(
            prompt: "Open",
            message: "Select a ResMed SD card or DATALOG export folder"
        ) {
            library.load(url)
        }
        #else
        presentIOSFolderPicker { url in
            library.load(url)
        }
        #endif
    }

    @ViewBuilder
    private var sidebar: some View {
        @Bindable var library = library

        Group {
            switch library.state {
            case .empty:
                ContentUnavailableView {
                    Label("No SD Card", systemImage: "externaldrive")
                } description: {
                    Text("Import a ResMed SD card folder to begin.")
                } actions: {
                    Button {
                        openSDCard()
                    } label: {
                        Label("Import from SD Card", systemImage: "sdcard")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .loading(let url):
                LoadingView(
                    url: url,
                    prefetchProgress: library.cloudPrefetchProgress,
                    deviceName: loadingDeviceName(for: url)
                )
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        openSDCard()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .loaded(let card), .hydrating(let card):
                DayListView(card: card, selection: $library.selection)
            }
        }
        .navigationTitle(sidebarNavigationTitle)
    }

    /// Hide the app name while the loading screen is up — the
    /// LoadingView already says which device is being fetched, and a
    /// bold "Snorecard" title above it looks redundant.
    private var sidebarNavigationTitle: String {
        if case .loading = library.state { return "" }
        return "Snorecard"
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let card = library.card {
                switch library.selection {
                case .overview:
                    OverviewView(card: card)
                case .day:
                    if let day = library.selectedDay {
                        DayDetailView(day: day)
                    } else {
                        ContentUnavailableView(
                            "Day not found",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                    }
                case .none:
                    ContentUnavailableView(
                        "Select Overview or a day",
                        systemImage: "sidebar.left",
                        description: Text("Pick something from the sidebar.")
                    )
                }
            } else {
                Color.clear
            }
        }
        #if os(iOS)
        .toolbar { detailToolbarButtonsForiOS }
        #endif
    }
}
