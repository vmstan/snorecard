import Foundation
import FoundationModels
import os.log

private let log = Logger(subsystem: "com.vmstan.Snorecard", category: "Narration")

/// Errors raised during on-device generation. `unavailable` is
/// thrown by `NoOpNarrationService` when a call sneaks through
/// without the caller first checking `IntelligenceAvailability`.
/// `rejected` is thrown when `Guardrails` refuses the output —
/// callers should treat it the same as `unavailable` and hide the
/// surface.
public enum NarrationError: Error, Sendable, Equatable {
    case unavailable
    case rejected(Guardrails.Violation, match: String)
    case sessionFailed(String)
}

/// Abstract boundary for every Apple-Intelligence-backed narration
/// feature in Snorecard. A real implementation hits
/// `LanguageModelSession`; a test stub returns fixed structs; a
/// no-op (for unsupported devices) throws `unavailable`.
public protocol NarrationService: Sendable {
    func nightSummary(_ input: NightSummaryInput) async throws -> NightSummaryOutput
    func overviewNarrative(_ input: OverviewNarrativeInput) async throws -> OverviewNarrativeOutput
    func explainMetric(_ input: MetricExplainInput) async throws -> MetricExplainOutput
    func extractNoteTags(_ input: NoteTagInput) async throws -> NoteTagsOutput
    func correlationNarrative(_ input: CorrelationNarrativeInput) async throws -> CorrelationNarrativeOutput
}

/// Default implementation that drives the on-device Foundation
/// Models session. Every call builds a fresh `LanguageModelSession`
/// keyed on the feature's system instructions — we don't reuse
/// sessions across features because the system instructions differ
/// enough that reuse would leak persona between surfaces.
///
/// Guardrails run on every output field before the value returns
/// to the caller. A failed verdict is thrown as
/// `NarrationError.rejected`; the call site catches and hides its
/// surface.
public struct FoundationNarrationService: NarrationService {
    public init() {}

    public func nightSummary(
        _ input: NightSummaryInput
    ) async throws -> NightSummaryOutput {
        let session = LanguageModelSession(
            instructions: Instructions(NightSummaryPrompt.systemInstructions)
        )
        let prompt = NightSummaryPrompt.buildPrompt(input: input)
        do {
            let response = try await session.respond(
                to: Prompt(prompt),
                generating: NightSummaryOutput.self
            )
            let output = response.content
            try enforce(Guardrails.evaluateAll([output.headline, output.paragraph]))
            return output
        } catch is CancellationError {
            // Task cancellation is expected when the user navigates
            // between days mid-generation — re-throw silently
            // rather than logging as a session failure.
            throw CancellationError()
        } catch let error as NarrationError {
            throw error
        } catch {
            log.error("nightSummary session failed: \(String(describing: error), privacy: .public)")
            throw NarrationError.sessionFailed(String(describing: error))
        }
    }

    public func overviewNarrative(
        _ input: OverviewNarrativeInput
    ) async throws -> OverviewNarrativeOutput {
        let session = LanguageModelSession(
            instructions: Instructions(OverviewNarrativePrompt.systemInstructions)
        )
        let prompt = OverviewNarrativePrompt.buildPrompt(input: input)
        do {
            let response = try await session.respond(
                to: Prompt(prompt),
                generating: OverviewNarrativeOutput.self
            )
            let output = response.content
            try enforce(Guardrails.evaluateAll(
                [output.paragraph, output.highlight ?? ""].filter { !$0.isEmpty }
            ))
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NarrationError {
            throw error
        } catch {
            log.error("overviewNarrative session failed: \(String(describing: error), privacy: .public)")
            throw NarrationError.sessionFailed(String(describing: error))
        }
    }

    public func explainMetric(
        _ input: MetricExplainInput
    ) async throws -> MetricExplainOutput {
        let session = LanguageModelSession(
            instructions: Instructions(MetricExplainPrompt.systemInstructions)
        )
        let prompt = MetricExplainPrompt.buildPrompt(input: input)
        do {
            let response = try await session.respond(
                to: Prompt(prompt),
                generating: MetricExplainOutput.self
            )
            let output = response.content
            try enforce(Guardrails.evaluateAll([output.whatItMeans, output.howYoursLooks]))
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NarrationError {
            throw error
        } catch {
            log.error("explainMetric session failed: \(String(describing: error), privacy: .public)")
            throw NarrationError.sessionFailed(String(describing: error))
        }
    }

    public func extractNoteTags(
        _ input: NoteTagInput
    ) async throws -> NoteTagsOutput {
        let session = LanguageModelSession(
            instructions: Instructions(NoteTagExtractionPrompt.systemInstructions)
        )
        let prompt = NoteTagExtractionPrompt.buildPrompt(input: input)
        do {
            let response = try await session.respond(
                to: Prompt(prompt),
                generating: NoteTagsOutput.self
            )
            let tags = Array(response.content.tags.prefix(NoteTagTaxonomy.maxTagsPerNote))
            return NoteTagsOutput(tags: tags)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("extractNoteTags session failed: \(String(describing: error), privacy: .public)")
            throw NarrationError.sessionFailed(String(describing: error))
        }
    }

    public func correlationNarrative(
        _ input: CorrelationNarrativeInput
    ) async throws -> CorrelationNarrativeOutput {
        let session = LanguageModelSession(
            instructions: Instructions(CorrelationNarrativePrompt.systemInstructions)
        )
        let prompt = CorrelationNarrativePrompt.buildPrompt(input: input)
        do {
            let response = try await session.respond(
                to: Prompt(prompt),
                generating: CorrelationNarrativeOutput.self
            )
            let output = response.content
            try enforce(Guardrails.evaluateAll([output.intro] + output.bullets))
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NarrationError {
            throw error
        } catch {
            log.error("correlationNarrative session failed: \(String(describing: error), privacy: .public)")
            throw NarrationError.sessionFailed(String(describing: error))
        }
    }

    private func enforce(_ verdict: Guardrails.Verdict) throws {
        if case let .rejected(violation, match) = verdict {
            log.info("Guardrail rejected output: \(violation.rawValue, privacy: .public) match=\(match, privacy: .public)")
            throw NarrationError.rejected(violation, match: match)
        }
    }
}

/// Used when Apple Intelligence is unavailable on this device, so
/// every feature view gates on `IntelligenceAvailability.isReady`
/// first and never reaches this object. Having a non-optional
/// service keeps call sites free of optional chaining.
public struct NoOpNarrationService: NarrationService {
    public init() {}

    public func nightSummary(_ input: NightSummaryInput) async throws -> NightSummaryOutput {
        throw NarrationError.unavailable
    }

    public func overviewNarrative(_ input: OverviewNarrativeInput) async throws -> OverviewNarrativeOutput {
        throw NarrationError.unavailable
    }

    public func explainMetric(_ input: MetricExplainInput) async throws -> MetricExplainOutput {
        throw NarrationError.unavailable
    }

    public func extractNoteTags(_ input: NoteTagInput) async throws -> NoteTagsOutput {
        throw NarrationError.unavailable
    }

    public func correlationNarrative(_ input: CorrelationNarrativeInput) async throws -> CorrelationNarrativeOutput {
        throw NarrationError.unavailable
    }
}
