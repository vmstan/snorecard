#if os(macOS)
import SwiftUI
import AppKit

/// Drops into a SwiftUI window to disable the minimize and zoom
/// traffic-light buttons, leaving only the red close button
/// active. Used by the Backups and Rename Device floating
/// windows so they read like Spotlight-style accessory panels:
/// you open them, do the thing, close them.
///
/// Implementation note — the only reliable way to toggle the
/// title-bar buttons on a SwiftUI-managed `NSWindow` is to grab
/// the host window from a representable on the view tree. The
/// dispatch async lets the window finish initialising before
/// we adjust its standard window buttons.
struct WindowControlAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Attach the window-button accessor to any SwiftUI view
    /// that's hosted inside a separate window on macOS.
    func disableNonCloseWindowButtons() -> some View {
        self.background(WindowControlAccessor())
    }
}
#endif
