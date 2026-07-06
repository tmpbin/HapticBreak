import SwiftUI

/// Haptic Lab: a small calibration bench for tuning how HapticBreak feels on *this* machine.
/// Two jobs, top to bottom:
/// 1. **Timbre feel check** — audition the three timbre families (soft / crisp / low-buzz) and, if one
///    feels wrong on this trackpad, switch it to an alternative actuation (persisted across launches).
/// 2. **Strength curve 1→10** — audition the exact strength scale the app plays, end to end.

// MARK: - Timbre catalog (alternative actuations per family, labelled by measured feel)

struct LabWaveform: Identifiable, Hashable {
    let id: Int32
    let nameKey: String
    var displayName: String { L.t(nameKey) }
}

enum HapticLabCatalog {
    static let waveforms: [LabWaveform] = [
        LabWaveform(id: 1,  nameKey: "lab.wf.1"),
        LabWaveform(id: 2,  nameKey: "lab.wf.2"),
        LabWaveform(id: 3,  nameKey: "lab.wf.3"),
        LabWaveform(id: 4,  nameKey: "lab.wf.4"),
        LabWaveform(id: 5,  nameKey: "lab.wf.5"),
        LabWaveform(id: 6,  nameKey: "lab.wf.6"),
        LabWaveform(id: 15, nameKey: "lab.wf.15"),
        LabWaveform(id: 16, nameKey: "lab.wf.16"),
    ]
}

// MARK: - Controller

/// Lab controller. Haptics fire on a dedicated serial queue (actuator create+open+actuate+close takes
/// time, avoid blocking the main thread); all `@Published` writes go back to the main thread. Sequence
/// playback uses `generation` guarding, so a new trigger cancels the old sequence.
final class HapticLab: ObservableObject, @unchecked Sendable {
    @Published var running = false
    @Published var nowPlaying: String = ""

    // Strength-curve audition controls (the exact production resolution path).
    @Published var curveTimbre: HapticTimbre = .crisp
    @Published var curveStrength: Int = 5

    /// Fire once on slide / param change, for continuously "sweeping" parameters to find the right feel. On by default.
    @Published var fireOnDrag = true

    let isAvailable: Bool

