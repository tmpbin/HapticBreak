import AppKit

/// App orchestration core: wires Settings / timer state machine / haptics / detection / statistics / UI.
final class AppController: NSObject, BreakTimerDelegate {

    let settings = Settings.shared
    let viewModel = AppViewModel()

    private var engine: HapticEngine
    private var currentBackend: HapticBackend
    private let player: HapticPlayer
    private let timer: BreakTimer
    private let stats = StatisticsStore.shared
    private let aux = AuxReminder()

    private var tickTimer: DispatchSourceTimer?
    private var lastWorkSeconds: Int
    private var lastEnableShortcuts: Bool

    /// Cached environment suppression (fullscreen / mic / focus). These probes are relatively expensive and
    /// the state changes slowly, so they are re-evaluated only every `detectCadence` ticks (see `onTick`).
    private var suppressCache: PauseReason?
    private var detectCounter = 0
    private static let detectCadence = 3

    /// "Honest rest": only count a break when the user actually steps away after a reminder.
    private var restConfirmer = RestConfirmer()
    /// Cap for mic-based pausing — beyond this it's treated as a persistent background capture,
    /// so reminders resume to avoid "never reminding".
    private var micActiveSince: Date?
    private static let micPauseCap: TimeInterval = 90 * 60
    private lazy var menuBar = MenuBarController(viewModel: viewModel)
    private lazy var windows = WindowManager(viewModel: viewModel)

    override init() {
        currentBackend = settings.backend
        engine = HapticEngineFactory.make(settings.backend)
        player = HapticPlayer(engine: engine)
        timer = BreakTimer(settings: settings)
        lastWorkSeconds = max(1, settings.workMinutes * 60)
        lastEnableShortcuts = settings.enableShortcuts
        super.init()
        viewModel.controller = self
        timer.delegate = self
        viewModel.backendName = engine.backendName
        viewModel.backendAvailable = engine.isAvailable
    }

    // MARK: - Lifecycle

