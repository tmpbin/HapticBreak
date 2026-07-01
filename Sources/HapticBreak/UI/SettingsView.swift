import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var showResetConfirm = false
    @State private var labTapCount = 0
    @State private var lastLabTap = Date.distantPast

    /// Version string shown in "About" — reads the packaged `CFBundleShortVersionString`, staying in sync
    /// with the release tag instead of being hard-coded.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Hidden entry point: tapping the "actuator status" row 5 times within 2 seconds opens the "Haptic Lab".
    private func revealHapticLab() {
        let now = Date()
        labTapCount = now.timeIntervalSince(lastLabTap) < 2.0 ? labTapCount + 1 : 1
        lastLabTap = now
        if labTapCount >= 5 {
            labTapCount = 0
            viewModel.openHapticLab()
        }
    }

    /// Category-grouped pattern picker (basic / nature / rhythm / custom).
    @ViewBuilder
    private func groupedPatternPicker(_ title: String, selection: Binding<String>, idTag: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(HapticPatternCategory.allCases) { cat in
                let items = settings.patterns(in: cat)
                if !items.isEmpty {
                    Section(cat.displayName) {
                        ForEach(items) { Text($0.displayName).tag($0.id) }
                    }
                }
            }
        }
        .id("pick.\(idTag).\(l10n.language.rawValue)")
    }

    var body: some View {
        Form {
            Section(L.t("settings.section.general")) {
                Picker(L.t("settings.language"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .id("pick.language.\(l10n.language.rawValue)")
            }

            Section {
                Picker(L.t("label.interval"), selection: $settings.breakIntervalMinutes) {
                    ForEach(Settings.intervalOptions, id: \.self) { Text(L.t("unit.minutes", $0)).tag($0) }
                }
                .disabled(settings.pomodoroEnabled)
                .id("pick.interval.\(l10n.language.rawValue)")

                groupedPatternPicker(L.t("label.reminderPattern"), selection: $settings.selectedPatternID, idTag: "pattern")

                HStack {
                    Text(L.t("settings.intensityFull"))
                    Slider(value: Binding(get: { Double(settings.strength) },
                                          set: { settings.strength = Int($0.rounded()) }),
                           in: 1...10, step: 1)
                    Text("\(settings.strength)").monospacedDigit().frame(width: 22)
                    Button(L.t("btn.test")) { viewModel.testCurrentPattern() }
                }

                Stepper(settings.reminderRepeat <= 1 ? L.t("settings.repeatOnce") : L.t("settings.repeatN", settings.reminderRepeat),
                        value: $settings.reminderRepeat, in: 1...5)

                Stepper(L.t("help.postpone", settings.postponeMinutes),
                        value: $settings.postponeMinutes, in: 1...30)
            } header: {
                Text(L.t("settings.section.reminder"))
            } footer: {
                if settings.pomodoroEnabled {
                    Text(L.t("settings.reminderPomoFooter"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                groupedPatternPicker(L.t("label.headsUpPattern"), selection: $settings.headsUpPatternID, idTag: "headsup")
                    .disabled(!settings.gentleHeadsUp)
                groupedPatternPicker(L.t("label.finishPattern"), selection: $settings.finishPatternID, idTag: "finish")
            } header: {
                Text(L.t("settings.section.events"))
            } footer: {
                Text(L.t("settings.eventsFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L.t("settings.typingDefer"), isOn: $settings.typingAwareDefer)
                Toggle(L.t("settings.headsUp"), isOn: $settings.gentleHeadsUp)
                Toggle(L.t("settings.escalation"), isOn: $settings.skipEscalation)
                Toggle(L.t("settings.panelHeartbeat"), isOn: $settings.panelHeartbeat)
            } header: {
                Text(L.t("settings.section.rhythm"))
            } footer: {
                Text(L.t("settings.rhythmFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L.t("settings.idle"), isOn: $settings.idleEnabled)
                Stepper(L.t("settings.idleSeconds", settings.idlePauseSeconds),
                        value: $settings.idlePauseSeconds, in: 15...600, step: 15)
                    .disabled(!settings.idleEnabled)
                Stepper(settings.idleResetMinutes == 0 ? L.t("settings.idleResetOff")
                                                       : L.t("settings.idleResetN", settings.idleResetMinutes),
                        value: $settings.idleResetMinutes, in: 0...60, step: 1)
                    .disabled(!settings.idleEnabled)
                Toggle(L.t("settings.fullscreen"), isOn: $settings.skipDuringFullscreen)
                Toggle(L.t("settings.mic"), isOn: $settings.pauseDuringMic)
                Toggle(L.t("settings.focus"), isOn: $settings.respectFocusMode)
            } header: {
                Text(L.t("settings.section.autopause"))
            } footer: {
                Text(L.t("settings.autopauseFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L.t("settings.adv.pomodoro")) {
                Toggle(L.t("settings.pomodoroToggle"), isOn: $settings.pomodoroEnabled)
                Stepper(L.t("settings.pomoWork", settings.pomodoroWorkMinutes),
                        value: $settings.pomodoroWorkMinutes, in: 5...90)
                    .disabled(!settings.pomodoroEnabled)
                Stepper(L.t("settings.pomoBreak", settings.pomodoroBreakMinutes),
                        value: $settings.pomodoroBreakMinutes, in: 1...30)
                    .disabled(!settings.pomodoroEnabled)
            }

            Section {
                Picker(L.t("settings.menuBarStyle"), selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .id("pick.menubar.\(l10n.language.rawValue)")
                Toggle(L.t("settings.flash"), isOn: $settings.auxFlashScreen)
                Toggle(L.t("settings.menubarHi"), isOn: $settings.auxMenubarHighlight)
                Toggle(L.t("settings.sound"), isOn: $settings.soundEnabled)
                if settings.soundEnabled {
                    Picker(L.t("settings.soundName"), selection: $settings.soundName) {
                        ForEach(AuxReminder.systemSoundNames, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: settings.soundName) { _ in AuxReminder.play(named: settings.soundName) }
                    Button {
                        AuxReminder.play(named: settings.soundName)
                    } label: {
                        Label(L.t("settings.soundPreview"), systemImage: "speaker.wave.2.fill")
                    }
                    .help(L.t("settings.soundPreviewHelp"))
                }
            } header: {
                Text(L.t("settings.adv.menubar"))
            } footer: {
                Text(L.t("settings.alertsFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(L.t("settings.backendPicker"), selection: $settings.backend) {
                    ForEach(HapticBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .id("pick.backend.\(l10n.language.rawValue)")
                LabeledContent(L.t("settings.currentBackend"), value: viewModel.backendName)
                LabeledContent(L.t("settings.actuatorStatus")) {
                    Label(viewModel.backendAvailable ? L.t("status.available") : L.t("status.unavailable"),
                          systemImage: viewModel.backendAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(viewModel.backendAvailable ? .green : .orange)
                        .labelStyle(.titleAndIcon)
                }
                .contentShape(Rectangle())
                .onTapGesture { revealHapticLab() }   // Hidden entry point: tap 5 times to open the "Haptic Lab"
            } header: {
                Text(L.t("settings.adv.backend"))
            } footer: {
                Text(L.t("settings.backendFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L.t("settings.launchAtLogin"), isOn: $settings.launchAtLogin)
                Toggle(L.t("settings.shortcuts"), isOn: $settings.enableShortcuts)
                if settings.enableShortcuts {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("settings.scPause")).font(.caption).foregroundStyle(.secondary)
                        Text(L.t("settings.scSkip")).font(.caption).foregroundStyle(.secondary)
                        Text(L.t("settings.scBreak")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(L.t("settings.autoUpdate"), isOn: $settings.autoUpdateCheck)
                Button {
                    UpdaterController.shared.checkForUpdates(nil)
                } label: {
                    Label(L.t("settings.checkUpdate"), systemImage: "arrow.triangle.2.circlepath")
                }
                Button(L.t("settings.openEditor")) { viewModel.openPatternEditor() }
            } header: {
                Text(L.t("settings.adv.system"))
            } footer: {
                Text(L.t("settings.updateFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Label(L.t("settings.resetDefaults"), systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text(L.t("settings.resetFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("HapticBreak", value: "v" + Self.appVersion)
                Text(L.t("settings.about"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .alert(L.t("settings.resetConfirmTitle"), isPresented: $showResetConfirm) {
            Button(L.t("btn.cancel"), role: .cancel) {}
            Button(L.t("settings.resetDefaults"), role: .destructive) { settings.resetToDefaults() }
        } message: {
            Text(L.t("settings.resetConfirmMsg"))
        }
    }
}
