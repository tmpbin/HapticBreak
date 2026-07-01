import Foundation

/// Headless logic self-test: drives the BreakTimer state machine directly to verify core behavior.
/// Run via `HapticBreak --logictest`; returns 0 when everything passes.

private final class CountingDelegate: BreakTimerDelegate {
    var fires = 0
    var rests = 0
    var changes = 0
    var willSoon = 0
    func breakTimerDidFire(_ timer: BreakTimer) { fires += 1 }
    func breakTimerDidFinishRest(_ timer: BreakTimer) { rests += 1 }
    func breakTimerWillFireSoon(_ timer: BreakTimer) { willSoon += 1 }
    func breakTimerStateChanged(_ timer: BreakTimer) { changes += 1 }
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
    print("== BreakTimer logic self-test ==")
    // Drive with purely in-memory preferences; never touch the user's real preferences and never write any file.
    let s = Settings(defaults: InMemoryKeyValueStore())

    // Config: 1-minute interval, idle and pomodoro off, for precise driving.
    s.pomodoroEnabled = false
    s.breakIntervalMinutes = 1
    s.idleEnabled = false
    s.idleResetMinutes = 0
    // Turn off "respectful reminders" for deterministic core checks (their behavior is tested separately).
    s.typingAwareDefer = false
    s.gentleHeadsUp = false
    s.skipEscalation = false

    let delegate = CountingDelegate()
    let timer = BreakTimer(settings: s)
    timer.delegate = delegate

    check(timer.total == 60, "initial total = 60s (1 minute)")
    check(timer.remaining == 60, "initial remaining = 60s")

    for _ in 0..<59 { _ = timer.tick(idleSeconds: 0, externalSuppress: nil) }
    check(timer.remaining == 1, "after 59 ticks remaining = 1")

    _ = timer.tick(idleSeconds: 0, externalSuppress: nil)
    check(delegate.fires == 1, "fires the reminder once at the deadline")
    check(timer.remaining == 60, "auto-resets to the full interval after the deadline")

    // Skip
    for _ in 0..<10 { _ = timer.tick(idleSeconds: 0, externalSuppress: nil) }
    timer.skip()
    check(timer.remaining == 60, "remaining resets to 60 after skip")

    // Postpone (capped at total*2)
    timer.postpone(minutes: 5)
    check(timer.remaining == 120, "postponing 5 minutes is capped at 120s under a 1-minute interval")

    // Manual pause holds
    timer.toggleManualPause()
    let beforePause = timer.remaining
    _ = timer.tick(idleSeconds: 0, externalSuppress: nil)
    check(timer.isPaused && timer.pauseReason == .manual, "state is manual after manual pause")
    check(timer.remaining == beforePause, "does not decrement while manually paused")
    timer.toggleManualPause()
    check(!timer.isPaused, "no longer paused after resume")

    // Idle pause
    s.idleEnabled = true
    s.idlePauseSeconds = 60
    let beforeIdle = timer.remaining
    _ = timer.tick(idleSeconds: 120, externalSuppress: nil)
    check(timer.pauseReason == .idle, "idle over threshold → idle pause")
    check(timer.remaining == beforeIdle, "does not decrement while idle-paused")

    // External suppression (fullscreen)
    _ = timer.tick(idleSeconds: 0, externalSuppress: .fullscreen)
    check(timer.pauseReason == .fullscreen, "external suppression → fullscreen pause")

    // Pomodoro cycle
    s.idleEnabled = false
    s.pomodoroEnabled = true
    s.pomodoroWorkMinutes = 1
    s.pomodoroBreakMinutes = 1
    timer.resetCycle()
    check(timer.phase == .working && timer.total == 60, "pomodoro: starts in the work segment, 60s")
    delegate.fires = 0; delegate.rests = 0
    for _ in 0..<60 { _ = timer.tick(idleSeconds: 0, externalSuppress: nil) }
    check(delegate.fires == 1 && timer.phase == .resting, "work segment ends → enters rest segment")
    check(timer.total == 60, "rest segment lasts 60s")
    for _ in 0..<60 { _ = timer.tick(idleSeconds: 0, externalSuppress: nil) }
    check(delegate.rests == 1 && timer.phase == .working, "rest segment ends → back to work segment")

    // CR-02 heads-up tap: exactly once per cycle, and doesn't affect the real reminder
    s.pomodoroEnabled = false
    s.breakIntervalMinutes = 1
    s.gentleHeadsUp = true
    s.typingAwareDefer = false
    let d2 = CountingDelegate()
    let t2 = BreakTimer(settings: s)
    t2.delegate = d2
    for _ in 0..<60 { _ = t2.tick(idleSeconds: 0, externalSuppress: nil) }
    check(d2.willSoon == 1, "CR-02: exactly one heads-up tap per cycle")
    check(d2.fires == 1, "CR-02: reminder still fires normally after the heads-up")
    s.gentleHeadsUp = false

