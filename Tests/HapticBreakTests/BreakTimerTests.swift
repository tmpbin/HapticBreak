import XCTest
@testable import HapticBreak

/// Core behavior of the timer state machine — migrated from the hidden CLI regression (--logictest) to standard unit tests,
/// each case using an isolated `Settings`, so they don't pollute each other and can run in parallel.
final class BreakTimerTests: HBTestCase {

    private final class CountingDelegate: BreakTimerDelegate {
        var fires = 0, rests = 0, changes = 0, willSoon = 0
        func breakTimerDidFire(_ timer: BreakTimer) { fires += 1 }
        func breakTimerDidFinishRest(_ timer: BreakTimer) { rests += 1 }
        func breakTimerWillFireSoon(_ timer: BreakTimer) { willSoon += 1 }
        func breakTimerStateChanged(_ timer: BreakTimer) { changes += 1 }
    }

    /// A deterministic timer with a 1-minute interval and idle/pomodoro/respectful-reminders turned off.
    private func makeTimer(_ configure: (Settings) -> Void = { _ in })
        -> (BreakTimer, CountingDelegate) {
        let s = makeSettings { s in
            s.pomodoroEnabled = false
            s.breakIntervalMinutes = 1
            s.idleEnabled = false
            s.idleResetMinutes = 0
            s.typingAwareDefer = false
            s.gentleHeadsUp = false
            s.skipEscalation = false
            configure(s)
        }
        let d = CountingDelegate()
        let t = BreakTimer(settings: s)
        t.delegate = d
        return (t, d)
    }

    private func tick(_ t: BreakTimer, _ n: Int, idle: TimeInterval = 0,
                      suppress: PauseReason? = nil) {
        for _ in 0..<n { _ = t.tick(idleSeconds: idle, externalSuppress: suppress) }
    }

    func testInitialCountdown() {
        let (t, _) = makeTimer()
        XCTAssertEqual(t.total, 60)
        XCTAssertEqual(t.remaining, 60)
    }

    func testFireResetsAtExpiry() {
        let (t, d) = makeTimer()
        tick(t, 59)
        XCTAssertEqual(t.remaining, 1, "1s left after 59 ticks")
        tick(t, 1)
        XCTAssertEqual(d.fires, 1, "fires once at the deadline")
        XCTAssertEqual(t.remaining, 60, "auto-resets to the full interval after the deadline")
    }

    func testSkipResets() {
        let (t, _) = makeTimer()
        tick(t, 10)
        t.skip()
        XCTAssertEqual(t.remaining, 60, "resets to 60 after skip")
    }

    func testPostponeIsCappedAtDoubleTotal() {
        let (t, _) = makeTimer()
        t.postpone(minutes: 5)
        XCTAssertEqual(t.remaining, 120, "under a 1-minute interval, postpone is capped at total*2 = 120s")
    }

    func testManualPauseHoldsRemaining() {
        let (t, _) = makeTimer()
        t.toggleManualPause()
        let before = t.remaining
        tick(t, 1)
        XCTAssertTrue(t.isPaused)
        XCTAssertEqual(t.pauseReason, .manual)
        XCTAssertEqual(t.remaining, before, "does not decrement while manually paused")
        t.toggleManualPause()
        XCTAssertFalse(t.isPaused, "no longer paused after resume")
    }

    func testIdlePause() {
        let (t, _) = makeTimer { s in
            s.idleEnabled = true
            s.idlePauseSeconds = 60
        }
        let before = t.remaining
        _ = t.tick(idleSeconds: 120, externalSuppress: nil)
        XCTAssertEqual(t.pauseReason, .idle, "idle over threshold → idle pause")
        XCTAssertEqual(t.remaining, before, "does not decrement while idle-paused")
    }

    func testExternalSuppressFullscreen() {
        let (t, _) = makeTimer()
        _ = t.tick(idleSeconds: 0, externalSuppress: .fullscreen)
        XCTAssertEqual(t.pauseReason, .fullscreen, "external suppression → fullscreen pause")
    }

    func testPomodoroCycle() {
        let (t, d) = makeTimer { s in
            s.pomodoroEnabled = true
            s.pomodoroWorkMinutes = 1
            s.pomodoroBreakMinutes = 1
        }
        t.resetCycle()
        XCTAssertEqual(t.phase, .working)
        XCTAssertEqual(t.total, 60, "starts in the work segment, 60s")
        tick(t, 60)
        XCTAssertEqual(d.fires, 1)
        XCTAssertEqual(t.phase, .resting, "work segment ends → enters rest segment")
        XCTAssertEqual(t.total, 60, "rest segment 60s")
        tick(t, 60)
        XCTAssertEqual(d.rests, 1)
        XCTAssertEqual(t.phase, .working, "rest segment ends → back to work segment")
    }

    func testHeadsUpFiresOncePerCycle() {
        let (t, d) = makeTimer { s in s.gentleHeadsUp = true }
        tick(t, 60)
        XCTAssertEqual(d.willSoon, 1, "CR-02: exactly one heads-up tap per cycle")
        XCTAssertEqual(d.fires, 1, "CR-02: still fires normally after the heads-up")
    }

    func testTypingDefersUntilPause() {
        let (t, d) = makeTimer { s in s.typingAwareDefer = true }
        tick(t, 60, idle: 0)  // keep typing
        XCTAssertEqual(d.fires, 0, "CR-01: still typing at the deadline → not fired")
        XCTAssertTrue(t.isDeferring)
        XCTAssertEqual(t.remaining, 0, "CR-01: remaining stays 0 while deferring")
        _ = t.tick(idleSeconds: 2.0, externalSuppress: nil)  // natural pause
        XCTAssertEqual(d.fires, 1, "CR-01: fires immediately after a pause")
        XCTAssertFalse(t.isDeferring)
    }

    func testTypingDeferHasHardCap() {
        let (t, d) = makeTimer { s in s.typingAwareDefer = true }
        tick(t, 110, idle: 0)  // keep typing past the 45s defer cap
        XCTAssertGreaterThanOrEqual(d.fires, 1, "CR-01: fires after the defer cap even while still typing")
    }

    func testEscalationBumpRisesAndDecays() {
        let (t, _) = makeTimer { s in s.skipEscalation = true }
        XCTAssertEqual(t.escalationBump, 0, "CR-05: no bonus initially")
        t.skip(); t.skip(); t.skip()
        XCTAssertEqual(t.escalationBump, 2, "CR-05: consecutive skips → bonus capped at 2")
        tick(t, 120, idle: 2.0)  // two natural completions
        XCTAssertEqual(t.escalationBump, 1, "CR-05: natural completion → bonus decays")
    }
}
