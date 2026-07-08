import SwiftUI

/// Menu-bar control panel (opened with a left click).
///
/// The panel manages "now" (ring, actions, quick interval) plus the product's first impression:
/// pattern selection (select-to-preview), strength and a test button live here so a first-time
/// user can feel the haptic identity without opening Settings.
struct PopoverView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared

    /// The popover keeps this hosting view alive even while dismissed. When `collapsed` (panel closed) the
    /// body renders only an inert placeholder, so the observed view model's per-second ticks don't re-lay-out
    /// the whole ring/controls subtree in the background. The menu-bar controller flips this on show/close.
    var collapsed: Bool = false

    var body: some View {
        if collapsed {
            // Keep the panel width so reopening doesn't flash a resize; height is minimal since it's unseen.
            Color.clear.frame(width: Theme.panelWidth, height: 1)
        } else {
            expandedContent
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 14) {
            CountdownRing(remaining: viewModel.remaining,
                          total: viewModel.total,
                          color: viewModel.accentColor,
                          timeText: viewModel.timeString,
                          statusText: displayStatusText,
                          statusSymbol: viewModel.statusSymbol,
                          animated: !viewModel.isPaused && !viewModel.isDeferring && viewModel.panelVisible,
                          breathing: viewModel.phase == .resting && !viewModel.isPaused && viewModel.panelVisible,
                          onImpact: { viewModel.ringImpact() },
                          onTap: ringTap,
                          tapHint: ringTapHint)
                .padding(.top, 14)

            VStack(spacing: 8) {
                infoRow
                if !viewModel.todayRhythm.isEmpty {
                    TodayRhythmBand(rhythm: viewModel.todayRhythm)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.openStatistics() }
                        .help(L.t("popover.bandHelp"))
                }
            }

            actionRow

            if viewModel.showNudgeHint {
                nudgeHintCard
            } else if !settings.hasSeenPanelIntro {
                Label(L.t("popover.firstIntro"), systemImage: "hand.wave.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(Theme.neutralFill))
            }

            if !viewModel.backendAvailable {
                Label(L.t("popover.noActuator"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Label(L.t("label.interval"), systemImage: "timer").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // Quiet scenes: bounded "not now" decisions that restore themselves — smarter than
                    // a bare pause, which is easy to forget to resume.
                    Menu {
                        Button(L.t("scene.focus90"))   { viewModel.startFocusScene() }
                        Button(L.t("scene.meeting60")) { viewModel.startQuietScene(.meeting) }
                        Button(L.t("scene.doneToday")) { viewModel.startQuietScene(.day) }
                    } label: {
                        Label(L.t("scene.menu"), systemImage: "moon")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    ForEach(Settings.intervalOptions, id: \.self) { minutes in
                        Chip(text: "\(minutes)",
                             selected: settings.breakIntervalMinutes == minutes) {
                            settings.breakIntervalMinutes = minutes
                        }
                    }
                }
                if settings.restMinutes > 0 {
                    Label(L.t("popover.cycleMode", settings.breakIntervalMinutes, settings.restMinutes),
                          systemImage: "cup.and.saucer.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }

            // Pattern + intensity: left label column aligned, controls filling the right side, two paired
            // rows — a first-time user can explore the haptic identity right here (select-to-preview,
            // same interaction as the sound picker).
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label(L.t("label.pattern"), systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: Theme.rowLabelWidth, alignment: .leading)
                    // .id(...language): the menu Picker's underlying NSPopUpButton caches the collapsed
                    // title, so a language switch needs a rebuild to refresh the selected item's text.
                    Picker("", selection: $settings.selectedPatternID) {
                        ForEach(HapticPatternCategory.allCases) { cat in
                            let items = settings.patterns(in: cat)
                            if !items.isEmpty {
                                Section(cat.displayName) {
                                    ForEach(items) { Text($0.displayName).tag($0.id) }
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("pick.pop.pattern.\(l10n.language.rawValue)")
                    .onChange(of: settings.selectedPatternID) { _ in
                        if viewModel.panelVisible { viewModel.testCurrentPattern() }
                    }
                    // Dice: jump to a random pattern — select-to-preview turns the 35 presets
                    // into small first-run surprises.
                    Button {
                        let others = settings.allPatterns.filter { $0.id != settings.selectedPatternID }
                        if let pick = others.randomElement() { settings.selectedPatternID = pick.id }
                    } label: {
                        Image(systemName: "die.face.5")
                    }
                    .buttonStyle(.borderless)
                    .help(L.t("help.dice"))
                }
                HStack(spacing: 8) {
                    Label(L.t("label.intensity"), systemImage: "dial.medium")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: Theme.rowLabelWidth, alignment: .leading)
                    Slider(value: Binding(get: { Double(settings.strength) },
                                          set: { settings.strength = Int($0.rounded()) }),
                           in: 1...10, step: 1)
                    Text("\(settings.strength)").font(.caption).monospacedDigit().frame(width: 18)
                }
            }

            Divider()

            HStack(spacing: 14) {
                FooterButton(title: L.t("footer.settings"), symbol: "gearshape") { viewModel.openSettings() }
                    .help(L.t("help.openSettings"))
                FooterButton(title: L.t("footer.stats"), symbol: "chart.bar") { viewModel.openStatistics() }
                    .help(L.t("help.openStats"))
                Spacer()
                FooterButton(title: L.t("footer.quit"), symbol: "power") { viewModel.quit() }
                    .help(L.t("help.quit"))
            }
        }
        .padding(16)
        .frame(width: Theme.panelWidth)
    }

    /// Ring click = the primary action. Only offered in self-decided states (working / manual pause /
    /// reminding) — during environment pauses (idle / fullscreen / meeting / Focus / scene) a click
    /// would stack a confusing manual pause on top, so the ring stays inert.
    private var ringTap: (() -> Void)? {
        if viewModel.phase == .reminding { return { [weak viewModel] in viewModel?.acknowledge() } }
        switch viewModel.pauseReason {
        case .none, .manual: return { [weak viewModel] in viewModel?.togglePause() }
        default: return nil
        }
    }

    private var ringTapHint: (symbol: String, label: String)? {
        if viewModel.phase == .reminding { return ("cup.and.saucer.fill", L.t("ring.tapAck")) }
        switch viewModel.pauseReason {
        case .none:   return ("pause.fill", L.t("ring.tapPause"))
        case .manual: return ("play.fill", L.t("ring.tapResume"))
        default:      return nil
        }
    }

    /// Rest phase: the status line rotates gentle companion tips every 10 s (driven by the elapsed
    /// seconds the panel already re-renders on — no extra timer).
    private var displayStatusText: String {
        guard viewModel.phase == .resting, !viewModel.isPaused else { return viewModel.statusText }
        let sequence = ["status.resting", "tip.rest.1", "tip.rest.2", "tip.rest.3", "tip.rest.4"]
        let elapsed = max(0, viewModel.total - viewModel.remaining)
        return L.t(sequence[(elapsed / 10) % sequence.count])
    }

    private var autoResumeKey: String? {
        switch viewModel.pauseReason {
        case .idle:       return "popover.resume.idle"
        case .fullscreen: return "popover.resume.fullscreen"
        case .meeting:    return "popover.resume.meeting"
        case .focus:      return "popover.resume.focus"
        default:          return nil
        }
    }

    /// Companion line, always exactly one caption row high (state changes must not jolt the layout).
    /// The leading slot carries whichever is relevant — active scene (with cancel), auto-pause
    /// transparency ("resumes after …"), or the next reminder time; today's real rests trail it.
    /// When every source is empty (e.g. a fresh user pausing manually) a hidden anchor keeps the height.
    @ViewBuilder
    private var infoRow: some View {
        HStack(spacing: 12) {
            if !viewModel.sceneText.isEmpty {
                Label(viewModel.sceneText, systemImage: "moon.stars")
                    .foregroundStyle(.secondary)
                Button(L.t("scene.cancel")) { viewModel.cancelScene() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            } else if let key = autoResumeKey {
                Label(L.t(key), systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            } else if viewModel.phase == .reminding {
                // Make the reminding model legible at a glance: what stops the nudging, and that
                // actually walking away is enough — no buttons needed.
                Label(L.t("popover.remindingHint"), systemImage: "figure.walk.motion")
                    .foregroundStyle(.secondary)
            } else if !viewModel.nextFireText.isEmpty {
                Label(L.t("popover.nextReminder", viewModel.nextFireText), systemImage: "bell.badge")
                    .foregroundStyle(.secondary)
            } else if viewModel.todayBreaks < 1 {
                Label(L.t("status.paused"), systemImage: "bell.badge").hidden()
            }
            if viewModel.todayBreaks >= 1 {
                Label(L.t("popover.todayBreaks", viewModel.todayBreaks), systemImage: "cup.and.saucer")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.openStatistics() }
        .help(L.t("help.openStats"))
    }

    /// Teaching hint card: pops up after several unanswered nudges to teach the user how to acknowledge.
    private var nudgeHintCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L.t("popover.nudgeHint.title"), systemImage: "hand.raised.fingers.spread.fill")
                .font(.caption.bold())
            Text(L.t("popover.nudgeHint.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
    }

    /// While reminding, the primary action becomes "Start break" (acknowledge); otherwise pause/resume.
    private var actionRow: some View {
        HStack(spacing: 8) {
            if viewModel.phase == .reminding {
                ActionButton(title: L.t("action.acknowledge"), symbol: "cup.and.saucer.fill",
                             prominent: true, accent: viewModel.accentColor) { viewModel.acknowledge() }
                    .help(L.t("help.acknowledge", settings.hotKeys.acknowledge.display))
            } else {
                ActionButton(title: viewModel.pauseReason == .manual ? L.t("action.resume") : L.t("action.pause"),
                             symbol: viewModel.pauseReason == .manual ? "play.fill" : "pause.fill",
                             prominent: true, accent: viewModel.accentColor) { viewModel.togglePause() }
                    .help(viewModel.pauseReason == .manual ? L.t("help.resume") : L.t("help.pause"))
            }
            ActionButton(title: L.t("action.skip"), symbol: "forward.end.fill") { viewModel.skip() }
                .help(L.t("help.skip"))
            ActionButton(title: L.t("action.postpone", settings.postponeMinutes), symbol: "clock.arrow.circlepath") { viewModel.postpone() }
                .help(L.t("help.postpone", settings.postponeMinutes))
            ActionButton(title: L.t("action.testHaptic"), symbol: "hand.tap.fill") { viewModel.testCurrentPattern() }
                .help(L.t("help.testHaptic"))
        }
    }
}

/// Today's rhythm band: hour cells shaded by work density, green dots = real rests, a thin line = now.
/// Glanceable honesty — the day's story without opening the statistics window.
private struct TodayRhythmBand: View {
    var rhythm: TodayRhythm

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let nowMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let bounds = Self.visibleHours(rhythm: rhythm, nowHour: nowMinute / 60)
        let spanMinutes = CGFloat((bounds.end - bounds.start) * 60)

        GeometryReader { geo in
            let width = geo.size.width
            let xOf: (Int) -> CGFloat = { minute in
                width * CGFloat(minute - bounds.start * 60) / spanMinutes
            }

            ZStack(alignment: .leading) {
                HStack(spacing: 1.5) {
                    ForEach(bounds.start..<bounds.end, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(Self.cellOpacity(rhythm.activeByHour[hour])))
                    }
                }
                ForEach(Array(rhythm.breakMinutes.enumerated()), id: \.offset) { _, minute in
                    if minute >= bounds.start * 60 && minute < bounds.end * 60 {
                        Circle().fill(.green)
                            .frame(width: 5, height: 5)
                            .position(x: xOf(minute), y: geo.size.height / 2)
                    }
                }
                if nowMinute >= bounds.start * 60 && nowMinute < bounds.end * 60 {
                    Capsule().fill(.secondary)
                        .frame(width: 1.5, height: geo.size.height + 3)
                        .position(x: xOf(nowMinute), y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 7)
    }

    private static func cellOpacity(_ activeSeconds: Int) -> Double {
        activeSeconds == 0 ? 0.07 : 0.18 + 0.55 * min(1, Double(activeSeconds) / 3600)
    }

    /// Visible range: from the earliest activity (capped at 9 AM if the day started later) through
    /// "now", at least 8 hours wide so a fresh morning doesn't look zoomed-in.
    static func visibleHours(rhythm: TodayRhythm, nowHour: Int) -> (start: Int, end: Int) {
        var marks = rhythm.activeByHour.enumerated().filter { $0.element > 0 }.map(\.offset)
        marks += rhythm.breakMinutes.map { $0 / 60 }
        let first = marks.min() ?? nowHour
        let start = max(0, min(first, min(nowHour, 9)))
        let end = min(24, max(max(marks.max() ?? nowHour, nowHour) + 1, start + 8))
        return (start, max(end, start + 1))
    }
}
