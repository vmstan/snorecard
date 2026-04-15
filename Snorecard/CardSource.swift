import Foundation
import SwiftUI
import SnorecardKit

/// Where the currently loaded ResMed card lives on disk. Derived from the
/// card's `rootURL` so we can surface a small indicator in the sidebar.
enum CardSource {
    case sdCard
    case iCloud
    case localBackup

    var label: String {
        switch self {
        case .sdCard: "SD Card"
        case .iCloud: "iCloud Sync"
        case .localBackup: "Local Backup"
        }
    }

    var systemImage: String {
        switch self {
        case .sdCard: "sdcard"
        case .iCloud: "icloud"
        case .localBackup: "archivebox"
        }
    }

    /// Best-effort classification from a folder URL. We treat anything
    /// inside the Mobile Documents iCloud Drive path as iCloud, any
    /// `/Volumes/` mount on macOS as an SD card, and anything else as a
    /// local backup. On iOS we can't reliably tell an external-volume pick
    /// apart from a Files-app pick, so SD vs local collapses to
    /// `.localBackup` unless the path obviously matches iCloud.
    static func detect(from url: URL) -> CardSource {
        let path = url.path

        if path.contains("/Mobile Documents/com~apple~CloudDocs/") {
            return .iCloud
        }

        #if os(macOS)
        if path.hasPrefix("/Volumes/") {
            return .sdCard
        }
        #endif

        return .localBackup
    }
}
