import XCTest
@testable import SnorecardKit

final class UserProfileTests: XCTestCase {
    func testEmptyProfileIsEmpty() {
        XCTAssertTrue(UserProfile.empty.isEmpty)
    }

    func testProfileWithNameIsNotEmpty() {
        var p = UserProfile.empty
        p.name = "Alex"
        XCTAssertFalse(p.isEmpty)
    }

    func testProfileWithBlankNameIsStillEmpty() {
        var p = UserProfile.empty
        p.name = "   "
        XCTAssertTrue(p.isEmpty)
    }

    func testProfileWithDiagnosisDateIsNotEmpty() {
        var p = UserProfile.empty
        p.diagnosisDate = Date()
        XCTAssertFalse(p.isEmpty)
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let profile = UserProfile(
            name: "Alex",
            heightCm: 178,
            weightKg: 80,
            heightSource: .healthKit,
            weightSource: .manual,
            biologicalSex: .female,
            biologicalSexSource: .healthKit,
            dateOfBirth: Date(timeIntervalSince1970: 500_000_000),
            dateOfBirthSource: .healthKit,
            untreatedAHI: 22.4,
            diagnosisDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(UserProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testHeightSourceDefaultsToManual() {
        let profile = UserProfile()
        XCTAssertEqual(profile.heightSource, .manual)
        XCTAssertEqual(profile.weightSource, .manual)
        XCTAssertEqual(profile.biologicalSexSource, .manual)
        XCTAssertEqual(profile.dateOfBirthSource, .manual)
    }

    func testAgeYearsDerivesFromDateOfBirth() {
        var p = UserProfile.empty
        XCTAssertNil(p.ageYears)
        p.dateOfBirth = Calendar.current.date(byAdding: .year, value: -42, to: Date())
        XCTAssertEqual(p.ageYears, 42)
    }

    func testAgeYearsNilsOutForFutureDates() {
        var p = UserProfile.empty
        p.dateOfBirth = Calendar.current.date(byAdding: .year, value: 5, to: Date())
        XCTAssertNil(p.ageYears)
    }

    func testProfileWithBiologicalSexIsNotEmpty() {
        var p = UserProfile.empty
        p.biologicalSex = .male
        XCTAssertFalse(p.isEmpty)
    }

    func testProfileWithDateOfBirthIsNotEmpty() {
        var p = UserProfile.empty
        p.dateOfBirth = Date(timeIntervalSince1970: 500_000_000)
        XCTAssertFalse(p.isEmpty)
    }
}
