import Foundation

/// What we can tell about HealthKit access right now.
///
/// Apple deliberately hides read-grant status — `authorizationStatus(for:)`
/// always returns `.sharingAuthorized` for read-only types whether or not
/// the user actually granted the prompt. That's why there's no
/// `sharingAuthorized` case here: the only honest signal we have is "we
/// asked, the system returned, and the user has either let samples
/// through or hasn't." Empty results across many recent days are a
/// soft hint to surface in the UI, never a hard "denied" claim.
public enum HealthKitAuthState: String, Codable, Sendable, Equatable {
    /// The platform doesn't expose Health data on this device
    /// (`HKHealthStore.isHealthDataAvailable() == false`).
    case unsupported
    /// We haven't asked the system yet this session.
    case notDetermined
    /// We've called `requestAuthorization`. The system has responded;
    /// the user may or may not have granted read access.
    case requested
}
