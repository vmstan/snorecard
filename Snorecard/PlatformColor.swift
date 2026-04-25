import SwiftUI

extension Color {
    /// Event marker colours used by non-palette-aware views (the
    /// waveform section, session timeline) for OA / H / CA bars.
    /// Darker and more saturated than a purely muted set so stacked
    /// bars and timeline overlays clear ≥3:1 non-text contrast on
    /// both light and dark chart backgrounds. The palette-aware
    /// views (event donut, Trends charts) route through
    /// `EventColorPalette` instead.
    static let eventObstructive = Color(red: 0.72, green: 0.20, blue: 0.20)
    static let eventHypopnea    = Color(red: 0.78, green: 0.52, blue: 0.08)
    static let eventCentral     = Color(red: 0.18, green: 0.38, blue: 0.72)

    /// Neutral-by-default session bar for the day timeline so the
    /// coloured event markers and viewport indicator remain legible
    /// against it.
    static let timelineSessionFill = Color.secondary.opacity(0.28)
    static let timelineViewportFill = Color.accentColor.opacity(0.38)
    static let timelineViewportEdge = Color.accentColor

    /// Severity palette for AHI / leak / flow-limit / Glasgow bands.
    /// Pitched for WCAG AA as card backgrounds (≥4.5:1 when the
    /// tinted plate lands under primary text), keeping the same
    /// good/amber/red semantics as the system palette.
    static let severityGood   = Color(red: 0.22, green: 0.55, blue: 0.30)
    static let severityLow    = Color(red: 0.78, green: 0.52, blue: 0.08)
    static let severityMedium = Color(red: 0.80, green: 0.42, blue: 0.08)
    static let severityHigh   = Color(red: 0.72, green: 0.20, blue: 0.20)

    /// Chart series palette for the default theme. Each hue lands at
    /// ≥3:1 non-text contrast against a white chart background so
    /// the series stay legible for colour-contrast users. Values
    /// that pair with severity / event colours (chartBlue =
    /// eventCentral, chartOrange = severityMedium, chartGreen =
    /// severityGood) are kept identical so the same "blue CA" /
    /// "green good" identities hold across every chart.
    static let chartTeal   = Color(red: 0.12, green: 0.52, blue: 0.58)
    static let chartBlue   = Color(red: 0.18, green: 0.38, blue: 0.72)
    static let chartOrange = Color(red: 0.80, green: 0.42, blue: 0.08)
    static let chartPink   = Color(red: 0.72, green: 0.24, blue: 0.52)
    static let chartMint   = Color(red: 0.18, green: 0.58, blue: 0.48)
    static let chartIndigo = Color(red: 0.30, green: 0.30, blue: 0.68)
    static let chartGreen  = Color(red: 0.22, green: 0.55, blue: 0.30)
    /// Soft version of the accent used for Usage bars so compliant
    /// and non-compliant nights remain distinguishable without vivid
    /// saturation.
    static let chartUsageStrong = Color.accentColor.opacity(0.75)
    static let chartUsageWeak   = Color.accentColor.opacity(0.3)
}

extension EventColorPalette {
    /// Colour for obstructive-apnea markers in this palette.
    var obstructive: Color {
        switch self {
        case .topher: return Color(red: 1.000, green: 0.322, blue: 0.251)
        case .nick:   return Color(red: 0.988, green: 0.824, blue: 0.447)
        case .oscar:  return Color(red: 0.000, green: 0.757, blue: 1.000)
        }
    }

    /// Colour for hypopnea markers in this palette.
    var hypopnea: Color {
        switch self {
        case .topher: return Color(red: 0.216, green: 0.651, blue: 0.553)
        case .nick:   return Color(red: 0.757, green: 0.682, blue: 0.984)
        case .oscar:  return Color(red: 0.173, green: 0.000, blue: 1.000)
        }
    }

    /// Colour for central-apnea markers in this palette.
    var central: Color {
        switch self {
        case .topher: return Color(red: 0.251, green: 0.451, blue: 0.918)
        case .nick:   return Color(red: 0.490, green: 0.882, blue: 0.718)
        case .oscar:  return Color(red: 0.537, green: 0.000, blue: 0.522)
        }
    }

    // MARK: - Trend / hourly chart slots
    //
    // These extend the three event colours into a full themed palette
    // for every chart on the Trends pane and the Daily overview's
    // hourly panels. Each preset picks hues that sit in the same
    // visual family as its OA / H / CA colours so a theme reads as
    // one set across the whole app.

    /// Median mask pressure line — paired with `pressureP95` on the
    /// Trends two-line chart, so the two must stay distinguishable.
    var pressureMedian: Color {
        switch self {
        case .topher: return Color(red: 0.349, green: 0.337, blue: 0.839)
        case .nick:   return Color(red: 0.694, green: 0.831, blue: 0.969)
        case .oscar:  return Color(red: 0.000, green: 0.749, blue: 0.800)
        }
    }

    /// 95th-percentile mask pressure line — second series on the
    /// Trends pressure chart.
    var pressureP95: Color {
        switch self {
        case .topher: return Color(red: 1.000, green: 0.584, blue: 0.000)
        case .nick:   return Color(red: 1.000, green: 0.780, blue: 0.639)
        case .oscar:  return Color(red: 0.902, green: 0.200, blue: 0.651)
        }
    }

