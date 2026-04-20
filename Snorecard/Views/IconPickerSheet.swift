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
    case joey = "Joey"
    case oscar = "Oscar"
    case royale = "Royale"
    case sadie = "Sadie"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// `nil` on the default means "primary app icon". The other
    /// cases map to the alternate-icon asset names in the target.
    var alternateIconName: String? {
        switch self {
        case .default: return nil
        case .claude:  return "Snorecard-Claude"
        case .joey:    return "Snorecard-Joey"
        case .oscar:   return "Snorecard-Oscar"
        case .royale:  return "Snorecard-Royale"
        case .sadie:   return "Snorecard-Sadie"
        }
    }

    /// Base gradient colour pulled from each `.icon` package's
    /// `icon.json` — used for the picker's preview swatch.
    var backgroundColor: Color {
        switch self {
        case .default: return Color(red: 0.58188, green: 0.21569, blue: 1.00000)
        case .claude:  return Color(red: 0.85633, green: 0.41433, blue: 0.27193)
        case .joey:    return Color(red: 0.80543, green: 0.29125, blue: 0.60434)
        case .oscar:   return Color(red: 0.20471, green: 0.47274, blue: 0.77461)
        case .royale:  return Color(red: 0.41961, green: 0.12941, blue: 0.78824)
        case .sadie:   return Color(red: 0.58082, green: 0.08843, blue: 0.31864)
        }
    }

    /// Accent colour for the waveform glyph in the preview —
    /// white on most icons, violet on Joey, yellow on Royale.
    var accentColor: Color {
        switch self {
        case .joey:    return Color(red: 0.47330, green: 0.25304, blue: 0.88424)
        case .royale:  return Color(red: 1.00000, green: 0.83922, blue: 0.03922)
        default:       return .white
        }
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
        app.setAlternateIconName(targetName) { _ in }
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

/// Icon-picker sheet/inspector content. Six tappable tiles in an
/// adaptive grid; the active option gets a tint ring so the user
/// can confirm their selection without re-opening the picker.
struct IconPickerSheet: View {
    let onClose: () -> Void

    @State private var selection: AppIconOption = AppIconController.current

    var body: some View {
        #if os(iOS)
        NavigationStack {
            grid
                .navigationTitle("App Icon")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        CloseSheetButton { onClose() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        VStack(alignment: .leading, spacing: 0) {
            InspectorPaneHeader(
                title: "App Icon",
                caption: "Changes the Snorecard icon in the Dock and on the Home Screen."
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            grid
        }
        .navigationTitle("App Icon")
        #endif
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 16)],
                spacing: 16
            ) {
                ForEach(AppIconOption.allCases) { option in
                    tile(for: option)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func tile(for option: AppIconOption) -> some View {
        let isSelected = option == selection
        Button {
            selection = option
            AppIconController.apply(option)
        } label: {
            VStack(spacing: 10) {
                preview(for: option)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    }
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                Text(option.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func preview(for option: AppIconOption) -> some View {
        if let image = AppIconPreview.image(for: option) {
            image
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            // Fallback when Xcode hasn't surfaced the rendered
            // icon to the runtime bundle (happens for the primary
            // on some sim configurations) — use the icon.json
            // gradient plus an SF-symbol waveform so the tile
            // still reads as "Snorecard in this colour".
            ZStack {
                LinearGradient(
                    colors: [
                        option.backgroundColor,
                        option.backgroundColor.opacity(0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Image(systemName: "waveform.path")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(option.accentColor)
                    .offset(y: 2)
            }
        }
    }
}

/// Platform-specific resolution of an `AppIconOption` to the
/// rendered image actually shipped in the app bundle. Keeps
/// `IconPickerSheet` free of `UIKit` / `AppKit` plumbing and
/// gives one place to adjust if Xcode changes how it surfaces
/// compiled `.icon` assets.
@MainActor
enum AppIconPreview {
    static func image(for option: AppIconOption) -> Image? {
        #if canImport(UIKit)
        if let ui = loadUIImage(for: option) {
            return Image(uiImage: ui)
        }
        #elseif canImport(AppKit)
        if let ns = loadNSImage(for: option) {
            return Image(nsImage: ns)
        }
        #endif
        return nil
    }

    #if canImport(UIKit)
    /// Walk the Info.plist's `CFBundleIcons` tree to find the
    /// PNG filename Xcode emitted for this icon asset, then load
    /// it via `UIImage(named:)`. Alternate-icon PNGs aren't
    /// auto-surfaced by asset-catalog lookup on iOS, so the plist
    /// is the authoritative source.
    private static func loadUIImage(for option: AppIconOption) -> UIImage? {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        if let name = option.alternateIconName {
            let alternates = icons?["CFBundleAlternateIcons"] as? [String: [String: Any]]
            guard let files = alternates?[name]?["CFBundleIconFiles"] as? [String],
                  let last = files.last,
                  let image = UIImage(named: last)
            else { return nil }
            return image
        }
        // Primary — iOS stores its filename list under
        // CFBundlePrimaryIcon. Take the last (largest) entry.
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        guard let files = primary?["CFBundleIconFiles"] as? [String],
              let last = files.last,
              let image = UIImage(named: last)
        else {
            // Last-resort: the asset name itself sometimes
            // resolves on newer iOS when the .icon package was
            // added to the asset catalog.
            return UIImage(named: "Snorecard")
        }
        return image
    }
    #elseif canImport(AppKit)
    /// macOS compiles each `.icon` package to a named image in
    /// the asset catalog; `NSImage(named:)` looks it up directly.
    private static func loadNSImage(for option: AppIconOption) -> NSImage? {
        if let name = option.alternateIconName,
           let image = NSImage(named: name) {
            return image
        }
        // Primary is indexed under the app's AppIcon name
        // (the ASSETCATALOG_COMPILER_APPICON_NAME build setting).
        return NSImage(named: "Snorecard")
            ?? NSApp.applicationIconImage
    }
    #endif
}
