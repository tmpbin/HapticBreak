import Foundation
import Combine

extension Notification.Name {
    /// Broadcast after any setting changes, so the controller can reconfigure in real time.
    static let hbSettingsChanged = Notification.Name("com.aremind.hapticbreak.settingsChanged")
}

/// Menu-bar icon style.
enum MenuBarStyle: String, CaseIterable {
    case iconCountdown   // Icon + countdown (default)
    case iconOnly        // Icon only (compact, for crowded menu bars)
    case progressRing    // Progress ring

    var displayName: String {
        switch self {
        case .iconCountdown: return L.t("menustyle.iconCountdown")
        case .iconOnly:      return L.t("menustyle.iconOnly")
        case .progressRing:  return L.t("menustyle.progressRing")
        }
    }
}

/// Global settings, persisted via UserDefaults and serving as a SwiftUI observable object.
final class Settings: ObservableObject {

    static let shared = Settings(defaults: RuntimeMode.settingsDefaults())
    private let defaults: KeyValueStore
    private var ready = false

    /// Selectable reminder intervals (minutes).
    static let intervalOptions = [15, 20, 25, 30, 45, 60]

    // MARK: - Reminder / cycle
    @Published var breakIntervalMinutes: Int { didSet { persist(breakIntervalMinutes, .interval) } }
    /// Rest segment length in minutes. 0 = reminder only (no timed rest segment). Unifies the old
    /// "periodic reminder vs pomodoro" split into a single work X / rest Y model.
    @Published var restMinutes: Int { didSet { persist(restMinutes, .restMinutes) } }
    @Published var selectedPatternID: String { didSet { persist(selectedPatternID, .pattern) } }
    /// Pattern used for the heads-up (a light hint before a break).
    @Published var headsUpPatternID: String { didSet { persist(headsUpPatternID, .headsUpPattern) } }
    /// Pattern used on finish (rest segment ends).
    @Published var finishPatternID: String { didSet { persist(finishPatternID, .finishPattern) } }
    /// Global haptic strength 1…10 (multiplicative main gain; old 1…5 auto-migrated ×2).
    @Published var strength: Int { didSet { persist(strength, .strength) } }
    @Published var postponeMinutes: Int { didSet { persist(postponeMinutes, .postpone) } }

    // MARK: - Acknowledge-to-stop reminding
    /// Seconds between gentle follow-up nudges while a reminder awaits acknowledgment.
    @Published var remindPulseSeconds: Int { didSet { persist(remindPulseSeconds, .pulseSeconds) } }
    /// Total nudges (including the initial reminder) before the reminder silently auto-postpones.
    @Published var remindPulseMax: Int { didSet { persist(remindPulseMax, .pulseMax) } }
    /// Acknowledge the reminder with a three-finger triple-tap on the trackpad (listened for only while reminding).
    @Published var ackGestureEnabled: Bool { didSet { persist(ackGestureEnabled, .ackGesture) } }

    // MARK: - Respectful / smart reminders
    /// If you're typing at the deadline, wait for a natural pause before buzzing (CR-01).
    @Published var typingAwareDefer: Bool { didSet { persist(typingAwareDefer, .typingDefer) } }
    /// One very faint "heads-up tap" ~30s early (CR-02).
    @Published var gentleHeadsUp: Bool { didSet { persist(gentleHeadsUp, .headsUp) } }
    /// While the control panel is visible, overlay the faintest "heartbeat" as a breathing companion (can be off).
    @Published var panelHeartbeat: Bool { didSet { persist(panelHeartbeat, .panelHeartbeat) } }

    // MARK: - Smart pause
    @Published var idleEnabled: Bool { didSet { persist(idleEnabled, .idleEnabled) } }
    @Published var idlePauseSeconds: Int { didSet { persist(idlePauseSeconds, .idlePause) } }
    @Published var idleResetMinutes: Int { didSet { persist(idleResetMinutes, .idleReset) } }
    @Published var skipDuringFullscreen: Bool { didSet { persist(skipDuringFullscreen, .fullscreen) } }
    @Published var respectFocusMode: Bool { didSet { persist(respectFocusMode, .focus) } }
    /// Auto-pause when the microphone is in use (call/meeting) (CR-06).
    @Published var pauseDuringMic: Bool { didSet { persist(pauseDuringMic, .pauseMic) } }

