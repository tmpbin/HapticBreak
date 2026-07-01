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

    // Set representative "fresh install" defaults so snapshots faithfully reflect the real first-run experience (doesn't affect the .app domain).
    let s = Settings.shared
    s.breakIntervalMinutes = 25
    s.selectedPatternID = HapticPattern.urgent.id
    s.strength = 6
    s.reminderRepeat = 3
    s.auxFlashScreen = true
    s.postponeMinutes = 5
    s.idleEnabled = true
    s.idlePauseSeconds = 60
    s.idleResetMinutes = 5
    s.skipDuringFullscreen = true
    s.respectFocusMode = true
    s.pomodoroEnabled = false
    s.pomodoroWorkMinutes = 25
    s.pomodoroBreakMinutes = 5
    s.auxMenubarHighlight = true
    s.soundEnabled = false
    s.soundName = "Tink"
    s.menuBarStyle = .iconCountdown
    s.typingAwareDefer = true
    s.gentleHeadsUp = true
    s.skipEscalation = false
    s.pauseDuringMic = true
    s.enableShortcuts = true

    let vm = AppViewModel()
    vm.remaining = 912
    vm.total = 1500
    vm.phase = .working
    vm.pauseReason = .none
    vm.backendName = L.t("backend.name.private")
    vm.backendAvailable = true
    vm.panelVisible = true   // Snapshot represents the "panel open" state: the ring renders as active (second hand/shimmer normal, not the collapsed power-saving state)

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
        shoot("settings", SettingsView(viewModel: vm), light: light)
        shoot("statistics", StatisticsView(), light: light)
        shoot("editor", PatternEditorView(viewModel: vm), light: light)
        shoot("hapticlab", HapticLabView(), light: light)
    }
    return 0
}
