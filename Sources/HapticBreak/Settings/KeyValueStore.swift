import Foundation

/// Minimal abstraction for reading/writing preferences — decouples `Settings` from a concrete `UserDefaults`.
/// Production uses `UserDefaults` (disk-persisted); tests and ephemeral runs (--demo) inject an in-memory
/// implementation, with zero disk footprint throughout, never polluting the user's real preferences nor
/// leaving empty plists in `~/Library/Preferences`.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// Pure in-memory preference store: in-process-isolated, discarded on exit, writes no files.
final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Any] = [:]

    func object(forKey key: String) -> Any? { storage[key] }
    func data(forKey key: String) -> Data? { storage[key] as? Data }
    func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }
}
