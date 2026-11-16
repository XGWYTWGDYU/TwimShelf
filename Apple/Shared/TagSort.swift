import Foundation

/// How the tag list is ordered (every platform has the same four): by media count, by how many
/// carry it as your tag, by how many carry it as an AI tag, or by name. Remembered per device.
enum TagSort: String, CaseIterable {
    case count, mine, ai, name

    var title: String {
        switch self {
        case .count: L("tags.sort.count")
        case .mine: L("tags.sort.mine")
        case .ai: L("tags.sort.ai")
        case .name: L("common.name")
        }
    }

    static var saved: TagSort {
        get { UserDefaults.standard.string(forKey: "tags.sort").flatMap(TagSort.init(rawValue:)) ?? .count }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tags.sort") }
    }

    /// Largest first (ties by name), or by name.
    func apply(_ v: [TagCount]) -> [TagCount] {
        switch self {
        case .count: v.sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        case .mine: v.sorted { ($0.user, $1.label) > ($1.user, $0.label) }
        case .ai: v.sorted { ($0.ai, $1.label) > ($1.ai, $0.label) }
        case .name: v.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
    }
}
