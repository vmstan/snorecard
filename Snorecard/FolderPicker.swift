import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
/// Runs a folder `NSOpenPanel` synchronously and returns the chosen URL.
/// All macOS picker use sites live in this one file so `Library` stays
/// platform-agnostic.
@MainActor
func presentFolderPicker(
    prompt: String,
    message: String,
    startingAt directoryURL: URL? = nil
) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = prompt
    panel.message = message
    panel.showsHiddenFiles = true
    if let directoryURL {
        panel.directoryURL = directoryURL
    }
    return panel.runModal() == .OK ? panel.url : nil
}
#endif

#if os(iOS)
/// Presents a `UIDocumentPickerViewController` in folder-picking mode from
/// the current key window. Unlike SwiftUI's `.fileImporter`, this works
/// reliably when picking the root folder of a mounted external volume
/// (USB-C SD card readers on iPhone 15 Pro and later).
///
/// The security-scoped URL is left "started" for the lifetime of the
/// process — a follow-up pass should persist a bookmark instead.
@MainActor
func presentIOSFolderPicker(onPick: @escaping (URL) -> Void) {
    guard let rootViewController = topmostViewController() else { return }

    let picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [.folder],
        asCopy: false
    )
    picker.allowsMultipleSelection = false
    picker.shouldShowFileExtensions = true

    let delegate = FolderPickerDelegate(onPick: onPick)
    picker.delegate = delegate

    // UIDocumentPickerViewController only keeps a weak reference to its
    // delegate, so we attach ours via an associated object to keep it
    // alive for the lifetime of the picker.
    objc_setAssociatedObject(
        picker,
        &FolderPickerDelegate.associatedObjectKey,
        delegate,
        .OBJC_ASSOCIATION_RETAIN
    )

    rootViewController.present(picker, animated: true)
}

private final class FolderPickerDelegate: NSObject, UIDocumentPickerDelegate {
    nonisolated(unsafe) static var associatedObjectKey: UInt8 = 0

    private let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        _ = url.startAccessingSecurityScopedResource()
        onPick(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // No-op — nothing to clean up.
    }
}

@MainActor
private func topmostViewController() -> UIViewController? {
    let windowScene = UIApplication.shared
        .connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    let keyWindow = windowScene?.windows.first { $0.isKeyWindow }
        ?? windowScene?.windows.first

    var top = keyWindow?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}
#endif
