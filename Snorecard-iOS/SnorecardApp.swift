import SwiftUI

@main
struct SnorecardApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .task {
                    AppIconController.applyStoredOnLaunch()
                    await library.loadLastOpenedIfPossible()
                }
        }
    }
}
