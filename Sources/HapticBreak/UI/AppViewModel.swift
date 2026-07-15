import SwiftUI

/// Today's rhythm snapshot for the panel band: work density per hour + real-rest dots.
struct TodayRhythm: Equatable {
    var activeByHour: [Int] = Array(repeating: 0, count: 24)
    var breakMinutes: [Int] = []
    var isEmpty: Bool { breakMinutes.isEmpty && activeByHour.allSatisfy { $0 == 0 } }
}

/// Haptic backend identity/health (shown in About and the panel's warning row). Lives in its own
/// observable, apart from `AppViewModel`: `remaining` fires `objectWillChange` every second, and any
/// hidden-but-alive auxiliary window observing the view model would re-layout + redraw once per tick
/// in the background (see docs/PANEL_CPU_INVESTIGATION.md §12). Auxiliary windows must observe only
/// this (rarely changing) object — never the whole view model.
final class BackendStatus: ObservableObject {
    @Published var name: String = ""
    @Published var available: Bool = true
}

/// Bridge between the controller and SwiftUI (MVVM). Holds mirrored state and the action entry points.
///
/// CPU regression rule: `remaining` makes this object tick at 1 Hz. Only the panel (PopoverView) may
/// observe it via `@ObservedObject`; auxiliary window views (Settings / editor / About / lab / stats)
/// hold it as a plain `let` for actions, or observe `backend` for the rare backend fields.
final class AppViewModel: ObservableObject {

    @Published var remaining: Int = 0
    @Published var total: Int = 1
    @Published var phase: BreakPhase = .working
    @Published var pauseReason: PauseReason = .none
    @Published var isDeferring: Bool = false
    let backend = BackendStatus()
    /// Whether the control panel is visible. When collapsed, the ring stops all animation rendering,
    /// minimizing background resource usage.
    @Published var panelVisible: Bool = false
    /// Flipped to `true` after several unanswered nudges to show the teaching hint card
    /// (explaining triple-tap / step-away acknowledgment). Cleared when the phase leaves reminding.
    @Published var showNudgeHint: Bool = false

    let settings = Settings.shared
    weak var controller: AppController?

    var isPaused: Bool { pauseReason.isPaused }
    var progress: Double { total > 0 ? Double(total - remaining) / Double(total) : 0 }
    /// While a reminder awaits acknowledgment there is no countdown — show a short invitation instead.
    var timeString: String {
        phase == .reminding ? L.t("status.breakShort") : Self.format(remaining)
    }

    static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    var statusText: String {
        if isDeferring { return L.t("status.waitingTyping") }
        switch pauseReason {
        case .manual:     return L.t("status.paused")
        case .idle:       return L.t("status.idlePaused")
        case .focus:      return L.t("status.focusPaused")
        case .fullscreen: return L.t("status.fullscreenPaused")
        case .meeting:    return L.t("status.meetingPaused")
        case .scene:      return L.t("status.scenePaused")
        case .none:
            switch phase {
            case .working:   return L.t("status.working")
            case .reminding: return L.t("status.reminding")
            case .resting:   return L.t("status.resting")
            }
        }
    }

    var statusSymbol: String {
        if isDeferring { return "ellipsis.circle.fill" }
        switch pauseReason {
        case .manual:     return "pause.circle.fill"
        case .idle:       return "moon.zzz.fill"
        case .focus:      return "moon.fill"
        case .fullscreen: return "rectangle.inset.filled"
        case .meeting:    return "mic.fill"
        case .scene:      return "moon.stars.fill"
        case .none:
            switch phase {
            case .working:   return "bolt.fill"
            case .reminding: return "cup.and.saucer.fill"
            case .resting:   return "cup.and.saucer.fill"
            }
        }
    }

    var accentColor: Color {
        if isPaused { return pauseReason == .manual ? .orange : .gray }
        switch phase {
        case .working:   return .blue
        case .reminding: return .orange
        case .resting:   return .green
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// The time of the next reminder (only meaningful while working and not paused).
    var nextFireText: String {
        guard !isPaused, !isDeferring, phase == .working else { return "" }
        return Self.clockFormatter.string(from: Date().addingTimeInterval(TimeInterval(remaining)))
    }

    /// Consecutive days of completed rests (streak). Cached and refreshed by the controller (on panel open /
    /// when a break is recorded), so the panel doesn't recompute it on every per-second render.
    @Published var streak: Int = 0
    /// Real rests completed today (cached like `streak`; drives the panel's companion line).
    @Published var todayBreaks: Int = 0
    /// Today's rhythm band data (cached like `streak`).
    @Published var todayRhythm: TodayRhythm = TodayRhythm()
    /// Companion line for an active quiet scene (empty = no scene active).
    @Published var sceneText: String = ""

    // MARK: - Actions
    func startFocusScene()    { controller?.startFocusScene() }
    func startQuietScene(_ kind: QuietScene) { controller?.startQuietScene(kind) }
    func cancelScene()        { controller?.cancelQuietScene() }
    func togglePause()        { controller?.toggleManualPause() }
    func skip()               { controller?.skip() }
    func postpone()           { controller?.postpone() }
    func breakNow()           { controller?.breakNow() }
    func acknowledge()        { controller?.acknowledge(.panel) }
    func ringImpact()         { controller?.ringImpact() }
    func testCurrentPattern() { controller?.testCurrentPattern() }
    func testPattern(_ p: HapticPattern) { controller?.testPattern(p) }
    func testStep(_ step: HapticStep)    { controller?.testStep(step) }
    func auditionStep(_ step: HapticStep) { controller?.auditionStep(step) }
    func openSettings()       { controller?.openSettings() }
    func openStatistics()     { controller?.openStatistics() }
    func openPatternEditor()  { controller?.openPatternEditor() }
    func openHapticLab()      { controller?.openHapticLab() }
    func openAbout()          { controller?.openAbout() }
    func setHotKeyCapture(_ active: Bool) { controller?.setHotKeyCaptureActive(active) }
    func quit()               { NSApp.terminate(nil) }
}
