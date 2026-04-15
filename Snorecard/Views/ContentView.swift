import SwiftUI
import SnorecardKit

struct ContentView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library

        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                #if os(iOS)
                // On iPhone the split view collapses to a NavigationStack;
                // toolbar items on the root view reach the iOS nav bar only
                // when attached here rather than on the split view itself.
                .toolbar { toolbarButtons }
                #endif
        } detail: {
            detail
        }
        #if os(macOS)
        // On macOS, toolbar items attached to the sidebar land in the
        // narrow column header. Putting them at the split-view level
        // instead lets them span the full window toolbar.
        .toolbar { toolbarButtons }
        #endif
        .sheet(isPresented: backupSheetBinding) {
            BackupStatusSheet(state: library.backup) {
                library.dismissBackupStatus()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button {
                openSDCard()
            } label: {
                Label("Open SD Card", systemImage: "sdcard")
            }
            .help("Open a ResMed SD card folder (⌘O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                openICloudCopy()
            } label: {
                Label("Open iCloud Copy", systemImage: "icloud.and.arrow.down")
            }
            .help("Load a previously-synced copy from iCloud Drive (⇧⌘I)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                library.startBackupToICloudDrive()
            } label: {
                Label("Sync to iCloud", systemImage: "icloud.and.arrow.up")
            }
            .disabled(library.card == nil)
            .help("Overwrite the iCloud copy of this device with the current SD card (⌘S)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                takeBackup()
            } label: {
                Label("Take a Backup", systemImage: "externaldrive.badge.timemachine")
            }
            .disabled(library.card == nil)
            .help("Save a timestamped backup of the current SD card to a folder you pick (⇧⌘S)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                restoreFromBackup()
            } label: {
                Label("Restore from Backup", systemImage: "clock.arrow.circlepath")
            }
            .help("Open a previously-saved backup folder (⇧⌘O)")
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    openSDCard()
                } label: {
                    Label("Open SD Card", systemImage: "sdcard")
                }
                Button {
                    openICloudCopy()
                } label: {
                    Label("Open iCloud Copy", systemImage: "icloud.and.arrow.down")
                }
                Button {
                    restoreFromBackup()
                } label: {
                    Label("Restore from Backup", systemImage: "clock.arrow.circlepath")
                }
                Divider()
                Button {
                    library.startBackupToICloudDrive()
                } label: {
                    Label("Sync to iCloud", systemImage: "icloud.and.arrow.up")
                }
                .disabled(library.card == nil)
                Button {
                    takeBackup()
                } label: {
                    Label("Take a Backup", systemImage: "externaldrive.badge.timemachine")
                }
                .disabled(library.card == nil)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
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

    private func restoreFromBackup() {
        #if os(macOS)
        if let url = presentFolderPicker(
            prompt: "Open",
            message: "Select a previously-saved ResMed backup folder"
        ) {
            library.load(url)
        }
        #else
        presentIOSFolderPicker { url in
            library.load(url)
        }
        #endif
    }

    private func takeBackup() {
        #if os(macOS)
        if let url = presentFolderPicker(
            prompt: "Back Up Here",
            message: "Choose a folder to save a timestamped backup into"
        ) {
            library.startBackup(to: url)
        }
        #else
        presentIOSFolderPicker { url in
            library.startBackup(to: url)
        }
        #endif
    }

    private func openICloudCopy() {
        #if os(macOS)
        guard let backupRoot = Library.iCloudBackupRoot else {
            library.state = .failed(
                "iCloud Drive isn't set up, or Snorecard's iCloud container hasn't finished initialising yet. Enable iCloud Drive in System Settings and try again."
            )
            return
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: backupRoot.path) else {
            library.state = .failed(
                "No Snorecard backups found in iCloud Drive yet. Use “Sync to iCloud” after opening an SD card."
            )
            return
        }

        // List device-serial subfolders inside the ubiquity container. If
        // there's exactly one we open it directly; otherwise pop up the
        // folder picker rooted at that folder so the user can choose.
        let subfolders: [URL] = ((try? fm.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        if subfolders.count == 1 {
            library.load(subfolders[0])
            return
        }

        if let url = presentFolderPicker(
            prompt: "Open",
            message: "Select an iCloud-synced ResMed device folder",
            startingAt: backupRoot
        ) {
            library.load(url)
        }
        #else
        // On iOS the document picker doesn't take a starting directory,
        // so the user navigates to iCloud Drive themselves.
        presentIOSFolderPicker { url in
            library.load(url)
        }
        #endif
    }

    private var backupSheetBinding: Binding<Bool> {
        Binding(
            get: {
                switch library.backup {
                case .idle: return false
                case .running, .completed, .failed: return true
                }
            },
            set: { newValue in
                if !newValue { library.dismissBackupStatus() }
            }
        )
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
                    Text("Open a ResMed SD card folder to begin.")
                } actions: {
                    Button {
                        openSDCard()
                    } label: {
                        Label("Open SD Card", systemImage: "sdcard")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .loading(let url):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning \(url.lastPathComponent)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .navigationTitle("Snorecard")
    }

    @ViewBuilder
    private var detail: some View {
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
}
