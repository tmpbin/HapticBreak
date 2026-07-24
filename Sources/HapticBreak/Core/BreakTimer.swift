import Foundation

enum BreakPhase {
    case working    // Counting down to the next reminder
    case reminding  // Reminder fired, gently re-nudging until the user acknowledges (or steps away)
    case resting    // Timed rest segment (restMinutes > 0)
}

enum PauseReason: Equatable {
    case none
    case manual
    case idle
    case focus
    case fullscreen
    case meeting
    case scene      // A temporary quiet scene ("done for today"), self-restoring on expiry

    var isPaused: Bool { self != .none }
}

/// How a reminding cycle was acknowledged (drives statistics / future delivery metrics).
enum AckMethod {
    case gesture    // Three-finger triple-tap on the trackpad
    case hotkey     // Global shortcut
    case panel      // "Start break" button in the control panel / context menu
    case stepAway   // Implicit: the user actually stepped away (idle)
}

protocol BreakTimerDelegate: AnyObject {
    /// Work segment ended: the reminder fires (first nudge of the reminding phase).
    func breakTimerDidFire(_ timer: BreakTimer)
    /// A manual "buzz now" (`fireNow`): plays the reminder but is NOT a real deadline — it must not
    /// open the honest-rest confirmation window, or a test buzz followed by stepping away would
    /// inflate the break statistics.
    func breakTimerDidFireManually(_ timer: BreakTimer)
    /// Reminding phase: a follow-up nudge (the reminder hasn't been acknowledged yet).
    /// Every nudge replays the full user preset identically.
    func breakTimerPulse(_ timer: BreakTimer)
    /// Unanswered nudges reached `min(3, remindPulseMax)`: show a teaching hint so the user
    /// learns how to acknowledge. Called once per reminding cycle.
    func breakTimerShouldShowHint(_ timer: BreakTimer)
    /// Reminding phase hit its nudge cap without acknowledgment → auto-postponed.
    func breakTimerDidAutoPostpone(_ timer: BreakTimer)
    /// The reminding phase was acknowledged (explicitly or by stepping away).
    func breakTimerDidAcknowledge(_ timer: BreakTimer, method: AckMethod)
    /// Rest segment ended: back to work.
    func breakTimerDidFinishRest(_ timer: BreakTimer)
    /// Reminder approaching (early heads-up): used for the faint "heads-up tap".
    func breakTimerWillFireSoon(_ timer: BreakTimer)
    /// Any state change (used to refresh the UI).
    func breakTimerStateChanged(_ timer: BreakTimer)
}

/// Reminder countdown state machine. Driven about once per second by the outside (AppController)
/// via `tick`; the countdown itself is anchored to the wall clock (see `tick`), so delayed or
/// coalesced ticks can never stretch the interval.
final class BreakTimer {

    weak var delegate: BreakTimerDelegate?
    private let settings: Settings
    /// Injectable clock for deterministic tests. Contract: read **exactly once per `tick`** (tests
    /// rely on this to drive "one tick = one second" with an auto-advancing clock).
    private let now: () -> Date

    private(set) var phase: BreakPhase = .working
    private(set) var pauseReason: PauseReason = .none
    private(set) var remaining: Int = 0
    private(set) var total: Int = 1

    private var manualPaused = false
    private var idleResetArmed = false   // Whether the current idle cycle has already performed a "timer reset"

    // Wall-clock anchoring: the countdown subtracts the *measured* elapsed time between ticks, not
    // "one second per tick" — App Nap timer coalescing, a busy main thread, or missed ticks would
    // otherwise silently stretch a 25-minute interval.
    private var lastTick: Date
    /// Fractional elapsed seconds carried to the next tick (whole seconds are applied immediately).
    private var elapsedCarry: Double = 0
    /// A tick gap longer than this is a discontinuity (system sleep / clock jump), not work time —
    /// only the cap is counted. Long absences are the idle reset / idle pause's job, not the clock's.
    private static let maxCountedGap: TimeInterval = 60

