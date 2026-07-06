import SwiftUI
import AppKit

/// Offscreen-render each SwiftUI screen to PNG for visual review without screen-recording permission.
/// Uses a real NSHostingView + offscreen-window cacheDisplay, correctly rendering Picker/Slider/Toggle/Charts.
/// Usage: `HapticBreak --rendershots <dir> [zhHans|en|ja]`
@MainActor
func renderShots(to dir: String, language: AppLanguage? = nil) -> Int32 {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // When a language is specified, switch preview-only (not persisted) for a tri-lingual visual review.
    if let language { L10n.shared.previewOnlySet(language) }

    // Set representative "fresh install" defaults so snapshots faithfully reflect the real first-run
    // experience. Safe against the user's real preferences: `--rendershots` is an ephemeral run
    // (RuntimeMode), so Settings.shared is backed by an in-memory store.
    let s = Settings.shared
    s.breakIntervalMinutes = 25
    s.restMinutes = 0
    s.selectedPatternID = HapticPattern.urgent.id
    s.strength = 6
    s.remindPulseSeconds = 20
    s.remindPulseMax = 4
    s.ackGestureEnabled = true
    s.auxFlashScreen = true
    s.postponeMinutes = 5
    s.idleEnabled = true
    s.idlePauseSeconds = 60
    s.idleResetMinutes = 5
    s.skipDuringFullscreen = true
    s.respectFocusMode = true
    s.auxMenubarHighlight = true
    s.soundEnabled = false
    s.soundName = "Tink"
    s.menuBarStyle = .iconCountdown
    s.typingAwareDefer = true
    s.gentleHeadsUp = true
    s.pauseDuringMic = true
    s.enableShortcuts = true

    // Representative "mid-afternoon" rhythm: morning ramp-up, lunch dip, afternoon block + real rests.
    var rhythm = TodayRhythm()
    let hourLoad = [9: 2400, 10: 3300, 11: 2900, 12: 800, 13: 1900, 14: 3100, 15: 2600]
    for (hour, seconds) in hourLoad { rhythm.activeByHour[hour] = seconds }
    rhythm.breakMinutes = [10 * 60 + 25, 11 * 60 + 45, 14 * 60 + 30]

    let vm = AppViewModel()
    vm.remaining = 912
    vm.total = 1500
    vm.phase = .working
    vm.pauseReason = .none
    vm.backendName = L.t("backend.name.private")
    vm.backendAvailable = true
    vm.todayBreaks = 3
    vm.todayRhythm = rhythm
    vm.panelVisible = true   // Snapshot represents the "panel open" state: the ring renders as active (second hand/shimmer normal, not the collapsed power-saving state)

    // A second view model frozen in the reminding phase, to review the acknowledge-to-stop UI
    // (orange ring, "Start break" primary action).
    let vmReminding = AppViewModel()
    vmReminding.remaining = 0
    vmReminding.total = 1
    vmReminding.phase = .reminding
    vmReminding.pauseReason = .none
    vmReminding.backendName = L.t("backend.name.private")
    vmReminding.backendAvailable = true
    vmReminding.todayBreaks = 3
    vmReminding.todayRhythm = rhythm
    vmReminding.panelVisible = true

    // A third view model frozen mid-rest, to review the breathing companion (halo + rotating tips).
    let vmResting = AppViewModel()
    vmResting.remaining = 224
    vmResting.total = 300
    vmResting.phase = .resting
    vmResting.pauseReason = .none
    vmResting.backendName = L.t("backend.name.private")
    vmResting.backendAvailable = true
    vmResting.todayBreaks = 3
    vmResting.todayRhythm = rhythm
    vmResting.panelVisible = true

    func shoot<V: View>(_ name: String, _ view: V, light: Bool) {
        // Composite an adaptive background (simulating the NSPopover / NSWindow surface) to faithfully review dark-mode contrast.
        let wrapped = ZStack {
            Color(nsColor: .windowBackgroundColor)
            view
        }
        let host = NSHostingView(rootView: AnyView(wrapped))
        var size = host.fittingSize
        if size.width < 1 { size.width = 460 }
        if size.height < 1 { size.height = 560 }
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000,
                                                  width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("render fail: \(name)"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let suffix = light ? "-light" : "-dark"
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)\(suffix).png"))
            print("wrote \(name)\(suffix).png \(Int(size.width))x\(Int(size.height))")
        }
        window.orderOut(nil)
    }

    for light in [true, false] {
        shoot("popover", PopoverView(viewModel: vm), light: light)
        shoot("popover-reminding", PopoverView(viewModel: vmReminding), light: light)
        shoot("popover-resting", PopoverView(viewModel: vmResting), light: light)
        shoot("settings", SettingsView(viewModel: vm), light: light)
        shoot("settings-advanced", SettingsView(viewModel: vm, initialTab: .advanced), light: light)
        shoot("about", AboutView(viewModel: vm), light: light)
        shoot("statistics", StatisticsView(), light: light)
        shoot("editor", PatternEditorView(viewModel: vm), light: light)
        shoot("hapticlab", HapticLabView(), light: light)
    }
    return 0
}
