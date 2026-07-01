import AppKit

/// Auxiliary reminders: optional "screen flash" and sound, as extra channels beyond haptics.
final class AuxReminder {

    private var activeWindows: [NSWindow] = []

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
            for screen in NSScreen.screens {
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

                let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.white.cgColor
                view.alphaValue = 0
                window.contentView = view
                window.orderFrontRegardless()
                self.activeWindows.append(window)

                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    view.animator().alphaValue = 0.18
                }, completionHandler: {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.5
                        view.animator().alphaValue = 0
                    }, completionHandler: {
                        window.orderOut(nil)
                        self.activeWindows.removeAll { $0 == window }
                    })
                })
            }
        }
    }

    func playSound(named name: String) {
        Self.play(named: name)
    }
}
