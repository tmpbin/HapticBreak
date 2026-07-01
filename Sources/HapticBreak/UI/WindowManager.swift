import AppKit
import SwiftUI

/// Manages the SwiftUI windows for settings / statistics / pattern editor / haptic lab (reused, brought to front).
final class WindowManager {

    private let viewModel: AppViewModel
    private var settingsWindow: NSWindow?
    private var statsWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var hapticLabWindow: NSWindow?
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
    }

    func showSettings() {
        settingsWindow = present(settingsWindow,
                                 title: L.t("window.settings"),
                                 size: NSSize(width: 460, height: 600)) {
            SettingsView(viewModel: viewModel)
        }
    }

    func showStatistics() {
        statsWindow = present(statsWindow,
                              title: L.t("window.stats"),
                              size: NSSize(width: 520, height: 560)) {
            StatisticsView()
        }
    }

    func showPatternEditor() {
        editorWindow = present(editorWindow,
                               title: L.t("editor.title"),
                               size: NSSize(width: 560, height: 560)) {
            PatternEditorView(viewModel: viewModel)
        }
    }

    func showHapticLab() {
        hapticLabWindow = present(hapticLabWindow,
                                  title: L.t("window.hapticLab"),
                                  size: NSSize(width: 480, height: 640)) {
            HapticLabView()
        }
    }

    /// Show the native macOS About panel (app icon / name / version + tagline credits).
    /// Version is read from the packaged `CFBundleShortVersionString`, falling back for dev runs.
    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: L.t("settings.about"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "HapticBreak",
            .applicationVersion: version,
            .credits: credits,
        ])
    }

    private func present<Content: View>(_ existing: NSWindow?,
                                        title: String,
                                        size: NSSize,
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
        window.setContentSize(size)          // Override any initial size from hosting, keeping it consistent with center()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
