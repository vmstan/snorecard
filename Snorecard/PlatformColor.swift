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

    /// Muted severity palette for AHI values — softer replacements for
    /// the system `.green`/`.yellow`/`.orange`/`.red` so bar charts
    /// don't look harsh.
    static let severityGood   = Color(red: 0.55, green: 0.78, blue: 0.58)
    static let severityLow    = Color(red: 0.92, green: 0.75, blue: 0.35)
    static let severityMedium = Color(red: 0.92, green: 0.60, blue: 0.35)
    static let severityHigh   = Color(red: 0.85, green: 0.42, blue: 0.42)

    /// Muted chart series colours used across the Overview trend charts.
    static let chartTeal   = Color(red: 0.38, green: 0.70, blue: 0.72)
    static let chartBlue   = Color(red: 0.42, green: 0.60, blue: 0.82)
    static let chartOrange = Color(red: 0.92, green: 0.60, blue: 0.35)
    static let chartPink   = Color(red: 0.86, green: 0.55, blue: 0.70)
    static let chartMint   = Color(red: 0.50, green: 0.78, blue: 0.72)
    static let chartIndigo = Color(red: 0.55, green: 0.55, blue: 0.80)
    /// Soft version of the accent used for Usage bars so compliant
    /// and non-compliant nights remain distinguishable without vivid
    /// saturation.
    static let chartUsageStrong = Color.accentColor.opacity(0.75)
    static let chartUsageWeak   = Color.accentColor.opacity(0.3)
}