    // CR-01 typing-aware defer: if still typing at the deadline, defer; fire immediately after a pause
    s.typingAwareDefer = true
    let d3 = CountingDelegate()
    let t3 = BreakTimer(settings: s)
    t3.delegate = d3
    for _ in 0..<60 { _ = t3.tick(idleSeconds: 0, externalSuppress: nil) }  // keep typing
    check(d3.fires == 0 && t3.isDeferring, "CR-01: still typing at the deadline → deferred, not fired")
    check(t3.remaining == 0, "CR-01: remaining stays 0 while deferring")
    _ = t3.tick(idleSeconds: 2.0, externalSuppress: nil)                    // natural pause
    check(d3.fires == 1 && !t3.isDeferring, "CR-01: fires immediately once a pause appears and clears the defer")

    // CR-01 defer cap: fires even if typing continues past the limit
    let d4 = CountingDelegate()
    let t4 = BreakTimer(settings: s)
    t4.delegate = d4
    for _ in 0..<110 { _ = t4.tick(idleSeconds: 0, externalSuppress: nil) }
    check(d4.fires >= 1, "CR-01: fires after the 45s defer cap even while still typing")
    s.typingAwareDefer = false

    // CR-05 escalation bump: skips accumulate a bonus (capped at 2), natural completion decays it
    s.skipEscalation = true
    let d5 = CountingDelegate()
    let t5 = BreakTimer(settings: s)
    t5.delegate = d5
    check(t5.escalationBump == 0, "CR-05: no escalation bump initially")
    t5.skip(); t5.skip(); t5.skip()
    check(t5.escalationBump == 2, "CR-05: consecutive skips → bonus capped at 2")
    for _ in 0..<120 { _ = t5.tick(idleSeconds: 2.0, externalSuppress: nil) } // two natural completions
    check(t5.escalationBump == 1, "CR-05: natural completion → bonus decays")
    s.skipEscalation = false

    // CR-04 honest rest: only count a real rest if you "actually leave" after a reminder (window 120s / idle 30s)
    let t0 = Date()
    var rc = RestConfirmer()
    check(rc.tick(idleSeconds: 100, now: t0) == false, "CR-04: leaving without a reminder isn't counted as a rest")
    rc.didFire(at: t0)
    check(rc.tick(idleSeconds: 0, now: t0.addingTimeInterval(5)) == false, "CR-04: still active after a reminder → not counted")
    check(rc.tick(idleSeconds: 30, now: t0.addingTimeInterval(20)) == true, "CR-04: actually left after a reminder → count one real rest")
    check(rc.tick(idleSeconds: 60, now: t0.addingTimeInterval(25)) == false, "CR-04: only counted once per reminder")
    var rc2 = RestConfirmer()
    rc2.didFire(at: t0)
    check(rc2.tick(idleSeconds: 0, now: t0.addingTimeInterval(121)) == false, "CR-04: still not left past the window → this one is void")
    check(rc2.tick(idleSeconds: 60, now: t0.addingTimeInterval(130)) == false, "CR-04: leaving after voiding doesn't back-fill a count")

    // === Ring per-minute deduction (L1 RingModel pure logic; animation lives in L2/L3, this only locks the "truth") ===
    print("-- Ring per-minute deduction (RingModel) --")
    func ringEvents(total: Int, animated: Bool = true) -> [RingModel.Event] {
        var m = RingModel(.init(remaining: total, total: total, animated: animated))
        var out: [RingModel.Event] = []
        for r in stride(from: total - 1, through: 0, by: -1) {
            let e = m.update(.init(remaining: r, total: total, animated: animated))
            if case .none = e {} else { out.append(e) }
        }
        return out
    }
    func isDeduct(_ e: RingModel.Event, _ from: Int, _ to: Int) -> Bool {
        if case let .deduct(f, t) = e { return f == from && t == to }
        return false
    }

    check(RingModel.gridCount(900) == 15 && RingModel.litGrids(900) == 15, "ring: 15 minutes = 15 grids, full ring lights 15")
    check(RingModel.litGrids(841) == 15 && RingModel.litGrids(840) == 14, "ring: remaining 841 still 15 grids, 840 (14:00) drops to 14 grids")

    let evs = ringEvents(total: 900)
    check(evs.count == 15, "ring: a natural 15-minute countdown yields 15 deductions")
    check(evs.allSatisfy { if case .deduct = $0 { return true } else { return false } }, "ring: all deducts throughout (no misclassified align)")
    check(evs.first.map { isDeduct($0, 15, 14) } ?? false, "ring: first grid at 14:00 deducts 15→14 (off-by-one regression lock)")
    check(evs.last.map { isDeduct($0, 1, 0) } ?? false, "ring: last grid deducts 1→0")

    var mPause = RingModel(.init(remaining: 900, total: 900, animated: false))
    let evPause = mPause.update(.init(remaining: 840, total: 900, animated: false))
    check({ if case .align(14) = evPause { return true } else { return false } }(), "ring: crossing a minute while paused → align (no bullet emitted)")

    var mJump = RingModel(.init(remaining: 300, total: 600, animated: true))    // 5/10 grids
    let evJump = mJump.update(.init(remaining: 540, total: 600, animated: true)) // jump to 9 grids
    check({ if case .align(9) = evJump { return true } else { return false } }(), "ring: remaining jumps up → align(9) (no spurious deduct)")

    // The isolated suite is cleared on defer; no need to restore real settings.
    print(failures == 0 ? "all passed ✅" : "\(failures) failed ❌")
    return failures == 0 ? 0 : 1
}
