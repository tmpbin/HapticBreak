import AppKit

/// Auxiliary reminders: optional "screen flash" and sound, as extra channels beyond haptics.
final class AuxReminder {

    /// One reusable overlay window per screen (rebuilt when the screen layout changes). The flash
    /// fires every nudge (every ~10 s while reminding) — creating fresh NSWindows each time was
    /// pure window-server churn.
    private var flashWindows: [NSWindow] = []
    /// Invalidates stale completion handlers when flashes overlap (manual test during a nudge).
    private var flashGeneration = 0

    /// Optional system alert sounds — the built-in named sounds matching macOS "System Settings > Sound >
    /// Alert sound", used directly via `NSSound(named:)` without bundling. Ordered roughly from light to
    /// heavy, crisp to deep.
    static let systemSoundNames = [
        "Tink", "Pop", "Glass", "Ping", "Purr",
        "Bottle", "Frog", "Funk", "Hero", "Morse",
        "Submarine", "Blow", "Sosumi", "Basso"
    ]

    /// Play a named system alert sound (silently ignored if not found). Shared by the settings preview and the on-time reminder.
    static func play(named name: String) {
        DispatchQueue.main.async { NSSound(named: name)?.play() }
    }

    /// Do one very brief, low-opacity white fade flash across all screens (non-interrupting, non-clickable).
    func flashScreen() {
        DispatchQueue.main.async {
            self.ensureFlashWindows()
            self.flashGeneration += 1
            let generation = self.flashGeneration
            for window in self.flashWindows {
                guard let view = window.contentView else { continue }
                view.layer?.removeAllAnimations()
                view.alphaValue = 0
                window.orderFrontRegardless()

                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    view.animator().alphaValue = 0.18
                }, completionHandler: {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.5
                        view.animator().alphaValue = 0
                    }, completionHandler: {
                        // Only the newest flash may tuck the window away — an overlapping flash
                        // (manual test during a nudge) keeps it on screen for its own run.
                        if self.flashGeneration == generation { window.orderOut(nil) }
                    })
                })
            }
        }
    }

    /// Build (or rebuild after a display change) one overlay window per screen.
    private func ensureFlashWindows() {
        let screens = NSScreen.screens
        let layoutMatches = flashWindows.count == screens.count
            && zip(flashWindows, screens).allSatisfy { $0.frame == $1.frame }
        guard !layoutMatches else { return }
        for window in flashWindows { window.orderOut(nil) }
        flashWindows = screens.map(Self.makeFlashWindow(for:))
    }

    private static func makeFlashWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.alphaValue = 0
        window.contentView = view
        return window
    }

    func playSound(named name: String) {
        Self.play(named: name)
    }
}
