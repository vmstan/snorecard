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

    /// Muted colour palette for apnea / hypopnea event markers. Softer
    /// than the primary `.red` / `.yellow` / `.purple` so stacked bars
    /// and timeline overlays don't look harsh.
    static let eventObstructive = Color(red: 0.85, green: 0.42, blue: 0.42)
    static let eventHypopnea    = Color(red: 0.92, green: 0.75, blue: 0.35)
    static let eventCentral     = Color(red: 0.62, green: 0.52, blue: 0.82)

    /// Neutral-by-default session bar for the day timeline so the
    /// coloured event markers and viewport indicator remain legible
    /// against it.
    static let timelineSessionFill = Color.secondary.opacity(0.28)
    static let timelineViewportFill = Color.accentColor.opacity(0.38)
    static let timelineViewportEdge = Color.accentColor
}
