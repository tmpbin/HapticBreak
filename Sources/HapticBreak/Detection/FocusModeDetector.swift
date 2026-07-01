import Foundation

/// Detects whether the system "Do Not Disturb / Focus" is on.
///
/// macOS has no public API to query the Focus state, so this uses a best-effort approach: parsing
/// `~/Library/DoNotDisturb/DB/Assertions.json`. When there's an active assertion record, it's treated as
/// DND on. Any parse failure returns `false`, without affecting the main flow.
enum FocusModeDetector {

    private static let assertionsPath = NSHomeDirectory()
        + "/Library/DoNotDisturb/DB/Assertions.json"

    static func isFocusActive() -> Bool {
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
