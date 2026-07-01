import XCTest
@testable import HapticBreak

/// Base class for all unit tests: provides "in-process isolated" `Settings` and `StatisticsStore`,
/// cleaned up after use — never touching the user's real preferences (UserDefaults) or statistics (Application Support).
class HBTestCase: XCTestCase {

    private var tempDirs: [URL] = []
    private var stores: [StatisticsStore] = []

    /// A `Settings` isolated per test case (purely in-memory preferences), zero disk footprint.
    func makeSettings(_ configure: (Settings) -> Void = { _ in }) -> Settings {
        let s = Settings(defaults: makeDefaults())
        configure(s)
        return s
    }

    /// An in-memory preference store isolated per test case (useful for seeding legacy keys / migration tests).
    func makeDefaults() -> InMemoryKeyValueStore { InMemoryKeyValueStore() }

    /// A statistics store isolated per test case (statistics.json in a temp directory), cleared on exit.
    func makeStatsStore() -> StatisticsStore {
        let store = StatisticsStore(fileURL: makeTempStatsURL())
        stores.append(store)
        return store
    }

    /// A temporary statistics file path (for "write to disk → new instance reads back" persistence checks).
    func makeTempStatsURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HBTests-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return dir.appendingPathComponent("statistics.json")
    }

    override func tearDown() {
        // First synchronously drain each store's write queue, to avoid an async save landing after the directory is removed and recreating the file.
        for store in stores { store.flush() }
        stores.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }
}