    // MARK: - Auxiliary reminders
    @Published var auxFlashScreen: Bool { didSet { persist(auxFlashScreen, .flash) } }
    @Published var auxMenubarHighlight: Bool { didSet { persist(auxMenubarHighlight, .menubarHi) } }
    @Published var soundEnabled: Bool { didSet { persist(soundEnabled, .sound) } }
    /// Alert sound name — a named system sound matching macOS "System Settings > Sound".
    @Published var soundName: String { didSet { persist(soundName, .soundName) } }
    @Published var menuBarStyle: MenuBarStyle { didSet { persist(menuBarStyle.rawValue, .menuBarStyle) } }

    // MARK: - System
    @Published var launchAtLogin: Bool {
        didSet {
            persist(launchAtLogin, .login)
            if ready { LoginItem.setEnabled(launchAtLogin) }
        }
    }
    @Published var enableShortcuts: Bool { didSet { persist(enableShortcuts, .shortcuts) } }
    /// The four global shortcuts (user-editable). Stored as one JSON blob.
    @Published var hotKeys: HotKeyBindings { didSet { persistHotKeys() } }
    /// In-app automatic update checking (Sparkle). Synced to Sparkle's `automaticallyChecksForUpdates`.
    @Published var autoUpdateCheck: Bool { didSet { persist(autoUpdateCheck, .autoUpdate) } }
    @Published var backend: HapticBackend {
        didSet { persist(backend.rawValue, .backend) }
    }

    // MARK: - Custom patterns
    @Published var customPatterns: [HapticPattern] { didSet { persistPatterns() } }

