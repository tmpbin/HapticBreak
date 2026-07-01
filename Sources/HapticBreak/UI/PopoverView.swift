import SwiftUI

/// Menu-bar control panel (opened with a left click).
struct PopoverView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 14) {
            CountdownRing(remaining: viewModel.remaining,
                          total: viewModel.total,
                          color: viewModel.accentColor,
                          timeText: viewModel.timeString,
                          statusText: viewModel.statusText,
                          statusSymbol: viewModel.statusSymbol,
                          animated: !viewModel.isPaused && !viewModel.isDeferring && viewModel.panelVisible,
                          onImpact: { viewModel.ringImpact() })
                .padding(.top, 14)

            if !viewModel.nextFireText.isEmpty || viewModel.streak >= 1 {
                HStack(spacing: 12) {
                    if !viewModel.nextFireText.isEmpty {
                        Label(L.t("popover.nextReminder", viewModel.nextFireText), systemImage: "bell.badge")
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.streak >= 1 {
                        Label(L.t("popover.streakDays", viewModel.streak), systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 8) {
                ActionButton(title: viewModel.pauseReason == .manual ? L.t("action.resume") : L.t("action.pause"),
                             symbol: viewModel.pauseReason == .manual ? "play.fill" : "pause.fill",
                             prominent: true, accent: viewModel.accentColor) { viewModel.togglePause() }
                    .help(viewModel.pauseReason == .manual ? L.t("help.resume") : L.t("help.pause"))
                ActionButton(title: L.t("action.skip"), symbol: "forward.end.fill") { viewModel.skip() }
                    .help(L.t("help.skip"))
                ActionButton(title: L.t("action.postpone", settings.postponeMinutes), symbol: "clock.arrow.circlepath") { viewModel.postpone() }
                    .help(L.t("help.postpone", settings.postponeMinutes))
                ActionButton(title: L.t("action.testHaptic"), symbol: "hand.tap.fill") { viewModel.testCurrentPattern() }
                    .help(L.t("help.testHaptic"))
            }

            if !viewModel.backendAvailable {
                Label(L.t("popover.noActuator"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Label(L.t("label.interval"), systemImage: "timer").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Settings.intervalOptions, id: \.self) { minutes in
                        Chip(text: "\(minutes)",
                             selected: settings.breakIntervalMinutes == minutes && !settings.pomodoroEnabled) {
                            settings.pomodoroEnabled = false
                            settings.breakIntervalMinutes = minutes
                        }
                    }
                }
                if settings.pomodoroEnabled {
                    Label(L.t("popover.pomodoroMode", settings.pomodoroWorkMinutes, settings.pomodoroBreakMinutes),
                          systemImage: "leaf.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }

            // Pattern + intensity: left label column aligned, controls filling the right side, two paired
            // rows — dropping the old native popup that floated at half width, and forming a clear
            // hierarchy with the full-width interval pills above ("full-row select → paired fine-tune").
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label(L.t("label.pattern"), systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: Theme.rowLabelWidth, alignment: .leading)
                    // The pattern picker aligns left against the label column, starting at the same x as the
                    // slider below, paired and columnar; the popup hugs its content (normal popup behavior).
                    // Pattern selection = "select-to-preview": switching auto-previews once (panel visible only),
                    // the same interaction as the sound picker; the "test" action row above lets you feel the
                    // current haptic anytime (first-launch exploration) — distinct roles, no duplicated control.
                    // .id(...language): the menu Picker's underlying NSPopUpButton caches the collapsed title,
                    // so a language switch needs a rebuild to refresh the selected item's text.
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
                FooterButton(title: L.t("footer.patterns"), symbol: "slider.horizontal.3") { viewModel.openPatternEditor() }
                    .help(L.t("help.openEditor"))
                Spacer()
                FooterButton(title: L.t("footer.quit"), symbol: "power") { viewModel.quit() }
                    .help(L.t("help.quit"))
            }
        }
        .padding(16)
        .frame(width: Theme.panelWidth)
    }
}