    /// One-cycle work length override (the "focus for 90 minutes" scene): consumed when the cycle
    /// expires into reminding, cleared by any action that abandons the cycle (skip / restart / reset).
    private var workOverrideSeconds: Int?

    // Respectful / smart reminders (CR-01 / CR-02)
    private var headsUpFired = false        // Whether a heads-up has fired this cycle
    private(set) var isDeferring = false     // Deferring because of typing
    private var deferredSeconds = 0

    // Reminding phase (acknowledge-to-stop)
    private(set) var pulsesFired = 0         // Nudges emitted this reminding cycle (initial fire counts as 1)
    private var remindingSeconds = 0         // Seconds elapsed in the reminding phase (pause-aware)
    private var nextPulseAt = 0              // remindingSeconds threshold for the next nudge
    private var pulseDeferSeconds = 0        // Typing-aware defer applied to each individual nudge
    private var hintShown = false

    private let typingPauseThreshold: TimeInterval = 1.5
    private let maxDeferSeconds = 45
    /// No-input seconds during reminding that count as "actually stepped away" → implicit acknowledgment.
    /// Matches `RestConfirmer.idleThreshold`, so the honest-rest confirmation follows naturally.
    private let ackIdleThreshold: TimeInterval = 30

    init(settings: Settings, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.now = now
        self.lastTick = now()
        configureForCurrentPhase(reset: true)
    }

    var isPaused: Bool { pauseReason.isPaused }

    private func preWarnThreshold() -> Int { min(30, max(2, total / 2)) }

    private func resetCycleFlags() {
        headsUpFired = false
        isDeferring = false
        deferredSeconds = 0
        pulsesFired = 0
        remindingSeconds = 0
        nextPulseAt = 0
        pulseDeferSeconds = 0
        hintShown = false
    }

    // MARK: - Configuration

    private func workSeconds() -> Int { workOverrideSeconds ?? max(1, settings.workMinutes * 60) }
    private func restSeconds() -> Int { max(1, settings.restMinutes * 60) }

    private func configureForCurrentPhase(reset: Bool) {
        switch phase {
        case .working:   total = workSeconds()
        case .resting:   total = restSeconds()
        case .reminding: total = 1   // No countdown while awaiting acknowledgment
        }
        if phase == .reminding { remaining = 0; return }
        if reset { remaining = total }
        else { remaining = min(remaining, total) }
    }

    /// Call after settings change (interval / rest length, etc.): update total and clamp remaining
    /// so it never exceeds the new total.
    func applySettingsChange() {
        // When the rest segment is turned off mid-rest, always return to the work segment.
        if phase == .resting && settings.restMinutes == 0 {
            phase = .working
            configureForCurrentPhase(reset: true)
        } else {
            configureForCurrentPhase(reset: false)
        }
        delegate?.breakTimerStateChanged(self)
    }

    // MARK: - Per-second driver

