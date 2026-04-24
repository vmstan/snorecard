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
    case callan = "Callan"
    case charlie = "Charlie"
    case claude = "Claude"
    case inverted = "Inverted"
    case joey = "Joey"
    case oscar = "Oscar"
    case royale = "Royale"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// `nil` on the default means "primary app icon". The other
    /// cases map to the alternate-icon asset names in the target.
    var alternateIconName: String? {
        switch self {
        case .default:  return nil
        case .callan:   return "Snorecard-Callan"
        case .charlie:  return "Snorecard-Charlie"
        case .claude:   return "Snorecard-Claude"
        case .inverted: return "Snorecard-Inverted"
        case .joey:     return "Snorecard-Joey"
        case .oscar:    return "Snorecard-Oscar"
        case .royale:   return "Snorecard-Royale"
        }
    }

    /// Rounded-square background fill, pulled from each `.icon`
    /// package's top-level `fill.solid` colour.
    var backgroundColor: Color {
        switch self {
        case .default:  return Color(.displayP3, red: 0.58824, green: 0.23922, blue: 0.59216)
        case .callan:   return Color(.sRGB, red: 0.18039, green: 0.49020, blue: 0.19608)
        case .charlie:  return Color(.sRGB, red: 0.99216, green: 0.72157, blue: 0.15294)
        case .claude:   return Color(.displayP3, red: 0.72157, green: 0.32941, blue: 0.05882)
        case .inverted: return Color(white: 1)
        case .joey:     return Color(.displayP3, red: 0.78431, green: 0.06275, blue: 0.18039)
        case .oscar:    return Color(.displayP3, red: 0.00000, green: 0.44314, blue: 0.70980)
        case .royale:   return Color(.displayP3, red: 0.41569, green: 0.10588, blue: 0.60392)
        }
    }

    /// Light-mode waveform fill. Pulled from each `.icon` package's
    /// first `fill-specializations` entry (or the bare `fill.solid`
    /// on packages that don't specialise by appearance).
    var foregroundColor: Color {
        switch self {
        case .charlie:  return Color(white: 0)
        case .inverted: return Color(.displayP3, red: 0.58824, green: 0.23922, blue: 0.59216)
        case .royale:   return Color(.sRGB, red: 0.99216, green: 0.72157, blue: 0.15294)
        default:        return Color(white: 1)
        }
    }

    /// Dark-mode override for the waveform fill. Mirrors the
    /// `appearance: "dark"` entry in each package's
    /// `fill-specializations` array so the picker preview matches
    /// what the system renders on a dark Home Screen / Dock.
    /// `nil` means the package has no dark specialisation and
    /// `foregroundColor` is used in both appearances.
    var darkForegroundStyle: AnyShapeStyle? {
        switch self {
        case .default, .charlie, .inverted:
            return nil
        case .callan:
            return AnyShapeStyle(Color(.sRGB, red: 0.38039, green: 0.73333, blue: 0.27451))
        case .claude:
            return AnyShapeStyle(Color(.sRGB, red: 0.96078, green: 0.50980, blue: 0.12157))
        case .joey:
            return AnyShapeStyle(Color(.sRGB, red: 0.87843, green: 0.22745, blue: 0.24314))
        case .oscar:
            return AnyShapeStyle(Color(.sRGB, red: 0.00000, green: 0.61569, blue: 0.86275))
        case .royale:
            // Vertical gradient: purple at top, yellow at 70% down
            // and below. Matches the package's linear-gradient with
            // start (0.5, 0) → stop (0.5, 0.7).
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color(.displayP3, red: 0.58824, green: 0.23922, blue: 0.59216),
                    Color(.sRGB, red: 0.99216, green: 0.72157, blue: 0.15294)
                ],
                startPoint: UnitPoint(x: 0.5, y: 0),
                endPoint: UnitPoint(x: 0.5, y: 0.7)
            ))
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // The .icon spec measures against a 1024pt canvas; its
            // layer translates -60pt downward and scales to 0.8 of
            // the canvas. Convert those constants to the current
            // rendered `side` so the preview looks identical at
            // 24pt (picker row) and any future larger size.
            let canvasToSide = side / 1024
            let waveformStyle: AnyShapeStyle = {
                if colorScheme == .dark, let dark = option.darkForegroundStyle {
                    return dark
                }
                return AnyShapeStyle(option.foregroundColor)
            }()
            ZStack {
                option.backgroundColor
                Image("IconWaveform")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(waveformStyle)
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