    func start() {
        menuBar.install()
        registerShortcutsIfNeeded()
        startTick()
        syncViewModel()
        refreshStreak()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .hbSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged),
            name: .hbLanguageChanged, object: nil)

        // First launch: auto-open the control panel to help users discover the menu-bar UI.
        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.menuBar.showPopover()
            }
        }
    }

    func applicationWillTerminate() {
        panelVisible = false
        stats.flush()
        HotKeyManager.shared.unregisterAll()
    }

    // MARK: - Panel heartbeat companion
    // Follow-the-second: while the panel is visible, every time the countdown actually ticks down
    // one second, emit the faintest double "tick" in sync with the ring's second hand — like a
    // heartbeat, one beat per second, not a self-running loop. Exclusive: yields automatically while
    // a higher-priority haptic (test/reminder/heads-up) is playing, and resumes afterward.

    private var panelVisible = false
    private var lastBeatRemaining = -1

    /// Panel opened: enable the heartbeat companion; emit one beat immediately, then driven per second.
    func panelOpened() {
        panelVisible = true
        lastBeatRemaining = timer.remaining
        refreshStreak()
        playPanelBeat()
    }

    /// Panel closed: stop the companion (no more beats on the next tick).
    func panelClosed() { panelVisible = false }

    /// Called by `onTick`: emit a beat only when the panel is visible and the seconds actually changed
    /// (in sync with the UI, not paused/waiting).
    private func panelBeatIfNeeded() {
        guard panelVisible, settings.panelHeartbeat, engine.isAvailable else { return }
        let now = timer.remaining
        guard now != lastBeatRemaining else { return }
        lastBeatRemaining = now
        playPanelBeat()
    }

    /// One beat: the faintest double "tick"; yields (stays silent) if another haptic
    /// (test/reminder/heads-up) is currently playing.
    private func playPanelBeat() {
        player.ambientTick(strength: settings.strength)
    }

    /// Strong feedback for the ring's "deduct one minute" hit: a stronger buzz the moment the bullet
    /// strikes the end (more noticeable than the heartbeat). Routed here from `CountdownRing`'s hit
    /// event via `AppViewModel.ringImpact()` — the UI does not own the haptic engine.
    /// Shares the `panelHeartbeat` switch with the follow-the-second beat: turning off the heartbeat
    /// also silences the hit feedback.
    func ringImpact() {
        guard panelVisible, settings.panelHeartbeat, engine.isAvailable else { return }
        player.impact(strength: settings.strength)
    }

    /// Smoke test: instantiate every SwiftUI window in turn and fire a real reminder to verify no crash.
    func runDemo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.openStatistics() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.openPatternEditor() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.testCurrentPattern()
            self.breakNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            self.toggleManualPause(); self.toggleManualPause()
            self.skip(); self.postpone()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            print("DEMO_OK")
            NSApp.terminate(nil)
        }
    }

    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        tickTimer = t
    }

    private func onTick() {
        let idle = IdleMonitor.secondsSinceLastInput()

        // Honest rest: only when you actually step away briefly after a reminder do we count a real
        // break (drives streak / statistics).
        if restConfirmer.tick(idleSeconds: idle) { stats.recordBreak(); refreshStreak() }

        // Environment suppressors (fullscreen / mic / focus) change slowly and their probes are relatively
        // expensive — window-server enumeration, a file read + JSON parse, and CoreAudio. Evaluate them on a
        // cadence and cache the result rather than every second; the countdown itself still ticks at 1 Hz.
        // While manually paused they can't influence the state (manual outranks them), so skip probing
        // entirely and re-probe on the first tick after resuming.
        if timer.pauseReason == .manual {
            suppressCache = nil
            detectCounter = 0
        } else {
            if detectCounter == 0 { suppressCache = evaluateSuppression() }
            detectCounter = (detectCounter + 1) % Self.detectCadence
        }

        let active = timer.tick(idleSeconds: idle, externalSuppress: suppressCache)
        if active && !timer.isDeferring { stats.addActiveSecond() }
        panelBeatIfNeeded()
    }

    /// Evaluate the (relatively expensive) environment suppressors — probing only what the user enabled.
    private func evaluateSuppression() -> PauseReason? {
        if settings.skipDuringFullscreen, FullscreenDetector.isFrontmostFullscreen() { return .fullscreen }
        if settings.pauseDuringMic, micShouldPause() { return .meeting }
        if settings.respectFocusMode, FocusModeDetector.isFocusActive() { return .focus }
        return nil
    }

    /// Whether mic usage should trigger a pause: enforce a continuous cap, beyond which it's treated as
    /// a persistent background capture and reminders resume.
    private func micShouldPause() -> Bool {
        guard MicMonitor.isActive() else { micActiveSince = nil; return false }
        let since = micActiveSince ?? Date()
        micActiveSince = since
        return Date().timeIntervalSince(since) < Self.micPauseCap
    }

    // MARK: - BreakTimerDelegate

    func breakTimerDidFire(_ timer: BreakTimer) {
        // Escalation bump added to global strength (escalationBump 0–2 from the old 1–5 space, ×2 to fit 1–10).
        let extra = settings.skipEscalation ? timer.escalationBump * 2 : 0
        let effective = max(1, min(10, settings.strength + extra))
        // Screen flash / sound stay in sync with each repeat of the haptic: the player invokes this at the
        // start of every pass, so the count naturally equals the number of reminder repeats.
        player.play(settings.selectedPattern, strength: effective, repeatCount: settings.reminderRepeat) { [weak self] in
            guard let self else { return }
            if self.settings.soundEnabled { self.aux.playSound(named: self.settings.soundName) }
            if self.settings.auxFlashScreen { self.aux.flashScreen() }
        }
        // Do not count a rest the moment the reminder sounds — wait until the user actually steps away,
        // confirmed by restConfirmer (honest statistics).
        restConfirmer.didFire()
        menuBar.pulse()
    }

    func breakTimerDidFinishRest(_ timer: BreakTimer) {
        player.play(settings.finishPattern, strength: settings.strength)
        stats.recordPomodoro()
        menuBar.pulse()
    }

    /// Approaching a reminder: use the "heads-up" pattern to hint the break is coming (scaled by the global 10 levels).
    func breakTimerWillFireSoon(_ timer: BreakTimer) {
        player.play(settings.headsUpPattern, strength: settings.strength)
    }

    func breakTimerStateChanged(_ timer: BreakTimer) {
        syncViewModel()
    }

    /// Mirror timer state into the view model, assigning only what actually changed: every `@Published`
    /// write fires `objectWillChange` regardless of equality, and this runs once per second — unconditional
    /// writes would invalidate every observer (collapsed popover, any open window) five times per tick.
    private func syncViewModel() {
        if viewModel.remaining   != timer.remaining   { viewModel.remaining   = timer.remaining }
        if viewModel.total       != timer.total       { viewModel.total       = timer.total }
        if viewModel.phase       != timer.phase       { viewModel.phase       = timer.phase }
        if viewModel.pauseReason != timer.pauseReason { viewModel.pauseReason = timer.pauseReason }
        if viewModel.isDeferring != timer.isDeferring { viewModel.isDeferring = timer.isDeferring }
        menuBar.refresh()
    }

    /// Refresh the cached streak (only changes when a break is recorded / the day rolls over), so the panel
    /// doesn't recompute it on every render tick.
    private func refreshStreak() { viewModel.streak = stats.currentStreak() }

    // MARK: - Actions

    func toggleManualPause() { timer.toggleManualPause() }
    func skip()              { timer.skip(); stats.recordSkip() }
    func postpone()          { timer.postpone(minutes: settings.postponeMinutes); stats.recordPostpone() }
    func breakNow()          { timer.fireNow() }
    func testCurrentPattern(){ player.play(settings.selectedPattern, strength: settings.strength) }
    /// Editor preview: design reference (unaffected by global scaling, so you hear exactly the designed strength).
    func testPattern(_ p: HapticPattern) { player.playDesign(p) }
    func testStep(_ step: HapticStep)    { player.testStepDesign(step) }
    func openSettings()      { windows.showSettings() }
    func openStatistics()    { windows.showStatistics() }
    func openPatternEditor() { windows.showPatternEditor() }
    func openHapticLab()     { windows.showHapticLab() }
    func openAbout()         { windows.showAbout() }

    // MARK: - Settings changes

    /// Language switch: refresh engine-produced localized strings such as the backend name
    /// (SwiftUI text refreshes automatically via @ObservedObject).
    @objc private func languageChanged() {
        viewModel.backendName = engine.backendName
    }

    @objc private func settingsChanged() {
        // Re-probe environment suppression on the next tick, so toggling a suppressor setting responds promptly.
        detectCounter = 0

        if settings.backend != currentBackend {
            currentBackend = settings.backend
            engine = HapticEngineFactory.make(settings.backend)
            player.updateEngine(engine)
            viewModel.backendName = engine.backendName
            viewModel.backendAvailable = engine.isAvailable
        }

        // Re-register only when the "enable shortcuts" switch changes, to avoid repeated registration
        // from high-frequency changes like dragging a slider.
        if settings.enableShortcuts != lastEnableShortcuts {
            lastEnableShortcuts = settings.enableShortcuts
            registerShortcutsIfNeeded()
        }

        // When the work duration changes (interval switch / pomodoro work length), restart the countdown
        // with the new duration — more intuitive.
        let newWork = max(1, settings.workMinutes * 60)
        if newWork != lastWorkSeconds {
            lastWorkSeconds = newWork
            timer.restartWorking()
        } else {
            timer.applySettingsChange()
        }
        syncViewModel()
    }

    private func registerShortcutsIfNeeded() {
        HotKeyManager.shared.unregisterAll()
        guard settings.enableShortcuts else { return }
        HotKeyManager.shared.registerDefaults(
            togglePause: { [weak self] in self?.toggleManualPause() },
            skip:        { [weak self] in self?.skip() },
            breakNow:    { [weak self] in self?.breakNow() })
    }
}
