import AppKit

/// Temporary quiet scenes: bounded, self-restoring "not now" decisions. Unlike a bare manual pause
/// (easy to forget to resume), a scene carries its own end and comes back on its own.
enum QuietScene: String {
    case meeting   // Quiet for one hour (an ad-hoc call/meeting the mic probe can't see)
    case day       // Done for today — quiet until early next morning
}

/// App orchestration core: wires Settings / timer state machine / haptics / detection / statistics / UI.
final class AppController: NSObject, BreakTimerDelegate {

    let settings = Settings.shared
    let viewModel = AppViewModel()

    private var engine: HapticEngine
    private let player: HapticPlayer
    private let timer: BreakTimer
    private let stats = StatisticsStore.shared
    private let aux = AuxReminder()

    private var tickTimer: DispatchSourceTimer?
    /// App Nap suppression token (see `start()`); held for the app's lifetime.
    private var activityToken: NSObjectProtocol?

    /// Cached environment suppression (fullscreen / mic / focus). These probes are relatively expensive and
    /// the state changes slowly, so they are re-evaluated only every `detectCadence` ticks (see `onTick`),
    /// and run **off the main thread**: window-server enumeration + file read/JSON parse + CoreAudio were
    /// a fixed main-thread tax every 3 s. The result lands one hop later — well within the cache's own
    /// staleness budget.
    private var suppressCache: PauseReason?
    private var detectCounter = 0
    private static let detectCadence = 3
    private let probeQueue = DispatchQueue(label: "com.aremind.hapticbreak.probes", qos: .utility)
    private var probeInFlight = false

    /// "Honest rest": only count a break when the user actually steps away after a reminder.
    private var restConfirmer = RestConfirmer()
    /// Cap for mic-based pausing — beyond this it's treated as a persistent background capture,
    /// so reminders resume to avoid "never reminding".
    private var micActiveSince: Date?
    private static let micPauseCap: TimeInterval = 90 * 60

    /// Active quiet scene (nil = none). Persisted via `Settings` so "done for today" survives an
    /// app restart (and ephemeral runs stay isolated); expiry is checked by the environment probe
    /// and clears itself.
    private var sceneUntil: Date?
    private var sceneKind: QuietScene?
    private lazy var menuBar = MenuBarController(viewModel: viewModel)
    private lazy var windows = WindowManager(viewModel: viewModel)

    override init() {
        engine = HapticEngineFactory.make(settings.backend)
        player = HapticPlayer(engine: engine)
        timer = BreakTimer(settings: settings)
        super.init()
        viewModel.controller = self
        timer.delegate = self
        viewModel.backend.name = engine.backendName
        viewModel.backend.available = engine.isAvailable
    }

    // MARK: - Lifecycle

    func start() {
        // Launch-at-login truth lives in SMAppService (it persists across launches and can be
        // changed behind our back in System Settings → Login Items); align the stored preference
        // on startup so the Settings toggle never shows a stale state.
        if settings.launchAtLogin != LoginItem.isEnabled {
            settings.launchAtLogin = LoginItem.isEnabled
        }
        restoreScene()
        menuBar.install()
        registerShortcutsIfNeeded()
        // Keep the 1 Hz tick trustworthy: without an activity assertion, App Nap coalesces a
        // windowless accessory app's timers by seconds to minutes. Idle *system* sleep stays
        // allowed — a break reminder must never keep the Mac awake. (BreakTimer's wall-clock
        // anchoring covers whatever drift remains.)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "HapticBreak break countdown")
        startTick()
        syncViewModel()
        refreshStreak()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged(_:)),
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
        TouchGestureMonitor.shared.stop()
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