    // MARK: - First launch (not @Published, only for one-time onboarding)
    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunched.full) }
        set { defaults.set(newValue, forKey: Key.hasLaunched.full) }
    }

    /// One-time intro line in the control panel (flipped after the panel is first closed).
    var hasSeenPanelIntro: Bool {
        get { defaults.bool(forKey: Key.seenPanelIntro.full) }
        set { defaults.set(newValue, forKey: Key.seenPanelIntro.full) }
    }

    // MARK: - Derived
    var workMinutes: Int { breakIntervalMinutes }

    var allPatterns: [HapticPattern] { HapticPattern.builtins + customPatterns }

    var selectedPattern: HapticPattern {
        pattern(for: selectedPatternID) ?? .heartbeat
    }

    var headsUpPattern: HapticPattern { pattern(for: headsUpPatternID) ?? .gentle }
    var finishPattern: HapticPattern { pattern(for: finishPatternID) ?? .gentle }

    func pattern(for id: String) -> HapticPattern? {
        allPatterns.first { $0.id == id }
    }

    /// Get patterns by category (for the grouped pickers in settings/editor).
    func patterns(in category: HapticPatternCategory) -> [HapticPattern] {
        category == .custom ? customPatterns : HapticPattern.builtins(in: category)
    }

    // MARK: - Custom pattern operations
    func upsertCustomPattern(_ pattern: HapticPattern) {
        if let idx = customPatterns.firstIndex(where: { $0.id == pattern.id }) {
            customPatterns[idx] = pattern
        } else {
            customPatterns.append(pattern)
        }
    }

    func deleteCustomPattern(id: String) {
        customPatterns.removeAll { $0.id == id }
        if selectedPatternID == id { selectedPatternID = Default.pattern }
    }

    // MARK: - Factory defaults (init read fallbacks and "restore defaults" share one source of truth, preventing drift between the two)
    private enum Default {
        static let interval = 25
        static let restMinutes = 0
        static let pattern = HapticPattern.urgent.id
        static let headsUpPattern = HapticPattern.ripple.id
        static let finishPattern = HapticPattern.ramp.id
        static let strength = 6
        static let postpone = 5
        static let pulseSeconds = 20
        static let pulseMax = 4
        static let ackGesture = true
        static let typingDefer = true
        static let headsUp = true
        static let panelHeartbeat = true
        static let idleEnabled = true
        static let idlePause = 60
        static let idleReset = 5
        static let fullscreen = true
        static let focus = true
        static let pauseMic = true
        static let flash = true
        static let menubarHi = true
        static let sound = false
        static let soundName = "Tink"
        static let menuBarStyle = MenuBarStyle.iconCountdown
        static let login = false
        static let shortcuts = true
        static let autoUpdate = true
        static let backend = HapticBackend.auto
    }

    // MARK: - Initialization
    /// Defaults to `.standard` (app shared singleton); tests/ephemeral runs inject an in-memory implementation for isolation, zero disk footprint.
    init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
        Settings.migrateLegacyPomodoro(defaults)
        breakIntervalMinutes  = Settings.read(defaults, .interval, Default.interval)
        restMinutes           = Settings.read(defaults, .restMinutes, Default.restMinutes)
        selectedPatternID     = Settings.read(defaults, .pattern, Default.pattern)
        headsUpPatternID      = Settings.read(defaults, .headsUpPattern, Default.headsUpPattern)
        finishPatternID       = Settings.read(defaults, .finishPattern, Default.finishPattern)
        strength              = Settings.migrateStrength(defaults)
        postponeMinutes       = Settings.read(defaults, .postpone, Default.postpone)
        remindPulseSeconds    = Settings.read(defaults, .pulseSeconds, Default.pulseSeconds)
        remindPulseMax        = Settings.read(defaults, .pulseMax, Default.pulseMax)
        ackGestureEnabled     = Settings.read(defaults, .ackGesture, Default.ackGesture)
        typingAwareDefer      = Settings.read(defaults, .typingDefer, Default.typingDefer)
        gentleHeadsUp         = Settings.read(defaults, .headsUp, Default.headsUp)
        panelHeartbeat        = Settings.read(defaults, .panelHeartbeat, Default.panelHeartbeat)
        idleEnabled           = Settings.read(defaults, .idleEnabled, Default.idleEnabled)
        idlePauseSeconds      = Settings.read(defaults, .idlePause, Default.idlePause)
        idleResetMinutes      = Settings.read(defaults, .idleReset, Default.idleReset)
        skipDuringFullscreen  = Settings.read(defaults, .fullscreen, Default.fullscreen)
        respectFocusMode      = Settings.read(defaults, .focus, Default.focus)
        pauseDuringMic        = Settings.read(defaults, .pauseMic, Default.pauseMic)
        auxFlashScreen        = Settings.read(defaults, .flash, Default.flash)
        auxMenubarHighlight   = Settings.read(defaults, .menubarHi, Default.menubarHi)
        soundEnabled          = Settings.read(defaults, .sound, Default.sound)
        soundName             = Settings.read(defaults, .soundName, Default.soundName)
        menuBarStyle          = MenuBarStyle(rawValue: Settings.read(defaults, .menuBarStyle, Default.menuBarStyle.rawValue)) ?? Default.menuBarStyle
        launchAtLogin         = Settings.read(defaults, .login, Default.login)
        enableShortcuts       = Settings.read(defaults, .shortcuts, Default.shortcuts)
        hotKeys               = Settings.readHotKeys(defaults)
        autoUpdateCheck       = Settings.read(defaults, .autoUpdate, Default.autoUpdate)
        backend               = HapticBackend(rawValue: Settings.read(defaults, .backend, Default.backend.rawValue)) ?? Default.backend
        customPatterns        = Settings.readPatterns(defaults)
        // Stored IDs may point at a built-in preset removed in an update; fall back to the defaults
        // so the pickers never show an empty selection (runs before `ready`, so no broadcast storm).
        if pattern(for: selectedPatternID) == nil { selectedPatternID = Default.pattern }
        if pattern(for: headsUpPatternID)  == nil { headsUpPatternID  = Default.headsUpPattern }
        if pattern(for: finishPatternID)   == nil { finishPatternID   = Default.finishPattern }
        ready = true
    }

    /// Restore defaults: reset all preferences to factory defaults (**does not affect custom patterns or statistics**).
    /// During reset, temporarily set `ready=false` to silence per-item broadcasts (values are still written to
    /// UserDefaults); afterward, apply the login item and broadcast once, avoiding a notification storm and repeated timer restarts.
    func resetToDefaults() {
        ready = false
        breakIntervalMinutes  = Default.interval
        restMinutes           = Default.restMinutes
        selectedPatternID     = Default.pattern
        headsUpPatternID      = Default.headsUpPattern
        finishPatternID       = Default.finishPattern
        strength              = Default.strength
        postponeMinutes       = Default.postpone
        remindPulseSeconds    = Default.pulseSeconds
        remindPulseMax        = Default.pulseMax
        ackGestureEnabled     = Default.ackGesture
        typingAwareDefer      = Default.typingDefer
        gentleHeadsUp         = Default.headsUp
        panelHeartbeat        = Default.panelHeartbeat
        idleEnabled           = Default.idleEnabled
        idlePauseSeconds      = Default.idlePause
        idleResetMinutes      = Default.idleReset
        skipDuringFullscreen  = Default.fullscreen
        respectFocusMode      = Default.focus
        pauseDuringMic        = Default.pauseMic
        auxFlashScreen        = Default.flash
        auxMenubarHighlight   = Default.menubarHi
        soundEnabled          = Default.sound
        soundName             = Default.soundName
        menuBarStyle          = Default.menuBarStyle
        launchAtLogin         = Default.login
        enableShortcuts       = Default.shortcuts
        hotKeys               = HotKeyBindings.defaults
        autoUpdateCheck       = Default.autoUpdate
        backend               = Default.backend
        ready = true
        LoginItem.setEnabled(launchAtLogin)
        NotificationCenter.default.post(name: .hbSettingsChanged, object: nil)
    }

    // MARK: - Persistence
    private enum Key: String {
        case interval, restMinutes, pattern, headsUpPattern, finishPattern, strength, postpone
        case pulseSeconds, pulseMax, ackGesture
        case typingDefer, headsUp, panelHeartbeat
        case idleEnabled, idlePause, idleReset, fullscreen, focus, pauseMic
        case flash, menubarHi, sound, soundName, menuBarStyle
        case login, shortcuts, hotKeys, autoUpdate, backend
        case customPatterns
        case hasLaunched, seenPanelIntro

        var full: String { "hb." + rawValue }
    }

    private func persist<T>(_ value: T, _ key: Key) {
        defaults.set(value, forKey: key.full)
        if ready { NotificationCenter.default.post(name: .hbSettingsChanged, object: nil) }
    }

    private func persistPatterns() {
        if let data = try? JSONEncoder().encode(customPatterns) {
            defaults.set(data, forKey: Key.customPatterns.full)
        }
        if ready { NotificationCenter.default.post(name: .hbSettingsChanged, object: nil) }
    }

    private func persistHotKeys() {
        if let data = try? JSONEncoder().encode(hotKeys) {
            defaults.set(data, forKey: Key.hotKeys.full)
        }
        if ready { NotificationCenter.default.post(name: .hbSettingsChanged, object: nil) }
    }

    private static func readHotKeys(_ defaults: KeyValueStore) -> HotKeyBindings {
        guard let data = defaults.data(forKey: Key.hotKeys.full),
              let bindings = try? JSONDecoder().decode(HotKeyBindings.self, from: data)
        else { return .defaults }
        return bindings
    }

    private static func read<T>(_ defaults: KeyValueStore, _ key: Key, _ fallback: T) -> T {
        defaults.object(forKey: key.full) as? T ?? fallback
    }

    /// One-time migration of the legacy pomodoro model into the unified work/rest cycle:
    /// pomodoro on → interval takes the old work length (snapped to the nearest selectable option)
    /// and `restMinutes` the old break length; pomodoro off → `restMinutes = 0` (pure reminder).
    /// The legacy keys (`hb.pomodoro` / `hb.pomoWork` / `hb.pomoBreak` and the retired
    /// `hb.reminderRepeat` / `hb.escalation`) are removed afterwards.
    private static func migrateLegacyPomodoro(_ defaults: KeyValueStore) {
        if defaults.object(forKey: Key.restMinutes.full) == nil,
           let pomodoroOn = defaults.object(forKey: "hb.pomodoro") as? Bool {
            if pomodoroOn {
                let work = defaults.object(forKey: "hb.pomoWork") as? Int ?? 25
                let rest = defaults.object(forKey: "hb.pomoBreak") as? Int ?? 5
                let snapped = intervalOptions.min { abs($0 - work) < abs($1 - work) } ?? Default.interval
                defaults.set(snapped, forKey: Key.interval.full)
                defaults.set(max(1, min(30, rest)), forKey: Key.restMinutes.full)
            } else {
                defaults.set(0, forKey: Key.restMinutes.full)
            }
        }
        for legacy in ["hb.pomodoro", "hb.pomoWork", "hb.pomoBreak", "hb.reminderRepeat", "hb.escalation"] {
            defaults.set(nil, forKey: legacy)
        }
    }

    /// Global strength migration: prefer the new key `hb.strength`; otherwise migrate the old key
    /// `hb.intensity` (1…5) ×2 to 1…10 and persist once.
    private static func migrateStrength(_ defaults: KeyValueStore) -> Int {
        if let v = defaults.object(forKey: Key.strength.full) as? Int { return max(1, min(10, v)) }
        if let old = defaults.object(forKey: "hb.intensity") as? Int {
            let s = max(1, min(10, old * 2))
            defaults.set(s, forKey: Key.strength.full)
            return s
        }
        return Default.strength
    }

    private static func readPatterns(_ defaults: KeyValueStore) -> [HapticPattern] {
        guard let data = defaults.data(forKey: Key.customPatterns.full),
              let patterns = try? JSONDecoder().decode([HapticPattern].self, from: data)
        else { return [] }
        return patterns
    }
}
