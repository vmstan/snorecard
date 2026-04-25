import SwiftUI
import SnorecardKit
import UniformTypeIdentifiers

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
    /// Per-range AI narrative — fired from Trends. Routes
    /// to `TrendsView` so it can populate the trigger state
    /// with its current range and filtered stats before the
    /// sheet / inspector opens.
    static let snorecardOpenTrendsAnalysis = Notification.Name("Snorecard.OpenTrendsAnalysis")
    /// Raised from the Settings sheet on both platforms — routes
    /// back to ContentView which owns the destructive confirmation
    /// alert.
    static let snorecardRebuildCache = Notification.Name("Snorecard.RebuildCache")
    /// Open the Detailed Statistics window — fired from the macOS
    /// View menu. Routed to `DayDetailView` which owns the
    /// currently-loaded waveform bundle used to build the payload.
    static let snorecardOpenDetailedStatistics = Notification.Name("Snorecard.OpenDetailedStatistics")
    /// Open the Advanced Charting window — fired from the macOS
    /// View menu. Routed to `DayDetailView` which builds the
    /// payload from the current day's BRP / PLD / EVE URLs.
    static let snorecardOpenAdvancedCharting = Notification.Name("Snorecard.OpenAdvancedCharting")
    /// Present the SD-card folder picker — fired from the macOS
    /// File menu so ContentView, which owns the `.fileImporter`
    /// presentation state, can surface the sheet.
    static let snorecardImportSDCard = Notification.Name("Snorecard.ImportSDCard")
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var isConfirmingRebuild = false
    @State private var isShowingSettings = false
    @State private var isShowingFolderPicker = false
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
    enum InspectorPane { case notes, deviceNotes, settings, explainMetric, sleepAnalysis, trendsAnalysis }
    @State private var inspectorPane: InspectorPane? = nil
    #endif
    #if os(iOS)
    @State private var isShowingDeviceNotes = false
    /// Drives whether the detail pane carries its own Options menu.
    /// On iPad regular-width the sidebar is always on screen and
    /// already hosts the same menu, so duplicating it in the detail
    /// toolbar would show the ellipsis twice. Compact / iPhone
    /// layouts stack the columns, so the detail pane needs its own
    /// copy for when the sidebar isn't visible.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
        return "Machine \(folder.serial)"
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
                        library.pendingTrendsAnalysis = nil
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
            // from Trends, so retract it when the user drills
            // into a day.
            if case .notes = inspectorPane, case .day = newSelection { return }
            if case .settings = inspectorPane, case .day = newSelection { return }
            if case .sleepAnalysis = inspectorPane, case .day = newSelection { return }
            if case .deviceNotes = inspectorPane, case .trends = newSelection { return }
            if case .trendsAnalysis = inspectorPane, case .trends = newSelection { return }
            if inspectorPane == .notes
                || inspectorPane == .settings
                || inspectorPane == .deviceNotes
                || inspectorPane == .explainMetric
                || inspectorPane == .sleepAnalysis
                || inspectorPane == .trendsAnalysis {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = nil
                    library.pendingExplain = nil
                    library.pendingTrendsAnalysis = nil
                }
            }
        }
        // Any tap on a stat card — either in DayDetailView or in
        // TrendsView — sets `library.pendingExplain`. Open the
        // inspector in the shared column so the metric
        // explanation matches how Sleep Journal / Therapy Details
        // are presented. Closing the inspector later clears the
        // request back to nil so the same tap can re-open.
        //
        // Clearing `pendingTrendsAnalysis` here prevents stale
        // state from the other surface making the per-card
        // toggle check (`pendingExplain == newRequest`) look
        // wrong on the next tap — without this, tapping a card
        // after switching from Sleep Analysis to the explain
        // pane would silently reset the request and only open
        // on the *second* tap.
        .onChange(of: library.pendingExplain) { _, newRequest in
            if newRequest != nil {
                if library.pendingTrendsAnalysis != nil {
                    library.pendingTrendsAnalysis = nil
                }
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = .explainMetric
                }
            } else if inspectorPane == .explainMetric {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = nil
                }
            }
        }
        // TrendsView sets `pendingTrendsAnalysis` when the
        // user triggers Sleep Analysis from Trends. Same
        // cross-clearing so a pending explain doesn't persist
        // past a swap to Sleep Analysis.
        .onChange(of: library.pendingTrendsAnalysis) { _, newRequest in
            if newRequest != nil {
                if library.pendingExplain != nil {
                    library.pendingExplain = nil
                }
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = .trendsAnalysis
                }
            } else if inspectorPane == .trendsAnalysis {
                withAnimation(.smooth(duration: 0.32)) {
                    inspectorPane = nil
                }
            }
        }
        #endif
        // iOS keeps these as sheets; macOS routes them through the
        // shared inspector column declared above.
        #if os(iOS)
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet(onClose: { isShowingSettings = false })
                .environment(library)
        }
        .sheet(isPresented: $isShowingDeviceNotes) {
            NavigationStack {
                DeviceNotesCard()
                    .padding(20)
                    .padding(.top, 12)
                    .navigationBarTitleDisplayMode(.inline)
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
            // automatically. The sheet skips `.navigationTitle`
            // intentionally — the `InspectorPaneHeader` inside
            // `MetricExplainSheet` already shows the value +
            // caption, so a centered nav title on the same bar
            // would duplicate the content.
            NavigationStack {
                MetricExplainSheet(request: request)
                    .padding(.top, 12)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .environment(library)
        }
        .sheet(item: $library.pendingTrendsAnalysis) { request in
            // Same pattern as Sleep Analysis on the day view —
            // iOS presents as a sheet here at the ContentView
            // root so TrendsView doesn't have to host it
            // directly.
            NavigationStack {
                TrendNarrativeCard(
                    stats: request.stats,
                    rangeStart: request.rangeStart,
                    rangeEnd: request.rangeEnd
                )
                .padding(20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationBarTitleDisplayMode(.inline)
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
            "Rebuild Cache?",
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
            Button("Rebuild Cache", role: .destructive) {
                library.rebuildCache()
            }
        } message: {
            Text(rebuildCacheWarning)
        }
        // Apple Watch sleep first-launch prompt — iOS only. macOS
        // never sets `pendingHealthKitPrompt`, so the alert wouldn't
        // fire there anyway, but `#if`-ing it out keeps the macOS
        // build free of any Health-related UI dead code.
        #if os(iOS)
        .alert(
            "Pull sleep stages from Apple Watch?",
            isPresented: Binding(
                get: { library.pendingHealthKitPrompt },
                set: { newValue in
                    // Treat dismissal-by-tap-outside the same as
                    // "Not now" so we don't keep re-presenting on
                    // every subsequent import.
                    if !newValue { library.declineHealthKitFirstRunPrompt() }
                }
            )
        ) {
            Button("Not now", role: .cancel) {
                library.declineHealthKitFirstRunPrompt()
            }
            Button("Connect") {
                library.acceptHealthKitFirstRunPrompt()
            }
        } message: {
            Text(
                "Snorecard can show your Apple Watch sleep stages alongside each night's CPAP data. "
                + "You'll be asked to grant Health access — Snorecard only reads sleep samples and never writes anything."
            )
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .snorecardRebuildCache)) { _ in
            if library.card?.identification?.serialNumber != nil {
                isConfirmingRebuild = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardImportSDCard)) { _ in
            isShowingFolderPicker = true
        }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            onCompletion: handleFolderImport
        )
        .task(id: library.card?.rootURL) {
            knownDevices = Library.iCloudDeviceFolders()
        }
        #if os(macOS)
        // Bridges from the macOS View menu and the day-detail
        // toolbar. All routes funnel into the same inspector
        // state so the third column is the one surface hosting
        // these accessory views. App-wide Settings is *not* in
        // this list — it opens a standalone window via the
        // SwiftUI `Settings { }` scene declared in SnorecardApp.
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
    ///
    /// Also clears the shared explain / trends-analysis
    /// request state whenever the pane changes. Those state
    /// vars drive the cross-platform presentation of their own
    /// panes, so swapping to an unrelated pane should leave no
    /// stale request behind — otherwise the toggle check on
    /// the next stat-card tap (`pendingExplain == newRequest`)
    /// can resolve against outdated data and swallow the tap.
    private func toggleInspector(_ pane: InspectorPane) {
        withAnimation(.smooth(duration: 0.32)) {
            inspectorPane = (inspectorPane == pane) ? nil : pane
            library.pendingExplain = nil
            library.pendingTrendsAnalysis = nil
        }
    }

    /// Contents of the shared inspector column. Each case is
    /// wrapped in a `NavigationStack` so the pane gets its own
    /// title bar, matching how `DailySettingsInspector` and
    /// `NotesCard` already present themselves on iOS.
    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorPane {
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
                    date: day.date,
                    productName: day.stats?.productName
                        ?? library.card?.identification?.productName,
                    serialNumber: library.card?.identification?.serialNumber,
                    deviceAlias: deviceAliasForInspector,
                    deviceType: library.deviceType(for: library.card).displayName
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
        case .trendsAnalysis:
            if let request = library.pendingTrendsAnalysis {
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
    private var rebuildCacheWarning: String {
        let dayCount = library.card?.days.count ?? 0
        // Prefer the user-set alias (or ResMed product name) over
        // the generic device-type label so the dialog names the
        // machine the user actually recognises.
        let deviceName = library.card
            .map { library.displayName(for: $0) }
            ?? library.deviceType(for: library.card).displayName
        let scope: String
        if dayCount == 0 {
            scope = "every day of data from your \(deviceName)"
        } else if dayCount == 1 {
            scope = "the one day of data from your \(deviceName)"
        } else {
            scope = "all \(dayCount) days of data from your \(deviceName)"
        }

        return """
        This will recompute every metric for \(scope) and replace the data in iCloud. Sleep Analysis summaries are reset at the same time, and will be regenerated on-demand.

        While your charting, AHI, computed percentiles and other scoring data will still be available, the Therapy Details for individual nights your \(deviceName) no longer keeps in its rolling summary, may be lost.

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
                    Label("Import Sleep Data", systemImage: "externaldrive.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command])
                .help("Import your latest sleep data from an SD card")
                #else
                optionsMenu
                #endif
            }
        }
    }

    /// iOS detail toolbar — renders the same library-level
    /// Options menu as the sidebar. Per-context actions (Sleep
    /// Analysis, Sleep Journal, Therapy Details) now live in the
    /// floating action bar at the bottom of `DayDetailView` and
    /// `TrendsView`, so the nav bar stays uncluttered.
    @ToolbarContentBuilder
    private var detailToolbarButtonsForiOS: some ToolbarContent {
        toolbarButtons
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
                Label("Import Sleep Data", systemImage: "externaldrive.badge.plus")
            }
            #if os(macOS)
            .keyboardShortcut("o", modifiers: [.command])
            #endif

            if library.card?.identification?.serialNumber != nil,
               !otherDevices.isEmpty {
                Menu {
                    ForEach(otherDevices) { folder in
                        Button(deviceMenuLabel(for: folder)) {
                            library.load(folder.url)
                        }
                    }
                } label: {
                    Label("Swap Machines", systemImage: "rectangle.2.swap")
                }
            }

            Divider()
            Button {
                isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Label("Actions", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
    }

    // MARK: - Actions

    private func openSDCard() {
        isShowingFolderPicker = true
    }

    /// Handler for the shared `.fileImporter` sheet. On iOS the
    /// returned URL is security-scoped against the external volume,
    /// so access is started and left open for the lifetime of the
    /// process — matches the prior UIDocumentPicker behaviour.
    private func handleFolderImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        #if os(iOS)
        _ = url.startAccessingSecurityScopedResource()
        #endif
        library.load(url)
    }

    @ViewBuilder
    private var sidebar: some View {
        @Bindable var library = library

        Group {
            switch library.state {
            case .empty where library.isInitialProbing:
                // Initial launch splash — keeps the column from
                // flashing the "No SD Card" empty state before the
                // probe has had a chance to pick a folder (common
                // on fresh iPads where iCloud is still delivering
                // metadata for the backup root).
                initialProbeSplash
            case .empty:
                ContentUnavailableView {
                    Label("No SD Card", systemImage: "externaldrive")
                } description: {
                    Text("Import a ResMed SD card folder to begin.")
                } actions: {
                    Button {
                        openSDCard()
                    } label: {
                        Label("Import from SD Card", systemImage: "externaldrive.badge.plus")
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
                case .trends:
                    TrendsView(card: card)
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
                        "Welcome to Snorecard",
                        systemImage: "sidebar.left",
                        description: Text("Select an option from the sidebar to get started.")
                    )
                }
            } else if library.isInitialProbing {
                initialProbeSplash
            } else {
                Color.clear
            }
        }
        #if os(iOS)
        .toolbar {
            if horizontalSizeClass == .compact {
                detailToolbarButtonsForiOS
            }
        }
        #endif
    }

    /// Matching splash used in both the sidebar and the detail
    /// pane during the initial launch probe. Generic enough that
    /// neither column needs to know what the probe is actually
    /// doing — "opening" covers the iCloud-check, snapshot-load,
    /// and UserDefaults-fallback paths alike.
    private var initialProbeSplash: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            VStack(spacing: 4) {
                Text("Opening Snorecard")
                    .font(.headline)
                Text("Checking iCloud for your sleep data…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
