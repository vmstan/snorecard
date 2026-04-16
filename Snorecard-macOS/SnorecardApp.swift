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
