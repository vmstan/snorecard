import SwiftUI

/// About tab for the Settings surface. Shows the app icon, name,
/// version/build from the bundle, a short tagline, and links the
/// user to the source repository and attribution for the Glasgow
/// Index algorithm we depend on. Matches the `.formStyle(.grouped)`
/// idiom used by every other Settings tab so the macOS tab-bar and
/// iOS NavigationStack push both land on a consistent surface.
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    AppIconPreview(option: AppIconController.current)
                        .frame(width: 96, height: 96)
                    Text("Snorecard")
                        .font(.title2.weight(.semibold))
                    Text(versionLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("A local-first ResMed CPAP viewer for macOS and iOS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: URL(string: "https://github.com/vmstan/snorecard")!) {
                    LabeledContent("Source Code", value: "github.com/vmstan/snorecard")
                }
                Link(destination: URL(string: "https://github.com/vmstan/snorecard/issues")!) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }
            } header: {
                Text("Project")
            }

            Section {
                Link(destination: URL(string: "https://github.com/DaveSkvn/GlasgowIndex")!) {
                    LabeledContent("Glasgow Index", value: "DaveSkvn")
                }
                Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=Tamisier+CPAP+flow+limitation")!) {
                    LabeledContent("NED Analysis", value: "Tamisier et al.")
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("Snorecard uses the open-source Glasgow Index algorithm for sleep-quality scoring and the NED (Negative Effort Dependence) concept from Tamisier et al. for per-breath flow-limitation analysis. RERA detection is Snorecard's interpretation of AASM scoring criteria — informational, not a validated diagnostic.")
            }

            Section {
                LabeledContent("Copyright", value: copyrightLine)
            }
        }
        .formStyle(.grouped)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (Build \(build))"
    }

    private var copyrightLine: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "© 2026"
    }
}
