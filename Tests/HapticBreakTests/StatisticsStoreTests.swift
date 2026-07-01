import XCTest
@testable import HapticBreak

/// Statistics store — inject a temporary file path, never touching the real Application Support.
/// Covers recording, querying, zero-fill, export, consecutive-day streaks, and persistence round-trip.
final class StatisticsStoreTests: HBTestCase {

    private func dayKey(offset: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        return f.string(from: date)
    }

    private func writeStats(_ days: [DayStat], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dict = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        let data = try! JSONEncoder().encode(dict)
        try! data.write(to: url)
    }

    func testRecordCountsAccumulateForToday() {
        let store = makeStatsStore()
        store.recordBreak()
        store.recordSkip()
        store.recordPostpone()
        store.recordPomodoro()
        let today = store.today()
        XCTAssertEqual(today.breaks, 1)
        XCTAssertEqual(today.skips, 1)
        XCTAssertEqual(today.postpones, 1)
        XCTAssertEqual(today.pomodoros, 1)
    }

    func testActiveSecondsAccumulate() {
        let store = makeStatsStore()
        for _ in 0..<90 { store.addActiveSecond() }
        XCTAssertEqual(store.today().activeSeconds, 90)
        XCTAssertEqual(store.today().activeMinutes, 1, "90s = 1 minute (integer division)")
    }

    func testRecentIsZeroFilledAndAscending() {
        let store = makeStatsStore()
        store.recordBreak()
        let recent = store.recent(7)
        XCTAssertEqual(recent.count, 7, "padded to 7 days")
        XCTAssertEqual(recent.last?.date, dayKey(offset: 0), "the last day is today")
        XCTAssertEqual(recent.first?.date, dayKey(offset: -6), "the first day is 6 days ago")
        XCTAssertEqual(recent.last?.breaks, 1)
        XCTAssertEqual(recent.dropLast().reduce(0) { $0 + $1.breaks }, 0, "past days are zero-filled")
    }

    func testTotals() {
        let store = makeStatsStore()
        store.recordBreak(); store.recordBreak(); store.recordSkip()
        let t = store.totals(7)
        XCTAssertEqual(t.breaks, 2)
        XCTAssertEqual(t.skips, 1)
    }

    func testExportCSV() {
        let store = makeStatsStore()
        store.recordBreak()
        let csv = store.exportCSV()
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "date,active_minutes,breaks,skips,postpones,pomodoros")
        XCTAssertTrue(csv.contains("\(dayKey(offset: 0)),0,1,0,0,0"), "contains today's row with correct counts")
    }

    func testCurrentStreakToday() {
        let store = makeStatsStore()
        XCTAssertEqual(store.currentStreak(), 0, "no rest → 0")
        store.recordBreak()
        XCTAssertEqual(store.currentStreak(), 1, "completed today → 1")
    }

    func testCurrentStreakAcrossConsecutiveDays() {
        let url = makeTempStatsURL()
        writeStats([
            DayStat(date: dayKey(offset: 0), breaks: 1),
            DayStat(date: dayKey(offset: -1), breaks: 2),
            DayStat(date: dayKey(offset: -2), breaks: 1),
        ], to: url)
        let store = StatisticsStore(fileURL: url)
        XCTAssertEqual(store.currentStreak(), 3, "today + two consecutive days → 3")
    }

    func testCurrentStreakBreaksOnGap() {
        let url = makeTempStatsURL()
        writeStats([
            DayStat(date: dayKey(offset: 0), breaks: 1),
            // yesterday missing (gap)
            DayStat(date: dayKey(offset: -2), breaks: 1),
        ], to: url)
        let store = StatisticsStore(fileURL: url)
        XCTAssertEqual(store.currentStreak(), 1, "gap yesterday → only today counts as the streak")
    }

    func testPersistenceRoundTrip() {
        let url = makeTempStatsURL()
        let store = StatisticsStore(fileURL: url)
        store.recordBreak()
        store.recordBreak()
        store.flush()  // synchronous write to disk
        let reloaded = StatisticsStore(fileURL: url)
        XCTAssertEqual(reloaded.today().breaks, 2, "a new instance reads back from the same file")
    }

    func testResetAllClearsInMemory() {
        let store = makeStatsStore()
        store.recordBreak()
        store.resetAll()
        XCTAssertTrue(store.days.isEmpty)
        XCTAssertEqual(store.today().breaks, 0)
    }
}
