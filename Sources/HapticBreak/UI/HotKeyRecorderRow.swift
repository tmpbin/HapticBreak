import SwiftUI
import AppKit
import Carbon.HIToolbox

/// One editable shortcut row: label on the left, the current combo as a bordered button on the
/// right. Click → recording mode (orange): the next key press becomes the new combo; ⎋ cancels.
/// While recording the app's global hotkeys are suspended, so the *current* combos can be re-recorded
/// instead of being swallowed by Carbon before they reach us.
struct HotKeyRecorderRow: View {
    let title: String
    @Binding var binding: HotKeyBinding
    /// Rejects combos already used by another action.
    let isTaken: (HotKeyBinding) -> Bool
    /// Suspends (true) / restores (false) the app's global hotkey registration during capture.
    let setCaptureActive: (Bool) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.orange)
                }
                Button {
                    recording ? stopRecording() : beginRecording()
                } label: {
                    Text(recording ? L.t("hotkey.recording") : binding.display)
                        .monospacedDigit()
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .tint(recording ? .orange : nil)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func beginRecording() {
        guard monitor == nil else { return }
        recording = true
        hint = nil
        setCaptureActive(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // Swallow every key press while recording
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        guard let combo = HotKeyBinding(event: event) else {
            hint = L.t("hotkey.needModifier")
            return
        }
        if combo != binding, isTaken(combo) {
            hint = L.t("hotkey.taken")
            return
        }
        binding = combo
        hint = nil
        stopRecording()
    }

    private func stopRecording() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        setCaptureActive(false)
    }
}
