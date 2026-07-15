import XCTest
@testable import HapticBreak

/// Core behavior of the timer state machine — each case uses an isolated `Settings`, so they don't
/// pollute each other and can run in parallel. Covers the working → reminding (acknowledge-to-stop)
/// → resting/working cycle.
final class BreakTimerTests: HBTestCase {

    private final class CountingDelegate: BreakTimerDelegate {
        var fires = 0, pulses = 0, hints = 0, autoPostpones = 0, acks = 0
        var lastAckMethod: AckMethod?
        var rests = 0, changes = 0, willSoon = 0
        func breakTimerDidFire(_ timer: BreakTimer) { fires += 1 }
        func breakTimerPulse(_ timer: BreakTimer) { pulses += 1 }
        func breakTimerShouldShowHint(_ timer: BreakTimer) { hints += 1 }
        func breakTimerDidAutoPostpone(_ timer: BreakTimer) { autoPostpones += 1 }
        func breakTimerDidAcknowledge(_ timer: BreakTimer, method: AckMethod) {
            acks += 1; lastAckMethod = method
        }
        func breakTimerDidFinishRest(_ timer: BreakTimer) { rests += 1 }
        func breakTimerWillFireSoon(_ timer: BreakTimer) { willSoon += 1 }
        func breakTimerStateChanged(_ timer: BreakTimer) { changes += 1 }
    }

    /// Idle seconds representing "active but not typing this instant": above the 1.5s typing-pause
    /// threshold, well below the 30s step-away acknowledgment.
    private let activeIdle: TimeInterval = 5

    /// A deterministic timer with a 1-minute interval, no rest segment, and idle/respectful-reminders off.
    private func makeTimer(_ configure: (Settings) -> Void = { _ in })
        -> (BreakTimer, CountingDelegate) {
        let s = makeSettings { s in
            s.breakIntervalMinutes = 1
            s.restMinutes = 0
            s.idleEnabled = false
            s.idleResetMinutes = 0
            s.typingAwareDefer = false
            s.gentleHeadsUp = false
            s.remindPulseSeconds = 10
            s.remindPulseMax = 2
            s.postponeMinutes = 5
            configure(s)
        }
        let d = CountingDelegate()
        let t = BreakTimer(settings: s)
        t.delegate = d
        return (t, d)
    }

    private func tick(_ t: BreakTimer, _ n: Int, idle: TimeInterval = 5,
                      suppress: PauseReason? = nil) {
        for _ in 0..<n { _ = t.tick(idleSeconds: idle, externalSuppress: suppress) }
    }

    func testInitialCountdown() {
        let (t, _) = makeTimer()
        XCTAssertEqual(t.total, 60)
        XCTAssertEqual(t.remaining, 60)
    }

    func testExpiryEntersReminding() {
        let (t, d) = makeTimer()
        tick(t, 59)
        XCTAssertEqual(t.remaining, 1, "1s left after 59 ticks")
        tick(t, 1)
        XCTAssertEqual(d.fires, 1, "fires once at the deadline")
        XCTAssertEqual(t.phase, .reminding, "deadline → reminding phase, awaiting acknowledgment")
    }

    func testAcknowledgeWithoutRestReturnsToWork() {
        let (t, d) = makeTimer()
        tick(t, 60)
        t.acknowledge(.panel)
        XCTAssertEqual(d.acks, 1)
        XCTAssertEqual(d.lastAckMethod, .panel)
        XCTAssertEqual(t.phase, .working)
        XCTAssertEqual(t.remaining, 60, "ack with restMinutes=0 → fresh work countdown")
    }

    func testAcknowledgeWithRestEntersRestSegment() {
        let (t, d) = makeTimer { s in s.restMinutes = 1 }
        tick(t, 60)
        t.acknowledge(.gesture)
        XCTAssertEqual(t.phase, .resting)
        XCTAssertEqual(t.total, 60, "60s rest segment")
        tick(t, 60)
        XCTAssertEqual(d.rests, 1)
        XCTAssertEqual(t.phase, .working, "rest segment ends → back to work")
    }

    func testAcknowledgeOutsideRemindingIsNoOp() {
        let (t, d) = makeTimer()
        tick(t, 10)
        t.acknowledge(.hotkey)
        XCTAssertEqual(d.acks, 0, "acknowledge is meaningful only while reminding")
        XCTAssertEqual(t.remaining, 50)
    }

    func testRemindingPulsesOnScheduleThenAutoPostpones() {
        let (t, d) = makeTimer()
        tick(t, 60)
        XCTAssertEqual(d.fires, 1, "initial fire counts as nudge 1")
        tick(t, 10)
        XCTAssertEqual(d.pulses, 1, "gentle follow-up nudge after the pulse interval")
        tick(t, 10)
        XCTAssertEqual(d.autoPostpones, 1, "cap (2 nudges) reached → silent auto-postpone")
        XCTAssertEqual(t.phase, .working)
        XCTAssertEqual(t.remaining, min(5 * 60, t.total), "postpone minutes on the clock, capped at one interval")
    }

    func testStepAwayAcknowledgesImplicitly() {
        let (t, d) = makeTimer()
        tick(t, 60)
        _ = t.tick(idleSeconds: 35, externalSuppress: nil)
        XCTAssertEqual(d.lastAckMethod, .stepAway, "idle ≥ 30s during reminding = implicit acknowledgment")
        XCTAssertEqual(t.phase, .working)
    }

