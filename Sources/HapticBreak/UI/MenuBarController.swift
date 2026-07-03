import AppKit
import SwiftUI

/// Menu-bar status item: left click opens the control panel (Popover), right click shows a quick menu,
/// and it displays the countdown on demand.
final class MenuBarController: NSObject {

    private let viewModel: AppViewModel
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hostingController: NSHostingController<PopoverView>!

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    private lazy var iconImage: NSImage? = {
        let img = Self.symbolImage("hand.tap.fill")
        img?.isTemplate = true
        return img
    }()

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = iconImage
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // The popover size is computed and clamped synchronously by preparePopoverSize() before every
        // expansion, so it's deterministic and controllable.
        // We do NOT enable sizingOptions=[.preferredContentSize]: that option rewrites
        // preferredContentSize asynchronously after expansion, competing with our contentSize and possibly
        // growing taller again post-expansion — pushing the top ring behind the menu bar. That's one of
        // the root causes of the "occlusion".
        let hosting = NSHostingController(rootView: PopoverView(viewModel: viewModel, collapsed: true))
        hostingController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting
        popover.delegate = self
        refresh()
    }

    /// Compute and clamp the popover size synchronously before expansion:
    /// 1) Force layout and set contentSize to the content's real height, so NSPopover lands right the first
    ///    time and doesn't deform after expansion;
    /// 2) The key guardrail — clamp the height within the "available height below the menu bar on the
    ///    status item's screen": once the content exceeds the available height, AppKit tucks the top behind
    ///    the menu bar (top ring occluded). After clamping, the popover always fits fully below the menu
    ///    bar, structurally eliminating occlusion.
    private func preparePopoverSize() {
        hostingController.view.layoutSubtreeIfNeeded()
        var fitting = hostingController.view.fittingSize
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        if let screen {
            // Reserve room for the arrow and top/bottom safety margins; shrink if it overflows (a fallback
            // for tiny screens / taller future content).
            let maxHeight = screen.visibleFrame.height - 24
            if fitting.height > maxHeight { fitting.height = maxHeight }
        }
        if fitting.width > 100, fitting.height > 100 {
            popover.contentSize = fitting
        }
    }

    /// Last states actually pushed to the status button. `refresh()` runs every tick (1 Hz), but
    /// reassigning an unchanged title/image/tint still dirties the button and redraws the menu bar
    /// (plus its replicant snapshot) — measurable idle CPU when paused or in a title-less style.
    /// Diffing here means the button only redraws when something visible changed.
    private var lastTitle: String?
    private var lastImage: NSImage?
    private var lastTint: NSColor?
    /// Progress-ring quantization step last drawn (the 16 pt glyph can't resolve finer than ~1/64 turn,
    /// so redrawing it every second is pure waste — once per step suffices).
    private var ringStep = -1
    private var ringImage: NSImage?
    private static let ringSteps = 64

    /// Refresh the menu-bar icon (style), countdown, and tinting.
    func refresh() {
        guard let button = statusItem?.button else { return }

        // Icon-only / progress-ring are "title-less": use a zero-width character as a placeholder to trigger
        // the menu bar's light/dark adaptive tinting (NSStatusBarButton's template image only inverts with
        // the menu-bar background when accompanied by a title).
        let title: String
        let image: NSImage?
        switch viewModel.settings.menuBarStyle {
        case .iconCountdown:
            title = " " + viewModel.timeString
            image = iconImage
        case .iconOnly:
            title = "\u{200B}"
            image = iconImage
        case .progressRing:
            title = "\u{200B}"
            let step = Int((max(0, min(1, viewModel.progress)) * Double(Self.ringSteps)).rounded())
            if step != ringStep || ringImage == nil {
                ringStep = step
                ringImage = progressRingImage(progress: Double(step) / Double(Self.ringSteps))
            }
            image = ringImage
        }
        if title != lastTitle { lastTitle = title; button.title = title }
        if image !== lastImage { lastImage = image; button.image = image }

        // Reminder-state emphasis: gray when paused, orange when near. Stays nil normally, so the system
        // adapts tinting to the wallpaper contrast.
        let tint: NSColor?
        if viewModel.isPaused {
            tint = .secondaryLabelColor
        } else if viewModel.settings.auxMenubarHighlight && viewModel.remaining <= 60 && viewModel.phase == .working {
            tint = .systemOrange
        } else {
            tint = nil
        }
        if tint != lastTint { lastTint = tint; button.contentTintColor = tint }
    }

    /// Draw the menu-bar "progress ring" template image: a thin track ring + a solid arc that grows with progress.
    private func progressRingImage(progress: Double) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 2.5, dy: 2.5)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1.4
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()

        let p = max(0, min(1, progress))
        if p > 0.001 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(p), clockwise: true)
            arc.lineWidth = 2.4
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// A brief highlight pulse when a reminder fires.
    func pulse() {
        guard let button = statusItem?.button else { return }
        button.contentTintColor = .systemRed
        lastTint = .systemRed   // keep the diff cache honest so the follow-up refresh() restores the tint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Interaction

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    /// Expand the panel content to its full form before showing, so `preparePopoverSize()` measures the real
    /// height and the ring animates while visible.
    private func expandPanelContent() {
        hostingController.rootView = PopoverView(viewModel: viewModel, collapsed: false)
    }

    /// Collapse the panel content to an inert placeholder once dismissed. The popover keeps the hosting view
    /// alive, so without this the observed view model's per-second ticks would re-lay-out the whole ring in
    /// the background (idle CPU creeping up after the panel is opened once).
    private func collapsePanelContent() {
        hostingController.rootView = PopoverView(viewModel: viewModel, collapsed: true)
    }

    /// Actively open the control panel (used for the first-launch onboarding).
    func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        expandPanelContent()
        preparePopoverSize()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            expandPanelContent()
            preparePopoverSize()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let pauseTitle = viewModel.pauseReason == .manual ? L.t("menu.resume") : L.t("menu.pause")
        menu.addItem(withTitle: pauseTitle, action: #selector(menuTogglePause), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.skip"), action: #selector(menuSkip), keyEquivalent: "")
        menu.addItem(withTitle: L.t("help.postpone", viewModel.settings.postponeMinutes), action: #selector(menuPostpone), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.breakNow"), action: #selector(menuBreakNow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("menu.settings"), action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L.t("menu.stats"), action: #selector(menuStats), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.editor"), action: #selector(menuEditor), keyEquivalent: "")
        menu.addItem(.separator())
        if UpdaterController.shared.isConfigured {
            menu.addItem(withTitle: L.t("menu.checkUpdate"), action: #selector(menuCheckUpdate), keyEquivalent: "")
        }
        menu.addItem(withTitle: L.t("menu.about"), action: #selector(menuAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("help.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuTogglePause() { viewModel.togglePause() }
    @objc private func menuSkip()        { viewModel.skip() }
    @objc private func menuPostpone()    { viewModel.postpone() }
    @objc private func menuBreakNow()    { viewModel.breakNow() }
    @objc private func menuSettings()    { viewModel.openSettings() }
    @objc private func menuStats()       { viewModel.openStatistics() }
    @objc private func menuEditor()      { viewModel.openPatternEditor() }
    @objc private func menuCheckUpdate() { UpdaterController.shared.checkForUpdates(nil) }
    @objc private func menuAbout()       { viewModel.openAbout() }

    // MARK: - Helpers

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: "HapticBreak")?
            .withSymbolConfiguration(config)
    }
}

// MARK: - Panel visible → render gating + heartbeat companion
extension MenuBarController: NSPopoverDelegate {
    /// About to show: light up `panelVisible` first, so the ring animation starts together with the panel fade-in.
    func popoverWillShow(_ notification: Notification) {
        viewModel.panelVisible = true
    }
    func popoverDidShow(_ notification: Notification) {
        viewModel.controller?.panelOpened()
    }
    /// On close: turn off `panelVisible`, the ring stops all animations (shimmer/second hand, etc.), and it
    /// stays alive silently in the background.
    func popoverDidClose(_ notification: Notification) {
        viewModel.controller?.panelClosed()
        viewModel.panelVisible = false
        collapsePanelContent()
    }
}
