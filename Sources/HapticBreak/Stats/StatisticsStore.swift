import Foundation

/// Per-day aggregated statistics.
struct DayStat: Codable, Identifiable {
    var date: String          // yyyy-MM-dd (local)
    var activeSeconds: Int = 0
    var breaks: Int = 0
    var skips: Int = 0
    var postpones: Int = 0
    /// Completed work+rest cycles (only counted when a timed rest segment finishes).
    /// Kept under the historical `pomodoros` JSON key for backward-compatible statistics files.
    var cycles: Int = 0
    /// Acknowledged reminders (gesture / hotkey / panel / stepped away) — the delivery signal.
    var acks: Int = 0
    /// Active seconds bucketed by hour of day (24 entries) — the today-rhythm band's density shading.
    var activeByHour: [Int] = Array(repeating: 0, count: 24)
    /// Minute-of-day (0…1439) of each real rest — the band's break dots (capped, see `recordBreak`).
    var breakMinutes: [Int] = []

    var id: String { date }
    var activeMinutes: Int { activeSeconds / 60 }

    private enum CodingKeys: String, CodingKey {
        case date, activeSeconds, breaks, skips, postpones
        case cycles = "pomodoros"
        case acks, activeByHour, breakMinutes
    }

    init(date: String) { self.date = date }

    /// Tolerant decoding: fields added over time default to 0 when absent, so older statistics
    /// files keep loading unchanged.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date          = try c.decode(String.self, forKey: .date)
        activeSeconds = try c.decodeIfPresent(Int.self, forKey: .activeSeconds) ?? 0
        breaks        = try c.decodeIfPresent(Int.self, forKey: .breaks) ?? 0
        skips         = try c.decodeIfPresent(Int.self, forKey: .skips) ?? 0
        postpones     = try c.decodeIfPresent(Int.self, forKey: .postpones) ?? 0
        cycles        = try c.decodeIfPresent(Int.self, forKey: .cycles) ?? 0
        acks          = try c.decodeIfPresent(Int.self, forKey: .acks) ?? 0
        let hours     = try c.decodeIfPresent([Int].self, forKey: .activeByHour) ?? []
        activeByHour  = Array((hours + Array(repeating: 0, count: 24)).prefix(24))
        breakMinutes  = try c.decodeIfPresent([Int].self, forKey: .breakMinutes) ?? []
    }
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
        let hour = Calendar.current.component(.hour, from: Date())
        mutateToday {
            $0.activeSeconds += 1
            if $0.activeByHour.indices.contains(hour) { $0.activeByHour[hour] += 1 }
        }
        dirtyActiveSeconds += 1
        if dirtyActiveSeconds >= 30 { dirtyActiveSeconds = 0; save() }
    }

    func recordBreak() {
        let now = Date()
        let minute = Calendar.current.component(.hour, from: now) * 60
                   + Calendar.current.component(.minute, from: now)
        mutateToday {
            $0.breaks += 1
            if $0.breakMinutes.count < 96 { $0.breakMinutes.append(minute) }   // Sanity cap
        }
        save()
    }
    func recordSkip()     { mutateToday { $0.skips += 1 };     save() }
    func recordPostpone() { mutateToday { $0.postpones += 1 }; save() }
    func recordCycle()    { mutateToday { $0.cycles += 1 };    save() }
    func recordAck()      { mutateToday { $0.acks += 1 };      save() }

    // MARK: - Queries

    func today() -> DayStat { days[Self.todayKey()] ?? DayStat(date: Self.todayKey()) }

    /// Replace one day's record wholesale — used by the render-shot seeding (ephemeral store) and tests.
    func importDay(_ stat: DayStat) {
        days[stat.date] = stat
        save()
    }

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
        var lines = ["date,active_minutes,breaks,skips,postpones,cycles,acks"]
        for stat in days.values.sorted(by: { $0.date < $1.date }) {
            lines.append("\(stat.date),\(stat.activeMinutes),\(stat.breaks),\(stat.skips),\(stat.postpones),\(stat.cycles),\(stat.acks)")
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
    func totals(_ n: Int) -> (activeMinutes: Int, breaks: Int, skips: Int, cycles: Int) {
        let days = recent(n)
        return (days.reduce(0) { $0 + $1.activeMinutes },
                days.reduce(0) { $0 + $1.breaks },
                days.reduce(0) { $0 + $1.skips },
                days.reduce(0) { $0 + $1.cycles })
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
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: DayStat].self, from: data) {
            days = decoded
        } else {
            // Unreadable statistics (e.g. a bad schema change): move the file aside instead of
            // letting the next save() silently overwrite the whole history with an empty set.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
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
