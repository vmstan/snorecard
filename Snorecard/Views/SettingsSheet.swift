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

    @State private var selection: AppIconOption = AppIconController.current

    var body: some View {
        #if os(iOS)
        NavigationStack {
            List {
                appIconSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
                appIconSection
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Settings")
        #endif
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
    private func row(for option: AppIconOption) -> some View {
        let isSelected = option == selection
        Button {
            selection = option
            AppIconController.apply(option)
        } label: {
            HStack(spacing: 14) {
                preview(for: option)
                    .frame(width: 44, height: 44)
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