    private let engine = PrivateHapticEngine(debug: false)
    private let queue = DispatchQueue(label: "com.aremind.hapticbreak.lab", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    init() {
        isAvailable = engine.isAvailable
    }

    // MARK: Timbre feel check

    /// Audition a timbre family's currently assigned actuation (mid strength) — the exact production feel.
    func fireTimbre(_ timbre: HapticTimbre) {
        let tone = HapticProfile.shared.resolve(timbre: timbre, strength: 6, dullness: 0.3, global: 6)
        fireRaw(id: tone.actuationID, scale: tone.float0, time: tone.float1)
    }

    func dragFireTimbre(_ timbre: HapticTimbre) {
        guard isAvailable, fireOnDrag, !running else { return }
        fireTimbre(timbre)
    }

    // MARK: Strength curve 1→10

    /// Resolve and fire once with the current (timbre, strength) — exactly matching the app's production path.
    func fireCurvePoint() {
        let tone = HapticProfile.shared.resolve(timbre: curveTimbre, strength: curveStrength, dullness: 0.3, global: 6)
        fireRaw(id: tone.actuationID, scale: tone.float0, time: tone.float1)
    }

    func dragFireCurve() { guard isAvailable, fireOnDrag, !running else { return }; fireCurvePoint() }

    /// Play the 1→10 curve end-to-end (same timbre, only strength increasing), to confirm it's
    /// monotonic and distinguishable on this machine.
    func previewCurve() {
        let items: [RawItem] = (1...HapticProfile.strengthLevels).map { s in
            let tone = HapticProfile.shared.resolve(timbre: curveTimbre, strength: s, dullness: 0.3, global: 6)
            return RawItem(id: tone.actuationID, scale: tone.float0, time: tone.float1,
                           label: L.t("lab.curve.now", s))
        }
        runRawSequence(items, gapMs: 600)
    }

    func stop() { _ = bump(); running = false; nowPlaying = "" }

    // MARK: - Internals

    private struct RawItem { let id: Int32; let scale: Float; let time: Float; let label: String }

    /// Single trigger (cancels the in-progress sequence). Coalesces rapid drag fires: only the newest
    /// queued closure performs the heavy create→open→actuate→close; superseded ones bail early.
    private func fireRaw(id: Int32, scale: Float, time: Float) {
        let myGen = bump(); running = false; nowPlaying = ""
        queue.async { [weak self] in
            guard let self, !self.isStale(myGen) else { return }
            _ = self.engine.actuateRaw(actuationID: id, strengthFlags: 0, scale: scale, timeScale: time)
        }
    }

    private func runRawSequence(_ items: [RawItem], gapMs: Int) {
        guard !items.isEmpty else { return }
        let myGen = bump()
        running = true
        queue.async { [weak self] in
            guard let self else { return }
            for it in items {
                if self.isStale(myGen) { break }
                DispatchQueue.main.async { self.nowPlaying = it.label }
                _ = self.engine.actuateRaw(actuationID: it.id, strengthFlags: 0, scale: it.scale, timeScale: it.time)
                usleep(useconds_t(gapMs * 1000))
            }
            DispatchQueue.main.async {
                if !self.isStale(myGen) { self.running = false; self.nowPlaying = "" }
            }
        }
    }

    private func bump() -> Int { lock.lock(); generation += 1; let g = generation; lock.unlock(); return g }
    private func isStale(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation != g }
}

// MARK: - View

struct HapticLabView: View {
    @StateObject private var lab = HapticLab()
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var profile = HapticProfile.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !lab.isAvailable { unavailableNotice }
                timbreSection
                curveSection
                if lab.running { runningBar }
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 480)
    }

    // MARK: Title + status

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("lab.title")).font(.system(size: 20, weight: .semibold))
            Text(L.t("lab.subtitle")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label(lab.isAvailable ? L.t("lab.diag.ready") : L.t("lab.diag.unavailable"),
                      systemImage: lab.isAvailable ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(lab.isAvailable ? .green : .orange)
                    .font(.caption)
                Toggle(isOn: $lab.fireOnDrag) { Text(L.t("lab.fireOnDrag")).font(.caption) }
                    .toggleStyle(.switch).controlSize(.mini).fixedSize()
            }
        }
    }

    private var unavailableNotice: some View {
        Label(L.t("lab.unavailable.note"), systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Timbre feel check

    private var timbreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L.t("lab.timbre.title"), L.t("lab.timbre.hint"))
            ForEach(HapticTimbre.allCases) { t in timbreRow(t) }
            if !isDefaultAssignment {
                Button(L.t("lab.reset")) { profile.resetToDefault() }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isDefaultAssignment: Bool {
        profile.softID == HapticTimbre.soft.defaultActuationID
            && profile.crispID == HapticTimbre.crisp.defaultActuationID
            && profile.buzzID == HapticTimbre.buzz.defaultActuationID
    }

    private func timbreRow(_ t: HapticTimbre) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Label(t.displayName, systemImage: t.symbol)
                Text(L.t("lab.timbre.desc." + t.rawValue)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)
            Picker("", selection: Binding(
                get: { profile.actuationID(for: t) },
                set: { profile.setActuationID($0, for: t); lab.dragFireTimbre(t) })) {
                ForEach(HapticLabCatalog.waveforms) { wf in Text(wf.displayName).tag(wf.id) }
            }
            .labelsHidden().frame(width: 130)
            .id("lab.timbre.\(t.rawValue).\(l10n.language.rawValue)")
            Spacer()
            Button { lab.fireTimbre(t) } label: { Image(systemName: "hand.tap.fill") }
                .buttonStyle(.bordered).disabled(!lab.isAvailable)
                .help(L.t("lab.try")).accessibilityLabel(L.t("lab.try"))
        }
    }

    // MARK: Strength curve 1→10

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L.t("lab.curve.title"), L.t("lab.curve.hint"))
            Picker("", selection: Binding(get: { lab.curveTimbre }, set: { lab.curveTimbre = $0; lab.dragFireCurve() })) {
                ForEach(HapticTimbre.allCases) { t in Text(t.displayName).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .id("lab.curve.timbre.\(l10n.language.rawValue)")

            HStack(spacing: 10) {
                Text(L.t("lab.curve.strength")).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Slider(value: Binding(get: { Double(lab.curveStrength) }, set: { lab.curveStrength = Int($0.rounded()) }), in: 1...10, step: 1)
                    .onChange(of: lab.curveStrength) { _ in lab.dragFireCurve() }
                Text("\(lab.curveStrength)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Button { lab.fireCurvePoint() } label: {
                    Label(L.t("lab.try"), systemImage: "hand.tap.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).disabled(!lab.isAvailable)
                Button { lab.previewCurve() } label: {
                    Label(L.t("lab.curve.preview"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(!lab.isAvailable || lab.running)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Running status bar + footer

    private var runningBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(lab.nowPlaying).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button(L.t("lab.stop")) { lab.stop() }.controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        Text(L.t("lab.footer"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
