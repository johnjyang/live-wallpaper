import Foundation
import CoreGraphics

enum PlaybackMode: String, CaseIterable {
    case visible, always, paused
    var title: String {
        switch self {
        case .visible: return "Play When Desktop Is Visible"
        case .always: return "Always Play"
        case .paused: return "Pause"
        }
    }
}

enum StatusJSON {
    static func data(_ status: [String: Any]) -> Data? {
        // Foundation's JSON writer raises an Objective-C exception for NaN;
        // Swift's do/catch cannot catch it. Validate before entering the writer.
        guard JSONSerialization.isValidJSONObject(status) else { return nil }
        return try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
    }
}

enum WallpaperSelection: Equatable {
    case aerial(String)
    case shuffle(ShuffleChoice)
    case systemDefault
    case other
    case unavailable
}

enum WallpaperStore {
    // Read-only: these are the system's files, never rewritten by this app.
    static func selection(in store: [String: Any], display: String, space: String?, categoryIDs: Set<String> = []) -> WallpaperSelection {
        var sections: [[String: Any]] = []
        if let space, let entry = (store["Spaces"] as? [String: [String: Any]])?[space] {
            if let d = (entry["Displays"] as? [String: [String: Any]])?[display] { sections.append(d) }
            if let d = entry["Default"] as? [String: Any] { sections.append(d) }
        }
        if let d = (store["Displays"] as? [String: [String: Any]])?[display] { sections.append(d) }
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if let d = store[key] as? [String: Any] { sections.append(d) }
        }
        for section in sections {
            let type = section["Type"] as? String
            guard let slot = section[type == "linked" ? "Linked" : "Desktop"] as? [String: Any],
                  let content = slot["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]], let choice = choices.first else { continue }
            let provider = choice["Provider"] as? String
            // macOS represents its default aerial (Golden Gate Sunset on
            // macOS 27) with an empty configuration rather than an asset ID.
            if provider == "default" {
                guard (choice["Configuration"] as? Data)?.isEmpty != false else { return .unavailable }
                return .systemDefault
            }
            guard provider == "com.apple.wallpaper.choice.aerials" else { return .other }
            guard let data = choice["Configuration"] as? Data,
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = config["assetID"] as? String else { return .unavailable }
            if id == "shuffle-all-aerials" || categoryIDs.contains(id) {
                let options = (content["EncodedOptionValues"] as? Data).flatMap {
                    try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                }
                let values = options?["values"] as? [String: Any]
                let frequency = values?["aerialShuffleFrequency"] as? [String: Any]
                let picker = (frequency?["picker"] as? [String: Any])?["_0"] as? [String: Any]
                let raw = picker?["id"] as? String ?? "shuffle_continuously"
                guard let cadence = ShuffleCadence(rawValue: raw) else { return .unavailable }
                return .shuffle(ShuffleChoice(collectionID: id, cadence: cadence))
            }
            guard UUID(uuidString: id) != nil else { return .unavailable }
            return .aerial(id)
        }
        return .unavailable
    }
}

enum ShuffleCadence: String, Hashable {
    case continuously = "shuffle_continuously"
    case twelveHours = "shuffle_every_12_hours"
    case day = "shuffle_every_1_day"
    case twoDays = "shuffle_every_2_days"
    case week = "shuffle_every_1_week"
    case month = "shuffle_every_1_month"

    func deadline(after date: Date) -> Date? {
        switch self {
        case .continuously: return nil
        case .twelveHours: return date.addingTimeInterval(12 * 3600)
        case .day: return Calendar.current.date(byAdding: .day, value: 1, to: date)
        case .twoDays: return Calendar.current.date(byAdding: .day, value: 2, to: date)
        case .week: return Calendar.current.date(byAdding: .day, value: 7, to: date)
        case .month: return Calendar.current.date(byAdding: .month, value: 1, to: date)
        }
    }
}

struct ShuffleChoice: Hashable {
    let collectionID: String
    let cadence: ShuffleCadence
}

struct AerialCatalog {
    struct Asset {
        let id: String
        let name: String
        let categories: Set<String>
        let includeInShuffle: Bool
    }
    let assets: [Asset]
    let categoryIDs: Set<String>
    init(_ manifest: [String: Any]) {
        assets = (manifest["assets"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["id"] as? String, UUID(uuidString: id) != nil else { return nil }
            return Asset(id: id, name: a["accessibilityLabel"] as? String ?? id,
                         categories: Set(a["categories"] as? [String] ?? []),
                         includeInShuffle: a["includeInShuffle"] as? Bool ?? true)
        }
        categoryIDs = Set((manifest["categories"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    }
    func candidates(for choice: ShuffleChoice, available: (String) -> Bool) -> [String] {
        assets.filter { $0.includeInShuffle &&
            (choice.collectionID == "shuffle-all-aerials" || $0.categories.contains(choice.collectionID)) && available($0.id)
        }.map(\.id)
    }
}

struct ShuffleBag {
    private(set) var current: String?
    private var remaining: [String] = []
    private var eligible: Set<String> = []
    mutating func select(from candidates: [String], advance: Bool = false) -> String? {
        let pool = Set(candidates)
        remaining = remaining.filter { pool.contains($0) }
        remaining += Array(pool.subtracting(eligible).subtracting(Set(remaining))).filter { $0 != current }.shuffled()
        eligible = pool
        guard !pool.isEmpty else { current = nil; remaining = []; return nil }
        if !advance, let current, pool.contains(current) { return current }
        if remaining.isEmpty { remaining = Array(pool).shuffled() }
        if remaining.first == current, let alternative = remaining.firstIndex(where: { $0 != current }) {
            remaining.swapAt(0, alternative)
        }
        current = remaining.removeFirst()
        return current
    }
}

enum BundledDefault {
    static func video(in directory: URL = URL(fileURLWithPath: "/System/Library/Wallpapers/.default", isDirectory: true)) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        let videos = files.filter {
            ["mov", "mp4"].contains($0.pathExtension.lowercased()) &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        // Don't guess between unrelated movies if Apple changes this layout.
        return videos.count == 1 ? videos[0] : nil
    }
}

enum Visibility {
    // Exact union of the occluders, clipped to a display. Overlaps count once.
    // Window counts are small; an x-axis sweep avoids a per-pixel/grid scan.
    static func coveredFraction(of screen: CGRect, by windows: [CGRect]) -> Double {
        guard screen.width > 0, screen.height > 0 else { return 0 }
        let rects = windows.map { $0.intersection(screen) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xs.count > 1 else { return 0 }
        var area = 0.0
        for i in 1..<xs.count {
            let left = xs[i-1], right = xs[i]
            let intervals = rects.filter { $0.minX < right && $0.maxX > left }
                .map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            guard var merged = intervals.first else { continue }
            var height = 0.0
            for interval in intervals.dropFirst() {
                if interval.0 <= merged.1 { merged.1 = max(merged.1, interval.1) }
                else { height += merged.1 - merged.0; merged = interval }
            }
            height += merged.1 - merged.0
            area += (right-left) * height
        }
        return min(1, max(0, area / (screen.width * screen.height)))
    }

    // Hysteresis prevents flicker near the boundary. Keep moving while a
    // meaningful part of the desktop is exposed, pause when almost covered.
    static func shouldPlay(mode: PlaybackMode, suspended: Bool, coverage: Double, wasPlaying: Bool) -> Bool {
        guard !suspended, mode != .paused else { return false }
        if mode == .always { return true }
        return coverage < (wasPlaying ? 0.95 : 0.90)
    }
}
