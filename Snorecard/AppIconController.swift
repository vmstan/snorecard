#if canImport(UIKit)
import UIKit

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
    var previewAssetName: String {
        "IconPreview-\(rawValue)"
    }
}

/// Persists + applies the user's icon selection across app launches.
/// The preference lives in `UserDefaults.standard` under
/// `"selectedAppIcon"`; both platforms read it on app launch and
/// re-apply so the change survives relaunch.
///
/// iOS only. macOS has no public API equivalent — swapping
/// `NSApp.applicationIconImage` at runtime changes the Dock icon
/// only while the process is alive and reverts the moment the app
/// quits, so the feature isn't offered on that platform.
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
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let targetName = option.alternateIconName
        guard app.alternateIconName != targetName else { return }
        app.setAlternateIconName(targetName) { error in
            if let error {
                print("Icon change failed: \(error.localizedDescription)")
            }
        }
    }

    /// Re-apply whatever the user last picked. Called from the
    /// top-level `SnorecardApp` `.task` so the icon matches the
    /// stored preference after a cold launch.
    static func applyStoredOnLaunch() {
        apply(current)
    }
}
#endif
