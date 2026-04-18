import SwiftUI
import SnorecardKit

// Notifications used by the iOS Options menu to drive the daily
// view's per-night sheets. Defined in the shared codebase so both
// ContentView (the menu owner) and DayDetailView (the sheet
// owner) can reference them without a cross-target import.
extension Notification.Name {
    static let snorecardOpenDailyNotes = Notification.Name("Snorecard.OpenDailyNotes")
    static let snorecardOpenDailySettings = Notification.Name("Snorecard.OpenDailySettings")
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var isRenamingDevice = false
    @State private var isConfirmingRebuild = false
    @State private var isShowingBackups = false
    @State private var knownDevices: [Library.DeviceFolder] = []
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
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
        #endif
        // iOS keeps these as sheets; macOS routes them through
        // dedicated WindowGroups (see SnorecardApp) so they
        // open as floating windows with traffic-light controls.
        #if os(iOS)
        .sheet(isPresented: $isShowingBackups) {
            BackupsView()
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
                    }
                )
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
        // Bridges from the macOS File menu and Options menu —
        // sheets become standalone windows on macOS so they
        // can show traffic-light controls.
        .onReceive(NotificationCenter.default.publisher(for: .snorecardRenameDevice)) { _ in
            openRenameWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardRebuildStatistics)) { _ in
            if library.card?.identification?.serialNumber != nil {
                isConfirmingRebuild = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snorecardShowBackups)) { _ in
            if library.card?.identification?.serialNumber != nil {
                openWindow(id: "backups")
            }
        }
        #endif
    }

    #if os(macOS)
    /// Build the Rename Device payload from the currently
    /// loaded card and open the window. Bails when no device
    /// is loaded — the menu items are already disabled in
    /// that state, but the notification path could still fire.
    private func openRenameWindow() {
        guard
            let card = library.card,
            let serial = card.identification?.serialNumber
        else { return }
        let payload = RenameDeviceWindowPayload(
            serial: serial,
            defaultName: card.identification?.productName ?? "ResMed Device",
            currentOverride: library.deviceNameOverrides[serial]
        )
        openWindow(value: payload)
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
                optionsMenu
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
            #if os(iOS)
            // Day-detail-specific actions piggyback on the
            // shared Options menu when the user is viewing a
            // day, so the nav bar only ever shows one button.
            // macOS keeps these in the day-detail toolbar
            // proper because there's room for the extra glyphs.
            if isViewingDay {
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
                Divider()
            }
            #endif

            if library.card?.identification?.serialNumber != nil {
                Button {
                    library.reloadCurrent()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                #if os(macOS)
                .keyboardShortcut("r", modifiers: [.command])
                #endif
            }

            Button {
                openSDCard()
            } label: {
                Label("Import SD Card", systemImage: "sdcard")
            }
            #if os(macOS)
            .keyboardShortcut("o", modifiers: [.command])
            #endif

            if library.card?.identification?.serialNumber != nil {
                Divider()
                Button {
                    #if os(macOS)
                    openRenameWindow()
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
                    openWindow(id: "backups")
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
