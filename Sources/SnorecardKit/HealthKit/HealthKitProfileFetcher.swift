import Foundation
import os.log
#if canImport(HealthKit)
import HealthKit
#endif

/// Read-only fetcher for the Apple Health fields that map onto
/// Snorecard's user profile — height, body mass, biological sex,
/// and date of birth. Apple HealthKit doesn't expose the Medical-
/// ID name to third-party apps so name stays manual.
///
/// The protocol stays HealthKit-free so a mock can drop in for
/// tests without `import HealthKit`.
public protocol ProfileFetching: Sendable {
    /// Ask the user for read access to bodyMass, height, biological
    /// sex, and date of birth, then fetch the most recent sample /
    /// characteristic of each. Returns metric values regardless of
    /// the user's display unit preference — Apple Health stores in
    /// metric internally.
    func fetchProfile() async throws -> ProfileFetchResult
}

/// Result bundle for `ProfileFetching.fetchProfile`. Every field is
/// independently optional so a user with weight in Health but no
/// height (or no Medical-ID date-of-birth) still gets a usable
/// import.
public struct ProfileFetchResult: Sendable, Equatable {
    public let heightCm: Double?
    public let weightKg: Double?
    public let biologicalSex: BiologicalSex?
    public let dateOfBirth: Date?

    public init(
        heightCm: Double?,
        weightKg: Double?,
        biologicalSex: BiologicalSex? = nil,
        dateOfBirth: Date? = nil
    ) {
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.biologicalSex = biologicalSex
        self.dateOfBirth = dateOfBirth
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
        let sexType = HKCharacteristicType(.biologicalSex)
        let dobType = HKCharacteristicType(.dateOfBirth)
        do {
            try await store.requestAuthorization(
                toShare: [],
                read: [height, mass, sexType, dobType]
            )
        } catch {
            throw HealthKitSleepError.framework(String(describing: error))
        }
        async let heightCm = latestSample(of: height, unit: .meterUnit(with: .centi))
        async let weightKg = latestSample(of: mass, unit: .gramUnit(with: .kilo))
        let h = await heightCm
        let w = await weightKg
        let sex = readBiologicalSex()
        let dob = readDateOfBirth()
        healthKitLog.debug(
            "fetchProfile heightCm=\(h ?? -1, privacy: .public) weightKg=\(w ?? -1, privacy: .public) sex=\(sex?.rawValue ?? "nil", privacy: .public) dob=\(dob?.description ?? "nil", privacy: .public)"
        )
        return ProfileFetchResult(
            heightCm: h,
            weightKg: w,
            biologicalSex: sex,
            dateOfBirth: dob
        )
    }

    /// Read the Medical-ID biological-sex characteristic. Returns
    /// `nil` when the user hasn't filled it in (or denied access);
    /// HealthKit's `notSet` collapses into `nil` so callers don't
    /// have to special-case it.
    private func readBiologicalSex() -> BiologicalSex? {
        do {
            let object = try store.biologicalSex()
            switch object.biologicalSex {
            case .notSet: return nil
            case .female: return .female
            case .male:   return .male
            case .other:  return .other
            @unknown default: return nil
            }
        } catch {
            healthKitLog.error(
                "biologicalSex read failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Read the Medical-ID date-of-birth characteristic. HealthKit
    /// returns calendar `DateComponents`; resolve them through the
    /// current calendar so we end up with a `Date` at midnight on
    /// the user's birthday.
    private func readDateOfBirth() -> Date? {
        do {
            let components = try store.dateOfBirthComponents()
            return Calendar(identifier: components.calendar?.identifier ?? .gregorian)
                .date(from: components)
        } catch {
            healthKitLog.error(
                "dateOfBirth read failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
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
