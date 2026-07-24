import Foundation

/// Headless **smoke gate** for the packaged binary (`HapticBreak --logictest`): drives one pass
/// through the core reminder loop to prove the shipped executable's state machine is wired and
/// sane. Returns 0 when everything passes.
///
/// Deliberately thin: the full behavior matrix (teaching hints, typing-aware defer variants,
/// pause/suppression matrix, RestConfirmer window edges, RingModel quantization edges) lives in
/// `Tests/HapticBreakTests` as the single source of truth — do not re-grow it here.

private final class CountingDelegate: BreakTimerDelegate {
    var fires = 0
    var manualFires = 0
    var pulses = 0
    var hints = 0
    var autoPostpones = 0
    var acks = 0
    var lastAckMethod: AckMethod?
    var rests = 0
    var changes = 0
    var willSoon = 0
    func breakTimerDidFire(_ timer: BreakTimer) { fires += 1 }
    func breakTimerDidFireManually(_ timer: BreakTimer) { manualFires += 1 }
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

/// Test clock: every read advances one second, matching the "one tick = one second" driving
/// convention (BreakTimer reads its clock exactly once per `tick` — a documented contract).
private func autoTickClock() -> () -> Date {
    var current = Date(timeIntervalSinceReferenceDate: 0)
    return { current.addTimeInterval(1); return current }
}

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

func runLogicTests() -> Int32 {
    print("== Core reminder loop smoke test ==")
    // Drive with purely in-memory preferences; never touch the user's real preferences and never write any file.
    let s = Settings(defaults: InMemoryKeyValueStore())
    s.breakIntervalMinutes = 1
    s.restMinutes = 0
    s.idleEnabled = false
    s.idleResetMinutes = 0
    s.typingAwareDefer = false
    s.gentleHeadsUp = false
    s.remindPulseSeconds = 10
    s.remindPulseMax = 2
    s.postponeMinutes = 5

    // Idle 5s: enough of a "typing pause" not to defer, well below the 30s step-away ack.
    let activeIdle = 5.0

    let delegate = CountingDelegate()
    let timer = BreakTimer(settings: s, now: autoTickClock())
    timer.delegate = delegate
    func tick(_ n: Int, idle: Double = activeIdle) {
        for _ in 0..<n { _ = timer.tick(idleSeconds: idle, externalSuppress: nil) }
    }

    // Work segment → reminder → explicit acknowledgment
    check(timer.total == 60 && timer.remaining == 60, "initial work segment = 60s")
    tick(59)
    check(timer.remaining == 1, "after 59 ticks remaining = 1")
    tick(1)
    check(delegate.fires == 1 && timer.phase == .reminding, "deadline fires once → reminding phase")
    timer.acknowledge(.panel)
    check(delegate.acks == 1 && delegate.lastAckMethod == .panel, "explicit acknowledgment delivered with its method")
    check(timer.phase == .working && timer.remaining == 60, "ack with restMinutes=0 → fresh work countdown")

    // Reminding nudges → cap → silent auto-postpone
    tick(60)
    check(delegate.fires == 2, "second cycle reminds again")
    tick(10)
    check(delegate.pulses == 1, "one gentle follow-up nudge after the pulse interval")
    tick(10)
    check(delegate.autoPostpones == 1, "nudge cap reached → silently auto-postponed")
    check(timer.phase == .working && timer.remaining == min(5 * 60, timer.total),
          "auto-postpone → working with postponeMinutes on the clock (capped at one interval)")

    // Implicit acknowledgment by stepping away
    tick(60 * 5)
    check(timer.phase == .reminding, "third cycle reminds")
    _ = timer.tick(idleSeconds: 35, externalSuppress: nil)
    check(delegate.lastAckMethod == .stepAway && timer.phase == .working,
          "stepping away (idle ≥ 30s) acknowledges implicitly")

    // Manual pause freezes; external suppression freezes
    timer.toggleManualPause()
    let held = timer.remaining
    tick(3)
    check(timer.pauseReason == .manual && timer.remaining == held, "manual pause freezes the countdown")
    timer.toggleManualPause()
    _ = timer.tick(idleSeconds: 0, externalSuppress: .fullscreen)
    check(timer.pauseReason == .fullscreen, "external suppression pauses")
    _ = timer.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(timer.pauseReason == PauseReason.none, "resumes when suppression lifts")

    // Work/rest cycle
    s.restMinutes = 1
    let dc = CountingDelegate()
    let tc = BreakTimer(settings: s, now: autoTickClock())
    tc.delegate = dc
    for _ in 0..<60 { _ = tc.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    tc.acknowledge(.hotkey)
    check(tc.phase == .resting && tc.total == 60, "ack with restMinutes=1 → 60s rest segment")
    for _ in 0..<60 { _ = tc.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dc.rests == 1 && tc.phase == .working, "rest segment ends → back to work")
    s.restMinutes = 0

    // Wall-clock anchoring: late ticks catch up; sleep-sized gaps are capped
    s.breakIntervalMinutes = 25
    var wallNow = Date(timeIntervalSinceReferenceDate: 0)
    let tWall = BreakTimer(settings: s) { wallNow }
    wallNow.addTimeInterval(10)
    _ = tWall.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(tWall.remaining == 1490, "wall clock: a 10s-late tick subtracts the full 10s (no drift)")
    wallNow.addTimeInterval(3600)
    _ = tWall.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(tWall.remaining == 1430, "wall clock: a sleep-sized gap counts only the 60s cap")
    s.breakIntervalMinutes = 1

    // Manual "buzz now": manual fire path, never a real deadline
    let dBuzz = CountingDelegate()
    let tBuzz = BreakTimer(settings: s, now: autoTickClock())
    tBuzz.delegate = dBuzz
    tBuzz.fireNow()
    check(dBuzz.manualFires == 1 && dBuzz.fires == 0 && tBuzz.phase == .working,
          "buzz now: manual path, work countdown restarts, no reminding phase")

    // Honest rest: one quick pass (edge cases live in RestConfirmerTests)
    let t0 = Date()
    var rc = RestConfirmer()
    rc.didFire(at: t0)
    check(rc.tick(idleSeconds: 30, now: t0.addingTimeInterval(20)) == true,
          "honest rest: actually stepping away after a reminder counts one real rest")
    check(rc.tick(idleSeconds: 60, now: t0.addingTimeInterval(25)) == false,
          "honest rest: only counted once per reminder")

    // Ring truth: one quick pass (quantization edges live in RingModelTests)
    var ring = RingModel(.init(remaining: 900, total: 900, animated: true))
    check(ring.update(.init(remaining: 840, total: 900, animated: true)) == .deduct(from: 15, to: 14),
          "ring: first grid at 14:00 deducts 15→14 (off-by-one regression lock)")

    print(failures == 0 ? "all passed ✅" : "\(failures) failed ❌")
    return failures == 0 ? 0 : 1
}