    /// Called about once per second by the outside.
    /// - Parameters:
    ///   - idleSeconds: Seconds since the last input.
    ///   - externalSuppress: External suppression reason (fullscreen/Focus), nil if none.
    /// - Returns: Whether this second counts as "active work time".
    @discardableResult
    func tick(idleSeconds: TimeInterval, externalSuppress: PauseReason?) -> Bool {
        // 0) Measure the real elapsed wall time since the previous tick (the clock is read exactly
        //    once per tick — see `now`). Negative gaps (clock set back) count as zero; gaps beyond
        //    `maxCountedGap` count only the cap.
        let tickDate = now()
        let gap = tickDate.timeIntervalSince(lastTick)
        lastTick = tickDate

        // 1) Compute idle reset (work segment only, enabled and threshold > 0)
        if settings.idleEnabled, settings.idleResetMinutes > 0, phase == .working {
            if idleSeconds >= Double(settings.idleResetMinutes * 60) {
                if !idleResetArmed {
                    idleResetArmed = true
                    remaining = total // A long absence counts as already rested; restart the timer on return
                }
            } else if idleSeconds < 2 {
                idleResetArmed = false
            }
        }

        // 2) Compute pause reason: manual > external (fullscreen/Focus) > idle.
        //    Idle pauses only the work segment: while reminding it's the implicit acknowledgment
        //    (handled below), and while resting, being away IS the rest — freezing the rest
        //    countdown would punish exactly the behavior the app asks for.
        let idlePaused = phase == .working
            && settings.idleEnabled && idleSeconds >= Double(settings.idlePauseSeconds)
        let newReason: PauseReason
        if manualPaused { newReason = .manual }
        else if let ext = externalSuppress { newReason = ext }
        else if idlePaused { newReason = .idle }
        else { newReason = .none }

        let changed = newReason != pauseReason
        pauseReason = newReason

        if pauseReason.isPaused {
            elapsedCarry = 0   // Paused time never counts toward the countdown
            if changed { delegate?.breakTimerStateChanged(self) }
            return false
        }

        // Whole seconds to apply this tick (the fraction carries forward).
        elapsedCarry += min(max(gap, 0), Self.maxCountedGap)
        let seconds = Int(elapsedCarry)
        elapsedCarry -= Double(seconds)

        // 3) Reminding phase: wait for acknowledgment, re-nudging gently on a bounded schedule
        if phase == .reminding {
            tickReminding(idleSeconds: idleSeconds, seconds: seconds)
            delegate?.breakTimerStateChanged(self)
            return false
        }

        // 4) Approaching reminder: one early "heads-up tap" (CR-02)
        if settings.gentleHeadsUp, phase == .working, !headsUpFired,
           remaining > 0, remaining <= preWarnThreshold() {
            headsUpFired = true
            delegate?.breakTimerWillFireSoon(self)
        }

        // 5) Decrement by the elapsed whole seconds (never below 0)
        if remaining > 0 { remaining = max(0, remaining - seconds) }

        // 6) Expiry: typing-aware defer (CR-01) or normal expiry
        if remaining <= 0 {
            if phase == .working, settings.typingAwareDefer,
               idleSeconds < typingPauseThreshold, deferredSeconds < maxDeferSeconds {
                deferredSeconds += max(1, seconds)
                if !isDeferring { isDeferring = true }
                delegate?.breakTimerStateChanged(self)
                return true   // Still working (typing)
            }
            handleExpiry()
        }
        delegate?.breakTimerStateChanged(self)
        return phase == .working
    }

    /// One reminding-phase second: implicit acknowledgment when the user actually steps away;
    /// otherwise replay the full user preset every `remindPulseSeconds`, auto-postponing at the cap.
    /// The teaching hint fires once per cycle, on the nudge that reaches `min(3, cap)`.
    private func tickReminding(idleSeconds: TimeInterval, seconds: Int) {
        if idleSeconds >= ackIdleThreshold {
            completeAcknowledge(.stepAway)
            return
        }
        remindingSeconds += seconds
        guard remindingSeconds >= nextPulseAt else { return }
        if settings.typingAwareDefer, idleSeconds < typingPauseThreshold,
           pulseDeferSeconds < maxDeferSeconds {
            pulseDeferSeconds += max(1, seconds)
            return
        }
        pulseDeferSeconds = 0
        let cap = max(1, settings.remindPulseMax)
        if pulsesFired >= cap {
            autoPostpone()
        } else {
            pulsesFired += 1
            nextPulseAt = remindingSeconds + max(10, settings.effectivePulseSeconds)
            delegate?.breakTimerPulse(self)
            maybeShowHint()
        }
    }

    /// Teaching hint: fire once per reminding cycle, on the nudge that reaches `min(3, cap)` —
    /// the cap bound guarantees the hint still appears at the *last* nudge when the user has
    /// lowered `remindPulseMax` below 3 (including 1, where the initial fire is the only nudge).
    private func maybeShowHint() {
        let cap = max(1, settings.remindPulseMax)
        guard !hintShown, pulsesFired >= min(3, cap) else { return }
        hintShown = true
        delegate?.breakTimerShouldShowHint(self)
    }

