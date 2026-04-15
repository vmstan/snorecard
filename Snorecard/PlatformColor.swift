import SwiftUI

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    /// Background tone used by inset cards, chips, and status sheets. Uses
    /// the platform's native "raised-but-subtle" control colour on each OS
    /// so the chrome matches the rest of the system UI.
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
