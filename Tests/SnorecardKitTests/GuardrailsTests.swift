import XCTest
@testable import SnorecardKit

final class GuardrailsTests: XCTestCase {
    func testPlainDescriptionIsAccepted() {
        XCTAssertEqual(
            Guardrails.evaluate("Leak averaged 6 L/min, consistent with last week."),
            .accepted
        )
    }

    func testPrescriptiveModalsAreRejected() {
        let phrases = [
            "You should try a different mask.",
            "You must adjust the pressure.",
            "We recommend lowering EPAP.",
            "You need to tighten the straps."
        ]
        for phrase in phrases {
            let verdict = Guardrails.evaluate(phrase)
            guard case .rejected(.prescriptive, _) = verdict else {
                XCTFail("Expected prescriptive rejection for: \(phrase), got \(verdict)")
                continue
            }
        }
    }

    func testCausalClaimsAreRejected() {
        let phrases = [
            "The alcohol caused the higher AHI.",
            "This leads to more hypopneas.",
            "Because the room was warmer.",
            "The new mask triggered the leak."
        ]
        for phrase in phrases {
            let verdict = Guardrails.evaluate(phrase)
            guard case .rejected(.causal, _) = verdict else {
                XCTFail("Expected causal rejection for: \(phrase), got \(verdict)")
                continue
            }
        }
    }

    func testDiagnosticLanguageIsRejected() {
        let phrases = [
            "This diagnoses as mild apnea.",
            "The prescription should change.",
            "Your dosage is too low."
        ]
        for phrase in phrases {
            let verdict = Guardrails.evaluate(phrase)
            switch verdict {
            case .rejected:
                continue
            case .accepted:
                XCTFail("Expected rejection for: \(phrase)")
            }
        }
    }

    func testDescriptivePastTenseVerbsAreAccepted() {
        // Regression: these used to be rejected because the banlist
        // listed every tense. The card then vanished intermittently
        // because the 3B model naturally narrates with past-tense
        // verbs. Descriptive narration must pass cleanly.
        let phrases = [
            "AHI increased from 2.3 to 3.1.",
            "Leak decreased slightly versus last week.",
            "You tried a different mask on two nights.",
            "Usage was adjusted by the auto-ramp overnight.",
            "Your pressure increased after the first session."
        ]
        for phrase in phrases {
            XCTAssertEqual(
                Guardrails.evaluate(phrase),
                .accepted,
                "Expected accepted for: \(phrase)"
            )
        }
    }

    func testImperativeFormsAreStillRejected() {
        // Bare-verb imperatives are still advisory and must be
        // rejected — the fix is in the word-boundary handling of
        // past-tense forms, not in loosening the policy for
        // instructions directed at the user.
        let phrases = [
            "Try a different mask.",
            "Increase your humidifier.",
            "Decrease the ramp time.",
            "Adjust the pressure band."
        ]
        for phrase in phrases {
            let verdict = Guardrails.evaluate(phrase)
            guard case .rejected(.prescriptive, _) = verdict else {
                XCTFail("Expected prescriptive rejection for: \(phrase), got \(verdict)")
                continue
            }
        }
    }

    func testWordBoundaryDoesNotFalseTrip() {
        // "becoming" contains "because" — shouldn't, but makes a
        // good boundary test. "tryst" contains "try". "adjustment"
        // contains "adjust".
        XCTAssertEqual(
            Guardrails.evaluate("Numbers were nearly identical this week."),
            .accepted
        )
        // Substring match with alphabetic boundary must not hit.
        XCTAssertEqual(
            Guardrails.evaluate("The mustache was irrelevant."),
            .accepted
        )
    }

    func testEvaluateAllShortCircuits() {
        let verdict = Guardrails.evaluateAll([
            "Looks fine.",
            "You should check the mask."
        ])
        guard case .rejected(.prescriptive, let match) = verdict else {
            XCTFail("Expected prescriptive rejection, got \(verdict)")
            return
        }
        XCTAssertEqual(match, "should")
    }
}
