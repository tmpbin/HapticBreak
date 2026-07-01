import XCTest
@testable import HapticBreak

/// L1 ring truth layer: pure-function quantization and "two consecutive frames" decisions, locking down the first-grid off-by-one and ensuring pause/jump don't fire spurious animations.
final class RingModelTests: XCTestCase {

    func testGridAndLitCounts() {
        XCTAssertEqual(RingModel.gridCount(900), 15, "15 minutes = 15 grids")
        XCTAssertEqual(RingModel.litGrids(900), 15, "full ring lights 15")
        XCTAssertEqual(RingModel.litGrids(841), 15, "14:01 still 15 grids")
        XCTAssertEqual(RingModel.litGrids(840), 14, "14:00 drops to 14 grids")
        XCTAssertEqual(RingModel.gridCount(0), 1, "total seconds falls back to at least 1 grid")
        XCTAssertEqual(RingModel.litGrids(-5), 0, "negative remaining → 0 grids")
    }

    func testNaturalCountdownDeductsEveryMinute() {
        let events = ringEvents(total: 900)
        XCTAssertEqual(events.count, 15, "15 minutes yields 15 deductions")
        XCTAssertTrue(events.allSatisfy { if case .deduct = $0 { return true } else { return false } },
                      "all deducts throughout, no misclassified align")
        XCTAssertEqual(events.first, .deduct(from: 15, to: 14), "first grid at 14:00 deducts 15→14 (off-by-one regression lock)")
        XCTAssertEqual(events.last, .deduct(from: 1, to: 0), "last grid deducts 1→0")
    }

    func testPausedCrossMinuteAligns() {
        var m = RingModel(.init(remaining: 900, total: 900, animated: false))
        XCTAssertEqual(m.update(.init(remaining: 840, total: 900, animated: false)), .align(to: 14),
                       "crossing a minute while paused → align (no bullet emitted)")
    }

    func testJumpUpAligns() {
        var m = RingModel(.init(remaining: 300, total: 600, animated: true))
        XCTAssertEqual(m.update(.init(remaining: 540, total: 600, animated: true)), .align(to: 9),
                       "remaining jumps up → align (no spurious deduct)")
    }

    func testSameMinuteIsIdempotent() {
        var m = RingModel(.init(remaining: 900, total: 900, animated: true))
        XCTAssertEqual(m.update(.init(remaining: 899, total: 900, animated: true)), .none,
                       "feeding values repeatedly within the same minute only yields .none")
        XCTAssertEqual(m.update(.init(remaining: 850, total: 900, animated: true)), .none,
                       "still in the 15-grid range → .none")
    }

    private func ringEvents(total: Int, animated: Bool = true) -> [RingModel.Event] {
        var m = RingModel(.init(remaining: total, total: total, animated: animated))
        var out: [RingModel.Event] = []
        for r in stride(from: total - 1, through: 0, by: -1) {
            let e = m.update(.init(remaining: r, total: total, animated: animated))
            if case .none = e {} else { out.append(e) }
        }
        return out
    }
}
