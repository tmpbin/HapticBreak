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
    /// Reminding phase: a gentle follow-up nudge (the reminder hasn't been acknowledged yet).
    func breakTimerPulse(_ timer: BreakTimer)
    /// Reminding phase hit its nudge cap without acknowledgment → silently auto-postponed.
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

/// Reminder countdown state machine. Driven once per second by the outside (AppController) via `tick`.
final class BreakTimer {

    weak var delegate: BreakTimerDelegate?
    private let settings: Settings

    private(set) var phase: BreakPhase = .working
    private(set) var pauseReason: PauseReason = .none
    private(set) var remaining: Int = 0
    private(set) var total: Int = 1

    private var manualPaused = false
    private var idleResetArmed = false   // Whether the current idle cycle has already performed a "timer reset"

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

    private let typingPauseThreshold: TimeInterval = 1.5
    private let maxDeferSeconds = 45
    /// No-input seconds during reminding that count as "actually stepped away" → implicit acknowledgment.
    /// Matches `RestConfirmer.idleThreshold`, so the honest-rest confirmation follows naturally.
    private let ackIdleThreshold: TimeInterval = 30

    init(settings: Settings) {
        self.settings = settings
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

    /// Called once per second by the outside.
    /// - Parameters:
    ///   - idleSeconds: Seconds since the last input.
    ///   - externalSuppress: External suppression reason (fullscreen/Focus), nil if none.
    /// - Returns: Whether this second counts as "active work time".
    @discardableResult
    func tick(idleSeconds: TimeInterval, externalSuppress: PauseReason?) -> Bool {
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
        //    While reminding, idle is not a pause — it's the implicit acknowledgment (handled below).
        let idlePaused = phase != .reminding
            && settings.idleEnabled && idleSeconds >= Double(settings.idlePauseSeconds)
        let newReason: PauseReason
        if manualPaused { newReason = .manual }
        else if let ext = externalSuppress { newReason = ext }
        else if idlePaused { newReason = .idle }
        else { newReason = .none }

        let changed = newReason != pauseReason
        pauseReason = newReason

        if pauseReason.isPaused {
            if changed { delegate?.breakTimerStateChanged(self) }
            return false
        }

        // 3) Reminding phase: wait for acknowledgment, re-nudging gently on a bounded schedule
        if phase == .reminding {
            tickReminding(idleSeconds: idleSeconds)
            delegate?.breakTimerStateChanged(self)
            return false
        }

        // 4) Approaching reminder: one early "heads-up tap" (CR-02)
        if settings.gentleHeadsUp, phase == .working, !headsUpFired,
           remaining > 0, remaining <= preWarnThreshold() {
            headsUpFired = true
            delegate?.breakTimerWillFireSoon(self)
        }

        // 5) Decrement (never below 0)
        if remaining > 0 { remaining -= 1 }

        // 6) Expiry: typing-aware defer (CR-01) or normal expiry
        if remaining <= 0 {
            if phase == .working, settings.typingAwareDefer,
               idleSeconds < typingPauseThreshold, deferredSeconds < maxDeferSeconds {
                deferredSeconds += 1
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
    /// otherwise emit typing-aware nudges every `remindPulseSeconds`, auto-postponing at the cap.
    private func tickReminding(idleSeconds: TimeInterval) {
        if idleSeconds >= ackIdleThreshold {
            completeAcknowledge(.stepAway)
            return
        }
        remindingSeconds += 1
        guard remindingSeconds >= nextPulseAt else { return }
        // Typing-aware defer per nudge: never buzz mid-typing; wait for a natural pause (bounded).
        if settings.typingAwareDefer, idleSeconds < typingPauseThreshold,
           pulseDeferSeconds < maxDeferSeconds {
            pulseDeferSeconds += 1
            return
        }
        pulseDeferSeconds = 0
        if pulsesFired >= max(1, settings.remindPulseMax) {
            autoPostpone()
        } else {
            pulsesFired += 1
            nextPulseAt = remindingSeconds + max(10, settings.remindPulseSeconds)
            delegate?.breakTimerPulse(self)
        }
    }

    private func handleExpiry() {
        if phase == .working {
            workOverrideSeconds = nil   // The temporary long segment ran its course — back to the normal rhythm
            resetCycleFlags()
            phase = .reminding
            configureForCurrentPhase(reset: true)
            pulsesFired = 1
            nextPulseAt = max(10, settings.remindPulseSeconds)
            delegate?.breakTimerDidFire(self)
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
    /// does not enter the reminding phase).
    func fireNow() {
        workOverrideSeconds = nil
        resetCycleFlags()
        phase = .working
        delegate?.breakTimerDidFire(self)
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
