import SwiftUI

/// Bridge between the controller and SwiftUI (MVVM). Holds mirrored state and the action entry points.
final class AppViewModel: ObservableObject {

    @Published var remaining: Int = 0
    @Published var total: Int = 1
    @Published var phase: BreakPhase = .working
    @Published var pauseReason: PauseReason = .none
    @Published var isDeferring: Bool = false
    @Published var backendName: String = ""
    @Published var backendAvailable: Bool = true
    /// Whether the control panel is visible. When collapsed, the ring stops all animation rendering,
    /// minimizing background resource usage.
    @Published var panelVisible: Bool = false

    let settings = Settings.shared
    weak var controller: AppController?

    var isPaused: Bool { pauseReason.isPaused }
    var progress: Double { total > 0 ? Double(total - remaining) / Double(total) : 0 }
    var timeString: String { Self.format(remaining) }

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
        case .none:       return phase == .resting ? L.t("status.resting") : L.t("status.working")
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
        case .none:       return phase == .resting ? "cup.and.saucer.fill" : "bolt.fill"
        }
    }

    var accentColor: Color {
        if isPaused { return pauseReason == .manual ? .orange : .gray }
        return phase == .resting ? .green : .blue
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

    // MARK: - Actions
    func togglePause()        { controller?.toggleManualPause() }
    func skip()               { controller?.skip() }
    func postpone()           { controller?.postpone() }
    func breakNow()           { controller?.breakNow() }
    func ringImpact()         { controller?.ringImpact() }
    func testCurrentPattern() { controller?.testCurrentPattern() }
    func testPattern(_ p: HapticPattern) { controller?.testPattern(p) }
    func testStep(_ step: HapticStep)    { controller?.testStep(step) }
    func openSettings()       { controller?.openSettings() }
    func openStatistics()     { controller?.openStatistics() }
    func openPatternEditor()  { controller?.openPatternEditor() }
    func openHapticLab()      { controller?.openHapticLab() }
    func openAbout()          { controller?.openAbout() }
    func quit()               { NSApp.terminate(nil) }
}
