import XCTest
@testable import HapticBreak

/// The editor's rhythm-recording state machine — pure logic, driven with explicit dates.
final class RhythmRecorderTests: HBTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func beat() -> HapticStep { HapticStep(timbre: .crisp, strength: 6, gapMsAfter: 0) }

    func testTapsBookGapsOnThePreviousBeat() {
        var r = RhythmRecorder()
        r.start(at: t0)
        r.tap(beat(), at: t0.addingTimeInterval(1.0))
        r.tap(beat(), at: t0.addingTimeInterval(1.3))
        r.tap(beat(), at: t0.addingTimeInterval(2.0))
        XCTAssertEqual(r.steps.count, 3)
        XCTAssertEqual(r.steps[0].gapMsAfter, 300, "gap to the second tap lands on the first beat")
        XCTAssertEqual(r.steps[1].gapMsAfter, 700)
        XCTAssertEqual(r.steps[2].gapMsAfter, 0, "the last beat has no trailing gap yet")
    }

    func testGapsAreClamped() {
        var r = RhythmRecorder()
        r.start(at: t0)
        r.tap(beat(), at: t0.addingTimeInterval(1))
        r.tap(beat(), at: t0.addingTimeInterval(1.01))   // 10 ms — below the blur threshold
        r.tap(beat(), at: t0.addingTimeInterval(9))      // 7.99 s — a "thinking" pause
        XCTAssertEqual(r.steps[0].gapMsAfter, RhythmRecorder.minGapMs)
        XCTAssertEqual(r.steps[1].gapMsAfter, RhythmRecorder.maxGapMs)
    }

    func testPausedSpanNeverLeaksIntoGapsOrElapsed() {
        var r = RhythmRecorder()
        r.start(at: t0)
        r.tap(beat(), at: t0.addingTimeInterval(1))
        r.setPaused(true, at: t0.addingTimeInterval(2))
        XCTAssertEqual(r.elapsed(at: t0.addingTimeInterval(60)), 2, "elapsed freezes while paused")
        r.tap(beat(), at: t0.addingTimeInterval(30))     // taps while paused are ignored
        XCTAssertEqual(r.steps.count, 1)
        r.setPaused(false, at: t0.addingTimeInterval(62))  // paused for 60 s
        r.tap(beat(), at: t0.addingTimeInterval(62.5))
        XCTAssertEqual(r.steps[0].gapMsAfter, 1500,
                       "gap = 1s before the pause + 0.5s after — the 60s pause is excluded")
        XCTAssertEqual(r.elapsed(at: t0.addingTimeInterval(63)), 3, accuracy: 0.001,
                       "elapsed likewise excludes the paused span")
    }

    func testStartAndClearResetTakes() {
        var r = RhythmRecorder()
        r.start(at: t0)
        r.tap(beat(), at: t0.addingTimeInterval(1))
        r.clear(at: t0.addingTimeInterval(2))
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.elapsed(at: t0.addingTimeInterval(5)), 3, "clear restarts the session clock")
        r.tap(beat(), at: t0.addingTimeInterval(6))
        r.tap(beat(), at: t0.addingTimeInterval(6.4))
        XCTAssertEqual(r.steps[0].gapMsAfter, 400, "no stale gap from the cleared take")
    }
}
