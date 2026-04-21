import Foundation
import FoundationModels
import Observation

/// Single source of truth for whether Apple Intelligence can be
/// used in this session. Views gate every Intelligence-backed
/// surface on `isReady` and render `EmptyView` when it's false —
/// there is no placeholder UI, by product decision.
///
/// State changes (Apple Intelligence toggled off in Settings, model
/// downloading, low-battery throttle) are picked up by re-probing
/// on app foreground. A Mac with no Apple Intelligence hardware
/// simply reports `isReady == false` forever.
@Observable
@MainActor
public final class IntelligenceAvailability {
    /// UserDefaults key backing the Appearance ▸ Apple Intelligence
    /// toggle. Absent-key default is "on", so existing installs that
    /// had the feature enabled continue to see it after upgrading.
    private static let userEnabledKey = "appleIntelligenceEnabled"

    /// Hardware + OS can run Apple Intelligence on-device.
    /// Independent of the user preference — a Mac without the
    /// supporting hardware reports `isSupported == false` regardless
    /// of what the toggle says.
    public private(set) var isSupported: Bool

    /// User preference, mutated by the Appearance-tab toggle.
    /// Persisted to UserDefaults so it survives relaunches.
    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.userEnabledKey)
        }
    }

    /// Combined gate every Intelligence-backed surface checks —
    /// both the hardware probe and the user's preference must
    /// agree before any AI UI renders.
    public var isReady: Bool {
        isSupported && isEnabled
    }

    public init() {
        let defaults = UserDefaults.standard
        self.isEnabled = (defaults.object(forKey: Self.userEnabledKey) as? Bool) ?? true
        self.isSupported = Self.probe()
    }

    /// Re-evaluate hardware availability. Call from an `NSApplication`
    /// foreground observer (macOS) or `UIApplication.didBecomeActive`
    /// (iOS) so the UI updates cleanly if the user toggled Apple
    /// Intelligence in System Settings while the app was backgrounded.
    public func refresh() {
        isSupported = Self.probe()
    }

    private static func probe() -> Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }
}
