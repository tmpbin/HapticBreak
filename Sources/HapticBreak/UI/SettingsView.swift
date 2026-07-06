import SwiftUI

/// Settings, split by audience rather than by feature domain:
/// - **Basic**: the four decisions every user actually makes — cycle, haptic, acknowledge, general.
/// - **Advanced**: everything the smart defaults already handle, flat and honest for power users.
/// Backend/actuator diagnostics moved out of Settings entirely (into the About window).
struct SettingsView: View {
    enum Tab { case basic, advanced }

    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var showResetConfirm = false
    @State private var tab: Tab

    init(viewModel: AppViewModel, initialTab: Tab = .basic) {
        self.viewModel = viewModel
        _tab = State(initialValue: initialTab)
    }

    /// Version string shown in the footer — reads the packaged `CFBundleShortVersionString`, staying in
    /// sync with the release tag instead of being hard-coded.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// One shortcut recorder row: rejects combos already bound to another action and suspends the
    /// global hotkeys during capture (so the current combos can be re-recorded).
    @ViewBuilder
    private func hotKeyRow(_ title: String, _ keyPath: WritableKeyPath<HotKeyBindings, HotKeyBinding>) -> some View {
        HotKeyRecorderRow(
            title: title,
            binding: Binding(get: { settings.hotKeys[keyPath: keyPath] },
                             set: { settings.hotKeys[keyPath: keyPath] = $0 }),
            isTaken: { combo in
                var candidate = settings.hotKeys
                candidate[keyPath: keyPath] = combo
                return !candidate.hasNoDuplicates
            },
            setCaptureActive: { viewModel.setHotKeyCapture($0) })
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
        TabView(selection: $tab) {
            basicForm
                .tabItem { Label(L.t("settings.tab.basic"), systemImage: "slider.horizontal.3") }
                .tag(Tab.basic)
            advancedForm
                .tabItem { Label(L.t("settings.tab.advanced"), systemImage: "gearshape.2") }
                .tag(Tab.advanced)
        }
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .alert(L.t("settings.resetConfirmTitle"), isPresented: $showResetConfirm) {
            Button(L.t("btn.cancel"), role: .cancel) {}
            Button(L.t("settings.resetDefaults"), role: .destructive) { settings.resetToDefaults() }
        } message: {
            Text(L.t("settings.resetConfirmMsg"))
        }
    }

    // MARK: - Basic

    private var basicForm: some View {
        Form {
            Section {
                Picker(L.t("label.interval"), selection: $settings.breakIntervalMinutes) {
                    ForEach(Settings.intervalOptions, id: \.self) { Text(L.t("unit.minutes", $0)).tag($0) }
                }
                .id("pick.interval.\(l10n.language.rawValue)")

                Stepper(settings.restMinutes == 0 ? L.t("settings.restOff")
                                                  : L.t("settings.restN", settings.restMinutes),
                        value: $settings.restMinutes, in: 0...30)
            } header: {
                Text(L.t("settings.section.cycle"))
            } footer: {
                Text(L.t("settings.cycleFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                groupedPatternPicker(L.t("label.reminderPattern"), selection: $settings.selectedPatternID, idTag: "pattern")

                HStack {
                    Text(L.t("settings.intensityFull"))
                    Slider(value: Binding(get: { Double(settings.strength) },
                                          set: { settings.strength = Int($0.rounded()) }),
                           in: 1...10, step: 1)
                    Text("\(settings.strength)").monospacedDigit().frame(width: 22)
                    Button(L.t("btn.test")) { viewModel.testCurrentPattern() }
                }
            } header: {
                Text(L.t("settings.section.haptic"))
            }

            Section {
                Toggle(L.t("settings.ackGesture"), isOn: $settings.ackGestureEnabled)
                    .disabled(!TouchGestureMonitor.isSupported)
                Text(L.t("hotkey.ackHint", settings.hotKeys.acknowledge.display))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L.t("settings.section.acknowledge"))
            } footer: {
                Text(L.t("settings.ackFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L.t("settings.section.general")) {
                Picker(L.t("settings.language"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .id("pick.language.\(l10n.language.rawValue)")
                Toggle(L.t("settings.launchAtLogin"), isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    private var advancedForm: some View {
        Form {
            Section {
                Stepper(L.t("settings.pulseInterval", settings.remindPulseSeconds),
                        value: $settings.remindPulseSeconds, in: 10...120, step: 5)
                Stepper(L.t("settings.pulseMax", settings.remindPulseMax),
                        value: $settings.remindPulseMax, in: 1...10)
                Stepper(L.t("help.postpone", settings.postponeMinutes),
                        value: $settings.postponeMinutes, in: 1...30)
                Toggle(L.t("settings.typingDefer"), isOn: $settings.typingAwareDefer)
                Toggle(L.t("settings.headsUp"), isOn: $settings.gentleHeadsUp)
                Toggle(L.t("settings.panelHeartbeat"), isOn: $settings.panelHeartbeat)
                groupedPatternPicker(L.t("label.headsUpPattern"), selection: $settings.headsUpPatternID, idTag: "headsup")
                    .disabled(!settings.gentleHeadsUp)
                groupedPatternPicker(L.t("label.finishPattern"), selection: $settings.finishPatternID, idTag: "finish")
            } header: {
                Text(L.t("settings.section.reminderBehavior"))
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
                Toggle(L.t("settings.shortcuts"), isOn: $settings.enableShortcuts)
                if settings.enableShortcuts {
                    hotKeyRow(L.t("hotkey.pause"), \.pause)
                    hotKeyRow(L.t("hotkey.skip"), \.skip)
                    hotKeyRow(L.t("hotkey.buzz"), \.buzz)
                    hotKeyRow(L.t("hotkey.ack"), \.acknowledge)
                    if settings.hotKeys != .defaults {
                        Button(L.t("hotkey.reset")) { settings.hotKeys = .defaults }
                    }
                }
            } header: {
                Text(L.t("settings.section.hotkeys"))
            } footer: {
                Text(L.t("settings.hotkeysFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L.t("settings.autoUpdate"), isOn: $settings.autoUpdateCheck)
                LabeledContent(L.t("settings.checkUpdate")) {
                    Button(L.t("settings.checkNow")) { UpdaterController.shared.checkForUpdates(nil) }
                        .buttonStyle(.bordered)
                }
                LabeledContent(L.t("editor.title")) {
                    Button(L.t("settings.openEditorBtn")) { viewModel.openPatternEditor() }
                        .buttonStyle(.bordered)
                }
            } header: {
                Text(L.t("settings.adv.system"))
            } footer: {
                Text(L.t("settings.updateFooter"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(L.t("settings.resetDefaults")) {
                    Button(role: .destructive) { showResetConfirm = true } label: {
                        Label(L.t("settings.resetBtn"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("settings.resetFooter"))
                    Text("HapticBreak v" + Self.appVersion)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
