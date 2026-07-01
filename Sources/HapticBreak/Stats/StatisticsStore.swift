import Foundation

/// Per-day aggregated statistics.
struct DayStat: Codable, Identifiable {
    var date: String          // yyyy-MM-dd (local)
    var activeSeconds: Int = 0
    var breaks: Int = 0
    var skips: Int = 0
    var postpones: Int = 0
    var pomodoros: Int = 0

    var id: String { date }
    var activeMinutes: Int { activeSeconds / 60 }
}

/// Statistics persistence (a JSON file in Application Support), plus CSV export.
final class StatisticsStore {

    static let shared = StatisticsStore(fileURL: RuntimeMode.statsFileURL())

    private(set) var days: [String: DayStat] = [:]
    private let queue = DispatchQueue(label: "com.aremind.hapticbreak.stats")
    private var dirtyActiveSeconds = 0   // Accumulated active seconds, for throttled disk writes

    private let fileURL: URL

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Production default path: `~/Library/Application Support/HapticBreak/statistics.json`.
    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HapticBreak", isDirectory: true)
            .appendingPathComponent("statistics.json")
    }

    /// Defaults to the production path (app shared singleton); tests can inject a temp file path for
    /// isolation, discarded on exit and mutually non-polluting.
    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    // MARK: - Recording

    static func todayKey() -> String { dateFormatter.string(from: Date()) }

    private func mutateToday(_ block: (inout DayStat) -> Void) {
        let key = Self.todayKey()
        var stat = days[key] ?? DayStat(date: key)
        block(&stat)
        days[key] = stat
    }

    /// Called once per active second; throttled to disk (flushed once every 30 seconds).
    func addActiveSecond() {
        mutateToday { $0.activeSeconds += 1 }
        dirtyActiveSeconds += 1
        if dirtyActiveSeconds >= 30 { dirtyActiveSeconds = 0; save() }
    }

    func recordBreak()    { mutateToday { $0.breaks += 1 };    save() }
    func recordSkip()     { mutateToday { $0.skips += 1 };     save() }
    func recordPostpone() { mutateToday { $0.postpones += 1 }; save() }
    func recordPomodoro() { mutateToday { $0.pomodoros += 1 }; save() }

    // MARK: - Queries

    func today() -> DayStat { days[Self.todayKey()] ?? DayStat(date: Self.todayKey()) }

    /// The last n days (including today), ascending by date, missing days zero-filled.
    func recent(_ n: Int) -> [DayStat] {
        let cal = Calendar.current
        var result: [DayStat] = []
        for offset in stride(from: n - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = Self.dateFormatter.string(from: date)
            result.append(days[key] ?? DayStat(date: key))
        }
        return result
    }

    // MARK: - Export

    func exportCSV() -> String {
        var lines = ["date,active_minutes,breaks,skips,postpones,pomodoros"]
        for stat in days.values.sorted(by: { $0.date < $1.date }) {
            lines.append("\(stat.date),\(stat.activeMinutes),\(stat.breaks),\(stat.skips),\(stat.postpones),\(stat.pomodoros)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Consecutive days of completed rests (streak). Today being incomplete doesn't break it — the prior
    /// consecutive count is still shown.
    func currentStreak() -> Int {
        let cal = Calendar.current
        var streak = 0
        var offset = 0
        let todayBreaks = days[Self.todayKey()]?.breaks ?? 0
        if todayBreaks >= 1 { streak += 1 }
        offset = 1
        while true {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { break }
            let key = Self.dateFormatter.string(from: date)
            if (days[key]?.breaks ?? 0) >= 1 { streak += 1; offset += 1 } else { break }
        }
        return streak
    }

    /// Totals over the last n days.
    func totals(_ n: Int) -> (activeMinutes: Int, breaks: Int, skips: Int, pomodoros: Int) {
        let days = recent(n)
        return (days.reduce(0) { $0 + $1.activeMinutes },
                days.reduce(0) { $0 + $1.breaks },
                days.reduce(0) { $0 + $1.skips },
                days.reduce(0) { $0 + $1.pomodoros })
    }

    // MARK: - Persistence

    /// Synchronous disk write: used before exit (ensuring the write completes before quitting, so async
    /// writes aren't dropped by process termination) and for deterministic read-back in tests.
    func flush() { writeToDisk(days, sync: true) }

    /// Clear all statistics.
    func resetAll() {
        days = [:]
        dirtyActiveSeconds = 0
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: DayStat].self, from: data)
        else { return }
        days = decoded
    }

    private func save() { writeToDisk(days, sync: false) }

    private func writeToDisk(_ snapshot: [String: DayStat], sync: Bool) {
        let url = fileURL
        let work = {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}
