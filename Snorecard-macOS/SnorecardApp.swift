import SwiftUI
import AppKit

/// Quit the app when the user closes its only window. Standard macOS
/// behavior leaves the process running in the Dock — not what a
/// single-window data viewer like Snorecard should do.
final class SnorecardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SnorecardApp: App {
    @NSApplicationDelegateAdaptor(SnorecardAppDelegate.self) private var appDelegate
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
                Button("Import from SD Card…") {
                    if let url = presentFolderPicker(
                        prompt: "Open",
                        message: "Select a ResMed SD card or DATALOG export folder"
                    ) {
                        library.load(url)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}
