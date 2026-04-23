import Foundation

/// Qualitative whole-night snoring classification, derived from the
/// fraction of on-therapy time the ResMed `Snore` signal spent in
/// each ResScan-icon band. The raw 0–5 number the machine emits is
/// a proprietary vibration score with no acoustic calibration, so a
/// single numeric value isn't directly meaningful to a reader. The
/// band thresholds come from OSCAR's documentation of the ResScan
/// icons: 1.5 = moderately loud, 3.0 = loud, >3.0 = off-scale.
public enum SnoreLevel: String, Sendable, Equatable {
    case quiet
    case mild
    case moderate
    case loud

    /// Short human label for the stat card primary value.
    public var label: String {
        switch self {
        case .quiet:    return "Quiet"
        case .mild:     return "Mild"
        case .moderate: return "Moderate"
        case .loud:     return "Loud"
        }
    }

    /// Classify the night given time spent in each band and total
    /// on-therapy seconds. Returns `nil` when the night had no
    /// snore samples (older firmware, STR-only days).
    public static func classify(
        moderateSeconds: Double?,
        loudSeconds: Double?,
        usageSeconds: Double
    ) -> SnoreLevel? {
        guard let moderate = moderateSeconds,
              let loud = loudSeconds,
              usageSeconds > 0 else { return nil }
        let loudPct = loud / usageSeconds * 100
        let modPct = moderate / usageSeconds * 100
        // Tiers chosen to match how the night reads on an
        // OSCAR-style snore plot: sustained off-scale snoring
        // dominates a night; occasional spikes or a lot of
        // moderately loud time pushes the label up a notch.
        if loudPct >= 5 { return .loud }
        if loudPct >= 1 || modPct >= 20 { return .moderate }
        if modPct >= 5 { return .mild }
        return .quiet
    }

    /// Short subtitle for the stat card — shows the most
    /// informative band percentage. Returns `nil` when the night
    /// was effectively silent and no figure adds information.
    public static func subtitle(
        moderateSeconds: Double?,
        loudSeconds: Double?,
        usageSeconds: Double
    ) -> String? {
        guard let moderate = moderateSeconds,
              let loud = loudSeconds,
              usageSeconds > 0 else { return nil }
        let loudPct = loud / usageSeconds * 100
        let modPct = moderate / usageSeconds * 100
        if loudPct >= 1 {
            return String(format: "%.0f%% loud", loudPct)
        }
        if modPct >= 1 {
            return String(format: "%.0f%% moderate", modPct)
        }
        return nil
    }
}