    /// Flow Limitation trend + hourly bars.
    var flowLimit: Color {
        switch self {
        case .topher: return Color(red: 1.000, green: 0.176, blue: 0.333)
        case .nick:   return Color(red: 0.980, green: 0.757, blue: 0.851)
        case .oscar:  return Color(red: 1.000, green: 0.549, blue: 0.000)
        }
    }

    /// Mask Leak trend + hourly bars.
    var leak: Color {
        switch self {
        case .topher: return Color(red: 0.353, green: 0.784, blue: 0.980)
        case .nick:   return Color(red: 0.718, green: 0.922, blue: 0.906)
        case .oscar:  return Color(red: 0.549, green: 0.000, blue: 1.000)
        }
    }

    /// Glasgow Index trend line + per-night breakdown bars.
    var glasgowIndex: Color {
        switch self {
        case .topher: return Color(red: 0.196, green: 0.843, blue: 0.294)
        case .nick:   return Color(red: 0.780, green: 0.875, blue: 0.690)
        case .oscar:  return Color(red: 0.502, green: 0.902, blue: 0.149)
        }
    }

    /// Tidal Volume trend + hourly line.
    var tidalVolume: Color {
        switch self {
        case .topher: return Color(red: 0.686, green: 0.322, blue: 0.871)
        case .nick:   return Color(red: 0.792, green: 0.722, blue: 0.910)
        case .oscar:  return Color(red: 1.000, green: 0.851, blue: 0.102)
        }
    }

    // MARK: - Themed severity slots
    //
    // The Trends page surfaces three charts whose threshold bands are
    // directional (good / watch / bad) but not clinical in the way
    // the stat-card tints are — the AHI bar chart, Usage bars, and
    // Large Leak bars. These slots let those charts keep their band
    // structure while adapting to the active palette so the Trends
    // page reads as one themed set. Global `Color.severityX` is
    // still used by the stat-card tints elsewhere in the app.

    /// Lowest severity band — green/mint family per theme.
    var severityGood: Color {
        switch self {
        case .topher: return Color(red: 0.196, green: 0.843, blue: 0.294)
        case .nick:   return Color(red: 0.718, green: 0.898, blue: 0.780)
        case .oscar:  return Color(red: 0.200, green: 0.902, blue: 0.502)
        }
    }

    /// Mid-low severity band — yellow/cream family per theme.
    var severityLow: Color {
        switch self {
        case .topher: return Color(red: 1.000, green: 0.800, blue: 0.000)
        case .nick:   return Color(red: 1.000, green: 0.878, blue: 0.639)
        case .oscar:  return Color(red: 1.000, green: 0.851, blue: 0.102)
        }
    }

    /// Mid-high severity band — orange family per theme.
    var severityMedium: Color {
        switch self {
        case .topher: return Color(red: 1.000, green: 0.584, blue: 0.000)
        case .nick:   return Color(red: 1.000, green: 0.780, blue: 0.639)
        case .oscar:  return Color(red: 1.000, green: 0.549, blue: 0.000)
        }
    }

    /// Highest severity band — red/coral family per theme.
    var severityHigh: Color {
        switch self {
        case .topher: return Color(red: 1.000, green: 0.231, blue: 0.188)
        case .nick:   return Color(red: 0.988, green: 0.600, blue: 0.600)
        case .oscar:  return Color(red: 1.000, green: 0.200, blue: 0.100)
        }
    }

    // MARK: - Apple Watch sleep stages
    //
    // Each theme picks one hue family for the sleep-stage trio so
    // Deep, Core, and REM read as variants of the same colour
    // rather than three unrelated chips. Deep is the anchor (the
    // most saturated / darkest); Core sits one step lighter; REM
    // sits one step lighter still. Awake doesn't have a slot —
    // the timeline filters it out, and the legend below the chart
    // never lists it.

    /// Deep-sleep anchor colour for this palette. Oscar's deep
    /// shade matches its CA event colour (magenta-purple) so the
    /// chart and the donut reuse the same hue identity; the other
    /// themes pick a complementary indigo/lavender family.
    var deepSleep: Color {
        switch self {
        case .topher: return Color(red: 0.220, green: 0.090, blue: 0.694)
        case .nick:   return Color(red: 0.471, green: 0.443, blue: 0.690)
        case .oscar:  return Color(red: 0.537, green: 0.000, blue: 0.522)
        }
    }

    /// Core-sleep colour — the same hue as `deepSleep` lightened.
    var coreSleep: Color {
        switch self {
        case .topher: return Color(red: 0.420, green: 0.290, blue: 0.831)
        case .nick:   return Color(red: 0.671, green: 0.643, blue: 0.835)
        case .oscar:  return Color(red: 0.722, green: 0.314, blue: 0.706)
        }
    }

    /// REM-sleep colour — `deepSleep` lightened one step further.
    var remSleep: Color {
        switch self {
        case .topher: return Color(red: 0.624, green: 0.541, blue: 0.910)
        case .nick:   return Color(red: 0.831, green: 0.816, blue: 0.945)
        case .oscar:  return Color(red: 0.875, green: 0.604, blue: 0.867)
        }
    }
}
