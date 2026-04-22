#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// Catalogue of every app-icon the user can switch between on iOS.
/// macOS intentionally skips the picker — `NSApp.applicationIconImage`
/// is unreliable for `.icon` packages and the AppKit bridge wasn't
/// worth maintaining for a purely cosmetic feature.
///
/// Each case also carries the two fill colours its `.icon` package
/// uses — the rounded-square background and the waveform foreground —
/// so the picker can render a live SwiftUI preview from the shared
/// vector asset instead of shipping pre-rasterised PNG thumbnails.
/// If a package's fills change, update the tuple to match.
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

    /// Rounded-square background fill, pulled from each `.icon`
    /// package's top-level `fill.solid` colour.
    var backgroundColor: Color {
        switch self {
        case .default:  return Color(.displayP3, red: 0.42107, green: 0.13119, blue: 0.78871)
        case .claude:   return Color(.displayP3, red: 0.91657, green: 0.64250, blue: 0.42990)
        case .inverted: return Color(white: 1)
        case .joey:     return Color(.displayP3, red: 0.80543, green: 0.29125, blue: 0.60434)
        case .oscar:    return Color(.displayP3, red: 0.20471, green: 0.47274, blue: 0.77461)
        case .royale:   return Color(.displayP3, red: 0.41961, green: 0.12941, blue: 0.78824)
        case .sadie:    return Color(.sRGB, red: 1.00000, green: 0.49327, blue: 0.47400)
        case .slimer:   return Color(.sRGB, red: 0.49804, green: 0.78824, blue: 0.12941)
        }
    }

    /// Waveform foreground fill, pulled from the single layer
    /// inside each `.icon` package's `groups[0].layers[0]`.
    var foregroundColor: Color {
        switch self {
        case .inverted: return Color(.displayP3, red: 0.42276, green: 0.13308, blue: 0.78482)
        case .royale:   return Color(.sRGB, red: 1.00000, green: 0.83922, blue: 0.03922)
        default:        return Color(white: 1)
        }
    }
}

/// iOS-only alternate-icon controller. Persists the user's pick in
/// `UserDefaults.standard` under `"selectedAppIcon"` and applies it
/// via `UIApplication.setAlternateIconName` — the one call that has
/// no SwiftUI equivalent.
///
/// Stub methods compile on macOS so callers can invoke them
/// unconditionally, but they're no-ops there since macOS no longer
/// exposes the picker.
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
        #endif
    }

    /// Re-apply whatever the user last picked. Called from the
    /// top-level `SnorecardApp` `.task` so the icon matches the
    /// stored preference after a cold launch.
    static func applyStoredOnLaunch() {
        apply(current)
    }
}

/// SwiftUI-only live preview that recreates an icon at any size by
/// compositing the shared vector waveform over the option's
/// background fill. Replaces the per-icon `IconPreview-*.png`
/// imagesets that used to ship alongside each `.icon` package.
///
/// The vector is stored once in `Assets.xcassets/IconWaveform.imageset`
/// as a template-rendered SVG so `.foregroundStyle` applies the per-
/// option accent. Layout constants match the `.icon` package's
/// declared `scale: 0.8` and `translation-in-points: [0, -60]`
/// against a 1024pt canvas, normalised to the rendered size so the
/// 24pt picker row and a hypothetical larger preview both look right.
struct AppIconPreview: View {
    let option: AppIconOption

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // The .icon spec measures against a 1024pt canvas; its
            // layer translates -60pt downward and scales to 0.8 of
            // the canvas. Convert those constants to the current
            // rendered `side` so the preview looks identical at
            // 24pt (picker row) and any future larger size.
            let canvasToSide = side / 1024
            ZStack {
                option.backgroundColor
                Image("IconWaveform")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(option.foregroundColor)
                    .frame(width: side * 0.8, height: side * 0.8)
                    .offset(y: -60 * canvasToSide)
            }
            .frame(width: side, height: side)
            // Matches the iOS 18 / macOS 15 "continuous" app-icon
            // squircle closely enough for picker-row scale. The
            // ratio is Apple's published 0.2237 × canvas radius.
            .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
