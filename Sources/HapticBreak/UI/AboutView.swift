import SwiftUI

/// About window: app identity + the haptic backend diagnostics that used to clutter Settings.
/// "MultitouchSupport · private API" is debug information — it belongs here, out of everyday sight,
/// together with the hidden Haptic Lab entry (tap the actuator row 5 times).
struct AboutView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var labTapCount = 0
    @State private var lastLabTap = Date.distantPast

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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 72, height: 72)
                }
                Text("HapticBreak").font(.title3.bold())
                Text("v" + SettingsView.appVersion)
                    .font(.caption).foregroundStyle(.secondary)
                Text(L.t("settings.about"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
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
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }
}
