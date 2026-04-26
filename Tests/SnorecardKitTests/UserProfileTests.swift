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

    func testProfileWithEmptyPrescriptionIsStillEmpty() {
        var p = UserProfile.empty
        p.prescription = UserProfilePrescription(mode: .cpap)
        XCTAssertTrue(p.isEmpty,
                      "A prescription with only the default mode and no values shouldn't count as filled.")
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
            prescription: UserProfilePrescription(
                mode: .bipap,
                pressureMin: 9,
                pressureMax: 16,
                pressureSupport: 4,
                notes: "Dr. Lee — ResMed AirCurve 10 VAuto"
            ),
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
    }

    func testPrescriptionHasAnyValueDetectsPopulatedFields() {
        var rx = UserProfilePrescription(mode: .cpap)
        XCTAssertFalse(rx.hasAnyValue)
        rx.pressureMin = 9
        XCTAssertTrue(rx.hasAnyValue)
        rx.pressureMin = nil
        rx.notes = "  "
        XCTAssertFalse(rx.hasAnyValue,
                       "Whitespace-only notes shouldn't count as a populated field.")
        rx.notes = "Auto-titration"
        XCTAssertTrue(rx.hasAnyValue)
    }
}
