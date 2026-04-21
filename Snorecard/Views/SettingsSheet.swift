import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Catalogue of every app-icon the user can switch between. The
/// `assetName` matches the `.icon` package shipped in the bundle
/// (see `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`). The
/// gradient / accent colours approximate each icon's look so the
/// picker shows a recognisable preview without shipping separate
/// thumbnail PNGs.
enum AppIconOption: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case claude = "Claude"
    case inverted = "Inverted"
    case joey = "Joey"
    case oscar = "Oscar"
    case royale = "Royale"
    case sadie = "Sadie"
    case slimer = "Slimer"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// `nil` on the default means "primary app icon". The other
    /// cases map to the alternate-icon asset names in the target.
    var alternateIconName: String? {
        switch self {
        case .default:  return nil
        case .claude:   return "Snorecard-Claude"
        case .inverted: return "Snorecard-Inverted"
        case .joey:     return "Snorecard-Joey"
        case .oscar:    return "Snorecard-Oscar"
        case .royale:   return "Snorecard-Royale"
        case .sadie:    return "Snorecard-Sadie"
        case .slimer:   return "Snorecard-Slimer"
        }
    }

    /// Asset-catalog name of the pre-rendered preview PNG. Lives
    /// in `Assets.xcassets/IconPreview-<Name>.imageset` with the
    /// same 1024×1024 source bitmap the icon was exported from.
    /// Using plain imagesets (not `.icon` packages) gives SwiftUI
    /// a CGImage-backed UIImage/NSImage, so `.resizable()` is safe
    /// on both platforms.
    var previewAssetName: String {
        "IconPreview-\(rawValue)"
    }

}

/// Persists + applies the user's icon selection across app launches.
/// The preference lives in `UserDefaults.standard` under
/// `"selectedAppIcon"`; both platforms read it on app launch and
/// re-apply so the change survives relaunch.
@MainActor
enum AppIconController {
    private static let defaultsKey = "selectedAppIcon"

    static var current: AppIconOption {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
        return AppIconOption(rawValue: raw ?? "") ?? .default
    }

    /// Apply + persist a selection. No-ops when the target is
    /// already active so repeat taps don't churn the system.
    static func apply(_ option: AppIconOption) {
        UserDefaults.standard.set(option.rawValue, forKey: defaultsKey)
        #if canImport(UIKit)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let targetName = option.alternateIconName
        guard app.alternateIconName != targetName else { return }
        app.setAlternateIconName(targetName) { error in
            if let error {
                print("Icon change failed: \(error.localizedDescription)")
            }
        }
        #elseif canImport(AppKit)
        // macOS doesn't expose a public `setAlternateIconName`
        // equivalent. Swap `NSApp.applicationIconImage` at runtime —
        // the Dock picks it up as soon as the app's icon is drawn,
        // and the UserDefaults write above re-applies it on the
        // next launch via `AppIconController.applyStoredOnLaunch()`.
        let image: NSImage? = option.alternateIconName.flatMap { NSImage(named: $0) }
        NSApp.applicationIconImage = image
        #endif
    }

    /// Re-apply whatever the user last picked. Called from the
    /// top-level `SnorecardApp` `.task` so the icon matches the
    /// stored preference after a cold launch.
    static func applyStoredOnLaunch() {
        apply(current)
    }
}

/// Top-level Settings sheet / inspector pane. Currently hosts just
/// the App Icon picker, but structured as a sectioned list so more
/// preference groups can slot in without reshaping the surface.
struct SettingsSheet: View {
    let onClose: () -> Void

    @Environment(Library.self) private var library
    @State private var selection: AppIconOption = AppIconController.current
    /// Draft of the PAP-device alias. Synced from Library on
    /// appear / card change and committed back via `commitDeviceName`
    /// on submit and on dismiss, so the user's edits are trimmed
    /// and persisted without hammering the iCloud store on every
    /// keystroke.
    @State private var deviceNameDraft: String = ""
    /// Serial the draft belongs to — used to re-sync when the
    /// user swaps devices while Settings is open.
    @State private var draftSerial: String?

    private var hasCard: Bool {
        library.card?.identification?.serialNumber != nil
    }

    private var currentSerial: String? {
        library.card?.identification?.serialNumber
    }

    private var currentDefaultName: String {
        library.card?.identification?.productName ?? "ResMed PAP-device"
    }