    func testRemindingPulseIsTypingAware() {
        let (t, d) = makeTimer { s in s.typingAwareDefer = true }
        tick(t, 60)                      // fires (activeIdle counts as a pause)
        XCTAssertEqual(t.phase, .reminding)
        tick(t, 15, idle: 0)             // keep typing past the pulse interval
        XCTAssertEqual(d.pulses, 0, "nudge deferred while typing")
        tick(t, 1, idle: 2.0)            // natural pause
        XCTAssertEqual(d.pulses, 1, "nudge lands right after a typing pause")
    }

    func testSkipResets() {
        let (t, _) = makeTimer()
        tick(t, 10)
        t.skip()
        XCTAssertEqual(t.remaining, 60, "resets to 60 after skip")
    }

    func testSkipDuringRemindingEndsIt() {
        let (t, d) = makeTimer()
        tick(t, 60)
        t.skip()
        XCTAssertEqual(t.phase, .working)
        XCTAssertEqual(t.remaining, 60)
        XCTAssertEqual(d.acks, 0, "skip is not an acknowledgment")
    }

    func testPostponeIsCappedAtDoubleTotal() {
        let (t, _) = makeTimer()
        t.postpone(minutes: 5)
        XCTAssertEqual(t.remaining, 120, "under a 1-minute interval, postpone is capped at total*2 = 120s")
    }

    func testPostponeDuringRemindingSetsFreshDelay() {
        let (t, _) = makeTimer()
        tick(t, 60)
        t.postpone(minutes: 5)
        XCTAssertEqual(t.phase, .working)
        XCTAssertEqual(t.remaining, min(5 * 60, t.total), "reminding postpone = remind me in N minutes (capped)")
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

    func testIdleDuringRestingKeepsCountingDown() {
        let (t, _) = makeTimer { s in
            s.restMinutes = 1
            s.idleEnabled = true
            s.idlePauseSeconds = 60
        }
        tick(t, 60)
        t.acknowledge(.panel)
        XCTAssertEqual(t.phase, .resting)
        _ = t.tick(idleSeconds: 120, externalSuppress: nil)
        XCTAssertEqual(t.pauseReason, PauseReason.none,
                       "being away during the rest segment IS the rest — no idle pause")
        XCTAssertEqual(t.remaining, 59, "rest countdown keeps running while the user is away")
    }

    func testIdleDuringRemindingAcknowledgesInsteadOfPausing() {
        let (t, d) = makeTimer { s in
            s.idleEnabled = true
            s.idlePauseSeconds = 60
        }
        tick(t, 60)
        XCTAssertEqual(t.phase, .reminding)
        _ = t.tick(idleSeconds: 120, externalSuppress: nil)
        XCTAssertEqual(d.lastAckMethod, .stepAway, "long idle while reminding = stepped away, not a pause")
        XCTAssertEqual(t.phase, .working)
    }

    func testExternalSuppressFullscreen() {
        let (t, _) = makeTimer()
        _ = t.tick(idleSeconds: 0, externalSuppress: .fullscreen)
        XCTAssertEqual(t.pauseReason, .fullscreen, "external suppression → fullscreen pause")
    }

    func testExternalSuppressPausesRemindingPulses() {
        let (t, d) = makeTimer()
        tick(t, 60)
        tick(t, 30, suppress: .meeting)
        XCTAssertEqual(d.pulses, 0, "no nudges while a meeting suppresses the timer")
        XCTAssertEqual(t.phase, .reminding, "still awaiting acknowledgment after the meeting")
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

    func testTurningRestOffMidRestReturnsToWork() {
        let s = makeSettings { s in
            s.breakIntervalMinutes = 1
            s.restMinutes = 1
            s.idleEnabled = false
            s.typingAwareDefer = false
            s.gentleHeadsUp = false
        }
        let t = BreakTimer(settings: s)
        tick(t, 60)
        t.acknowledge(.panel)
        XCTAssertEqual(t.phase, .resting)
        s.restMinutes = 0
        t.applySettingsChange()
        XCTAssertEqual(t.phase, .working, "rest segment removed mid-rest → back to work")
    }

    // MARK: - Temporary work override (the "focus" scene)

    func testTemporaryWorkRunsOneCycleThenRestoresRhythm() {
        let (t, d) = makeTimer()
        t.startTemporaryWork(seconds: 120)
        XCTAssertEqual(t.total, 120, "current cycle uses the temporary length")
        XCTAssertEqual(t.remaining, 120)
        tick(t, 120)
        XCTAssertEqual(d.fires, 1, "the long segment still expires into a normal reminder")
        XCTAssertEqual(t.phase, .reminding)
        t.acknowledge(.panel)
        XCTAssertEqual(t.phase, .working)
        XCTAssertEqual(t.total, 60, "after the focus cycle, back to the configured interval")
    }

    func testTemporaryWorkClearsManualPause() {
        let (t, _) = makeTimer()
        t.toggleManualPause()
        XCTAssertEqual(t.pauseReason, .manual)
        t.startTemporaryWork(seconds: 120)
        XCTAssertEqual(t.pauseReason, PauseReason.none, "choosing to focus means running")
    }

    func testSkipAbandonsTemporaryWork() {
        let (t, _) = makeTimer()
        t.startTemporaryWork(seconds: 120)
        tick(t, 10)
        t.skip()
        XCTAssertEqual(t.total, 60, "skip abandons the focus segment and restores the rhythm")
        XCTAssertEqual(t.remaining, 60)
    }

    func testSceneSuppressionPausesLikeExternal() {
        let (t, _) = makeTimer()
        tick(t, 5, suppress: .scene)
        XCTAssertEqual(t.pauseReason, .scene)
        XCTAssertEqual(t.remaining, 60, "quiet scene freezes the countdown")
        tick(t, 1)
        XCTAssertEqual(t.pauseReason, PauseReason.none, "resumes as soon as the scene lifts")
        XCTAssertEqual(t.remaining, 59)
    }
}