    /// Panel closed: stop the companion (no more beats on the next tick). The one-time intro line
    /// has been seen by now — never show it again.
    func panelClosed() {
        panelVisible = false
        if !settings.hasSeenPanelIntro { settings.hasSeenPanelIntro = true }
    }

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
            if detectCounter == 0 { refreshSuppression() }
            detectCounter = (detectCounter + 1) % Self.detectCadence
        }

        // Deferring (typing past the deadline) still counts as active work — the user is
        // demonstrably at the keyboard.
        let active = timer.tick(idleSeconds: idle, externalSuppress: suppressCache)
        if active { stats.addActiveSecond() }
        panelBeatIfNeeded()
    }

    /// Re-evaluate the environment suppressors. The quiet scene outranks the probes (an explicit
    /// user decision) and is pure main-thread state — handled synchronously, with expiry clearing
    /// itself here. The system probes run on `probeQueue`; their verdict is assembled back on the
    /// main thread and lands in `suppressCache` for the next tick.
    private func refreshSuppression() {
        if let until = sceneUntil {
            if Date() < until { suppressCache = sceneKind == .meeting ? .meeting : .scene; return }
            clearScene()
        }
        guard !probeInFlight else { return }
        // Snapshot the toggles on the main thread; probe only what the user enabled.
        let checkFullscreen = settings.skipDuringFullscreen
        let checkMic = settings.pauseDuringMic
        let checkFocus = settings.respectFocusMode
        guard checkFullscreen || checkMic || checkFocus else { suppressCache = nil; return }
        probeInFlight = true
        probeQueue.async { [weak self] in
            let fullscreen = checkFullscreen && FullscreenDetector.isFrontmostFullscreen()
            let micActive = checkMic && MicMonitor.isActive()
            let focus = checkFocus && FocusModeDetector.isFocusActive()
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeInFlight = false
                // Mic bookkeeping runs every round regardless of which suppressor wins, so the
                // continuous-capture cap is measured from when the mic actually went live (the old
                // inline probe short-circuited past it while e.g. fullscreen was active).
                let micPause = checkMic && self.micShouldPause(activeNow: micActive)
                if fullscreen { self.suppressCache = .fullscreen }
                else if micPause { self.suppressCache = .meeting }
                else if focus { self.suppressCache = .focus }
                else { self.suppressCache = nil }
            }
        }
    }

    // MARK: - Quiet scenes

    /// "Focus for 90 minutes": one long work segment, then the normal reminding flow — the next
    /// cycle returns to the configured rhythm on its own. Cancels any quiet scene (focusing = running).
    func startFocusScene() {
        restConfirmer.cancel()   // Choosing to focus = explicitly not resting now
        clearScene()
        timer.startTemporaryWork(seconds: 90 * 60)
        syncViewModel()
    }

    /// Start a bounded quiet scene (meeting = 1 hour; day = until ~4 AM tomorrow).
    func startQuietScene(_ kind: QuietScene) {
        restConfirmer.cancel()   // Entering a quiet scene declines the pending reminder
        sceneKind = kind
        switch kind {
        case .meeting: sceneUntil = Date().addingTimeInterval(60 * 60)
        case .day:
            sceneUntil = Calendar.current.nextDate(after: Date(),
                                                   matching: DateComponents(hour: 4, minute: 0),
                                                   matchingPolicy: .nextTime) ?? Date().addingTimeInterval(12 * 3600)
        }
        settings.sceneUntil = sceneUntil
        settings.sceneKindRaw = kind.rawValue
        detectCounter = 0   // Take effect on the next tick
        syncViewModel()
    }

    func cancelQuietScene() {
        clearScene()
        detectCounter = 0
        suppressCache = nil
        syncViewModel()
    }

    private func clearScene() {
        sceneUntil = nil
        sceneKind = nil
        settings.sceneUntil = nil
        settings.sceneKindRaw = nil
    }

    /// Restore a persisted scene on launch ("done for today" survives restarts); drop it if expired.
    private func restoreScene() {
        guard let until = settings.sceneUntil,
              let kind = settings.sceneKindRaw.flatMap(QuietScene.init) else { return }
        if until > Date() { sceneUntil = until; sceneKind = kind } else { clearScene() }
    }

    private static let sceneClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Companion line for the active scene (empty = no scene).
    private func sceneText() -> String {
        guard let until = sceneUntil, until > Date(), let kind = sceneKind else { return "" }
        switch kind {
        case .meeting: return L.t("scene.until", Self.sceneClockFormatter.string(from: until))
        case .day:     return L.t("scene.untilTomorrow")
        }
    }

    /// Whether mic usage should trigger a pause: enforce a continuous cap, beyond which it's treated as
    /// a persistent background capture and reminders resume. `activeNow` is the probe result (the
    /// CoreAudio query itself runs on `probeQueue`); the bookkeeping stays main-thread state.
    private func micShouldPause(activeNow: Bool) -> Bool {
        guard activeNow else { micActiveSince = nil; return false }
        let since = micActiveSince ?? Date()
        micActiveSince = since
        return Date().timeIntervalSince(since) < Self.micPauseCap
    }

    // MARK: - BreakTimerDelegate

    /// The one announcement every nudge makes: full user preset with the aux channels in sync.
    /// Initial fire and every follow-up go through here, so they can never drift apart.
    private func playFullReminder() {
        player.play(settings.selectedPattern, strength: settings.strength) { [weak self] in
            guard let self else { return }
            if self.settings.soundEnabled { self.aux.playSound(named: self.settings.soundName) }
            if self.settings.auxFlashScreen { self.aux.flashScreen() }
        }
        menuBar.pulse()
    }

    func breakTimerDidFire(_ timer: BreakTimer) {
        playFullReminder()
        // Do not count a rest the moment the reminder sounds — wait until the user actually steps away,
        // confirmed by restConfirmer (honest statistics).
        restConfirmer.didFire()
    }

    /// Manual "buzz now": play the full reminder, but never open the honest-rest window — a test
    /// buzz followed by stepping away must not count as a real break.
    func breakTimerDidFireManually(_ timer: BreakTimer) {
        playFullReminder()
    }

    /// Reminding follow-up nudge: replays the full user preset identically to the initial fire.
    func breakTimerPulse(_ timer: BreakTimer) {
        playFullReminder()
    }

    /// After several unanswered nudges, mark the teaching hint as visible and gently surface the
    /// panel. Uses `showPopoverPassive()` so the user's front app keeps focus — no key stealing.
    func breakTimerShouldShowHint(_ timer: BreakTimer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewModel.showNudgeHint = true
            self.menuBar.showPopoverPassive()
        }
    }

    /// Reminding cap reached without acknowledgment → silently auto-postpone.
    /// The honest-rest window is voided with it: the reminder went unanswered, so a later idle
    /// spell must not retroactively count as a rest.
    func breakTimerDidAutoPostpone(_ timer: BreakTimer) {
        restConfirmer.cancel()
        menuBar.pulse()
        menuBar.closeAfterReminderResolved()
    }

    func breakTimerDidAcknowledge(_ timer: BreakTimer, method: AckMethod) {
        stats.recordAck()
        // Close the loop for explicit acknowledgments with a double-tap receipt ("got it — rest begins");
        // stepping away needs no feedback — the user is already gone.
        if method != .stepAway {
            player.play(.double, strength: settings.strength)
        }
        // If the teaching panel surfaced itself for this reminder, tuck it away shortly after the
        // acknowledgment (e.g. the three-finger tap) — the user never asked for a panel to manage.
        menuBar.closeAfterReminderResolved()
    }

    func breakTimerDidFinishRest(_ timer: BreakTimer) {
        player.play(settings.finishPattern, strength: settings.strength)
        stats.recordCycle()
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
        // Reminding countdown: read-only from the timer (purely for visual display).
        let cd = timer.remindingCountdown
        if viewModel.remindingCountdown != cd { viewModel.remindingCountdown = cd }

        if viewModel.remaining   != timer.remaining   { viewModel.remaining   = timer.remaining }
        if viewModel.total       != timer.total       { viewModel.total       = timer.total }
        if viewModel.phase       != timer.phase       {
            viewModel.phase = timer.phase
            if timer.phase != .reminding { viewModel.showNudgeHint = false }
            updateGestureMonitor()
        }
        if viewModel.pauseReason != timer.pauseReason { viewModel.pauseReason = timer.pauseReason }
        if viewModel.isDeferring != timer.isDeferring { viewModel.isDeferring = timer.isDeferring }
        let scene = sceneText()
        if viewModel.sceneText != scene { viewModel.sceneText = scene }
        // Actuator availability can change at runtime (a Bluetooth Magic Trackpad connecting after
        // launch, or disconnecting): mirror it so the warning row / About window stay truthful.
        // `isAvailable` is cheap — the engine caches its device and throttles re-probing internally.
        let available = engine.isAvailable
        if viewModel.backend.available != available {
            viewModel.backend.available = available
            viewModel.backend.name = engine.backendName   // Auto backend's name follows its live pick
        }
        menuBar.refresh()
    }

    /// The trackpad ack gesture is listened for **only during the reminding phase** — zero idle cost
    /// and zero chance of accidental triggers the rest of the time.
    private func updateGestureMonitor() {
        if timer.phase == .reminding, settings.ackGestureEnabled, TouchGestureMonitor.isSupported {
            TouchGestureMonitor.shared.onTripleTap = { [weak self] in self?.acknowledge(.gesture) }
            TouchGestureMonitor.shared.start()
        } else {
            TouchGestureMonitor.shared.stop()
        }
    }

    /// Refresh the cached streak and today's rest count (they only change when a break is recorded /
    /// the day rolls over), so the panel doesn't recompute them on every render tick.
    private func refreshStreak() {
        viewModel.streak = stats.currentStreak()
        let today = stats.today()
        viewModel.todayBreaks = today.breaks
        let rhythm = TodayRhythm(activeByHour: today.activeByHour, breakMinutes: today.breakMinutes)
        if viewModel.todayRhythm != rhythm { viewModel.todayRhythm = rhythm }
    }

    // MARK: - Actions

    func toggleManualPause() { timer.toggleManualPause() }
    // Skip / postpone explicitly decline the pending reminder — void the honest-rest window,
    // otherwise stepping away shortly after would count both a skip AND a break for one reminder.
    func skip()              { restConfirmer.cancel(); timer.skip(); stats.recordSkip() }
    func postpone()          { restConfirmer.cancel(); timer.postpone(minutes: settings.postponeMinutes); stats.recordPostpone() }
    func breakNow()          { timer.fireNow() }
    /// Acknowledge the current reminder (no-op outside the reminding phase).
    func acknowledge(_ method: AckMethod) { timer.acknowledge(method) }
    func testCurrentPattern(){ player.play(settings.selectedPattern, strength: settings.strength) }
    /// Editor preview: design reference (unaffected by global scaling, so you hear exactly the designed strength).
    func testPattern(_ p: HapticPattern) { player.playDesign(p) }
    func testStep(_ step: HapticStep)    { player.testStepDesign(step) }
    /// Recorder playback: like `testStep` but without drag-coalescing — every beat must sound.
    func auditionStep(_ step: HapticStep) { player.auditionStepDesign(step) }
    func openSettings()      { windows.showSettings() }
    func openStatistics()    { windows.showStatistics() }
    func openPatternEditor() { windows.showPatternEditor() }
    func openHapticLab()     { windows.showHapticLab() }
    func openAbout()         { windows.showAbout() }

    // MARK: - Settings changes

    /// Language switch: refresh engine-produced localized strings such as the backend name
    /// (SwiftUI text refreshes automatically via @ObservedObject).
    @objc private func languageChanged() {
        viewModel.backend.name = engine.backendName
    }

    /// Dispatch on the changed key delivered by `Settings` (equal re-assignments never arrive, so
    /// every delivery is a real change — no manual old-value caches needed here anymore).
    @objc private func settingsChanged(_ note: Notification) {
        let key = note.userInfo?[Settings.changedKeyUserInfoKey] as? Settings.Key
        switch key {
        case .backend:
            rebuildEngine()
        case .shortcuts, .hotKeys:
            registerShortcutsIfNeeded()
        case .ackGesture:
            // May change mid-reminding; re-evaluate the monitor.
            updateGestureMonitor()
        case .interval:
            // Work duration changed: restart the countdown with the new duration — more intuitive.
            timer.restartWorking()
        case .restMinutes:
            timer.applySettingsChange()
        case .idleEnabled, .idlePause, .idleReset, .fullscreen, .focus, .pauseMic:
            // Re-probe on the next tick, so toggling a suppressor responds promptly.
            detectCounter = 0
        case nil:
            // Bulk change (reset to defaults): reconfigure everything.
            rebuildEngine()
            registerShortcutsIfNeeded()
            updateGestureMonitor()
            detectCounter = 0
            timer.restartWorking()
        default:
            break   // Display/haptic-content settings need no controller reconfiguration
        }
        syncViewModel()
    }

    private func rebuildEngine() {
        engine = HapticEngineFactory.make(settings.backend)
        player.updateEngine(engine)
        viewModel.backend.name = engine.backendName
        viewModel.backend.available = engine.isAvailable
    }

    /// Suspend the global hotkeys while the settings recorder captures a combo (otherwise the
    /// currently registered combos would be swallowed by Carbon before reaching the recorder).
    func setHotKeyCaptureActive(_ active: Bool) {
        if active { HotKeyManager.shared.unregisterAll() }
        else { registerShortcutsIfNeeded() }
    }

    private func registerShortcutsIfNeeded() {
        HotKeyManager.shared.unregisterAll()
        guard settings.enableShortcuts else { return }
        HotKeyManager.shared.registerBindings(
            settings.hotKeys,
            togglePause: { [weak self] in self?.toggleManualPause() },
            skip:        { [weak self] in self?.skip() },
            breakNow:    { [weak self] in self?.breakNow() },
            acknowledge: { [weak self] in self?.acknowledge(.hotkey) })
    }
}
