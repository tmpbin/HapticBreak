import Foundation

enum BreakPhase {
    case working   // Counting down to the next reminder / pomodoro work segment
    case resting   // Pomodoro rest segment
}

enum PauseReason: Equatable {
    case none
    case manual
    case idle
    case focus
    case fullscreen
    case meeting

    var isPaused: Bool { self != .none }
}

protocol BreakTimerDelegate: AnyObject {
    /// Work segment ended: reached the reminder/rest moment.
    func breakTimerDidFire(_ timer: BreakTimer)
    /// Pomodoro rest segment ended: back to work.
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

    // Respectful / smart reminders (CR-01 / CR-02 / CR-05)
    private var headsUpFired = false        // Whether a heads-up has fired this cycle
    private(set) var isDeferring = false     // Deferring because of typing
    private var deferredSeconds = 0
    private(set) var consecutiveSkips = 0    // Consecutive skip/postpone count (escalation bump)

    private let typingPauseThreshold: TimeInterval = 1.5
    private let maxDeferSeconds = 45

    init(settings: Settings) {
        self.settings = settings
        configureForCurrentPhase(reset: true)
    }

    var isPaused: Bool { pauseReason.isPaused }

    /// Escalation bump strength (0–2), layered in by the controller when playing.
    var escalationBump: Int { min(consecutiveSkips, 2) }

    private func preWarnThreshold() -> Int { min(30, max(2, total / 2)) }

    private func resetCycleFlags() {
        headsUpFired = false
        isDeferring = false
        deferredSeconds = 0
    }

    // MARK: - Configuration

    private func workSeconds() -> Int { max(1, settings.workMinutes * 60) }
    private func restSeconds() -> Int { max(1, settings.pomodoroBreakMinutes * 60) }

    private func configureForCurrentPhase(reset: Bool) {
        let target = phase == .working ? workSeconds() : restSeconds()
        total = target
        if reset { remaining = target }
        else { remaining = min(remaining, target) }
    }

    /// Call after settings change (interval / pomodoro durations, etc.): update total and clamp remaining
    /// so it never exceeds the new total.
    func applySettingsChange() {
        // When the pomodoro switch changes, always return to the work segment to avoid inconsistent state.
        if phase == .resting && !settings.pomodoroEnabled {
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

        // 2) Compute pause reason: manual > external (fullscreen/Focus) > idle
        let idlePaused = settings.idleEnabled && idleSeconds >= Double(settings.idlePauseSeconds)
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

        // 3) Approaching reminder: one early "heads-up tap" (CR-02)
        if settings.gentleHeadsUp, phase == .working, !headsUpFired,
           remaining > 0, remaining <= preWarnThreshold() {
            headsUpFired = true
            delegate?.breakTimerWillFireSoon(self)
        }

        // 4) Decrement (never below 0)
        if remaining > 0 { remaining -= 1 }

        // 5) Expiry: typing-aware defer (CR-01) or normal expiry
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

    private func handleExpiry() {
        resetCycleFlags()
        if phase == .working {
            consecutiveSkips = max(0, consecutiveSkips - 1)  // Natural completion → escalation decays
            delegate?.breakTimerDidFire(self)
            if settings.pomodoroEnabled {
                phase = .resting
                configureForCurrentPhase(reset: true)
            } else {
                configureForCurrentPhase(reset: true) // Periodic reminder: restart the timer
            }
        } else {
            delegate?.breakTimerDidFinishRest(self)
            phase = .working
            configureForCurrentPhase(reset: true)
        }
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

    /// Skip this one: reset the work segment timer.
    func skip() {
        consecutiveSkips = min(consecutiveSkips + 1, 5)
        resetCycleFlags()
        phase = .working
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }

    /// Postpone: add N minutes to the current remaining (capped at twice a full work segment).
    func postpone(minutes: Int) {
        consecutiveSkips = min(consecutiveSkips + 1, 5)
        resetCycleFlags()
        let add = max(1, minutes) * 60
        remaining = min(max(remaining, 0) + add, total * 2)
        delegate?.breakTimerStateChanged(self)
    }

    /// Fire a reminder immediately (does not change the timing phase semantics; just fires manually and
    /// resets the work segment).
    func fireNow() {
        resetCycleFlags()
        phase = .working
        delegate?.breakTimerDidFire(self)
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }

    /// When the work length changes (user switches interval / pomodoro work length), restart the
    /// countdown with the new length. Preserves the manual pause state.
    func restartWorking() {
        phase = .working
        pauseReason = manualPaused ? .manual : .none
        idleResetArmed = false
        resetCycleFlags()
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }

    /// Full reset to the start of the work segment.
    func resetCycle() {
        manualPaused = false
        idleResetArmed = false
        consecutiveSkips = 0
        resetCycleFlags()
        phase = .working
        pauseReason = .none
        configureForCurrentPhase(reset: true)
        delegate?.breakTimerStateChanged(self)
    }
}
