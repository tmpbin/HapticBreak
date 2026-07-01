import AppKit
import SwiftUI

// HapticBreak — a macOS app that reminds you to take breaks via trackpad haptics.
// Pure native AppKit/SwiftUI, menu-bar resident (accessory), no Dock icon.

// Self-test mode: verify the Swift-side dlopen bindings can actually trigger haptics, for pre-packaging regression checks.
if CommandLine.arguments.contains("--selftest") {
    let engine = HapticEngineFactory.make(.auto, debug: true)
    print("backend=\(engine.backendName) available=\(engine.isAvailable)")
    let player = HapticPlayer(engine: engine)
    for s in 1...10 {
        player.testTone(timbre: .crisp, strength: s, dullness: 0.3, strengthGlobal: 6)
        usleep(450_000)
    }
    usleep(600_000)
    exit(engine.isAvailable ? 0 : 2)
}

// Haptic strength calibration: play the strength curve 1→10 in order (crisp timbre, float0 as the linear main control) and confirm on device it gets progressively stronger.
// See `HapticProfile` for timbre-family IDs and the mapping math; for per-step choreography or timbre changes, use "Haptic Lab".
if CommandLine.arguments.contains("--hapticscan") {
    let engine = PrivateHapticEngine(debug: true)
    let devDesc = engine.deviceID.map { String(format: "0x%llx", $0) } ?? "nil"
    print("available=\(engine.isAvailable) deviceID=\(devDesc)")
    let profile = HapticProfile.shared
    print("== strength curve 1→10 (crisp timbre · float0 linear main control; should get stronger, if a level is weaker it's abnormal) ==")
    for s in 1...10 {
        let tone = profile.resolve(timbre: .crisp, strength: s, dullness: 0.3, global: 6)
        print("  ▶︎ strength \(s)  →  ID \(tone.actuationID) · float0 \(String(format: "%.2f", tone.float0)) · float1 \(String(format: "%.2f", tone.float1))")
        for _ in 0..<2 {
            engine.actuate(tone)
            usleep(220_000)
        }
        usleep(900_000)
    }
    print("For per-step choreography of timbre/strength/dullness, or to browse all timbres, open: --hapticlab")
    exit(engine.isAvailable ? 0 : 2)
}

// Rhythm audition: play every rhythm-category groove (incl. iconic motifs) back-to-back at global strength 6,
// so the whole set can be felt in one pass on the trackpad and tuned by feel.
if CommandLine.arguments.contains("--rhythms") {
    let engine = HapticEngineFactory.make(.auto, debug: false)
    print("backend=\(engine.backendName) available=\(engine.isAvailable)")
    let player = HapticPlayer(engine: engine)
    for pattern in HapticPattern.builtins(in: .rhythm) {
        print("  ▶︎ \(pattern.displayName)  ·  \(pattern.steps.count) beats  ·  ~\(String(format: "%.1f", pattern.estimatedDuration))s")
        player.play(pattern, strength: 6)
        usleep(useconds_t((pattern.estimatedDuration + 1.1) * 1_000_000))
    }
    exit(engine.isAvailable ? 0 : 2)
}

// Haptic Lab: direct standalone window for on-device calibration (timbre-family assignment + 1→10 curve + raw probe).
if CommandLine.arguments.contains("--hapticlab") {
    let labApp = NSApplication.shared
    labApp.setActivationPolicy(.regular)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                       backing: .buffered, defer: false)
    win.title = L.t("window.hapticLab")
    let labHosting = NSHostingController(rootView: HapticLabView())
    labHosting.sizingOptions = []          // Prevent SwiftUI's ideal size from pushing back and making the window jump after it appears
    win.contentViewController = labHosting
    win.center()
    win.makeKeyAndOrderFront(nil)
    labApp.activate(ignoringOtherApps: true)
    labApp.run()
    exit(0)
}

// Logic self-test: headless verification of the timer state machine (skip/postpone/pause/idle/deadline/pomodoro).
if CommandLine.arguments.contains("--logictest") {
    exit(runLogicTests())
}

// Icon generation: programmatically draw the 1024×1024 primary artwork.
if let idx = CommandLine.arguments.firstIndex(of: "--makeicon"),
   idx + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    exit(makeAppIcon(to: CommandLine.arguments[idx + 1]))
}

// Offscreen-render UI snapshots for visual review. Optional second argument specifies the language (zhHans|en|ja) for a tri-lingual review.
if let idx = CommandLine.arguments.firstIndex(of: "--rendershots"),
   idx + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dir = CommandLine.arguments[idx + 1]
    let lang: AppLanguage? = idx + 2 < CommandLine.arguments.count
        ? AppLanguage(rawValue: CommandLine.arguments[idx + 2])
        : nil
    let rc = MainActor.assumeIsolated { renderShots(to: dir, language: lang) }
    exit(rc)
}

// Read-only environment check: verify idle/fullscreen/Focus detection and statistics reads don't crash and return sane values.
if CommandLine.arguments.contains("--checkenv") {
    _ = NSApplication.shared
    print("idleSeconds = \(String(format: "%.1f", IdleMonitor.secondsSinceLastInput()))")
    print("frontmostFullscreen = \(FullscreenDetector.isFrontmostFullscreen())")
    print("focusActive = \(FocusModeDetector.isFocusActive())")
    print("micActive = \(MicMonitor.isActive())")
    print("loginItemEnabled = \(LoginItem.isEnabled)")
    let today = StatisticsStore.shared.today()
    print("statsToday = \(today.date) active=\(today.activeSeconds)s breaks=\(today.breaks)")
    print("currentStreak = \(StatisticsStore.shared.currentStreak())")
    print("csvHeader = \(StatisticsStore.shared.exportCSV().split(separator: "\n").first ?? "")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
