import SwiftUI
import SnorecardKit

/// Renders an on-device metric explanation. Used on iOS as a
/// sheet at the `ContentView` root, and on macOS as the
/// `.explainMetric` inspector pane — see `ContentView`. Stays
/// data-source agnostic: the `ExplainRequest` carries enough to
/// render the chrome plus a source tag that tells `Library`
/// which resolver to use behind the scenes.
///
/// Hidden affordance when Apple Intelligence is unavailable —
/// the taps that build the request are never wired up on
/// unsupported devices.
struct MetricExplainSheet: View {
    let request: ExplainRequest

    @Environment(Library.self) private var library
    @State private var explanation: MetricExplainOutput?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorPaneHeader(
                    title: {
                        Text(request.displayValue)
                            .monospacedDigit()
                    },
                    caption: request.valueCaption
                )
                Group {
                    if let explanation {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(explanation.whatItMeans)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                            Text(explanation.howYoursLooks)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if failed {
                        Text("An explanation isn't available right now.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        placeholder
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // NED Analysis ships a fixed "How it works" card
                // alongside whatever the on-device model produces —
                // the definitions don't change night-to-night, and
                // the static panel keeps the disclaimer wording
                // verbatim. Shown whether the AI succeeded or not.
                if request.metric == .reraIndex {
                    NEDExplainerCard()
                }
                Spacer(minLength: 8)
                Text("Summary only — not medical advice. Generated using on-device intelligence.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: request.id) {
            await load()
        }
    }

    private var placeholder: some View {
        AIWorkingRow(label: "Preparing an explanation…")
    }

    private func load() async {
        explanation = nil
        failed = false
        let result = await library.resolveExplain(request)
        if result == nil {
            failed = true
        } else {
            explanation = result
        }
    }
}
