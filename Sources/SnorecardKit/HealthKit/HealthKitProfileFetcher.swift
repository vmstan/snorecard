import Foundation
import os.log
#if canImport(HealthKit)
import HealthKit
#endif

/// Read-only fetcher for the small handful of Apple Health fields
/// that map onto Snorecard's user profile (height + body mass).
/// Apple HealthKit doesn't expose the Medical-ID name to third-
/// party apps so name stays manual; date-of-birth / biological
/// sex aren't surfaced today either, though they could be added
/// later via `HKCharacteristicType` if the profile grows.
///
/// The protocol stays HealthKit-free so a mock can drop in for
/// tests without `import HealthKit`.
public protocol ProfileFetching: Sendable {
    /// Ask the user for read access to bodyMass + height, then
    /// fetch the most recent sample of each. Returns metric values
    /// regardless of the user's display unit preference — Apple
    /// Health stores in metric internally.
    func fetchProfile() async throws -> ProfileFetchResult
}

/// Result bundle for `ProfileFetching.fetchProfile`. Both fields
/// are independently optional so a user with weight in Health but
/// no height (or vice versa) still gets a usable import.
public struct ProfileFetchResult: Sendable, Equatable {
    public let heightCm: Double?
    public let weightKg: Double?

    public init(heightCm: Double?, weightKg: Double?) {
        self.heightCm = heightCm
        self.weightKg = weightKg
    }
}

#if canImport(HealthKit)

/// Production fetcher. iOS only in practice — macOS HealthKit
/// reads of bodyMass / height work in principle (both types sync
/// over iCloud Health) but Library wires this up only on iOS to
/// match the read-only-on-Mac story for the rest of the
/// HealthKit feature surface.
public actor HealthKitProfileFetcher: ProfileFetching {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func fetchProfile() async throws -> ProfileFetchResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSleepError.unsupported
        }
        let height = HKQuantityType(.height)
        let mass = HKQuantityType(.bodyMass)
        do {
            try await store.requestAuthorization(
                toShare: [],
                read: [height, mass]
            )
        } catch {
            throw HealthKitSleepError.framework(String(describing: error))
        }
        async let heightCm = latestSample(of: height, unit: .meterUnit(with: .centi))
        async let weightKg = latestSample(of: mass, unit: .gramUnit(with: .kilo))
        let h = await heightCm
        let w = await weightKg
        healthKitLog.debug(
            "fetchProfile heightCm=\(h ?? -1, privacy: .public) weightKg=\(w ?? -1, privacy: .public)"
        )
        return ProfileFetchResult(heightCm: h, weightKg: w)
    }

    /// Fetch the single most recent sample for `type`, expressed
    /// in `unit`. Returns `nil` when nothing is on file or the
    /// query throws (the typed-predicate composition gap that bit
    /// us for sleep analysis doesn't apply here — this query has
    /// no date filter and a hard limit of 1, so the wrapper is
    /// straightforward).
    private func latestSample(
        of type: HKQuantityType,
        unit: HKUnit
    ) async -> Double? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 1
        )
        do {
            let samples = try await descriptor.result(for: store)
            guard let sample = samples.first else { return nil }
            return sample.quantity.doubleValue(for: unit)
        } catch {
            healthKitLog.error(
                "latestSample(\(type.identifier, privacy: .public)) failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}

#endif