    private func handleExpiry() {
        if phase == .working {
            workOverrideSeconds = nil   // The temporary long segment ran its course — back to the normal rhythm
            resetCycleFlags()
            phase = .reminding
            configureForCurrentPhase(reset: true)
            pulsesFired = 1
            nextPulseAt = max(10, settings.effectivePulseSeconds)
            delegate?.breakTimerDidFire(self)
            maybeShowHint()   // cap == 1: the initial fire is the only nudge this cycle
        } else {
            resetCycleFlags()
            delegate?.breakTimerDidFinishRest(self)
            phase = .working
            configureForCurrentPhase(reset: true)
        }
    }

    /// Reminding cap reached without acknowledgment: silently postpone — gentle but not giving up.
    private func autoPostpone() {
        resetCycleFlags()
        phase = .working
        configureForCurrentPhase(reset: true)
        remaining = min(max(1, settings.postponeMinutes) * 60, total)
        delegate?.breakTimerDidAutoPostpone(self)
    }

    // MARK: - Acknowledgment

    /// Acknowledge the current reminder (gesture / hotkey / panel). No-op outside the reminding phase.
    func acknowledge(_ method: AckMethod) {
        guard phase == .reminding else { return }
        completeAcknowledge(method)
    }

    private func completeAcknowledge(_ method: AckMethod) {
        resetCycleFlags()
        phase = settings.restMinutes > 0 ? .resting : .working
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerDidAcknowledge(self, method: method)
        delegate?.breakTimerStateChanged(self)
    }

    // MARK: - User actions

    func toggleManualPause() {
        manualPaused.toggle()
        if !manualPaused { idleResetArmed = false }
        pauseReason = manualPaused ? .manual : .none
        delegate?.breakTimerStateChanged(self)
    }

    func setManualPause(_ paused: Bool) {
        guard manualPaused != paused else { return }
        toggleManualPause()
    }

    /// Skip this one: reset the work segment timer (also ends a reminding phase without acknowledging).
    func skip() {
        workOverrideSeconds = nil
        resetCycleFlags()
        phase = .working
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }

    /// Start a one-off longer work segment (the "focus" scene): the current cycle restarts with the
    /// given length, expires into the normal reminding phase, and the next cycle returns to the
    /// configured rhythm automatically. Clears a manual pause — choosing to focus means running.
    func startTemporaryWork(seconds: Int) {
        workOverrideSeconds = max(60, seconds)
        manualPaused = false
        idleResetArmed = false
        resetCycleFlags()
        phase = .working
        pauseReason = .none
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }

    /// Postpone: add N minutes to the current remaining (capped at twice a full work segment).
    /// From the reminding phase this means "not now, remind me in N minutes".
    func postpone(minutes: Int) {
        let wasReminding = phase == .reminding
        resetCycleFlags()
        if wasReminding {
            phase = .working
            configureForCurrentPhase(reset: true)
            remaining = min(max(1, minutes) * 60, total)
        } else {
            let add = max(1, minutes) * 60
            remaining = min(max(remaining, 0) + add, total * 2)
        }
        delegate?.breakTimerStateChanged(self)
    }

    /// Fire a one-shot reminder immediately and restart the work segment (a manual "buzz now";
    /// does not enter the reminding phase). Deliberately NOT `breakTimerDidFire`: a manual buzz is
    /// not a real deadline and must not open the honest-rest confirmation window.
    func fireNow() {
        workOverrideSeconds = nil
        resetCycleFlags()
        phase = .working
        delegate?.breakTimerDidFireManually(self)
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }

    /// When the work length changes (user switches interval), restart the countdown with the new
    /// length. Preserves the manual pause state.
    func restartWorking() {
        workOverrideSeconds = nil
        phase = .working
        pauseReason = manualPaused ? .manual : .none
        idleResetArmed = false
        resetCycleFlags()
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }

    /// Full reset to the start of the work segment.
    func resetCycle() {
        workOverrideSeconds = nil
        manualPaused = false
        idleResetArmed = false
        resetCycleFlags()
        phase = .working
        pauseReason = .none
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }
}
