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
    public private(set) var isReady: Bool

    public init() {
        self.isReady = Self.probe()
    }

    /// Re-evaluate availability. Call from an `NSApplication`
    /// foreground observer (macOS) or `UIApplication.didBecomeActive`
    /// (iOS) so the UI updates cleanly if the user toggled Apple
    /// Intelligence while the app was backgrounded.
    public func refresh() {
        isReady = Self.probe()
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
