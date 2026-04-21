import AppKit

/// Quit the app when the user closes its only window. Standard macOS
/// behavior leaves the process running in the Dock — not what a
/// single-window data viewer like Snorecard should do.
///
/// This is the only AppKit-backed type in the macOS target. SwiftUI
/// has no scene-level API for quit-on-last-window-close, so an
/// `NSApplicationDelegate` shim is the minimum-viable bridge.
final class SnorecardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
