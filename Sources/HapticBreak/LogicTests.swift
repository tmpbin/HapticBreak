import Foundation

/// Headless logic self-test: drives the BreakTimer state machine directly to verify core behavior.
/// Run via `HapticBreak --logictest`; returns 0 when everything passes.

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

/// Test clock: every read advances one second, matching the suite's "one tick = one second"
/// driving convention (BreakTimer reads its clock exactly once per `tick` — a documented contract).
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
    print("== BreakTimer logic self-test ==")
    // Drive with purely in-memory preferences; never touch the user's real preferences and never write any file.
    let s = Settings(defaults: InMemoryKeyValueStore())

    // Config: 1-minute interval, no rest segment, idle off, for precise driving.
    s.breakIntervalMinutes = 1
    s.restMinutes = 0
    s.idleEnabled = false
    s.idleResetMinutes = 0
    // Turn off "respectful reminders" for deterministic core checks (their behavior is tested separately).
    s.typingAwareDefer = false
    s.gentleHeadsUp = false
    // Reminding phase parameters: nudge every 10s, at most 2 nudges, then auto-postpone 5 min.
    s.remindPulseSeconds = 10
    s.remindPulseMax = 2
    s.postponeMinutes = 5

    // Idle 5s everywhere below: enough of a "typing pause" not to defer, well below the 30s step-away ack.
    let activeIdle = 5.0

    let delegate = CountingDelegate()
    let timer = BreakTimer(settings: s, now: autoTickClock())
    timer.delegate = delegate

    check(timer.total == 60, "initial total = 60s (1 minute)")
    check(timer.remaining == 60, "initial remaining = 60s")

    for _ in 0..<59 { _ = timer.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(timer.remaining == 1, "after 59 ticks remaining = 1")

    _ = timer.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(delegate.fires == 1, "fires the reminder once at the deadline")
    check(timer.phase == .reminding, "deadline → enters the reminding phase (awaiting acknowledgment)")

    // Acknowledge (panel) with no rest segment → back to a fresh work countdown
    timer.acknowledge(.panel)
    check(delegate.acks == 1 && delegate.lastAckMethod == .panel, "explicit acknowledgment is delivered with its method")
    check(timer.phase == .working && timer.remaining == 60, "ack with restMinutes=0 → fresh work countdown")

    // Reminding pulses: initial fire counts as nudge 1; nudge 2 at +10s; cap(2) → auto-postpone at +20s
    for _ in 0..<60 { _ = timer.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(timer.phase == .reminding && delegate.fires == 2, "second cycle fires and reminds again")
    for _ in 0..<10 { _ = timer.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(delegate.pulses == 1, "one gentle follow-up nudge after the pulse interval")
    for _ in 0..<10 { _ = timer.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(delegate.autoPostpones == 1, "nudge cap reached → silently auto-postponed")
    check(timer.phase == .working && timer.remaining == min(5 * 60, timer.total),
          "auto-postpone → working with postponeMinutes on the clock (capped at one interval)")

    // Teaching hint after 3 unanswered nudges (pulseMax=6, hint fires once at pulse 3)
    s.remindPulseMax = 6
    let dHint = CountingDelegate()
    let tHint = BreakTimer(settings: s, now: autoTickClock())
    tHint.delegate = dHint
    for _ in 0..<60 { _ = tHint.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(tHint.phase == .reminding && dHint.fires == 1, "hint test: reminding begins")
    for _ in 0..<10 { _ = tHint.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dHint.pulses == 1 && dHint.hints == 0, "hint test: pulse 2, no hint yet")
    for _ in 0..<10 { _ = tHint.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dHint.pulses == 2 && dHint.hints == 1, "hint test: pulse 3 → teaching hint fires once")
    for _ in 0..<10 { _ = tHint.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dHint.hints == 1, "hint test: hint doesn't fire again on subsequent pulses")
    for _ in 0..<10 { _ = tHint.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    for _ in 0..<10 { _ = tHint.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    for _ in 0..<10 { _ = tHint.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dHint.autoPostpones == 1, "hint test: auto-postpone at cap(6)")

    // Teaching hint with low cap (pulseMax=2): hint fires at pulse 2 (min(3,2)=2), then auto-postpone
    s.remindPulseMax = 2
    let dLow = CountingDelegate()
    let tLow = BreakTimer(settings: s, now: autoTickClock())
    tLow.delegate = dLow
    for _ in 0..<60 { _ = tLow.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(tLow.phase == .reminding && dLow.fires == 1, "low-cap hint: reminding begins")
    for _ in 0..<10 { _ = tLow.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dLow.pulses == 1 && dLow.hints == 1, "low-cap hint: pulse 2 → hint fires (min(3,2)=2)")
    for _ in 0..<10 { _ = tLow.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dLow.autoPostpones == 1, "low-cap hint: auto-postpone at cap(2)")

    // Teaching hint with cap=1: the initial fire is the only nudge, so the hint rides on it
    s.remindPulseMax = 1
    let dOne = CountingDelegate()
    let tOne = BreakTimer(settings: s, now: autoTickClock())
    tOne.delegate = dOne
    for _ in 0..<60 { _ = tOne.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(tOne.phase == .reminding && dOne.fires == 1 && dOne.hints == 1,
          "cap-1 hint: teaching hint fires with the initial reminder (min(3,1)=1)")
    for _ in 0..<10 { _ = tOne.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dOne.autoPostpones == 1 && dOne.hints == 1, "cap-1 hint: auto-postpone, hint stays once")
    s.remindPulseMax = 2

    // Implicit acknowledgment: actually stepping away (idle ≥ 30s) during reminding
    timer.restartWorking()
    for _ in 0..<60 { _ = timer.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(timer.phase == .reminding, "third cycle reminds")
    _ = timer.tick(idleSeconds: 35, externalSuppress: nil)
    check(delegate.lastAckMethod == .stepAway, "stepping away (idle ≥ 30s) acknowledges implicitly")
    check(timer.phase == .working, "step-away ack with restMinutes=0 → back to work countdown")

    // Typing-aware nudge deferral: a nudge never lands mid-typing; it waits for a natural pause
    s.typingAwareDefer = true
    let dPulse = CountingDelegate()
    let tPulse = BreakTimer(settings: s, now: autoTickClock())
    tPulse.delegate = dPulse
    for _ in 0..<60 { _ = tPulse.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(tPulse.phase == .reminding && dPulse.fires == 1, "reminding begins (typing-aware active)")
    for _ in 0..<15 { _ = tPulse.tick(idleSeconds: 0, externalSuppress: nil) }   // keep typing past the interval
    check(dPulse.pulses == 0, "nudge deferred while typing")
    _ = tPulse.tick(idleSeconds: 2.0, externalSuppress: nil)                     // natural pause
    check(dPulse.pulses == 1, "nudge lands right after a typing pause")
    s.typingAwareDefer = false

    // Skip
    let d0 = CountingDelegate()
    let t0m = BreakTimer(settings: s, now: autoTickClock())
    t0m.delegate = d0
    for _ in 0..<10 { _ = t0m.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    t0m.skip()
    check(t0m.remaining == 60, "remaining resets to 60 after skip")

    // Postpone from working (capped at total*2)
    t0m.postpone(minutes: 5)
    check(t0m.remaining == 120, "postponing 5 minutes is capped at 120s under a 1-minute interval")

    // Postpone from reminding = "not now, remind me in N minutes"
    for _ in 0..<120 { _ = t0m.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(t0m.phase == .reminding, "cycle expires into reminding")
    t0m.postpone(minutes: 5)
    check(t0m.phase == .working && t0m.remaining == 60, "postpone during reminding → working, capped at one interval")

    // Manual pause holds
    let tp = BreakTimer(settings: s, now: autoTickClock())
    tp.toggleManualPause()
    let beforePause = tp.remaining
    _ = tp.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(tp.isPaused && tp.pauseReason == .manual, "state is manual after manual pause")
    check(tp.remaining == beforePause, "does not decrement while manually paused")
    tp.toggleManualPause()
    check(!tp.isPaused, "no longer paused after resume")

    // Idle pause
    s.idleEnabled = true
    s.idlePauseSeconds = 60
    let beforeIdle = tp.remaining
    _ = tp.tick(idleSeconds: 120, externalSuppress: nil)
    check(tp.pauseReason == .idle, "idle over threshold → idle pause")
    check(tp.remaining == beforeIdle, "does not decrement while idle-paused")

    // External suppression (fullscreen)
    _ = tp.tick(idleSeconds: 0, externalSuppress: .fullscreen)
    check(tp.pauseReason == .fullscreen, "external suppression → fullscreen pause")

    // Quiet-scene suppression behaves like other external suppressors and lifts cleanly
    _ = tp.tick(idleSeconds: 0, externalSuppress: .scene)
    check(tp.pauseReason == .scene, "quiet scene → scene pause")
    _ = tp.tick(idleSeconds: 0, externalSuppress: nil)
    check(tp.pauseReason == PauseReason.none, "scene expiry → resumes on its own")

    // Focus scene: one temporary long work segment, then back to the configured rhythm
    s.idleEnabled = false
    let df = CountingDelegate()
    let tf = BreakTimer(settings: s, now: autoTickClock())
    tf.delegate = df
    tf.startTemporaryWork(seconds: 120)
    check(tf.total == 120 && tf.remaining == 120, "focus scene: current cycle uses the temporary length")
    for _ in 0..<120 { _ = tf.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(df.fires == 1 && tf.phase == .reminding, "focus scene: still expires into a normal reminder")
    tf.acknowledge(.panel)
    check(tf.total == 60, "focus scene: next cycle returns to the configured interval")
    s.idleEnabled = true

    // Work/rest cycle (unified model): ack enters a timed rest, rest expiry returns to work
    s.idleEnabled = false
    s.restMinutes = 1
    let dc = CountingDelegate()
    let tc = BreakTimer(settings: s, now: autoTickClock())
    tc.delegate = dc
    check(tc.phase == .working && tc.total == 60, "cycle: starts in the work segment, 60s")
    for _ in 0..<60 { _ = tc.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dc.fires == 1 && tc.phase == .reminding, "cycle: work segment ends → reminding")
    tc.acknowledge(.hotkey)
    check(tc.phase == .resting && tc.total == 60, "cycle: ack with restMinutes=1 → 60s rest segment")
    for _ in 0..<60 { _ = tc.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(dc.rests == 1 && tc.phase == .working, "cycle: rest segment ends → back to work segment")
    s.restMinutes = 0

    // CR-02 heads-up tap: exactly once per cycle, and doesn't affect the real reminder
    s.gentleHeadsUp = true
    s.typingAwareDefer = false
    let d2 = CountingDelegate()
    let t2 = BreakTimer(settings: s, now: autoTickClock())
    t2.delegate = d2
    for _ in 0..<60 { _ = t2.tick(idleSeconds: activeIdle, externalSuppress: nil) }
    check(d2.willSoon == 1, "CR-02: exactly one heads-up tap per cycle")
    check(d2.fires == 1, "CR-02: reminder still fires normally after the heads-up")
    s.gentleHeadsUp = false

    // CR-01 typing-aware defer: if still typing at the deadline, defer; fire immediately after a pause
    s.typingAwareDefer = true
    let d3 = CountingDelegate()
    let t3 = BreakTimer(settings: s, now: autoTickClock())
    t3.delegate = d3
    for _ in 0..<60 { _ = t3.tick(idleSeconds: 0, externalSuppress: nil) }  // keep typing
    check(d3.fires == 0 && t3.isDeferring, "CR-01: still typing at the deadline → deferred, not fired")
    check(t3.remaining == 0, "CR-01: remaining stays 0 while deferring")
    _ = t3.tick(idleSeconds: 2.0, externalSuppress: nil)                    // natural pause
    check(d3.fires == 1 && !t3.isDeferring, "CR-01: fires immediately once a pause appears and clears the defer")

    // CR-01 defer cap: fires even if typing continues past the limit
    let d4 = CountingDelegate()
    let t4 = BreakTimer(settings: s, now: autoTickClock())
    t4.delegate = d4
    for _ in 0..<110 { _ = t4.tick(idleSeconds: 0, externalSuppress: nil) }
    check(d4.fires >= 1, "CR-01: fires after the 45s defer cap even while still typing")
    s.typingAwareDefer = false

    // Wall-clock anchoring: a delayed tick applies the real elapsed time; sleep-sized gaps are capped
    s.breakIntervalMinutes = 25   // 1500s, so the 60s discontinuity cap is observable
    var wallNow = Date(timeIntervalSinceReferenceDate: 0)
    let dWall = CountingDelegate()
    let tWall = BreakTimer(settings: s) { wallNow }
    tWall.delegate = dWall
    wallNow.addTimeInterval(10)   // The tick arrives 10s late (App Nap coalescing)
    _ = tWall.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(tWall.remaining == 1490, "wall clock: a 10s-late tick subtracts the full 10s (no drift)")
    wallNow.addTimeInterval(3600) // System slept for an hour
    _ = tWall.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(tWall.remaining == 1430, "wall clock: a sleep-sized gap counts only the 60s cap")
    tWall.toggleManualPause()
    wallNow.addTimeInterval(30)
    _ = tWall.tick(idleSeconds: activeIdle, externalSuppress: nil)
    tWall.toggleManualPause()
    wallNow.addTimeInterval(1)
    _ = tWall.tick(idleSeconds: activeIdle, externalSuppress: nil)
    check(tWall.remaining == 1429, "wall clock: paused time is discarded, resume counts normally")
    s.breakIntervalMinutes = 1

    // Manual "buzz now": plays via the manual path and never opens the honest-rest window
    let dBuzz = CountingDelegate()
    let tBuzz = BreakTimer(settings: s, now: autoTickClock())
    tBuzz.delegate = dBuzz
    tBuzz.fireNow()
    check(dBuzz.manualFires == 1 && dBuzz.fires == 0, "buzz now: manual fire path, not a real deadline")
    check(tBuzz.phase == .working && tBuzz.remaining == 60, "buzz now: work countdown restarts, no reminding phase")

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
