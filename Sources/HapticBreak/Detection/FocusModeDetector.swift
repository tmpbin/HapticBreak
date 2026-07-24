import Foundation

/// Detects whether the system "Do Not Disturb / Focus" is on.
///
/// macOS has no public API to query the Focus state, so this uses a best-effort approach: parsing
/// `~/Library/DoNotDisturb/DB/Assertions.json`. When there's an active assertion record, it's treated as
/// DND on. Any parse failure returns `false`, without affecting the main flow.
///
/// The parse result is cached by the file's modification date — the periodic probe then costs one
/// `stat` instead of a read + JSON parse. Not thread-safe by itself; callers serialize (the app
/// probes only on `AppController.probeQueue`, `--checkenv` is a one-shot CLI read).
enum FocusModeDetector {

    private static let assertionsPath = NSHomeDirectory()
        + "/Library/DoNotDisturb/DB/Assertions.json"

    private static var cache: (mtime: Date, value: Bool)?

    static func isFocusActive() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: assertionsPath),
              let mtime = attrs[.modificationDate] as? Date else {
            cache = nil
            return false
        }
        if let cache, cache.mtime == mtime { return cache.value }
        let value = parseAssertions()
        cache = (mtime, value)
        return value
    }

    private static func parseAssertions() -> Bool {
        guard let data = FileManager.default.contents(atPath: assertionsPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = root["data"] as? [[String: Any]]
        else { return false }

        for entry in dataArray {
            if let records = entry["storeAssertionRecords"] as? [[String: Any]], !records.isEmpty {
                return true
            }
        }
        return false
    }
}