    private var currentOverride: String? {
        guard let serial = currentSerial else { return nil }
        let value = library.deviceNameOverrides[serial]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            List {
                deviceSection
                appIconSection
                maintenanceSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: syncDeviceDraft)
        .onChange(of: currentSerial) { _, _ in syncDeviceDraft() }
        .onDisappear(perform: commitDeviceName)
        #else
        VStack(alignment: .leading, spacing: 0) {
            InspectorPaneHeader(
                title: "Settings",
                caption: "Preferences that apply across the whole Snorecard app."
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Form {
                deviceSection
                appIconSection
                macOSMaintenanceSection
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Settings")
        .onAppear(perform: syncDeviceDraft)
        .onChange(of: currentSerial) { _, _ in syncDeviceDraft() }
        .onDisappear(perform: commitDeviceName)
        #endif
    }

    @ViewBuilder
    private var deviceSection: some View {
        if hasCard, let serial = currentSerial {
            Section {
                TextField(currentDefaultName, text: $deviceNameDraft)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    #endif
                    .onSubmit(commitDeviceName)
                LabeledContent("Model", value: currentDefaultName)
                LabeledContent("Serial") {
                    Text(serial).monospaced()
                }
                if currentOverride != nil {
                    Button(role: .destructive) {
                        deviceNameDraft = ""
                        library.setDeviceName(nil, for: serial)
                    } label: {
                        #if os(iOS)
                        Text("Use Default Name")
                            .frame(maxWidth: .infinity, alignment: .center)
                        #else
                        Text("Use Default Name")
                        #endif
                    }
                }
            } header: {
                Text("PAP Device")
            } footer: {
                Text("Shown in the sidebar. Syncs between your devices via iCloud.")
            }
        }
    }

    private func syncDeviceDraft() {
        let serial = currentSerial
        if serial != draftSerial {
            draftSerial = serial
            deviceNameDraft = currentOverride ?? ""
        }
    }

    private func commitDeviceName() {
        guard let serial = currentSerial else { return }
        let trimmed = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = library.deviceNameOverrides[serial]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed != stored else { return }
        library.setDeviceName(trimmed.isEmpty ? nil : trimmed, for: serial)
        deviceNameDraft = trimmed
    }

    @ViewBuilder
    private var appIconSection: some View {
        Section("App Icon") {
            ForEach(AppIconOption.allCases) { option in
                row(for: option)
            }
        }
    }

    @ViewBuilder
    private var maintenanceSection: some View {
        Section {
            Button(role: .destructive) {
                NotificationCenter.default.post(
                    name: .snorecardRebuildAnalysis,
                    object: nil
                )
                onClose()
            } label: {
                Text("Rebuild Analysis")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(!hasCard)
        } footer: {
            Text("Rebuilds the cached analysis for this PAP device from the original source data. Useful if the analysis appears stale or incorrect.")
        }
    }

    #if os(macOS)
    /// Two-column Maintenance row on macOS — description + caption
    /// on the leading edge, destructive action on the trailing
    /// edge. Kept inside the `Form` (instead of a sibling below it)
    /// because grouped `Form` + sibling in the same `VStack`
    /// triggers a layout loop in AppKit ("more Update Constraints
    /// in Window passes than there are views"), which hangs then
    /// crashes the app.
    @ViewBuilder
    private var macOSMaintenanceSection: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rebuild Analysis")
                        .font(.callout.weight(.medium))
                    Text("Recompute the statistics for this PAP-device from the original source data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button(role: .destructive) {
                    onClose()
                    NotificationCenter.default.post(
                        name: .snorecardRebuildAnalysis,
                        object: nil
                    )
                } label: {
                    Image(systemName: "hammer")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(!hasCard)
                .help("Rebuild analysis")
            }
            .padding(.vertical, 4)
        } header: {
            Text("Maintenance")
        }
    }
    #endif

    @ViewBuilder
    private func row(for option: AppIconOption) -> some View {
        let isSelected = option == selection
        Button {
            selection = option
            AppIconController.apply(option)
        } label: {
            HStack(spacing: 14) {
                preview(for: option)
                    .frame(width: 18, height: 18)
                Text(option.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func preview(for option: AppIconOption) -> some View {
        // Pre-rendered PNG from the asset catalog. Plain imageset
        // (not a `.icon` package), so SwiftUI's `.resizable()`
        // works cleanly on both platforms.
        Image(option.previewAssetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}
