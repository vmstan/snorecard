import SwiftUI
import SnorecardKit

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var isRenamingDevice = false
    @State private var isConfirmingRebuild = false
    @State private var knownDevices: [Library.DeviceFolder] = []

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
        .confirmationDialog(
            "Rebuild Statistics?",
            isPresented: $isConfirmingRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild", role: .destructive) {
                library.invalidateStatsCacheAndReload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This discards the cached per-day statistics and recomputes every day's summary from scratch. It can take a while for devices with months of data.")
        }
        .task(id: library.card?.rootURL) {
            knownDevices = Library.iCloudDeviceFolders()
        }
    }

    private var isLoading: Bool {
        if case .loading = library.state { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if !isLoading {
                optionsMenu
            }
        }
    }

    @ViewBuilder
    private var optionsMenu: some View {
        Menu {
            Button {
                openSDCard()
            } label: {
                Label("Import from SD Card", systemImage: "sdcard")
            }
            #if os(macOS)
            .keyboardShortcut("o", modifiers: [.command])
            #endif

            if let card = library.card,
               card.identification?.serialNumber != nil {
                Divider()
                Button {
                    library.reloadCurrent()
                } label: {
                    Label("Reload from iCloud", systemImage: "icloud.and.arrow.down")
                }
                Button {
                    isRenamingDevice = true
                } label: {
                    Label("Rename Device…", systemImage: "square.and.pencil")
                }
                Button {
                    isConfirmingRebuild = true
                } label: {
                    Label("Rebuild Statistics", systemImage: "arrow.clockwise")
                }
                if !otherDevices.isEmpty {
                    Divider()
                    Menu {
                        ForEach(otherDevices) { folder in
                            Button(deviceMenuLabel(for: folder)) {
                                library.load(folder.url)
                            }
                        }
                    } label: {
                        Label("Switch Device", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        #if os(macOS)
        .help("Import data or rename the current device")
        #endif
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
            case .loaded(let card):
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
            if case .loaded(let card) = library.state {
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
        .toolbar { toolbarButtons }
        #endif
    }
}
