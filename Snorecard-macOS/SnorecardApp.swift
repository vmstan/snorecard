import SwiftUI

@main
struct SnorecardApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    library.loadLastOpenedIfPossible()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open SD Card…") {
                    if let url = presentFolderPicker(
                        prompt: "Open",
                        message: "Select a ResMed SD card or DATALOG export folder"
                    ) {
                        library.load(url)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open iCloud Copy") {
                    openICloudCopyFromMenu()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Restore from Backup…") {
                    if let url = presentFolderPicker(
                        prompt: "Open",
                        message: "Select a previously-saved ResMed backup folder"
                    ) {
                        library.load(url)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Sync to iCloud") {
                    library.startBackupToICloudDrive()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(library.card == nil)

                Button("Take a Backup…") {
                    if let url = presentFolderPicker(
                        prompt: "Back Up Here",
                        message: "Choose a folder to save a timestamped backup into"
                    ) {
                        library.startBackup(to: url)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(library.card == nil)
            }
        }
    }

    /// Shared "Open iCloud Copy" logic between the menu item and the toolbar
    /// button — auto-opens the single device folder when only one exists,
    /// otherwise drops the user into the picker at Snorecard's iCloud
    /// container root.
    private func openICloudCopyFromMenu() {
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
        let subfolders = ((try? fm.contentsOfDirectory(
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
    }
}
