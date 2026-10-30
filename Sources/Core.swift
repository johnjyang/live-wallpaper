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
    case other
    case unavailable
}

enum WallpaperStore {
    // Read-only: these are the system's files, never rewritten by this app.
    static func selection(in store: [String: Any], display: String, space: String?) -> WallpaperSelection {
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
            guard choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials" else { return .other }
            guard let data = choice["Configuration"] as? Data,
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = config["assetID"] as? String, UUID(uuidString: id) != nil else { return .unavailable }
            return .aerial(id)
        }
        return .unavailable
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
