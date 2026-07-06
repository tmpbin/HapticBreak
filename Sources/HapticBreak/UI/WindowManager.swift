import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted every time the statistics window is presented. Windows are reused (closing only hides
    /// them), so SwiftUI `onAppear` fires just once per app run — snapshot-based views listen for this
    /// to reload instead of showing data frozen at first open.
    static let hbStatsWindowShown = Notification.Name("com.aremind.hapticbreak.statsWindowShown")
}

/// Manages the SwiftUI windows for settings / statistics / pattern editor / haptic lab (reused, brought to front).
final class WindowManager {

    private let viewModel: AppViewModel
    private var settingsWindow: NSWindow?
    private var statsWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var hapticLabWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var languageObserver: NSObjectProtocol?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        // On language switch, window content refreshes automatically via SwiftUI; the title is an AppKit
        // property and must be synced manually.
        languageObserver = NotificationCenter.default.addObserver(
            forName: .hbLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.retitleWindows()
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    private func retitleWindows() {
        settingsWindow?.title = L.t("window.settings")
        statsWindow?.title = L.t("window.stats")
        editorWindow?.title = L.t("editor.title")
        hapticLabWindow?.title = L.t("window.hapticLab")
        aboutWindow?.title = L.t("window.about")
    }

    func showSettings() {
        settingsWindow = present(settingsWindow,
                                 title: L.t("window.settings"),
                                 size: NSSize(width: 460, height: 600),
                                 minSize: NSSize(width: 460, height: 520)) {
            SettingsView(viewModel: viewModel)
        }
    }

    func showStatistics() {
        statsWindow = present(statsWindow,
                              title: L.t("window.stats"),
                              size: NSSize(width: 520, height: 560),
                              minSize: NSSize(width: 480, height: 480)) {
            StatisticsView()
        }
        NotificationCenter.default.post(name: .hbStatsWindowShown, object: nil)
    }

    func showPatternEditor() {
        editorWindow = present(editorWindow,
                               title: L.t("editor.title"),
                               size: NSSize(width: 560, height: 560),
                               minSize: NSSize(width: 520, height: 480)) {
            PatternEditorView(viewModel: viewModel)
        }
    }

    func showHapticLab() {
        hapticLabWindow = present(hapticLabWindow,
                                  title: L.t("window.hapticLab"),
                                  size: NSSize(width: 480, height: 640),
                                  minSize: NSSize(width: 460, height: 560)) {
            HapticLabView()
        }
    }

    /// Custom About window: app identity plus the haptic backend diagnostics (moved out of Settings —
    /// they're debug information, not everyday decisions) and the hidden Haptic Lab entry.
    func showAbout() {
        aboutWindow = present(aboutWindow,
                              title: L.t("window.about"),
                              size: NSSize(width: 400, height: 460)) {
            AboutView(viewModel: viewModel)
        }
    }

    private func present<Content: View>(_ existing: NSWindow?,
                                        title: String,
                                        size: NSSize,
                                        minSize: NSSize? = nil,
                                        content: () -> Content) -> NSWindow {
        if let existing = existing {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        let hosting = NSHostingController(rootView: content())
        // Key: clear sizingOptions. The default includes `.preferredContentSize`, which lets SwiftUI's
        // "ideal size" push back and rewrite the window size after it appears → causing "pop then jump /
        // grow/shrink". After clearing, the window stably uses the fixed size below, and overly tall
        // content scrolls within the Form/ScrollView itself.
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        // SwiftUI `.frame(minWidth:minHeight:)` can't constrain a manually managed NSWindow (with
        // sizingOptions cleared, nothing feeds the min back to AppKit) — enforce it here so the user
        // can't shrink the window until controls clip or overlap.
        window.contentMinSize = minSize ?? size
        window.setContentSize(size)          // Override any initial size from hosting, keeping it consistent with center()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
