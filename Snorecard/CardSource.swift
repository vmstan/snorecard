import Foundation
import SwiftUI
import SnorecardKit

/// Where the currently loaded ResMed card lives on disk. Derived from the
/// card's `rootURL` so we can surface a small indicator in the sidebar.
enum CardSource {
    case sdCard
    case iCloud

    /// Classify a folder URL by checking whether it lives inside
    /// Snorecard's iCloud ubiquity container. Everything else is
    /// treated as an SD card import.
    static func detect(from url: URL) -> CardSource {
        if let container = FileManager.default
            .url(forUbiquityContainerIdentifier: "iCloud.com.vmstan.Snorecard")?
            .appendingPathComponent("Documents", isDirectory: true),
           url.path.hasPrefix(container.path) {
            return .iCloud
        }
        return .sdCard
    }
}
