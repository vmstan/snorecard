#if os(iOS)
import SwiftUI

/// Centered glass pill anchored to the bottom of the daily and
/// trends screens on iOS. Hosts the per-context shortcuts that
/// used to live inside the navigation bar's "..." menu — Sleep
/// Analysis, Sleep Journal, and (for day views) Therapy Details
/// — so reaching them no longer requires opening a menu.
///
/// Buttons post the same notifications the Options menu used, so
/// the existing sheet plumbing in `DayDetailView` / `ContentView`
/// keeps working unchanged.
struct FloatingActionBar: View {
    enum Item: Hashable {
        case sleepAnalysis
        case sleepJournal
        case sessions
        case therapyDetails
    }

    let items: [Item]
    var isEnabled: (Item) -> Bool = { _ in true }
    let onTap: (Item) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.title3.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled(item))
                .opacity(isEnabled(item) ? 1 : 0.4)
                .accessibilityLabel(item.title)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

extension FloatingActionBar.Item {
    var title: String {
        switch self {
        case .sleepAnalysis:  return "Sleep Analysis"
        case .sleepJournal:   return "Sleep Journal"
        case .sessions:       return "Therapy Sessions"
        case .therapyDetails: return "Therapy Details"
        }
    }

    var systemImage: String {
        switch self {
        case .sleepAnalysis:  return "sparkles"
        case .sleepJournal:   return "note.text"
        case .sessions:       return "clock"
        case .therapyDetails: return "fan"
        }
    }
}
#endif
