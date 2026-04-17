import SwiftUI
import UIKit

@main
struct SnorecardApp: App {
    @State private var library = Library()

    init() {
        // Bump UINavigationBar's subtitle font slightly so the
        // device name reads at a comfortable size under the
        // large "Snorecard" title — the system default is a bit
        // small once paired with the large title style. Applied
        // globally because every nav bar in the app is the
        // system one.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeSubtitleTextAttributes = [
            .font: UIFont.preferredFont(forTextStyle: .body)
        ]
        appearance.subtitleTextAttributes = [
            .font: UIFont.preferredFont(forTextStyle: .subheadline)
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .task {
                    library.loadLastOpenedIfPossible()
                }
        }
    }
}
